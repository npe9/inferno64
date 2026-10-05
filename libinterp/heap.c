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

/*
 * Same fix as alloc.c's D2BPC, same reason: D2B(b,dp)'s own
 * getcallerpc(&dp) only names the real caller when dp is the
 * enclosing function's own first parameter (see doc/inferno-ports.ms,
 * "D2B's own caller pc was wrong in the four functions that need it
 * most"). Both D2B uses in this file are mismatched: destroy()'s
 * consistency check anchors on h (a local; destroy(void *v)'s real
 * first parameter is v) and freelist()'s tail-loop check anchors on
 * th (a local; freelist(Heap *h, int)'s real first parameter is h).
 * D2B itself stays untouched (shared with os/osprey/kernlib/pool.c);
 * D2BPC is local to this file, matching alloc.c's copy exactly except
 * for the name, since C has no way to share a macro across
 * translation units without a shared header this fix must not touch.
 * pc64-only, temporary. See doc/inferno-ports.ms.
 *
 * Follow-up: fixing every reachable D2B/D2BPC site's anchor did not
 * move destroy+703 at all (doc/inferno-ports.ms, "Eliminating
 * candidates for destroy+703") -- every direct candidate this hunt
 * could name was eliminated by bisection, yet the value never
 * changed. D2BPC now takes an explicit tag (matching alloc.c's own
 * follow-up) so each call site's own panic message names itself
 * directly instead of requiring offset decoding.
 */
#define D2BPC(b, dp, pc, tag)	b = ((Bhdr*)((uchar*)(dp) - (BHDRSIZE - sizeof(Btail)))); \
				if(b->magic != MAGIC_A && b->magic != MAGIC_I){\
					b = ((Balign*)((char*)(dp)-sizeof(Balign)))->hdr; \
					if(b->magic != MAGIC_A && b->magic != MAGIC_I)\
						poolfault(dp, tag, pc);\
				}

void	(*heapmonitor)(int, void*, ulong);
/*
 * "Is a collection running that this process is not part of?"
 *
 * nil, and so false, unless a kernel sets it: emu and every board
 * without a stop-the-world collector behave exactly as before.  See
 * destroy() below for what it is for.
 */
int	(*gcstopped)(void);
static int statictype(Type*);		/* named below; used by destroy() */
/*
 * Names for what statictype() returns, which is a 1-based index into
 * statics[] below, or 0 for a type that is not one of them.  Slot 0 is
 * the "?" and is why this array is one longer than that one -- a new
 * static type has to be added in both places, and the comment above
 * statics[] already says so for its half.
 */
static char* const staticname[] = {
	"?", "Tarray", "Tstring", "Tlist", "Tmodlink", "Tchannel",
	"Tptr", "Tbyte", "Tword", "Tlong", "Treal",
};

#define	BIT(bt, nb)	(bt & (1<<nb))

void
freeptrs(void *v, Type *t)
{
	int c;
	WORD **w, *x;
	uchar *p, *ep;

	if(t->np == 0)
		return;

	w = (WORD**)v;
	p = t->map;
	ep = p + t->np;
	while(p < ep) {
		c = *p;
		if(c != 0) {
 			if(BIT(c, 0) && (x = w[7]) != H) destroy(x);
			if(BIT(c, 1) && (x = w[6]) != H) destroy(x);
 			if(BIT(c, 2) && (x = w[5]) != H) destroy(x);
			if(BIT(c, 3) && (x = w[4]) != H) destroy(x);
			if(BIT(c, 4) && (x = w[3]) != H) destroy(x);
			if(BIT(c, 5) && (x = w[2]) != H) destroy(x);
			if(BIT(c, 6) && (x = w[1]) != H) destroy(x);
			if(BIT(c, 7) && (x = w[0]) != H) destroy(x);
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
	freetype(t);		/* was an inline copy; freetype guards statics */
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
		freetype(t);	/* was an inline copy; freetype guards statics */
	}
	if(swept)
		return;
	l = l->tail;
	while(l != (List*)H) {
		t = l->t;
		th = D2H(l);
		if(ADEC(&th->ref) != 0)
			break;
		/*
		 * This was the one decrement of a Type reference in the
		 * whole tree that did not go through freetype(), and so the
		 * only one the static-Type guard could not see.  It was left
		 * raw on the strength of a probe that asserted th->t ==
		 * &Tlist and that the count never reached zero here: six
		 * boots of the virtarm64 reproducer, never fired.  Six boots
		 * on another board is not much, and pc64 has since produced
		 * a Tlist underflow among three captures in 96 boots, so the
		 * assumption is no longer worth keeping unchecked.
		 *
		 * freetype() is exactly this decrement plus the guard.  th->t
		 * is &Tlist by construction -- cons() sets it -- and Tlist is
		 * static, so freetype() cannot free it here; the only change
		 * is that a count reaching zero now reports instead of
		 * passing silently.  The type is checked once rather than
		 * asserted, because a tail cell whose type is not Tlist would
		 * itself be the find.
		 */
		if(th->t != &Tlist) {
			static int said;

			if(!said) {
				said = 1;
				print("freelist: tail cell %#p type %#p not Tlist\n",
					th, th->t);
			}
		}
		freetype(th->t);
		if(t != nil) {
			if (t->np)
				freeptrs(l->data, t);
			freetype(t);	/* was an inline copy; freetype guards statics */
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
		{ Bhdr *b; D2BPC(b, th, getcallerpc(&h), "alloc:D2B:freelist-tail"); }
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
	else if(!swept){
		destroy(ml->MP);
	}
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
	extern void panic(char*, ...);
	Heap *h;
	Type *t;

	if(v == H)
		return;

	h = D2H(v);

	{ Bhdr *b; D2BPC(b, h, getcallerpc(&v), "alloc:D2B:destroy-entry"); }		/* consistency check */

	/*
	 * chan.c's decref() panics when a Ref underflows (old <= 0),
	 * before the bad count is ever used to compute a bad pointer;
	 * ADEC(&h->ref) had no equivalent.  A result below zero means
	 * h->ref was already at or below zero when this decrement ran --
	 * an extra destroy() on an object already at the end of its life
	 * -- and saying so here turns an eventual, hard-to-place
	 * alloc:D2B into an immediate, exactly located panic.  n == 0 is
	 * the ordinary "just hit zero, time to free" case and falls
	 * through unchanged.
	 */
	{
		int n;

		n = ADEC(&h->ref);
		if(n < 0){
			/*
			 * The colour and type are printed because they answer
			 * the first question anyone asks here: had the
			 * collector already swept this object, so that the
			 * count belongs to whatever now occupies the block?
			 *
			 * Asked and answered on this branch, at
			 * parallelvm=1: "n -1 colour 0 (mutator 0) t
			 * 0x345700".  Mutator-coloured, with a type pointer
			 * that is still a type -- an intact, live-looking
			 * object whose count simply went one drop too far.
			 * Not a swept block, which ruled out the write
			 * barrier as the cause and saved the next reader the
			 * same hypothesis.  See doc/multicore-plan.ms.
			 */
			panic("destroy: h->ref underflow, h %#p n %d"
				" colour %d (mutator %d) t %#p %s",
				h, n, h->color, mutator, h->t,
				h->t == nil ? "(nil)" :
				staticname[statictype(h->t)]);
		}
		if(n > 0)
			return;
		if(gcdepth > 64){
			/*
			 * Too deep to keep recursing; protect the C stack and
			 * leave this object for the collector, which will find
			 * it unreachable.  Not a leak, a handover -- and it
			 * really happens: three times in a plain shell spawn
			 * storm, with the depth reaching 65.  Counted so that
			 * stays visible.
			 */
			gcdeferred++;
			return;
		}
		if(gcstopped != nil && gcstopped()){
			/*
			 * The same handover, for the same reason, in the case
			 * the VM lock used to make impossible.
			 *
			 * A collection is running and this process is not it.
			 * Freeing now hands the collector's own mark and sweep
			 * a block that has gone back to the pool underneath it,
			 * which is what the three faults left at parallelvm=1
			 * look like: frame+0x1a, movp+0xf7 and string2c+0x17,
			 * all dereferencing bad heap pointers.  Measured, not
			 * assumed -- a counter on libinterp's own heapmonitor
			 * hook caught "heap op 1 from dis pid 8, not the
			 * collector (dis pid 9)", op 1 being this exact point.
			 *
			 * The object's count is already zero, so nothing else
			 * refers to it and the collector will find it
			 * unreachable and sweep it.  Waiting here instead would
			 * mean sleeping in destroy(), which is reached from
			 * callers that hold locks.
			 */
			gcdeferred++;
			return;
		}
	}

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

/*
 * The Types at the top of this file are kernel data, not pool blocks.
 * Each starts with ref 1 and nothing may ever free one: handing a
 * static to free() gives the pool allocator an address it never
 * owned.  A pc64 boot did exactly that -- "alloc:D2B:free 34b5f8 not
 * in pools", from freelist()'s head-node limb, and 0x34b5f8 resolves
 * to Tptr exactly (utils/p9sym.py; doc/inferno-ports.ms, "The
 * captured pcs were right").  For that to happen the initial
 * reference must have been consumed, i.e. one ADEC more than the
 * matching AINC -- OP(consp)'s single AINC(&Tptr.ref) per cons cell
 * against one ADEC per free of that cell.  A list cell freed twice
 * produces it directly, which is the same double free this hunt has
 * been chasing from the other end.
 *
 * So this is containment and attribution, not a cure: the underlying
 * imbalance is still there.  Refusing the free keeps kernel data out
 * of the pool, and naming the running Dis module at the moment the
 * count reaches zero attributes the underflow where it happens rather
 * than leaving it to surface later as an unrelated pool panic.  The
 * static reference is put back so a second underflow reports again
 * instead of going quiet.
 */
/*
 * Same source of truth for "which Dis module is running" that
 * os/inferno/port/alloc.c's notefree() had to be corrected to use:
 * the plain global R is the process-wide register file and its R.M was
 * found dangling here even with a live currun(), which was the
 * dominant crash of this hunt.  currun()'s own Prog carries its saved
 * module pointer and is valid for a live xp whether or not R has been
 * swapped in.  See doc/inferno-ports.ms.
 */
static void
reportunder(Type *t, int n, char *what)
{
	Prog *xp;
	Module *mod;
	extern void dumpstack(void);

	xp = currun();
	mod = (xp != nil) ? modlinkmod(xp->reg.M) : nil;
	print("freetype: %s %#p ref underflow n %d, pid %d module %s\n",
		what, t, n, xp != nil ? xp->pid : -1,
		mod != nil ? mod->name : "?");
	dumpstack();
}

/*
 * Shared by every probe that walks another Prog's saved registers to
 * name its module: devprog.c's modstatus() reached from disdump(),
 * alloc.c's notefree() (the freehist ring), and this file's own
 * reportunder().  It lives here rather than in os/inferno/port/dis.c
 * so the hosted build can use it too; it needs only D2H, Tmodlink and
 * H, all of which interp.h already provides.  Both have
 * now faulted on this port, at modstatus+0x18 and notefree+0xb8, and
 * both had the same incomplete guard -- M tested against nil and H,
 * then M->m dereferenced.
 *
 * That guard cannot catch what actually happens.  The captured value
 * is 0x00FF53F000E2C3F0: not nil, not H, and sitting on a Modlink
 * whose heap type is intact, so every condition either probe tested
 * passes.  What is wrong with it is that it is not a canonical
 * address -- bits 63:48 are 0x00FF, so the sign bits disagree -- which
 * is why the fault is a general protection violation with CR2 0
 * rather than a page fault.  Testing for exactly that is both the
 * cheapest check and the one that matches the evidence.
 *
 * This is why the earlier modstatus guard never reported: it asked
 * whether the Modlink was live and whether m was nil, and in the
 * observed failure the answer to both is "fine".
 */
static int
canonical(void *v)
{
	uintptr a;

	a = (uintptr)v;
	return (a >> 47) == 0 || (a >> 47) == 0x1FFFF;
}

/*
 * Returns the Module, not a yes/no, and that matters.  The first
 * version answered int and the callers then wrote M->m->name -- so the
 * pointer that was checked and the pointer that was used were two
 * separate loads of the same memory.  notefree+0xb2 faulted between
 * them, on this exact port: modlinkok() had already returned true, and
 * the reload produced a non-canonical value, TYPE 0D with CR2 0, after
 * the call.  Time of check is not time of use.
 *
 * Handing the caller the pointer this function actually validated
 * removes the second load, and with it the window.
 */
Module*
modlinkmod(Modlink *ml)
{
	Module *mod;

	if(ml == nil || ml == H || !canonical(ml))
		return nil;
	if(D2H(ml)->t != &Tmodlink)
		return nil;
	mod = ml->m;
	if(mod == nil || !canonical(mod))
		return nil;
	return mod;
}

/*
 * These are every statically initialised Type in the tree, and
 * include/interp.h declares the same ten.  A new one has to be added
 * here too, or it gets handed to free() the first time its count is
 * over-decremented.  Returns a 1-based index so the caller can keep a
 * per-type flag; Type itself has no spare field, and widening it would
 * move map[], which dtype()'s sizeof(Type)-sizeof(t->map)+mapsize and
 * the JITs' field offsets both depend on.
 */
static Type* const statics[] = {
	&Tarray, &Tstring, &Tlist, &Tmodlink, &Tchannel,
	&Tptr, &Tbyte, &Tword, &Tlong, &Treal,
};

static int
statictype(Type *t)
{
	int i;

	for(i = 0; i < nelem(statics); i++)
		if(t == statics[i])
			return i+1;
	return 0;
}

void
freetype(Type *t)
{
	int i, n;

	if(t == nil)
		return;
	n = ADEC(&t->ref);
	if(n > 0)
		return;
	if((i = statictype(t)) != 0) {
		static uchar reported[nelem(statics)];

		/*
		 * Report the first one per type only.  Putting the reference
		 * back restores the static but not the count of live objects
		 * it was standing for, so the very next destroy of an object
		 * of this type lands on zero again and reports again: the
		 * first boot to fire this turned one real event into
		 * eighteen identical lines.  The repeats are an artefact of
		 * the repair, not eighteen separate underflows, and they
		 * bury the one capture that matters.
		 */
		if(!reported[i-1]) {
			reported[i-1] = 1;
			reportunder(t, n, "static type");
		}
		t->ref = 1;		/* kernel data: put the static reference back */
		return;
	}
	if(n < 0) {
		/*
		 * Already at zero before this decrement, so a previous
		 * caller has freed t and this block is gone.  The three
		 * inline copies this function replaced only freed on
		 * ADEC == 0 and silently did nothing here; freetype()'s
		 * own callers used to free on <= 0, i.e. free it twice.
		 * Neither is right -- report it and free nothing.
		 */
		reportunder(t, n, "type");
		return;
	}
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
