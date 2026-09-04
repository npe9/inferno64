#include "ember.h"

/*
 * "ember -X file.e": every name the file declares and every use of
 * one, with positions and types, as an editor (or a language server)
 * would want them:
 *
 *	decl LINE:COL NAME KIND TYPE
 *	use LINE:COL NAME DECLLINE:DECLCOL TYPE
 *
 * the tree has been checked, so a use carries the declaration the
 * checker resolved it to; names the compiler made for itself (they
 * begin with a dot) are left out, and so are uses whose declaration
 * is elsewhere -- an imported module's member has no position in
 * this file.  positions are the line and the character within it,
 * both counting from 1.
 */

static Biobuf *xb;
static Decl **seen;		/* grown, so that it holds as many as the port's list does */
static int nseen, aseen;

static char*
kindof(Decl *d)
{
	switch(d->store){
	case Dtype:	return "type";
	case Dfn:
		/* a method's dot is its type's declaration; a module member's is the module */
		if(d->dot != nil && d->dot != impdecl && d->dot->store == Dtype && d->dot->ty != nil
		&& (d->dot->ty->kind == Tadt || d->dot->ty->named))
			return "method";
		return "func";
	case Dglobal:	return "global";
	case Dlocal:	return "local";
	case Darg:	return "arg";
	case Dconst:	return "const";
	case Dfield:	return "field";
	case Dtag:	return "tag";
	case Dimport:	return "import";
	}
	return "name";
}

static int
hidden(Sym *s)
{
	return s == nil || s->name == nil || s->name[0] == '.' || s->name[0] == '$';
}

/*
 * where a declaration is: "line:col" in the file being compiled, and
 * "Module:line:col" when it came from an interface, since the line
 * numbers there are that file's own
 */
static char*
declat(Decl *d)
{
	static char buf[256];
	Fline fl;

	fl = fline(d->src.start.line);
	if(d->dot != nil && d->dot != impdecl && d->dot->ty != nil && d->dot->ty->kind == Tmodule)
		seprint(buf, buf+sizeof(buf), "%s:%d:%d", d->dot->sym->name, fl.line, d->src.start.pos + 1);
	else
		seprint(buf, buf+sizeof(buf), "%d:%d", fl.line, d->src.start.pos + 1);
	return buf;
}

/* where a use is: always in the file being compiled */
static char*
useat(Node *n)
{
	static char buf[64];
	Fline fl;

	fl = fline(n->src.start.line);
	seprint(buf, buf+sizeof(buf), "%d:%d", fl.line, n->src.start.pos + 1);
	return buf;
}

/* a method is named for its type, so two "name"s can be told apart */
static char*
fnname(Decl *d)
{
	static char buf[256];

	if(d->dot != nil && d->dot != impdecl && d->dot->store == Dtype)
		seprint(buf, buf+sizeof(buf), "%s.%s", d->dot->sym->name, d->sym->name);
	else
		seprint(buf, buf+sizeof(buf), "%s", d->sym->name);
	return buf;
}

/* a declaration is printed once, the first time a use resolves to it */
static void
xdecl(Decl *d)
{
	int i;

	if(d == nil || hidden(d->sym) || d->src.start.line <= 0)
		return;
	for(i = 0; i < nseen; i++)
		if(seen[i] == d)
			return;
	if(nseen == aseen){
		aseen = aseen != 0 ? aseen * 2 : 512;
		seen = reallocmem(seen, aseen * sizeof(Decl*));
		if(seen == nil)
			fatal("out of memory");
	}
	seen[nseen++] = d;
	Bprint(xb, "decl %s %s %s %T\n", declat(d), d->sym->name, kindof(d), d->ty);
}

static void
xwalk(Node *n)
{
	Type *t;

	if(n == nil)
		return;
	if(n->op == Oname && n->decl != nil && !hidden(n->sym) && n->src.start.line > 0){
		/* a type name used in a literal has no type of its own: name the type */
		t = n->ty != nil ? n->ty : n->decl->ty;
		xdecl(n->decl);
		if(n->decl->src.start.line > 0)
			Bprint(xb, "use %s %s %s %T\n", useat(n), n->sym->name, declat(n->decl), t);
		else
			Bprint(xb, "use %s %s - %T\n", useat(n), n->sym->name, t);
	}
	xwalk(n->left);
	xwalk(n->right);
	xwalk(n->aux);
}

void
xref(Node *tree, Biobuf *b, Decl *fns[], int nfns)
{
	Node *p, *d;
	int i;

	xb = b;
	nseen = 0;
	/* the module's own declarations, in the order they were written */
	for(p = tree->right; p != nil; p = p->right){
		d = p->op == Oseq ? p->left : p;
		switch(d->op){
		case Ofndecl:
			if(d->left->op == Omethod)
				xdecl(d->left->right->sym->decl);
			else
				xdecl(d->left->sym->decl);
			break;
		case Otypedecl:
		case Ocondecl:
			xdecl(d->left->sym->decl);
			break;
		}
		if(p->op != Oseq)
			break;
	}
	/* then every use, function body by function body */
	for(i = 0; i < nfns; i++)
		if(fns[i]->init != nil && fns[i]->init->aux != nil && !hidden(fns[i]->sym)){
			xdecl(fns[i]);
			Bprint(xb, "in %s\n", fnname(fns[i]));
			xwalk(fns[i]->init->aux);
		}
}
