#include "ember.h"

/*
 * resolver and type checker.
 *
 * walks the parsed tree, resolving names against nested scopes,
 * mapping ember surface types onto the backend (limbo-model)
 * types from types.c, and annotating expression nodes with their
 * types.  imports are resolved by reading the limbo .m interface
 * (iface.c), so ember code calls limbo modules through exactly
 * the frame and signature contracts limbo itself would use.
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

static	void	fnchk(Decl*);
static	void	stchk(Node*);
static	Type	*echk(Node*);
static	Type	*stype(Node*);

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

static void
install(Decl *d)
{
	Sym *s;

	s = d->sym;
	d->scope = scope;
	d->old = s->decl;
	s->decl = d;
	d->next = nil;
	if(scopes[scope] == nil)
		scopes[scope] = d;
	else
		scopeends[scope]->next = d;
	scopeends[scope] = d;
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
		if(t->kind != Tadt && t->kind != Tfn && t->kind != Tadtpick){
			nerror(n, "ref requires an adt or function type");
			return terror;
		}
		return mktype(&n->src, Tref, t, nil);
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
		n->decl = d;
		return d->ty;
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
				case Dglobal:
					nerror(n, "module data access not yet supported");
					n->ty = terror;
					return n->ty;
				default:
					nerror(n, "cannot use %s.%s here", n->left->sym->name, n->sym->name);
					n->ty = terror;
					return n->ty;
				}
			}
		}
		t = echk(n->left);
		nerror(n, "field selection on %T not yet supported", t);
		n->ty = terror;
		return n->ty;
	case Ocall: {
		Node *a;
		Decl *arg;
		Type *ft;
		int i;

		/* callee */
		switch(n->left->op){
		case Oname:
		case Odot:
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
	if(lhs->op != Oname){
		nerror(n, "unsupported := form");
		return;
	}
	t = echk(n->right);
	if(t == tnone){
		nerror(n, ":= of a void expression");
		t = terror;
	}
	if(t == tany){
		nerror(n, ":= of nil needs a type");
		t = terror;
	}
	d = mkdecl(&lhs->src, Dlocal, t);
	d->sym = lhs->sym;
	install(d);
	lhs->decl = d;
	lhs->ty = t;
	n->ty = t;

	/* record the local on the current function */
	d->link = nil;
	if(curfn->locals == nil)
		curfn->locals = d;
	else{
		Decl *e;

		for(e = curfn->locals; e->next != nil; e = e->next)
			;
		e->next = d;
	}
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
			return;
		case Oret:
			if(n->left == nil){
				if(curret != tnone)
					nerror(n, "missing return value");
				return;
			}
			t = echk(n->left);
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
	for(arg = d->ty->ids; arg != nil; arg = arg->next)
		if(arg->sym != nil)
			install(arg);
	stchk(body);
	/* args were installed manually: pop without breaking the arg chain */
	{
		Decl *a;

		for(a = scopes[scope]; a != nil; a = a->old){
			/* nothing: args restored below */
			break;
		}
	}
	/* restore syms for args */
	for(arg = d->ty->ids; arg != nil; arg = arg->next)
		if(arg->sym != nil && arg->sym->decl == arg)
			arg->sym->decl = arg->old;
	scope--;
	curfn = nil;
}

/*
 * add a function to the module
 */
static void
fndecl(Node *n)
{
	Decl *d;
	Type *t;

	if(n->left->op == Omethod){
		nerror(n, "methods not yet supported");
		return;
	}
	t = stype(n->right);
	t->ok |= OKverify;
	sizetype(t);
	d = mkdecl(&n->src, Dfn, t);
	d->sym = n->left->sym;
	d->init = n;
	d->offset = idoffsets(t->ids, MaxTemp, IBY2WD);
	d->dot = impdecl;
	install(d);

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
			nerror(decl, "module variables not yet supported");
			break;
		case Otypedecl:
			nerror(decl, "type declarations not yet supported");
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
	 * module interface: all top level functions are exported
	 */
	impdecl->ty->ids = nil;
	{
		Decl *last, *dd;

		last = nil;
		for(i = 0; i < nfns; i++){
			dd = dupdecl(fns[i]);
			dd->next = nil;
			fns[i]->link = dd;	/* interface copy */
			if(impdecl->ty->ids == nil)
				impdecl->ty->ids = dd;
			else
				last->next = dd;
			last = dd;
		}
	}

	/*
	 * second pass: check function bodies
	 */
	for(i = 0; i < nfns; i++)
		fnchk(fns[i]);
}
