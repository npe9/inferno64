#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "interp.h"

#define left	u.s.bhl
#define right	u.s.bhr
#define fwd	u.s.bhf
#define prev	u.s.bhv
#define parent	u.s.bhp

#define RESERVED	512*1024

struct Pool
{
	char*	name;
	int	pnum;
	uintptr	maxsize;
	intptr	quanta;
	int	chunk;
	uintptr	ressize;
	uintptr	cursize;
	uintptr	arenasize;
	uintptr	hw;
	Lock	l;
	Bhdr*	root;
	Bhdr*	chain;
	uintptr	nalloc;
	uintptr	nfree;
	intptr	nbrk;
	intptr	lastfree;
	int	warn;
	void	(*move)(void*, void*);
};

/* keep the quanta above the size of 5 pointers and 2 longs else the next block
	will be getting overwritten by the header -- starts a corruption hunt
	when pointer size = 8 bytes, then 63 = 2^q -1
		for 4 bytes, 31
	TODO make this a macro?
	for allocpc and reallocpc, 2 * 8 = 16 bytes get added
	so, minimum size = 2*4 + 2*8 + 5*8 = 64, using 127 to satisfy 2^q -1
 */
static
struct
{
	int	n;
	Pool	pool[MAXPOOL];
	// Lock	l;
} table = {
	3,
	{
		/* cursize must start 0: poolsize() may set maxsize below the old
		 * 31MB placeholder; poolmax() then underflows and /dev/memory
		 * lines exceed the 12-byte fields wm/memory parses. */
		{ "main",  0, 	32*1024*1024, 127,  512*1024, 0, 0 },
		{ "heap",  1, 	32*1024*1024, 127,  512*1024, 0, 0 },
		{ "image", 2,   64*1024*1024+256, 127, 4*1024*1024, 1, 0 },
	}
};

Pool*	mainmem = &table.pool[0];
Pool*	heapmem = &table.pool[1];
Pool*	imagmem = &table.pool[2];

static void _auditmemloc(char *, void *);
void (*auditmemloc)(char *, void *) = _auditmemloc;
static void _poolfault(void *, char *, uintptr);
void (*poolfault)(void *, char *, uintptr) = _poolfault;

/*
 * A resolved "alloc:D2B ... (from X/Y)" this hunt captured put X
 * inside destroy() at an offset that made no sense next to the one,
 * real poolfree() call site a clean-boot capture separately confirmed
 * (doc/inferno-ports.ms, "Who freed it first, and a discrepancy left
 * open"). The cause: include/pool.h's D2B(b, dp) macro computes its
 * own caller pc as getcallerpc(&dp) -- and every other getcallerpc()
 * call in this tree (chan.c's decref()/incref()/cclose()/newpath(),
 * this file's own setmalloctag() using &dsize inside mallocalign())
 * anchors on the ENCLOSING FUNCTION'S OWN FIRST PARAMETER, because
 * that is the stack slot the Plan9 a+0(FP) trick actually reads.
 * D2B's dp is correct for poolimmutable(void*)/poolmutable(void*)/
 * free(void*)/set-and-get-{malloc,realloc}tag(void*,...), whose first
 * parameter IS the data pointer -- but poolfree(Pool*,void*),
 * poolrealloc(Pool*,void*,...), poolmsize(Pool*,void*) all take the
 * Pool* first, and mallocalign()'s dp is a local, not a parameter at
 * all. In those four, D2B's own poolfault() names a plausible-looking
 * but wrong pc whenever it fires.
 *
 * D2B itself is shared with os/osprey/kernlib/pool.c (a tree this
 * hunt does not touch) and emu/, libinterp/, devforth.c besides --
 * changing its signature is out of scope. D2BPC is the same check
 * with an explicit, correctly-anchored pc instead, local to this
 * file, used only at the four mismatched call sites. pc64-only,
 * temporary alongside the rest of this hunt's probes. See
 * doc/inferno-ports.ms.
 *
 * Follow-up: fixing every reachable D2B/D2BPC site's anchor did not
 * move destroy+703 at all (doc/inferno-ports.ms, "Eliminating
 * candidates for destroy+703") -- every direct candidate this hunt
 * could name (poolfree, poolmsize, freelist's tail check, destroy's
 * own consistency check) was eliminated by bisection, yet the value
 * never changed. Rather than guess at a fifth site, D2BPC now takes
 * an explicit tag so each call site's own panic message names itself
 * directly -- the next capture answers which site fired from the
 * message text alone, no offset decoding needed.
 */
#define D2BPC(b, dp, pc, tag)	b = ((Bhdr*)((uchar*)(dp) - (BHDRSIZE - sizeof(Btail)))); \
				if(b->magic != MAGIC_A && b->magic != MAGIC_I){\
					b = ((Balign*)((char*)(dp)-sizeof(Balign)))->hdr; \
					if(b->magic != MAGIC_A && b->magic != MAGIC_I)\
						poolfault(dp, tag, pc);\
				}

/*
 * auditmemloc() answers "is this address live, free, or nowhere" but
 * not "who freed it" -- the open half of the alloc:D2B double-free
 * this hunt hardware-confirmed (heap.c's destroy() calling poolfree()
 * on a block already MAGIC_F).  A small ring of the last NFREEHIST
 * successful poolfree() calls, each with its caller's pc, answers
 * that directly: on the next alloc:D2B, if the bad address is in this
 * ring, the panic can name exactly who freed it the first time,
 * turning "somewhere frees this twice" into a specific call site
 * without having to catch the double-free in the act.  pc64-only,
 * temporary.  See doc/inferno-ports.ms.
 *
 * NFREEHIST was 32 -- every real alloc:D2B:destroy-entry capture so
 * far aged out of it before the panic that would have used it (3/3
 * captures, no "was freed before" line at all).  Bumped by two orders
 * of magnitude; each entry is address+pc (16 bytes on this port), so
 * 4096 entries is 64KiB, trivial next to this port's pool sizes.  See
 * doc/inferno-ports.ms.
 */
enum { NFREEHIST = 4096 };
static struct { void *addr; uintptr pc; int pid; char *mname; } freehist[NFREEHIST];
static int freehistn;

static void
notefree(void *v, uintptr pc)
{
	int i;

	/*
	 * Bisection probe REMOVED: this used to print each distinct
	 * poolfree() caller pc the first time it was seen, to settle
	 * whether destroy() called poolfree() from more than one
	 * compiled address. It already answered that question during
	 * the pc64 hunt (doc/inferno-ports.ms) and was marked pc64-only,
	 * temporary, remove-with-the-rest-of-this-ring even then.
	 *
	 * It should have been removed before any other board was built.
	 * On riscv64/virt it instead caused a real, 100%-reproducible
	 * permanent boot hang: the fifth distinct caller pc, discovered
	 * mid-print during PCI device enumeration, never completed --
	 * five independent boots hung at the identical byte offset in
	 * the console output, and disabling just this loop (leaving the
	 * freehist ring and currun() call below untouched) was sufficient
	 * to restore a clean boot to a shell prompt, matching the
	 * committed ivirt binary's own behaviour. Root cause of why THIS
	 * print, from THIS call site, hangs riscv64 and not pc64 was not
	 * chased further -- the probe had already served its purpose and
	 * the fix is to remove it, not to make it portable. See
	 * doc/inferno-ports.ms, "The pc64-only bisection probe hangs
	 * riscv64/virt, deterministically".
	 */

	/*
	 * Same Dis pid/module trick _poolfault() already uses (below) --
	 * records which Dis process and module was current at the
	 * moment of THIS free, so a later "was freed before" match can
	 * compare it against whichever process/module is current at the
	 * double-free, answering "same owner freeing its own stale
	 * reference" vs "two different owners" directly (doc/inferno-
	 * ports.ms, "Who freed it first, this time reliably"). pc64-
	 * only, temporary.
	 */
	i = freehistn % NFREEHIST;
	freehist[i].addr = v;
	freehist[i].pc = pc;
	{
		Prog *xp;

		xp = currun();
		freehist[i].pid = xp != nil ? xp->pid : -1;
		/*
		 * THE dominant crash this hunt found: reading the PLAIN
		 * GLOBAL R here (libinterp/xec.c's single, process-wide
		 * interpreter register file) instead of xp->R, currun()'s
		 * own Prog's SAVED register file. A first fix gated the
		 * global R.M read on "xp != nil" too, on the theory that a
		 * live xp meant R was current for it -- rebuilt, reboot-
		 * tested, and it kept crashing at the same site (now
		 * notefree+292, same instruction shifted a few bytes): xp
		 * was pid 2 module Sh (confirmed by the successful dumpregs()
		 * print right before the crash, which already uses xp->R.M
		 * correctly), yet the global R.M was STILL dangling -- xp
		 * being at the head of the run queue does not mean the
		 * global R has been (re)loaded for it. pc64/trap.c's
		 * dumpregs() never had this bug because it never touches
		 * the global R at all; it reads xp->R.M, the specific Prog's
		 * own saved pointer, always valid for a live xp regardless
		 * of whether R has been swapped in for it this instant. Use
		 * the same source of truth here instead of trying to gate
		 * the global. "notefree+270/+283" (the original global-R
		 * bug, before the failed xp-gate attempt) accounted for 4416
		 * of 765 post-fix boot logs' TYPE 0D captures -- the
		 * dominant crash of the whole hunt. pc64-only, temporary.
		 * See doc/inferno-ports.ms.
		 */
		freehist[i].mname = (xp != nil && xp->R.M != nil && xp->R.M != H && xp->R.M->m != nil)
			? xp->R.M->m->name : nil;
	}
	freehistn++;
}

/*
 * Non-static so libinterp/xec.c's badptrslot() can also check the
 * ring, not just _poolfault()'s own call site -- the two genuine
 * "dv-freed" captures (doc/inferno-ports.ms, "Two genuine captures
 * with the corrected checker") want to know who freed the block
 * first, the same question this ring already answers for the native
 * pool allocator's own double-frees. pc64-only, temporary.
 */
void
printfreehist(void *v)
{
	int i, n;

	n = freehistn < NFREEHIST ? freehistn : NFREEHIST;
	for(i = 0; i < n; i++)
		if(freehist[i].addr == v)
			print("_poolfault: %#p was freed before, from pc=%#p pid %d module %s\n",
				v, freehist[i].pc, freehist[i].pid,
				freehist[i].mname != nil ? freehist[i].mname : "?");
}

int
memusehigh(void)
{
	return 	mainmem->cursize > mainmem->ressize ||
			heapmem->cursize > heapmem->ressize ||
			imagmem->cursize > imagmem->ressize;
}

void
poolimmutable(void *v)
{
	Bhdr *b;

	D2BPC(b, v, getcallerpc(&v), "alloc:D2B:poolimmutable");
	b->magic = MAGIC_I;
}

void
poolmutable(void *v)
{
	Bhdr *b;

	D2BPC(b, v, getcallerpc(&v), "alloc:D2B:poolmutable");
	b->magic = MAGIC_A;
	/* ((Heap*)v)->color = mutator; */
}

char*
poolname(Pool *p)
{
	return p->name;
}

Bhdr*
poolchain(Pool *p)
{
	return p->chain;
}

void
pooldel(Pool *p, Bhdr *t)
{
	Bhdr *s, *f, *rp, *q;

	if(t->parent == nil && p->root != t) {
		t->prev->fwd = t->fwd;
		t->fwd->prev = t->prev;
		return;
	}

	if(t->fwd != t) {
		f = t->fwd;
		s = t->parent;
		f->parent = s;
		if(s == nil)
			p->root = f;
		else {
			if(s->left == t)
				s->left = f;
			else
				s->right = f;
		}

		rp = t->left;
		f->left = rp;
		if(rp != nil)
			rp->parent = f;
		rp = t->right;
		f->right = rp;
		if(rp != nil)
			rp->parent = f;

		t->prev->fwd = t->fwd;
		t->fwd->prev = t->prev;
		return;
	}

	if(t->left == nil)
		rp = t->right;
	else {
		if(t->right == nil)
			rp = t->left;
		else {
			f = t;
			rp = t->right;
			s = rp->left;
			while(s != nil) {
				f = rp;
				rp = s;
				s = rp->left;
			}
			if(f != t) {
				s = rp->right;
				f->left = s;
				if(s != nil)
					s->parent = f;
				s = t->right;
				rp->right = s;
				if(s != nil)
					s->parent = rp;
			}
			s = t->left;
			rp->left = s;
			s->parent = rp;
		}
	}
	q = t->parent;
	if(q == nil)
		p->root = rp;
	else {
		if(t == q->left)
			q->left = rp;
		else
			q->right = rp;
	}
	if(rp != nil)
		rp->parent = q;
}

void
pooladd(Pool *p, Bhdr *q)
{
	int size;
	Bhdr *tp, *t;

	q->magic = MAGIC_F;

	q->left = nil;
	q->right = nil;
	q->parent = nil;
	q->fwd = q;
	q->prev = q;

	t = p->root;
	if(t == nil) {
		p->root = q;
		return;
	}

	size = q->size;

	tp = nil;
	while(t != nil) {
		if(size == t->size) {
			q->prev = t->prev;
			q->prev->fwd = q;
			q->fwd = t;
			t->prev = q;
			return;
		}
		tp = t;
		if(size < t->size)
			t = t->left;
		else
			t = t->right;
	}

	q->parent = tp;
	if(size < tp->size)
		tp->left = q;
	else
		tp->right = q;
}

void
poolsummary(void)
{
	int x = 0;
	char buf[400];

	print("\n");
	print("    cursize     maxsize       hw         nalloc       nfree      nbrk       max      name\n");

	x=poolread( buf, sizeof buf - 1, x );
	buf[x] = 0;
	putstrn(buf, x);
	print("\n");
}

void*
poolalloc(Pool *p, uintptr asize)
{
	Bhdr *q, *t;
	intptr alloc, ldr, ns, frag;
	intptr osize, size;
	Prog *prog;

	// if(asize >= 1024*1024*1024)	/* for sanity and to avoid overflow */
	//	return nil;
/*	if(p->cursize > p->ressize &&
		(prog = currun()) != nil &&
		prog->flags&Prestricted){
		print("poolalloc exception\n");
		return nil;
	}*/
	size = asize;
	osize = size;
	size = (size + BHDRSIZE + p->quanta) & ~(p->quanta);
	/*
	 * Both branch-local invariants above (exact-match chain,
	 * no-split/split q) held on the two size=0 reproductions checked
	 * against them so far -- narrowing toward either the arena-extend
	 * path below (which sets size directly rather than via a tree
	 * lookup) or size itself being wrong before any branch runs.
	 * Catch the second possibility here, once, before it can
	 * propagate identically into every branch's own internally-
	 * consistent-looking arithmetic.  pc64-only, temporary.  See
	 * doc/inferno-ports.ms.
	 */
	if(size <= osize || size < BHDRSIZE)
		panic("poolalloc: size computed wrong: osize %zd size %zud "
			"BHDRSIZE %zud quanta %#zux pc=%#p",
			osize, size, (uintptr)BHDRSIZE, p->quanta, getcallerpc(&p));

	ilock(&p->l);
	p->nalloc++;

	t = p->root;
	q = nil;
	while(t) {
		if(t->size == size) {
			Bhdr *tt = t;
			t = t->fwd;
			/*
			 * A self-consistent "_allocb: lim < base" capture this
			 * hunt caught (after fixing that diagnostic's own
			 * double-msize()-eval bug) showed a genuinely allocated,
			 * correctly-tagged block reporting size==BHDRSIZE on a
			 * 161-byte request -- reproduced twice across 90 boots.
			 * This exact-match branch matches on tt->size==size but
			 * then hands out tt->fwd (the next block chained at this
			 * tree bucket, per pooladd()'s own same-size chaining),
			 * WITHOUT re-verifying that tt->fwd carries the same
			 * size tt does.  Every other reader of this chain
			 * (pooladd()'s own insertion, pooldel()'s promotion of
			 * fwd into the tree slot) assumes that invariant holds
			 * by construction and never checks it either.  Verify it
			 * here, once, right where a violation would explain the
			 * capture directly.  pc64-only, temporary.  See
			 * doc/inferno-ports.ms.
			 */
			if(t->size != size)
				panic("poolalloc: exact-match chain size "
					"mismatch: tt %#p tt->size %zud "
					"t(=tt->fwd) %#p t->size %zud "
					"wanted %zud pc=%#p",
					tt, tt->size, t, t->size, size,
					getcallerpc(&p));
			pooldel(p, t);
			t->magic = MAGIC_A;
			p->cursize += t->size;
			if(p->cursize > p->hw)
				p->hw = p->cursize;
			iunlock(&p->l);
			return B2D(t);
		}
		if(size < t->size) {
			q = t;
			t = t->left;
		}
		else
			t = t->right;
	}
	if(q != nil) {
		/*
		 * Same standing lead as the exact-match branch above (see
		 * its own comment, doc/inferno-ports.ms): q is the smallest
		 * BST node found with size >= the wanted size, by the tree
		 * descent's own "if(size < t->size) q = t" invariant.  Two
		 * captures reproduced *without* the exact-match branch's own
		 * check firing, so that specific hypothesis is ruled out --
		 * verify the invariant this branch instead relies on, right
		 * before it's used, the same way.  pc64-only, temporary.
		 */
		if(q->size <= size)
			panic("poolalloc: no-split/split q size invariant "
				"broken: q %#p q->size %zud wanted %zud pc=%#p",
				q, q->size, size, getcallerpc(&p));
		pooldel(p, q);
		q->magic = MAGIC_A;
		frag = q->size - size;
		if(frag < (size>>2) && frag < 0x8000) {
			p->cursize += q->size;
			if(p->cursize > p->hw)
				p->hw = p->cursize;
			iunlock(&p->l);
			return B2D(q);
		}
		/* Split */
		ns = q->size - size;
		q->size = size;
		B2T(q)->hdr = q;
		t = B2NB(q);
		t->size = ns;
		B2T(t)->hdr = t;
		pooladd(p, t);
		p->cursize += q->size;
		if(p->cursize > p->hw)
			p->hw = p->cursize;
		iunlock(&p->l);
		return B2D(q);
	}

	ns = p->chunk;
	if(size > ns)
		ns = size;
	ldr = p->quanta+1;

	alloc = ns+ldr+ldr;
	p->arenasize += alloc;
	if(p->arenasize > p->maxsize) {
		p->arenasize -= alloc;
		ns = p->maxsize-p->arenasize-ldr-ldr;
		ns &= ~p->quanta;
		if (ns < size) {
			if(poolcompact(p)) {
				iunlock(&p->l);
				return poolalloc(p, osize);
			}

			iunlock(&p->l);
			if(p->warn)
				return nil;
			p->warn = 1;
			if (p != mainmem || ns > 512)
				/*
				 * A live "arena too large: main size
				 * 4294966320 ... cursize 417408 ..." capture
				 * this hunt caught (see doc/inferno-ports.ms)
				 * had mainmem barely used (417KB of a 251MB
				 * pool) -- this is not exhaustion, it is one
				 * absurdly-oversized single request (size is
				 * within 976 of exactly 2^32, the classic
				 * signature of a wrapped 32-bit unsigned
				 * subtraction reaching this far as a
				 * zero-extended 64-bit value). Added the
				 * caller's own pc so the next capture names
				 * who asked for it directly. pc64-only,
				 * temporary.
				 */
				print("arena too large: %s size %zd cursize %zud arenasize %zud maxsize %zud, alloc = %zd pc=%#p\n", p->name, osize, p->cursize, p->arenasize, p->maxsize, alloc, getcallerpc(&p));
			return nil;
		}
		alloc = ns+ldr+ldr;
		p->arenasize += alloc;
	}

	p->nbrk++;
	t = xalloc(alloc);
	if(t == nil) {
		p->nbrk--;
		iunlock(&p->l);
		return nil;
	}
	/* Double alignment */
	t = (Bhdr *)(((uintptr)t + 7) & ~7);

	/* TBS xmerge */
	if(0 && p->chain != nil && (char*)t-(char*)B2LIMIT(p->chain)-ldr == 0){
		/* can merge chains */
		if(0)print("merging chains %p and %p in %s\n", p->chain, t, p->name);
		q = B2LIMIT(p->chain);
		q->magic = MAGIC_A;
		q->size = alloc;
		B2T(q)->hdr = q;
		t = B2NB(q);
		t->magic = MAGIC_E;
		p->chain->csize += alloc;
		p->cursize += alloc;
		iunlock(&p->l);
		poolfree(p, B2D(q));		/* for backward merge */
		return poolalloc(p, osize);
	}

	t->magic = MAGIC_E;		/* Make a leader */
	t->size = ldr;
	t->csize = ns+ldr;
	t->clink = p->chain;
	p->chain = t;
	B2T(t)->hdr = t;
	t = B2NB(t);

	t->magic = MAGIC_A;		/* Make the block we are going to return */
	t->size = size;
	B2T(t)->hdr = t;
	q = t;

	ns -= size;			/* Free the rest */
	if(ns > 0) {
		q = B2NB(t);
		q->size = ns;
		B2T(q)->hdr = q;
		pooladd(p, q);
	}
	B2NB(q)->magic = MAGIC_E;	/* Mark the end of the chunk */

	p->cursize += t->size;
	if(p->cursize > p->hw)
		p->hw = p->cursize;
	iunlock(&p->l);
	return B2D(t);
}

void
poolfree(Pool *p, void *v)
{
	Bhdr *b, *c;
	/* extern Bhdr *ptr; defined in libinterp/gc.c */

	D2BPC(b, v, getcallerpc(&p), "alloc:D2B:poolfree");

	/*
	 * Probe: D2B only checks the magic byte, not size/alignment, and
	 * runs before ilock(&p->l) below -- so a stale-but-magic-shaped
	 * pointer could reach this point undetected.  _auditmemloc()
	 * treats these same two conditions (a live magic, a nonzero
	 * quanta-aligned size) as what makes a block trustworthy; apply
	 * them here too, at the moment poolfree() receives v, rather than
	 * only when something else later stumbles onto the damage.  See
	 * doc/inferno-ports.ms.
	 */
	if((b->magic != MAGIC_A && b->magic != MAGIC_I) ||
	   b->size <= 0 || (b->size & p->quanta))
		poolfault(v, "poolfree:badhdr", getcallerpc(&p));

	notefree(v, getcallerpc(&p));

	ilock(&p->l);
	p->nfree++;
	p->cursize -= b->size;

	c = B2NB(b);
	if(c->magic == MAGIC_F) {	/* Join forward */
		/*if(c == ptr)
			ptr = b; */
		pooldel(p, c);
		c->magic = 0;
		b->size += c->size;
		B2T(b)->hdr = b;
	}

	c = B2PT(b)->hdr;
	if(c->magic == MAGIC_F) {	/* Join backward */
		/*if(b == ptr)
			ptr = c; */
		pooldel(p, c);
		b->magic = 0;
		c->size += b->size;
		b = c;
		B2T(b)->hdr = b;
	}

	pooladd(p, b);
	iunlock(&p->l);
}

void *
poolrealloc(Pool *p, void *v, uintptr size)
{
	Bhdr *b;
	void *nv;
	intptr osize;

	// if(size >= 1024*1024*1024)	/* for sanity and to avoid overflow */
	//	return nil;
	if(size == 0){
		poolfree(p, v);
		return nil;
	}
	SET(osize);
	if(v != nil){
		ilock(&p->l);
		D2BPC(b, v, getcallerpc(&p), "alloc:D2B:poolrealloc");
		osize = b->size - BHDRSIZE;
		iunlock(&p->l);
		if(osize >= size)
			return v;
	}
	nv = poolalloc(p, size);
	if(nv != nil && v != nil){
		memmove(nv, v, osize);
		poolfree(p, v);
	}
	return nv;
}

uintptr
poolmsize(Pool *p, void *v)
{
	Bhdr *b;
	uintptr size;

	/*
	 * Bisection probe REMOVED: same pattern as notefree()'s own
	 * (removed above), same "pc64-only, temporary" marking, same
	 * already-answered question (doc/inferno-ports.ms). This one
	 * did not reproduce the riscv64/virt hang under test, but it is
	 * the identical shape of the probe that did, called from the
	 * same allocator hot path, so it is removed for consistency
	 * rather than kept on the strength of one clean boot. See
	 * doc/inferno-ports.ms, "The pc64-only bisection probe hangs
	 * riscv64/virt, deterministically".
	 */

	if(v == nil)
		return 0;
	ilock(&p->l);
	D2BPC(b, v, getcallerpc(&p), "alloc:D2B:poolmsize");
	size = b->size - BHDRSIZE;
	iunlock(&p->l);
	return size;
}

static uintptr
poolmax(Pool *p)
{
	Bhdr *t;
	uintptr size;

	ilock(&p->l);
	if(p->maxsize > p->cursize)
		size = p->maxsize - p->cursize;
	else
		size = 0;
	t = p->root;
	if(t != nil) {
		while(t->right != nil)
			t = t->right;
		if(size < t->size)
			size = t->size;
	}
	if(size >= BHDRSIZE)
		size -= BHDRSIZE;
	iunlock(&p->l);
	return size;
}

/* Exactly 11 digits + trailing space (wm/memory fixed 12-byte columns). */
static int
poolfmt11(char *d, int nd, uintptr v)
{
	char tmp[32];
	int n;

	if(v > 99999999999ULL)
		v = 99999999999ULL;
	n = snprint(tmp, sizeof(tmp), "%11zud ", v);
	if(n > nd)
		n = nd;
	if(n > 0)
		memmove(d, tmp, n);
	return n;
}

/*
 * Where a pool's live bytes actually are, by block size and by the pc
 * that asked for them.  doc/pycubed-plan.ms wants this: the kernel pool
 * floor is the largest single term in that budget and nobody had looked
 * inside it.
 *
 * Walks the chunks rather than sampling: each chunk in p->chain is a
 * MAGIC_E leader followed by blocks, ending at the next MAGIC_E, and
 * every block carries the allocpc that D2BPC recorded.  Prints rather
 * than filling a buffer, so it costs no memory on a board that has
 * little -- which is the whole point of measuring it.
 */
enum {
	Nbucket	= 13,
	Npc	= 20,
};

static void
histone(Pool *p)
{
	Bhdr *c, *b;
	uintptr nalloc[Nbucket], balloc[Nbucket];
	uintptr pcb[Npc];
	intptr pcv[Npc];
	uintptr live, freeb, hdrs, sz;
	int i, j, k, n, nlive, nfree;

	for(i = 0; i < Nbucket; i++)
		nalloc[i] = balloc[i] = 0;
	for(i = 0; i < Npc; i++){
		pcv[i] = 0;
		pcb[i] = 0;
	}
	live = freeb = hdrs = 0;
	nlive = nfree = 0;

	for(c = poolchain(p); c != nil; c = c->clink)
		for(b = B2NB(c); b != nil && b->magic != MAGIC_E; b = B2NB(b)){
			sz = b->size;
			if(sz == 0)
				break;			/* corrupt: do not spin */
			if(b->magic == MAGIC_F){
				freeb += sz;
				nfree++;
				continue;
			}
			if(b->magic != MAGIC_A && b->magic != MAGIC_I)
				break;			/* not ours: stop this chunk */
			live += sz;
			hdrs += BHDRSIZE;
			nlive++;
			for(i = 0, n = 32; i < Nbucket-1; i++, n <<= 1)
				if(sz <= n)
					break;
			nalloc[i]++;
			balloc[i] += sz;

			for(j = 0; j < Npc; j++)
				if(pcv[j] == b->allocpc || pcb[j] == 0)
					break;
			if(j < Npc){
				pcv[j] = b->allocpc;
				pcb[j] += sz;
			}
		}

	print("pool %s: ", p->name);
	print("live %zud in %d blocks, ", live, nlive);
	print("free %zud in %d, ", freeb, nfree);
	print("block headers %zud\n", hdrs);
	for(i = 0, n = 32; i < Nbucket; i++, n <<= 1){
		if(nalloc[i] == 0)
			continue;
		if(i == Nbucket-1)
			print("  >%d", n>>1);
		else
			print("  <=%d", n);
		print("\t%zud blocks", nalloc[i]);
		print("\t%zud bytes\n", balloc[i]);
	}
	/* the callers holding the most, biggest first */
	for(k = 0; k < 8; k++){
		j = -1;
		for(i = 0; i < Npc; i++)
			if(pcb[i] != 0 && (j < 0 || pcb[i] > pcb[j]))
				j = i;
		if(j < 0)
			break;
		print("  pc %#p", (void*)pcv[j]);
		print("\t%zud bytes\n", pcb[j]);
		pcb[j] = 0;
	}
}

void
poolhist(void)
{
	int i;

	for(i = 0; i < table.n; i++)
		histone(&table.pool[i]);
}

int
poolread(char *va, int count, uintptr offset)
{
	Pool *p;
	int n, i, signed_off;
	char line[128];
	int ln;

	n = 0;
	signed_off = offset;
	for(i = 0; i < table.n; i++) {
		p = &table.pool[i];
		/*
		 * One arg per snprint: KenC LP64 pad is 8 bytes; keep the
		 * fixed 12-byte fields that appl/wm/memory.b parses.
		 */
		ln = 0;
		ln += poolfmt11(line+ln, sizeof(line)-ln, p->cursize);
		ln += poolfmt11(line+ln, sizeof(line)-ln, p->maxsize);
		ln += poolfmt11(line+ln, sizeof(line)-ln, p->hw);
		ln += poolfmt11(line+ln, sizeof(line)-ln, p->nalloc);
		ln += poolfmt11(line+ln, sizeof(line)-ln, p->nfree);
		ln += poolfmt11(line+ln, sizeof(line)-ln, (uintptr)p->nbrk);
		ln += poolfmt11(line+ln, sizeof(line)-ln, poolmax(p));
		ln += snprint(line+ln, sizeof(line)-ln, "%s\n", p->name);
		if(ln <= 0)
			break;
		if(n+ln > count)
			ln = count-n;
		if(ln > 0){
			memmove(va+n, line, ln);
			n += ln;
		}

		if(signed_off > 0) {
			signed_off -= n;
			if(signed_off < 0) {
				memmove(va, va+n+signed_off, -signed_off);
				n = -signed_off;
			}
			else
				n = 0;
		}

	}
	return n;
}

/* this function signature is tied to the system's libc.h */
void*
malloc(ulong size)
{
	void *v;

	v = poolalloc(mainmem, size);
	if(v != nil){
		setmalloctag(v, getcallerpc(&size));
		setrealloctag(v, 0);
		memset(v, 0, size);
	}
	return v;
}

void*
smalloc(uintptr size)
{
	void *v;

	/*
	 * A live "arena too large: main size 4178666939 ... cursize
	 * 94208 ..." capture this hunt caught (see doc/inferno-ports.ms)
	 * resolved its caller pc to smalloc+32 -- this function itself,
	 * asking poolalloc() for ~4GB against a 251MB pool.  size is
	 * within a small, plausible byte count of 2^32 both times this
	 * fired, the classic signature of a wrapped 32-bit unsigned
	 * subtraction reaching here zero-extended into this 64-bit
	 * parameter.  Two real problems, not one: whichever of
	 * smalloc()'s many callers passed this size is still unidentified
	 * (this print names smalloc's OWN caller, one level too shallow),
	 * but smalloc()'s own "for(;;)" loop below has NO escape at all
	 * -- a request that can never fit in the pool, however large,
	 * makes this loop retry forever, since poolalloc() will keep
	 * returning nil no matter how long anything else frees.  That is
	 * a silent, permanent kernel hang, not a panic -- almost
	 * certainly what several of this batch's own boots actually hit
	 * (killed by this harness's own 70s timeout with no panic line at
	 * all, rather than a clean crash).  A request this large can
	 * never succeed regardless of what else runs, so fail loud
	 * immediately instead of hanging, and name the real caller (not
	 * smalloc's own frame) so the next capture identifies it
	 * directly.  pc64-only, temporary.
	 */
	if(size > mainmem->maxsize)
		panic("smalloc: size %zud > mainmem maxsize %zud, pc=%#p",
			size, mainmem->maxsize, getcallerpc(&size));
	for(;;) {
		v = poolalloc(mainmem, size);
		if(v != nil)
			break;
		tsleep(&up->sleep, return0, 0, 100);
	}
	setmalloctag(v, getcallerpc(&size));
	setrealloctag(v, 0);
	memset(v, 0, size);
	return v;
}

void*
mallocz(ulong size, int clr)
{
	void *v;

	v = poolalloc(mainmem, size);
	if(v != nil){
		setmalloctag(v, getcallerpc(&size));
		setrealloctag(v, 0);
		if(clr)
			memset(v, 0, size);
	}
	return v;
}

/* on 9front, mallocalign() returns a pointer to a buffer that
	satisfies the alignment, offset and span requirements.

	As inferno keeps track of buffers at a lesser granularity,
	it is harder to keep track of the small memory areas
	that will have to be skipped for alignment.

	Instead of taking the responsibility of accounting for
	those memory areas, this function returns a buffer
	which will have a pointer that satisfies the size, alignment,
	offset and span requirements. It will be upto the caller
	to use it is wants. When free'ing, it needs to ensure that
	it frees using the Bhdr.u.data pointer and not any other
	pointer in that buffer.

	Alternate implementation:
	The free() function finds the Bhdr that contains the
	pointer being free'ed and frees that Bhdr. This breaks
	the assumption that the pointer passed to free() is
	always Bhdr.u.data.

12:25 < joe7> cinap_lenrek: any comments on this? http://okturing.com/src/11617/body
12:26 < joe7> I have 2 ways of implementing mallocalign on inferno. The second (alternative implementation) approach lies closer to what 9front does.(I think).
12:27 < joe7> just want to run it by you..
12:27 < cinap_lenrek> joe7: obviously you want it to be symmetic
12:27 < cinap_lenrek> like dont push that extra complexity to the caller
12:27 < cinap_lenrek> the rest is just implementation detail
12:28 < joe7> izaki, there is a way to read nvram and secstore keys automatically in the boot process.
12:29 < joe7> cinap_lenrek: so, making the free more robust seems the obvious choice. Instead of assuming that free will always receive the data pointer, we make the assumption that the pointer being freed can be any where in a buffer's data space.
12:30 < cinap_lenrek> no.
12:30 < cinap_lenrek> free needs to be called exactly on the pointer returned from mallocalign
12:30 < joe7> so, someone needs to record the pointer returned by mallocalign..
12:31 < joe7> the allocator only keeps track of the Bhdr's in the Pool structure now.
12:31 < cinap_lenrek> or mark it with a header to find the Bhdr
12:31 < cinap_lenrek> or some padding bytes
12:31 < joe7> good idea, thanks, will think through.
12:32 < cinap_lenrek> i think pool has align magic for this
12:32 < cinap_lenrek> so free is kind of search for the Bhdr
12:32 < cinap_lenrek> but thats an implementation details
12:33 < cinap_lenrek> but calling free() on something other than the pointer returned by mallocalign should be undefined
12:33 < cinap_lenrek> and you shouldnt rely on it
 */
static void*
alignptr(void *v, u32 align, s32 offset)
{
	char *c;
	u32 off;

	c = v;
	if(align){
		off = ((u32)(uintptr)c) % align;
		if(off != offset){
			offset -= off;
			if(offset < 0)
				offset += align;
			c += offset;
		}
	}
	return c;
}
void*
mallocalign(uintptr dsize, u32 align, s32 offset, u32 span)
{
	uintptr asize;
	void *v;
	char *c;
	int skip;
	Balign *ba;
	Bhdr *b;

	/*
	 * allocate block
	 * 	dsize bytes
	 *	addr == offset (modulo align)
	 *	does not cross span-byte block boundary
	 *
	 * to satisfy alignment, just allocate an extra
	 * align bytes and then shift appropriately.
	 *
	 * to satisfy span, try once and see if we're
	 * lucky.  the second time, allocate 2x asize
	 * so that we definitely get one not crossing
	 * the boundary.
	 */
	if(align){
		if(offset < 0)
			offset = align - ((-offset)%align);
		offset %= align;
	}
	asize = dsize+align+sizeof(Balign);
	v = mallocz(asize, 1);
	if(v == nil)
		return nil;
	if(span && (uintptr)v/span != ((uintptr)v+asize)/span){
		/* try again */
		free(v);
		v = mallocz(2*asize, 1);
		if(v == nil)
			return nil;
	}

	/*
	 * figure out what pointer we want to return
	 */
	c = alignptr(v, align, offset);
	if(span && (uintptr)c/span != (uintptr)(c+dsize-1)/span){
		c += span - (uintptr)c%span;
		c = alignptr(c, align, offset);
		if((uintptr)c/span != (uintptr)(c+dsize-1)/span){
			free(v);
			werrstr("cannot satisfy dsize %lud span %lud with align %lud+%ld", dsize, span, align, offset);
			return nil;
		}
	}
	skip = c - (char*)v;
	if(skip == 0){ /* perfect match, Hallelujah */
		return c;
	}else if (skip < sizeof(Balign)){
		/* TODO this situation should be handled, error for now */
		werrstr("skip %d < sizeof(Balign) %d cannot satisfy dsize %lud span %lud with align %lud+%ld", skip, sizeof(Balign), dsize, span, align, offset);
		return nil;
	}else{
		/* add the Balign header to point back to the header */
		ba = (Balign*)(c-sizeof(Balign));
		D2BPC(b, v, getcallerpc(&dsize), "alloc:D2B:mallocalign");
		ba->hdr = b;
		setmalloctag(v, getcallerpc(&dsize));
		if(0)print("mallocalign dsize %zd align %d 0x%x offset %d span %d\n"
			"	b 0x%p b->magic 0x%x b->size %zd\n"
			"	ba 0x%p ba->hdr 0x%p v 0x%p c 0x%p\n",
			dsize, align, align, offset, span, b, b->magic, b->size,
			ba, ba->hdr, v, c);
		return c;
	}
}

void
free(void *v)
{
	Bhdr *b;

	if(v != nil) {
		D2BPC(b, v, getcallerpc(&v), "alloc:D2B:free");
		poolfree(mainmem, v);
	}
}

/* this function signature is tied to emu which is tied to the system's libc.h */
void*
realloc(void *v, ulong size)
{
	void *nv;

	if(size == 0)
		return malloc(size);	/* temporary change until realloc calls can be checked */
	nv = poolrealloc(mainmem, v, size);
	if(nv != nil) {
		nv = (uintptr*)nv;
		setrealloctag(nv, getcallerpc(&v));
		if(v == nil)
			setmalloctag(v, getcallerpc(&v));
	}
	return nv;
}

void
setmalloctag(void *v, uintptr pc)
{
	Bhdr *b;

	if(v != nil){
		D2BPC(b, v, getcallerpc(&v), "alloc:D2B:setmalloctag");
		b->allocpc = pc;
	}
}

uintptr
getmalloctag(void *v)
{
	Bhdr *b;

	if(v == nil)
		return ~0;
	D2BPC(b, v, getcallerpc(&v), "alloc:D2B:getmalloctag");
	return b->allocpc;
}

void
setrealloctag(void *v, uintptr pc)
{
	Bhdr *b;

	if(v != nil){
		D2BPC(b, v, getcallerpc(&v), "alloc:D2B:setrealloctag");
		b->reallocpc = pc;
	}
}

uintptr
getrealloctag(void *v)
{
	Bhdr *b;

	if(v == nil)
		return ~0;
	D2BPC(b, v, getcallerpc(&v), "alloc:D2B:getrealloctag");
	return b->reallocpc;
}

ulong
msize(void *v)
{
	if(v == nil)
		return 0;
	return poolmsize(mainmem, v);
}

/* this function signature is tied to emu which is tied to the system's libc.h */
void*
calloc(ulong n, ulong szelem)
{
	return malloc(n*szelem);
}

void
pooldump(Bhdr *b, int d, int c)
{
	Bhdr *t;

	if(b == nil)
		return;

	print("%.8p %.8p %.8p %c %4d %zud (f %.8p p %.8p)\n",
		b, b->left, b->right, c, d, b->size, b->fwd, b->prev);
	d++;
	for(t = b->fwd; t != b; t = t->fwd)
		print("\t%.8p %.8p %.8p\n", t, t->prev, t->fwd);
	pooldump(b->left, d, 'l');
	pooldump(b->right, d, 'r');
}

void
poolshow(void)
{
	int i;

	for(i = 0; i < table.n; i++) {
		print("Arena: %s root=%.8p\n", table.pool[i].name, table.pool[i].root);
		pooldump(table.pool[i].root, 0, 'R');
	}
}

void
poolsetcompact(Pool *p, void (*move)(void*, void*))
{
	p->move = move;
}

int
poolcompact(Pool *pool)
{
	Bhdr *base, *limit, *ptr, *end, *next;
	int compacted, nb;

	if(pool->move == nil || pool->lastfree == pool->nfree)
		return 0;

	pool->lastfree = pool->nfree;

	base = pool->chain;
	ptr = B2NB(base);	/* First Block in arena has clink */
	limit = B2LIMIT(base);
	compacted = 0;

	pool->root = nil;
	end = ptr;
	while(base != nil) {
		next = B2NB(ptr);
		if(ptr->magic == MAGIC_A || ptr->magic == MAGIC_I) {
			if(ptr != end) {
				memmove(end, ptr, ptr->size);
				pool->move(B2D(ptr), B2D(end));
				compacted = 1;
			}
			end = B2NB(end);
		}
		if(next >= limit) {
			nb = (uchar*)limit - (uchar*)end;
			if(nb > 0){
				if(nb < pool->quanta+1)
					panic("poolcompact: leftover too small\n");
				end->size = nb;
				B2T(end)->hdr = end;
				pooladd(pool, end);
			}
			base = base->clink;
			if(base == nil)
				break;
			ptr = B2NB(base);
			end = ptr;	/* could do better by copying between chains */
			limit = B2LIMIT(base);
		} else
			ptr = next;
	}

	return compacted;
}

void
poolsize(Pool *p, uintptr max, int contig)
{
	void *x;

	print("poolsize max %zud contig %d\n", max, contig);
	p->maxsize = max;
	if(max == 0)
		p->ressize = max;
	else if(max < RESERVED)
		p->ressize = max;
	else
		p->ressize = max-RESERVED;
	if (contig && max > 0) {
		p->chunk = max-1024;
		print("poolsize: poolalloc() contig chunk 0x%zx %zd\n", p->chunk, p->chunk);
		x = poolalloc(p, p->chunk);
		if(x == nil)
			panic("poolsize: don't have %d bytes\n", p->chunk);
		print("poolsize: before poolfree()\n");
		poolfree(p, x);
		print("poolsize: after poolfree()\n");
		p->hw = 0;
	}
}

static void
_poolfault(void *v, char *msg, uintptr c)
{
	Prog *xp;

	auditmemloc(msg, v);
	printfreehist(v);
	/*
	 * Same trick as pc64/trap.c's dumpregs() enhancement: name the
	 * Dis Prog and module current when the allocator itself catches
	 * a bad pointer, since the two native PCs already printed below
	 * cannot be resolved to a function without a symbol table this
	 * port's linked kernel does not carry.  See doc/inferno-ports.ms.
	 */
	/*
	 * xp->R (currun()'s Prog struct) is only refreshed at the start
	 * and end of xec()'s whole PQUANTA=2048-instruction quantum, not
	 * per instruction -- mid-quantum it can be stale by up to 2048
	 * instructions.  The plain global R (libinterp/xec.c) is live at
	 * exactly this point instead; see badptrslot()'s comment in
	 * libinterp/xec.c for the full story.  See doc/inferno-ports.ms.
	 */
	xp = currun();
	/*
	 * Same fix as notefree()'s own identical pattern (see its
	 * comment): read xp->R.M, currun()'s own Prog's saved register
	 * file, not the plain global R -- a live xp does not mean the
	 * global R has been (re)loaded for it, confirmed by a first fix
	 * that only gated the global on "xp != nil" and kept crashing
	 * anyway. pc64/trap.c's dumpregs() already reads xp->R.M this
	 * way and was never exposed to the bug. This call site is far
	 * rarer than notefree()'s (only real pool corruption reaches
	 * it, vs. every free), so it was never itself caught crashing,
	 * but the same stale global read was there -- fixed identically
	 * rather than left as a known-parallel gap. See
	 * doc/inferno-ports.ms.
	 */
	if(xp != nil && xp->R.M != nil && xp->R.M != H && xp->R.M->m != nil)
		print("_poolfault: running Dis pid %d module %s PC %#p\n",
			xp->pid, xp->R.M->m->name, xp->R.PC);
	else
		print("_poolfault: no live Dis prog, xp %#p\n", xp);
	panic("%s %p (from %p/%zux)", msg, v, getcallerpc(&v), c);
}

static void
dumpvl(char *msg, uintptr *v, int n)
{
	int i, l;

	l = print("%s at %p: ", msg, v);
	for(i = 0; i < n; i++) {
		if(l >= 60) {
			print("\n");
			l = print("    %p: ", v);
		}
		l += print(" %zux", *v++);
	}
	print("\n");
	USED(l);
}

static void
corrupted(char *str, char *msg, Pool *p, Bhdr *b, void *v)
{
	print("%s(%p): pool %s CORRUPT: %s at %p'%zud(magic=%ux)\n",
		str, v, p->name, msg, b, b->size, b->magic);
	dumpvl("bad Bhdr", (uintptr *)((uintptr)b & ~3)-4, 10);
}

static void
_auditmemloc(char *str, void *v)
{
	Pool *p;
	Bhdr *bc, *ec, *b, *nb, *fb = nil;
	char *fmsg, *msg;
	uintptr fsz;

	SET(fsz, fmsg, nb);
	for (p = &table.pool[0]; p < &table.pool[nelem(table.pool)]; p++) {
		ilock(&p->l);
		for (bc = p->chain; bc != nil; bc = bc->clink) {
			if (bc->magic != MAGIC_E) {
				iunlock(&p->l);
				corrupted(str, "chain hdr!=MAGIC_E", p, bc, v);
				goto nextpool;
			}
			ec = B2LIMIT(bc);
			if (((Bhdr*)v >= bc) && ((Bhdr*)v < ec)){
				goto found;
			}
		}
		iunlock(&p->l);
nextpool:	;
	}
	print("%s: %lux not in pools\n", str, v);
	return;

found:
	for (b = bc; b < ec; b = nb) {
		switch(b->magic) {
		case MAGIC_F:
			msg = "free blk";
			break;
		case MAGIC_I:
			msg = "immutable block";
			break;
		case MAGIC_A:
			msg = "block";
			break;
		default:
			if (b == bc && b->magic == MAGIC_E) {
				msg = "pool hdr";
				break;
			}
			iunlock(&p->l);
			corrupted(str, "bad magic", p, b, v);
			goto badchunk;
		}
		if (b->size <= 0 || (b->size & p->quanta)) {
			iunlock(&p->l);
			corrupted(str, "bad size", p, b, v);
			goto badchunk;
		}
		if (fb != nil)
			break;
		nb = B2NB(b);
		if ((Bhdr*)v < nb) {
			fb = b;
			fsz = b->size;
			fmsg = msg;
		}
	}
	iunlock(&p->l);
	if (b >= ec) {
		if (b > ec)
			corrupted(str, "chain size mismatch", p, b, v);
		else if (b->magic != MAGIC_E)
			corrupted(str, "chain end!=MAGIC_E", p, b, v);
	}
badchunk:
	if (fb != nil) {
		print("%s: %p in %s:", str, v, p->name);
		if (fb == v)
			print(" is %s '%zux\n", fmsg, fsz);
		else
			print(" in %s at %p B2D 0x%p size %zux ec 0x%p next block 0x%p searched address 0x%p\n",
				fmsg, fb, B2D(fb), fsz, ec, nb, v);
		dumpvl("area", (uintptr *)((uintptr)v & ~3)-4, 20);
	}
}

char *
poolaudit(char*(*audit)(int, Bhdr *))
{
	Pool *p;
	Bhdr *bc, *ec, *b;
	char *r = nil;

	for (p = &table.pool[0]; p < &table.pool[nelem(table.pool)]; p++) {
		ilock(&p->l);
		for (bc = p->chain; bc != nil; bc = bc->clink) {
			if (bc->magic != MAGIC_E) {
				iunlock(&p->l);
				return "bad chain hdr";
			}
			ec = B2LIMIT(bc);
			for (b = bc; b < ec; b = B2NB(b)) {
				if (b->size <= 0 || (b->size & p->quanta))
					r = "bad size in bhdr";
				else
					switch(b->magic) {
					case MAGIC_E:
						if (b != bc) {
							r = "unexpected MAGIC_E";
							break;
						}
					case MAGIC_F:
					case MAGIC_A:
					case MAGIC_I:
						r = audit(p->pnum, b);
						break;
					default:
						r = "bad magic";
					}
				if (r != nil) {
					iunlock(&p->l);
					return r;
				}
			}
			if (b != ec || b->magic != MAGIC_E) {
				iunlock(&p->l);
				return "bad chain ending";
			}
		}
		iunlock(&p->l);
	}
	return r;
}

/*
void
poolinit(void)
{
	debugkey('m', "memory pools", poolsummary, 0);
}
*/
/*
 * 9front's secalloc()/secfree(): memory for keys, cleared before it
 * goes back to the pool.  9front flags the block so that free() also
 * clears it; here the clearing is only in secfree(), which is what
 * the callers copied from 9front (../port/wifi.c) use.
 */
void*
secalloc(ulong n)
{
	return smalloc(n);
}

void
secfree(void *p)
{
	if(p == nil)
		return;
	memset(p, 0, msize(p));
	free(p);
}
