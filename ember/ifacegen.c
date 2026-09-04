#include "ember.h"

/*
 * "ember -i file.e": derive the module's interface file (.ei) from its
 * checked declarations, in source order: imports, constants, types
 * (interfaces printed as declared), variables, and the signatures of
 * functions and methods.  Generic and inline declarations carry
 * bodies an interface must repeat, so they are left to be written by
 * hand, with a comment saying so.  Hidden names (leading '.') are
 * the compiler's own and are skipped, except an interface's struct,
 * which stands for the interface.
 */

static Biobuf *ib;

static char*
aliasof(Decl *m)
{
	Dlist *dl;

	if(m == nil || m == impdecl)
		return nil;
	for(dl = imports; dl != nil; dl = dl->next)
		if(dl->d->importid == m)
			return dl->d->sym->name;
	return m->sym->name;
}

static void tsrc(Type *t);

static void
paramsrc(Decl *id, int skip)
{
	int first;

	first = 1;
	for(; id != nil; id = id->next){
		if(skip > 0){
			skip--;
			continue;
		}
		if(!first)
			Bprint(ib, ", ");
		first = 0;
		if(id->sym != nil && id->sym->name[0] != '.')
			Bprint(ib, "%s ", id->sym->name);
		tsrc(id->ty);
	}
}

static void
fnsrc(Type *t, int skip)
{
	Bprint(ib, "(");
	paramsrc(t->ids, skip);
	Bprint(ib, ")");
	if(t->tof != nil && t->tof->kind != Tnone){
		Bprint(ib, " ");
		tsrc(t->tof);
	}
}

static void
tsrc(Type *t)
{
	Decl *id;
	char *alias;

	if(t == nil){
		Bprint(ib, "nil");
		return;
	}
	if(t->named && t->decl != nil){
		Bprint(ib, "%s", t->decl->sym->name);	/* "type Color int": its own name */
		return;
	}
	switch(t->kind){
	case Tint:	Bprint(ib, "int"); return;
	case Tbig:	Bprint(ib, "big"); return;
	case Tbyte:	Bprint(ib, "byte"); return;
	case Treal:	Bprint(ib, "real"); return;
	case Tstring:	Bprint(ib, "string"); return;
	case Tbool:	Bprint(ib, "bool"); return;
	case Tref:
		if(t->tof != nil && t->tof->kind == Tfn && t->tof->hasenv){
			Bprint(ib, "func");
			fnsrc(t->tof, 1);
			return;
		}
		if(t->tof != nil && t->tof->kind == Tadt && t->tof->ismap){
			/* map[K]V: the key and value types from the entry */
			Type *ent;

			ent = t->tof->ids->ty->tof->tof;
			Bprint(ib, "map[");
			tsrc(ent->ids->ty);
			Bprint(ib, "]");
			tsrc(ent->ids->next->ty);
			return;
		}
		if(t->tof != nil && t->tof->kind == Tadt && t->tof->isiface && t->tof->decl != nil){
			/* ref .W$s is the interface W */
			char *s;

			s = t->tof->decl->sym->name;
			alias = aliasof(t->tof->decl->dot);
			if(alias != nil)
				Bprint(ib, "%s.", alias);
			Bprint(ib, "%.*s", (int)(strlen(s) - 3), s + 1);
			return;
		}
		Bprint(ib, "ref ");
		tsrc(t->tof);
		return;
	case Tarray:
		Bprint(ib, "[]");
		tsrc(t->tof);
		return;
	case Tlist:
		Bprint(ib, "list ");
		tsrc(t->tof);
		return;
	case Tchan:
		Bprint(ib, "chan ");
		tsrc(t->tof);
		return;
	case Tadtpick:
		alias = t->decl != nil ? aliasof(t->decl->dot != nil ? t->decl->dot->dot : nil) : nil;
		if(alias != nil)
			Bprint(ib, "%s.", alias);
		Bprint(ib, "%s.%s", t->decl->dot->sym->name, t->decl->sym->name);
		return;
	case Tadt:
	case Tpoly:
		if(t->decl != nil && t->decl->sym != nil){
			alias = aliasof(t->decl->dot);
			if(alias != nil)
				Bprint(ib, "%s.", alias);
			Bprint(ib, "%s", t->decl->sym->name);
			if(t->gtemplate != nil && t->ginst != nil){
				/* an instance: Box[int] */
				int i;

				Bprint(ib, "[");
				for(i = 0; i < t->ginst->nargs; i++){
					if(i > 0)
						Bprint(ib, ", ");
					tsrc(t->ginst->args[i]);
				}
				Bprint(ib, "]");
			}
			return;
		}
		Bprint(ib, "%s", kindname[t->kind]);
		return;
	case Ttuple:
		Bprint(ib, "(");
		for(id = t->ids; id != nil; id = id->next){
			tsrc(id->ty);
			if(id->next != nil)
				Bprint(ib, ", ");
		}
		Bprint(ib, ")");
		return;
	case Tfn:
		Bprint(ib, "func");
		fnsrc(t, 0);
		return;
	default:
		Bprint(ib, "%s", kindname[t->kind]);
		return;
	}
}

static void
fieldsrc(Decl *id, char *indent)
{
	for(; id != nil; id = id->next){
		Bprint(ib, "%s%s ", indent, id->sym->name);
		tsrc(id->ty);
		Bprint(ib, "\n");
	}
}

static void
constsrc(Node *n)
{
	if(n->flags & NSTR){
		strprint(ib, n->sym->name);
		return;
	}
	if(n->flags & NREAL){
		Bprint(ib, "%g", n->rval);
		return;
	}
	if(n->ty == tbig)
		Bprint(ib, "big(%lld)", (vlong)n->val);
	else
		Bprint(ib, "%lld", (vlong)n->val);
}

static void
typesrc(Decl *d)
{
	Type *t;
	Decl *tg, *m;
	char *s;

	t = d->ty;
	s = d->sym->name;
	if(t->named){
		/* "type Color int": the base type, then its methods */
		Bprint(ib, "type %s ", s);
		t->named = 0;
		tsrc(t);
		t->named = 1;
		Bprint(ib, "\n\n");
		return;
	}
	if(t->kind == Tadt && t->isiface){
		/* .W$s: print the interface it stands for */
		Bprint(ib, "type %.*s interface {\n", (int)(strlen(s) - 3), s + 1);
		for(m = t->ids; m != nil; m = m->next){
			if(m->sym->name[0] == '.')
				continue;	/* .self and .tag, the converter's own */
			Bprint(ib, "\t%s", m->sym->name);
			fnsrc(m->ty->tof, 1);
			Bprint(ib, "\n");
		}
		Bprint(ib, "}\n\n");
		return;
	}
	if(s[0] == '.')
		return;
	if(d->tparams != nil || (t->kind == Tadt && t->tparams != nil)){
		Bprint(ib, "// generic type %s: an interface repeats its body; write it by hand\n\n", s);
		return;
	}
	if(t->kind == Tadt && t->tags != nil){
		Bprint(ib, "type %s pick {\n", s);
		fieldsrc(t->ids, "\t");
		for(tg = t->tags; tg != nil; tg = tg->next){
			Bprint(ib, "\t%s(", tg->sym->name);
			paramsrc(tg->ty->ids, 0);
			Bprint(ib, ")\n");
		}
		Bprint(ib, "}\n\n");
		return;
	}
	if(t->kind == Tadt && t->decl == d){
		Bprint(ib, "type %s struct {\n", s);
		fieldsrc(t->ids, "\t");
		Bprint(ib, "}\n\n");
		return;
	}
	Bprint(ib, "type %s ", s);
	tsrc(t);
	Bprint(ib, "\n\n");
}

static void
methodsrc(Decl *d, char *tname)
{
	Decl *recv;

	if(d->tparams != nil){
		Bprint(ib, "// generic method %s.%s: write it by hand\n", tname, d->sym->name);
		return;
	}
	recv = d->ty->ids;
	Bprint(ib, "func (%s ", recv->sym->name);
	tsrc(recv->ty);
	Bprint(ib, ") %s", d->sym->name);
	fnsrc(d->ty, 1);
	Bprint(ib, "\n");
}

void
ifacegen(Node *tree, Biobuf *b)
{
	Node *p, *decl;
	Decl *d, *m;
	Dlist *dl;
	int n, anyexport;

	ib = b;
	anyexport = 0;
	for(p = tree->right; p != nil; p = p->right){
		decl = p->op == Oseq ? p->left : p;
		if(decl->val & 2)
			anyexport = 1;
		if(p->op != Oseq)
			break;
	}
	Bprint(ib, "module %s\n\n", tree->left->sym->name);
	Bprint(ib, "// derived by ember -i; generic and inline declarations are not\n// derived, an interface must carry their bodies\n\n");
	n = 0;
	for(p = tree->right; p != nil; p = p->right){
		decl = p;
		if(p->op == Oseq)
			decl = p->left;
		if(decl->op == Oimport){
			if(decl->left != nil)
				Bprint(ib, "import %s \"%s\"\n", decl->left->sym->name, decl->right->sym->name);
			else
				Bprint(ib, "import \"%s\"\n", decl->right->sym->name);
			n++;
		}
		if(p->op != Oseq)
			break;
	}
	if(n > 0)
		Bprint(ib, "\n");
	for(p = tree->right; p != nil; p = p->right){
		decl = p;
		if(p->op == Oseq)
			decl = p->left;
		if(anyexport && !(decl->val & 2) && decl->op != Oimport){
			if(p->op != Oseq)
				break;
			continue;	/* not exported */
		}
		switch(decl->op){
		case Ocondecl:
			if(decl->left->sym->name[0] == '.' || decl->right->op != Oconst)
				break;
			Bprint(ib, "const %s = ", decl->left->sym->name);
			constsrc(decl->right);
			Bprint(ib, "\n");
			break;
		case Otypedecl:
			d = decl->left->sym->decl;
			if(d == nil || d->store != Dtype)
				break;
			if(d->ty->kind == Tref && d->ty->tof != nil && d->ty->tof->kind == Tadt && d->ty->tof->isiface)
				break;	/* "type W ref .W$s": the interface was printed with its struct */
			typesrc(d);
			if((d->ty->kind == Tadt || d->ty->named) && !d->ty->isiface && d->sym->name[0] != '.'){
				/* meths is prepended: print in declaration order */
				Decl *ms[256];

				n = 0;
				for(m = d->ty->meths; m != nil && n < 256; m = m->link)
					ms[n++] = m;
				while(n > 0)
					methodsrc(ms[--n], d->sym->name);
				if(d->ty->meths != nil)
					Bprint(ib, "\n");
			}
			break;
		case Ovardecl: {
			Node *names, *id;

			for(names = decl->left; names != nil; names = names->right){
				id = names;
				if(names->op == Oseq)
					id = names->left;
				d = id->sym->decl;
				if(d != nil && d->store == Dglobal){
					Bprint(ib, "var %s ", d->sym->name);
					tsrc(d->ty);
					Bprint(ib, "\n");
				}
				if(names->op != Oseq)
					break;
			}
			break;
		}
		case Ofndecl:
			if(decl->left->op == Omethod)
				break;	/* printed with its type */
			if(decl->left->sym->name[0] == '.')
				break;
			d = decl->left->sym->decl;
			if(d == nil || d->store != Dfn)
				break;
			if(d->tparams != nil){
				Bprint(ib, "// generic function %s: write it by hand\n", d->sym->name);
				break;
			}
			if(strcmp(d->sym->name, "init") == 0)
				break;
			Bprint(ib, "func %s", d->sym->name);
			fnsrc(d->ty, 0);
			Bprint(ib, "\n");
			break;
		}
		if(p->op != Oseq)
			break;
	}
}
