#include "ember.h"

/*
 * ember interface loader (.ei).
 *
 * ember owns its module headers.  an interface file is ordinary ember
 * syntax with no function bodies:
 *
 *	module Sys
 *	const PATH = "$Sys"
 *	type FD struct { fd int }
 *	func print(s string) int
 *
 * imports resolve against the -I search path (default: $ROOT/ember/module).
 * limbo's module/ *.m files are never read.
 */

typedef struct Iface Iface;
struct Iface
{
	char	*path;
	Decl	*d;
	Iface	*next;
};

static	Iface	*ifaces;
static	char	*incdir[MaxIncPath];
static	int	nincdir;

void
addincpath(char *dir)
{
	if(nincdir >= MaxIncPath)
		fatal("too many -I directories");
	incdir[nincdir++] = dir;
}

void
setpath(char *dir)
{
	addincpath(dir);
}

static Biobuf*
openiface(char *path, char *opened, int openlen)
{
	Biobuf *b;
	char buf[512];
	int i;

	opened[0] = 0;
	if(path[0] == '/' || path[0] == '.'){
		b = Bopen(path, OREAD);
		if(b != nil)
			secpy(opened, opened+openlen, path);
		return b;
	}

	for(i = 0; i < nincdir; i++){
		seprint(buf, buf+sizeof(buf), "%s/%s", incdir[i], path);
		b = Bopen(buf, OREAD);
		if(b != nil){
			secpy(opened, opened+openlen, buf);
			return b;
		}
		/* allow import "sys" to find sys.ei */
		if(strstr(path, ".ei") == nil){
			seprint(buf, buf+sizeof(buf), "%s/%s.ei", incdir[i], path);
			b = Bopen(buf, OREAD);
			if(b != nil){
				secpy(opened, opened+openlen, buf);
				return b;
			}
		}
	}
	b = Bopen(path, OREAD);
	if(b != nil)
		secpy(opened, opened+openlen, path);
	else if(strstr(path, ".ei") == nil){
		seprint(buf, buf+sizeof(buf), "%s.ei", path);
		b = Bopen(buf, OREAD);
		if(b != nil)
			secpy(opened, opened+openlen, buf);
	}
	USED(b);
	return b;
}

/*
 * map a surface type expression to a backend type while binding
 * names against the interface module under construction.
 */
static Type *itype(Node*, Decl*);
static Decl *findtype(Decl*, Sym*);

static Decl*
ifields(Node *n, Decl *mod, int store)
{
	Decl *ids, *last, *d;
	Node *f, *names, *id;
	Type *t;

	ids = last = nil;
	for(; n != nil; n = n->right){
		f = n;
		if(n->op == Oseq)
			f = n->left;
		if(f->op != Ofield)
			fatal("bad field in interface");
		t = itype(f->right, mod);
		for(names = f->left; names != nil; names = names->right){
			id = names;
			if(names->op == Oseq)
				id = names->left;
			d = mkdecl(&id->src, store, t);
			d->sym = id->sym;
			d->dot = mod;
			if(ids == nil)
				ids = d;
			else
				last->next = d;
			last = d;
			if(names->op != Oseq)
				break;
		}
		if(n->op != Oseq)
			break;
	}
	return ids;
}

static int rawfn;	/* the next Otfunc is a function declaration's own signature */

static Type*
itype(Node *n, Decl *mod)
{
	Type *t, *ft;
	Decl *d, *args, *last, *id;
	Node *p, *ids;
	char buf[32];
	int i;
	int raw;

	if(n == nil)
		return tnone;
	switch(n->op){
	case Otarray:
		return mktype(&n->src, Tarray, itype(n->right, mod), nil);
	case Otchan:
		return mktype(&n->src, Tchan, itype(n->right, mod), nil);
	case Otlist:
		return mktype(&n->src, Tlist, itype(n->right, mod), nil);
	case Otref:
		return mktype(&n->src, Tref, itype(n->right, mod), nil);
	case Otstruct:
		t = mktype(&n->src, Tadt, nil, ifields(n->left, mod, Dfield));
		t->ok |= OKverify;
		return t;
	case Otpick:
		/* tags filled by typedec */
		t = mktype(&n->src, Tadt, nil, nil);
		t->ok |= OKverify;
		return t;
	case Ottuple: {
		Decl *idl;

		idl = last = nil;
		i = 0;
		for(p = n->left; p != nil; p = p->right){
			Node *tn;

			tn = p;
			if(p->op == Oseq)
				tn = p->left;
			d = mkdecl(&tn->src, Dfield, itype(tn, mod));
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
	case Otfunc:
		raw = rawfn;
		rawfn = 0;
		args = last = nil;
		ft = mktype(&n->src, Tfn, tnone, nil);
		for(p = n->left; p != nil; p = p->right){
			Node *f;

			f = p;
			if(p->op == Oseq)
				f = p->left;
			if(f->flags & NVARARG && f->right == nil && f->left == nil){
				ft->varargs = 1;
				if(p->op != Oseq)
					break;
				continue;
			}
			if(f->flags & NVARARG)
				ft->varargs = 1;
			t = itype(f->right, mod);
			if(f->left == nil){
				/*
				 * an unnamed parameter, a function type's
				 * "func(int) int": it was skipped, so every
				 * function-typed variable, field or parameter
				 * in an interface lost its parameters -- caught
				 * by the module's own interface check
				 */
				d = mkdecl(&f->src, Darg, t);
				d->sym = nil;
				if(args == nil)
					args = d;
				else
					last->next = d;
				last = d;
			}else
			for(ids = f->left; ids != nil; ids = ids->right){
				Node *nid;

				nid = ids;
				if(ids->op == Oseq)
					nid = ids->left;
				d = mkdecl(&nid->src, Darg, t);
				d->sym = nid->sym;
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
			ft->tof = itype(n->right, mod);
		if(raw)
			return ft;
		/* a value type: the closure shape, as check.c's stype() */
		return mktype(&n->src, Tref, envfn(&n->src, ft), nil);
	case Oname:
		/* search module members, then builtins */
		if(mod != nil && mod->ty != nil){
			for(id = mod->ty->ids; id != nil; id = id->next)
				if(id->sym == n->sym && id->store == Dtype)
					return id->ty;
		}
		if(n->sym->decl != nil && n->sym->decl->store == Dtype)
			return n->sym->decl->ty;
		error(n->src.start, "unknown type %s", n->sym->name);
		return terror;
	case Odot:
		/* alias.Type: a type from an interface this one imports */
		if(mod != nil && mod->ty != nil && n->left != nil && n->left->op == Oname){
			for(id = mod->ty->ids; id != nil; id = id->next)
				if(id->store == Dimport && id->sym == n->left->sym)
					break;
			if(id == nil){
				error(n->src.start, "%s is not an imported interface", n->left->sym->name);
				return terror;
			}
			d = findtype(id->importid, n->right != nil ? n->right->sym : n->sym);
			if(d == nil){
				error(n->src.start, "%s has no type %s", n->left->sym->name,
					n->right != nil ? n->right->sym->name : n->sym->name);
				return terror;
			}
			return d->ty;
		}
		error(n->src.start, "bad qualified type");
		return terror;
	default:
		error(n->src.start, "unsupported interface type %O", n->op);
		return terror;
	}
}

static void
installmember(Decl *mod, Decl *d)
{
	d->dot = mod;
	d->next = nil;
	if(mod->ty->ids == nil)
		mod->ty->ids = d;
	else{
		Decl *e;

		for(e = mod->ty->ids; e->next != nil; e = e->next)
			;
		e->next = d;
	}
}

/*
 * replace, in a constant's initializer, every name of one of mod's
 * own already-declared constants by a copy of that constant's literal
 */
static void
iconstnames(Node *n, Decl *mod)
{
	Decl *id;

	if(n == nil)
		return;
	if(n->op == Oname){
		for(id = mod->ty->ids; id != nil; id = id->next)
			if(id->store == Dconst && id->sym == n->sym && id->init != nil && id->init->op == Oconst){
				Src src;

				src = n->src;
				*n = *id->init;
				n->src = src;
				return;
			}
		return;
	}
	iconstnames(n->left, mod);
	iconstnames(n->right, mod);
}

static Decl*
findtype(Decl *mod, Sym *s)
{
	Decl *id;

	for(id = mod->ty->ids; id != nil; id = id->next)
		if(id->sym == s && id->store == Dtype)
			return id;
	return nil;
}

static void
bindiface(Decl *mod, Node *tree)
{
	Node *n, *decl;
	Decl *d, *td;
	Type *t;

	/* pass 1: publish every type name so forward refs share one Type* */
	for(n = tree->right; n != nil; n = n->right){
		decl = n;
		if(n->op == Oseq)
			decl = n->left;
		if(decl->op == Oimport){
			/*
			 * "import sys "sys"" inside an interface: another
			 * interface's types are referenced as alias.Type
			 * (itype's Odot case) -- bufio's Iobuf carries a
			 * "ref sys.FD" field, and nearly every real library
			 * refers to Sys's types somewhere.  read it through
			 * the same readiface() the main module uses (and its
			 * cache, so an interface reached both ways yields the
			 * same Type objects, structurally and by identity),
			 * and record the alias as a Dimport member: never
			 * exported (mkiface() ignores the store), never
			 * reachable as alias.sys from a client (echk's Odot
			 * refuses it).  the module's own type name is
			 * published too, as a Dtype member of Tmodule kind,
			 * so a module type can appear in a signature
			 * (bufio's setfill(f BufioFill)).
			 */
			Decl *m, *a;
			Sym *alias;

			m = readiface(decl->right->sym->name, &decl->src);
			if(m == nil){
				error(decl->src.start, "cannot import %s", decl->right->sym->name);
				if(n->op != Oseq)
					break;
				continue;
			}
			alias = decl->left != nil ? decl->left->sym : m->sym;
			a = mkdecl(&decl->src, Dimport, m->ty);
			a->sym = alias;
			a->importid = m;
			installmember(mod, a);
			if(findtype(mod, m->sym) == nil){
				a = mkdecl(&decl->src, Dtype, m->ty);
				a->sym = m->sym;
				installmember(mod, a);
			}
		}
		if(decl->op == Otypedecl && findtype(mod, decl->left->sym) == nil){
			td = mkdecl(&decl->src, Dtype, nil);
			td->sym = decl->left->sym;
			td->ty = mktype(&decl->src, Tadt, nil, nil);
			td->ty->decl = td;
			installmember(mod, td);
		}
		if(n->op != Oseq)
			break;
	}

	for(n = tree->right; n != nil; n = n->right){
		decl = n;
		if(n->op == Oseq)
			decl = n->left;
		switch(decl->op){
		case Otypedecl:
			td = findtype(mod, decl->left->sym);
			if(td == nil)
				fatal("typedecl missing after pass 1");
			/*
			 * fill the placeholder in place so earlier ref Type*
			 * aliases stay valid.
			 */
			t = td->ty;
			if(decl->right->op == Otstruct){
				t->kind = Tadt;
				t->ids = ifields(decl->right->left, mod, Dfield);
				t->ok |= OKverify;
			}else if(decl->right->op == Otpick){
				Decl *tags, *last, *tag;
				Node *p, *tg;
				int ntag;

				t->kind = Tadt;
				t->ok |= OKverify;
				tags = last = nil;
				ntag = 0;
				for(p = decl->right->left; p != nil; p = p->right){
					tg = p;
					if(p->op == Oseq)
						tg = p->left;
					tag = mkdecl(&tg->src, Dtag, nil);
					tag->sym = tg->left->sym;
					/* the discriminant, in declaration order --
					 * the same numbering check.c's typedec() gives
					 * the implementing module's own tags; unset,
					 * every tag was 0 on the client side */
					tag->tag = ntag++;
					tag->ty = mktype(&tg->src, Tadtpick, nil,
						ifields(tg->right, mod, Dfield));
					tag->ty->tof = t;
					tag->ty->decl = tag;
					tag->dot = td;
					if(tags == nil)
						tags = tag;
					else
						last->next = tag;
					last = tag;
					if(p->op != Oseq)
						break;
				}
				t->tags = tags;
			}else{
				Type *nt;

				nt = itype(decl->right, mod);
				*t = *nt;
				t->decl = td;
			}
			td->dot = mod;
			break;
		case Ocondecl:
			d = mkdecl(&decl->src, Dconst, nil);
			d->sym = decl->left->sym;
			/*
			 * an interface's initializers are never echk()'d
			 * (nothing is in scope), so: replace names of this
			 * interface's earlier constants by their literals,
			 * then fold literals through check.c's
			 * foldconstexpr() -- "const Degree = Pi / 180.0",
			 * "const NaN = 0.0 / 0.0", "const EOF = -1".
			 */
			iconstnames(decl->right, mod);
			foldconstexpr(decl->right);
			d->init = decl->right;
			if(decl->right->op == Oconst){
				if(decl->right->flags & NSTR)
					d->ty = tstring;
				else if(decl->right->flags & NREAL)
					d->ty = treal;
				else
					d->ty = tint;
				/*
				 * confold() (check.c) copies the initializer's
				 * own ty onto every use; nothing else ever types
				 * this node, so a client's "bufio.OWRITE" read
				 * back as a nil-typed constant ("cannot use nil
				 * as int") until this was set.
				 */
				decl->right->ty = d->ty;
			}else
				d->ty = tunknown;
			installmember(mod, d);
			break;
		case Ovardecl:
			/* module data: ids [type] [= init] */
			{
				Node *names, *id;

				t = itype(decl->right, mod);
				for(names = decl->left; names != nil; names = names->right){
					id = names;
					if(names->op == Oseq)
						id = names->left;
					d = mkdecl(&id->src, Dglobal, t);
					d->sym = id->sym;
					installmember(mod, d);
					if(names->op != Oseq)
						break;
				}
			}
			break;
		case Ofndecl:
			if(decl->right != nil && decl->right->aux != nil){
				/* a generic is instantiated from its body, which an interface has not */
				error(decl->src.start, "generic function %s cannot be declared in an interface",
					decl->left->op == Omethod ? decl->left->right->sym->name : decl->left->sym->name);
				break;
			}
			rawfn = 1;
			if(decl->aux != nil){
				error(decl->src.start, "function body not allowed in interface");
				break;
			}
			t = itype(decl->right, mod);
			rawfn = 0;
			if(decl->left->op == Omethod){
				/*
				 * "func (h ref HashTable) find(key string) ref
				 * HashVal": a method of an adt this interface
				 * declares.  built exactly the way check.c's
				 * fndecl() builds an implementing module's own
				 * methods: the receiver is an implicit first
				 * parameter (rtsign() signs it SIGSELF, matching
				 * limbo's "self"), the Dfn's dot is the adt's own
				 * Dtype (disw.c names its link entry "Type.method"
				 * off that, on both the import and export sides),
				 * and it's chained on the adt's meths so recv.m(...)
				 * resolves through echk()'s ordinary bound-method
				 * lookup -- Ocall then dispatches it through the
				 * import alias (its Omdot rewrite) since the Dfn's
				 * dot->dot is this module, not impdecl.  it's still
				 * a module member (installmember) so mkiface()
				 * gives it a link-table slot; modmember() skips
				 * methods so "alias.find" can't reach it directly.
				 */
				Node *recv;
				Type *rt, *bt;
				Decl *rd;

				recv = decl->left->left;
				rt = itype(recv->right, mod);
				bt = rt;
				if(bt->kind == Tref)
					bt = bt->tof;
				if(bt->kind != Tadt || bt->decl == nil){
					error(decl->src.start, "receiver type must be a struct or ref struct declared in this interface");
					break;
				}
				rd = mkdecl(&recv->left->src, Darg, rt);
				rd->sym = recv->left->sym;
				rd->implicit = 1;
				rd->next = t->ids;
				t->ids = rd;
			}
			t->ok |= OKverify;
			sizetype(t);
			{
				Decl *a;

				for(a = t->ids; a != nil; a = a->next)
					sizetype(a->ty);
				sizetype(t->tof);
			}
			d = mkdecl(&decl->src, Dfn, t);
			d->offset = idoffsets(t->ids, MaxTemp, IBY2WD);
			if(decl->left->op == Omethod){
				Type *bt;

				bt = t->ids->ty;
				if(bt->kind == Tref)
					bt = bt->tof;
				d->sym = decl->left->right->sym;
				installmember(mod, d);
				d->dot = bt->decl;
				d->link = bt->meths;
				bt->meths = d;
			}else{
				d->sym = decl->left->sym;
				installmember(mod, d);
			}
			break;
		case Oimport:
			/* handled in pass 1 above */
			break;
		default:
			error(decl->src.start, "unsupported interface declaration %O", decl->op);
			break;
		}
		if(n->op != Oseq)
			break;
	}

	/* size every member first; teqclass requires OKsized on adts */
	for(d = mod->ty->ids; d != nil; d = d->next)
		if(d->ty != nil)
			sizetype(d->ty);
	for(d = mod->ty->ids; d != nil; d = d->next)
		if(d->ty != nil && (d->store == Dfn || d->store == Dtype || d->store == Dglobal))
			teqclass(d->ty);
	/*
	 * imported modules start with linkall=0 so unused members
	 * can be stripped from the LDT (see narrowmods).
	 */
	sizetype(mod->ty);
	teqclass(mod->ty);
}

/*
 * the module's own interface -- limbo's "include m.m": <module>.ei
 * (the module name lowercased) beside the source file, else on the
 * include path.  nil, silently, when there is none: then nothing
 * beyond the functions is exported.  the checker verifies the
 * variables it declares against the implementation and exports
 * exactly those, laid out as the interface's .mp record, so an
 * importer can address them.
 */
Decl*
readownface(char *modname, char *srcfile)
{
	char name[256], path[1024], *p;
	Biobuf *b;
	int i, n;

	n = 0;
	for(p = modname; *p != '\0' && n < sizeof(name)-4; p++)
		name[n++] = *p >= 'A' && *p <= 'Z' ? *p - 'A' + 'a' : *p;
	strcpy(name+n, ".ei");

	p = strrchr(srcfile, '/');
	if(p != nil)
		seprint(path, path+sizeof(path), "%s%.*s/%s", srcfile[0] == '/' ? "" : "./", (int)(p - srcfile), srcfile, name);
	else
		seprint(path, path+sizeof(path), "./%s", name);
	b = Bopen(path, OREAD);
	if(b != nil){
		Bterm(b);
		return readiface(path, nil);
	}
	for(i = 0; i < nincdir; i++){
		seprint(path, path+sizeof(path), "%s%s/%s", incdir[i][0] == '/' || incdir[i][0] == '.' ? "" : "./", incdir[i], name);
		b = Bopen(path, OREAD);
		if(b != nil){
			Bterm(b);
			return readiface(path, nil);
		}
	}
	return nil;
}

Decl*
readiface(char *path, Src *src)
{
	Iface *ic;
	Decl *mod;
	Node *tree;
	Biobuf *b;
	char opened[512];
	char *savedinfile;
	Node *savedtree;
	int savederrors;

	USED(src);
	for(ic = ifaces; ic != nil; ic = ic->next)
		if(strcmp(ic->path, path) == 0)
			return ic->d;

	b = openiface(path, opened, sizeof opened);
	if(b == nil){
		fprint(2, "ember: can't open interface %s\n", path);
		errors++;
		return nil;
	}
	Bterm(b);	/* parse opens the file itself */

	ic = allocmem(sizeof *ic);
	ic->path = allocmem(strlen(path)+1);
	strcpy(ic->path, path);
	ic->d = nil;
	ic->next = ifaces;
	ifaces = ic;

	savedinfile = infile;
	savedtree = tree;
	savederrors = errors;
	tree = nil;
	infile = opened;
	tree = parse(opened);
	if(tree == nil || tree->op != Omodule){
		fprint(2, "ember: %s: expected module interface\n", opened);
		errors++;
		infile = savedinfile;
		tree = savedtree;
		return nil;
	}

	mod = mkdecl(&tree->src, Dtype, nil);
	mod->sym = tree->left->sym;
	mod->ty = mktype(&tree->src, Tmodule, nil, nil);
	mod->ty->decl = mod;

	/*
	 * temporarily publish builtin type names on the symbol table
	 * so interface type expressions resolve (int, string, ...).
	 */
	{
		Decl *bint, *bbig, *bbyte, *breal, *bstr;
		Decl *oldint, *oldbig, *oldbyte, *oldreal, *oldstr;

		bint = mkdecl(&nosrc, Dtype, tint);
		bint->sym = enter("int", 0);
		oldint = bint->sym->decl;
		bint->sym->decl = bint;

		bbig = mkdecl(&nosrc, Dtype, tbig);
		bbig->sym = enter("big", 0);
		oldbig = bbig->sym->decl;
		bbig->sym->decl = bbig;

		bbyte = mkdecl(&nosrc, Dtype, tbyte);
		bbyte->sym = enter("byte", 0);
		oldbyte = bbyte->sym->decl;
		bbyte->sym->decl = bbyte;

		breal = mkdecl(&nosrc, Dtype, treal);
		breal->sym = enter("real", 0);
		oldreal = breal->sym->decl;
		breal->sym->decl = breal;

		bstr = mkdecl(&nosrc, Dtype, tstring);
		bstr->sym = enter("string", 0);
		oldstr = bstr->sym->decl;
		bstr->sym->decl = bstr;

		bindiface(mod, tree);

		bint->sym->decl = oldint;
		bbig->sym->decl = oldbig;
		bbyte->sym->decl = oldbyte;
		breal->sym->decl = oldreal;
		bstr->sym->decl = oldstr;
	}

	ic->d = mod;
	infile = savedinfile;
	tree = savedtree;
	USED(savederrors);
	return mod;
}
