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

	return inst;
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
			if(p->op != Oseq)
				break;
		}
		ft->ids = args;
		if(n->right != nil)
			ft->tof = stype(n->right);
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
		/* module member type: mod.Type */
		Decl *md, *id;

		if(n->left->op != Oname){
			nerror(n, "bad qualified type");
			return terror;
		}
		md = lookup(n->left->sym);
		if(md == nil || md->ty == nil || md->ty->kind != Tmodule){
			nerror(n, "%s is not a module", n->left->sym->name);
			return terror;
		}
		for(id = md->ty->ids; id != nil; id = id->next)
			if(id->sym == n->sym && id->store == Dtype)
				return id->ty;
		nerror(n, "%s has no type %s", n->left->sym->name, n->sym->name);
		return terror;
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
	Decl *fid;
	int keyed;
	Node *p;

	t = stype(n->left);
	if(t->kind != Tadt){
		nerror(n, "composite literal of non-struct type %T", t);
		n->ty = terror;
		return n->ty;
	}
	if(t->tags != nil){
		nerror(n, "composite literal of tagged type %T not yet supported", t);
		n->ty = terror;
		return n->ty;
	}
	keyed = -1;
	fid = t->ids;
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
				nerror(e, "%T has no field %s", t, e->left->sym->name);
		}else{
			if(keyed == 1)
				nerror(e, "cannot mix keyed and positional elements in %T composite literal", t);
			keyed = 0;
			fd = fid;
			if(fd == nil)
				nerror(e, "too many elements in %T composite literal", t);
			else
				fid = fid->next;
		}

		/*
		 * tagged (pick) adts and tuples still need a real recursive
		 * store this compiler doesn't have (a pick's storage isn't
		 * just "fields at fixed offsets" -- it needs its tag word
		 * set too); refuse those cleanly.  a plain struct-typed
		 * field is fine: if the value is itself a composite literal
		 * (the only way to construct a struct *value*, since a bare
		 * name can't denote one -- see echk's Ocomposite case),
		 * recurse into compositefields() the same way this
		 * function's own caller (Oref's echk case) does, so nested
		 * fields get the same field-matching and offset-stashing
		 * treatment; com.c's Oref case (storecomposite()) walks the
		 * resulting nested e->decl chain to do the actual recursive
		 * store.
		 */
		if(fd != nil && (fd->ty->kind == Tadtpick || fd->ty->kind == Ttuple)){
			nerror(e, "composite literal field %s: tagged/tuple fields not yet supported", fd->sym->name);
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
	if(keyed == 0 && fid != nil)
		nerror(n, "too few elements in %T composite literal", t);
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
				case Dfn:
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
			if(t != nil && t->kind == Tadt){
				Decl *id;

				for(id = t->ids; id != nil; id = id->next)
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
		int i;

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
		switch(n->left->op){
		case Oname:
		case Odot:
		case Omdot:
			break;
		default:
			nerror(n, "cannot call this expression");
			n->ty = terror;
			return n->ty;
		}
		ft = echk(n->left);
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

		/* check fixed args */
		arg = ft->ids;
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
	case Ochk:
		t = echk(n->left);
		/* Result[T,E]-style: for now require ref adt with tags; type is first tag payload later */
		if(t->kind == Tref)
			t = t->tof;
		if(t == nil || t->kind != Tadt || t->tags == nil){
			nerror(n, "? requires a pick adt (Result)");
			n->ty = terror;
			return n->ty;
		}
		/* provisional: type of ? is the adt itself until elaboration */
		n->ty = t;
		return n->ty;
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
		if(t->kind != Tadt){
			nerror(n, "ref of non-adt %T", t);
			n->ty = terror;
			return n->ty;
		}
		n->ty = mktype(&n->src, Tref, t, nil);
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
			return n->ty;
		}
	case Ofunclit:
		nerror(n, "closures not yet typechecked");
		n->ty = terror;
		return n->ty;
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
	Type *t, *pt, *ct;
	Node *p, *arm, *pat, *q, *wild;
	Case *c;
	int nlab, ok;

	t = echk(n->left);
	ok = 1;
	if(t != tint && t != terror){
		nerror(n, "match subject must be int, not %T", t);
		ok = 0;
	}
	wild = nil;
	nlab = 0;
	for(p = n->right; p != nil; ){
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
			for(pat = arm->left; (q = nextpat(&pat)) != nil; ){
				if(q->op == Opat){
					nerror(q, "tag patterns not yet supported");
					ok = 0;
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
		pushscope();
		stchk(arm->right);
		popscope();
	}
	if(!ok || t != tint)
		return;
	c = matchlabels(n->right, tint, nlab);
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
			t = echk(n->left);
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

		tags = last = nil;
		for(p = n->right->left; p != nil; p = p->right){
			tg = p;
			if(p->op == Oseq)
				tg = p->left;
			tag = mkdecl(&tg->src, Dtag, nil);
			tag->sym = tg->left->sym;
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

		it = echk(n->aux);
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
		 * func swap[A, B](...) -- own type parameters on a
		 * (non-method) function.  scoped out along with generic
		 * methods below: monomorphizing a struct type by
		 * re-stype()-ing its body with the parameter names bound
		 * (tinstantiate(), above) doesn't extend to a *function*
		 * body, which needs its own per-instantiation compiled
		 * code, not just a per-instantiation Type.
		 */
		nerror(n, "generic functions not yet supported");
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
			 * bound from the receiver's instantiation.  same gap as
			 * generic functions just above: needs per-instantiation
			 * compiled code.  caught here, before stype(recv->right)
			 * below would otherwise try to resolve A/B as if they
			 * were ordinary (unbound) type names and fail with a
			 * confusing "A is not a type" instead.
			 */
			nerror(n, "generic methods not yet supported");
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
	 * module interface: all top-level functions are exported.
	 * chain the real fn decls so mkiface (via teqclass) can
	 * build the Dis linkage table.
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

	/*
	 * second pass: check function bodies
	 */
	for(i = 0; i < nfns; i++)
		fnchk(fns[i]);
}
