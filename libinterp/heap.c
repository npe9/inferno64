#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "pool.h"
#include "raise.h"

void	freearray(Heap*, int);
void	freelist(Heap*, int);
void	freemodlink(Heap*, int);
void	freechan(Heap*, int);
Type	Tarray = { 1, freearray, markarray, sizeof(Array) };
Type	Tstring = { 1, freestring, noptrs, sizeof(String) };
Type	Tlist = { 1, freelist, marklist, sizeof(List) };
Type	Tmodlink = { 1, freemodlink, markheap, -1, 1, 0, 0, { 0x80 } };
Type	Tchannel = { 1, freechan, markheap, sizeof(Channel), 1,0,0,{0x80} };
Type	Tptr = { 1, 0, markheap, sizeof(WORD*), 1, 0, 0, { 0x80 } };
Type	Tbyte = { 1, 0, 0, 1 };
Type Tword = { 1, 0, 0, sizeof(WORD) };
Type Tlong = { 1, 0, 0, sizeof(LONG) };
Type Treal = { 1, 0, 0, sizeof(REAL) };

extern	Pool*	heapmem;
extern	int	mutator;

void	(*heapmonitor)(int, void*, ulong);

#define	BIT(bt, nb)	(bt & (1<<nb))

/*
 * By the time destroy() fires from either of freeptrs()'s two
 * callers (OP(ret), OP(mcall)'s native branch), R.FP has already
 * been restored to the *caller's* frame -- xec.c does "R.FP = f->fp"
 * before calling freeptrs(f, f->t), not after.  destroy()'s own
 * probe reading R.FP therefore names the wrong frame's bounds.  Set
 * here, right where the real v/t/slot are still in hand, so
 * destroy() can read the frame that actually owned the bad slot
 * instead.  See doc/inferno-ports.ms.
 */
void *freeptrsv;
Type *freeptrst;
WORD **freeptrsslot;

void
freeptrs(void *v, Type *t)
{
	int c;
	WORD **w, *x;
	uchar *p, *ep;

	if(t->np == 0)
		return;

	freeptrsv = v;
	freeptrst = t;
	w = (WORD**)v;
	p = t->map;
	ep = p + t->np;
	while(p < ep) {
		c = *p;
		if(c != 0) {
 			if(BIT(c, 0) && (x = w[7]) != H) { freeptrsslot = &w[7]; destroy(x); }
			if(BIT(c, 1) && (x = w[6]) != H) { freeptrsslot = &w[6]; destroy(x); }
 			if(BIT(c, 2) && (x = w[5]) != H) { freeptrsslot = &w[5]; destroy(x); }
			if(BIT(c, 3) && (x = w[4]) != H) { freeptrsslot = &w[4]; destroy(x); }
			if(BIT(c, 4) && (x = w[3]) != H) { freeptrsslot = &w[3]; destroy(x); }
			if(BIT(c, 5) && (x = w[2]) != H) { freeptrsslot = &w[2]; destroy(x); }
			if(BIT(c, 6) && (x = w[1]) != H) { freeptrsslot = &w[1]; destroy(x); }
			if(BIT(c, 7) && (x = w[0]) != H) { freeptrsslot = &w[0]; destroy(x); }
		}
		p++;
		w += 8;
	}
}

/*
void
nilptrs(void *v, Type *t)
{
	int c, i;
	WORD **w;
	uchar *p, *ep;

	w = (WORD**)v;
	p = t->map;
	ep = p + t->np;
	while(p < ep) {
		c = *p;
		for(i = 0; i < 8; i++){
			if(BIT(c, 7)) *w = H;
			c <<= 1;
			w++;
		}
		p++;
	}
}
*/

void
freechan(Heap *h, int swept)
{
	Channel *c;

	USED(swept);
	c = H2D(Channel*, h);
	if(c->mover == movtmp)
		freetype(c->mid.t);
	killcomm(&c->send);
	killcomm(&c->recv);
	if (!swept && c->buf != H)
		destroy(c->buf);
}

void
freestring(Heap *h, int swept)
{
	String *s;

	USED(swept);
	s = H2D(String*, h);
	if(s->tmp != nil)
		free(s->tmp);
}

void
freearray(Heap *h, int swept)
{
	int i;
	Type *t;
	uchar *v;
	Array *a;

	a = H2D(Array*, h);
	t = a->t;

	if(!swept) {
		if(a->root != H)
			destroy(a->root);
		else
		if(t->np != 0) {
			v = a->data;
			for(i = 0; i < a->len; i++) {
				freeptrs(v, t);
				v += t->size;
			}
		}
	}
	if(ADEC(&t->ref) == 0) {
		freejitcode(t->initialize);
		free(t);
	}
}

void
freelist(Heap *h, int swept)
{
	Type *t;
	List *l;
	Heap *th;

	l = H2D(List*, h);
	t = l->t;

	if(t != nil) {
		if(!swept && t->np)
			freeptrs(l->data, t);
		if(ADEC(&t->ref) == 0) {
			freejitcode(t->initialize);
			free(t);
		}
	}
	if(swept)
		return;
	l = l->tail;
	while(l != (List*)H) {
		t = l->t;
		th = D2H(l);
		if(ADEC(&th->ref) != 0)
			break;
		ADEC(&th->t->ref);	/* should be &Tlist and ref shouldn't go to 0 here nor be 0 already */
		if(t != nil) {
			if (t->np)
				freeptrs(l->data, t);
			if(ADEC(&t->ref) == 0) {
				freejitcode(t->initialize);
				free(t);
			}
		}
		l = l->tail;
		if(heapmonitor != nil)
			heapmonitor(1, th, 0);
		/*
		 * Probe, not a fix: destroy() does this same D2B check
		 * immediately before its own poolfree(heapmem, h) call,
		 * but this iterative tail-walk's per-node poolfree(heapmem,
		 * th) never did.  If th is already bad here, freelist() is
		 * downstream of some earlier corruption, not upstream of
		 * it; if this never fires while alloc:D2B/cclone/cclose
		 * keep panicking elsewhere, freelist() itself is cleared.
		 * See doc/inferno-ports.ms.
		 */
		{ Bhdr *b; D2B(b, th); }
		poolfree(heapmem, th);
	}
}

void
freemodlink(Heap *h, int swept)
{
	Modlink *ml;

	ml = H2D(Modlink*, h);
	if(ml->m->rt == DYNMOD)
		freedyndata(ml);
	else if(!swept)
		destroy(ml->MP);
	unload(ml->m);
}

int
heapref(void *v)
{
	return D2H(v)->ref;
}

void
freeheap(Heap *h, int swept)
{
	Type *t;

	if(swept)
		return;

	t = h->t;
	if (t->np)
		freeptrs(H2D(void*, h), t);
}

void
destroy(void *v)
{
	Heap *h;
	Type *t;

	if(v == H)
		return;

	h = D2H(v);

	/*
	 * Probe: destroy(0) has now fired twice, same value both times,
	 * both right as /dis/init starts running -- reproducible, not
	 * random.  getcallerpc() has failed twice running (0x32, then
	 * 0x0, anchored on two different locals) to name a real caller
	 * pc from this early-exit guard, so this round drops it and asks
	 * for the two things that have worked reliably all through this
	 * crash-hunt instead: which Dis Prog/module was running (the
	 * currun() trick dumpregs()/_poolfault() already use) and a raw
	 * dumpstack() -- board-specific, deliberately temporary, revert
	 * once a capture lands.  See doc/inferno-ports.ms.
	 */
	if((uintptr)v < 0x1000) {
		Prog *xp;
		extern void dumpstack(void);

		xp = currun();
		/*
		 * xp->R (currun()'s Prog struct) is only refreshed at the
		 * start and end of xec()'s whole PQUANTA=2048-instruction
		 * quantum, not per instruction -- during the quantum it is
		 * stale by however many instructions have run since entry.
		 * The plain global R is live at exactly this point instead;
		 * see badptrslot()'s comment in xec.c for the full story.
		 */
		if(R.M != nil && R.M->m != nil)
			/*
			 * The instruction index (PC - m->prog) is build-
			 * independent -- a module's own compiled bytecode
			 * doesn't move across kernel rebuilds, unlike the
			 * raw PC pointer -- so it's directly disassemblable
			 * with disdump against the same .dis file later.
			 */
			print("destroy: bad v %p, running Dis pid %d module %s PC %#p inst %d\n",
				v, xp != nil ? xp->pid : -1, R.M->m->name, R.PC,
				(int)(R.PC - R.M->m->prog));
		else
			print("destroy: bad v %p, R.M nil or has no module\n", v);
		/*
		 * R.FP is *not* usable here: both of freeptrs()'s callers
		 * (OP(ret), OP(mcall)'s native branch) restore R.FP to the
		 * caller's frame before calling freeptrs(f, f->t) -- by the
		 * time this fires, R.FP names the wrong frame entirely.
		 * freeptrsv/freeptrst/freeptrsslot (set in freeptrs() itself,
		 * right where the real v/t/slot are still in hand) name the
		 * frame that actually owned this slot, and its exact offset
		 * within it: whether that offset falls inside t->size (where
		 * initmem() should have written H at creation) or beyond it,
		 * in whatever a Stkext's mallocz(l, 0) left unclaimed.  See
		 * doc/inferno-ports.ms.
		 */
		print("destroy: freeptrsv %#p freeptrst->size %d slot %#p "
			"(slot - v = %ld)\n",
			freeptrsv, freeptrst != nil ? freeptrst->size : -1,
			freeptrsslot, (long)((uchar*)freeptrsslot - (uchar*)freeptrsv));
		dumpstack();
		abort();
	}

	{ Bhdr *b; D2B(b, h); }		/* consistency check */

	if(ADEC(&h->ref) > 0 || gchalt > 64) 	/* Protect 'C' thread stack */
		return;

	if(heapmonitor != nil)
		heapmonitor(1, h, 0);
	t = h->t;
	if(t != nil) {
		gclock();
		t->free(h, 0);
		gcunlock();
		freetype(t);
	}
	poolfree(heapmem, h);
}

Type*
dtype(void (*destroy)(Heap*, int), int size, uchar *map, int mapsize)
{
	Type *t;

	t = malloc(sizeof(Type)-sizeof(t->map)+mapsize);
	if(t != nil) {
		t->ref = 1;
		t->free = destroy;
		t->mark = markheap;
		t->size = size;
		t->np = mapsize;
		memmove(t->map, map, mapsize);
	}
	return t;
}

void*
checktype(void *v, Type *t, char *name, int newref)
{
	Heap *h;

	if(v == H || v == nil)
		error(exNilref);
	h = D2H(v);
	if(t == nil || h->t != t)
		errorf("%s: %s", exType, name);
	if(newref){
		AINC(&h->ref);
		Setmark(h);
	}
	return v;
}

void
freetype(Type *t)
{
	if(t == nil || ADEC(&t->ref) > 0)
		return;

	freejitcode(t->initialize);
	free(t);
}

void
incmem(void *vw, Type *t)
{
	Heap *h;
	uchar *p;
	int i, c, m;
	WORD **w, **q, *wp;

	w = (WORD**)vw;
	p = t->map;
	for(i = 0; i < t->np; i++) {
		c = *p++;
		if(c != 0) {
			q = w;
			for(m = 0x80; m != 0; m >>= 1) {
				if((c & m) && (wp = *q) != H) {
					h = D2H(wp);
					AINC(&h->ref);
					Setmark(h);
				}
				q++;
			}
		}
		w += 8;
	}
}

void
scanptrs(void *vw, Type *t, void (*f)(void*))
{
	uchar *p;
	int i, c, m;
	WORD **w, **q, *wp;

	w = (WORD**)vw;
	p = t->map;
	for(i = 0; i < t->np; i++) {
		c = *p++;
		if(c != 0) {
			q = w;
			for(m = 0x80; m != 0; m >>= 1) {
				if((c & m) && (wp = *q) != H)
					f(D2H(wp));
				q++;
			}
		}
		w += 8;
	}
}

void
initmem(Type *t, void *vw)
{
	int c;
	WORD **w;
	uchar *p, *ep;

	w = (WORD**)vw;
	p = t->map;
	ep = p + t->np;
	while(p < ep) {
		c = *p;
		if(c != 0) {
 			if(BIT(c, 0)) w[7] = H;
			if(BIT(c, 1)) w[6] = H;
			if(BIT(c, 2)) w[5] = H;
			if(BIT(c, 3)) w[4] = H;
			if(BIT(c, 4)) w[3] = H;
			if(BIT(c, 5)) w[2] = H;
			if(BIT(c, 6)) w[1] = H;
			if(BIT(c, 7)) w[0] = H;
		}
		p++;
		w += 8;
	}
}

Heap*
nheap(int n)
{
	Heap *h;

	h = poolalloc(heapmem, sizeof(Heap)+n);
	if(h == nil)
		error(exHeap);

	h->t = nil;
	h->ref = 1;
	h->color = mutator;
	if(heapmonitor != nil)
		heapmonitor(0, h, n);

	return h;
}

Heap*
heapz(Type *t)
{
	Heap *h;

	h = poolalloc(heapmem, sizeof(Heap)+t->size);
	if(h == nil)
		error(exHeap);

	h->t = t;
	AINC(&t->ref);
	h->ref = 1;
	h->color = mutator;
	memset(H2D(void*, h), 0, t->size);
	if(t->np)
		initmem(t, H2D(void*, h));
	if(heapmonitor != nil)
		heapmonitor(0, h, t->size);
	return h;
}

Heap*
heap(Type *t)
{
	Heap *h;

	h = poolalloc(heapmem, sizeof(Heap)+t->size);
	if(h == nil)
		error(exHeap);

	h->t = t;
	AINC(&t->ref);
	h->ref = 1;
	h->color = mutator;
	if(t->np)
		initmem(t, H2D(void*, h));
	if(heapmonitor != nil)
		heapmonitor(0, h, t->size);
	return h;
}

Heap*
heaparray(Type *t, int sz)
{
	Heap *h;
	Array *a;

	h = nheap(sizeof(Array) + (t->size*sz));
	h->t = &Tarray;
	AINC(&Tarray.ref);
	a = H2D(Array*, h);
	a->t = t;
	a->len = sz;
	a->root = H;
	a->data = (uchar*)a + sizeof(Array);
	initarray(t, a);
	return h;
}

int
hmsize(void *v)
{
	return poolmsize(heapmem, v);
}

void
initarray(Type *t, Array *a)
{
	int i;
	uchar *p;

	AINC(&t->ref);
	if(t->np == 0)
		return;

	p = a->data;
	for(i = 0; i < a->len; i++) {
		initmem(t, p);
		p += t->size;
	}
}

void*
arraycpy(Array *sa)
{
	int i;
	Heap *dh;
	Array *da;
	uchar *elemp;
	void **sp, **dp;

	if(sa == H)
		return H;

	dh = nheap(sizeof(Array) + sa->t->size*sa->len);
	dh->t = &Tarray;
	AINC(&Tarray.ref);
	da = H2D(Array*, dh);
	da->t = sa->t;
	AINC(&da->t->ref);
	da->len = sa->len;
	da->root = H;
	da->data = (uchar*)da + sizeof(Array);
	if(da->t == &Tarray) {
		dp = (void**)da->data;
		sp = (void**)sa->data;
		/*
		 * Maximum depth of this recursion is set by DADEPTH
		 * in include/isa.h
		 */
		for(i = 0; i < sa->len; i++)
			dp[i] = arraycpy(sp[i]);			
	}
	else {
		memmove(da->data, sa->data, da->len*sa->t->size);
		elemp = da->data;
		for(i = 0; i < sa->len; i++) {
			incmem(elemp, da->t);
			elemp += da->t->size;
		}
	}
	return da;
}

void
newmp(void *dst, void *src, Type *t)
{
	Heap *h;
	int c, i, m;
	void **uld, *wp, **q;

	memmove(dst, src, t->size);
	uld = dst;
	for(i = 0; i < t->np; i++) {
		c = t->map[i];
		if(c != 0) {
			m = 0x80;
			q = uld;
			while(m != 0) {
				if((m & c) && (wp = *q) != H) {
					h = D2H(wp);
					if(h->t == &Tarray)
						*q = arraycpy(wp);
					else {
						AINC(&h->ref);
						Setmark(h);
					}
				}
				m >>= 1;
				q++;
			}
		}
		uld += 8;
	}
}
