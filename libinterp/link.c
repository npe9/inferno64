#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"
#include <kernel.h>

#define DP if(1){}else print

static void
newlink(Link *l, char *fn, int sig, Type *t)
{
	l->name = malloc(strlen(fn)+1);
	if(l->name == nil)
		error(exNomem);
	strcpy(l->name, fn);
	l->sig = sig;
	l->frame = t;
}

void
runtime(Module *m, Link *l, char *fn, int sig, void (*runt)(void*), Type *t)
{
	USED(m);
	newlink(l, fn, sig, t);
	l->u.runt = runt;
}

void
mlink(Module *m, Link* l, uchar *fn, int sig, int pc, Type *t)
{
	newlink(l, (char*)fn, sig, t);
	l->u.pc = m->prog+pc;
}

static int
linkm(Module *m, Modlink *ml, int i, Import *ldt)
{
	Link *l;
	int sig;
	char e[ERRMAX];

	sig = ldt->sig;
	for(l = m->ext; l->name; l++)
		if(strcmp(ldt->name, l->name) == 0){
			DP(" matched l->name %s l->sig 0x%ux\n", l->name, l->sig);
			break;
		}

	if(l == nil) {
		snprint(e, sizeof(e), "link failed fn %s->%s() not implemented",
			m->name, ldt->name);
		goto bad;
	}
	if(l->sig != sig) {
		snprint(e, sizeof(e), "link typecheck %s->%s() %ux/%ux",
			m->name, ldt->name, l->sig, sig);
		goto bad;
	}

	ml->links[i].u = l->u;
	ml->links[i].frame = l->frame;
	ml->links[i].name = l->name;
	return 0;
bad:
	kwerrstr(e);
	print("%s\n", e);
	return -1;
}

Modlink*
mklinkmod(Module *m, int n)
{
	Heap *h;
	Modlink *ml;

	h = nheap(sizeof(Modlink)+(n-1)*sizeof(ml->links[0]));
	h->t = &Tmodlink;
	AINC(&Tmodlink.ref);
	ml = H2D(Modlink*, h);
	ml->nlinks = n;
	ml->m = m;
	ml->prog = m->prog;
	ml->type = m->type;
	ml->compiled = m->compiled;
	ml->MP = H;
	ml->data = nil;
	/*
	 * Probe: ml->MP has been observed holding exactly 0x18 --
	 * H2D(t,0), computing the Heap-header-plus offset on a plain nil
	 * instead of H -- stably, across dozens of GC epochs, in a live,
	 * correctly-typed, correctly-refcounted Modlink object (see
	 * doc/inferno-ports.ms, "Two shapes, one checker").  Every H2D()
	 * call site that can write ml->MP looked properly guarded on
	 * reading -- this validates the write itself, right where it
	 * happens, to catch it at the source if the write is ever wrong
	 * rather than the value going bad sometime after a correct write.
	 * pc64-only, temporary.
	 */
	if(ml->MP != H && (uintptr)ml->MP < 0x1000)
		print("mklinkmod: bad ml->MP %#p right after assignment, ml %#p\n",
			ml->MP, ml);

	return ml;
}
/* Create a Modlink which connects
   the functions in the ldt with their code in Module m
   Module m exports those functions through m->ext
 */
Modlink*
linkmod(Module *m, Import *ldt, int mkmp)
{
	Type *t;
	Heap *h;
	int i;
	Modlink *ml;
	Import *l;

	if(m == nil)
		return H;

	for(i = 0, l = ldt; l->name != nil; i++, l++)
		;
	ml = mklinkmod(m, i);

	if(mkmp){
		if(m->rt == DYNMOD)
			newdyndata(ml);
		else if(mkmp && m->origmp != H && m->ntype > 0) {
			t = m->type[0];
			h = nheap(t->size);
			h->t = t;
			typeinc(t);
			ml->MP = H2D(uchar*, h);
			if(ml->MP != H && (uintptr)ml->MP < 0x1000)
				print("linkmod: bad ml->MP %#p right after H2D, h %#p ml %#p\n",
					ml->MP, h, ml);
			newmp(ml->MP, m->origmp, t);
		}
	}

	for(i = 0, l = ldt; l->name != nil; i++, l++) {
		DP("linkmod connect i %d l->name %s l->sig 0x%ux",
			i, l->name, l->sig);
		if(linkm(m, ml, i, l) < 0){
			destroy(ml);
			return H;
		}
	}

	return ml;
}

void
destroylinks(Module *m)
{
	Link *l;

	for(l = m->ext; l->name; l++)
		free(l->name);
	free(m->ext);
}
