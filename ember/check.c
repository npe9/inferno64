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
static	Type	*echk(Node*);
static	Type	*stype(Node*);
static	Type	*compositefields(Node*);
static	Type	*tinstantiate(Node*);
static	Type	*envfn(Src*, Type*);
static	Decl	*synthfvwrap(Src*, Decl*);
static	Decl	*synthimportwrap(Src*, Decl*, Decl*);
static	Decl	*synthfunclit(Node*);
static	Decl	*tinstantiatefncore(Src*, Decl*, Type**, int, Decl*);
static	Decl	*tinstantiatefn(Node*);
static	Decl	*inferfn(Node*);
static	void	unifytparam(Node*, Type*, Decl*, Type**);
static	Decl	*tinstantiatemeth(Decl*, Type*);
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
static Type*
tinstantiate(Node *n)
{
	Decl *td, *pd;
	Type *tt, *inst, **argv;
	Ginst *ti;
	Node *p, *a, *pn;
	int i, nargs, nparams, match;

	if(n->left->op != Oname){
		nerror(n, "bad generic type reference");
		return terror;
	}
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
			if(ti->args[i] != argv[i]){
				match = 0;
				break;
			}
		if(match)
			return ti->ty;
	}

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
	inst = stype(tt->tbody);
	popscope();
	tinstdepth--;

	{
		Decl *id;
		char buf[256], *bp, *be;

		id = mkdecl(&n->src, Dtype, inst);
		bp = buf;
		be = buf + sizeof buf;
		bp = seprint(bp, be, "%s[", td->sym->name);
		for(i = 0; i < nargs; i++)
			bp = seprint(bp, be, "%s%T", i ? ", " : "", argv[i]);
		seprint(bp, be, "]");
		id->sym = enter(buf, 0);
		inst->decl = id;
	}
	sizetype(inst);
	teqclass(inst);

	ti = allocmem(sizeof *ti);
	ti->nargs = nargs;
	ti->args = argv;
	ti->ty = inst;
	ti->next = tt->tinsts;
	tt->tinsts = ti;

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
	Decl *pd, *savedcurfn;
	Type *ft, *savedcurret;
	Ginst *fi;
	Node *p, *pn;
	int i, match;

	for(fi = td->finsts; fi != nil; fi = fi->next){
		match = 1;
		for(i = 0; i < nargs; i++)
			if(fi->args[i] != argv[i]){
				match = 0;
				break;
			}
		if(match)
			return fi->decl;
	}

	for(i = 0; i < tinstdepth; i++)
		if(tinstack[i] == td){
			error(src->start, "%s: recursive generic instantiation not yet supported", td->sym->name);
			return nil;
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
		ft = stype(tn->right);
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

		savedcurfn = curfn;
		savedcurret = curret;
		fnchk(fnd);
		curfn = savedcurfn;
		curret = savedcurret;
		fnd->checked = 1;

		fi = allocmem(sizeof *fi);
		fi->nargs = nargs;
		fi->args = argv;
		fi->decl = fnd;
		fi->next = td->finsts;
		td->finsts = fi;

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
static Type*
envfn(Src *src, Type *pub)
{
	Decl *ids, *last, *p, *np;
	Type *ft;

	ids = last = mkdecl(src, Darg, tany);
	ids->sym = enter(".env", 0);
	for(p = pub->ids; p != nil; p = p->next){
		np = dupdecl(p);
		np->next = nil;
		last->next = np;
		last = np;
	}
	ft = mktype(src, Tfn, pub->tof, ids);
	ft->varargs = pub->varargs;
	ft->hasenv = 1;
	ft->ok |= OKverify;
	sizetype(ft);
	for(p = ft->ids; p != nil; p = p->next)
		sizetype(p->ty);
	sizetype(ft->tof);
	idoffsets(ft->ids, MaxTemp, IBY2WD);
	return ft;
}

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
	args = nil;
	for(arg = wt->ids->next; arg != nil; arg = arg->next)
		args = mkseq(args, mkname(src, arg->sym));
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

	pubt = stype(n->right);

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
			fd = mkdecl(&n->src, Dfield, cl->d->ty);
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

			un->op = Oind;
			un->left = addr;
			un->right = nil;
			un->decl = fd;
			un->ty = fd->ty;
		}
	}

	return ld;
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
				if(argv[j] == nil)
					argv[j] = at;
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
static Decl*
inferfn(Node *n)
{
	Decl *td;
	Type **argv;
	Node *p, *f, *ids, *id, *a, *arg;
	int i, nparams;

	if(n->left->op != Oname)
		return nil;
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
static Type*
stype(Node *n)
{
	Type *t;
	Decl *d;
	Node *p, *ids;

	if(n == nil)
		return tnone;
	switch(n->op){
	case Otarray:
		return mktype(&n->src, Tarray, stype(n->right), nil);
	case Otchan:
		return mktype(&n->src, Tchan, stype(n->right), nil);
	case Otlist:
		return mktype(&n->src, Tlist, stype(n->right), nil);
	case Otref:
		t = stype(n->right);
		if(t->kind != Tadt && t->kind != Tfn && t->kind != Tadtpick
		&& t->kind != Terror && t->kind != Tpoly){
			nerror(n, "ref requires an adt or function type");
			return terror;
		}
		return mktype(&n->src, Tref, t, nil);
	case Otstruct:
		t = mktype(&n->src, Tadt, nil, nil);
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
			if(f->flags & NVARARG)
				ft->varargs = 1;
			t = stype(f->right);
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
		return ft;
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
		return tinstantiate(n);
	case Odot: {
		/* module member type: mod.Type, or a local pick adt's own tag: Adt.Tag */
		Decl *md, *id, *tg;
		Type *rt;

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

	for(id = mt->ids; id != nil; id = id->next)
		if(id->sym == s)
			return id;
	return nil;
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
	if(alias == nil || alias->ty == nil || alias->ty->kind != Tmodule || alias->store != Dglobal)
		return nil;
	id = modmember(alias->ty, dot->sym);
	if(id == nil || id->store != Dfn)
		return nil;
	return id;
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
				nerror(e, "%T has no field %s", t, e->left->sym->name);
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
static Type*
echk(Node *n)
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
		d = lookup(n->sym);
		if(d == nil){
			nerror(n, "%s is not declared", n->sym->name);
			n->ty = terror;
			return n->ty;
		}
		if(d->store == Dconst){
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
			if(d != nil && d->ty != nil && d->ty->kind == Tmodule && d->store == Dglobal){
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
				case Dglobal:
				case Dtype:
					d->refs++;
					id->refs++;
					n->op = Omdot;
					n->left->decl = d;
					n->left->ty = d->ty;
					n->right = mkn(Oname, nil, nil);
					n->right->src = n->src;
					n->right->sym = n->sym;
					n->right->decl = id;
					n->right->ty = id->ty;
					n->ty = id->ty;
					return n->ty;
				default:
					nerror(n, "cannot use %s.%s here", n->left->sym->name, n->sym->name);
					n->ty = terror;
					return n->ty;
				}
			}
		}
		{
			Type *bt;
			int isref;

			bt = echk(n->left);
			t = bt;
			isref = bt != nil && bt->kind == Tref;
			if(isref)
				t = bt->tof;
			if(t != nil && (t->kind == Tadt || t->kind == Tadtpick)){
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
				 * cover both chains. a plain Tadt has no second
				 * chain (chains[1] stays nil), degrading to exactly
				 * the original single-chain search.
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
							n->decl = fnd;
							n->ty = fnd->ty;
							n->right = nil;
							return n->ty;
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
		Node *a;
		Decl *arg;
		Type *ft;
		int i, isvalcall;

		isvalcall = 0;

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
		if(n->left->op == Otinst || n->left->op == Oindex){
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
		}else if(n->left->op == Oname && lookup(n->left->sym) != nil
		&& lookup(n->left->sym)->store == Dfn && lookup(n->left->sym)->tparams != nil){
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
		}else if(n->left->op == Oname && lookup(n->left->sym) != nil && lookup(n->left->sym)->store == Dfn){
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

			fnd = lookup(n->left->sym);
			fnd->refs++;
			n->left->decl = fnd;
			n->left->ty = fnd->ty;
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

			alias = lookup(n->left->left->sym);
			fnd = modmember(alias->ty, n->left->sym);
			alias->refs++;
			fnd->refs++;
			n->left->op = Omdot;
			n->left->left->decl = alias;
			n->left->left->ty = alias->ty;
			n->left->right = mkn(Oname, nil, nil);
			n->left->right->src = n->left->src;
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
				break;
			default:
				nerror(n, "cannot call this expression");
				n->ty = terror;
				return n->ty;
			}
			ft = echk(n->left);
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
			Decl *meth;
			Node *recvexpr, *callee;

			meth = n->left->decl;
			recvexpr = n->left->left;
			n->right = mkseq(recvexpr, n->right);
			callee = mkn(Oname, nil, nil);
			callee->src = n->left->src;
			callee->sym = meth->sym;
			callee->decl = meth;
			callee->ty = meth->ty;
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
		i = 0;
		for(a = n->right; a != nil; a = a->right){
			Node *e;

			e = a;
			if(a->op == Oseq)
				e = a->left;
			t = echk(e);
			i++;
			if(arg != nil){
				if(!assignable(arg->ty, t, e))
					nerror(e, "argument %d: cannot use %T as %T", i, t, arg->ty);
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
		if(ft->varargs){
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
		n->ty = tint;
		return n->ty;
	case Oandand: case Ooror:
		echk(n->left);
		echk(n->right);
		n->ty = tint;
		return n->ty;
	case Onot:
		echk(n->left);
		n->ty = tint;
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
	case Oindex:
		t = echk(n->left);
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
			if(t != tint && t != terror)
				nerror(n, "channel size must be int, not %T", t);
		}
		t = mktype(&n->src, Tchan, stype(n->right), nil);
		sizetype(t);
		n->right = nil;	/* type expr consumed; ecom sees only size */
		n->ty = t;
		return n->ty;
	case Oarray:
		t = echk(n->left);
		if(t != tint && t != terror)
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
		if(!assignable(t->tof, tr, n->right))
			nerror(n, "cannot send %T on %T", tr, t);
		n->ty = tnone;
		return n->ty;
	case Ocomposite:
		/*
		 * a bare (non-ref) composite literal typechecks its fields
		 * via compositefields() -- so a typo'd field name or wrong
		 * count is still reported -- but is otherwise refused: it
		 * would need com.c to store into a value-typed local/global
		 * in place, the same address-of-arbitrary-lvalue capability
		 * Odot's field-access case above is missing.  "ref T{...}"
		 * (Oref's case) is the supported path; it never reaches
		 * here since it calls compositefields() directly.
		 */
		t = compositefields(n);
		if(t != terror)
			nerror(n, "composite literal %T{...} used as a value not yet supported (write ref %T{...} to allocate)", t, t);
		n->ty = terror;
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
	case Oload:
		nerror(n, "load not yet typechecked");
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

		t = echk(n->right);
		if(t->kind != Ttuple){
			nerror(n, "multiple assignment needs a multi-valued call on the right, not %T", t);
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
			sizetype(fd->ty);
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
	sizetype(t);
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
	USED(ty);
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
			labs[i].start = q;
			labs[i].stop = q;
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
			if(casecmp(ctype, labs[e].start, stop) <= 0)
				nerror(labs[e].start, "case label %lld overlaps %lld",
					(vlong)labs[e].start->val, (vlong)stop->val);
			if(ctype != tint
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
	if(subj == nil && t != tint && t != terror){
		nerror(n, "match subject must be int or a tagged adt, not %T", t);
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
				if(pt != tint && pt != terror){
					nerror(q, "case label must be int, not %T", pt);
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
	if(!ok || subj == nil && t != tint)
		return;
	c = matchlabels(n->right, tint, nlab);
	c->tagof = subj;
	ct = mktype(&n->src, Tcase, nil, nil);
	ct->cse = c;
	sizetype(ct);
	n->ty = ct;
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

					rt = echk(n->right);
					if(rt->kind != Ttuple){
						nerror(n, "multiple assignment needs a multi-valued call on the right, not %T", rt);
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
						lt = echk(id);
						if(lt != terror && !assignable(lt, fd->ty, nil))
							nerror(n, "cannot assign %T to %T", fd->ty, lt);
						fd = fd->next;
						if(p->op != Oseq)
							break;
					}
					n->ty = rt;
					return;
				}
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
					if(n->left->ty != terror && t != terror && !assignable(n->left->ty, t, n->right))
						nerror(n, "cannot assign %T to %T", t, n->left->ty);
					return;
				}
				t = echk(n->right);
				echk(n->left);
				if(n->left->ty != terror && !assignable(n->left->ty, t, n->right))
					nerror(n, "cannot assign %T to %T", t, n->left->ty);
				return;
			case Oaddas: case Osubas: case Omulas: case Odivas: case Omodas:
			case Oandas: case Ooras: case Oxoras: case Olshas: case Orshas:
				echk(n->left);
				echk(n->right);
				if(n->left->ty != terror && n->right->ty != terror
				&& !tequal(n->left->ty, n->right->ty))
					nerror(n, "type mismatch in %s", opname[n->op]);
				return;
			case Oinc: case Odec:
				echk(n->left);
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
			case Osnd:
				echk(n);
				return;
			case Onothing:
				return;
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
			echk(n->left);
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
			matchcheck(n);
			return;
		case Ofor:
			pushscope();
			if(n->aux != nil)
				stchk(n->aux->left);
			if(n->left != nil)
				echk(n->left);
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
static void
fnchk(Decl *d)
{
	Node *body;
	Decl *arg;

	curfn = d;
	curret = d->ty->tof;
	body = d->init->aux;

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
	for(arg = d->ty->ids; arg != nil; arg = arg->next){
		if(arg->sym != nil && arg->sym->decl == arg){
			arg->sym->decl = arg->old;
			arg->old = nil;
		}
	}
	popscope();
	curfn = nil;
}

/*
 * add a function to the module
 */
static void
typedec(Node *n)
{
	Decl *d;
	Type *t;

	d = mkdecl(&n->src, Dtype, nil);
	d->sym = n->left->sym;
	d->dot = impdecl;
	install(d);

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
		if(n->right->op != Otstruct){
			nerror(n, "generic type %s: only struct bodies are supported (not tagged/pick types)", d->sym->name);
			d->ty = terror;
			return;
		}
		t = mktype(&n->src, Tadt, nil, nil);
		t->tparams = n->aux;
		t->tbody = n->right;
		d->ty = t;
		t->decl = d;
		return;
	}

	t = stype(n->right);
	if(n->right->op == Otpick){
		Decl *tags, *last, *tag;
		Node *p, *tg;
		int ntag;

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
		for(p = n->right->left; p != nil; p = p->right){
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

				fake = *n->right;
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
	t = stype(n->right);
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
		if(bt->kind != Tadt){
			nerror(n, "receiver type must be a struct or ref struct, not %T", rt);
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

	if(tree == nil || tree->op != Omodule)
		return;
	modname = tree->left->sym;

	pushscope();	/* builtins */
	declbuiltin("int", tint);
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

	pushscope();	/* module scope */

	impdecl = mkdecl(&tree->src, Dtype, nil);
	impdecl->sym = modname;
	impdecl->ty = mktype(&tree->src, Tmodule, nil, nil);
	impdecl->ty->decl = impdecl;

	/*
	 * first pass: declare everything at module scope
	 */
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
	sizetype(impdecl->ty);
	teqclass(impdecl->ty);
	/* export every top-level function from this module */
	if(impdecl->ty->tof != nil)
		impdecl->ty->tof->linkall = 1;
}
