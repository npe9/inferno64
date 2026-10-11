#include "ember.h"

/*
 * resolver and type checker.
 *
 * walks the parsed tree, resolving names against nested scopes,
 * mapping ember surface types onto the backend type model in
 * types.c, and annotating expression nodes with their types.
 * imports are resolved from ember .ei interfaces (iface.c).
 *
 * the output feeds com.c: every name node points at its Decl,
 * every expression carries its Type, and module calls point at
 * the interface member they invoke.
 */

Decl	*impdecl;			/* this module */
Decl	**fns;				/* functions to compile */
int	nfns;

/* the checked functions, for xref.c */
Decl**
emberfns(void)
{
	return fns;
}

int
emberfnc(void)
{
	return nfns;
}

/*
 * every use of a constant name, kept as confold() replaces the name
 * with its value: the checked tree no longer has the name in it, and
 * xref.c wants to report the use like any other
 */
static Cuse *cuses;
static int ncuses, acuses;

static void
addcuse(Node *n, Decl *d)
{
	if(n->sym == nil || d->src.start.line <= 0)
		return;
	if(ncuses == acuses){
		acuses = acuses != 0 ? acuses * 2 : 256;
		cuses = reallocmem(cuses, acuses * sizeof(Cuse));
		if(cuses == nil)
			fatal("out of memory");
	}
	cuses[ncuses].src = n->src;
	cuses[ncuses].sym = n->sym;
	cuses[ncuses].decl = d;
	ncuses++;
}

Cuse*
emberconsts(void)
{
	return cuses;
}

int
emberconstc(void)
{
	return ncuses;
}
Decl	*entrydecl;			/* the entry function (init) */
Dlist	*imports;			/* imported module variables */
Decl	*moduledecls;			/* module-scope var/const decls */
Sym	*modname;

static	int	lenfns;

static	Decl	*scopes[MaxScope];
static	Decl	*scopeends[MaxScope];
static	int	scope;

static	Decl	*curfn;
static	Type	*curret;
static	Decl	*curclosure;		/* non-nil while fnchk()ing an Ofunclit's own body -- see synthfunclit() */
static	int	nclosures;		/* per-file counter for $closureN synthesized names */

enum { MaxTinstDepth = 16 };
static	Decl	*tinstack[MaxTinstDepth];	/* generic templates currently being instantiated */
static	int	tinstdepth;

static	void	fnchk(Decl*);
static	void	stchk(Node*);
static	void	matchcheck(Node*);
static	void	altcheck(Node*);
static	Type	*echk(Node*);
static	Type	*stype(Node*);
static	Type	*compositefields(Node*);
static	Type	*tinstantiate(Node*);
static	Decl	*synthfvwrap(Src*, Decl*);
static	void	boxvar(Decl*, Decl*);
static	int	lowerguards(Node*);
static	int	isifacetype(Type*);
static	int	implements(Type*, Type*, Node*);
static	Node	*typeval(Src*, Type*);
static	Type	*methvalue(Node*, Decl*);
static	int	incallee;	/* echk() is checking the callee of a call: a method there stays a method */
static	void	subst(Node*, Sym*, Node*);
static	Node	*zeroval(Src*, Type*);
static	void	ifaceconv(Node*, Type*);
static	void	condchk(Node*);
static	void	packvarargs(Node*, Decl*);
static	int	nargsfixed(Node*);
static	int	ismaptype(Type*);
static	Node*	builtinref(Src*, char*);
static	Node*	mkmethcall(Src*, Node*, char*, Node*);
static	Node*	mapindexcall(Node*, char*);
static	int	ismapindex(Node*);
static	int	isidxcall(Node*);
static	void	unboxuse(Node*, Decl*);
static	void	boxpass(Decl*);
static	Node*	mkdeclname(Src*, Decl*);
static	Decl	*synthimportwrap(Src*, Decl*, Decl*);
static	Decl	*synthfunclit(Node*);
static	Decl	*tinstantiatefncore(Src*, Decl*, Type**, int, Decl*);
static	Decl	*tinstantiatefn(Node*);
static	Decl	*inferfn(Node*);
static	Decl	*inferfn1(Node*);
static	Decl	*modtemplate(Node*);
static	int	iscond(Type*);
static	int	rangefor(Node*);
static	void	declconst(char*, long, Type*);
static	Decl	*modmember(Type*, Sym*);
static	int	ismodvar(Decl*);
static	Decl	*modalias(Decl*);
static	Decl	*tmplmodule(Decl*);
static	void	pushmodscope(Decl*);
static	void	popmodscope(Decl*);
static	void	unifytparam(Node*, Type*, Decl*, Type**);
static	Decl	*tinstantiatemeth(Decl*, Type*);
static	Decl	*inlmeth(Decl*, Type*);
static	Node	*structeq(Node*, Node*, Type*, Src*);
static	Case	*matchlabels(Node*, Type*, int);
static	int	casecmp(Type*, Node*, Node*);
static	void	casesort(Type*, Label*, Label*, int, int);

static void
nerror(Node *n, char *fmt, ...)
{
	char buf[512];
	va_list arg;

	va_start(arg, fmt);
	vseprint(buf, buf+sizeof(buf), fmt, arg);
	va_end(arg);
	error(n->src.start, "%s", buf);
}

/*
 * the two types print the same but sign differently: a generic
 * instantiated by a type the interface declares (a pick holding a
 * map of itself) builds a second copy of the type graph, and the
 * recursion ids in a link signature depend on how the graph is
 * shared.  say so, rather than printing one type twice
 */
static char sigsame[] = ": the same shape, but a generic instantiated by a type this interface declares signs differently on the two sides -- keep such a type out of the interface (parallel arrays rather than a map of itself)";

static int
samesig(Type *a, Type *b)
{
	char bufa[1024], bufb[1024];

	seprint(bufa, bufa+sizeof(bufa), "%T", a);
	seprint(bufb, bufb+sizeof(bufb), "%T", b);
	return strcmp(bufa, bufb) == 0;
}

/*
 * scopes
 */
static void
pushscope(void)
{
	if(scope >= MaxScope-1)
		fatal("scopes too deep");
	scope++;
	scopes[scope] = nil;
	scopeends[scope] = nil;
}

static Decl*
popscope(void)
{
	Decl *d;

	for(d = scopes[scope]; d != nil; d = d->next){
		if(d->sym != nil && d->sym->decl == d)
			d->sym->decl = d->old;
	}
	return scopes[scope--];
}

/*
 * install a chain of decls (limbo installids).  next pointers
 * are preserved so argument/field lists stay intact; the chain
 * is appended to the current scope.
 */
static void
installids(Decl *ids)
{
	Decl *d, *last;
	Sym *s;

	last = nil;
	for(d = ids; d != nil; d = d->next){
		d->scope = scope;
		s = d->sym;
		if(s != nil){
			d->old = s->decl;
			s->decl = d;
		}
		last = d;
	}
	if(ids != nil){
		if(scopes[scope] == nil)
			scopes[scope] = ids;
		else
			scopeends[scope]->next = ids;
		scopeends[scope] = last;
	}
}

static void
install(Decl *d)
{
	d->next = nil;
	installids(d);
}

/*
 * "map[string]ref V", "ref Result[T]", "Vec[int]" in an interface
 * file: the generic machinery lives here, so iface.c hands the type
 * expression over.  the interface's own types are installed in a
 * scope of their own first, since a type argument may name one
 */
Type*
ifacetinst(Node *n, Decl *mod)
{
	Type *t;
	Decl *id;

	pushscope();
	if(mod != nil && mod->ty != nil)
		for(id = mod->ty->ids; id != nil; id = id->next)
			if(id->store == Dtype){
				Decl *d;

				d = mkdecl(&id->src, Dtype, id->ty);
				d->sym = id->sym;
				install(d);
			}
	t = stype(n);
	popscope();
	return t;
}

static int inref;	/* stype() is resolving the operand of a ref */
static int rawfn;	/* the next Otfunc stype() sees is a declaration's own signature, not a value type */

static void	picktags(Node*, Type*, Decl*);

static Decl*
lookup(Sym *s)
{
	return s->decl;
}

/*
 * builtin types are declared in the outermost scope
 */
static void
declbuiltin(char *name, Type *t)
{
	Decl *d;

	d = mkdecl(&nosrc, Dtype, t);
	d->sym = enter(name, 0);
	install(d);
	if(t->decl == nil)
		t->decl = d;
}

/* a builtin constant: true, false */
static void
declconst(char *name, long v, Type *t)
{
	Decl *d;

	d = mkdecl(&nosrc, Dconst, t);
	d->sym = enter(name, 0);
	d->init = mkconst(&nosrc, v);
	d->init->ty = t;
	install(d);
}

/*
 * "Name[arg, arg, ...]" (Otinst): resolve one instantiation of a
 * generic struct template (see the Type.tparams/tbody comment,
 * ember.h), monomorphizing it into its own concrete Type the first
 * time this exact argument list is used, and returning the cached
 * one after that -- so two composite literals both writing
 * "Pair[int, string]" get the *same* Type, not two that merely
 * compare equal (tequal isn't even taught about this; identity is
 * what mktdesc/genaddr/etc. all key off of already).
 */
/*
 * the same type argument?  identity for named and basic types (each
 * a single object), structure for the composite types a mention
 * builds afresh -- "ref Option[int]" written twice is two Tref
 * objects, and comparing by identity gave every mention of
 * Result[ref Option[int]] its own, incompatible instance.
 */
static int
sametype(Type *a, Type *b)
{
	Decl *da, *db;

	if(a == b)
		return 1;
	if(a == nil || b == nil || a->kind != b->kind)
		return 0;
	switch(a->kind){
	case Tref:
	case Tarray:
	case Tlist:
	case Tchan:
		return sametype(a->tof, b->tof);
	case Ttuple:
	case Tfn:
		if(!sametype(a->tof, b->tof) || a->varargs != b->varargs)
			return 0;
		for(da = a->ids, db = b->ids; da != nil && db != nil; da = da->next, db = db->next)
			if(!sametype(da->ty, db->ty))
				return 0;
		return da == nil && db == nil;
	}
	return 0;
}

/* the name of an instantiation: Node[int], Pair[int, string] */
static Sym*
instsym(Decl *td, Type **argv, int nargs)
{
	char buf[256], *bp, *be;
	int i;

	bp = buf;
	be = buf + sizeof buf;
	bp = seprint(bp, be, "%s[", td->sym->name);
	for(i = 0; i < nargs; i++)
		bp = seprint(bp, be, "%s%T", i ? ", " : "", argv[i]);
	seprint(bp, be, "]");
	return enter(buf, 0);
}

static Type*
tinstantiate(Node *n)
{
	Decl *td, *pd, *id;
	Type *tt, *inst, *body, **argv;
	Ginst *ti;
	Node *p, *a, *pn;
	int i, nargs, nparams, match;

	td = nil;
	if(n->left->op == Odot && n->left->left->op == Oname){
		/* alias.T[args]: a generic type from the interface, instantiated here */
		Decl *alias;

		alias = lookup(n->left->left->sym);
		if(alias != nil && alias->ty != nil && alias->ty->kind == Tmodule && ismodvar(alias))
			td = modmember(alias->ty, n->left->sym);
		if(td == nil || td->store != Dtype || td->ty == nil || td->ty->tparams == nil){
			nerror(n, "%s.%s is not a generic type", n->left->left->sym->name, n->left->sym->name);
			return terror;
		}
		/* the names stay in the tree (a composite's type): give them their decls */
		n->left->left->decl = alias;
		n->left->left->ty = alias->ty;
		n->left->decl = td;
		if(n->left->right != nil && n->left->right->op == Oname)
			n->left->right->decl = td;
	}else if(n->left->op != Oname){
		nerror(n, "bad generic type reference");
		return terror;
	}
	if(td == nil)
		td = n->left->decl;
	if(td == nil)
		td = lookup(n->left->sym);
	if(td == nil || td->store != Dtype){
		nerror(n, "%s is not a type", n->left->sym->name);
		return terror;
	}
	n->left->decl = td;
	tt = td->ty;
	if(tt == nil || tt->tparams == nil){
		nerror(n, "%T is not a generic type", tt);
		return terror;
	}

	nargs = 0;
	for(p = n->right; p != nil; p = p->right){
		nargs++;
		if(p->op != Oseq)
			break;
	}
	argv = allocmem(nargs * sizeof(Type*));
	i = 0;
	for(p = n->right; p != nil; p = p->right){
		a = p;
		if(p->op == Oseq)
			a = p->left;
		argv[i++] = stype(a);
		if(p->op != Oseq)
			break;
	}

	nparams = 0;
	for(p = tt->tparams; p != nil; p = p->right){
		nparams++;
		if(p->op != Oseq)
			break;
	}
	if(nargs != nparams){
		nerror(n, "%s needs %d type argument%s, got %d", td->sym->name,
			nparams, nparams == 1 ? "" : "s", nargs);
		return terror;
	}

	for(ti = tt->tinsts; ti != nil; ti = ti->next){
		match = 1;
		for(i = 0; i < nargs; i++)
			if(!sametype(ti->args[i], argv[i])){
				match = 0;
				break;
			}
		if(match)
			return ti->ty;
	}

	/*
	 * a struct instance exists before its body is walked: a
	 * placeholder Tadt, cached and named now, so a field that names
	 * the type being instantiated ("next ref Node[T]", a generic
	 * list) resolves to the very instance under construction, as a
	 * non-generic recursive struct does through its Dtype.  the
	 * walked body is copied into the placeholder afterwards.
	 */
	inst = nil;
	id = nil;
	if(tt->tbody != nil && (tt->tbody->op == Otstruct || tt->tbody->op == Otpick)){
		inst = mktype(&n->src, Tadt, nil, nil);
		ti = allocmem(sizeof *ti);
		ti->nargs = nargs;
		ti->args = argv;
		ti->ty = inst;
		ti->next = tt->tinsts;
		tt->tinsts = ti;
		id = mkdecl(&n->src, Dtype, inst);
		id->sym = instsym(td, argv, nargs);
		inst->decl = id;
	}else
	for(i = 0; i < tinstdepth; i++)
		if(tinstack[i] == td){
			nerror(n, "%s: recursive generic instantiation not yet supported", td->sym->name);
			return terror;
		}
	if(tinstdepth >= MaxTinstDepth){
		nerror(n, "generic types nested too deeply");
		return terror;
	}
	tinstack[tinstdepth++] = td;

	/*
	 * bind each type-parameter name to its concrete argument type in
	 * a fresh scope, then re-stype() the template's raw, unresolved
	 * body: Otstruct's field loop (stype's own case) calls
	 * stype(f->right) per field, and a field type written as the
	 * bare name "A" resolves through ordinary scope lookup (stype's
	 * Oname case) to whatever's bound here -- no substitution walker
	 * needed, the existing type checker just runs again with
	 * different names in scope.
	 */
	pushscope();
	i = 0;
	for(p = tt->tparams; p != nil; p = p->right){
		pn = p;
		if(p->op == Oseq)
			pn = p->left;
		pd = mkdecl(&pn->src, Dtype, argv[i]);
		pd->sym = pn->sym;
		install(pd);
		i++;
		if(p->op != Oseq)
			break;
	}
	{
		int frommod;

		/* a template from an interface: its module's names for the body */
		frommod = tmplmodule(td) != nil;
		if(frommod)
			pushmodscope(tmplmodule(td));
		body = stype(tt->tbody);
		if(inst != nil && body != terror){
			*inst = *body;
			inst->decl = id;
			/* a generic pick's tags, with the type parameters in scope */
			if(tt->tbody->op == Otpick)
				picktags(tt->tbody, inst, id);
		}
		if(frommod)
			popmodscope(tmplmodule(td));
	}
	if(inst != nil && body == terror){
		popscope();
		tinstdepth--;
		return terror;
	}
	popscope();
	tinstdepth--;
	if(inst == nil){
		inst = body;
		id = mkdecl(&n->src, Dtype, inst);
		id->sym = instsym(td, argv, nargs);
		inst->decl = id;
	}
	sizetype(inst);
	teqclass(inst);

	if(ti == nil){
		ti = allocmem(sizeof *ti);
		ti->nargs = nargs;
		ti->args = argv;
		ti->ty = inst;
		ti->next = tt->tinsts;
		tt->tinsts = ti;
	}

	/*
	 * reverse link, for a generic-receiver method lookup on this
	 * specific instantiation (echk's Odot case, below) to find its
	 * way back to the template's methtmpl and the arguments to
	 * instantiate one with.
	 */
	inst->gtemplate = tt;
	inst->ginst = ti;

	return inst;
}

/*
 * shared engine behind both ways of resolving one instantiation of a
 * generic function template (see fndecl()'s comment, and the
 * Decl.tparams/finsts comment in ember.h) once its type arguments are
 * already known -- td came from either an explicit "name[args](...)"
 * (tinstantiatefn(), below) or inference from a plain call's argument
 * types (inferfn(), below).  same "bind the parameter names in a
 * scope, re-run the existing checker" approach tinstantiate() (above)
 * uses for generic struct types -- except a function's *body* has to
 * be checked too, and check()'s ordinary two-pass structure (fndecl()
 * for every signature, then fnchk() for every body, much later) has
 * nowhere to keep the type-parameter scope alive that long.  so this
 * does the whole thing right here, synchronously, while the scope is
 * still pushed: build the instantiated signature (fndecl()'s own
 * non-generic logic, just inlined since there's no receiver to worry
 * about -- a generic method is a separate, unimplemented case),
 * fnchk() the body immediately, then mark the result "checked" so
 * check()'s later pass (which will still reach it, since it walks
 * fns[] by index against a length that keeps growing) skips it
 * rather than re-checking it with the bindings gone.
 *
 * curfn/curret are check.c's own reentrancy hazard here: fnchk()
 * sets them unconditionally and clears curfn on return, without
 * saving/restoring anything, because until now nothing ever called
 * it from inside another function's own fnchk() -- exactly what
 * happens here, called via echk() while the *caller's* body (whoever
 * writes "swap[int, string](...)") is itself still being checked.
 * saved and restored explicitly around the nested call.
 */
static Decl*
tinstantiatefncore(Src *src, Decl *td, Type **argv, int nargs, Decl *recvarg)
{
	Decl *pd, *savedcurfn, *savedclosure;
	Type *ft, *savedcurret;
	Ginst *fi;
	Node *p, *pn;
	int i, match;

	for(fi = td->finsts; fi != nil; fi = fi->next){
		match = 1;
		for(i = 0; i < nargs; i++)
			if(!sametype(fi->args[i], argv[i])){
				match = 0;
				break;
			}
		if(match)
			return fi->decl;
	}

	if(tinstdepth >= MaxTinstDepth){
		error(src->start, "generic functions nested too deeply");
		return nil;
	}
	tinstack[tinstdepth++] = td;

	pushscope();
	i = 0;
	for(p = td->tparams; p != nil; p = p->right){
		pn = p;
		if(p->op == Oseq)
			pn = p->left;
		pd = mkdecl(&pn->src, Dtype, argv[i]);
		pd->sym = pn->sym;
		install(pd);
		i++;
		if(p->op != Oseq)
			break;
	}

	{
		Decl *fnd;
		Decl *dd;
		Node *tn;
		char buf[256], *bp, *be;

		/*
		 * a fresh, independent copy of the whole template, not
		 * td->init itself: unlike a generic struct's field-type
		 * names (only ever consulted to build a Type, then never
		 * read again), a function body is walked directly by
		 * codegen (fncom(), com.c reads decl->init->aux) using the
		 * exact same nodes echk() just mutated in place (Oname.decl/
		 * ty, via lookup()) -- so two instantiations sharing the
		 * template's own nodes would corrupt each other: whichever
		 * got fnchk()'d last silently wins for *both*, since fncom()
		 * for either one reads the same, already-overwritten tree.
		 * confirmed empirically, not just reasoned about: identity
		 * [int] and identity[string] both compiled to a "movp"
		 * (pointer) return before this fix, identity[int]'s wrongly
		 * so -- both had ended up sharing whichever body the second
		 * instantiation's typecheck left behind.
		 */
		tn = dupntree(td->init);
		/* a template from an interface: its module's names for the signature */
		if(tmplmodule(td) != nil)
			pushmodscope(tmplmodule(td));
		rawfn = 1;
		ft = stype(tn->right);
		rawfn = 0;
		if(tmplmodule(td) != nil)
			popmodscope(tmplmodule(td));
		if(recvarg != nil){
			/*
			 * a generic method's receiver, prepended to the checked
			 * parameter list exactly the way an ordinary method's
			 * is in fndecl() -- before sizetype()/fnchk() below, so
			 * the body sees it as an ordinary bound name in scope,
			 * same as any other method's receiver.
			 */
			recvarg->next = ft->ids;
			ft->ids = recvarg;
		}
		ft->ok |= OKverify;
		sizetype(ft);
		for(dd = ft->ids; dd != nil; dd = dd->next)
			sizetype(dd->ty);
		sizetype(ft->tof);

		fnd = mkdecl(src, Dfn, ft);
		bp = buf;
		be = buf + sizeof buf;
		bp = seprint(bp, be, "%s[", td->sym->name);
		for(i = 0; i < nargs; i++)
			bp = seprint(bp, be, "%s%T", i ? ", " : "", argv[i]);
		seprint(bp, be, "]");
		fnd->sym = enter(buf, 0);
		fnd->init = tn;
		fnd->offset = idoffsets(ft->ids, MaxTemp, IBY2WD);
		fnd->dot = impdecl;
		/*
		 * not install()ed under its own name (there isn't one to
		 * install under besides the template's, already taken) --
		 * only reachable through this instantiation path, same as
		 * a bound method.
		 */

		if(nfns >= lenfns){
			lenfns = nfns + 32;
			fns = reallocmem(fns, lenfns * sizeof *fns);
		}
		fns[nfns++] = fnd;

		/*
		 * cached before its body is checked: a recursive call in
		 * the body (a generic list's length()) instantiates the
		 * same function with the same arguments and must find this
		 * one, whose type is already complete.
		 */
		fi = allocmem(sizeof *fi);
		fi->nargs = nargs;
		fi->args = argv;
		fi->decl = fnd;
		fi->next = td->finsts;
		td->finsts = fi;

		savedcurfn = curfn;
		savedcurret = curret;
		savedclosure = curclosure;
		curclosure = nil;	/* the template's body is its own, not this closure's: its locals are not captures */
		if(tmplmodule(td) != nil)
			pushmodscope(tmplmodule(td));
		fnchk(fnd);
		if(tmplmodule(td) != nil)
			popmodscope(tmplmodule(td));
		curclosure = savedclosure;
		curfn = savedcurfn;
		curret = savedcurret;
		fnd->checked = 1;

		popscope();
		tinstdepth--;
		return fnd;
	}
}

/*
 * given a function value's own *public* Tfn (no env -- a real Dfn's
 * own signature, or a parameter/local's declared "func(...) ..."),
 * build the internal shape every function value actually carries at
 * runtime: an "env any" parameter prepended to a dupdecl()'d copy of
 * the original parameter list, offset from MaxTemp the same way a
 * real function's own parameters are (fndecl() does the identical
 * sizetype+idoffsets sequence).  a closure and a plain, non-capturing
 * function value share this exact shape -- only whether the runtime
 * env field ends up nil differs (com.c's ecom() Oname/Dfn case, and
 * later, an actual closure literal) -- so com.c's calling code
 * (fpcall()) never needs to know which kind of value it's calling
 * through.
 */

/*
 * synthesize (once, cached as fn->wrapdecl) the "function value
 * wrapper" every value of fn -- taken as a bare name, per echk's
 * Oname case below -- is actually called through: a fresh top-level
 * Dfn with envfn()'s env-prepended signature, whose body just calls
 * fn directly (by name -- an ordinary direct call, unaffected by any
 * of this: Ocall's own callee-shape check devirtualizes it, same as
 * any other literal-name call) with its own parameters and returns
 * whatever fn returns -- or, when fn is void, just calls it and
 * returns nothing itself (check.c's own Oret case rejects a non-nil
 * return expression inside a void function, same rule for this
 * synthesized body as for real code, so "return fn(...)" only works
 * when fn actually returns something).  shares fn->valty's same
 * envfn() Tfn object
 * (built once, right here) so the wrapper's real signature and every
 * call site going through fpcall() are reading the identical,
 * identically-offset Tfn -- not two independently-derived shapes that
 * could silently drift apart.
 *
 * added to fns[] (hence checked, exported, and given a .iface entry)
 * the same way a generic instantiation is: synchronously, from inside
 * echk(), while check()'s pass-2 loop can still reach it -- see
 * ed352cc8 for why the module-interface build had to move after that
 * loop for this to work at all (a generic instantiation never needed
 * an .iface entry -- it's only ever called directly, by PC -- so this
 * ordering requirement was invisible until a wrapper, reached
 * indirectly via Rnoff/.iface->offset, needed one).
 */
static Decl*
synthfvwrap(Src *src, Decl *fn)
{
	Decl *wd, *arg;
	Node *call, *args, *body, *stmt;
	Type *wt;
	char buf[StrSize];

	if(fn->wrapdecl != nil)
		return fn->wrapdecl;

	wt = envfn(src, fn->ty);
	fn->valty = mktype(src, Tref, wt, nil);
	/*
	 * every OTHER Tref built anywhere in this compiler goes through
	 * sizetype() before anything structural reads it -- daschk()
	 * (":=") always sizetype()s its RHS's type first, for exactly
	 * this reason.  this one didn't, and it's not just tidiness:
	 * idoffsets() (types.c) reads a type's .size/.align to compute
	 * *the next* temp's offset; left unsized (both 0, sizetype()'s
	 * own OKsized guard never having run), a plain function value
	 * passed as a call argument got a real, distinct frame offset of
	 * its own from com.c's talloc() -- but idoffsets() then failed to
	 * *advance past* it (0-sized), so whatever temp was allocated
	 * right after silently landed on the exact same offset instead of
	 * the next one.  invisible for a call not itself nested inside
	 * another call's own argument list (nothing else needed an
	 * offset before this function's frame was done with it) -- found
	 * nested ("outer(inner(f, x))"): inner's own call-frame temp
	 * (IFRAME/IMFRAME, still needed to actually execute the call)
	 * aliased the function value's tfnptr temp, so building the
	 * tfnptr overwrote the frame pointer -- INEWZ's own "destroy
	 * whatever was here before" (see the INEWZ comment in com.c's
	 * ecom, Oname/Dfn case) then destroy()d that raw frame pointer as
	 * though it were a stale heap value, garbage neither D2H nor D2B
	 * survives.  sizetype() on a Tref is IBY2WD/IBY2WD unconditionally
	 * (types.c) regardless of what it points to, so this is a fixed,
	 * cheap call, not something that needs to happen lazily.
	 */
	sizetype(fn->valty);

	wd = mkdecl(src, Dfn, wt);
	seprint(buf, buf+sizeof(buf), "%s$fv", fn->sym->name);
	wd->sym = enter(buf, 0);
	wd->dot = impdecl;
	/*
	 * fndecl()'s own equivalent: d->offset = idoffsets(t->ids,
	 * MaxTemp, IBY2WD) -- the frame size through the end of the
	 * parameter region, which fncom() (com.c) later *extends* to
	 * cover locals/temps too (decl->offset = idoffsets(loc,
	 * decl->offset, MaxAlign), starting from whatever this already
	 * is).  envfn() already idoffsets()'d wt->ids itself (each
	 * parameter's own .offset), but its return value -- this total
	 * -- was discarded there; left at mkdecl()'s zero default, the
	 * wrapper's own locals/temps would be laid out starting from 0,
	 * overlapping its parameters instead of following them (real,
	 * not theoretical: "wrote off end of decl map" from gendesc()
	 * building a too-small frame descriptor from the resulting
	 * bogus size).  idoffsets() is idempotent given the same
	 * already-offset input, so recomputing it here just to capture
	 * the total is safe, not a second, diverging computation.
	 */
	wd->offset = idoffsets(wt->ids, MaxTemp, IBY2WD);

	/* fn(arg1, arg2, ...) -- every wrapper param but env, in order */
	call = mkname(src, fn->sym);
	call->decl = fn;	/* by decl, not name: an instance's name is not declared */
	args = nil;
	for(arg = wt->ids->next; arg != nil; arg = arg->next)
		args = mkseq(args, mkname(src, arg->sym));
	if(fn->ty->varargs == 2 && args != nil)	/* pass the packed array through */
		(args->op == Oseq ? args->right : args)->flags |= NVARARG;
	call = mkn(Ocall, call, rotater(args));

	if(fn->ty->tof == tnone){
		/*
		 * "return fn(...)" (the else branch, below) needs fn's own
		 * return value -- fine when there is one, but check.c's
		 * ordinary Oret case rejects *any* non-nil return expression
		 * inside a void function ("function returns no value"),
		 * true for this synthesized wrapper exactly as it's true for
		 * user code: a void fn's own wrapper is void too (envfn()
		 * passes pub->tof through unchanged).  "fn(...); return;" --
		 * two statements, an expression-statement call discarding
		 * the (nonexistent) result, then a bare return -- instead.
		 */
		Node *stmts;

		stmts = mkseq(nil, mkn(Oexpr, call, nil));
		stmts = mkseq(stmts, mkn(Oret, nil, nil));
		body = mkn(Oscope, rotater(stmts), nil);
	}else{
		stmt = mkn(Oret, call, nil);
		body = mkn(Oscope, stmt, nil);
	}

	wd->init = mkn(Ofndecl, nil, nil);
	wd->init->aux = body;

	if(nfns >= lenfns){
		lenfns = nfns + 32;
		fns = reallocmem(fns, lenfns * sizeof *fns);
	}
	fns[nfns++] = wd;

	{
		/*
		 * fnchk() sets curfn/curret unconditionally and clears
		 * curfn (to nil, not the caller's) on return -- safe from
		 * check()'s own top-level pass-2 loop, not from here: this
		 * runs nested, from inside echk(), itself called while the
		 * function actually referencing fn as a value is *its own*
		 * fnchk() is still in progress.  same reentrancy hazard
		 * tinstantiatefncore() already guards against, missed here
		 * at first: without this, whatever check.c code runs right
		 * after synthfvwrap() returns sees curfn==nil and crashes
		 * (daschk() dereferencing it unconditionally, confirmed the
		 * hard way -- a segfault compiling funcvalue.e, not caught
		 * by any earlier, simpler test that never called this from
		 * inside a caller with locals of its own left to check).
		 */
		Decl *savedcurfn;
		Type *savedcurret;

		savedcurfn = curfn;
		savedcurret = curret;
		fnchk(wd);
		curfn = savedcurfn;
		curret = savedcurret;
	}
	wd->checked = 1;

	fn->wrapdecl = wd;
	return wd;
}

/*
 * synthimportwrap(): the Odot analogue of synthfvwrap() (above) -- a
 * value use of an *imported* module's function ("g := sys.print"),
 * not a same-module one. id (the member's own Dfn, e.g. "print") is
 * shared across every file that imports the same module: readiface()
 * (iface.c) caches by path, so two files importing "sys" in one
 * compiler invocation get the exact same Decl* for sys.print -- but a
 * wrapper is a Dfn that must live in *this* module's own fns[] and
 * interface, so it can't be cached directly on id the way
 * synthfvwrap() caches on fn. cached instead through the ordinary
 * install()/lookup() symbol table, under a name unique to this
 * (alias, member) pair -- the "$fv" idea run through the ordinary
 * declaration machinery instead of a dedicated field. alias itself
 * (the import's own Dglobal, "v" in importchk()) is already unique
 * per import statement, so this is safe even if the same underlying
 * module were imported twice under different names in one file.
 *
 * this project compiles one file per invocation everywhere it's
 * actually exercised (every test, tests/run.sh, this whole branch's
 * history) even though main.c's translate() loop *can* run more than
 * once per process -- and fns[]/imports/ifaces are none of them reset
 * between calls, so multi-file-per-invocation compilation is already
 * unsupported for reasons well beyond this function; not solved here.
 *
 * the wrapper's own value-type (Tref{envfn(id->ty)}, the shape a
 * caller reading this function as a value actually needs) is cached
 * on wd->valty -- reusing the same field/meaning synthfvwrap() gives
 * a same-module Dfn, safe here because wd is never itself referenced
 * from real Ember source (install()ed only under this synthesized,
 * unspellable name) so nothing else could ever want wd->valty to mean
 * something else.
 */
static Decl*
synthimportwrap(Src *src, Decl *alias, Decl *id)
{
	Decl *wd, *arg;
	Node *call, *args, *body, *stmt, *dot;
	Type *wt;
	Sym *wsym;
	char buf[StrSize];

	if(id->ty->varargs == 1){
		/* a wrapper has one frame shape; a varargs call has one per site */
		error(src->start, "%s.%s takes a variable number of arguments and cannot be used as a value",
			alias->sym->name, id->sym->name);
		return nil;
	}
	seprint(buf, buf+sizeof(buf), "%s.%s$fv", alias->sym->name, id->sym->name);
	wsym = enter(buf, 0);
	wd = lookup(wsym);
	if(wd != nil)
		return wd;

	wt = envfn(src, id->ty);

	wd = mkdecl(src, Dfn, wt);
	wd->sym = wsym;
	wd->dot = impdecl;
	/* fndecl()'s own equivalent -- see synthfvwrap()'s identical line
	 * for why the frame-size total, not just each param's own offset,
	 * has to be captured here. */
	wd->offset = idoffsets(wt->ids, MaxTemp, IBY2WD);

	/* alias.member(arg1, arg2, ...) -- every wrapper param but env,
	 * matching parse.c's own pprimary()/ptypename() Odot construction
	 * ("mkbin(Odot, base, selector); n->sym = selector->sym") exactly,
	 * so this reaches echk()'s ordinary Odot case looking identical to
	 * a real "alias.member" the user could have written by hand. */
	dot = mkbin(Odot, mkname(src, alias->sym), mkname(src, id->sym));
	dot->sym = id->sym;
	args = nil;
	for(arg = wt->ids->next; arg != nil; arg = arg->next)
		args = mkseq(args, mkname(src, arg->sym));
	if(id->ty->varargs == 2 && args != nil)	/* pass the packed array through */
		(args->op == Oseq ? args->right : args)->flags |= NVARARG;
	call = mkn(Ocall, dot, rotater(args));

	if(id->ty->tof == tnone){
		/* "alias.member(...); return;" -- see synthfvwrap()'s
		 * identical void-return handling for why. */
		Node *stmts;

		stmts = mkseq(nil, mkn(Oexpr, call, nil));
		stmts = mkseq(stmts, mkn(Oret, nil, nil));
		body = mkn(Oscope, rotater(stmts), nil);
	}else{
		stmt = mkn(Oret, call, nil);
		body = mkn(Oscope, stmt, nil);
	}

	wd->init = mkn(Ofndecl, nil, nil);
	wd->init->aux = body;

	if(nfns >= lenfns){
		lenfns = nfns + 32;
		fns = reallocmem(fns, lenfns * sizeof *fns);
	}
	fns[nfns++] = wd;
	install(wd);

	{
		/* same fnchk() reentrancy hazard synthfvwrap() guards
		 * against -- see its identical comment. */
		Decl *savedcurfn;
		Type *savedcurret;

		savedcurfn = curfn;
		savedcurret = curret;
		fnchk(wd);
		curfn = savedcurfn;
		curret = savedcurret;
	}
	wd->checked = 1;

	wd->valty = mktype(src, Tref, wt, nil);
	sizetype(wd->valty);
	/*
	 * wd is already env-shaped (envfn() built wt) and belongs to
	 * *this* module -- it needs no separate wrapper of its own, the
	 * same "ld->wrapdecl = ld" self-reference synthfunclit() gives a
	 * lifted closure literal for the identical reason. this is what
	 * lets the caller (echk's Odot case, below) rewrite a value-use
	 * into a plain Oname naming wd and fall straight into ecom()'s
	 * *existing*, unmodified Oname/Dfn case (com.c) -- which reads
	 * exactly this field (d->wrapdecl) to find what to build the
	 * tfnptr's ISELF/Rnoff reference against.
	 */
	wd->wrapdecl = wd;
	return wd;
}

/*
 * is d one of fn's own parameters (fn->ty->ids) or locals (fn->locals,
 * threaded through ->link -- see daschk()'s "record the local on the
 * current function" comment)?  used by synthfunclit(), below, to tell
 * a closure literal's own bound names from a free reference to
 * something in an enclosing function -- a real capture.  not static:
 * com.c's own capture-construction code (ecom()'s Oname/Dfn case) needs
 * the identical test, to tell a directly-owned capture from one that's
 * only reachable by reading through an intermediate closure's own
 * capture (transitive captures, below) -- see ember.h's declaration.
 */
int
declownedby(Decl *d, Decl *fn)
{
	Decl *p;

	for(p = fn->ty->ids; p != nil; p = p->next)
		if(p == d)
			return 1;
	for(p = fn->locals; p != nil; p = p->link)
		if(p == d)
			return 1;
	return 0;
}

/*
 * record that closure's body captures orig (dedup by decl identity;
 * prepended, like this file's other Dlists -- imports, above -- so
 * whatever order captures ends up in, capty's own fields are built by
 * walking it the same way, so the two always line up) and, when n is
 * non-nil, that node n is one of the references to it -- used by
 * echk's Oname case, consumed by synthfunclit() after fnchk() returns,
 * once every capture is known and capty can be built.  a decl already
 * in the list isn't re-added, but n, when given, is *always* recorded:
 * every occurrence needs its own fixup, not just the first.
 *
 * n is nil for a *transitive* capture (echk's Oname case, below): when
 * a reference inside closure C0 reaches a decl owned two or more
 * enclosing frames out, every closure strictly between C0 and the
 * actual owner also needs the decl threaded through its own captures,
 * purely so com.c can read it one frame at a time when each level's
 * own tfnptr gets built -- but there's no literal reference to that
 * decl inside an intermediate closure's own body syntax to rewrite (it
 * was carved out into C0's own lifted Dfn already), so nothing goes
 * into capuses for it.  capty is still built correctly either way:
 * it's driven purely by captures, never by capuses.
 */
static void
addcapture(Decl *closure, Decl *orig, Node *n)
{
	Dlist *p;

	for(p = closure->captures; p != nil; p = p->next)
		if(p->d == orig)
			goto found;
	p = allocmem(sizeof *p);
	p->d = orig;
	p->next = closure->captures;
	closure->captures = p;
found:
	if(n == nil)
		return;
	if(closure->ncapuses >= closure->lencapuses){
		closure->lencapuses += 32;
		closure->capuses = reallocmem(closure->capuses,
			closure->lencapuses * sizeof *closure->capuses);
	}
	closure->capuses[closure->ncapuses++] = n;
}

/*
 * "func(params) ret { body }" as a value (echk's Ofunclit case, below):
 * lift the literal into a fresh top-level Dfn with envfn()'s
 * env-prepended signature, exactly like synthfvwrap()'s wrapper except
 * the body is the literal's own, not a synthesized call-through -- so
 * ld needs no separate wrapper of its own: it already has the right
 * shape, hence "ld->wrapdecl = ld" below, which lets com.c's ecom()
 * (Oname/Dfn case) build its tfnptr with zero changes, the same code
 * path a plain function value already goes through.
 *
 * a reference inside the body to a Darg/Dlocal not owned by ld itself
 * (declownedby(), above) is a capture; echk's Oname case checks this
 * for every name reference as it resolves each one, gated on curclosure
 * so it can never fire outside of checking a closure's own body
 * (curclosure is nil everywhere else, including the entire rest of
 * this compiler's own test suite) -- see its own comment.  phase 3 of
 * the closure-lowering plan (doc/ember-repository-study.md, by-value
 * captures): a capture reaching directly into ld->enclosing's own frame
 * is recorded (addcapture()); one reaching further out, through one or
 * more intermediate closures, is also recorded (transitive captures,
 * same comment) -- every closure strictly between ld and whichever
 * function actually owns the decl gets it threaded through as a pure
 * pass-through capture of its own.  once fnchk() returns
 * below, every recorded capture becomes a field of a synthesized
 * captures adt (ld->capty) and every recorded use gets rewritten to
 * read/write through it instead of the original decl -- see the
 * Decl.captures/capuses/capty comment, ember.h, for why that rewrite
 * has to happen here and not deferred to codegen.  the literal's env
 * (t2 of the tfnptr) stays nil only when captures is nil -- com.c's
 * ecom() (Oname/Dfn case) allocates and populates the real captures
 * adt instance when it isn't.
 */
static Decl*
synthfunclit(Node *n)
{
	Decl *ld, *savedcurfn, *savedclosure;
	Type *savedcurret;
	Type *pubt, *wt;
	char buf[StrSize];

	rawfn = 1;
	pubt = stype(n->right);
	rawfn = 0;

	wt = envfn(&n->src, pubt);

	ld = mkdecl(&n->src, Dfn, wt);
	seprint(buf, buf+sizeof(buf), "$closure%d", nclosures++);
	ld->sym = enter(buf, 0);
	ld->dot = impdecl;
	ld->offset = idoffsets(wt->ids, MaxTemp, IBY2WD);	/* see synthfvwrap()'s own comment on this line */
	ld->init = mkn(Ofndecl, nil, nil);
	ld->init->aux = n->aux;
	ld->wrapdecl = ld;

	if(nfns >= lenfns){
		lenfns = nfns + 32;
		fns = reallocmem(fns, lenfns * sizeof *fns);
	}
	fns[nfns++] = ld;

	ld->enclosing = curfn;

	/* same reentrancy save/restore as synthfvwrap()'s own fnchk(wd) call */
	savedcurfn = curfn;
	savedcurret = curret;
	savedclosure = curclosure;
	curclosure = ld;
	fnchk(ld);
	curclosure = savedclosure;
	curfn = savedcurfn;
	curret = savedcurret;
	ld->checked = 1;

	if(ld->captures != nil){
		Decl *fids, *flast, *fd, *tdecl;
		Dlist *cl;
		char fbuf[32];
		int i;

		/*
		 * build the captures adt: one Dfield per entry of
		 * ld->captures, walked in the same order addcapture() built
		 * it in, so a capuses fixup below can find a use's field by
		 * *position*, not by matching names or decls a second time.
		 * field names are synthesized (".capN") purely so mktdesc()/
		 * disw.c have *something* to print -- nothing ever looks one
		 * up by name, this adt is never surfaced to the user or the
		 * module's exported interface.
		 */
		fids = flast = nil;
		i = 0;
		for(cl = ld->captures; cl != nil; cl = cl->next){
			fd = mkdecl(&n->src, Dfield, cl->d->boxty);	/* the box, shared with the owner */
			seprint(fbuf, fbuf+sizeof(fbuf), ".cap%d", i++);
			fd->sym = enter(fbuf, 0);
			if(fids == nil)
				fids = fd;
			else
				flast->next = fd;
			flast = fd;
		}
		ld->capty = mktype(&n->src, Tadt, nil, fids);
		ld->capty->ok |= OKverify;
		/*
		 * an ordinary struct gets its .decl from typedec() (a real,
		 * install()ed Dtype); this one is synthesized and never
		 * install()ed, but still needs .decl set the same way --
		 * mktdesc() (types.c) and mktn() (gen.c, INEWZ's own type
		 * operand) both read it, mktdesc() self-healing with a
		 * throwaway one if it's nil, but relying on that here would
		 * be one more never-explicitly-sized-anything trap to walk
		 * into blind, having just spent a turn finding the last one.
		 */
		tdecl = mkdecl(&n->src, Dtype, ld->capty);
		seprint(fbuf, fbuf+sizeof(fbuf), "%s$env", ld->sym->name);
		tdecl->sym = enter(fbuf, 0);
		ld->capty->decl = tdecl;
		sizetype(ld->capty);
		for(fd = ld->capty->ids; fd != nil; fd = fd->next)
			sizetype(fd->ty);

		/*
		 * now fix up every recorded use: rewrite each in place from
		 * a plain Oname (still reading correctly-typed, but wrongly
		 * -addressed off the *original* decl) into the same
		 * Oind(Oadd(base, $offset)) shape echk's own Odot case builds
		 * for an ordinary "p.field" -- must happen before check()
		 * returns (see the Decl.capuses comment, ember.h) since com.c's
		 * sumark() decides addressing straight off decl->store, before
		 * ecom() ever runs.
		 */
		for(i = 0; i < ld->ncapuses; i++){
			Node *un, *envref, *off, *addr;
			Type *envrefty;
			Dlist *cl2;
			int pos;

			un = ld->capuses[i];
			pos = 0;
			for(cl2 = ld->captures; cl2 != nil; cl2 = cl2->next, pos++)
				if(cl2->d == un->decl)
					break;
			fd = ld->capty->ids;
			while(pos-- > 0)
				fd = fd->next;

			envref = mkname(&un->src, ld->ty->ids->sym);
			envref->decl = ld->ty->ids;
			envrefty = mktype(&un->src, Tref, ld->capty, nil);
			sizetype(envrefty);
			envref->ty = envrefty;

			off = mkconst(&un->src, fd->offset);
			off->ty = tint;

			addr = mkn(Oadd, envref, off);
			addr->src = un->src;
			addr->ty = tint;

			/*
			 * the env field holds the variable's box (capture by
			 * reference, boxvar() below): read the box from the
			 * env, then the variable out of the box -- the same
			 * shape twice
			 */
			un->op = Oind;
			un->left = addr;
			un->right = nil;
			un->decl = fd;
			un->ty = fd->ty;
			unboxuse(un, cl2->d);
		}
	}

	return ld;
}

/*
 * capture by reference: a variable any closure captures lives in a
 * box, a one-field adt (.box{v T}) on the heap, from its declaration
 * on; the owner keeps the box in a hidden local (boxdecl) and every
 * closure's env holds the same pointer, so both see each other's
 * writes.  boxvar() makes the types and the local when the capture
 * is first seen (echk's Oname case); the owner's body is rewritten
 * once it is fully checked (boxpass(), from fnchk()): each use of
 * the variable becomes box.v (unboxuse()), and its declaration is
 * followed by the box's allocation (boxinit()).
 */
static void
boxvar(Decl *d, Decl *owner)
{
	Decl *fd, *tdecl, *bd, *e;
	Type *bt;
	char buf[StrSize];
	static int nbox;

	if(d->boxdecl != nil)
		return;
	fd = mkdecl(&d->src, Dfield, d->ty);
	fd->sym = enter("v", 0);
	bt = mktype(&d->src, Tadt, nil, fd);
	bt->ok |= OKverify;
	tdecl = mkdecl(&d->src, Dtype, bt);
	seprint(buf, buf+sizeof(buf), ".box%d$%s", nbox, d->sym->name);
	tdecl->sym = enter(buf, 0);
	bt->decl = tdecl;
	sizetype(bt);
	sizetype(fd->ty);
	/* bound for good under its hidden name, outside every scope */
	tdecl->old = tdecl->sym->decl;
	tdecl->sym->decl = tdecl;
	d->boxtdecl = tdecl;
	d->boxty = mktype(&d->src, Tref, bt, nil);
	sizetype(d->boxty);
	bd = mkdecl(&d->src, Dlocal, d->boxty);
	seprint(buf, buf+sizeof(buf), ".b%d$%s", nbox++, d->sym->name);
	bd->sym = enter(buf, 0);
	bd->link = nil;
	if(owner->locals == nil)
		owner->locals = bd;
	else{
		for(e = owner->locals; e->link != nil; e = e->link)
			;
		e->link = bd;
	}
	d->boxdecl = bd;
}

/*
 * rewrite n, a node already reading the box of d (a ref), in place
 * into the variable inside it: Oind(Oadd(box, $0)), echk's own Odot
 * shape
 */
static void
unboxuse(Node *n, Decl *d)
{
	Node *box, *off, *addr;

	box = mkn(n->op, n->left, n->right);
	*box = *n;
	off = mkconst(&n->src, 0);
	off->ty = tint;
	addr = mkn(Oadd, box, off);
	addr->src = n->src;
	addr->ty = tint;
	n->op = Oind;
	n->left = addr;
	n->right = nil;
	n->aux = nil;
	n->decl = d->boxty->tof->ids;
	n->ty = d->ty;
}

/* boxdecl = ref .box{v: d}, as an unchecked statement */
static Node*
boxinit(Src *src, Decl *d)
{
	Node *elem, *comp;

	elem = mkbin(Oelem, mkname(src, enter("v", 0)), mkdeclname(src, d));
	comp = mkn(Ocomposite, mkname(src, d->boxtdecl->sym), elem);
	comp->src = *src;
	comp = mkunary(Oref, comp);
	comp->src = *src;
	return mkbin(Oas, mkdeclname(src, d->boxdecl), comp);
}

/*
 * a boxed variable of the function being checked: a closure body's
 * references to an enclosing function's boxed variable are captures,
 * rewritten by synthfunclit()'s capuses fixup instead
 */
static int
isboxed(Node *n)
{
	return n != nil && n->op == Oname && n->decl != nil && n->decl->boxdecl != nil
		&& (n->decl->store == Dlocal || n->decl->store == Darg) && declownedby(n->decl, curfn);
}

/* the box allocations for the boxed names in a declaring list */
static Node*
boxinits(Node *names)
{
	Node *p, *id, *inits;

	inits = nil;
	for(p = names; p != nil; p = p->right){
		id = p;
		if(p->op == Oseq)
			id = p->left;
		if(isboxed(id))
			inits = mkseq(inits, boxinit(&id->src, id->decl));
		if(p->op != Oseq)
			break;
	}
	return rotater(inits);
}

static void
boxwalk(Node **np)
{
	Node *n, *inits, *box, *off, *addr;

	n = *np;
	if(n == nil)
		return;
	switch(n->op){
	case Oname:
		if(isboxed(n)){
			box = mkdeclname(&n->src, n->decl->boxdecl);
			box->ty = n->decl->boxty;
			off = mkconst(&n->src, 0);
			off->ty = tint;
			addr = mkn(Oadd, box, off);
			addr->src = n->src;
			addr->ty = tint;
			n->op = Oind;
			n->left = addr;
			n->right = nil;
			n->decl = n->decl->boxty->tof->ids;
		}
		return;
	case Odas:
		boxwalk(&n->right);
		inits = boxinits(n->left);
		if(inits != nil){
			stchk(inits);
			*np = mkseq(n, inits);
		}
		return;
	case Ovardecl:
		boxwalk(&n->aux);
		inits = boxinits(n->left);
		if(inits != nil){
			stchk(inits);
			*np = mkseq(n, inits);
		}
		return;
	case Ocase:
		/* pattern binders declare; their boxes open the arm */
		inits = nil;
		for(box = n->left; box != nil; box = box->right){
			off = box;
			if(box->op == Oseq)
				off = box->left;
			if(off->op == Opat)
				inits = mkseq(inits, boxinits(off->right));
			if(box->op != Oseq)
				break;
		}
		boxwalk(&n->right);
		if(inits != nil){
			inits = rotater(inits);
			stchk(inits);
			n->right = mkseq(inits, n->right);
		}
		return;
	case Otry:
		boxwalk(&n->left);
		boxwalk(&n->right);
		if(isboxed(n->aux)){
			inits = boxinit(&n->aux->src, n->aux->decl);
			stchk(inits);
			n->right = mkseq(inits, n->right);
		}
		return;
	case Ofor:
		/*
		 * a captured loop variable of a three-part for gets a fresh
		 * box each iteration, holding its value at the end of the
		 * body, before the post statement: closures made in one
		 * iteration keep that iteration's value (go 1.22)
		 */
		if(n->aux != nil && n->aux->op == Oforctl && n->aux->left != nil && n->aux->left->op == Odas){
			inits = boxinits(n->aux->left->left);
			if(inits != nil){
				n->aux->right = mkseq(inits, n->aux->right);
				stchk(inits);
			}
		}
		break;
	}
	boxwalk(&n->left);
	boxwalk(&n->right);
	boxwalk(&n->aux);
}

static void
boxpass(Decl *d)
{
	Decl *p;
	Node *inits;
	int any;

	any = 0;
	for(p = d->ty->ids; p != nil; p = p->next)
		if(p->boxdecl != nil)
			any = 1;
	for(p = d->locals; p != nil; p = p->link)
		if(p->boxdecl != nil)
			any = 1;
	if(!any)
		return;
	boxwalk(&d->init->aux);
	inits = nil;
	for(p = d->ty->ids; p != nil; p = p->next)
		if(p->boxdecl != nil)
			inits = mkseq(inits, boxinit(&d->init->src, p));
	if(inits != nil){
		inits = rotater(inits);
		stchk(inits);
		d->init->aux = mkseq(inits, d->init->aux);
	}
}

/*
 * "name[arg, arg, ...](args)" (echk's Ocall case, when the callee is
 * Otinst/Oindex rather than a plain name): the explicit-instantiation
 * front end to tinstantiatefncore() -- resolve td, parse the bracketed
 * type-argument list into argv, hand off.
 */
static Decl*
tinstantiatefn(Node *n)
{
	Decl *td;
	Type **argv;
	Node *p, *a;
	int i, nargs, nparams;

	if(n->left->op != Oname){
		nerror(n, "bad generic function reference");
		return nil;
	}
	td = n->left->decl;	/* a template from an interface, already resolved */
	if(td == nil)
		td = lookup(n->left->sym);
	if(td == nil || td->store != Dfn || td->tparams == nil){
		nerror(n, "%s is not a generic function", n->left->sym->name);
		return nil;
	}
	n->left->decl = td;

	nargs = 0;
	for(p = n->right; p != nil; p = p->right){
		nargs++;
		if(p->op != Oseq)
			break;
	}
	argv = allocmem(nargs * sizeof(Type*));
	i = 0;
	for(p = n->right; p != nil; p = p->right){
		a = p;
		if(p->op == Oseq)
			a = p->left;
		argv[i++] = stype(a);
		if(p->op != Oseq)
			break;
	}

	nparams = 0;
	for(p = td->tparams; p != nil; p = p->right){
		nparams++;
		if(p->op != Oseq)
			break;
	}
	if(nargs != nparams){
		nerror(n, "%s needs %d type argument%s, got %d", td->sym->name,
			nparams, nparams == 1 ? "" : "s", nargs);
		return nil;
	}

	return tinstantiatefncore(&n->src, td, argv, nargs, nil);
}

/*
 * unify one parameter's *raw, unresolved* declared-type syntax node
 * (pt -- straight off the template's own Otfunc parameter list,
 * check.c's own grammar shapes: Oname a bare type name, Otarray/
 * Otchan/Otlist/Otref a container wrapping one element/target type,
 * Otinst a generic type instantiated with its own type arguments)
 * against the *already-checked* Type an actual call argument turned
 * out to have (at), binding any of tparams found as a bare Oname
 * into argv (by position, matching tparams' own order) -- first
 * binding for a given parameter wins, later ones are ignored, same
 * as inferfn()'s previous single-level version.  purely structural:
 * a shape mismatch (pt wants an array, at isn't one) just fails to
 * bind anything from that branch rather than erroring -- inferfn()'s
 * own end-of-loop "argv[i] == nil" check is what actually reports an
 * unresolvable type parameter.
 *
 * Otfunc ("f func(T) U", a function-typed parameter) unifies through
 * both its parameter list and its return type: pt's own Otfunc syntax
 * is the template's *unresolved* signature (an Oseq of Ofield, each
 * possibly binding several names to one type, exactly the shape
 * stype()'s own Otfunc case and inferfn()'s outer loop already walk),
 * matched positionally against at's real Tfn -- unwrapped from the
 * Tref every function-typed *value* is represented behind (com.c's
 * tfnptr; stype()'s own Otfunc case, above, wraps a function-typed
 * parameter's type in exactly this Tref for the identical reason),
 * skipping at's own synthetic leading "env any" parameter
 * (Type.hasenv, envfn()) since pt's syntax never has one -- an
 * ordinary user-written function signature knows nothing about
 * ember's own function-value calling convention.  tests/ok/
 * generics.e's own map2[T, U](xs []T, f func(T) U) is exactly this
 * shape for U: xs alone used to infer T, but U only appeared inside
 * f's own signature, so calling map2 without an explicit [T, U] used
 * to fail with "cannot infer all type arguments" even though every
 * argument's type was fully known at the call site.
 *
 * NOT unified through, still (falls into the default: case, binds
 * nothing): Ottuple, i.e. a type parameter that only appears inside a
 * function-typed parameter's own *multi*-result type ("f func(T)
 * (U, V)") -- a real, deliberately deferred gap one level deeper than
 * map2's own shape needed; a type parameter buried only there still
 * needs an explicit "f[...](...)".
 *
 * Otchan, Otref, and now Otfunc are real, tested branches (tests/
 * type/genericinfer2.e); Otlist is implemented identically but
 * *untested* -- not because list-of-T unification doesn't work, but
 * because no list literal syntax exists yet to construct a "list T"
 * argument with at all ("::"/Ocons is in the AST enum but was never
 * wired into the parser -- and, one layer deeper, "nil" itself has no
 * ecom() codegen case in this compiler at all, a separate, real design
 * fork -- see the ember-language-status memory file, not chased here),
 * the same gap that also leaves Otarray's own test unable to use a
 * literal.
 */
static void
unifytparam(Node *pt, Type *at, Decl *tparams, Type **argv)
{
	Node *tp, *tpn, *ta, *targ, *pp, *pf, *pids;
	Decl *itd, *pd;
	Type *ft;
	int j, i;

	if(pt == nil || at == nil || at == terror)
		return;
	switch(pt->op){
	case Oname:
		j = 0;
		for(tp = tparams; tp != nil; tp = tp->right){
			tpn = tp;
			if(tp->op == Oseq)
				tpn = tp->left;
			if(tpn->sym == pt->sym){
				if(argv[j] == nil){
					/*
					 * a tag value binds the parameter to its
					 * pick, the type it is assignable to:
					 * ok(ref Option[int].Some{...}) makes
					 * Result[ref Option[int]]
					 */
					if(at->kind == Tadtpick && at->tof != nil)
						at = at->tof;
					else if(at->kind == Tref && at->tof != nil && at->tof->kind == Tadtpick && at->tof->tof != nil){
						at = mktype(&pt->src, Tref, at->tof->tof, nil);
						sizetype(at);
					}
					argv[j] = at;
				}
				return;
			}
			j++;
			if(tp->op != Oseq)
				break;
		}
		return;
	case Otarray:
		if(at->kind != Tarray)
			return;
		unifytparam(pt->right, at->tof, tparams, argv);
		return;
	case Otchan:
		if(at->kind != Tchan)
			return;
		unifytparam(pt->right, at->tof, tparams, argv);
		return;
	case Otlist:
		if(at->kind != Tlist)
			return;
		unifytparam(pt->right, at->tof, tparams, argv);
		return;
	case Otref:
		if(at->kind != Tref)
			return;
		unifytparam(pt->right, at->tof, tparams, argv);
		return;
	case Otinst:
		/*
		 * "Box[T]" as a parameter's own declared type, called with
		 * an already-instantiated Box[int] argument: at->gtemplate
		 * is the generic Type "Box[T]" itself instantiated from
		 * (ember.h's own comment on Type.gtemplate/ginst), so
		 * confirm pt->left actually names that same template (not
		 * merely "some generic type or other") before trusting
		 * at->ginst->args to line up positionally with pt->right.
		 */
		if(pt->left == nil || pt->left->op != Oname)
			return;
		if(at->kind == Tadtpick && at->tof != nil)
			at = at->tof;	/* a tag value stands for its pick */
		if(at->kind != Tadt || at->gtemplate == nil || at->ginst == nil)
			return;
		itd = lookup(pt->left->sym);
		if(itd == nil || itd->store != Dtype || itd->ty != at->gtemplate)
			return;
		ta = pt->right;
		i = 0;
		for(; ta != nil && i < at->ginst->nargs; i++){
			targ = ta;
			if(ta->op == Oseq)
				targ = ta->left;
			unifytparam(targ, at->ginst->args[i], tparams, argv);
			if(ta->op != Oseq)
				break;
			ta = ta->right;
		}
		return;
	case Ottuple:
		/*
		 * "(T, U)" as a function-typed parameter's own multi-
		 * result return type -- "f func(int) (T, U)", reached via
		 * Otfunc's own pt->right recursion below when the callee's
		 * signature returns more than one value. at is the real
		 * argument's return Type at that point, always a plain
		 * Ttuple built by stype()'s own Ottuple case (above, one
		 * Dfield per component, in order) -- Ttuple has no
		 * gtemplate/ginst the way Tadt does, so unlike Otinst just
		 * above there's nothing to confirm beyond the kind check:
		 * walk pt->left's own raw type list against at->ids's
		 * Dfield list positionally, the same two-list shape
		 * Otinst's and Otfunc's own loops already use.
		 */
		if(at->kind != Ttuple)
			return;
		pd = at->ids;
		for(ta = pt->left; ta != nil && pd != nil; ta = ta->right){
			targ = ta;
			if(ta->op == Oseq)
				targ = ta->left;
			unifytparam(targ, pd->ty, tparams, argv);
			pd = pd->next;
			if(ta->op != Oseq)
				break;
		}
		return;
	case Otfunc:
		/*
		 * "f func(T) U": at is a function *value*'s type, always
		 * Tref{Tfn}, the same wrap stype()'s own Otfunc case (above)
		 * gives a function-typed parameter -- unwrap it before
		 * comparing against pt's own bare (unwrapped) signature
		 * syntax.
		 */
		if(at->kind != Tref || at->tof == nil || at->tof->kind != Tfn)
			return;
		ft = at->tof;
		pd = ft->ids;
		if(ft->hasenv && pd != nil)
			pd = pd->next;	/* skip the synthetic "env any" (envfn()) */
		for(pp = pt->left; pp != nil && pd != nil; pp = pp->right){
			pf = pp;
			if(pp->op == Oseq)
				pf = pp->left;
			if(pf->left == nil){
				/* an anonymous parameter: one type, one pd */
				unifytparam(pf->right, pd->ty, tparams, argv);
				pd = pd->next;
			}else{
				for(pids = pf->left; pids != nil && pd != nil; pids = pids->right){
					unifytparam(pf->right, pd->ty, tparams, argv);
					pd = pd->next;
					if(pids->op != Oseq)
						break;
				}
			}
			if(pp->op != Oseq)
				break;
		}
		if(pt->right != nil)
			unifytparam(pt->right, ft->tof, tparams, argv);
		return;
	default:
		/* a concrete/unparameterized type: nothing to unify */
		return;
	}
}

/*
 * "name(args)" (echk's Ocall case, plain callee, no explicit "[...]"):
 * infer a generic function's type arguments from the call's own
 * argument types, rather than requiring them spelled out, via
 * unifytparam() (above) -- walked the same way stype()'s own Otfunc
 * case flattens a parameter list (outer loop over Ofields, inner
 * loop over each field's names, so "a, b T" binds both a and b to
 * the same argument-derived T).  a bare parameter ("x T") binds
 * directly; a parameter type that only *contains* a type parameter
 * (a slice of T, a chan of T, ref T, or a generic type instantiated
 * with T -- "xs []T", "b Box[T]") unifies structurally, one level
 * of nesting or more, via unifytparam()'s own recursion; any type
 * parameter that never appears this way just doesn't get inferred --
 * reported cleanly asking for an explicit "f[...](...)" rather than
 * guessed at.  returns nil (silently, no error) when n->left doesn't
 * name a generic function template at all, so callers can fall
 * through to the ordinary, non-generic call path.
 */
/*
 * inference for a template from an interface needs its module's
 * names in scope (a parameter typed with the module's own generic
 * type): around inferfn1(), the real work
 */
static Decl*
inferfn(Node *n)
{
	Decl *td, *r;
	int frommod;

	td = nil;
	if(n->left->op == Oname){
		td = n->left->decl;
		if(td == nil)
			td = lookup(n->left->sym);
	}
	frommod = td != nil && tmplmodule(td) != nil;
	if(frommod)
		pushmodscope(tmplmodule(td));
	r = inferfn1(n);
	if(frommod)
		popmodscope(tmplmodule(td));
	return r;
}

static Decl*
inferfn1(Node *n)
{
	Decl *td;
	Type **argv;
	Node *p, *f, *ids, *id, *a, *arg;
	int i, nparams;

	if(n->left->op != Oname)
		return nil;
	td = n->left->decl;	/* a template from an interface, already resolved */
	if(td == nil)
		td = lookup(n->left->sym);
	if(td == nil || td->store != Dfn || td->tparams == nil)
		return nil;
	n->left->decl = td;

	nparams = 0;
	for(p = td->tparams; p != nil; p = p->right){
		nparams++;
		if(p->op != Oseq)
			break;
	}
	argv = allocmem(nparams * sizeof(Type*));
	for(i = 0; i < nparams; i++)
		argv[i] = nil;

	a = n->right;
	for(p = td->init->right->left; p != nil && a != nil; p = p->right){
		f = p;
		if(p->op == Oseq)
			f = p->left;
		for(ids = f->left; ids != nil && a != nil; ids = ids->right){
			id = ids;
			if(ids->op == Oseq)
				id = ids->left;
			USED(id);
			arg = a;
			if(a->op == Oseq)
				arg = a->left;
			/*
			 * echk() every argument up front, whether or not it
			 * ends up unifying against anything -- unifytparam()
			 * needs the checked Type to look inside (an array's
			 * element type, a generic instantiation's own type
			 * arguments), not just a bare parameter name match.
			 * echk()ing the same node again is not new here: the
			 * shared Ocall path further down (below tinstantiate-
			 * fncore()'s return) always echk()s every argument a
			 * second time anyway, against the now-instantiated
			 * signature's real parameter types.
			 */
			unifytparam(f->right, echk(arg), td->tparams, argv);
			a = a->op == Oseq ? a->right : nil;
			if(ids->op != Oseq)
				break;
		}
		if(p->op != Oseq)
			break;
	}

	for(i = 0; i < nparams; i++)
		if(argv[i] == nil){
			nerror(n, "cannot infer all type arguments for %s; use %s[...] explicitly",
				td->sym->name, td->sym->name);
			return nil;
		}

	return tinstantiatefncore(&n->src, td, argv, nparams, nil);
}

/*
 * echk's Odot case (below), on a field/method lookup miss against an
 * *instantiated* generic type's meths (always nil -- instantiating a
 * struct never copies methods over): mtd is the matching entry found
 * on t->gtemplate->methtmpl instead (a generic-receiver method
 * template, fndecl()'s doing), t the specific instantiation the
 * lookup was against (e.g. Box[int]'s own Type).  the type arguments
 * are already decided -- t->ginst->args, the same ones that produced
 * t itself -- so there's no explicit-vs-inferred choice to make the
 * way a bare call has; this is really just tinstantiatefncore() with
 * one more thing to build first: the receiver argument itself, whose
 * type is t (or ref t) and whose name is whatever the method template
 * declared ("b" in "func (b ref Box[T]) get() T").
 */
static Decl*
tinstantiatemeth(Decl *mtd, Type *t)
{
	Decl *rd;
	Node *recv;
	Type *rt;
	int isref;

	recv = mtd->init->left->left;	/* Ofndecl.left(Omethod).left = the receiver Ofield */
	isref = recv->right->op == Otref;
	rt = isref ? mktype(&mtd->src, Tref, t, nil) : t;
	rd = mkdecl(&recv->left->src, Darg, rt);
	rd->sym = recv->left->sym;
	rd->implicit = 1;

	return tinstantiatefncore(&mtd->src, mtd, t->ginst->args, t->ginst->nargs, rd);
}

/*
 * map a surface type expression to a backend type
 */
/*
 * "a == b" on two struct values: the field-by-field comparison a
 * programmer would write, nested structs and all.  nil when a field
 * has no equality of its own (an array, say)
 */
static Node*
structeq(Node *a, Node *b, Type *t, Src *src)
{
	Node *cmp, *e, *la, *lb;
	Decl *id;

	cmp = nil;
	for(id = t->ids; id != nil; id = id->next){
		la = mkbin(Odot, dupn(a), mkname(src, id->sym));
		la->sym = id->sym;
		la->src = *src;
		lb = mkbin(Odot, dupn(b), mkname(src, id->sym));
		lb->sym = id->sym;
		lb->src = *src;
		switch(id->ty->kind){
		case Tint: case Tbig: case Tbyte: case Treal:
		case Tstring: case Tbool: case Tref: case Tany:
			e = mkbin(Oeq, la, lb);
			e->src = *src;
			break;
		case Tadt:
			if(id->ty->tags != nil)
				return nil;	/* a pick has no field-by-field equality */
			e = structeq(la, lb, id->ty, src);
			if(e == nil)
				return nil;
			break;
		default:
			return nil;
		}
		cmp = cmp == nil ? e : mkbin(Oandand, cmp, e);
		if(cmp != e)
			cmp->src = *src;
	}
	if(cmp == nil){
		cmp = mkconst(src, 1);	/* a struct with no fields: every value is the same */
		cmp->ty = tint;
	}
	return cmp;
}

/*
 * does t, or a type embedded in it, have this field or method?
 * ("type Derived struct { Base; ... }": Base's own names are
 * reachable through the Derived value)
 */
static int
hasmember(Type *t, Sym *s)
{
	Decl *id;
	Type *et;

	if(t == nil)
		return 0;
	if(t->kind == Tref)
		t = t->tof;
	if(t == nil || (t->kind != Tadt && t->kind != Tadtpick))
		return 0;
	for(id = t->ids; id != nil; id = id->next)
		if(id->sym == s)
			return 1;
	for(id = t->meths; id != nil; id = id->link)
		if(id->sym == s)
			return 1;
	for(id = t->ids; id != nil; id = id->next)
		if(id->embedded){
			et = id->ty;
			if(hasmember(et, s))
				return 1;
		}
	return 0;
}

/*
 * a method declared with its body in an interface (builtin.ei's
 * Builder): this module's own copy, as an inline function is
 */
static Decl*
inlmeth(Decl *mtd, Type *t)
{
	Decl *rd;
	Node *recv;
	Type *rt;

	recv = mtd->init->left->left;	/* Ofndecl.left(Omethod).left = the receiver Ofield */
	rt = recv->right->op == Otref ? mktype(&mtd->src, Tref, t, nil) : t;
	sizetype(rt);
	rd = mkdecl(&recv->left->src, Darg, rt);
	rd->sym = recv->left->sym;
	rd->implicit = 1;
	return tinstantiatefncore(&mtd->src, mtd, nil, 0, rd);
}

static Type*
stype(Node *n)
{
	Type *t;
	Decl *d;
	Node *p, *ids;

	if(n == nil)
		return tnone;
	switch(n->op){
	case Otypeval:
		return n->ty;
	case Otarray:
		return mktype(&n->src, Tarray, stype(n->right), nil);
	case Otchan:
		return mktype(&n->src, Tchan, stype(n->right), nil);
	case Otlist:
		return mktype(&n->src, Tlist, stype(n->right), nil);
	case Oref:
		/*
		 * "ref P" parsed as an expression (a type argument in
		 * expression position, Box[ref P]{...}): the type form
		 */
		n->op = Otref;
		n->right = n->left;
		n->left = nil;
		return stype(n);
	case Otref:
		inref++;
		t = stype(n->right);
		inref--;
		if(t->kind != Tadt && t->kind != Tfn && t->kind != Tadtpick
		&& t->kind != Terror && t->kind != Tpoly){
			nerror(n, "ref requires an adt or function type");
			return terror;
		}
		return mktype(&n->src, Tref, t, nil);
	case Otstruct:
		t = mktype(&n->src, Tadt, nil, nil);
		if(n->flags & NIFACE)
			t->isiface = 1;	/* parse.c's pinterface */
		{
			Decl *ids, *last, *d;
			Node *f, *names, *id;

			ids = last = nil;
			for(p = n->left; p != nil; p = p->right){
				f = p;
				if(p->op == Oseq)
					f = p->left;
				for(names = f->left; names != nil; names = names->right){
					id = names;
					if(names->op == Oseq)
						id = names->left;
					d = mkdecl(&id->src, Dfield, stype(f->right));
					d->sym = id->sym;
					d->embedded = f->val == 1;	/* a bare type name: promoted */
					if(ids == nil)
						ids = d;
					else
						last->next = d;
					last = d;
					if(names->op != Oseq)
						break;
				}
				if(p->op != Oseq)
					break;
			}
			t->ids = ids;
		}
		t->ok |= OKverify;
		return t;
	case Otpick:
		/* tags attached by typedec */
		t = mktype(&n->src, Tadt, nil, nil);
		t->ok |= OKverify;
		return t;
	case Ottuple: {
		Decl *idl, *last;
		char buf[32];
		int i;

		idl = last = nil;
		i = 0;
		for(p = n->left; p != nil; p = p->right){
			Node *tn;

			tn = p;
			if(p->op == Oseq)
				tn = p->left;
			d = mkdecl(&tn->src, Dfield, stype(tn));
			seprint(buf, buf+sizeof(buf), "t%d", i++);
			d->sym = enter(buf, 0);
			if(idl == nil)
				idl = d;
			else
				last->next = d;
			last = d;
			if(p->op != Oseq)
				break;
		}
		return mktype(&n->src, Ttuple, nil, idl);
	}
	case Otfunc: {
		Decl *args, *last;
		Type *ft;
		int raw;

		/*
		 * a function type is a closure value everywhere but in a
		 * declaration's own signature (fndecl(), synthfunclit(),
		 * tinstantiatefncore() set rawfn): a variable, field,
		 * element or type argument of type func(int) int holds
		 * ref envfn(...), what a closure literal or a function
		 * value is -- the same wrap parameters and results already
		 * got below, which left "var g func() int" unassignable.
		 */
		raw = rawfn;
		rawfn = 0;
		args = last = nil;
		ft = mktype(&n->src, Tfn, tnone, nil);
		for(p = n->left; p != nil; p = p->right){
			Node *f;

			f = p;
			if(p->op == Oseq)
				f = p->left;
			if(f->op != Ofield)
				fatal("bad param node in stype");
			if(f->flags & NVARARG && f->right == nil && f->left == nil){
				ft->varargs = 1;
				if(p->op != Oseq)
					break;
				continue;
			}
			t = stype(f->right);
			if(f->flags & NVARARG){
				/* "xs ...T": an array of T inside, packed at each call */
				t = mktype(&f->src, Tarray, t, nil);
				sizetype(t);
				ft->varargs = 2;
			}
			if(t->kind == Tfn){
				/*
				 * a function type used as a *value*'s type (a
				 * parameter, e.g. "f func(int) int"), not a
				 * function's own signature -- fndecl() builds
				 * the latter straight from stype()'s Otfunc
				 * case (below) without going through this
				 * per-parameter loop at all, so it's never
				 * wrapped here.  com.c represents a function
				 * value as a tfnptr (types.c), always behind a
				 * pointer -- Tref matches every other
				 * heap-allocated value's own representation
				 * (composite literals, etc.), and lets the
				 * existing Tref-generic machinery (genmove,
				 * assignable, ...) carry it with no changes.
				 *
				 * idoffsets() here matters, not just tidiness:
				 * fndecl() calls idoffsets(t->ids, MaxTemp,
				 * IBY2WD) on a *real* function's own parameter
				 * list, reserving the register-spill temp
				 * region (MaxTemp) before the first argument --
				 * every actual Dfn's frame is laid out that
				 * way.  this Tfn is built by the exact same
				 * stype() Otfunc case but *without* going
				 * through fndecl(), so left alone its ids stay
				 * at mkdecl()'s zero-initialized offsets --
				 * fpcall()/callcom() write a call-through-this-
				 * value's arguments at *those* (wrong, 0-based)
				 * offsets, while the real callee (any actual
				 * "func(int) int"-shaped Dfn) reads them at its
				 * own MaxTemp-based ones: silent frame
				 * corruption, not a compile error, caught only
				 * by actually running a call through a function
				 * value (confirmed: without this, "apply(inc,
				 * 10)" ran and printed a wrong result instead of
				 * faulting outright).
				 *
				 * envfn() (below) does this idoffsets() itself,
				 * plus one more thing a bare Tref{Tfn} can't:
				 * every function value -- capturing (a future
				 * closure literal) or not (echk()'s Oname case,
				 * synthfvwrap()) -- is actually called through a
				 * synthesized wrapper whose real first parameter
				 * is an "env any"; a parameter declared "f
				 * func(int) int" has to carry that same
				 * env-prepended shape too, or it can never
				 * tequal() a real value's own type.
				 */
				t = mktype(&f->src, Tref, envfn(&f->src, t), nil);
			}
			if(f->left == nil){
				/*
				 * an *anonymous* parameter -- psignature(named=0)
				 * (parse.c) is how a function *type* (not a
				 * declaration) parses its parameter list, e.g.
				 * "f func(int) int"'s own "int": one bare type, no
				 * name, since there's nothing to bind it to.  the
				 * loop below only ever adds an arg per *name*, so
				 * without this an anonymous parameter's type was
				 * silently dropped entirely -- "func(int) int"
				 * type-checked to zero parameters, not one, and
				 * calling such a value ("f(x)") failed with "too
				 * many arguments" for any real argument at all.
				 */
				d = mkdecl(&f->src, Darg, t);
				d->sym = nil;
				if(args == nil)
					args = d;
				else
					last->next = d;
				last = d;
			}else{
				for(ids = f->left; ids != nil; ids = ids->right){
					Node *id;

					id = ids;
					if(ids->op == Oseq)
						id = ids->left;
					d = mkdecl(&id->src, Darg, t);
					d->sym = id->sym;
					if(args == nil)
						args = d;
					else
						last->next = d;
					last = d;
					if(ids->op != Oseq)
						break;
				}
			}
			if(p->op != Oseq)
				break;
		}
		ft->ids = args;
		if(n->right != nil){
			ft->tof = stype(n->right);
			if(ft->tof->kind == Tfn){
				/*
				 * a return type that's itself function-shaped
				 * ("func mk(...) func(int) int {...}") is just as
				 * much a function *value*'s type as a parameter
				 * declared "f func(int) int" is (the comment on
				 * this same case's parameter loop, above, explains
				 * why *that* gets wrapped) -- the value returned
				 * has to be a real, callable tfnptr (env-prepended,
				 * envfn()), not the bare signature fndecl() builds
				 * for a function's *own* top-level type.  this
				 * wraps unconditionally, whether the enclosing
				 * Otfunc is itself someone's own top-level signature
				 * (fndecl()) or another value's type (the parameter
				 * loop, or this same case recursively) -- either
				 * way, *this* function's return position holds a
				 * value, not a signature, the moment its own type
				 * is function-shaped.  missing this made returning
				 * *any* function value -- capturing or not -- from
				 * a function declared to return one a compile
				 * error ("cannot return ref fn(...) as fn(...)":
				 * the value side always envfn()-wraps via
				 * synthfvwrap()/synthfunclit(), this return-type
				 * side never did), not something specific to
				 * closures -- found via a closure that outlives its
				 * creating frame, the case that actually needs a
				 * heap-allocated env to be worth anything.
				 */
				ft->tof = mktype(&n->src, Tref, envfn(&n->src, ft->tof), nil);
			}
		}
		if(raw)
			return ft;
		return mktype(&n->src, Tref, envfn(&n->src, ft), nil);
	}
	case Oname:
		d = lookup(n->sym);
		if(d == nil || d->store != Dtype){
			nerror(n, "%s is not a type", n->sym->name);
			return terror;
		}
		if(d->ty != nil && d->ty->tparams != nil){
			nerror(n, "%s needs type arguments, e.g. %s[...]", n->sym->name, n->sym->name);
			return terror;
		}
		/*
		 * a pick has no size of its own -- only each tag does
		 * (sizetype, types.c), as in limbo -- so it exists only
		 * behind a ref: by value it silently got zero-width storage.
		 */
		if(inref == 0 && d->ty != nil && d->ty->kind == Tadt && d->ty->tags != nil){
			nerror(n, "pick %s has no size of its own: use ref %s", n->sym->name, n->sym->name);
			return terror;
		}
		n->decl = d;
		return d->ty;
	case Otinst:
	case Oindex:
		/*
		 * ptypename() (used for a field's declared type, a var's
		 * type, etc.) always produces Otinst for "Name[args]"; the
		 * general expression grammar (ppostfix's '[' case, used
		 * everywhere a composite literal's type-before-'{' comes
		 * from) can't tell an index from a type instantiation at
		 * parse time and always produces Oindex instead, deferring
		 * to the type checker -- so both land here, and both have
		 * the same left/right shape (name, Oseq-of-args).
		 */
		t = tinstantiate(n);
		if((n->flags & NMAPT) && t != nil && t->kind == Tadt)
			t->ismap = 1;	/* map[K]V (parse.c's pmaptype) */
		return t;
	case Odot: {
		/* module member type: mod.Type, or a local pick adt's own tag: Adt.Tag */
		Decl *md, *id, *tg;
		Type *rt;

		if(n->left == nil)
			fatal("stype: Odot %s resolved twice (its operands were consumed)", n->sym ? n->sym->name : "?");
		if(n->left->op == Odot || n->left->op == Oindex || n->left->op == Otinst){
			/* mod.Adt.Tag, or a generic pick's tag Result[int].Ok */
			/* mod.Adt.Tag: resolve mod.Adt first, then its tag */
			Type *at;

			rt = terror;
			at = stype(n->left);
			if(at != terror){
				if(at->kind != Tadt || at->tags == nil)
					nerror(n, "%T is not a pick type", at);
				else{
					for(tg = at->tags; tg != nil; tg = tg->next)
						if(tg->sym == n->sym){
							rt = tg->ty;
							break;
						}
					if(rt == terror)
						nerror(n, "%T has no tag %s", at, n->sym->name);
				}
			}
			n->left = nil;
			n->right = nil;
			return rt;
		}
		if(n->left->op != Oname){
			nerror(n, "bad qualified type");
			return terror;
		}
		rt = terror;
		md = lookup(n->left->sym);
		if(md != nil && md->store == Dtype && md->ty != nil
		&& md->ty->kind == Tadt && md->ty->tags != nil){
			/*
			 * "Result.Ok" -- a tag name dotted onto its own pick
			 * adt, the construction syntax a composite literal's
			 * own type position needs ("Result.Ok{val: 5}";
			 * istypeexpr()'s Odot case already accepts this shape
			 * syntactically, parse.c never distinguished it from a
			 * module-qualified name). matches limbo's own
			 * namedot(t->tags, ...) lookup (limbo/typecheck.c) --
			 * same tag-list shape, same by-symbol match.
			 */
			for(tg = md->ty->tags; tg != nil; tg = tg->next)
				if(tg->sym == n->sym){
					rt = tg->ty;
					break;
				}
			if(rt == terror)
				nerror(n, "%T has no tag %s", md->ty, n->sym->name);
		}else if(md == nil || md->ty == nil || md->ty->kind != Tmodule){
			nerror(n, "%s is not a module", n->left->sym->name);
		}else{
			for(id = md->ty->ids; id != nil; id = id->next)
				if(id->sym == n->sym && id->store == Dtype){
					rt = id->ty;
					break;
				}
			if(rt == terror)
				nerror(n, "%s has no type %s", n->left->sym->name, n->sym->name);
		}
		/*
		 * neither branch ever gives n->left/n->right (the "mod"/
		 * "Result" and "Type"/"Ok" name labels) their own .decl --
		 * both just do a raw lookup() by symbol, never stype()/echk()
		 * on the child nodes themselves -- so left attached, this
		 * Odot node would still be sitting in the tree, unresolved,
		 * for com.c's sumark() to walk into later whenever a
		 * composite literal's own type position reaches it (e.g.
		 * Odas's "sumark(n->right)" over the whole Ocomposite,
		 * including its unread .left) and fatal ("sumark: Oname
		 * without decl") on either child. mirrors the same "type
		 * expr consumed, ecom/sumark should never see it again"
		 * discipline check.c's Oarray/Ochan cases already use
		 * (n->right = nil once stype()'d) -- discovered here, not
		 * there, only because this is the first time a *dotted* type
		 * name ever reached a composite literal's own type position;
		 * a bare name (stype()'s own Oname case) was already safe on
		 * a different path -- it sets n->decl itself before sumark()
		 * ever sees it, matching sumark()'s own Oname/Dtype case
		 * ("a type name used as a value ... never loaded or stored").
		 */
		n->left = nil;
		n->right = nil;
		return rt;
	}
	default:
		nerror(n, "unsupported type expression %O", n->op);
		return terror;
	}
}

/*
 * can an expression of type s be assigned to type t?
 */
static int
assignable(Type *t, Type *s, Node *v)
{
	if(t == nil || s == nil)
		return 0;
	if(s == tany || (v != nil && v->op == Onil)){
		if(tattr[t->kind].isptr){
			if(v != nil)
				v->ty = t;
			return 1;
		}
		return 0;
	}
	if(t == tany)
		return tattr[s->kind].isptr;
	if(t == tint && s == tbool)
		return 1;	/* a bool is an int word: 0 or 1 */
	/*
	 * "ref Result.Ok{...}" (Tref{Tadtpick}) -> "ref Result" (Tref{the
	 * outer, unspecified-tag Tadt-with-tags}): the standard tagged-
	 * union widening, and the realistic construction site for a
	 * value a caller will later match on ("func f() ref Result {
	 * return ref Result.Ok{...} }"). tequal() itself stays strict,
	 * kind-for-kind structural equality (used far more broadly than
	 * just this one relationship, not safe to loosen generally) --
	 * this is deliberately a one-directional special case here, the
	 * same way the tany/nil cases just above already special-case
	 * something tequal() alone wouldn't accept.
	 */
	if(t->kind == Tref && s->kind == Tref
	&& s->tof != nil && s->tof->kind == Tadtpick
	&& t->tof != nil && t->tof->kind == Tadt && t->tof->tags != nil
	&& s->tof->tof == t->tof)
		return 1;
	/*
	 * an interface takes any ref to a struct or pick with its methods
	 * (implements()): the value is converted in place into a call of
	 * the interface's .Name$from converter (ifaceconv())
	 */
	if(v != nil && isifacetype(t) && !tequal(t, s)
	&& ((s->kind == Tref && s->tof != nil && (s->tof->kind == Tadt || s->tof->kind == Tadtpick)) || s->named)){
		if(!implements(s, t, v))
			return 0;
		ifaceconv(v, t);
		return 1;
	}
	/*
	 * tuples are assignable element by element, so "(s, ref
	 * Addr.Dollar{})" may be returned as "(string, ref Addr)": the
	 * widened elements are all pointers, so the layout is the same.
	 */
	if(t->kind == Ttuple && s->kind == Ttuple){
		Decl *a, *b;

		for(a = t->ids, b = s->ids; a != nil && b != nil; a = a->next, b = b->next)
			if(!assignable(a->ty, b->ty, nil))
				return 0;
		return a == nil && b == nil;
	}
	return tequal(t, s);
}

/*
 * fold a constant declaration reference into a literal node
 */
static int
confold(Node *n, Decl *d)
{
	Node *i;

	i = d->init;
	if(i == nil || i->op != Oconst)
		return 0;
	n->op = Oconst;
	n->left = n->right = n->aux = nil;
	n->flags = i->flags;
	n->val = i->val;
	n->rval = i->rval;
	n->sym = i->sym;
	n->ty = i->ty;
	n->decl = nil;
	return 1;
}

/*
 * import: read the interface and declare the module variable
 */
static void
importchk(Node *n)
{
	Decl *m, *v;
	Sym *name;
	Dlist *dl;

	m = readiface(n->right->sym->name, &n->src);
	if(m == nil)
		return;
	name = nil;
	if(n->left != nil)
		name = n->left->sym;
	else
		name = m->sym;	/* module's own name */

	v = mkdecl(&n->src, Dglobal, m->ty);
	v->sym = name;
	v->importid = m;
	install(v);
	n->decl = v;

	dl = allocmem(sizeof *dl);
	dl->d = v;
	dl->next = imports;
	imports = dl;

	/*
	 * also make the module type name visible (Sys, Draw, ...)
	 * for load expressions and type references
	 */
	if(lookup(m->sym) == nil)
		install(m);
}

/*
 * find a member of a module by name
 */
static Decl*
modmember(Type *mt, Sym *s)
{
	Decl *id;

	for(id = mt->ids; id != nil; id = id->next){
		/* an adt's method (iface.c chains it on the adt's meths;
		 * its dot is the adt's Dtype, not the module) is reached
		 * only through a receiver, never as "alias.method" */
		if(id->store == Dfn && id->dot != nil && id->dot->ty != nil && id->dot->ty->kind == Tadt)
			continue;
		if(id->sym == s)
			return id;
	}
	return nil;
}

/*
 * the import alias (a Tmodule-typed Dglobal) through which an
 * imported adt's method is called: meth's dot is the adt's Dtype,
 * whose own dot is the interface module m; nil for a method of this
 * module's own types (dot->dot is impdecl, or nil).
 */
static Decl*
methodmodule(Decl *meth)
{
	Decl *td;
	Dlist *dl;

	td = meth->dot;
	if(td == nil || td->store != Dtype || td->ty == nil
	|| (td->ty->kind != Tadt && !td->ty->named)	/* "type Color int" carries methods too */
	|| td->dot == nil || td->dot == impdecl)
		return nil;
	for(dl = imports; dl != nil; dl = dl->next)
		if(dl->d->importid == td->dot)
			return dl->d;
	return nil;
}

/*
 * a variable holding a module: the import alias itself (a Dglobal),
 * or -- since "m := load Rand path" yields an ordinary value of the
 * module type -- any local or parameter of that type.  the module's
 * TYPE name (Sys, Rand: a Dtype) is what this excludes.
 */
static int
ismodvar(Decl *d)
{
	return d->store == Dglobal || d->store == Dlocal || d->store == Darg;
}

/*
 * is dot a literal "alias.fn" naming a directly-callable imported
 * function -- an Odot whose left names an already-imported module
 * (a Tmodule-typed Dglobal) and whose member resolves to a Dfn?
 * the identical discrimination echk's own Odot case (below) uses to
 * separate a module member from a struct field/bound method, factored
 * out so Ocall's own fast path (below) can check it before echk(Odot)
 * ever runs -- a bound method's own receiver is never itself a
 * Tmodule-typed Dglobal, so this can never match one, by construction
 * rather than by reasoning about what receivers happen to exist.
 */
static Decl*
modcallee(Node *dot)
{
	Decl *alias, *id;

	if(dot->op != Odot || dot->left->op != Oname)
		return nil;
	alias = lookup(dot->left->sym);
	if(alias == nil || alias->ty == nil || alias->ty->kind != Tmodule || !ismodvar(alias))
		return nil;
	id = modmember(alias->ty, dot->sym);
	if(id == nil || id->store != Dfn || id->tparams != nil || id->inl)
		return nil;
	return id;
}

/*
 * alias.f where f is a generic template from the interface (iface.c):
 * instantiated here, in this module, like a local generic
 */
static Decl*
modtemplate(Node *dot)
{
	Decl *alias, *id;

	if(dot->op != Odot || dot->left->op != Oname)
		return nil;
	alias = lookup(dot->left->sym);
	if(alias == nil || alias->ty == nil || alias->ty->kind != Tmodule || !ismodvar(alias))
		return nil;
	id = modmember(alias->ty, dot->sym);
	if(id == nil || id->store != Dfn || (id->tparams == nil && !id->inl))
		return nil;
	return id;
}

/*
 * the interface module a template came from, or nil for a local one:
 * a function template's dot is the module, a generic type's method
 * template's dot is the type template, whose dot is the module
 */
static Decl*
tmplmodule(Decl *td)
{
	Decl *m;

	m = td->dot;
	if(m != nil && m->store == Dtype && m->ty != nil && m->ty->kind != Tmodule)
		m = m->dot;
	if(m == nil || m == impdecl || m->ty == nil || m->ty->kind != Tmodule)
		return nil;
	return m;
}

/* the import alias for a module's own declaration */
static Decl*
modalias(Decl *mod)
{
	Dlist *dl;

	for(dl = imports; dl != nil; dl = dl->next)
		if(dl->d->importid == mod)
			return dl->d;
	return nil;
}

/*
 * while a template from module mod is instantiated here, its body
 * sees mod's types, constants and functions by their own names
 * (calls to the functions are routed through the alias, echk's
 * Ocall case); mod's variables stay out -- they would need the
 * alias too.  bound like fnchk() binds parameters, restored in
 * reverse.
 */
enum { MaxTmplMods = 16 };
static	Decl	*tmplmods[MaxTmplMods];	/* modules whose scope is pushed, with a nesting count: a template instantiating another of its module's */
static	int	tmplcnt[MaxTmplMods];
static	int	ntmplmods;

static void
pushmodscope(Decl *mod)
{
	Decl *id;
	int i;

	for(i = 0; i < ntmplmods; i++)
		if(tmplmods[i] == mod){
			tmplcnt[i]++;
			return;
		}
	if(ntmplmods >= MaxTmplMods)
		fatal("template modules nested too deeply");
	tmplmods[ntmplmods] = mod;
	tmplcnt[ntmplmods] = 1;
	ntmplmods++;
	for(id = mod->ty->ids; id != nil; id = id->next){
		if(id->sym == nil || id->store == Dglobal || id->store == Dimport)
			continue;
		if(id->store == Dfn && id->dot != mod)
			continue;	/* a method */
		id->old = id->sym->decl;
		id->sym->decl = id;
	}
}

static void
popmodscope(Decl *mod)
{
	Decl *id;
	int i;

	for(i = 0; i < ntmplmods && tmplmods[i] != mod; i++)
		;
	if(i == ntmplmods)
		fatal("popmodscope: module not pushed");
	if(--tmplcnt[i] > 0)
		return;
	ntmplmods--;
	tmplmods[i] = tmplmods[ntmplmods];
	tmplcnt[i] = tmplcnt[ntmplmods];
	for(id = mod->ty->ids; id != nil; id = id->next){
		if(id->sym == nil || id->store == Dglobal || id->store == Dimport)
			continue;
		if(id->store == Dfn && id->dot != mod)
			continue;
		if(id->sym->decl == id){
			id->sym->decl = id->old;
			id->old = nil;
		}
	}
}

/*
 * T{ [key:] value, ... }; pcomposite() always wraps each element in
 * an Oelem(key-or-nil, value).  match each element to a field of t
 * (t = the type named by n->left), all-keyed or all-positional
 * (mixing is an error, like Go), and stash the matched Decl on the
 * Oelem node itself (e->decl) for com.c's Oref case to read the
 * field's offset back out at codegen time.
 *
 * e->left is the parsed field-name label (an undecl'd Oname pname()
 * built) -- same trap as Odot's field label: sumark() walks every
 * node's left/right unconditionally, so it must be cleared once
 * consumed, not left for sumark to trip over.
 *
 * shared by echk's Ocomposite and Oref cases: a composite literal is
 * only usable as an expression through "ref T{...}", so the
 * *standalone* Ocomposite case reuses this purely for its
 * diagnostics (an unknown field name is still reported), then still
 * refuses the expression.
 */
static Type*
compositefields(Node *n)
{
	Type *t;
	Decl *fid, *shared;
	int keyed, switched;
	Node *p;

	t = stype(n->left);
	if(t->kind != Tadt && t->kind != Tadtpick){
		nerror(n, "composite literal of non-struct type %T", t);
		n->ty = terror;
		return n->ty;
	}
	if(t->kind == Tadt && t->tags != nil){
		nerror(n, "composite literal of tagged type %T not yet supported -- construct a specific tag instead, e.g. %T.Tag{...}", t, t);
		n->ty = terror;
		return n->ty;
	}
	/*
	 * a Tadtpick type (a specific tag's own type, "Result.Ok" resolved
	 * through stype()'s own Odot case) has its fields split across two
	 * separate chains -- t->ids (this tag's own extra fields) and
	 * t->tof->ids (the outer adt's shared fields, common to every
	 * tag) -- since sizetype() (types.c) lays them out that way: the
	 * shared fields at their own offsets, this tag's own fields
	 * starting right after them, both counted from the same base a
	 * value of this specific tag's type actually gets allocated at.
	 * a plain (untagged) Tadt only ever has the one chain (t->ids,
	 * shared == nil) -- the loop below degrades to exactly the
	 * original single-chain behavior in that case.
	 */
	shared = t->kind == Tadtpick ? t->tof->ids : nil;
	keyed = -1;
	fid = t->ids;
	switched = shared == nil;
	for(p = n->right; p != nil; p = p->right){
		Node *e;
		Type *fty, *vt;
		Decl *fd;

		e = p;
		if(p->op == Oseq)
			e = p->left;

		fd = nil;
		if(e->left != nil){
			if(keyed == 0)
				nerror(e, "cannot mix keyed and positional elements in %T composite literal", t);
			keyed = 1;
			for(fd = t->ids; fd != nil; fd = fd->next)
				if(fd->sym == e->left->sym)
					break;
			if(fd == nil)
				for(fd = shared; fd != nil; fd = fd->next)
					if(fd->sym == e->left->sym)
						break;
			if(fd == nil)
				nerror(e->left, "%T has no field %s", t, e->left->sym->name);
		}else{
			if(keyed == 1)
				nerror(e, "cannot mix keyed and positional elements in %T composite literal", t);
			keyed = 0;
			if(fid == nil && !switched){
				fid = shared;
				switched = 1;
			}
			fd = fid;
			if(fd == nil)
				nerror(e, "too many elements in %T composite literal", t);
			else
				fid = fid->next;
		}

		/*
		 * a tagged (pick) adt field still needs a real recursive
		 * store this compiler doesn't have (its storage isn't just
		 * "fields at fixed offsets" -- it needs its tag word set
		 * too); refuse that cleanly.  a plain struct-typed field is
		 * fine: if the value is itself a composite literal (the
		 * only way to construct a struct *value*, since a bare name
		 * can't denote one -- see echk's Ocomposite case), recurse
		 * into compositefields() the same way this function's own
		 * caller (Oref's echk case) does, so nested fields get the
		 * same field-matching and offset-stashing treatment; com.c's
		 * Oref case (storecomposite()) walks the resulting nested
		 * e->decl chain to do the actual recursive store.
		 *
		 * a tuple-typed field ("struct { r (int, string) }") needs
		 * no such stub -- it turns out to already be structurally
		 * supported, not a real gap, once traced through: tequal()'s
		 * own Ttuple case (types.c) compares two tuple types by
		 * position+type via idequal(..., usenames=0, ...), so the
		 * declared field's type (fd->ty, built by stype()'s Ottuple
		 * case) and a fresh literal's own inferred type (vt, built
		 * by echk()'s pre-existing Otuple case -- "(1, "hello")" is
		 * already real, general parenthesised-tuple-expression
		 * syntax, parse.c's own '(' case) already compare correctly
		 * through the ordinary assignable() call below, field names
		 * ("t0"/"t1" vs "val"/"msg") never entering into it. Storage
		 * likewise needs no new code: storecomposite()'s existing
		 * non-Ocomposite branch already builds an Oind(Oadd(base,
		 * $offset)) destination typed fd->ty and hands it to the
		 * general ecom(), which already has an Otuple case (built for
		 * "return a, b") that stores each component positionally --
		 * it was never wired to anything but Oret before, simply
		 * because nothing else ever produced a live Otuple node to
		 * store, not because it only works there.
		 */
		if(fd != nil && fd->ty->kind == Tadtpick){
			nerror(e, "composite literal field %s: tagged fields not yet supported", fd->sym->name);
			fd = nil;
		}

		if(e->right->op == Ocomposite)
			vt = compositefields(e->right);
		else
			vt = echk(e->right);
		if(fd != nil){
			fty = fd->ty;
			if(!assignable(fty, vt, e->right))
				nerror(e, "cannot use %T as %T for field %s in composite literal", vt, fty, fd->sym->name);
			e->decl = fd;
		}
		e->left = nil;

		if(p->op != Oseq)
			break;
	}
	if(keyed == 0){
		/*
		 * a trailing catch-up switch: if the literal supplied
		 * exactly len(t->ids) positional elements and never
		 * triggered the mid-loop switch above, fid is nil but any
		 * required shared fields (t->tof->ids) were never actually
		 * checked -- without this, a literal that's fully positional
		 * for a tag's own fields but silently omits every shared
		 * field would wrongly pass as complete.
		 */
		if(fid == nil && !switched)
			fid = shared;
		if(fid != nil)
			nerror(n, "too few elements in %T composite literal", t);
	}
	n->ty = t;
	return n->ty;
}

/*
 * expression checking; annotates n->ty and returns it
 */
static Type *echk1(Node*);
static void setconst(Node*, Type*);
static void confoldbin(Node*);
static void confoldcast(Node*);

/*
 * constant folding: a binary operator (echk1's arithmetic case, once
 * both operands are typed alike) or a conversion applied to literals
 * becomes a literal, so "const N = 4 * 2 + 1", "const S = "ab" +
 * "cd"", "const B = big(1) << 33" are constants (check() insists a
 * const's initializer is an Oconst) and array sizes may be
 * expressions.  the folded node keeps the operator's own type; a
 * string result gets a fresh interned Sym.  division by a zero
 * literal is reported here rather than folded.
 */
static void
setconst(Node *n, Type *t)
{
	n->op = Oconst;
	n->left = n->right = n->aux = nil;
	n->decl = nil;
	n->ty = t;
}

/*
 * a tuple literal whose components include nil ("(nil, nil)", "nil,
 * err") has tany components, and a whole-tuple assignable() test
 * against the wanted tuple type is structural and refuses it.  when e
 * is a literal tuple and want a tuple type of the same arity, retype
 * every tany component that the corresponding wanted field accepts,
 * BEFORE the literal's type is sized, so codegen sees exactly the
 * wanted tuple.  used by return, send, assignment and arguments.
 * (assignable() itself retypes the node, so the tany test comes first.)
 */
static void
retypetuple(Node *e, Type *want)
{
	Decl *fd, *td;
	Node *p, *c;

	if(e == nil || e->op != Otuple || e->ty == nil || e->ty->kind != Ttuple
	|| want == nil || want->kind != Ttuple)
		return;
	fd = want->ids;
	td = e->ty->ids;
	for(p = e->left; p != nil && fd != nil && td != nil; p = p->right){
		c = p;
		if(p->op == Oseq)
			c = p->left;
		if(c->ty == tany && assignable(fd->ty, c->ty, c)){
			c->ty = fd->ty;
			td->ty = fd->ty;
		}
		fd = fd->next;
		td = td->next;
		if(p->op != Oseq)
			break;
	}
	e->ty->ok &= ~OKsized;
	e->ty->size = 0;
	sizetype(e->ty);
}

static void
confoldbin(Node *n)
{
	Node *l, *r;
	Long a, b, v;
	Real x, y, z;
	char *buf;
	int op;

	l = n->left;
	r = n->right;
	op = n->op;
	switch(n->ty->kind){
	case Tint:
	case Tbig:
	case Tbyte:
		a = l->val;
		b = r->val;
		switch(op){
		case Oadd:	v = a + b; break;
		case Osub:	v = a - b; break;
		case Omul:	v = a * b; break;
		case Odiv:
		case Omod:
			if(b == 0){
				nerror(n, "division by zero in constant expression");
				return;
			}
			v = op == Odiv ? a / b : a % b;
			break;
		case Oand:	v = a & b; break;
		case Oor:	v = a | b; break;
		case Oxor:	v = a ^ b; break;
		case Olsh:	v = a << b; break;
		case Orsh:	v = a >> b; break;
		default:	return;
		}
		if(n->ty->kind == Tint)
			v = (int)v;
		else if(n->ty->kind == Tbyte)
			v &= 0xff;
		setconst(n, n->ty);
		n->flags = 0;
		n->val = v;
		return;
	case Treal:
		x = l->rval;
		y = r->rval;
		switch(op){
		case Oadd:	z = x + y; break;
		case Osub:	z = x - y; break;
		case Omul:	z = x * y; break;
		case Odiv:	z = x / y; break;
		default:	return;
		}
		setconst(n, treal);
		n->flags = NREAL;
		n->rval = z;
		return;
	case Tstring:
		if(op != Oadd || l->sym == nil || r->sym == nil)
			return;
		buf = allocmem(l->sym->len + r->sym->len + 1);
		memmove(buf, l->sym->name, l->sym->len);
		memmove(buf + l->sym->len, r->sym->name, r->sym->len);
		buf[l->sym->len + r->sym->len] = 0;
		setconst(n, tstring);
		n->flags = NSTR;
		n->sym = enter(buf, 0);
		free(buf);
		return;
	}
}

/*
 * fold a constant expression tree of literals for an interface file
 * (iface.c), where nothing is in scope: names of the interface's own
 * earlier constants have already been replaced by copies of their
 * literals by the caller.  types each literal, folds unary minus and
 * the binary operators (both sides of one kind), and a conversion
 * written as a call to a builtin type name ("big(1)").  returns 1 if
 * n ended up an Oconst.
 */
int
foldconstexpr(Node *n)
{
	Type *t, *tr;

	if(n == nil)
		return 0;
	switch(n->op){
	case Oconst:
		if(n->ty == nil){
			if(n->flags & NSTR)
				n->ty = tstring;
			else if(n->flags & NREAL)
				n->ty = treal;
			else if(n->val > 0x7fffffffLL || n->val < -0x80000000LL)
				n->ty = tbig;
			else
				n->ty = tint;
		}
		return 1;
	case Oneg:
		if(!foldconstexpr(n->left) || (n->left->flags & NSTR))
			return 0;
		n->flags = n->left->flags;
		if(n->flags & NREAL)
			n->rval = -n->left->rval;
		else
			n->val = -n->left->val;
		t = n->left->ty;
		setconst(n, t);
		return 1;
	case Oadd: case Osub: case Omul: case Odiv: case Omod:
	case Oand: case Oor: case Oxor: case Olsh: case Orsh:
		if(!foldconstexpr(n->left) || !foldconstexpr(n->right))
			return 0;
		t = n->left->ty;
		tr = n->right->ty;
		if((n->op == Olsh || n->op == Orsh) && tr->kind == Tint && (t->kind == Tbig || t->kind == Tbyte))
			tr = t;
		if(t != tr)
			return 0;
		n->ty = t;
		confoldbin(n);
		return n->op == Oconst;
	case Ocall:
		/* big(1), real(2), int(3.5): a conversion of a literal */
		if(n->left->op != Oname || n->right == nil || n->right->op == Oseq)
			return 0;
		if(strcmp(n->left->sym->name, "int") == 0)
			t = tint;
		else if(strcmp(n->left->sym->name, "big") == 0)
			t = tbig;
		else if(strcmp(n->left->sym->name, "real") == 0)
			t = treal;
		else if(strcmp(n->left->sym->name, "byte") == 0)
			t = tbyte;
		else if(strcmp(n->left->sym->name, "string") == 0)
			t = tstring;
		else
			return 0;
		if(!foldconstexpr(n->right))
			return 0;
		n->op = Ocast;
		n->left = n->right;
		n->right = nil;
		n->ty = t;
		confoldcast(n);
		return n->op == Oconst;
	}
	return 0;
}

static void
confoldcast(Node *n)
{
	Node *l;
	Type *to, *from;
	char buf[64];

	l = n->left;
	to = n->ty;
	from = l->ty;
	if(from == nil || from->kind == Tarray || to->kind == Tarray)
		return;
	if(from->kind == to->kind){
		/* "const Hearts Suit = \"hearts\"": a named type of the same base, the same constant */
		Long v;
		Real r;
		Sym *sy;
		int fl;

		v = l->val;
		r = l->rval;
		sy = l->sym;
		fl = l->flags;
		setconst(n, to);
		n->val = v;
		n->rval = r;
		n->sym = sy;
		n->flags = fl;
		return;
	}
	if(from->kind == Tstring){
		/* the VM's cvtcw/cvtcl/cvtcf: strtol/strtod semantics, so
		 * int("12abc") is 12 and int("abc") is 0 */
		if(l->sym == nil)
			return;
		switch(to->kind){
		case Tint:
		case Tbig:
		case Tbyte: {
			Long v;

			v = strtoll(l->sym->name, nil, 10);
			setconst(n, to);
			n->flags = 0;
			n->val = to->kind == Tint ? (int)v : to->kind == Tbyte ? (v & 0xff) : v;
			return;
		}
		case Treal: {
			Real r;

			r = strtod(l->sym->name, nil);
			setconst(n, treal);
			n->flags = NREAL;
			n->rval = r;
			return;
		}
		}
		return;
	}
	switch(to->kind){
	case Tint:
	case Tbig:
	case Tbyte:
		if(from->kind == Treal){
			Real r;

			r = l->rval;
			/* round to nearest, as the Dis conversion does */
			setconst(n, to);
			n->flags = 0;
			n->val = (Long)(r < 0 ? r - 0.5 : r + 0.5);
		}else{
			Long v;

			v = l->val;
			setconst(n, to);
			n->flags = 0;
			n->val = v;
		}
		if(to->kind == Tint)
			n->val = (int)n->val;
		else if(to->kind == Tbyte)
			n->val &= 0xff;
		return;
	case Treal:
		if(from->kind == Treal){
			Real r;

			r = l->rval;
			setconst(n, treal);
			n->flags = NREAL;
			n->rval = r;
		}else{
			Long v;

			v = l->val;
			setconst(n, treal);
			n->flags = NREAL;
			n->rval = (Real)v;
		}
		return;
	case Tstring:
		if(from->kind == Treal)
			return;	/* runtime formatting rules; leave it */
		seprint(buf, buf+sizeof(buf), "%lld", (vlong)l->val);
		setconst(n, tstring);
		n->flags = NSTR;
		n->sym = enter(buf, 0);
		return;
	}
}


/*
 * echk() is NOT naturally idempotent: it rewrites nodes in place
 * (Odot -> Oind/Omdot/Oname, Oindex -> Oindx/Oinds, a call to a type
 * name -> Ocast, a bound method call's receiver prepended to its
 * arguments, a load's type name consumed, ...) and several callers
 * check the same node twice -- inferfn() checks every argument to
 * unify type parameters and Ocall's own loop then checks them again;
 * a bound-method receiver was checked through the dot and again as an
 * argument.  each such pair was a bug waiting for the first rewritten
 * shape to reach it ("unsupported expression indx", "get is not
 * declared", "cannot use string as no type").  so check once: a node
 * that has been through echk1() keeps its ty and is never re-entered.
 * dupn() clears the mark on copies.
 */
static Type*
echk(Node *n)
{
	Type *t;

	if(n == nil)
		return tnone;
	if(n->flags & NCHECKED)
		return n->ty;
	t = echk1(n);
	if(n->ty == nil)
		n->ty = t;
	n->flags |= NCHECKED;
	return t;
}

static Type*
echk1(Node *n)
{
	Type *t, *tr;
	Decl *d;
	Node *p;

	if(n == nil)
		return tnone;
	switch(n->op){
	case Oconst:
		if(n->flags & NSTR)
			n->ty = tstring;
		else if(n->flags & NREAL)
			n->ty = treal;
		else if(n->ty == tbig)
			;	/* folded from big operands */
		else if(n->val > 0x7fffffffLL || n->val < -0x80000000LL)
			n->ty = tbig;	/* int is 32 bits: a wider literal is a big, as in limbo */
		else
			n->ty = tint;
		return n->ty;
	case Onil:
		/*
		 * dead as of nildecl (see check(), below): mknil() (ast.c)
		 * now builds an ordinary Oname referencing the predeclared
		 * "nil" global instead of an Onil node, so this case is no
		 * longer reachable from the parser -- kept only as a safe
		 * fallback (matches nildecl's own tany typing exactly) in
		 * case anything ever constructs one directly.
		 */
		n->ty = tany;
		return n->ty;
	case Oname:
		/*
		 * a name already resolved to a function instance (an inline
		 * function from an interface, echk's Odot case) keeps it: the
		 * instance's own name is not declared
		 */
		d = nil;
		if(n->decl != nil && n->decl->store == Dfn && n->decl->tparams == nil && n->decl->init != nil && n->decl->init->op == Ofndecl)
			d = n->decl;
		/* a local the checker itself pointed at (defer, boxing): the parser never sets decl */
		if(n->decl != nil && (n->decl->store == Dlocal || n->decl->store == Darg))
			d = n->decl;
		if(d == nil)
			d = lookup(n->sym);
		if(d == nil){
			nerror(n, "%s is not declared", n->sym->name);
			n->ty = terror;
			return n->ty;
		}
		if(d->store == Dconst){
			addcuse(n, d);
			if(confold(n, d))
				return n->ty;
			nerror(n, "constant %s is not usable here", n->sym->name);
			n->ty = terror;
			return n->ty;
		}
		d->refs++;
		n->decl = d;
		n->ty = d->ty;
		if(curclosure != nil && (d->store == Darg || d->store == Dlocal) && !declownedby(d, curclosure)){
			/*
			 * synthfunclit() (above) is checking an Ofunclit's own
			 * body right now (curclosure == the closure's lifted
			 * Dfn) and d -- a parameter or local -- isn't one of
			 * its own: a reference reaching outward into an
			 * enclosing scope, i.e. an actual capture.  only real
			 * captures trip this: an *ordinary* function body never
			 * has any other function's scope open at the same time,
			 * so lookup() could never hand back a foreign Darg/
			 * Dlocal there -- this can only fire while curclosure is
			 * non-nil, i.e. nowhere else in the compiler or its own
			 * test suite.
			 *
			 * transitive captures (through more than one enclosing
			 * frame): walk curclosure's own ->enclosing chain out
			 * until we reach whichever function/closure genuinely
			 * owns d directly (anc, below) -- declownedby(d,
			 * curclosure->enclosing) was the old, depth-1-only
			 * version of exactly this test.  every closure strictly
			 * between curclosure and anc (curclosure itself, plus
			 * each intermediate ->enclosing link up to but not
			 * including anc) needs d threaded through its *own*
			 * captures too, so com.c can read it one frame at a time
			 * when each level's own tfnptr gets built, each level
			 * reading it from whichever frame is actually live and
			 * addressable at *that* level's own construction site --
			 * see com.c's ecom() (Oname/Dfn case) for the read side
			 * of this.  only curclosure's own capture gets a real
			 * capuses entry (n itself is what gets rewritten below,
			 * same as before); every intermediate level's capture is
			 * a pure pass-through with no direct reference of its
			 * own to rewrite (addcapture()'s n==nil case, above).
			 * an ordinary top-level function never sets ->enclosing
			 * (only synthfunclit() does, on a closure's own lifted
			 * Dfn), so this walk terminates in nil, not a cycle, if d
			 * genuinely isn't reachable at all.
			 */
			Decl *anc, *cl;

			anc = curclosure->enclosing;
			while(anc != nil && !declownedby(d, anc))
				anc = anc->enclosing;
			if(anc == nil){
				/*
				 * believed unreachable: lookup() only ever hands
				 * back a Darg/Dlocal that's genuinely visible in
				 * the current scope, and that scope is exactly
				 * the chain this loop walks (a lexically nested
				 * closure's enclosing chain mirrors the actual
				 * scope-push/pop nesting) -- so d not being owned
				 * by anything on it would mean lookup() found a
				 * decl that was never actually in scope, a bug
				 * elsewhere, not a real capture shape.  kept as a
				 * diagnostic rather than a fatal() in case that
				 * belief is wrong.
				 */
				nerror(n, "cannot resolve capture of %s", n->sym->name);
				n->ty = terror;
				return n->ty;
			}
			boxvar(d, anc);
			for(cl = curclosure; cl->enclosing != anc; cl = cl->enclosing)
				addcapture(cl->enclosing, d, nil);
			addcapture(curclosure, d, n);
		}
		if(d->store == Dfn && d->ty != nil){
			/*
			 * a bare function name used as a plain *value*
			 * (an argument, a := RHS, ...), not Ocall's own
			 * callee -- that shape is special-cased directly in
			 * Ocall below (a literal "f(...)" compiles to a
			 * direct call, unaffected by this).  every function
			 * value -- this one or an eventual closure literal --
			 * is actually called through a synthesized "$fv"
			 * wrapper (synthfvwrap(), above) whose own signature
			 * has an env parameter prepended; d->valty is that
			 * wrapper's Tref{Tfn}, not d's own bare signature, so
			 * a call like apply(inc, x) type-checks inc's value
			 * against a parameter's identically env-prepended
			 * "func(int) int" (stype()'s Otfunc case) and com.c's
			 * fpcall() always finds an env slot to write, whether
			 * this particular value turns out to carry one or not.
			 *
			 * synthfvwrap() caches both wrapdecl and valty on d,
			 * built together from the exact same envfn() Tfn
			 * object -- built once, sizetype()'d and idoffsets()'d
			 * once (see synthfvwrap()'s own comment for why a
			 * fresh, never-sized Tref per reference was a real bug
			 * here, found the hard way).
			 */
			if(synthfvwrap(&n->src, d) == nil){
				n->ty = terror;
				return n->ty;
			}
			n->ty = d->valty;
		}
		return n->ty;
	case Odot:
		/* module member, adt field, or tuple field */
		if(n->left->op == Oname){
			d = lookup(n->left->sym);
			if(d != nil && d->ty != nil && d->ty->kind == Tmodule && ismodvar(d)){
				Decl *id;

				id = modmember(d->ty, n->sym);
				if(id == nil){
					nerror(n, "%s has no member %s", n->left->sym->name, n->sym->name);
					n->ty = terror;
					return n->ty;
				}
				switch(id->store){
				case Dconst:
					if(confold(n, id))
						return n->ty;
					nerror(n, "constant %s.%s is not usable here",
						n->left->sym->name, n->sym->name);
					n->ty = terror;
					return n->ty;
				case Dfn: {
					/*
					 * a bare "alias.fn" used as a plain *value*,
					 * not Ocall's own callee -- that shape is
					 * special-cased directly in Ocall below (a
					 * literal "alias.fn(...)" compiles to a direct
					 * call, never reaching this branch at all, the
					 * identical split echk's own Oname case already
					 * draws for a same-module Dfn). synthimportwrap()
					 * (above) is the Odot analogue of synthfvwrap():
					 * builds (or finds, already cached by name) a
					 * wrapper Dfn in *this* module that calls
					 * through alias.fn, then hands back wd itself --
					 * rewriting this node into a plain Oname naming
					 * wd, exactly the shape a same-module function
					 * value already is, lets ecom()'s existing
					 * Oname/Dfn case (com.c) build the tfnptr with
					 * zero changes there: it reads d->wrapdecl,
					 * which synthimportwrap() sets to wd itself.
					 */
					Decl *wd;

					if(id->inl){
						/*
						 * an inline function from the interface as a
						 * value: this module's own instance, then a
						 * local function value (the Oname/Dfn case)
						 */
						Decl *fnd;

						fnd = tinstantiatefncore(&n->src, id, nil, 0, nil);
						if(fnd == nil || synthfvwrap(&n->src, fnd) == nil){
							n->ty = terror;
							return n->ty;
						}
						n->op = Oname;
						n->left = n->right = nil;
						n->decl = fnd;
						n->sym = fnd->sym;
						n->ty = fnd->valty;
						return n->ty;
					}
					wd = synthimportwrap(&n->src, d, id);
					if(wd == nil){
						n->ty = terror;
						return n->ty;
					}
					n->op = Oname;
					n->left = n->right = nil;
					n->decl = wd;
					n->sym = wd->sym;
					n->ty = wd->valty;
					return n->ty;
				}
				case Dglobal: {
					/*
					 * an imported module's variable: the alias
					 * holds the module link, whose first word is
					 * the module's data pointer, and the variable
					 * sits at its offset in the interface's
					 * name-sorted .mp record (mkiface(), which the
					 * exporter lays its data out by, modcom()):
					 * alias.var -> Oind(Oadd(Oind(alias), $off)),
					 * limbo/ecom.c's rewrite() of an Omdot global.
					 * from here on it is an ordinary indirect
					 * access -- an lvalue too.
					 */
					Decl *mp, *c;
					Node *inner, *off, *addr;

					d->refs++;
					id->refs++;
					if(d->ty->tof == nil)
						sizetype(d->ty);
					mp = id->iface;
					if(mp == nil || mp->ty == nil){
						nerror(n, "%s.%s: the interface exports no module data",
							n->left->sym->name, n->sym->name);
						n->ty = terror;
						return n->ty;
					}
					sizetype(mp->ty);
					for(c = mp->ty->ids; c != nil && c->iface != id; c = c->next)
						;
					if(c == nil)
						fatal("%s.%s missing from the .mp record", n->left->sym->name, n->sym->name);
					n->left->decl = d;
					n->left->ty = d->ty;
					inner = mkunary(Oind, n->left);
					inner->src = n->src;
					inner->ty = tint;
					off = mkconst(&n->src, c->offset);
					off->ty = tint;
					addr = mkn(Oadd, inner, off);
					addr->src = n->src;
					addr->ty = tint;
					n->op = Oind;
					n->left = addr;
					n->right = nil;
					n->decl = nil;
					n->ty = id->ty;
					return n->ty;
				}
				case Dtype: {
					Src msrc;

					d->refs++;
					id->refs++;
					/* the member keeps its own place, not the whole dot's: -X reports it */
					msrc = n->right != nil ? n->right->src : n->src;
					n->op = Omdot;
					n->left->decl = d;
					n->left->ty = d->ty;
					n->right = mkn(Oname, nil, nil);
					n->right->src = msrc;
					n->right->sym = n->sym;
					n->right->decl = id;
					n->right->ty = id->ty;
					n->ty = id->ty;
					return n->ty;
				}
				default:
					nerror(n, "cannot use %s.%s here", n->left->sym->name, n->sym->name);
					n->ty = terror;
					return n->ty;
				}
			}
		}
		{
			Type *bt;
			int isref, oincallee;

			oincallee = incallee;
			incallee = 0;	/* the receiver is a value, whatever the whole dot is */
			bt = echk(n->left);
			incallee = oincallee;
			t = bt;
			isref = bt != nil && bt->kind == Tref;
			if(isref)
				t = bt->tof;
			if(t != nil && t->named && !isref){
				/* "c.name()": a named type has no fields, only methods */
				Decl *id;

				for(id = t->meths; id != nil; id = id->link)
					if(id->sym == n->sym){
						if(!incallee)
							return methvalue(n, id);	/* "f := c.label": a method as a value */
						n->decl = id;
						n->ty = id->ty;
						n->right = nil;
						return n->ty;
					}
				nerror(n, "%T has no method %s", t, n->sym->name);
				n->ty = terror;
				return n->ty;
			}
			if(t != nil && (t->kind == Tadt || t->kind == Tadtpick || t->kind == Ttuple)){
				Decl *id, *chains[2];
				int ci;

				/*
				 * a Tadtpick receiver (a specific tag's own type,
				 * e.g. a local read back out of "ok := Result.Ok{
				 * val: 5}") has its fields split across two chains
				 * the same way compositefields() (above) does for
				 * construction: t->ids (this tag's own extra
				 * fields) and t->tof->ids (the outer adt's shared
				 * fields) -- both already correctly offset from the
				 * same base by sizetype() (types.c), so the address
				 * arithmetic below needs no changes at all once the
				 * matching field is found, only the search needs to
				 * cover both chains. a plain Tadt or Ttuple has no
				 * second chain (chains[1] stays nil, since the ?:
				 * below only fires for Tadtpick), degrading to
				 * exactly the original single-chain search -- a
				 * Ttuple's own fields ("t0", "t1", ... -- both
				 * stype()'s Ottuple case, for a declared tuple-typed
				 * field, and echk()'s Otuple case, for a literal's
				 * own inferred type, auto-generate these; a tuple
				 * TYPE has no named-component syntax anywhere in this
				 * grammar at all, parse.c's own '(' type-parser only
				 * ever reads a bare comma-separated type list, so
				 * "t0"/"t1"/... are the only names that can ever
				 * exist) live in that one chain (t->ids) the identical
				 * way an ordinary struct's fields do, so this needs no
				 * further change: "container.p.t0" (dot straight
				 * onto a Ttuple value, as opposed to the destructuring
				 * "x, s := container.p" that already worked) now
				 * resolves through the same offset arithmetic below.
				 */
				chains[0] = t->ids;
				chains[1] = t->kind == Tadtpick ? t->tof->ids : nil;
				for(ci = 0; ci < 2; ci++)
				for(id = chains[ci]; id != nil; id = id->next)
					if(id->sym == n->sym){
						Node *off, *addr;
						Type *fty;

						fty = id->ty;
						/*
						 * base.field -> Oind(Oadd(base', $offset)),
						 * same shape limbo/ecom.c's rewrite()
						 * builds for Odot.  n->right (the parsed
						 * field-name label) is discarded, not
						 * reused, to keep this simple.
						 *
						 * base' is base itself when base : ref adt
						 * (n->left already IS the pointer value to
						 * offset-and-dereference), but base : plain
						 * struct *value* needs base' = Oadr(base)
						 * first -- an explicit "address of this
						 * value's own storage" marker.  without it,
						 * sumark's Oadd/Oind tables would treat a
						 * value's frame slot exactly like a ref
						 * pointer's and emit a *real* dereference
						 * (Afpind) of whatever bytes happen to be
						 * sitting in that slot -- wrong, since a
						 * value struct's slot already IS the field
						 * data, not a pointer to it.  Oadr's own
						 * sumark case (com.c) exists precisely so
						 * this Oind collapses back to a plain
						 * Rreg/Rmreg (no dereference) instead of
						 * Radr/Rmadr, for exactly this reason --
						 * ported from limbo/ecom.c's identical
						 * Oadr-wraps-non-ref-bases rule, which this
						 * port originally (32d6cb90) skipped as
						 * "not yet supported", not realizing the
						 * wrap was the missing piece, not a whole
						 * separate feature.
						 *
						 * n->decl is set to the field only for the
						 * ref case: Radr's genaddr case (gen.c)
						 * ignores n->decl and recurses into n->left
						 * regardless, but Rreg's *checks* n->decl
						 * first and, if set, uses it directly
						 * instead of recursing -- which for the
						 * value case would skip right over the
						 * Oadr/Oadd chain that computes the real
						 * offset.  leaving it nil there is
						 * required, not just tidier.
						 */
						off = mkconst(&n->src, id->offset);
						off->ty = tint;
						if(isref)
							addr = mkn(Oadd, n->left, off);
						else{
							Node *adr;

							adr = mkunary(Oadr, n->left);
							adr->src = n->src;
							adr->ty = bt;
							addr = mkn(Oadd, adr, off);
						}
						addr->src = n->src;
						addr->ty = tint;
						n->op = Oind;
						n->left = addr;
						n->right = nil;
						n->decl = isref ? id : nil;
						n->ty = fty;
						return n->ty;
					}
				/*
				 * not a field: maybe a bound method.  leaves n
				 * as Odot (op unchanged) with n->decl set to
				 * the Dfn; Ocall recognizes this shape and
				 * desugars recv.m(args) -> m(recv, args) after
				 * this returns -- no addressing rewrite needed
				 * here since the receiver is just passed as an
				 * ordinary argument, value or ref alike.
				 */
				for(id = t->meths; id != nil; id = id->link)
					if(id->sym == n->sym){
						if(id->inl){
							/* declared with its body in an interface: this module's copy */
							id = inlmeth(id, t);
							if(id == nil){
								n->ty = terror;
								return n->ty;
							}
						}
						if(!incallee)
							return methvalue(n, id);	/* "f := c.get": a method as a value */
						n->decl = id;
						n->ty = id->ty;
						n->right = nil;
						return n->ty;
					}
				if(t->gtemplate != nil){
					/*
					 * t is a generic type's own instantiation (e.g.
					 * Box[int]); its meths is always nil (instantiating
					 * a struct never copies methods over), but a method
					 * declared with a generic receiver lives on the
					 * *template*'s methtmpl instead (fndecl()) -- found
					 * here, it's instantiated on the spot with the same
					 * type arguments (t->ginst) that produced t itself.
					 */
					Decl *mtd, *fnd;

					for(mtd = t->gtemplate->methtmpl; mtd != nil; mtd = mtd->link)
						if(mtd->sym == n->sym){
							fnd = tinstantiatemeth(mtd, t);
							if(fnd == nil){
								n->ty = terror;
								return n->ty;
							}
							if(!incallee)
								return methvalue(n, fnd);
							n->decl = fnd;
							n->ty = fnd->ty;
							n->right = nil;
							return n->ty;
						}
				}
				{
					/* an embedded field's own names, through it: "d.id" is "d.Base.id" */
					Decl *em;

					for(em = t->ids; em != nil; em = em->next)
						if(em->embedded && hasmember(em->ty, n->sym)){
							Node *base;

							base = mkbin(Odot, n->left, mkname(&n->src, em->sym));
							base->sym = em->sym;
							base->src = n->src;
							n->left = base;
							return echk1(n);
						}
				}
				nerror(n, "%T has no field or method %s", t, n->sym->name);
				n->ty = terror;
				return n->ty;
			}
			nerror(n, "field selection on %T", t);
			n->ty = terror;
		}
		return n->ty;
	case Ocall: {
		Node *a, *recvdone;
		Decl *arg;
		Type *ft;
		int i, isvalcall;

		isvalcall = 0;
		recvdone = nil;

		/*
		 * "int(x)", "string(b)", "real(i)": a call whose callee is
		 * a type name is a conversion, go-style -- rewrite it to
		 * Ocast (left the operand, right the type node) and check
		 * it there.  the builtin type names are ordinary Dtype
		 * symbols (declbuiltin()), so the parser can't tell this
		 * from a call and doesn't try to.
		 */
		if(n->left->op == Oname || (n->left->op == Odot && n->left->left != nil && n->left->left->op == Oname)){
			Decl *td, *md;

			if(n->left->op == Oname)
				td = lookup(n->left->sym);
			else{
				/* "alias.Color(x)": a type from an imported module */
				td = nil;
				md = lookup(n->left->left->sym);
				if(md != nil && md->ty != nil && md->ty->kind == Tmodule)
					td = modmember(md->ty, n->left->sym);
			}
			if(td != nil && td->store == Dtype){
				if(n->right == nil || n->right->op == Oseq){
					nerror(n, "conversion to %s needs exactly one argument", td->sym->name);
					n->ty = terror;
					return n->ty;
				}
				n->op = Ocast;
				a = n->left;
				n->left = n->right;
				n->right = a;
				return echk(n);
			}
		}
		/* callee: allow name, mod.fn, or builtins */
		if(n->left->op == Oname && strcmp(n->left->sym->name, "len") == 0){
			Node *a, *e;

			a = n->right;
			if(a == nil){
				nerror(n, "len needs an argument");
				n->ty = terror;
				return n->ty;
			}
			if(a->op == Oseq)
				e = a->left;
			else
				e = a;
			t = echk(e);
			if(ismaptype(t)){
				p = mkmethcall(&n->src, e, "size", nil);
				n->left = p->left;
				n->right = nil;
				return echk(n);
			}
			if(t->kind != Tarray && t->kind != Tstring && t->kind != Tlist){
				nerror(n, "len of %T", t);
				n->ty = terror;
				return n->ty;
			}
			n->op = Olen;
			n->left = e;
			n->right = nil;
			n->ty = tint;
			return n->ty;
		}
		if(n->left->op == Oname && strcmp(n->left->sym->name, "delete") == 0 && lookup(n->left->sym) == nil){
			/* delete(m, k): m.del(k) -- unless the program has its own delete */
			Node *a;

			a = n->right;
			if(a == nil || a->op != Oseq || a->right == nil || a->right->op == Oseq || !ismapindex(mkbin(Oindex, a->left, a->right))){
				nerror(n, "delete needs a map and a key");
				n->ty = terror;
				return n->ty;
			}
			p = mkmethcall(&n->src, a->left, "del", a->right);
			n->left = p->left;
			n->right = p->right;
			return echk(n);
		}
		if(n->left->op == Oname && strcmp(n->left->sym->name, "append") == 0 && lookup(n->left->sym) == nil){
			/*
			 * append(a, x) and append(a, xs...): .builtin.append and
			 * .builtin.appendall, templates instantiated by the
			 * argument types like any alias.f(args) call below
			 */
			Node *a;

			a = n->right;
			if(a == nil || a->op != Oseq || a->right == nil || a->right->op == Oseq){
				nerror(n, "append needs an array and a value");
				n->ty = terror;
				return n->ty;
			}
			if(a->right->flags & NVARARG){
				a->right->flags &= ~NVARARG;
				n->left = builtinref(&n->src, "appendall");
			}else
				n->left = builtinref(&n->src, "append");
		}
		if(n->left->op == Oname && strcmp(n->left->sym->name, "expect") == 0 && lookup(n->left->sym) == nil)
			n->left = builtinref(&n->src, "expect");	/* a test's assertion, builtin.ei's */
		if(n->left->op == Oname && strcmp(n->left->sym->name, ".typeid") == 0){
			/* the interface converter's .tag: the argument's type as a string, what x.(T) compares */
			Type *at;

			at = echk(n->right);
			if(at == terror){
				n->ty = terror;
				return n->ty;
			}
			if(isifacetype(at)){
				/* an interface narrowed to another keeps the tag of what it holds */
				n->op = Odot;
				n->left = n->right;
				n->right = mkname(&n->src, enter(".tag", 0));
				n->sym = n->right->sym;
				return echk(n);
			}
			*n = *mksconst(&n->src, enter(smprint("%T", at), 0));
			return echk(n);
		}
		if(n->left->op == Oname && strcmp(n->left->sym->name, "exit") == 0){
			/* "exit()": limbo's exit statement, Dis IEXIT; terminates */
			if(n->right != nil){
				nerror(n, "exit takes no arguments");
				n->ty = terror;
				return n->ty;
			}
			n->op = Oexit;
			n->left = nil;
			n->ty = tnone;
			return n->ty;
		}
		if(n->left->op == Oname && strcmp(n->left->sym->name, "copy") == 0){
			/*
			 * "copy(dst, src)": go's array copy as a statement, on
			 * Dis's slicela (limbo's "dst[0:] = src"). No value;
			 * src must fit in dst or the VM raises a bounds error.
			 */
			Node *a, *d, *e;
			Type *td;

			a = n->right;
			if(a == nil || a->op != Oseq || a->right == nil || a->right->op == Oseq){
				nerror(n, "copy needs two arguments");
				n->ty = terror;
				return n->ty;
			}
			d = a->left;
			e = a->right;
			td = echk(d);
			t = echk(e);
			if(td == terror || t == terror){
				n->ty = terror;
				return n->ty;
			}
			if(td->kind != Tarray || t->kind != Tarray || !sametype(td, t)){
				nerror(n, "copy of %T into %T", t, td);
				n->ty = terror;
				return n->ty;
			}
			n->op = Ocopy;
			n->left = d;
			n->right = e;
			n->ty = tnone;
			return n->ty;
		}
		if(n->left->op == Oname && (strcmp(n->left->sym->name, "hd") == 0
		|| strcmp(n->left->sym->name, "tl") == 0)){
			/*
			 * "hd(xs)"/"tl(xs)": function-call-style builtins,
			 * matching the *already-established* local convention
			 * "len" uses just above -- not limbo's own keyword-
			 * prefix-operator grammar ("hd xs"), which ember has no
			 * equivalent lexer/parser support for and doesn't need
			 * just for these two.
			 */
			int ishd;
			Node *a, *e;

			ishd = n->left->sym->name[0] == 'h';
			a = n->right;
			if(a == nil){
				nerror(n, "%s needs an argument", ishd ? "hd" : "tl");
				n->ty = terror;
				return n->ty;
			}
			if(a->op == Oseq)
				e = a->left;
			else
				e = a;
			t = echk(e);
			if(t->kind != Tlist || t->tof == nil){
				nerror(n, "cannot %s %T", ishd ? "hd" : "tl", t);
				n->ty = terror;
				return n->ty;
			}
			n->op = ishd ? Ohd : Otl;
			n->left = e;
			n->right = nil;
			n->ty = ishd ? t->tof : t;
			return n->ty;
		}
		if((n->left->op == Otinst || n->left->op == Oindex) && n->left->left->op == Odot
		&& modtemplate(n->left->left) != nil){
			/* alias.f[T](args): a template from the interface, resolved to its decl */
			Decl *tmpl;

			tmpl = modtemplate(n->left->left);
			/* no alias reference: the code is ours, the module need not load */
			n->left->left->op = Oname;
			n->left->left->sym = tmpl->sym;
			n->left->left->decl = tmpl;
			n->left->left->left = nil;
			n->left->left->right = nil;
		}
		if(n->left->op == Odot && modtemplate(n->left) != nil){
			/* alias.f(args): the same, with the type arguments inferred */
			Decl *tmpl;

			tmpl = modtemplate(n->left);
			n->left->op = Oname;
			n->left->sym = tmpl->sym;
			n->left->decl = tmpl;
			n->left->left = nil;
			n->left->right = nil;
		}
		if(!isidxcall(n->left) && (n->left->op == Otinst || n->left->op == Oindex)){
			/*
			 * "swap[int, string](1, "one")": the callee parsed as a
			 * type-instantiation-shaped expression (ptypename()
			 * always produces Otinst; the general expression grammar
			 * -- what a call's own callee position goes through --
			 * can't tell an index from an instantiation and produces
			 * Oindex instead, same ambiguity stype()'s own Otinst/
			 * Oindex cases already resolve for a type use).
			 * tinstantiatefn() resolves it to a concrete, already-
			 * fully-checked Dfn; replace the callee with a plain
			 * Oname naming it, same shape a resolved bound method
			 * gets below -- but read ft directly off the Decl rather
			 * than falling into the shared echk(Oname) path further
			 * down, which resolves purely by symbol lookup and would
			 * never find this one: an instantiation is deliberately
			 * not install()ed under any name (see tinstantiatefn()).
			 */
			Decl *fnd;

			fnd = tinstantiatefn(n->left);
			if(fnd == nil){
				n->ty = terror;
				return n->ty;
			}
			n->left = mkn(Oname, nil, nil);
			n->left->src = fnd->src;
			n->left->sym = fnd->sym;
			n->left->decl = fnd;
			n->left->ty = fnd->ty;
			ft = fnd->ty;
		}else if(n->left->op == Oname && (n->left->decl != nil ? n->left->decl : lookup(n->left->sym)) != nil
		&& (n->left->decl != nil ? n->left->decl : lookup(n->left->sym))->store == Dfn
		&& (n->left->decl != nil ? n->left->decl : lookup(n->left->sym))->tparams != nil){
			/*
			 * "swap(1, "one")": no explicit "[...]", but the callee
			 * names a generic function template -- try inferring
			 * the type arguments from the call's own argument types
			 * (inferfn()) instead of requiring them spelled out.
			 * same replace-the-callee-with-a-resolved-Oname shape as
			 * the explicit case above.
			 */
			Decl *fnd;

			fnd = inferfn(n);
			if(fnd == nil){
				n->ty = terror;
				return n->ty;
			}
			n->left = mkn(Oname, nil, nil);
			n->left->src = fnd->src;
			n->left->sym = fnd->sym;
			n->left->decl = fnd;
			n->left->ty = fnd->ty;
			ft = fnd->ty;
		}else if(n->left->op == Oname && (n->left->decl != nil ? n->left->decl : lookup(n->left->sym)) != nil
		&& (n->left->decl != nil ? n->left->decl : lookup(n->left->sym))->store == Dfn){
			/*
			 * a literal "f(...)": resolved directly, *without*
			 * going through echk()'s own Oname case -- that case
			 * unconditionally synthesizes a "$fv" wrapper for any
			 * Dfn it sees (synthfvwrap(), a real cost: a whole
			 * extra function, fnchk()'d, added to fns[]), needed
			 * only for a genuine *value* use.  a literal direct
			 * call never needs one at all (callcom's ordinary
			 * Rpc/ICALL path, unaffected by any of this) -- calling
			 * echk() here regardless, then discarding the wrap, used
			 * to be merely wasteful; now it's actively wrong,
			 * synthesizing (and fnchk()ing) a wrapper for *every*
			 * function ever called directly, whether or not anything
			 * ever takes it as a value -- real, ordinary cost
			 * (synthfvwrap()/synthfunclit() both support a void
			 * return now, so it's no longer a hard error too, but
			 * still unnecessary work for the overwhelming majority
			 * of calls that are never used as a value at all).
			 */
			Decl *fnd;

			fnd = n->left->decl;
			if(fnd == nil)
				fnd = lookup(n->left->sym);
			if(fnd->inl){
				/* an inline function from an interface: this module's own copy */
				fnd = tinstantiatefncore(&n->src, fnd, nil, 0, nil);
				if(fnd == nil){
					n->ty = terror;
					return n->ty;
				}
			}
			fnd->refs++;
			{
				Decl *alias;

				alias = nil;
				if(fnd->dot != nil && fnd->dot != impdecl && fnd->dot->ty != nil && fnd->dot->ty->kind == Tmodule)
					alias = modalias(fnd->dot);
				if(alias != nil){
					/*
					 * a template body (pushmodscope()) calling its
					 * own module's function by name: through the
					 * alias, as alias.f(...) would be
					 */
					Node *modn, *callee;

					alias->refs++;
					modn = mkn(Oname, nil, nil);
					modn->src = n->left->src;
					modn->sym = alias->sym;
					modn->decl = alias;
					modn->ty = alias->ty;
					callee = mkn(Oname, nil, nil);
					callee->src = n->left->src;
					callee->sym = fnd->sym;
					callee->decl = fnd;
					callee->ty = fnd->ty;
					n->left = mkbin(Omdot, modn, callee);
					n->left->src = callee->src;
					n->left->ty = fnd->ty;
				}else{
					n->left->decl = fnd;
					n->left->ty = fnd->ty;
				}
			}
			ft = fnd->ty;
		}else if(n->left->op == Odot && modcallee(n->left) != nil){
			/*
			 * a literal "alias.fn(...)": the Odot analogue of the
			 * literal "f(...)" fast path just above, for the
			 * identical reason -- without this, a direct call to
			 * an imported function would fall into the general
			 * echk(n->left) path below, which (per this session's
			 * change to echk's own Odot case, above) now
			 * unconditionally synthesizes a same-module wrapper
			 * (synthimportwrap()) for *any* Dfn read through Odot,
			 * needed only for a genuine value use ("g :=
			 * alias.fn"). resolved directly to a bare Omdot
			 * instead, matching Ocall's own pre-existing Omdot
			 * dispatch (com.c's callcom()) completely unchanged --
			 * modcallee()'s own guard is what keeps this from ever
			 * matching a bound method call (obj.method(...)),
			 * which reaches this same Odot shape but whose
			 * receiver is never itself a Tmodule-typed Dglobal.
			 */
			Decl *alias, *fnd;
			Src msrc;

			alias = lookup(n->left->left->sym);
			fnd = modmember(alias->ty, n->left->sym);
			alias->refs++;
			fnd->refs++;
			/* the member keeps its own place, not the whole dot's: -X reports it */
			msrc = n->left->right != nil ? n->left->right->src : n->left->src;
			n->left->op = Omdot;
			n->left->left->decl = alias;
			n->left->left->ty = alias->ty;
			n->left->right = mkn(Oname, nil, nil);
			n->left->right->src = msrc;
			n->left->right->sym = n->left->sym;
			n->left->right->decl = fnd;
			n->left->right->ty = fnd->ty;
			n->left->ty = fnd->ty;
			ft = fnd->ty;
		}else{
			switch(n->left->op){
			case Oname:
			case Odot:
			case Omdot:
			case Ocall:
			case Ofunclit:	/* func(...){...}(args): called (or spawned) at once */
			case Oindex:	/* fs[i](args): an array of function values (isidxcall) */
				break;
			default:
				nerror(n, "cannot call this expression");
				n->ty = terror;
				return n->ty;
			}
			incallee++;
			ft = echk(n->left);
			incallee--;
			if(ft != nil && ft->kind == Tref && ft->tof != nil && ft->tof->kind == Tfn){
				/*
				 * calling *through* a function value instead
				 * -- a parameter, local, global, or field, not
				 * a literal top-level name.  wrap the callee in
				 * Oind so ecom's Ocall dispatch (com.c) routes
				 * to fpcall() instead of callcom()'s direct-call
				 * path, the same "left->op==Oind" convention
				 * limbo/ecom.c's Ocall dispatch uses.
				 */
				Node *ind;

				ind = mkunary(Oind, n->left);
				ind->src = n->left->src;
				ind->ty = ft->tof;
				n->left = ind;
				ft = ft->tof;
				isvalcall = 1;
			}
		}
		if(ft->kind != Tfn){
			if(ft != terror)
				nerror(n, "call of a non-function");
			n->ty = terror;
			return n->ty;
		}

		/*
		 * bound method: n->left is still Odot (echk's Odot case
		 * leaves it that way when the name resolved to a method,
		 * not a field), with n->left->decl the Dfn and
		 * n->left->left the receiver expression.  Desugar
		 * recv.m(args) into m(recv, args) so the rest of Ocall,
		 * and all of com.c, see an ordinary local call -- the
		 * callee's Tfn already has the receiver as ids[0]
		 * (fndecl prepended it).
		 */
		if(n->left->op == Odot && n->left->decl != nil && n->left->decl->store == Dfn){
			Decl *meth, *alias;
			Node *recvexpr, *callee;

			meth = n->left->decl;
			recvexpr = n->left->left;
			/*
			 * the receiver was already echk()'d (by the Odot
			 * above, to find the method); the argument loop below
			 * must not check it again -- a receiver that is itself
			 * a method call ("p.get().val()") has by now been
			 * desugared to a bare Oname naming the method, which
			 * a second echk() can't resolve ("get is not
			 * declared", since methods aren't in ordinary scope).
			 */
			recvdone = recvexpr;
			n->right = mkseq(recvexpr, n->right);
			callee = mkn(Oname, nil, nil);
			callee->src = n->left->src;
			callee->sym = meth->sym;
			callee->decl = meth;
			callee->ty = meth->ty;
			alias = methodmodule(meth);
			if(alias != nil){
				/*
				 * a method of an imported adt (iface.c): not a
				 * local Dfn to call by pc but a link-table entry
				 * of the module the type came from, dispatched
				 * through that module's import alias -- the same
				 * Omdot(alias, fn) shape a direct "alias.fn(...)"
				 * call takes (above), which com.c's callcom()
				 * already handles unchanged.  limbo does the same:
				 * a Bufio->Iobuf method call goes through the
				 * bufio module variable.  the alias is referenced,
				 * so it's autoloaded at init.
				 */
				Node *modn;

				alias->refs++;
				meth->refs++;
				modn = mkn(Oname, nil, nil);
				modn->src = n->left->src;
				modn->sym = alias->sym;
				modn->decl = alias;
				modn->ty = alias->ty;
				callee = mkbin(Omdot, modn, callee);
				callee->src = n->left->src;
				callee->ty = meth->ty;
			}
			n->left = callee;
		}

		/*
		 * check fixed args -- a value-call's ft->ids leads with the
		 * synthesized wrapper's "env any" parameter (envfn(),
		 * synthfvwrap(), above), which the user never writes at the
		 * call site: skip it here, com.c's fpcall() supplies it.
		 */
		arg = ft->ids;
		if(isvalcall && arg != nil)
			arg = arg->next;
		if(ft->varargs == 2 && !(n->flags & NPACKED)){
			packvarargs(n, arg);
			n->flags |= NPACKED;
		}
		i = 0;
		for(a = n->right; a != nil; a = a->right){
			Node *e;

			e = a;
			if(a->op == Oseq)
				e = a->left;
			t = e == recvdone ? e->ty : echk(e);
			i++;
			if(arg != nil){
				retypetuple(e, arg->ty);
				if(!assignable(arg->ty, t, e)){
					if(t->kind == Ttuple && e->op == Ocall && a->op != Oseq && !ft->varargs){
						/*
						 * f(g()) with g multi-valued and the last
						 * argument (a method's receiver comes first):
						 * g's results are the remaining arguments,
						 * one per parameter (go's rule).  callcom()
						 * (com.c) evaluates the call into a tuple
						 * temporary and passes its fields.
						 */
						Decl *fd;

						for(fd = t->ids; fd != nil; fd = fd->next){
							if(arg == nil){
								nerror(e, "too many arguments");
								break;
							}
							if(!assignable(arg->ty, fd->ty, nil))
								nerror(e, "argument %d: cannot use %T as %T", i, fd->ty, arg->ty);
							i++;
							arg = arg->next;
						}
						e->flags |= NSPREAD;
						break;
					}
					nerror(e, "argument %d: cannot use %T as %T", i, t, arg->ty);
				}
				arg = arg->next;
			}else if(!ft->varargs)
				nerror(e, "too many arguments");
			if(a->op != Oseq)
				break;
		}
		if(arg != nil)
			nerror(n, "not enough arguments");

		/*
		 * varargs calls get a per-call fn type whose ids
		 * include the actual arguments, as limbo's mkvarargs
		 * does; the frame layout comes from this type
		 */
		if(ft->varargs == 1){
			Type *nft;
			Decl *nids, *nlast, *na;
			char buf[32];
			int j;

			nft = mktype(&n->src, Tfn, ft->tof, nil);
			nft->varargs = 1;
			nids = nlast = nil;
			j = 0;
			for(arg = ft->ids; arg != nil; arg = arg->next){
				na = dupdecl(arg);
				if(nids == nil)
					nids = na;
				else
					nlast->next = na;
				nlast = na;
				j++;
			}
			/*
			 * a value-call's ft->ids leads with the synthesized
			 * wrapper's own "env any" parameter (envfn()/
			 * synthfvwrap(), the same skip the fixed-arg-checking
			 * loop just above already applies to "arg") -- the user
			 * never writes it at the call site, so it isn't present
			 * in n->right at all, only in ft->ids (and, correctly,
			 * still needs to stay in nft->ids just built above:
			 * fpcall() (com.c) prepends a real env argument to
			 * n->right at *codegen* time, so the runtime frame this
			 * nft describes genuinely needs that slot). without this
			 * adjustment, j overcounts by one for a value-call and
			 * the loop below misaligns every real argument against
			 * nft->ids by one position, silently dropping the LAST
			 * real vararg (whichever argument would have filled the
			 * slot env's own unaccounted-for presence ate) -- found
			 * testing the value-call varargs fix (com.c's fpcall()/
			 * callcom(), same session): confirmed via callcom()'s own
			 * "too many args" fatal on a value-call passing more
			 * varargs than happened to survive the misalignment.
			 */
			if(isvalcall)
				j--;
			i = 0;
			for(a = n->right; a != nil; a = a->right){
				Node *e;

				e = a;
				if(a->op == Oseq)
					e = a->left;
				if(i >= j){
					na = mkdecl(&e->src, Darg, e->ty);
					seprint(buf, buf+sizeof(buf), ".a%d", i);
					na->sym = enter(buf, 0);
					if(nids == nil)
						nids = na;
					else
						nlast->next = na;
					nlast = na;
				}
				i++;
				if(a->op != Oseq)
					break;
			}
			nft->ids = nids;
			nft->ok |= OKverify;
			sizetype(nft);
			sizeids(nft->ids, MaxTemp);
			n->left->ty = nft;
		}
		n->ty = ft->tof;
		return n->ty;
	}
	case Oadd: case Osub: case Omul: case Odiv: case Omod:
	case Oand: case Oor: case Oxor: case Olsh: case Orsh:
		t = echk(n->left);
		tr = echk(n->right);
		if(t == terror || tr == terror){
			n->ty = terror;
			return n->ty;
		}
		/* a shift count is always an int, whatever is shifted
		 * (big(1) << 40, b << 2 for a byte), as in limbo */
		if((n->op == Olsh || n->op == Orsh) && tr->kind == Tint
		&& (t->kind == Tbig || t->kind == Tbyte))
			tr = t;
		if(!tequal(t, tr)){
			nerror(n, "type mismatch: %T %s %T", t, opname[n->op], tr);
			n->ty = terror;
			return n->ty;
		}
		switch(t->kind){
		case Tint:
		case Tbig:
		case Tbyte:
			break;
		case Treal:
			if(n->op == Omod || n->op == Oand || n->op == Oor || n->op == Oxor
			|| n->op == Olsh || n->op == Orsh){
				nerror(n, "operation not defined on %T", t);
				n->ty = terror;
				return n->ty;
			}
			break;
		case Tstring:
			if(n->op != Oadd){
				nerror(n, "operation not defined on %T", t);
				n->ty = terror;
				return n->ty;
			}
			break;
		default:
			nerror(n, "operation not defined on %T", t);
			n->ty = terror;
			return n->ty;
		}
		n->ty = t;
		if(n->left->op == Oconst && n->right->op == Oconst)
			confoldbin(n);
		return n->ty;
	case Ocons: {
		Type *et;

		et = echk(n->left);
		tr = echk(n->right);
		if(et == terror || tr == terror){
			n->ty = terror;
			return n->ty;
		}
		if(tr == tany){
			/*
			 * "x :: nil": bare nil (now an ordinary tany-typed
			 * global read, see check()'s nildecl) infers the
			 * list's own element type from the left side, exactly
			 * mirroring limbo/typecheck.c's identical special case.
			 * a fresh Tlist built here needs its own sizetype()
			 * call -- unlike stype()'s Otlist case, this one has
			 * no daschk()-style caller that sizes it afterward, and
			 * an unsized Type silently defaulting to size=0 is
			 * exactly the bug class 372f4524/c407e833 closed
			 * structurally (talloc() now fatal()s on it, so a
			 * mistake here would be loud, not a background fault --
			 * still correct to get right rather than lean on that).
			 */
			/*
			 * "ref Val.Num{...} :: nil" starts a list of ref Val, not
			 * of ref Val.Num: a tag's type is assignable to its pick
			 * type, and a list pinned to one tag could never take
			 * the others ("type mismatch in ref adt :: list of ref
			 * adt" on the second tag in tests/type/jsonlike.e).
			 */
			if(et->kind == Tref && et->tof != nil && et->tof->kind == Tadtpick
			&& et->tof->tof != nil){
				et = mktype(&n->src, Tref, et->tof->tof, nil);
				sizetype(et);
			}else if(et->kind == Tadtpick && et->tof != nil)
				et = et->tof;
			n->ty = mktype(&n->src, Tlist, et, nil);
			sizetype(n->ty);
			return n->ty;
		}
		if(tr->kind != Tlist){
			nerror(n, "cannot :: to %T", tr);
			n->ty = terror;
			return n->ty;
		}
		if(!assignable(tr->tof, et, n->left)){
			nerror(n, "type mismatch in %T :: %T", et, tr);
			n->ty = terror;
			return n->ty;
		}
		n->ty = tr;
		return n->ty;
	}
	case Oeq: case Oneq: case Olt: case Ogt: case Oleq: case Ogeq:
		t = echk(n->left);
		tr = echk(n->right);
		if(t != terror && tr != terror && !assignable(t, tr, n->right) && !assignable(tr, t, n->left))
			nerror(n, "type mismatch: %T %s %T", t, opname[n->op], tr);
		else if(t != terror && (n->op == Oeq || n->op == Oneq) && t->kind == Tadt && t->tags == nil
		&& tr != terror && tequal(t, tr)){
			/* "a == b" on two struct values: field by field */
			Node *cmp;

			if(n->left->op == Oname && n->right->op == Oname)
				cmp = structeq(n->left, n->right, t, &n->src);
			else{
				/*
				 * an operand that is not a name is evaluated once,
				 * as the parameter of a closure comparing the two:
				 *	(func(.ea T, .eb T) int { return ... })(a, b)
				 */
				Node *pa, *pb, *sig, *stmt, *fl, *call, *body;
				Sym *sa, *sb;
				char buf[32];
				static int neq;

				seprint(buf, buf+sizeof(buf), ".ea%d", neq);
				sa = enter(buf, 0);
				seprint(buf, buf+sizeof(buf), ".eb%d", neq++);
				sb = enter(buf, 0);
				body = structeq(mkname(&n->src, sa), mkname(&n->src, sb), t, &n->src);
				if(body == nil)
					cmp = nil;
				else{
					pa = mkbin(Ofield, mkname(&n->src, sa), typeval(&n->src, t));
					pb = mkbin(Ofield, mkname(&n->src, sb), typeval(&n->src, t));
					sig = mkn(Otfunc, mkseq(pa, pb), mkname(&n->src, enter("int", 0)));
					sig->src = n->src;
					stmt = mkn(Oret, body, nil);
					stmt->src = n->src;
					fl = mkn(Ofunclit, nil, sig);
					fl->aux = mkn(Oscope, stmt, nil);
					fl->aux->src = n->src;
					fl->src = n->src;
					call = mkn(Ocall, fl, mkseq(n->left, n->right));
					call->src = n->src;
					cmp = call;
				}
			}
			if(cmp == nil){
				nerror(n, "cannot compare %T values: a field has no equality of its own", t);
				n->ty = tbool;
				return n->ty;
			}
			if(n->op == Oneq){
				cmp = mkunary(Onot, cmp);
				cmp->src = n->src;
			}
			*n = *cmp;
			return echk(n);
		}
		else if(t != terror && (t->kind == Tadt || t->kind == Ttuple || t->kind == Tadtpick)){
			/*
			 * no Dis instruction compares a value struct or tuple:
			 * "p == q" compiled to a one-word compare (beqw of the
			 * first field) and reported structs differing in any
			 * later field as equal.  limbo refuses this too;
			 * compare the fields, or compare refs (identity).
			 */
			nerror(n, "cannot compare %T values: compare the fields, or compare refs", t);
		}else if(t != terror && t->kind != Tint && t->kind != Tbig && t->kind != Tbyte
		&& t->kind != Treal && t->kind != Tstring && n->op != Oeq && n->op != Oneq)
			nerror(n, "ordering is not defined on %T", t);
		n->ty = tbool;
		return n->ty;
	case Oandand: case Ooror:
		t = echk(n->left);
		tr = echk(n->right);
		if(!iscond(t) || !iscond(tr))
			nerror(n, "%s needs bool operands, not %T and %T", opname[n->op], t, tr);
		n->ty = tbool;
		return n->ty;
	case Onot:
		t = echk(n->left);
		if(!iscond(t))
			nerror(n, "! needs a bool operand, not %T", t);
		n->ty = tbool;
		return n->ty;
	case Oneg:
		t = echk(n->left);
		if(t->kind != Tint && t->kind != Tbig && t->kind != Treal && t->kind != Tbyte){
			nerror(n, "cannot negate %T", t);
			t = terror;
		}
		/* fold constant negation */
		if(n->left->op == Oconst && !(n->left->flags & NSTR)){
			p = n->left;
			n->op = Oconst;
			n->flags = p->flags;
			if(p->flags & NREAL)
				n->rval = -p->rval;
			else
				n->val = -p->val;
			n->left = nil;
		}
		n->ty = t;
		return n->ty;
	case Oinv:
		t = echk(n->left);
		if(t->kind != Tint && t->kind != Tbig && t->kind != Tbyte){
			nerror(n, "cannot complement %T", t);
			t = terror;
		}
		if(n->left->op == Oconst && !(n->left->flags & (NSTR|NREAL))){
			p = n->left;
			n->op = Oconst;
			n->val = ~p->val;
			n->left = nil;
		}
		n->ty = t;
		return n->ty;
	case Ocond: {
		/* c ? a : b: a and b of one type, either way round */
		Type *ta, *tb;

		condchk(n->left);
		ta = echk(n->right);
		tb = echk(n->aux);
		if(ta == terror || tb == terror){
			n->ty = terror;
			return n->ty;
		}
		if(assignable(ta, tb, n->aux))
			n->ty = ta;
		else if(assignable(tb, ta, n->right))
			n->ty = tb;
		else{
			nerror(n, "conditional arms differ: %T and %T", ta, tb);
			n->ty = terror;
		}
		return n->ty;
	}
	case Oassert: {
		/*
		 * x.(T): T's value when the interface holds one, else nil;
		 * "v, ok := x.(T)" (val 1) gives the pair (value, bool).
		 * the converter stored the receiver in .self and its type's
		 * name in .tag (parse.c's pinterface), so this is
		 *	x != nil && x..tag == "T" ? T(x..self) : nil
		 * with an unchecked reference cast.  x is evaluated at
		 * each mention, like ?.'s operand.
		 */
		Type *tx;
		Node *x, *cond, *yes, *no, *d;

		tx = echk(n->left);
		t = stype(n->right);
		n->right = nil;
		if(tx == terror || t == terror){
			n->ty = terror;
			return n->ty;
		}
		if(!isifacetype(tx)){
			nerror(n, "type assertion needs an interface value, not %T", tx);
			n->ty = terror;
			return n->ty;
		}
		if(isifacetype(t)){
			nerror(n, "type assertion needs a concrete type, not an interface");
			n->ty = terror;
			return n->ty;
		}
		if(t->kind != Tref){
			nerror(n, "type assertion needs a reference type, not %T", t);
			n->ty = terror;
			return n->ty;
		}
		sizetype(t);
		if(n->left->op != Oname){
			/*
			 * not a plain name: evaluated once, as the parameter of
			 * a closure asserting on it:  (func(.as S) T { return .as.(T) })(x)
			 */
			Node *param, *ret, *sig, *inner, *stmt, *fl, *call;
			Sym *an;
			char buf[32];
			static int nasrt;

			seprint(buf, buf+sizeof(buf), ".as%d", nasrt++);
			an = enter(buf, 0);
			param = mkbin(Ofield, mkname(&n->src, an), typeval(&n->src, tx));
			ret = typeval(&n->src, t);
			if(n->val == 1)
				ret = mkn(Ottuple, mkseq(ret, mkname(&n->src, enter("bool", 0))), nil);
			sig = mkn(Otfunc, param, ret);
			sig->src = n->src;
			inner = mkbin(Oassert, mkname(&n->src, an), typeval(&n->src, t));
			inner->val = n->val;
			stmt = mkn(Oret, inner, nil);
			stmt->src = n->src;
			fl = mkn(Ofunclit, nil, sig);
			fl->aux = mkn(Oscope, stmt, nil);
			fl->aux->src = n->src;
			fl->src = n->src;
			call = mkn(Ocall, fl, n->left);
			call->src = n->src;
			*n = *call;
			return echk(n);
		}
		x = n->left;
		x->flags |= NCHECKED;
		d = mkbin(Odot, deepdup(x), mkname(&n->src, enter(".tag", 0)));
		d->sym = d->right->sym;
		cond = mkbin(Oandand, mkbin(Oneq, deepdup(x), mkname(&n->src, enter("nil", 0))),
			mkbin(Oeq, d, mksconst(&n->src, enter(smprint("%T", t), 0))));
		d = mkbin(Odot, x, mkname(&n->src, enter(".self", 0)));
		d->sym = d->right->sym;
		echk(d);
		yes = mkn(Ocast, d, nil);
		yes->src = n->src;
		yes->val = 1;
		yes->ty = t;
		yes->flags |= NCHECKED;
		no = mkname(&n->src, enter("nil", 0));
		if(n->val == 1){
			yes = mkn(Otuple, mkseq(yes, mkname(&n->src, enter("true", 0))), nil);
			yes->src = n->src;
			no = mkn(Otuple, mkseq(no, mkname(&n->src, enter("false", 0))), nil);
			no->src = n->src;
		}
		n->op = Ocond;
		n->left = cond;
		n->right = yes;
		n->aux = no;
		n->val = 0;
		return echk(n);
	}
	case Oqchain: {
		/*
		 * a?.f...: nil when a is, else the chain (right) over the
		 * hidden name (aux) that stands for a.  a plain name is
		 * simply mentioned twice; anything else is evaluated once,
		 * as the parameter of a closure:
		 *	(func(.q S) T { return .q != nil ? chain : nil })(a)
		 * or, for a chain with no value, if .q != nil { chain }.
		 */
		Type *ts, *tc;
		Node *chain, *cond, *fl, *sig, *param, *ret, *stmt, *call, *e;
		Decl *qd;
		Sym *qs;

		ts = echk(n->left);
		if(ts == terror){
			n->ty = terror;
			return n->ty;
		}
		qs = n->aux->sym;
		chain = deepdup(n->right);	/* pristine, for the closure's body */
		pushscope();
		qd = mkdecl(&n->src, Dlocal, ts);
		qd->sym = qs;
		install(qd);
		tc = echk(n->right);	/* the chain's type, the name bound to a's */
		popscope();
		if(tc == terror){
			n->ty = terror;
			return n->ty;
		}
		if(tc->kind == Ttuple){
			nerror(n, "?. cannot yield a tuple");
			n->ty = terror;
			return n->ty;
		}
		if(n->left->op == Oname && tc != tnone){
			/* a plain name: mentioned again in the guard, no closure */
			subst(n->right, qs, n->left);
			cond = mkbin(Oneq, dupn(n->left), mkname(&n->src, enter("nil", 0)));
			cond->src = n->src;
			chain = n->right;
			n->op = Ocond;
			n->left = cond;
			n->right = chain;
			n->aux = zeroval(&n->src, tc);
			n->val = 0;
			return echk(n);
		}
		param = mkbin(Ofield, mkname(&n->src, qs), typeval(&n->src, ts));
		ret = tc == tnone ? nil : typeval(&n->src, tc);
		sig = mkn(Otfunc, param, ret);
		sig->src = n->src;
		cond = mkbin(Oneq, mkname(&n->src, qs), mkname(&n->src, enter("nil", 0)));
		cond->src = n->src;
		if(tc == tnone){
			stmt = mkn(Oif, cond, mkn(Oscope, mkunary(Oexpr, chain), nil));
			stmt->right->src = n->src;
		}else{
			e = mkn(Ocond, cond, chain);
			e->aux = zeroval(&n->src, tc);
			e->src = n->src;
			stmt = mkn(Oret, e, nil);
		}
		stmt->src = n->src;
		fl = mkn(Ofunclit, nil, sig);
		fl->aux = mkn(Oscope, stmt, nil);
		fl->aux->src = n->src;
		fl->src = n->src;
		call = mkn(Ocall, fl, n->left);
		call->src = n->src;
		*n = *call;
		return echk(n);
	}
	case Omaplit: {
		/*
		 * map[K]V{k: v, ...}: .builtin.mput(... .builtin.mput(
		 * .builtin.newmap[K, V](hash, eq), k1, v1) ..., kn, vn),
		 * the hash and equality inline functions chosen by K
		 */
		Node *inst, *kn, *vn, *call, *elem;
		Type *kt;
		char *hs, *es;

		stype(n->left);	/* instantiate and mark the map type (NMAPT) */
		inst = n->left->right;
		kn = inst->right->left;
		vn = inst->right->right;
		kt = stype(kn);
		switch(kt->kind){
		case Tint:
			hs = "inthash";
			es = "inteq";
			break;
		case Tstring:
			hs = "strhash";
			es = "streq";
			break;
		case Tbig:
			hs = "bighash";
			es = "bigeq";
			break;
		case Tbyte:
			hs = "bytehash";
			es = "byteeq";
			break;
		default:
			if(kt != terror)
				nerror(n, "a map key must be an int, big, byte or string, not %T", kt);
			n->ty = terror;
			return n->ty;
		}
		call = mkn(Ocall, mkbin(Otinst, builtinref(&n->src, "newmap"), rotater(mkseq(dupn(kn), dupn(vn)))),
			rotater(mkseq(builtinref(&n->src, hs), builtinref(&n->src, es))));
		call->src = n->src;
		for(p = n->right; p != nil; p = p->right){
			elem = p;
			if(p->op == Oseq)
				elem = p->left;
			call = mkn(Ocall, builtinref(&n->src, "mput"), rotater(mkseq(mkseq(call, elem->left), elem->right)));
			call->src = n->src;
			if(p->op != Oseq)
				break;
		}
		n->op = call->op;
		n->left = call->left;
		n->right = call->right;
		n->aux = nil;
		return echk(n);
	}
	case Oindex:
		t = echk(n->left);
		if(ismaptype(t)){
			p = mapindexcall(n, "get");
			n->op = p->op;
			n->left = p->left;
			n->right = p->right;
			return echk(n);
		}
		echk(n->right);
		if(t->kind == Tarray){
			n->op = Oindx;
			n->ty = t->tof;
			return n->ty;
		}
		if(t->kind == Tstring){
			n->op = Oinds;
			n->ty = tint;	/* rune */
			return n->ty;
		}
		nerror(n, "cannot index %T", t);
		n->ty = terror;
		return n->ty;
	case Oslice:
		t = echk(n->left);
		if(n->right != nil){
			if(n->right->left != nil)
				echk(n->right->left);
			if(n->right->right != nil)
				echk(n->right->right);
		}
		if(t->kind != Tarray && t->kind != Tstring){
			nerror(n, "cannot slice %T", t);
			n->ty = terror;
			return n->ty;
		}
		n->ty = t;
		return n->ty;
	case Ochk: {
		/*
		 * "x?" -- the second half of the user's own answered design
		 * fork (the first, match dispatch, shipped in 84c3ac85):
		 * the first tag in declaration order (Decl.tag == 0) is the
		 * success case, unwrapped; any other tag makes ? return the
		 * whole tagged value from the enclosing function, no new
		 * marker syntax. No limbo convention exists to port -- limbo
		 * has no ? operator at all (Inferno's own idiom is raising
		 * an exception).
		 *
		 * subject must be Tref{Tadt-with-tags}: matches
		 * matchcheck()'s own ref-subject handling, and is the only
		 * shape a real tagged value can actually be constructed as
		 * (the bare, unspecified-tag outer Tadt is never sized --
		 * sizetype(), types.c -- so nothing can be allocated at it
		 * directly; only a specific tag's own Tadtpick, or a ref to
		 * the general adt, are real values). A bare already-narrowed
		 * Tadtpick subject (matchcheck() accepts one; this
		 * deliberately doesn't) is compile-time-known which tag it
		 * is, so ? on it would be a degenerate, always-same-branch
		 * case, not the realistic use -- refused with a clear error
		 * below rather than specially handled.
		 */
		Type *rt, *subj;
		Decl *tag, *fd;
		int nfields;

		rt = echk(n->left);
		subj = rt;
		if(subj != nil && subj->kind == Tref)
			subj = subj->tof;
		if(subj == nil || subj->kind != Tadt || subj->tags == nil
		|| rt->kind != Tref){
			nerror(n, "? requires a ref to a pick adt (e.g. ref Result), not %T", rt);
			n->ty = terror;
			return n->ty;
		}
		/*
		 * curret must be exactly this same general tagged-adt ref
		 * type: a failing "?" returns the subject unchanged, so the
		 * enclosing function's own declared return type has to
		 * already be that type. No conversion is attempted --
		 * unlike Rust's own "?" (a From conversion across differing
		 * error types), no such mechanism exists in this language,
		 * and inventing one is out of scope here.
		 */
		if(!assignable(curret, rt, n->left)){
			nerror(n, "? used in a function returning %T, not %T", curret, rt);
			n->ty = terror;
			return n->ty;
		}
		/*
		 * t->tags is built in declaration order (the Otpick-
		 * processing loop above appends via last->next), so its
		 * head is always the tag with Decl.tag == 0 -- confirmed by
		 * construction, not searched for.
		 */
		tag = subj->tags;
		nfields = 0;
		for(fd = tag->ty->ids; fd != nil; fd = fd->next)
			nfields++;
		if(nfields > 1){
			nerror(n, "? requires %T's success tag %s to have zero or one field, not %d",
				subj, tag->sym->name, nfields);
			n->ty = terror;
			return n->ty;
		}
		fd = tag->ty->ids;	/* nil when nfields == 0 */
		n->decl = fd;		/* stashed for com.c's Ochk case */
		n->ty = fd == nil ? tnone : fd->ty;
		return n->ty;
	}
	case Oref:
		/*
		 * "ref T{...}" is how a composite literal is actually
		 * usable (com.c's Oref case allocates and stores its
		 * fields); go straight to compositefields() rather than
		 * through echk(Ocomposite) below, which exists only to
		 * reject a *bare* composite literal cleanly.
		 */
		if(n->left->op == Ocomposite)
			t = compositefields(n->left);
		else
			t = echk(n->left);
		/*
		 * Tadtpick (a specific tag's own type, "ref Result.Ok{...}")
		 * is a real, valid ref target too -- stype()'s own Otref
		 * case (above) already anticipated this ("ref requires an
		 * adt or function type" accepts Tadtpick alongside Tadt),
		 * this check just hadn't caught up to it yet.
		 */
		if(t->kind != Tadt && t->kind != Tadtpick){
			nerror(n, "ref of non-adt %T", t);
			n->ty = terror;
			return n->ty;
		}
		n->ty = mktype(&n->src, Tref, t, nil);
		/*
		 * unlike Ochan just below (which sizes its freshly-made
		 * type on the spot), this was missing -- and it mattered:
		 * a top-level "x := ref T{...}" never noticed, since
		 * daschk()/local declaration processing sizes x's own type
		 * separately. but a *nested* "ref Outer{in: ref Inner{...}}"
		 * has no declared local for the inner ref -- its type is
		 * only ever consumed by com.c's Oref case for a compiler
		 * temp (talloc(&tres, n->ty, nil), used whenever the outer
		 * literal's own field address isn't a plain addressable
		 * dst) -- so an unsized Tref (size=align=0, mktype's
		 * zero-initialised default) went straight into idoffsets(),
		 * which placed the temp at a zero-width slot overlapping
		 * whatever frame offset came next. the temp's own pointer
		 * then got silently clobbered by that later, unrelated
		 * write (no destroy(), since the overlap was invisible to
		 * both sides), while the frame's gc descriptor still marked
		 * the offset as a live pointer -- a background mark cycle
		 * would eventually dereference whatever garbage the other
		 * write had left there. sizetype() is idempotent (OKsized
		 * guard) so this is a no-op whenever T was already sized.
		 */
		sizetype(n->ty);
		return n->ty;
	case Ochan:
		if(n->left != nil){
			t = echk(n->left);
			if(t->kind != Tint && t != terror)
				nerror(n, "channel size must be int, not %T", t);
		}
		t = mktype(&n->src, Tchan, stype(n->right), nil);
		sizetype(t);
		n->right = nil;	/* type expr consumed; ecom sees only size */
		n->ty = t;
		return n->ty;
	case Oarray:
		t = echk(n->left);
		if(t->kind != Tint && t != terror)
			nerror(n, "array size must be int, not %T", t);
		t = mktype(&n->src, Tarray, stype(n->right), nil);
		sizetype(t);
		n->right = nil;	/* type expr consumed; ecom sees only size */
		if(n->aux != nil){
			/*
			 * "[size]T{v, v, ...}" -- positional-only, no keyed/
			 * sparse form (parse.c's own comment on this grammar
			 * shape explains why): every element must be present,
			 * so the count is checked here rather than left for
			 * com.c to discover at codegen time or, worse, silently
			 * write past/short of the allocated array. requiring
			 * the size to be a literal Oconst (not just any
			 * constant-foldable expression -- this compiler has no
			 * general constant-folding pass to lean on, confold()
			 * only ever runs on a nil comparison) is a real,
			 * deliberate scope boundary: "[n]int{1,2,3}" for a
			 * non-literal n fails loudly here ("must be a
			 * constant"), not silently mismatched against whatever
			 * n turns out to be at runtime.
			 */
			Node *p, *e;
			int nelem;
			Type *ety;

			nelem = 0;
			for(p = n->aux; p != nil; p = p->right){
				e = p;
				if(p->op == Oseq)
					e = p->left;
				ety = echk(e->right);
				if(!assignable(t->tof, ety, e->right))
					nerror(e, "cannot use %T as %T in array composite literal", ety, t->tof);
				nelem++;
				if(p->op != Oseq)
					break;
			}
			if(n->left->op != Oconst || n->left->ty != tint)
				nerror(n, "array composite literal size must be a constant");
			else if(n->left->val != nelem)
				nerror(n, "array size %lld does not match %d elements in composite literal",
					n->left->val, nelem);
		}
		n->ty = t;
		return n->ty;
	case Orcv:
		t = echk(n->left);
		if(t->kind != Tchan){
			nerror(n, "receive from non-channel %T", t);
			n->ty = terror;
			return n->ty;
		}
		n->ty = t->tof;
		return n->ty;
	case Osnd:
		t = echk(n->left);
		tr = echk(n->right);
		if(t->kind != Tchan){
			nerror(n, "send to non-channel %T", t);
			n->ty = terror;
			return n->ty;
		}
		retypetuple(n->right, t->tof);
		if(!assignable(t->tof, tr, n->right))
			nerror(n, "cannot send %T on %T", tr, t);
		n->ty = tnone;
		return n->ty;
	case Ocomposite:
		/*
		 * a bare (non-ref) composite literal in general value
		 * position -- a call argument, "Point{x: 1, y: 2}.x", a
		 * list cons head, anything that isn't the RHS of :=/=/var/
		 * return (each of which stores it straight into its own
		 * destination without ever coming through here).  it was
		 * refused as "not yet supported" until the first test to
		 * pass a struct literal straight to a cross-module call
		 * (tests/type/loadlib.e) tripped over it.  compositefields()
		 * checks and types it; com.c's ecom() Ocomposite case
		 * materializes the value (into the destination when that's
		 * a plain slot, else via a temp), the same two store paths
		 * ":=" already uses.
		 */
		t = compositefields(n);
		n->ty = t;
		return n->ty;
	case Otuple:
		{
			Decl *ids, *last, *d;
			char buf[32];
			int i;

			ids = last = nil;
			i = 0;
			for(p = n->left; p != nil; p = p->right){
				Node *e;

				e = p;
				if(p->op == Oseq)
					e = p->left;
				t = echk(e);
				d = mkdecl(&e->src, Dfield, t);
				seprint(buf, buf+sizeof(buf), "t%d", i++);
				d->sym = enter(buf, 0);
				if(ids == nil)
					ids = d;
				else
					last->next = d;
				last = d;
				if(p->op != Oseq)
					break;
			}
			n->ty = mktype(&n->src, Ttuple, nil, ids);
			/*
			 * sizetype() here, centrally, rather than leaving it to
			 * each of this case's own callers to remember: found via
			 * a real, general segfault, not the field-value case this
			 * was first written for -- a plain "bt = (1, "one")"
			 * reassigning an already-declared tuple-typed local hits
			 * check.c's Oas fallback (echk(n->right) with no
			 * sizetype() of its own), a *different* call site than
			 * compositefields()'s per-field one (which does size it
			 * explicitly, but only there). Oret's own case
			 * (mkn(Oret,...) handling, above) already calls
			 * sizetype() explicitly on exactly this same freshly-
			 * built type too -- redundant with this now (sizetype()'s
			 * own OKsized guard makes a second call a cheap no-op),
			 * left as-is rather than removed, since it's still
			 * correct and touching it isn't needed for this fix.
			 */
			sizetype(n->ty);
			return n->ty;
		}
	case Ofunclit: {
		Decl *ld;

		/*
		 * lift the literal into a fresh top-level Dfn (synthfunclit(),
		 * above) and rewrite this node in place into an ordinary
		 * Oname referring to it -- mutating n directly, not
		 * reassigning some ancestor's pointer to a fresh node, the
		 * same in-place-rewrite style Odot's Oind case (below) already
		 * uses.  synthfunclit() copies n->aux into ld->init->aux
		 * *before* returning -- fncom() (com.c) reads a function's
		 * body from decl->init->aux, never from any Oname's own aux,
		 * so ld's own codegen no longer depends on this node at all --
		 * clear right/aux here so this really is a leaf Oname, not one
		 * with a whole signature and body still dangling off it: left
		 * unset, com.c's generic sumark() walks every node's left/
		 * right unconditionally and crashes ("Oname without decl") on
		 * the signature's own unresolved-decl type-name nodes; aux
		 * doesn't crash anything (sumark never reads it) but a dump
		 * (-a, ast.c's astprint(), which walks left/right/aux on every
		 * node regardless of op) would otherwise print the entire
		 * literal a second time, nested under what claims to be a bare
		 * name.  from here on this node behaves exactly like any other
		 * Dfn-Oname (echk's own Oname case, above) with ld->wrapdecl
		 * == ld already cached, so com.c's ecom() builds its tfnptr
		 * with zero changes: env (t2) stays nil, same as a plain
		 * non-capturing function value -- the capture check inside
		 * synthfunclit() already refused anything else.
		 */
		ld = synthfunclit(n);
		if(ld == nil){
			n->ty = terror;
			return n->ty;
		}
		n->op = Oname;
		n->decl = ld;
		n->sym = ld->sym;
		n->right = nil;
		n->aux = nil;
		n->ty = mktype(&n->src, Tref, ld->ty, nil);
		sizetype(n->ty);	/* see synthfvwrap()'s valty comment: an unsized Tref here silently misled idoffsets() */
		return n->ty;
	}
	case Ocast: {
		/*
		 * left the operand, right the target type node (consumed
		 * here: cleared so sumark never sees a type in value
		 * position, the Oarray/Ochan discipline).  the conversions
		 * are limbo's (types.c's castop()/castvia()): the scalar
		 * kinds among themselves, string<->array of byte, and a
		 * same-type conversion as a plain copy.
		 */
		Type *tt;

		t = stype(n->right);
		n->right = nil;
		tt = echk(n->left);
		if(t == terror || tt == terror){
			n->ty = terror;
			return n->ty;
		}
		sizetype(t);	/* "[]byte(s)": stype() leaves an array type unsized */
		if(n->val == 1){
			/*
			 * the interface converter's .self (parse.c's pinterface)
			 * and x.(T): a reference reinterpreted as another, one
			 * move; nil when the value is not a reference at all
			 */
			if(tt->kind != Tref){
				*n = *mkname(&n->src, enter("nil", 0));
				return echk(n);
			}
			if(isifacetype(tt)){
				/* an interface narrowed to another: the receiver it holds, not the interface itself */
				n->left = mkbin(Odot, n->left, mkname(&n->src, enter(".self", 0)));
				n->left->sym = n->left->right->sym;
				echk(n->left);
			}
			n->ty = t;
			return n->ty;
		}
		if(t->kind == Tarray && tt->kind == Tlist && t->tof != nil && tt->tof != nil && tequal(t->tof, tt->tof)){
			/* "[]T(l)": the list's elements in an array, builtin.ei's toarray */
			Node *call;

			call = mkn(Ocall, builtinref(&n->src, "toarray"), n->left);
			call->src = n->src;
			*n = *call;
			return echk(n);
		}
		if(isifacetype(t) && !tequal(tt, t)){
			/* "Shape(x)": the conversion an assignment would make (assignable() rewrites the operand) */
			if(!assignable(t, tt, n->left)){
				nerror(n, "cannot convert %T to %T", tt, t);
				n->ty = terror;
				return n->ty;
			}
			*n = *n->left;
			return n->ty;
		}
		if(!castable(tt, t)){
			nerror(n, "cannot convert %T to %T", tt, t);
			n->ty = terror;
			return n->ty;
		}
		n->ty = t;
		if(n->left->op == Oconst)
			confoldcast(n);
		return n->ty;
	}
	case Oload: {
		/*
		 * "load Rand path" (or "load rand path", the import alias):
		 * the module type is whichever of the two importchk()
		 * installed -- m itself (a Dtype of Tmodule kind) or the
		 * alias variable v (a Dglobal carrying importid = m).  the
		 * result is a value of that Tmodule type, nil if the load
		 * fails, exactly limbo's own load; com.c's ecom() Oload
		 * case emits the same ILOAD autoload() already emits for
		 * an import's own startup load, with the path coming from
		 * this expression instead of the interface's PATH const.
		 * n->left is consumed here (stashed on n->decl as the
		 * alias/type decl, then cleared) so sumark() never sees a
		 * type name in value position.  deliberately does NOT bump
		 * the alias's refs: an import used only through explicit
		 * loads is never autoloaded at init, so a module whose
		 * PATH may be absent can still be probed for nil.
		 */
		Decl *v;

		if(n->left->op != Oname){
			nerror(n, "load needs a module name");
			n->ty = terror;
			return n->ty;
		}
		v = lookup(n->left->sym);
		if(v == nil || v->ty == nil || v->ty->kind != Tmodule
		|| (v->store != Dtype && v->importid == nil)){
			nerror(n, "%s is not an imported module", n->left->sym->name);
			n->ty = terror;
			return n->ty;
		}
		if(v->store == Dtype){
			/* the type name: find the alias that imported it */
			Dlist *dl;

			for(dl = imports; dl != nil; dl = dl->next)
				if(dl->d->importid == v)
					break;
			if(dl == nil){
				nerror(n, "%s is not an imported module", n->left->sym->name);
				n->ty = terror;
				return n->ty;
			}
			v = dl->d;
		}
		t = echk(n->right);
		if(t != terror && t != tstring){
			nerror(n, "load path must be a string, not %T", t);
			n->ty = terror;
			return n->ty;
		}
		n->decl = v;
		n->left = nil;
		n->ty = v->ty;
		return n->ty;
	}
	case Orange:
		nerror(n, "range is only the right side of a for header's :=");
		n->ty = terror;
		return n->ty;
	default:
		nerror(n, "unsupported expression %O", n->op);
		n->ty = terror;
		return n->ty;
	}
}

/*
 * declare locals for :=
 */
/* a local of that name already in the innermost scope (n := ... twice) */
static int
redeclared(Sym *sym)
{
	Decl *d;

	d = lookup(sym);
	if(d == nil)
		return 0;
	if(d->store == Darg)	/* parameters sit one scope above the body's block */
		return d->scope == scope - 1;
	return d->store == Dlocal && d->scope == scope;
}

/*
 * "_", go's blank identifier: a fresh hidden local the program
 * cannot name, so the value is evaluated and dropped. Renaming the
 * Oname is enough for every declaring form (daschk, rangefor);
 * declblank() also makes the local for an assignment target.
 */
/*
 * map[K]V: the type is builtin's Map[K, V] instantiated (parse.c's
 * pmaptype, stype's Otinst case marking it), and every operation on
 * one is rewritten here into a method call: m[k] is m.get(k), "v, ok
 * := m[k]" is m.lookup(k), "m[k] = v" is m.put(k, v), delete(m, k) is
 * m.del(k), len(m) is m.size(), and range walks m.entries().
 */
static int
ismaptype(Type *t)
{
	return t != nil && t->kind == Tref && t->tof != nil && t->tof->kind == Tadt && t->tof->ismap;
}

/* .builtin.name */
static Node*
builtinref(Src *src, char *name)
{
	Node *n;

	n = mkbin(Odot, mkname(src, enter(".builtin", 0)), mkname(src, enter(name, 0)));
	n->sym = n->right->sym;
	n->src = *src;
	return n;
}

/* recv.meth(args), unchecked */
static Node*
mkmethcall(Src *src, Node *recv, char *meth, Node *args)
{
	Node *dot, *call;

	dot = mkbin(Odot, recv, mkname(src, enter(meth, 0)));
	dot->sym = dot->right->sym;
	dot->src = *src;
	call = mkn(Ocall, dot, args);
	call->src = *src;
	return call;
}

/* the map indexing node n (Oindex, left the map, right the key) as recv.meth(key) */
static Node*
mapindexcall(Node *n, char *meth)
{
	return mkmethcall(&n->src, n->left, meth, n->right);
}

/* is n "m[k]" on a map?  echk's the map expression if so */
static int
ismapindex(Node *n)
{
	return n != nil && n->op == Oindex && ismaptype(echk(n->left));
}

/*
 * a call of a typed variadic function, "func f(sep string, xs ...T)":
 * the arguments past the fixed ones become one array literal (an
 * Oarray whose element type is given by an Otypeval), or "xs..."
 * passes an array through; arg is the first parameter the caller
 * writes (the env parameter of a value call already skipped)
 */
static void
packvarargs(Node *n, Decl *arg)
{
	Node *a, *e, *fixed, *elems, *arr, *tv, *last;
	Decl *pd;
	Type *at;
	int nfixed, nargs, k;

	nfixed = -1;
	at = nil;
	for(pd = arg; pd != nil; pd = pd->next){
		nfixed++;
		at = pd->ty;
	}
	if(at == nil || at->kind != Tarray)
		return;
	nargs = 0;
	last = nil;
	for(a = n->right; a != nil; a = a->right){
		last = a->op == Oseq ? a->left : a;
		nargs++;
		if(a->op != Oseq)
			break;
	}
	if(last != nil && (last->flags & NVARARG)){
		if(nargs != nfixed + 1)
			nerror(last, "xs... must be the last argument, after the fixed ones");
		last->flags &= ~NVARARG;
		return;
	}
	fixed = nil;
	elems = nil;
	k = 0;
	for(a = n->right; a != nil; a = a->right){
		e = a->op == Oseq ? a->left : a;
		if(elems == nil && nargsfixed(fixed) < nfixed)
			fixed = mkseq(fixed, e);
		else{
			elems = mkseq(elems, mkn(Oelem, nil, e));
			k++;
		}
		if(a->op != Oseq)
			break;
	}
	tv = mkn(Otypeval, nil, nil);
	tv->ty = at->tof;
	tv->src = n->src;
	arr = mkn(Oarray, mkconst(&n->src, k), tv);
	arr->aux = rotater(elems);
	arr->src = n->src;
	n->right = rotater(mkseq(fixed, arr));
}

/* how many nodes a left-nested mkseq chain holds */
static int
nargsfixed(Node *seq)
{
	int k;

	for(k = 0; seq != nil; seq = seq->left){
		k++;
		if(seq->op != Oseq)
			break;
	}
	return k;
}

static int
isifacetype(Type *t)
{
	return t != nil && t->kind == Tref && t->tof != nil && t->tof->kind == Tadt && t->tof->isiface;
}

/*
 * does s (a ref to a struct or pick) have every method the interface
 * t lists, with the same parameters and results?  the closure field
 * types carry an env parameter first, the methods their receiver.
 */
static int
implements(Type *s, Type *t, Node *v)
{
	Type *adt, *ft;
	Decl *f, *m, *fp, *mp;

	adt = s->named ? s : s->tof;	/* "type Color int" carries its methods itself */
	if(adt->kind == Tadtpick)
		adt = adt->tof;
	if(adt->isiface){
		/* another interface: its fields must include t's, with the same types */
		for(f = t->tof->ids; f != nil; f = f->next){
			if(f->sym->name[0] == '.')
				continue;
			for(m = adt->ids; m != nil; m = m->next)
				if(m->sym == f->sym)
					break;
			if(m == nil){
				nerror(v, "%T does not implement %T: no method %s", s, t, f->sym->name);
				return 0;
			}
			if(!tequal(f->ty, m->ty)){
				nerror(v, "%T does not implement %T: method %s has the wrong signature", s, t, f->sym->name);
				return 0;
			}
		}
		return 1;
	}
	for(f = t->tof->ids; f != nil; f = f->next){
		if(f->sym->name[0] == '.')
			continue;	/* .self and .tag, the converter's own */
		for(m = adt->meths; m != nil; m = m->link)
			if(m->sym == f->sym)
				break;
		if(m == nil && adt->gtemplate != nil){
			Decl *mtd;

			/* a generic struct's method, instantiated on demand as a call would */
			for(mtd = adt->gtemplate->methtmpl; mtd != nil; mtd = mtd->link)
				if(mtd->sym == f->sym){
					m = tinstantiatemeth(mtd, adt);
					break;
				}
		}
		if(m == nil){
			nerror(v, "%T does not implement %T: no method %s", s, t, f->sym->name);
			return 0;
		}
		ft = f->ty->tof;
		fp = ft->ids->next;
		mp = m->ty->ids->next;
		for(; fp != nil && mp != nil; fp = fp->next, mp = mp->next)
			if(!tequal(fp->ty, mp->ty))
				break;
		if(fp != nil || mp != nil || !tequal(ft->tof, m->ty->tof)){
			nerror(v, "%T does not implement %T: method %s has the wrong signature", s, t, f->sym->name);
			return 0;
		}
	}
	return 1;
}

/* v becomes .Name$from(v), through the alias when the interface is imported */
static void
ifaceconv(Node *v, Type *t)
{
	Node *callee, *c, *a;
	Decl *m;
	Dlist *dl;
	char buf[StrSize];

	Type *tmpl;

	/* the struct is .W$s (parse.c's pinterface): the converter is .W$from; an instance of a generic one names its template */
	tmpl = t->tof;
	if(tmpl->gtemplate != nil)
		tmpl = tmpl->gtemplate;
	seprint(buf, buf+sizeof(buf), "%s", tmpl->decl->sym->name);
	buf[strlen(buf) - 2] = 0;
	strcat(buf, "$from");
	m = tmpl->decl->dot;
	if(m != nil && m != impdecl && m->ty != nil && m->ty->kind == Tmodule){
		for(dl = imports; dl != nil; dl = dl->next)
			if(dl->d->importid == m)
				break;
		if(dl == nil)
			fatal("ifaceconv: no alias for %s", m->sym->name);
		callee = mkbin(Odot, mkname(&v->src, dl->d->sym), mkname(&v->src, enter(buf, 0)));
		callee->sym = callee->right->sym;
	}else
		callee = mkname(&v->src, enter(buf, 0));
	callee->src = v->src;
	a = dupn(v);
	a->flags |= NCHECKED;	/* v was checked: its type nodes are consumed, do not check the copy again */
	if(a->ty != nil && a->ty->kind == Tref && a->ty->tof != nil && a->ty->tof->kind == Tadtpick){
		/* a tag value stands for its pick: the methods are the pick's */
		a->ty = mktype(&v->src, Tref, a->ty->tof->tof, nil);
		sizetype(a->ty);
	}
	if(t->tof->ginst != nil){
		/* a generic interface: the converter's parameters are .T then the interface's own, given outright */
		Node *targs, *tv;
		int i;

		tv = mkn(Otypeval, nil, nil);
		tv->ty = a->ty;
		tv->src = v->src;
		targs = tv;
		for(i = 0; i < t->tof->ginst->nargs; i++){
			tv = mkn(Otypeval, nil, nil);
			tv->ty = t->tof->ginst->args[i];
			tv->src = v->src;
			targs = mkseq(targs, tv);
		}
		callee = mkbin(Otinst, callee, rotater(targs));
		callee->src = v->src;
	}
	c = mkn(Ocall, callee, a);
	c->src = v->src;
	*v = *c;
	echk(v);
}

/*
 * match guards, "case Num(v) if v > 0:".  the case table dispatches
 * on the value once, so a guarded arm becomes "if guard { body }
 * else { match again over the arms after it }", and the arms after
 * it also form the outer match's default, so a value the guard
 * refuses reaches them either way.  the subject is bound to a hidden
 * local first so it is evaluated once.
 */
static int nguard;

static Node*
guardarms(Node *subj, Node *arms)
{
	Node *out, *p, *arm, *rest, *nested, *ifn, *def, *body;

	out = nil;
	for(p = arms; p != nil; p = p->right){
		arm = p->op == Oseq ? p->left : p;
		if(arm->aux == nil){
			out = mkseq(out, arm);
			if(p->op != Oseq)
				break;
			continue;
		}
		rest = p->op == Oseq ? p->right : nil;
		nested = nil;
		if(rest != nil){
			nested = mkn(Omatch, dupn(subj), guardarms(subj, rest));
			nested->src = arm->src;
		}
		body = mkn(Oscope, arm->right, nil);
		body->src = arm->src;
		ifn = mkn(Oif, arm->aux, body);
		ifn->src = arm->src;
		if(nested != nil){
			ifn->aux = mkn(Oscope, nested, nil);
			ifn->aux->src = arm->src;
		}
		arm->right = ifn;
		arm->aux = nil;
		out = mkseq(out, arm);
		if(nested != nil){
			def = mkn(Ocase, nil, deepdup(nested));
			def->src = arm->src;
			out = mkseq(out, def);
		}
		break;
	}
	return rotater(out);
}

static int
lowerguards(Node *n)
{
	Node *p, *arm, *name, *das, *m;
	char buf[32];

	for(p = n->right; p != nil; p = p->right){
		arm = p->op == Oseq ? p->left : p;
		if(arm->aux != nil)
			break;
		if(p->op != Oseq)
			return 0;
	}
	if(p == nil)
		return 0;
	seprint(buf, buf+sizeof(buf), ".g%d", nguard++);
	name = mkname(&n->src, enter(buf, 0));
	das = mkbin(Odas, name, n->left);
	das->src = n->src;
	m = mkn(Omatch, mkname(&n->src, name->sym), guardarms(name, n->right));
	m->src = n->src;
	n->op = Oscope;
	n->left = mkseq(das, m);
	n->right = nil;
	n->aux = nil;
	return 1;
}

/*
 * "fs[i](x)": an index into an array of function values, not a
 * generic instantiation "f[T](x)" -- the two parse alike
 */
static int
isidxcall(Node *c)
{
	Decl *d;

	if(c->op != Oindex || c->left->op != Oname)
		return 0;
	d = lookup(c->left->sym);
	return d != nil && !(d->store == Dfn && d->tparams != nil);
}

static Sym*
blanksym(void)
{
	char buf[32];
	static int nblank;

	seprint(buf, buf+sizeof(buf), ".blank%d", nblank++);
	return enter(buf, 0);
}

static int
isblank(Node *n)
{
	return n != nil && n->op == Oname && strcmp(n->sym->name, "_") == 0;
}

static void
declhidden(Node *id, Type *t)
{
	Decl *d;

	sizetype(t);
	d = mkdecl(&id->src, Dlocal, t);
	d->sym = id->sym;
	install(d);
	id->decl = d;
	id->ty = t;
	d->link = nil;
	if(curfn->locals == nil)
		curfn->locals = d;
	else{
		Decl *e;

		for(e = curfn->locals; e->link != nil; e = e->link)
			;
		e->link = d;
	}
}

static void
declblank(Node *id, Type *t)
{
	id->sym = blanksym();
	declhidden(id, t);
}

/*
 * defer: a hidden local list (.defers) of the function's deferred
 * closures, each defer consing onto it; fnchk() runs the list, so
 * last first, at every return
 */
/*
 * the named types this module declares methods on ("func (c Color)
 * name() ..."): typedec gives those a type of their own, so a name
 * whose body is not a struct can still carry methods
 */
static Sym **methnames;
static int nmethnames, lenmethnames;

static void
findmethnames(Node *tree)
{
	Node *p, *d, *rty;

	nmethnames = 0;
	for(p = tree->right; p != nil; p = p->right){
		d = p->op == Oseq ? p->left : p;
		if(d->op == Ofndecl && d->left->op == Omethod){
			rty = d->left->left->right;
			if(rty->op == Oname){
				if(nmethnames >= lenmethnames){
					lenmethnames = nmethnames + 32;
					methnames = reallocmem(methnames, lenmethnames * sizeof *methnames);
				}
				methnames[nmethnames++] = rty->sym;
			}
		}
		if(p->op != Oseq)
			break;
	}
}

static int
hasmeths(Sym *s)
{
	int i;

	for(i = 0; i < nmethnames; i++)
		if(methnames[i] == s)
			return 1;
	return 0;
}

static Decl *deferlist;

/* a type as a node: stype() gives it back (Otypeval) */
static Node*
typeval(Src *src, Type *t)
{
	Node *n;

	n = mkn(Otypeval, nil, nil);
	n->ty = t;
	n->src = *src;
	return n;
}

/*
 * every unchecked mention of s in n becomes a copy of val: the
 * hidden name of a ?. chain, which "??" may have deepdup'ed, so the
 * occurrences cannot be found by pointer
 */
static void
subst(Node *n, Sym *s, Node *val)
{
	if(n == nil)
		return;
	if(n->op == Oname && n->sym == s){
		*n = *dupn(val);
		return;
	}
	subst(n->left, s, val);
	subst(n->right, s, val);
	subst(n->aux, s, val);
}

/*
 * "f := c.get": a method used as a value becomes the closure a
 * programmer would write, the receiver evaluated once and captured
 *
 *	func(.mp0 P0, ...) R { return .mv.get(.mp0, ...) }
 *
 * over the receiver itself when it is a name, or over the parameter
 * of an immediately-called wrapper when it is any other expression
 */
static Type*
methvalue(Node *n, Decl *meth)
{
	Node *recv, *rn, *params, *args, *sig, *call, *stmt, *fl, *dot, *outer, *osig, *ocall;
	Decl *id;
	Src *src;
	char buf[32];
	static int nmv;
	int i, isname;

	src = &n->src;
	recv = n->left;
	isname = recv->op == Oname;
	seprint(buf, buf+sizeof(buf), ".mv%d", nmv++);
	rn = mkname(src, enter(buf, 0));
	params = nil;
	args = nil;
	i = 0;
	for(id = meth->ty->ids != nil ? meth->ty->ids->next : nil; id != nil; id = id->next){
		Node *pn;

		seprint(buf, buf+sizeof(buf), ".mp%d", i++);
		pn = mkname(src, enter(buf, 0));
		params = mkseq(params, mkbin(Ofield, pn, typeval(src, id->ty)));
		args = mkseq(args, mkname(src, pn->sym));
	}
	sig = mkn(Otfunc, rotater(params), meth->ty->tof != nil && meth->ty->tof != tnone ? typeval(src, meth->ty->tof) : nil);
	sig->src = *src;
	dot = mkbin(Odot, isname ? dupn(recv) : mkname(src, rn->sym), mkname(src, meth->sym));
	dot->sym = meth->sym;
	dot->src = *src;
	call = mkn(Ocall, dot, rotater(args));
	call->src = *src;
	if(meth->ty->tof != nil && meth->ty->tof != tnone)
		stmt = mkn(Oret, call, nil);
	else
		stmt = mkunary(Oexpr, call);
	stmt->src = *src;
	fl = mkn(Ofunclit, nil, sig);
	fl->aux = mkn(Oscope, stmt, nil);
	fl->aux->src = *src;
	fl->src = *src;
	if(isname){
		*n = *fl;
		return echk(n);
	}
	/* (func(.mv T) fnvalue { return <closure> })(recv) */
	osig = mkn(Otfunc, mkbin(Ofield, mkname(src, rn->sym), typeval(src, recv->ty)), deepdup(sig));
	osig->src = *src;
	outer = mkn(Ofunclit, nil, osig);
	outer->aux = mkn(Oscope, mkn(Oret, fl, nil), nil);
	outer->aux->src = *src;
	outer->aux->left->src = *src;
	outer->src = *src;
	ocall = mkn(Ocall, outer, recv);
	ocall->src = *src;
	*n = *ocall;
	return echk(n);
}

/* what a?.f yields when a is nil: nil, or the zero of a type that has none */
static Node*
zeroval(Src *src, Type *t)
{
	Node *n;

	switch(t->kind){
	case Tint:
	case Tbyte:
	case Tbig:
		return mkconst(src, 0);
	case Treal:
		return mkrconst(src, 0.0);
	case Tbool:
		return mkname(src, enter("false", 0));
	}
	n = mkname(src, enter("nil", 0));
	return n;
}

static Node*
mkdeclname(Src *src, Decl *d)
{
	Node *n;

	n = mkname(src, d->sym);
	n->decl = d;
	return n;
}

/* .l := .defers; for .l != nil { .f := hd(.l); .f(); .l = tl(.l) } */
static Node*
defercalls(Src *src)
{
	Node *das, *cond, *body, *loop, *l, *f;
	Sym *ls, *fs;
	char buf[32];
	static int ndc;

	seprint(buf, buf+sizeof(buf), ".dl%d", ndc);
	ls = enter(buf, 0);
	seprint(buf, buf+sizeof(buf), ".df%d", ndc++);
	fs = enter(buf, 0);
	das = mkbin(Odas, mkname(src, ls), mkdeclname(src, deferlist));
	cond = mkbin(Oneq, mkname(src, ls), mkname(src, enter("nil", 0)));
	f = mkbin(Odas, mkname(src, fs), mkn(Ocall, mkname(src, enter("hd", 0)), mkname(src, ls)));
	body = mkseq(f, mkunary(Oexpr, mkn(Ocall, mkname(src, fs), nil)));
	l = mkbin(Oas, mkname(src, ls), mkn(Ocall, mkname(src, enter("tl", 0)), mkname(src, ls)));
	body = mkseq(body, l);
	body = mkn(Oscope, rotater(body), nil);
	body->src = *src;
	loop = mkn(Ofor, cond, body);
	loop->src = *src;
	return rotater(mkseq(das, loop));
}

/*
 * replace every return in the body (not in closures: their literals
 * are already lifted and left as Oname) with the defers followed by
 * the return, the value saved first so the defers cannot change it
 */
static void
deferrets(Node **np)
{
	Node *n, *r, *ret, *val;
	char buf[32];
	static int nret;

	n = *np;
	if(n == nil)
		return;
	switch(n->op){
	case Oret:
		if(n->left != nil){
			seprint(buf, buf+sizeof(buf), ".ret%d", nret++);
			val = mkname(&n->src, enter(buf, 0));
			ret = mkn(Oret, mkname(&n->src, val->sym), nil);
			ret->src = n->src;
			r = mkseq(mkbin(Odas, val, n->left), defercalls(&n->src));
			r = mkseq(r, ret);
		}else{
			ret = mkn(Oret, nil, nil);
			ret->src = n->src;
			r = mkseq(defercalls(&n->src), ret);
		}
		r = mkn(Oscope, rotater(r), nil);
		r->src = n->src;
		*np = r;
		stchk(r);
		return;
	case Oscope:
	case Oseq:
	case Oif:
	case Ofor:
	case Omatch:
	case Oalt:
	case Ocase:
	case Otry:
	case Olabel:
		deferrets(&n->left);
		deferrets(&n->right);
		deferrets(&n->aux);
		return;
	}
}

static void
daschk(Node *n)
{
	Type *t;
	Decl *d;
	Node *lhs;

	lhs = n->left;
	if(lhs->op == Oseq){
		/*
		 * "n, s := multi()": destructure a multi-valued call's
		 * result into fresh locals, one per name, typed from the
		 * RHS's Ttuple fields in order.  scom's Odas case (com.c)
		 * does the actual destructuring at codegen time -- call the
		 * RHS once into a fresh tuple-shaped temp, then copy each
		 * field out.  general "a, b = ..." (existing variables, via
		 * plain Oas) isn't supported yet: only := guarantees every
		 * LHS name is a fresh Oname, the same scoping this function
		 * already relies on for its single-name path below.
		 */
		Node *p, *id;
		Decl *fd;
		int nlhs, nrhs;

		/* "v, ok := m[k]": m.lookup(k) */
		if(ismapindex(n->right))
			n->right = mapindexcall(n->right, "lookup");
		/* "a, b := 1, 2": see the Oas case's note on expression lists */
		if(n->right->op == Oseq)
			n->right = mkn(Otuple, n->right, nil);
		t = echk(n->right);
		if(t->kind != Ttuple){
			nerror(n, "multiple assignment needs a multi-valued call or an expression list on the right, not %T", t);
			return;
		}
		nlhs = 0;
		for(p = lhs; p != nil; p = p->right){
			nlhs++;
			if(p->op != Oseq)
				break;
		}
		nrhs = 0;
		for(fd = t->ids; fd != nil; fd = fd->next)
			nrhs++;
		if(nlhs != nrhs){
			nerror(n, "assignment count mismatch: %d = %d", nlhs, nrhs);
			return;
		}
		fd = t->ids;
		for(p = lhs; p != nil; p = p->right){
			id = p;
			if(p->op == Oseq)
				id = p->left;
			if(id->op != Oname){
				nerror(n, "unsupported := form");
				return;
			}
			if(isblank(id))
				id->sym = blanksym();
			sizetype(fd->ty);
			if(redeclared(id->sym))
				nerror(id, "%s is already declared in this scope", id->sym->name);
			d = mkdecl(&id->src, Dlocal, fd->ty);
			d->sym = id->sym;
			install(d);
			id->decl = d;
			id->ty = fd->ty;

			d->link = nil;
			if(curfn->locals == nil)
				curfn->locals = d;
			else{
				Decl *e;

				for(e = curfn->locals; e->link != nil; e = e->link)
					;
				e->link = d;
			}
			fd = fd->next;
			if(p->op != Oseq)
				break;
		}
		n->ty = t;
		return;
	}
	if(lhs->op != Oname){
		nerror(n, "unsupported := form");
		return;
	}
	if(isblank(lhs))
		lhs->sym = blanksym();
	/*
	 * "p := Point{x: 1, y: 2}": same reasoning as Ovardecl's case
	 * above -- go through compositefields() directly so a value
	 * composite literal is usable here (there's a fresh local's
	 * frame slot to store into, in scom's Odas case, com.c), rather
	 * than echk() hitting the general Ocomposite case and refusing
	 * it as a bare value.
	 */
	t = n->right->op == Ocomposite ? compositefields(n->right) : echk(n->right);
	if(t == tnone){
		nerror(n, ":= of a void expression");
		t = terror;
	}
	if(t == tany){
		nerror(n, ":= of nil needs a type");
		t = terror;
	}
	if(t->kind == Tfn){
		/* only a method reached through a receiver has a bare Tfn
		 * type here (a function value is Tref{Tfn}): "g := p.get"
		 * would leave g uncallable ("not enough arguments") */
		nerror(n, "a method is not a value: call it, or wrap it in a closure");
		t = terror;
	}
	sizetype(t);
	if(redeclared(lhs->sym))
		nerror(lhs, "%s is already declared in this scope", lhs->sym->name);
	d = mkdecl(&lhs->src, Dlocal, t);
	d->sym = lhs->sym;
	install(d);
	lhs->decl = d;
	lhs->ty = t;
	n->ty = t;

	/* record the local on the current function (link, not next) */
	d->link = nil;
	if(curfn->locals == nil)
		curfn->locals = d;
	else{
		Decl *e;

		for(e = curfn->locals; e->link != nil; e = e->link)
			;
		e->link = d;
	}
}

/*
 * walk comma-separated patterns in an Ocase left.
 * for a single pattern, pats is the pattern node itself.
 */
static Node*
nextpat(Node **pp)
{
	Node *n, *q;

	n = *pp;
	if(n == nil)
		return nil;
	if(n->op == Oseq){
		q = n->left;
		*pp = n->right;
		return q;
	}
	*pp = nil;
	return n;
}

static int
casecmp(Type *ty, Node *a, Node *b)
{
	/*
	 * string labels compare by their text (the Oconst's own sym;
	 * no global decl exists yet at check time): byte order of
	 * UTF-8 is code-point order, which is what the VM's casec
	 * (libinterp/xec.c, stringcmp() on runes) binary-searches by.
	 */
	if(ty == tstring)
		return strcmp(a->sym->name, b->sym->name);
	if(a->val < b->val)
		return -1;
	if(a->val > b->val)
		return 1;
	return 0;
}

static void
casesort(Type *t, Label *aux, Label *labs, int start, int stop)
{
	int n, top, mid, base;

	n = stop - start;
	if(n <= 1)
		return;
	top = mid = start + n / 2;
	casesort(t, aux, labs, start, top);
	casesort(t, aux, labs, mid, stop);
	n = 0;
	base = start;
	while(base < top && mid < stop){
		if(casecmp(t, labs[base].start, labs[mid].start) <= 0)
			aux[n++] = labs[base++];
		else
			aux[n++] = labs[mid++];
	}
	if(base < top)
		memmove(&aux[n], &labs[base], (top-base) * sizeof *aux);
	else if(mid < stop)
		memmove(&aux[n], &labs[mid], (stop-mid) * sizeof *aux);
	memmove(&labs[start], &aux[0], (stop-start) * sizeof *labs);
}

static Case*
matchlabels(Node *arms, Type *ctype, int nlab)
{
	Node *p, *arm, *pat, *q, *wild, *stop;
	Label *labs, *aux;
	Case *c;
	int i, e;

	labs = allocmem(nlab * sizeof *labs);
	memset(labs, 0, nlab * sizeof *labs);
	i = 0;
	wild = nil;
	for(p = arms; p != nil; ){
		arm = p;
		if(p->op == Oseq){
			arm = p->left;
			p = p->right;
		}else
			p = nil;
		if(arm->left == nil){
			wild = arm;
			continue;
		}
		for(pat = arm->left; (q = nextpat(&pat)) != nil; ){
			labs[i].start = q->op == Orange ? q->left : q;
			labs[i].stop = q->op == Orange ? q->right : q;
			labs[i].node = arm;
			i++;
		}
	}
	if(i != nlab)
		fatal("matchlabels: bad label count %d vs %d", nlab, i);

	aux = allocmem(nlab * sizeof *aux);
	casesort(ctype, aux, labs, 0, nlab);
	for(i = 0; i < nlab; i++){
		stop = labs[i].stop;
		if(casecmp(ctype, labs[i].start, stop) > 0)
			nerror(labs[i].start, "unmatchable case label");
		for(e = i + 1; e < nlab; e++){
			if(casecmp(ctype, labs[e].start, stop) <= 0){
				if(ctype == tstring)
					nerror(labs[e].start, "duplicate case label \"%s\"", labs[e].start->sym->name);
				else
					nerror(labs[e].start, "case label %lld overlaps %lld",
						(vlong)labs[e].start->val, (vlong)stop->val);
			}
			if(ctype->kind != Tint
			|| labs[e].start->val != stop->val+1
			|| labs[e].node != labs[i].node)
				break;
			stop = labs[e].stop;
		}
		if(e != i + 1){
			labs[i].stop = stop;
			memmove(&labs[i+1], &labs[e], (nlab-e) * sizeof *labs);
			nlab -= e - (i + 1);
		}
	}
	free(aux);

	c = allocmem(sizeof *c);
	memset(c, 0, sizeof *c);
	c->nlab = nlab;
	c->labs = labs;
	c->wild = wild;
	return c;
}

/*
 * alt: every arm's guard is a send ("c <- e"), a bare receive
 * ("<-c"), or a receive into a fresh (":=") or existing ("=")
 * variable; at most one default (which makes it non-blocking).  each
 * arm's aux is set to its communication node (the Osnd or Orcv) for
 * com.c's altcom(), which builds the Dis alt table from it; the
 * guard's own statement shape (Odas/Oas) only says where a received
 * value lands.  n->ty becomes the Talt whose Case counts the arms,
 * sends first (the table's own layout, and the VM's arm numbering).
 */
static void
altcheck(Node *n)
{
	Node *p, *arm, *g, *comm, *wild;
	Case *c;
	int nsnd, nrcv, ok;

	ok = 1;
	nsnd = nrcv = 0;
	wild = nil;
	for(p = n->right; p != nil; ){
		arm = p;
		if(p->op == Oseq){
			arm = p->left;
			p = p->right;
		}else
			p = nil;
		g = arm->left;
		arm->aux = nil;
		if(g == nil){
			if(wild != nil)
				nerror(arm, "alt has more than one default");
			wild = arm;
			pushscope();
			stchk(arm->right);
			popscope();
			continue;
		}
		pushscope();
		comm = nil;
		switch(g->op){
		case Osnd:
			echk(g);
			if(g->ty != terror){
				comm = g;
				nsnd++;
			}else
				ok = 0;
			break;
		case Oexpr:
			if(g->left->op != Orcv)
				goto bad;
			echk(g->left);
			if(g->left->ty != terror){
				comm = g->left;
				nrcv++;
			}else
				ok = 0;
			break;
		case Odas:
			if(g->left->op != Oname || g->right->op != Orcv)
				goto bad;
			daschk(g);
			if(g->ty != terror && g->right->ty != terror && g->left->decl != nil){
				comm = g->right;
				nrcv++;
			}else
				ok = 0;
			break;
		case Oas:
			if(g->left->op == Oseq || g->right->op != Orcv)
				goto bad;
			stchk(g);
			if(g->left->ty != terror && g->right->ty != terror){
				comm = g->right;
				nrcv++;
			}else
				ok = 0;
			break;
		default:
		bad:
			nerror(g, "alt case must be a send, a receive, or a receive into a variable");
			ok = 0;
			break;
		}
		arm->aux = comm;
		stchk(arm->right);
		popscope();
	}
	if(!ok)
		return;
	c = allocmem(sizeof *c);
	memset(c, 0, sizeof *c);
	c->nlab = nsnd + nrcv;
	c->nsnd = nsnd;
	c->wild = wild;
	c->labs = allocmem((c->nlab + 1) * sizeof(Label));
	memset(c->labs, 0, (c->nlab + 1) * sizeof(Label));
	n->ty = mktalt(c);
}

/*
 * does a binder-less match pattern name a pick tag ("Expr.Num",
 * "lib.Shape.Rect") rather than a constant ("Eandand", "lex.Eid")?
 * a tag's qualifier is a type (or a module then a type); a constant's
 * is nothing or a module alias.
 */
static int
istagname(Node *n)
{
	Decl *d;

	if(n == nil)
		return 0;
	if(n->op == Oname){
		d = lookup(n->sym);
		return d != nil && d->store == Dtype;
	}
	if(n->op == Odot){
		if(n->left->op == Odot)
			return 1;	/* mod.Adt.Tag */
		if(n->left->op == Oindex || n->left->op == Otinst)
			return istagname(n->left->left);	/* Result[int].Ok */
		if(n->left->op != Oname)
			return 0;
		d = lookup(n->left->sym);
		if(d != nil && d->ty != nil && d->ty->kind == Tmodule && ismodvar(d)){
			/* alias.Type: a module's type, generic or not */
			d = modmember(d->ty, n->sym);
			return d != nil && d->store == Dtype;
		}
		return d != nil && d->store == Dtype;
	}
	return 0;
}

static void
matchcheck(Node *n)
{
	Type *t, *pt, *ct, *subj;
	Node *p, *arm, *pat, *q, *wild;
	Case *c;
	int nlab, ok, isref;

	t = echk(n->left);
	ok = 1;
	/*
	 * a tagged-adt subject ("match r { case Result.Ok(v): ...; case
	 * Result.Err(e): ... }") is dispatched by reading its tag word --
	 * a plain int, at offset 0 by sizetype()'s own layout -- and
	 * reusing the *identical* int-label Tcase/casecom() machinery a
	 * plain "match i { case 1: ...; case 2: ... }" already uses
	 * (advisor-recommended over a separate compare-and-branch chain:
	 * the tag word already IS an int, this table already exists).
	 * check.c's own job here is just resolving the subject's real
	 * type and validating/binding each Opat pattern; com.c's casecom()
	 * (below) does the actual tag-word extraction and per-arm binder
	 * copy at codegen time, off the ORIGINAL subject expression (kept
	 * around via Case.tagof, not thrown away here).
	 */
	subj = t;
	isref = t != nil && t->kind == Tref;
	if(isref)
		subj = t->tof;
	/*
	 * a bare (non-ref) Tadtpick subject -- an already-narrowed-to-one-
	 * tag value, e.g. "r := mk(); match r {...}" where mk() returns a
	 * plain (not ref) Result -- widens the same way "ref
	 * Result.Ok{...}" already does for assignable() (see that
	 * function's own comment): the specific tag's own outer adt is
	 * what actually matters for validating each Opat pattern belongs
	 * to the same pick type, same as the ref case just above.
	 */
	if(subj != nil && subj->kind == Tadtpick)
		subj = subj->tof;
	if(subj == nil || subj->kind != Tadt || subj->tags == nil)
		subj = nil;
	if(subj == nil && t->kind != Tint && t->kind != Tstring && t != terror){
		nerror(n, "match subject must be int, string or a tagged adt, not %T", t);
		ok = 0;
	}
	wild = nil;
	nlab = 0;
	for(p = n->right; p != nil; ){
		int npat;

		arm = p;
		if(p->op == Oseq){
			arm = p->left;
			p = p->right;
		}else
			p = nil;
		if(arm->left == nil){
			if(wild != nil)
				nerror(arm, "match has more than one default");
			wild = arm;
		}else{
			npat = 0;
			for(pat = arm->left; (q = nextpat(&pat)) != nil; npat++){
				if(q->op == Orange){
					/* lo...hi: both int constants */
					echk(q->left);
					echk(q->right);
					if(q->left->op != Oconst || q->right->op != Oconst || q->left->ty != tint || q->right->ty != tint){
						nerror(q, "a case range needs two int constants");
						ok = 0;
						continue;
					}
					q->ty = tint;
					nlab++;
					continue;
				}
				if(q->op == Opat && q->right == nil && !istagname(q->left)){
					/*
					 * "case Eandand:" / "case lex.Eid:": a name
					 * (or module member) that is a constant, not a
					 * tag -- the parser can't tell the two apart.
					 * echk() folds a constant name into its literal
					 * (confold()); the pattern becomes that label.
					 */
					echk(q->left);
					if(q->left->op == Oconst){
						Node *lab;

						lab = q->left;
						q->op = Oconst;
						q->flags = lab->flags;
						q->val = lab->val;
						q->rval = lab->rval;
						q->sym = lab->sym;
						q->ty = lab->ty;
						q->left = q->right = nil;
						q->decl = nil;
					}else{
						nerror(q, "case label is not a constant or a tag");
						ok = 0;
						continue;
					}
				}
				if(q->op == Opat){
					Type *tagty;
					Decl *fd, *bp;
					Node *bn;

					if(subj == nil){
						nerror(q, "tag pattern needs a tagged-adt match subject");
						ok = 0;
						continue;
					}
					if(npat != 0 || pat != nil){
						/*
						 * "case Result.Ok(v), Result.Err(e):" or
						 * "case Result.Ok(v), 3:" -- combining a tag
						 * pattern with anything else in one arm would
						 * need each combined pattern to bind the SAME
						 * names to potentially differently-typed
						 * fields; deliberately not attempted, refused
						 * cleanly rather than picked one meaning
						 * unsupervised. a tag pattern must be the
						 * only pattern in its own arm.
						 */
						nerror(q, "a tag pattern must be the only pattern in its case");
						ok = 0;
						continue;
					}
					tagty = stype(q->left);
					if(tagty->kind != Tadtpick || tagty->tof != subj){
						nerror(q, "%T is not a tag of the match subject's type %T", tagty, subj);
						ok = 0;
						continue;
					}
					/*
					 * stash the resolved tag type back on q->left's
					 * own .ty -- stype() doesn't set this itself (it
					 * returns the Type without mutating the node),
					 * but com.c's casecom() needs it again later, at
					 * codegen time, to find each binder's own field
					 * offset -- q->left is otherwise unused after
					 * this (matching the same "type expr consumed"
					 * discipline the Odot-into-tag fix above uses).
					 */
					q->left->ty = tagty;
					q->val = tagty->decl->tag;
					nlab++;
					/*
					 * bind each "(v, e, ...)" name positionally
					 * against the tag's own fields, into THIS arm's
					 * own scope (pushscope() below, popscope() after
					 * stchk() -- so a binder is visible only inside
					 * its own arm's body, same as any other block-
					 * scoped local). fd walks the tag's own ids only
					 * -- not the (currently always-empty, see this
					 * branch's own pick-adt plan) shared chain --
					 * matching Result.Ok's own fields being what a
					 * pattern binder is actually for.
					 */
					pushscope();
					fd = tagty->ids;
					for(bp = nil, bn = q->right; bn != nil && fd != nil; bn = bn->right){
						Node *id;
						Decl *d;

						id = bn;
						if(bn->op == Oseq)
							id = bn->left;
						if(id->op != Oname){
							nerror(id, "bad pattern binder");
							ok = 0;
							break;
						}
						sizetype(fd->ty);
						d = mkdecl(&id->src, Dlocal, fd->ty);
						d->sym = id->sym;
						install(d);
						id->decl = d;
						id->ty = fd->ty;
						d->link = nil;
						if(bp == nil){
							if(curfn->locals == nil)
								curfn->locals = d;
							else{
								Decl *e;

								for(e = curfn->locals; e->link != nil; e = e->link)
									;
								e->link = d;
							}
						}else
							bp->link = d;
						bp = d;
						fd = fd->next;
						if(bn->op != Oseq)
							break;
					}
					stchk(arm->right);
					popscope();
					continue;
				}
				pt = echk(q);
				if(pt != terror && pt->kind != (t->kind == Tstring ? Tstring : Tint)){
					nerror(q, "case label must be %s, not %T", t == tstring ? "string" : "int", pt);
					ok = 0;
				}else if(q->op != Oconst){
					nerror(q, "case label is not constant");
					ok = 0;
				}else
					nlab++;
			}
		}
		if(arm->left == nil || arm->left->op != Opat){
			pushscope();
			stchk(arm->right);
			popscope();
		}
	}
	if(!ok || subj == nil && t->kind != Tint && t->kind != Tstring)
		return;
	/*
	 * string subject: the labels sort and search by text
	 * (casecmp()), the table is a Tcasec (disw.c writes the label
	 * strings straight into module data, types.c's descriptor map
	 * marks them as pointers) and casecom() dispatches with ICASEC.
	 */
	c = matchlabels(n->right, t == tstring ? tstring : tint, nlab);
	c->tagof = subj;
	ct = mktype(&n->src, t == tstring ? Tcasec : Tcase, nil, nil);
	ct->cse = c;
	sizetype(ct);
	n->ty = ct;
}

/*
 * lvalue validity: is n -- already echk()'d, so already rewritten
 * into its post-check shape -- something a store can actually land
 * in?  nothing checked this before (0f8b9f9f's closing note): "5 = 3"
 * compiled and ran silently, and other shapes ("f() = 3", "-x = 3",
 * "xs[0:1] = xs") only failed as compiler fatals in com.c/gen.c,
 * i.e. the same missing check landing on a codegen path that happened
 * not to tolerate the nonsense.  one audit over every LHS shape, not
 * per-shape patches.  what counts:
 *
 *   Oname   a variable -- Dlocal/Darg/Dglobal (a captured variable is
 *           already an Oind chain by now, never a bare Oname).  a
 *           Dfn (own or import-wrapped) is a value, not storage; a
 *           Dtype is a type (a module's own type name included); a
 *           Dconst never survives echk() as an Oname (confold() turns
 *           it into an Oconst).  an import alias is an ordinary
 *           Dglobal and may be reassigned ("rand = load Rand path").
 *   Omdot   a module's own global (Dglobal only -- Dtype is the other
 *           store echk()'s Odot case lets through here).
 *   Oindx   an array element: arrays are heap objects, so the base
 *           may be any array-valued expression, a call included.
 *   Oinds   a string index: the store writes the string *variable*
 *           back (IINSC's dst operand, copy-on-write in the VM), so
 *           the string itself must be an lvalue -- limbo's typecheck.c
 *           draws the identical line (no writes into a string
 *           constant).
 *   Oind    a field or tuple component, Oind(Oadd(base', $off)) from
 *           echk()'s Odot case: through a ref base (base' is the
 *           pointer value itself) any expression will do, the write
 *           goes through the pointer; through a value base (base' is
 *           Oadr(base)) the base's own storage is what gets written,
 *           so it must itself be an lvalue -- "mkpoint().x = 5" would
 *           otherwise write into the temp fixcallbase() materializes
 *           and vanish.
 *
 * everything else -- constants, nil, calls, arithmetic, casts,
 * slices, len/hd/tl, tuples, composite literals -- is an rvalue.
 */
static char*
lvaldesc(Node *n)
{
	Decl *d;

	switch(n->op){
	case Oname:
		d = n->decl;
		if(d == nil)
			break;
		if(d == nildecl)
			return "nil";
		switch(d->store){
		case Dfn:
			return "a function";
		case Dtype:
			return "a type";
		case Dtag:
			return "a pick tag";
		}
		break;
	case Omdot:
		if(n->right->decl != nil && n->right->decl->store == Dtype)
			return "a type";
		break;
	case Oconst:
		return "a constant";
	case Onil:
		return "nil";
	case Ocall:
		return "a function call";
	case Oslice:
		return "a slice";
	case Otuple:
		return "a tuple";
	case Ocomposite:
	case Oref:
		return "a composite literal";
	case Olen: case Ohd: case Otl: case Ocons: case Ocast: case Ocopy: case Oexit: case Ocond:
	case Oneg: case Onot: case Oinv:
	case Oadd: case Osub: case Omul: case Odiv: case Omod:
	case Oand: case Oor: case Oxor: case Olsh: case Orsh:
	case Oandand: case Ooror:
	case Oeq: case Oneq: case Olt: case Ogt: case Oleq: case Ogeq:
	case Orcv: case Ochk:
		return "an expression";
	}
	return nil;
}

static int
islvalue(Node *n)
{
	Node *b;
	Decl *d;

	switch(n->op){
	case Oname:
		d = n->decl;
		if(d == nil || d == nildecl)
			return 0;
		return d->store == Dlocal || d->store == Darg || d->store == Dglobal;
	case Omdot:
		return n->right->decl != nil && n->right->decl->store == Dglobal;
	case Oindx:
		return 1;
	case Oinds:
		return islvalue(n->left);
	case Oind:
		for(b = n->left; b->op == Oadd; b = b->left)
			;
		if(b->op == Oadr)
			return islvalue(b->left);
		return 1;
	}
	return 0;
}

/*
 * report and return 0 if n isn't a valid store target; what names the
 * operation for the message ("assign to", "increment", ...).
 */
static int
chklval(Node *n, char *what)
{
	Node *b;
	char *desc;

	if(n->ty == terror)
		return 0;
	/*
	 * a closure captures an enclosing function's variable by value
	 * (a copy in its environment), so assigning to it inside the
	 * closure changes only the copy -- silently, which no reader
	 * expects.  refuse it; shared state goes through a ref.
	 */
	if(islvalue(n))
		return 1;
	desc = lvaldesc(n);
	if(desc == nil && n->op == Oind){
		/* a field of something that isn't itself storage */
		for(b = n->left; b->op == Oadd; b = b->left)
			;
		if(b->op == Oadr)
			desc = lvaldesc(b->left);
		if(desc != nil){
			nerror(n, "cannot %s a field of %s", what, desc);
			return 0;
		}
	}
	if(desc == nil && n->op == Oinds){
		desc = lvaldesc(n->left);
		if(desc != nil){
			nerror(n, "cannot %s an element of %s", what, desc);
			return 0;
		}
	}
	if(desc == nil)
		desc = "this expression";
	nerror(n, "cannot %s %s", what, desc);
	return 0;
}

/*
 * for i[, v] := range e { body }, e's type deciding the loop: an
 * array or string gives the index and, with a second name, the
 * element; a list gives the element; an int counts from 0.  e is
 * evaluated once, into a hidden local.  rewritten here into the
 * ordinary for (init; cond; post) shape, so nothing downstream
 * knows about range.
 */
static int
rangefor(Node *n)
{
	Node *das, *names, *first, *second, *e, *tmp, *init, *cond, *post, *prefix, *p;
	Type *t;
	Src *src;
	char buf[32];
	static int nrange;

	das = n->aux;
	names = das->left;
	first = names;
	second = nil;
	if(names->op == Oseq){
		first = names->left;
		second = names->right;
		if(second->op == Oseq){
			nerror(n, "range wants one or two names");
			return 0;
		}
	}
	if(isblank(first))
		first->sym = blanksym();
	if(isblank(second))
		second->sym = blanksym();
	e = das->right->left;
	src = &das->src;
	t = echk(e);
	if(t == terror)
		return 0;
	seprint(buf, buf+sizeof(buf), ".range%d", nrange++);
	tmp = mkname(src, enter(buf, 0));
	switch(t->kind){
	case Tarray:
	case Tstring:
		/* .r := e; i := 0; i < len(.r); i++ { [v := .r[i]] } */
		init = mkseq(mkn(Odas, tmp, e), mkn(Odas, first, mkconst(src, 0)));
		cond = mkbin(Olt, dupn(first), mkn(Ocall, mkname(src, enter("len", 0)), dupn(tmp)));
		post = mkunary(Oinc, dupn(first));
		prefix = nil;
		if(second != nil)
			prefix = mkn(Odas, second, mkbin(Oindex, dupn(tmp), dupn(first)));
		break;
	case Tlist:
		/* .r := e; .r != nil; .r = tl(.r) { v := hd(.r) } */
		if(second != nil){
			/* for i, x := range l: i counts from 0, as over an array */
			init = mkseq(mkn(Odas, tmp, e), mkn(Odas, first, mkconst(src, 0)));
			cond = mkbin(Oneq, dupn(tmp), mkname(src, enter("nil", 0)));
			post = mkseq(mkn(Oas, dupn(tmp), mkn(Ocall, mkname(src, enter("tl", 0)), dupn(tmp))), mkunary(Oinc, dupn(first)));
			prefix = mkn(Odas, second, mkn(Ocall, mkname(src, enter("hd", 0)), dupn(tmp)));
			break;
		}
		init = mkn(Odas, tmp, e);
		cond = mkbin(Oneq, dupn(tmp), mkname(src, enter("nil", 0)));
		post = mkn(Oas, dupn(tmp), mkn(Ocall, mkname(src, enter("tl", 0)), dupn(tmp)));
		prefix = mkn(Odas, first, mkn(Ocall, mkname(src, enter("hd", 0)), dupn(tmp)));
		break;
	case Tchan:
		/* .r := e; 1; { v := <-.r } -- until the body breaks; Dis channels do not close */
		if(second != nil){
			nerror(n, "range over a channel gives one name, the value received");
			return 0;
		}
		init = mkn(Odas, tmp, e);
		cond = mkconst(src, 1);
		post = nil;
		prefix = mkn(Odas, first, mkunary(Orcv, dupn(tmp)));
		break;
	case Tint:
		/* .r := e; i := 0; i < .r; i++ */
		if(second != nil){
			nerror(n, "range over an int gives one name, the count");
			return 0;
		}
		init = mkseq(mkn(Odas, tmp, e), mkn(Odas, first, mkconst(src, 0)));
		cond = mkbin(Olt, dupn(first), dupn(tmp));
		post = mkunary(Oinc, dupn(first));
		prefix = nil;
		break;
	default:
		if(ismaptype(t)){
			/*
			 * for k, v := range m: over a snapshot of the entries,
			 * .rangeN = m.entries(), indexed by a hidden .rangeNi
			 */
			Node *idx, *ent;

			seprint(buf, buf+sizeof(buf), ".range%di", nrange - 1);
			idx = mkname(src, enter(buf, 0));
			init = mkseq(mkn(Odas, tmp, mkmethcall(src, e, "entries", nil)), mkn(Odas, idx, mkconst(src, 0)));
			cond = mkbin(Olt, dupn(idx), mkn(Ocall, mkname(src, enter("len", 0)), dupn(tmp)));
			post = mkunary(Oinc, dupn(idx));
			ent = mkbin(Oindex, dupn(tmp), dupn(idx));
			prefix = mkn(Odas, first, mkbin(Odot, ent, mkname(src, enter("key", 0))));
			prefix->right->sym = prefix->right->right->sym;
			if(second != nil){
				ent = mkbin(Oindex, dupn(tmp), dupn(idx));
				p = mkn(Odas, second, mkbin(Odot, ent, mkname(src, enter("val", 0))));
				p->right->sym = p->right->right->sym;
				prefix = mkseq(prefix, p);
			}
			break;
		}
		nerror(n, "cannot range over %T", t);
		return 0;
	}
	init->src = *src;
	cond->src = *src;
	if(post != nil)
		post->src = *src;
	n->left = cond;
	n->aux = mkn(Oforctl, init, post);
	n->aux->src = *src;
	if(prefix != nil){
		prefix->src = *src;
		n->right = mkn(Oscope, mkseq(prefix, n->right), nil);
		n->right->src = *src;
	}
	return 1;
}

/*
 * a condition: a bool (a comparison, a logical expression, true/
 * false) or, for the code that predates bool, an int flag; anything
 * else -- a string, a ref -- is refused
 */
static int
iscond(Type *t)
{
	return t == terror || t->kind == Tbool || t->kind == Tint;
}

static void
condchk(Node *n)
{
	Type *t;

	t = echk(n);
	if(!iscond(t))
		nerror(n, "condition is %T, not bool", t);
}

static void
stchk(Node *n)
{
	Type *t;

	for(; n != nil; n = n->right){
		switch(n->op){
		default:
			/* expression statement or unsupported */
			switch(n->op){
			case Odas:
				daschk(n);
				return;
			case Oas:
				if(ismapindex(n->left)){
					/* m[k] = v: m.put(k, v) */
					Node *call;

					call = mkmethcall(&n->src, n->left->left, "put", rotater(mkseq(n->left->right, n->right)));
					n->op = Oexpr;
					n->left = call;
					n->right = nil;
					echk(call);
					return;
				}
				if(n->left->op == Oseq){
					/*
					 * "a, b = f()": same destructuring as daschk's
					 * ":=" case above, but every LHS name is an
					 * *existing* variable (echk()'d, not declared)
					 * -- unlike :=, Oas's LHS can in general be any
					 * lvalue, but multi-assignment is scoped to
					 * plain names here, same as := effectively is
					 * (daschk already errors on anything else).
					 */
					Node *p, *id;
					Decl *fd;
					Type *rt, *lt;
					int nlhs, nrhs;

					/* "a, b = b, a": an expression list is a tuple
					 * value, built whole before any store (com.c's
					 * destructure() evaluates it into a temp), so
					 * the swap idiom is safe -- same wrapping Oret
					 * does for "return a, b" */
					if(ismapindex(n->right))
						n->right = mapindexcall(n->right, "lookup");
					if(n->right->op == Oseq)
						n->right = mkn(Otuple, n->right, nil);
					rt = echk(n->right);
					if(rt->kind != Ttuple){
						nerror(n, "multiple assignment needs a multi-valued call or an expression list on the right, not %T", rt);
						return;
					}
					nlhs = 0;
					for(p = n->left; p != nil; p = p->right){
						nlhs++;
						if(p->op != Oseq)
							break;
					}
					nrhs = 0;
					for(fd = rt->ids; fd != nil; fd = fd->next)
						nrhs++;
					if(nlhs != nrhs){
						nerror(n, "assignment count mismatch: %d = %d", nlhs, nrhs);
						return;
					}
					fd = rt->ids;
					for(p = n->left; p != nil; p = p->right){
						id = p;
						if(p->op == Oseq)
							id = p->left;
						if(isblank(id))
							declblank(id, fd->ty);
						lt = echk(id);
						if(chklval(id, "assign to") && !assignable(lt, fd->ty, nil))
							nerror(n, "cannot assign %T to %T", fd->ty, lt);
						fd = fd->next;
						if(p->op != Oseq)
							break;
					}
					n->ty = rt;
					return;
				}
				if(isblank(n->left))
					declblank(n->left, echk(n->right));
				if(n->left->op == Oname && n->right->op == Ocomposite){
					/*
					 * "p = Point{x: 1, y: 2}" where p already exists:
					 * same reasoning as daschk()'s own ":=" case
					 * (above) -- go through compositefields()
					 * directly, rather than echk() hitting the
					 * general Ocomposite case and refusing it as a
					 * bare value.  restricted to a bare Oname LHS,
					 * same as Odas's own restriction (and for the
					 * same underlying reason, per com.c's Odas
					 * comment): the store this lowers to (com.c's
					 * scom Oas case's storecompositezero() call)
					 * needs a plain, unconditionally addressable name
					 * (Rreg/Rmreg) as its destination -- an arbitrary
					 * lvalue (p.field = ..., arr[i] = ...) isn't
					 * attempted here, deliberately, same boundary
					 * Odas already draws.
					 */
					t = compositefields(n->right);
					echk(n->left);
					if(chklval(n->left, "assign to") && t != terror && !assignable(n->left->ty, t, n->right))
						nerror(n, "cannot assign %T to %T", t, n->left->ty);
					return;
				}
				t = echk(n->right);
				echk(n->left);
				if(n->left->ty != nil)
					retypetuple(n->right, n->left->ty);
				if(chklval(n->left, "assign to") && !assignable(n->left->ty, t, n->right))
					nerror(n, "cannot assign %T to %T", t, n->left->ty);
				return;
			case Oaddas: case Osubas: case Omulas: case Odivas: case Omodas:
			case Oandas: case Ooras: case Oxoras: case Olshas: case Orshas:
				if(ismapindex(n->left)){
					/* m[k] op= v: m.put(k, m.get(k) op v); k is evaluated twice */
					Node *call, *val;

					val = mkbin(Oadd + (n->op - Oaddas), mapindexcall(dupn(n->left), "get"), n->right);
					val->src = n->src;
					call = mkmethcall(&n->src, n->left->left, "put", rotater(mkseq(n->left->right, val)));
					n->op = Oexpr;
					n->left = call;
					n->right = nil;
					echk(call);
					return;
				}
				echk(n->left);
				echk(n->right);
				if(chklval(n->left, "assign to") && n->right->ty != terror
				&& !tequal(n->left->ty, n->right->ty)
				&& !((n->op == Olshas || n->op == Orshas) && n->right->ty->kind == Tint
				&& (n->left->ty->kind == Tbig || n->left->ty->kind == Tbyte)))
					nerror(n, "type mismatch in %s", opname[n->op]);
				return;
			case Oinc: case Odec:
				if(ismapindex(n->left)){
					/* m[k]++: m.put(k, m.get(k) + 1) */
					Node *call, *val, *one;

					one = mkconst(&n->src, 1);
					val = mkbin(n->op == Oinc ? Oadd : Osub, mapindexcall(dupn(n->left), "get"), one);
					val->src = n->src;
					call = mkmethcall(&n->src, n->left->left, "put", rotater(mkseq(n->left->right, val)));
					n->op = Oexpr;
					n->left = call;
					n->right = nil;
					echk(call);
					return;
				}
				echk(n->left);
				chklval(n->left, n->op == Oinc ? "increment" : "decrement");
				return;
			case Oexpr:
				t = echk(n->left);
				USED(t);
				return;
			case Ospawn:
				echk(n->left);
				if(n->left->op == Ocall && n->left->ty != tnone && n->left->ty != terror)
					nerror(n, "spawned function must not return a value");
				return;
			case Odefer: {
				/*
				 * the argument temps run now; the func() literal
				 * is consed onto the hidden list the returns will
				 * walk (defercalls, above)
				 */
				Node *nm, *as;
				Type *lt;

				if(n->aux != nil)
					stchk(n->aux);
				t = echk(n->left);
				if(t == terror)
					return;
				if(deferlist == nil){
					lt = mktype(&n->src, Tlist, t, nil);
					sizetype(lt);
					nm = mkname(&n->src, enter(".defers", 0));
					declhidden(nm, lt);
					deferlist = nm->decl;
				}
				nm = mkdeclname(&n->src, deferlist);
				as = mkn(Oas, nm, mkbin(Ocons, n->left, mkdeclname(&n->src, deferlist)));
				as->src = n->src;
				if(n->aux != nil){
					n->op = Oseq;
					n->left = n->aux;
					n->right = as;
					n->aux = nil;
					stchk(as);
				}else{
					n->op = Oas;
					n->left = nm;
					n->right = as->right;
					n->aux = nil;
					stchk(n);
				}
				return;
			}
			case Oraise:
				echk(n->left);
				if(n->left->ty != tstring && n->left->ty != terror)
					nerror(n, "raise requires a string, not %T", n->left->ty);
				return;
			case Osnd:
				echk(n);
				return;
			case Onothing:
				return;
			case Ocondecl: {
				/* a local constant, the same as a module one (check()) */
				Decl *cd;

				if(n->aux != nil){
					pushscope();
					declconst("iota", n->aux->val, tint);
					t = echk(n->right);
					popscope();
				}else
					t = echk(n->right);
				if(n->right->op != Oconst){
					nerror(n, "constant expression required");
					return;
				}
				cd = mkdecl(&n->src, Dconst, t);
				cd->sym = n->left->sym;
				cd->init = n->right;
				install(cd);
				return;
			}
			default:
				nerror(n, "unsupported statement %O", n->op);
				return;
			}
		case Oseq:
			stchk(n->left);
			continue;
		case Oscope:
			pushscope();
			stchk(n->left);
			popscope();
			return;
		case Oif:
			condchk(n->left);
			pushscope();
			stchk(n->right);
			popscope();
			if(n->aux != nil){
				pushscope();
				stchk(n->aux);
				popscope();
			}
			return;
		case Omatch:
			if(lowerguards(n)){
				stchk(n);
				return;
			}
			matchcheck(n);
			return;
		case Oalt:
			altcheck(n);
			return;
		case Otry: {
			/*
			 * try { body } catch e { handler }: e is a string local
			 * of the handler's scope, filled by the VM with the
			 * raised string; a nameless catch still needs the slot
			 */
			Decl *ed;
			Node *en;

			pushscope();
			stchk(n->left);
			popscope();
			pushscope();
			en = n->aux;
			if(en == nil){
				en = mkn(Oname, nil, nil);
				en->src = n->src;
				en->sym = enter(".exc", 0);
				n->aux = en;
			}
			ed = mkdecl(&en->src, Dlocal, tstring);
			ed->sym = en->sym;
			install(ed);
			en->decl = ed;
			en->ty = tstring;
			ed->link = nil;
			if(curfn->locals == nil)
				curfn->locals = ed;
			else{
				Decl *e;

				for(e = curfn->locals; e->link != nil; e = e->link)
					;
				e->link = ed;
			}
			stchk(n->right);
			popscope();
			return;
		}
		case Ofor:
			if(n->aux != nil && n->aux->op == Odas && !rangefor(n))
				return;
			pushscope();
			if(n->aux != nil)
				stchk(n->aux->left);
			if(n->left != nil)
				condchk(n->left);
			pushscope();
			stchk(n->right);
			popscope();
			if(n->aux != nil)
				stchk(n->aux->right);
			popscope();
			return;
		case Obreak:
		case Ocont:
			/*
			 * validating the label itself (that one was given, that
			 * it names an enclosing loop) needs a loop-nesting stack
			 * matching com.c's labdep/labels[]; rather than duplicate
			 * that here, com.c's labeldepth() is the sole source of
			 * both "break/continue outside loop" and "label not
			 * found" -- already true pre-labels for the outside-loop
			 * case (bccom always checked labdep, never stchk).
			 */
			return;
		case Olabel:
			stchk(n->right);
			return;
		case Ovardecl: {
			Type *vt;
			Node *names, *id;
			Decl *d;

			vt = nil;
			if(n->right != nil)
				vt = stype(n->right);
			if(n->aux != nil){
				Node *it;

				/*
				 * "var p Point = Point{x: 1, y: 2}" (or ":= Point{...}",
				 * daschk below): a value-typed composite literal is
				 * usable here, unlike as a general expression (echk's
				 * Ocomposite case still refuses that), because scom's
				 * Ovardecl case (com.c) has an address to store into --
				 * the new local's own frame slot -- the same way an
				 * enclosing ref T{...}'s Oref case does for a nested
				 * field.  go through compositefields() directly, same
				 * as Oref's echk case, rather than echk() (which would
				 * hit the general Ocomposite case and refuse it).
				 */
				it = n->aux->op == Ocomposite ? compositefields(n->aux) : echk(n->aux);
				if(vt == nil)
					vt = it;
				else if(!assignable(vt, it, n->aux))
					nerror(n, "cannot initialize %T from %T", vt, it);
			}
			if(vt == nil){
				nerror(n, "variable needs a type");
				vt = terror;
			}
			sizetype(vt);
			for(names = n->left; names != nil; names = names->right){
				id = names;
				if(names->op == Oseq)
					id = names->left;
				d = mkdecl(&id->src, Dlocal, vt);
				d->sym = id->sym;
				d->init = n->aux;
				install(d);
				id->decl = d;
				id->ty = vt;

				/* record the local on the current function
				 * (link, not next) -- same bookkeeping as
				 * daschk's, above. */
				d->link = nil;
				if(curfn->locals == nil)
					curfn->locals = d;
				else{
					Decl *e;

					for(e = curfn->locals; e->link != nil; e = e->link)
						;
					e->link = d;
				}
				if(names->op != Oseq)
					break;
			}
			return;
		}
		case Oret:
			if(n->left == nil){
				if(curret != tnone)
					nerror(n, "missing return value");
				return;
			}
			/*
			 * "return a, b" -- pexprlist() (parse.c) leaves multiple
			 * return values as a bare Oseq chain, the same shape
			 * Otuple's own left already expects (its echk case
			 * walks n->left via ->right, exactly like this).  wrap
			 * once, here, only when there's more than one value
			 * (Oseq present) and the function's declared return
			 * type is itself a tuple -- a single-value return stays
			 * untouched, and com.c's Oret case (scom) below never
			 * needs to know the difference: ecom() gets a new
			 * Otuple case (com.c) that stores its elements the same
			 * way a bare (non-ref) composite literal's fields do.
			 */
			if(n->left->op == Oseq && curret->kind == Ttuple)
				n->left = mkn(Otuple, n->left, nil);
			/*
			 * "return Point{x: 1, y: 2}": same reasoning as
			 * Ovardecl/vardec's composite-literal cases -- there's
			 * somewhere to store this one, retalloc()'s destination
			 * (com.c), so go through compositefields() directly
			 * rather than echk()'s general Ocomposite case, which
			 * still refuses a bare value with nowhere given to put
			 * it.
			 */
			t = n->left->op == Ocomposite ? compositefields(n->left) : echk(n->left);
			/*
			 * echk's Otuple case builds a fresh Ttuple from the
			 * actual value expressions (mktype(), no sizetype())
			 * -- unlike curret (the function's *declared* return
			 * type, already sizetype()'d once in fndecl(), when the
			 * function itself was declared).  com.c's new Otuple
			 * case (ecom) reads this fresh type's own field offsets
			 * directly, so it needs sizing here, not just curret's.
			 * skipping this left every field's offset at its
			 * zero-initialized default -- every value landed at the
			 * same address, overwriting each other; two same-sized
			 * int fields happened not to show it (whichever losing
			 * write's value simply never got read back out), but an
			 * int followed by a string corrupted the string
			 * pointer's own bytes outright.
			 */
			retypetuple(n->left, curret);
			if(t->kind == Ttuple)
				sizetype(t);
			if(curret == tnone)
				nerror(n, "function returns no value");
			else if(!assignable(curret, t, n->left))
				nerror(n, "cannot return %T as %T", t, curret);
			return;
		}
	}
}

/*
 * check one function body
 */
/*
 * does a break inside n leave the loop n is the body of?  an
 * unlabeled break inside a nested loop, match or alt leaves that
 * one instead; a labeled break is assumed to reach out.
 */
static int
hasbreak(Node *n, int nested)
{
	if(n == nil)
		return 0;
	switch(n->op){
	case Obreak:
		return n->left != nil || !nested;
	case Ofor:
	case Omatch:
	case Oalt:
		return hasbreak(n->left, 1) || hasbreak(n->right, 1) || hasbreak(n->aux, 1);
	}
	return hasbreak(n->left, nested) || hasbreak(n->right, nested) || hasbreak(n->aux, nested);
}

/*
 * does the statement (list) n always end in a return or raise?  go's
 * terminating statements: return, raise, an if with an else both
 * terminating, a match or alt with a default and every arm
 * terminating, a for without a condition that no break leaves, and a
 * block whose last statement terminates.
 */
static int
terminates(Node *n)
{
	Node *arm;

	if(n == nil)
		return 0;
	while(n->op == Oseq){
		if(n->right == nil)
			return terminates(n->left);
		n = n->right;
	}
	switch(n->op){
	case Oscope:
		return terminates(n->left);
	case Oret:
	case Oraise:
		return 1;
	case Oexpr:
		return n->left != nil && n->left->op == Oexit;
	case Oif:
		return n->aux != nil && terminates(n->right) && terminates(n->aux);
	case Omatch:
	case Oalt: {
		int wild;

		wild = 0;
		for(n = n->right; n != nil; n = n->right){
			arm = n;
			if(n->op == Oseq)
				arm = n->left;
			if(arm->op == Ocase){
				if(arm->left == nil)
					wild = 1;
				if(!terminates(arm->right))
					return 0;
			}
			if(n->op != Oseq)
				break;
		}
		return wild;
	}
	case Ofor:
		return n->left == nil && !hasbreak(n->right, 0);
	case Olabel:
		return terminates(n->right);
	case Otry:
		return terminates(n->left) && terminates(n->right);
	}
	return 0;
}

static void
fnchk(Decl *d)
{
	Node *body, *calls;
	Decl *arg;
	Decl *saveddefers;

	curfn = d;
	curret = d->ty->tof;
	body = d->init->aux;
	saveddefers = deferlist;
	deferlist = nil;

	pushscope();
	/* bind args without appending to the scope chain (repushids) */
	for(arg = d->ty->ids; arg != nil; arg = arg->next){
		if(arg->sym != nil){
			arg->scope = scope;
			arg->old = arg->sym->decl;
			arg->sym->decl = arg;
		}
	}
	stchk(body);
	if(deferlist != nil){
		/*
		 * defer: every return runs the deferred calls first
		 * (deferrets), and so does falling off the end
		 */
		deferrets(&d->init->aux);
		body = d->init->aux;
		if(!terminates(body)){
			calls = defercalls(&body->src);
			stchk(calls);
			d->init->aux = mkseq(body, calls);
			body = d->init->aux;
		}
	}
	boxpass(d);
	body = d->init->aux;
	/*
	 * a function with a result must return on every path: falling
	 * off the end returned whatever the result slot held -- zero,
	 * which for a ref is not even nil
	 */
	if(d->ty->tof != nil && d->ty->tof != tnone && d->ty->tof != terror && !terminates(body))
		error(d->init->src.start, "function %s does not return a value on every path", d->sym->name);
	for(arg = d->ty->ids; arg != nil; arg = arg->next){
		if(arg->sym != nil && arg->sym->decl == arg){
			arg->sym->decl = arg->old;
			arg->old = nil;
		}
	}
	popscope();
	curfn = nil;
	deferlist = saveddefers;
}

/*
 * add a function to the module
 */
/*
 * a pick's tags, from its Otpick body: one Dtag per tag, its fields a
 * struct walked in the current scope (so a generic pick's fields see
 * the type parameters when tinstantiate() calls this), numbered in
 * declaration order.  shared by typedec() and tinstantiate().
 */
static void
picktags(Node *body, Type *t, Decl *d)
{
	Decl *tags, *last, *tag;
	Node *p, *tg;
	int ntag;

	if(body->right != nil){
		/* fields every tag carries: the pick adt's own ids, laid out first */
		Node fake;
		Type *ft;

		fake = *body;
		fake.op = Otstruct;
		fake.left = body->right;
		fake.right = nil;
		ft = stype(&fake);
		t->ids = ft->ids;
	}

	/*
	 * each tag's own runtime discriminant: declaration order,
	 * 0-based, matching limbo's identical convention exactly
	 * (limbo/types.c's pickdecled(): "d->tag = tag++") -- a
	 * standard enum-style numbering, not a fresh decision. Decl's
	 * own "tag" field (ember.h) already existed for this, just
	 * never assigned anywhere in this loop until now. com.c's own
	 * construction/match-dispatch codegen reads this field as the
	 * literal word value written to/compared against the tag word
	 * sizetype() (types.c) already reserves at offset 0 of every
	 * tagged value's own storage.
	 */
	tags = last = nil;
	ntag = 0;
	for(p = body->left; p != nil; p = p->right){
		tg = p;
		if(p->op == Oseq)
			tg = p->left;
		tag = mkdecl(&tg->src, Dtag, nil);
		tag->sym = tg->left->sym;
		tag->tag = ntag++;
		tag->ty = mktype(&tg->src, Tadtpick, nil, nil);
		if(tg->right != nil){
			/* reuse stype field walk via fake Otstruct */
			Node fake;
			Type *ft;

			fake = *body;
			fake.op = Otstruct;
			fake.left = tg->right;
			ft = stype(&fake);
			tag->ty->ids = ft->ids;
		}
		tag->ty->tof = t;
		tag->ty->decl = tag;
		tag->dot = d;
		if(tags == nil)
			tags = tag;
		else
			last->next = tag;
		last = tag;
		if(p->op != Oseq)
			break;
	}
	t->tags = tags;
}

static void
typedec(Node *n)
{
	Decl *d;
	Type *t, *ph;

	/*
	 * check() pre-installs every non-generic struct/pick type name
	 * with a placeholder Tadt (n->decl) before any declaration is
	 * processed, so a field can name a type declared later in the
	 * file or the type itself ("type P struct { next ref P }" --
	 * stype() crashed on the nil type of a name mid-declaration).
	 * the body built below is folded INTO that placeholder, which
	 * every earlier "ref P" already points at.
	 */
	d = n->decl;
	ph = nil;
	if(d != nil)
		ph = d->ty;
	else{
		d = mkdecl(&n->src, Dtype, nil);
		d->sym = n->left->sym;
		d->dot = impdecl;
		install(d);
	}

	if(n->aux != nil){
		/*
		 * generic struct template: "type Pair[A, B] struct {...}".
		 * A and B aren't types yet -- they're placeholders bound
		 * only per instantiation -- so don't stype() the body now;
		 * stash the parameter names and the raw AST for
		 * tinstantiate() (stype's Otinst case, i.e. an actual use
		 * like "Pair[int, string]") to resolve later, once per
		 * distinct argument list.  see the Type.tparams/tbody
		 * comment in ember.h.
		 */
		/* struct and pick bodies become adts; any other body (a generic interface's "ref .W$s[T]") is typed as written at each instantiation */
		t = mktype(&n->src, Tadt, nil, nil);
		t->tparams = n->aux;
		t->tbody = n->right;
		d->ty = t;
		t->decl = d;
		return;
	}

	t = stype(n->right);
	if(t != terror && t->kind != Tadt && t->kind != Tadtpick && hasmeths(d->sym)){
		/*
		 * "type Color int" with methods: a copy of the base type,
		 * so the name is a type of its own to hang them on.  the
		 * copy is structurally equal to the base (types.c's
		 * tequal), so a Color is still an int everywhere else.
		 */
		Type *nt;

		nt = mktype(&n->src, t->kind, nil, nil);
		*nt = *t;
		nt->decl = d;
		nt->named = 1;
		nt->meths = nil;
		nt->methtmpl = nil;
		t = nt;
		d->ty = t;
		sizetype(t);
		teqclass(t);
		return;
	}
	if(ph != nil && t != ph && t->kind == Tadt){
		ph->ids = t->ids;
		ph->isiface = t->isiface;
		ph->ok |= t->ok & OKverify;
		ph->src = t->src;
		/*
		 * an earlier declaration may already have sized and
		 * classed the placeholder through a "ref B" field
		 * (sizetype() follows a ref's target), when it had no
		 * fields yet: size 0, whose descriptor then can't hold the
		 * real fields' pointers ("wrote off end of type map").
		 * re-size and re-class the completed type below.
		 */
		ph->ok &= ~(OKsized | OKclass);
		ph->size = 0;
		t = ph;
	}
	if(n->right->op == Otpick)
	{
		t->building = 1;	/* a case's field type may ask for the pick's size */
		picktags(n->right, t, d);
		t->building = 0;
	}
	d->ty = t;
	t->decl = d;
	sizetype(t);
	teqclass(t);
}

static void
vardec(Node *n)
{
	Decl *d;
	Type *t;
	Node *names, *id;

	t = nil;
	if(n->right != nil)
		t = stype(n->right);
		/* size it: a declared global type (ref lex.Tok) was left
		 * unsized -- zero width, overlapping the next global, whose
		 * int stores then hit a pointer-marked slot (the self-hosted
		 * parser's look-ahead globals).  locals were already sized. */
		sizetype(t);
	if(n->aux != nil){
		Type *it;

		/*
		 * "var origin = Point{x: 0, y: 0}": a value composite
		 * literal is usable here the same way it is for Ovardecl's
		 * local case -- through compositefields() directly, not
		 * echk() (whose general Ocomposite case still refuses a
		 * bare value) -- since this now has somewhere to store one:
		 * a non-constant global initializer (which a composite
		 * literal always is, having no Oconst shape of its own)
		 * gets emitted as real code into entrydecl's prologue
		 * (fncom(), com.c), below.
		 */
		it = n->aux->op == Ocomposite ? compositefields(n->aux) : echk(n->aux);
		if(t == nil)
			t = it;
		else if(!assignable(t, it, n->aux))
			nerror(n, "cannot initialize %T from %T", t, it);
	}
	if(t == nil){
		nerror(n, "variable needs a type");
		t = terror;
	}
	for(names = n->left; names != nil; names = names->right){
		id = names;
		if(names->op == Oseq)
			id = names->left;
		d = mkdecl(&id->src, Dglobal, t);
		d->sym = id->sym;
		d->init = n->aux;
		/*
		 * disw.c's disdatum() encodes a global's initializer straight
		 * into the module's data section -- but it does that by
		 * blindly reading n->val/n->rval/n->decl->sym off whatever
		 * node d->init is, fields that only mean anything on an
		 * Oconst (or, recursively, a composite/tuple of them).  a
		 * non-constant initializer -- a call, arithmetic on anything
		 * but literals, anything with actual work to do at runtime
		 * -- silently read garbage there instead of erroring: "var x
		 * = five() + 1" compiled clean and read back 0 at runtime,
		 * not 6.  mark it instead: disvar() (disw.c) skips a
		 * runinit'd global's datum, and fncom() (com.c) emits it as
		 * real store code in entrydecl's prologue, the same place
		 * imports already get autoloaded before the user's own
		 * init() body runs.
		 */
		if(n->aux != nil && n->aux->op != Oconst)
			d->runinit = 1;
		d->dot = impdecl;
		install(d);
		d->link = nil;
		if(moduledecls == nil)
			moduledecls = d;
		else{
			Decl *e;

			for(e = moduledecls; e->link != nil; e = e->link)
				;
			e->link = d;
		}
		if(names->op != Oseq)
			break;
	}
}

static void
fndecl(Node *n)
{
	Decl *d, *rd;
	Type *t, *rt, *bt;
	Node *nm, *recv;
	Sym *fsym;

	nm = n->left;
	recv = nil;
	fsym = nm->sym;
	bt = nil;
	if(nm->op == Omethod){
		recv = nm->left;
		fsym = nm->right->sym;
	}
	if(n->aux == nil){
		nerror(n, "function requires a body (interfaces belong in .ei files)");
		return;
	}
	if(n->right->aux != nil){
		/*
		 * func swap[A, B](...): store as an unresolved template,
		 * same idea as typedec()'s generic-struct case, except a
		 * function needs its *body* checked and compiled per
		 * instantiation too, not just a Type resolved -- so this
		 * doesn't stype() the signature or add anything to fns[]
		 * here; tinstantiatefn() (below), reached from echk's Ocall
		 * case for an explicit "swap[int, string](...)" call site,
		 * does the whole thing at once: bind the parameter names in
		 * a scope, re-run this same signature-building logic and a
		 * full fnchk() against the body while that scope is still
		 * live (check()'s ordinary second pass runs far too late
		 * for that -- by the time it would reach an instantiated
		 * Dfn, its type-parameter bindings are long gone), then pop
		 * the scope and mark the result "checked" so that second
		 * pass skips it.  methods with a generic receiver (the
		 * check just below) aren't included; a method can't have
		 * its own type parameters independent of the receiver's,
		 * and instantiating *through* a generic receiver is its own
		 * unimplemented case.
		 */
		if(recv != nil){
			nerror(n, "generic methods not yet supported");
			return;
		}
		d = mkdecl(&n->src, Dfn, nil);
		d->sym = fsym;
		d->init = n;
		d->tparams = n->right->aux;
		d->dot = impdecl;
		install(d);
		return;
	}
	if(recv != nil){
		Node *rty;

		rty = recv->right;
		if(rty->op == Otref)
			rty = rty->right;
		if(rty->op == Otinst || rty->op == Oindex){
			/*
			 * func (p ref Pair[A, B]) m(...) -- a method on a
			 * generic receiver, its own type parameters implicitly
			 * bound from the receiver's instantiation ("A"/"B" here
			 * are the *method's* own binding names for the same
			 * positions as Pair's tparams -- not necessarily spelled
			 * the same as Pair's own, though they conventionally
			 * are).  stored as an unresolved template on the
			 * *type* template's own Type (methtmpl, ember.h), not
			 * fns[] or ordinary scope -- reached from echk's Odot
			 * case (below) via a specific instantiation's gtemplate/
			 * ginst reverse link, the same "bind the names in a
			 * scope, dupntree()+re-check" core generic functions
			 * already use (tinstantiatefncore()), just with the
			 * arguments coming from the receiver's own instantiation
			 * instead of an explicit "[...]" or inference.
			 */
			Decl *btd;

			if(rty->left->op != Oname){
				nerror(n, "bad generic receiver type");
				return;
			}
			btd = lookup(rty->left->sym);
			if(btd == nil || btd->store != Dtype || btd->ty == nil || btd->ty->tparams == nil){
				nerror(n, "%s is not a generic type", rty->left->sym->name);
				return;
			}
			d = mkdecl(&n->src, Dfn, nil);
			d->sym = fsym;
			d->init = n;
			d->tparams = rty->right;
			d->dot = btd;
			d->link = btd->ty->methtmpl;
			btd->ty->methtmpl = d;
			return;
		}
	}
	rawfn = 1;
	t = stype(n->right);
	rawfn = 0;
	if(recv != nil){
		/*
		 * a method's receiver is just its first argument,
		 * prepended to the parameter list stype() already built;
		 * the body then sees it as an ordinary bound name (no
		 * special-casing needed there).  recv.m(args) at call
		 * sites desugars to m(recv, args) in Ocall, below.
		 */
		rt = stype(recv->right);
		bt = rt;
		if(bt->kind == Tref)
			bt = bt->tof;
		if(bt->kind != Tadt && !bt->named){
			nerror(n, "receiver type must be a struct, ref struct or named type, not %T", rt);
			return;
		}
		if(bt->named && rt->kind == Tref){
			nerror(n, "a named type takes a value receiver, not %T", rt);
			return;
		}
		rd = mkdecl(&recv->left->src, Darg, rt);
		rd->sym = recv->left->sym;
		rd->implicit = 1;
		rd->next = t->ids;
		t->ids = rd;
	}
	t->ok |= OKverify;
	sizetype(t);
	for(d = t->ids; d != nil; d = d->next)
		sizetype(d->ty);
	sizetype(t->tof);
	d = mkdecl(&n->src, Dfn, t);
	d->sym = fsym;
	d->init = n;
	d->offset = idoffsets(t->ids, MaxTemp, IBY2WD);
	if(recv != nil){
		/* exported as "Type.method" (disw.c:dismod), not installed
		 * into ordinary scope: only recv.m(...) can reach it. */
		d->dot = bt->decl;
		d->link = bt->meths;
		bt->meths = d;
	}else{
		d->dot = impdecl;
		install(d);
	}

	if(nfns >= lenfns){
		lenfns = nfns + 32;
		fns = reallocmem(fns, lenfns * sizeof *fns);
	}
	fns[nfns++] = d;

	if(strcmp(d->sym->name, "init") == 0)
		entrydecl = d;
}

void
check(Node *tree)
{
	Node *n, *decl;
	Decl *d;
	int i;
	Decl *own, *id, *last;

	if(tree == nil || tree->op != Omodule)
		return;
	modname = tree->left->sym;

	pushscope();	/* builtins */
	declbuiltin("int", tint);
	declbuiltin("bool", tbool);
	declconst("true", 1, tbool);
	declconst("false", 0, tbool);
	declbuiltin("big", tbig);
	declbuiltin("byte", tbyte);
	declbuiltin("real", treal);
	declbuiltin("string", tstring);

	/*
	 * "nil" (matches limbo/decls.c's own declstart()): a single
	 * predeclared Tany-typed Dglobal with no initializer.  mknil()
	 * (ast.c) builds an ordinary Oname naming it, so every read of
	 * a literal nil flows through the *existing* Oname/Dglobal
	 * paths in both echk() and ecom() unchanged -- it reads back as
	 * whatever this module's own global data segment is zero-filled
	 * to at load, the same guarantee a fresh IFRAME already relies
	 * on elsewhere in this compiler.  must be installed before any
	 * source is checked, since mknil() already produced Oname nodes
	 * referencing this exact symbol during parsing, before check()
	 * ever ran.
	 */
	nildecl = mkdecl(&nosrc, Dglobal, tany);
	nildecl->sym = enter("nil", 0);
	install(nildecl);

	findmethnames(tree);

	/*
	 * the implicit import behind append and map[K]V: module/
	 * builtin.ei as the alias .builtin, which no source can name;
	 * all templates, so nothing is loaded at run time
	 */
	d = readiface("builtin", &nosrc);
	if(d != nil){
		Decl *v;
		Dlist *dl;

		v = mkdecl(&nosrc, Dglobal, d->ty);
		v->sym = enter(".builtin", 0);
		v->importid = d;
		install(v);
		dl = allocmem(sizeof *dl);
		dl->d = v;
		dl->next = imports;
		imports = dl;
		/* Result[T] by its bare name: bound directly, not install()ed,
		 * which would cut the module's member list at it */
		v = modmember(d->ty, enter("Result", 0));
		if(v != nil){
			v->old = v->sym->decl;
			v->sym->decl = v;
		}
		v = modmember(d->ty, enter("Builder", 0));
		if(v != nil){
			v->old = v->sym->decl;
			v->sym->decl = v;
		}
		v = modmember(d->ty, enter("sort", 0));
		if(v != nil){
			v->old = v->sym->decl;
			v->sym->decl = v;
		}
		v = modmember(d->ty, enter("tolist", 0));
		if(v != nil){
			v->old = v->sym->decl;
			v->sym->decl = v;
		}
		v = modmember(d->ty, enter("Vec", 0));
		if(v != nil){
			v->old = v->sym->decl;
			v->sym->decl = v;
		}
	}

	pushscope();	/* module scope */

	impdecl = mkdecl(&tree->src, Dtype, nil);
	impdecl->sym = modname;
	impdecl->ty = mktype(&tree->src, Tmodule, nil, nil);
	impdecl->ty->decl = impdecl;

	/*
	 * first pass: declare everything at module scope
	 */
	/*
	 * pre-pass: publish every non-generic struct/pick type name with
	 * a placeholder type, so declarations may refer to types
	 * declared later in the file, and to themselves (typedec()
	 * folds each body into its placeholder).
	 */
	for(n = tree->right; n != nil; n = n->right){
		decl = n;
		if(n->op == Oseq)
			decl = n->left;
		if(decl->op == Otypedecl && decl->aux == nil && decl->right != nil
		&& (decl->right->op == Otstruct || decl->right->op == Otpick)){
			d = mkdecl(&decl->src, Dtype, mktype(&decl->src, Tadt, nil, nil));
			d->sym = decl->left->sym;
			d->dot = impdecl;
			d->ty->decl = d;
			install(d);
			decl->decl = d;
		}
		if(n->op != Oseq)
			break;
	}

	for(n = tree->right; n != nil; n = n->right){
		decl = n;
		if(n->op == Oseq)
			decl = n->left;
		switch(decl->op){
		case Oimport:
			importchk(decl);
			break;
		case Ofndecl:
			fndecl(decl);
			break;
		case Ocondecl: {
			Type *t;

			if(decl->aux != nil){
				/* a const block item: iota is its index while folding */
				pushscope();
				declconst("iota", decl->aux->val, tint);
				t = echk(decl->right);
				popscope();
			}else
				t = echk(decl->right);
			if(decl->right->op != Oconst){
				nerror(decl, "constant expression required");
				break;
			}
			d = mkdecl(&decl->src, Dconst, t);
			d->sym = decl->left->sym;
			d->init = decl->right;
			install(d);
			break;
		}
		case Ovardecl:
			vardec(decl);
			break;
		case Otypedecl:
			typedec(decl);
			break;
		default:
			nerror(decl, "unsupported declaration %O", decl->op);
			break;
		}
		if(n->op != Oseq)
			break;
	}

	if(errors)
		return;

	/*
	 * second pass: check function bodies.  runs *before* the module
	 * interface is built (below), not after -- fns[] keeps growing
	 * during this loop (generic instantiations, and now function-
	 * value wrapper synthesis, both append to it from inside an
	 * earlier fns[i]'s own body-check; i<nfns is re-evaluated every
	 * iteration so it always catches up), and mkiface (via teqclass,
	 * below) needs the *final* fns[] to give every exported Dfn --
	 * including anything synthesized mid-pass -- an .iface entry.
	 * generic instantiations never needed this (they're only ever
	 * called directly, by PC, never taken as a value), which is why
	 * this ordering requirement went unnoticed until a function-value
	 * wrapper -- reached indirectly via Rnoff/.iface->offset, not a
	 * direct call -- needed one and silently got none: encoded as an
	 * unresolved "$-1", the same failure signature a truly orphaned
	 * descriptor produces (see the function-values commit).
	 */
	for(i = 0; i < nfns; i++){
		/*
		 * a generic function's instantiation (tinstantiatefn(),
		 * above) already ran fnchk() on itself, eagerly, while its
		 * type-parameter bindings were still in scope -- this loop
		 * still reaches it regardless (nfns keeps growing as new
		 * instantiations get appended mid-loop, from inside
		 * whichever earlier fns[i]'s own body called them; i<nfns
		 * is re-evaluated every iteration, so it always catches up),
		 * but by then those bindings are long gone, so re-running
		 * fnchk() here -- besides being redundant -- would silently
		 * corrupt it: every stchk/echk mutation the first pass made
		 * in place (locals installed with fresh Decls, Odas/Odot
		 * nodes rewritten, ...) gets *redone* on top of itself,
		 * against whatever the module's ordinary top-level scope
		 * happens to have instead of A/B, producing exactly the kind
		 * of nonsense codegen a "compiled fine, wrong values or a
		 * crash at runtime" bug looks like -- not a second, harmless
		 * no-op check.
		 */
		if(fns[i]->checked)
			continue;
		fnchk(fns[i]);
	}

	/*
	 * module interface: all top-level functions are exported.
	 * chain the real fn decls (the *final* list, including anything
	 * synthesized during the pass above) so mkiface (via teqclass)
	 * can build the Dis linkage table.
	 */
	impdecl->ty->ids = nil;
	{
		Decl *last;

		last = nil;
		for(i = 0; i < nfns; i++){
			fns[i]->next = nil;
			if(last == nil)
				impdecl->ty->ids = fns[i];
			else
				last->next = fns[i];
			last = fns[i];
		}
	}
	/*
	 * the module's own interface (readownface: <module>.ei beside the
	 * source or on the include path) is its module declaration, as
	 * limbo's included .m is: every variable it declares must exist
	 * here with the same type, and exactly those variables are
	 * exported -- mkiface() flattens them into the .mp record whose
	 * name-sorted layout modcom() then gives the data segment, so an
	 * importer's "alias.var" (echk's Odot case) addresses the same
	 * word the VM's .mp signature check guards.
	 */
	own = readownface(impdecl->sym->name, infile);
	last = nil;
	for(d = impdecl->ty->ids; d != nil; d = d->next)
		last = d;
	if(own != nil)
	for(id = own->ty->ids; id != nil; id = id->next){
		if(id->store != Dglobal)
			continue;
		d = lookup(id->sym);
		if(d == nil || d->store != Dglobal || d->dot != impdecl || d->importid != nil){
			error(id->src.start, "interface declares variable %s, which module %s does not define",
				id->sym->name, impdecl->sym->name);
			continue;
		}
		d->next = nil;
		if(last == nil)
			impdecl->ty->ids = d;
		else
			last->next = d;
		last = d;
	}
	sizetype(impdecl->ty);
	teqclass(impdecl->ty);
	/*
	 * the interface's types are separate objects from the module's
	 * own (a struct declared in both), so an exported variable's type
	 * is compared the way the VM will compare it: by link signature,
	 * which needs the equivalence classes just built
	 */
	if(own != nil)
	for(id = own->ty->ids; id != nil; id = id->next){
		if(id->store != Dglobal)
			continue;
		d = lookup(id->sym);
		if(d == nil || d->store != Dglobal || d->dot != impdecl || d->importid != nil)
			continue;
		if(sign(d) != sign(id))
			error(id->src.start, "variable %s is %T in the interface but %T in module %s",
				id->sym->name, id->ty, d->ty, impdecl->sym->name);
	}
	/* export every top-level function from this module */
	if(impdecl->ty->tof != nil)
		impdecl->ty->tof->linkall = 1;
	/*
	 * and keep every module type reachable from those exports
	 * complete too: see modrefable() (types.c).
	 */
	modrefable(impdecl->ty);
	/*
	 * and its functions and methods: a stale interface fails here,
	 * not at load time.  generic functions are not compared (an
	 * interface names the template, the module instantiates it).
	 */
	if(own != nil){
		modrefable(own->ty);
	for(id = own->ty->ids; id != nil; id = id->next){
		if(id->store != Dfn || id->tparams != nil || id->inl)
			continue;
		if(id->dot != nil && id->dot != own){	/* a method: dot is its struct's Dtype */
			Decl *td;

			td = lookup(id->dot->sym);
			if(td == nil || td->store != Dtype || td->ty == nil || (td->ty->kind != Tadt && !td->ty->named)){
				error(id->src.start, "interface declares method %s.%s, but module %s has no struct %s",
					id->dot->sym->name, id->sym->name, impdecl->sym->name, id->dot->sym->name);
				continue;
			}
			for(d = td->ty->meths; d != nil && d->sym != id->sym; d = d->link)
				;
			if(d == nil){
				error(id->src.start, "interface declares method %s.%s, which module %s does not define",
					id->dot->sym->name, id->sym->name, impdecl->sym->name);
				continue;
			}
			if(d->tparams == nil && sign(d) != sign(id))
				error(id->src.start, "method %s.%s is %T in the interface but %T in module %s%s",
					id->dot->sym->name, id->sym->name, id->ty, d->ty, impdecl->sym->name,
					samesig(id->ty, d->ty) ? sigsame : "");
			continue;
		}
		d = lookup(id->sym);
		if(d == nil || d->store != Dfn || d->dot != impdecl){
			error(id->src.start, "interface declares function %s, which module %s does not define",
				id->sym->name, impdecl->sym->name);
			continue;
		}
		if(d->tparams == nil && sign(d) != sign(id))
			error(id->src.start, "function %s is %T in the interface but %T in module %s%s",
				id->sym->name, id->ty, d->ty, impdecl->sym->name,
				samesig(id->ty, d->ty) ? sigsame : "");
	}
	}
}
