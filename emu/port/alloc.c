#include "dat.h"
#include "fns.h"
#include "interp.h"
#include "error.h"

enum
{
	MAXPOOL		= 4
};

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
	int	quanta;
	int	chunk;
	int	monitor;
	uintptr	ressize;	/* restricted size */
	uintptr	cursize;
	uintptr	arenasize;
	uintptr	hw;
	Lock	l;
	Bhdr*	root;
	Bhdr*	chain;
	uintptr	nalloc;
	uintptr	nfree;
	int	nbrk;
	int	lastfree;
	int	insec;		/* diagnostic: threads inside the locked region */
	void	(*move)(void*, void*);
};

void*	initbrk(ulong);
void	setmalloctag(void*, uintptr);
void	setrealloctag(void*, uintptr);
uintptr getmalloctag(void*);
uintptr getrealloctag(void*);

/* keep the quanta above the size of 5 pointers and 2 longs else the next block
	will be getting overwritten by the header -- starts a corruption hunt
	when pointer size = 8 bytes, then 63 = 2^q -1
		for 4 bytes, 31
	TODO make this a macro?
	for allocpc and reallocpc, 2 * 8 = 16 bytes get added
	so, minimum size = 2*4 + 2*8 + 5*8 = 64, using 127 to satisfy 2^q -1
 */
struct
{
	int	n;
	Pool	pool[MAXPOOL];
	/* Lock l; */
} table = {
	3,
	{
		{ "main",  0, 	32*1024*1024, 127,  512*1024, 0, 31*1024*1024 },
		{ "heap",  1, 	32*1024*1024, 127,  512*1024, 0, 31*1024*1024 },
		{ "image", 2,   64*1024*1024+256, 127, 4*1024*1024, 1, 63*1024*1024 },
	}
};

Pool*	mainmem = &table.pool[0];
Pool*	heapmem = &table.pool[1];
Pool*	imagmem = &table.pool[2];

static void _auditmemloc(char *, void *);
void (*auditmemloc)(char *, void *) = _auditmemloc;
static void _poolfault(void *, char *, uintptr);
void (*poolfault)(void *, char *, uintptr) = _poolfault;

enum {
	Monitor = 1
};

void	(*memmonitor)(int, uintptr, void *, uintptr) = nil;
#define	MM(v,pc,base,size)	if(!Monitor || memmonitor==nil){} else memmonitor((v),(pc),(base),(size))

#define CKLEAK	0
int	ckleak;
#define	ML(v, sz, pc)	if(CKLEAK && ckleak && v){ if(sz) fprint(2, "%zx %lux %zx\n", (uintptr)v, (ulong)sz, (uintptr)pc); else fprint(2, "%zx\n", (uintptr)v); }

int
memusehigh(void)
{
	return 	mainmem->cursize > mainmem->ressize ||
			heapmem->cursize > heapmem->ressize ||
			0 && imagmem->cursize > imagmem->ressize;
}

int
memlow(void)
{
	return heapmem->cursize > (heapmem->maxsize)/2;
}

/*
 * Size is uintptr, not int. maxsize and ressize have always been uintptr, but
 * this took an int, so any pool of 2GB or more arrived truncated - 2GB as a
 * negative number and 4GB as zero - and the "size < RESERVED" test below then
 * reported it as "not enough memory" on a machine with plenty. That is what
 * stopped gpubench running a mesh of 28 cubed, which needs a few megabytes.
 *
 * A pool smaller than the reserve is a bad argument rather than a fatal
 * condition, so it is refused and the caller prints usage. Nothing is
 * modified before the check: the old version assigned both fields and then
 * panicked, which left the table inconsistent if anything had caught it.
 */
int
poolsetsize(char *s, uintptr size)
{
	int i;

	if(size < RESERVED)
		return 0;
	for(i = 0; i < table.n; i++) {
		if(strcmp(table.pool[i].name, s) == 0) {
			table.pool[i].maxsize = size;
			table.pool[i].ressize = size-RESERVED;
			return 1;
		}
	}
	return 0;
}

void
poolimmutable(void *v)
{
	Bhdr *b;

	D2B(b, v);
	b->magic = MAGIC_I;
}

void
poolmutable(void *v)
{
	Bhdr *b;

	D2B(b, v);
	b->magic = MAGIC_A;
	((Heap*)v)->color = mutator;
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

/*
 * Free-block poisoning, for the allocator corruption in doc/hpc-plan.md.
 * Off unless INFERNO_POOLPOISON is set in the environment, matching the
 * INFERNO_DRAWDEBUG / INFERNO_METAL_STATS convention already in this tree.
 *
 * The symptom is dopoolalloc faulting while walking the free tree, whose
 * left/right/fwd links live inside free blocks - so something writes into a
 * block after it has been freed. Filling the dead part of every free block
 * with a known byte and checking it when the block leaves the free tree turns
 * that into a report naming the block, the offset, the bytes that overwrote
 * it, and - most usefully - allocpc, the caller that last allocated it.
 *
 * Only the payload AFTER the tree links is filled: the links themselves are
 * live while the block sits in the tree.
 */
enum {
	Poisonbyte = 0xa5,
	/*
	 * Only the first Poisonmax bytes past the links are filled and
	 * checked, not the whole block. Filling everything cost a 275x
	 * slowdown on allocation-heavy work (fem(2) assembly went from 14ms
	 * to 3845ms), which perturbs timing far too much to be useful on
	 * anything race-dependent - and a write-after-free almost always
	 * lands near the start of the block anyway.
	 */
	Poisonmax = 128
};

static int	poolpoison = -1;	/* -1 = not yet looked up */

/* Looked up once, lazily: emu has no poolinit() to hang it off, and the
 * pools are in use before main() gets to parse anything. getenv() only scans
 * environ, so calling it from inside the allocator does not recurse. */
static int
poisonon(void)
{
	if(poolpoison < 0){
		poolpoison = getenv("INFERNO_POOLPOISON") != nil;
		/*
		 * Say so, once. A run that reports no corruption is worth
		 * nothing unless the checking was actually happening, and
		 * there was no way to tell the two apart from the output: both
		 * are silence. The same reasoning as faultprobe(1).
		 *
		 * print() from inside the allocator is already what
		 * poisoncheck does, so it is not a new risk here.
		 */
		if(poolpoison)
			print("POOLPOISON: on, free blocks are poisoned and checked\n");
	}
	return poolpoison;
}

static uchar*
poisonrange(Bhdr *b, uintptr *len)
{
	uchar *lo, *hi;

	lo = (uchar*)b + offsetof(Bhdr, u) + sizeof(b->u.s);
	hi = (uchar*)B2T(b);
	if(hi <= lo){
		*len = 0;
		return nil;
	}
	*len = hi - lo;
	if(*len > Poisonmax)
		*len = Poisonmax;
	return lo;
}

static void
poisonfill(Bhdr *b)
{
	uchar *q;
	uintptr n;

	if(!poisonon())
		return;
	if((q = poisonrange(b, &n)) != nil)
		memset(q, Poisonbyte, n);
}

static void
poisoncheck(Bhdr *b, char *where)
{
	uchar *q;
	uintptr n, i, j, e;

	if(!poisonon())
		return;
	if((q = poisonrange(b, &n)) == nil)
		return;
	for(i = 0; i < n; i++)
		if(q[i] != Poisonbyte)
			break;
	if(i == n)
		return;

	print("POOLPOISON %s: block %p size %zud written %zud bytes after free\n",
		where, b, (uintptr)b->size, (uintptr)i);
	/* ASLR makes the raw pc useless; print it relative to a known exported
	 * symbol so it can be resolved against the on-disk binary. */
	print("POOLPOISON allocpc=%#zx (poolalloc%+zd) reallocpc=%#zx\n",
		(uintptr)b->allocpc,
		(intptr)((uintptr)b->allocpc - (uintptr)poolalloc),
		(uintptr)b->reallocpc);
	e = i + 48;
	if(e > n)
		e = n;
	print("POOLPOISON bytes:");
	for(j = i; j < e; j++)
		print(" %.2ux", q[j]);
	print("\nPOOLPOISON ascii: ");
	for(j = i; j < e; j++)
		print("%c", (q[j] >= 0x20 && q[j] < 0x7f)? q[j]: '.');
	print("\n");
	/* Do not fault here: the point is to see every writer, not just the
	 * first, and the block is about to be reused and overwritten anyway. */
	poisonfill(b);
}

/*
 * In-flight syscall buffers, under the same INFERNO_POOLPOISON flag.
 *
 * Sys_read (emu/port/inferno.c) hands a Limbo array's raw data pointer to the
 * host read AFTER release(), so the VM is free for the whole call and the
 * device eventually memmoves its reply into that pointer. The corruption in
 * doc/hpc-plan.md is always a device reply sitting in a free block, which says
 * that buffer is being freed while the read is still running - but not by
 * whom, and every hypothesis about who has been wrong so far.
 *
 * So this catches it at the free, which is the side that has not been
 * instrumented: a syscall registers its buffer for the duration of the
 * released window, and poolfree reports if the block it is about to free
 * contains one. Whoever is freeing it is then on the stack.
 */
/*
 * Deliberately lock-free and small. A first version took a lock on every
 * poolfree, which serialised the allocator enough to make the corruption stop
 * happening at all - 0 reports in 30 runs against a base rate near 1 in 10.
 * That is the third time instrumentation has moved this bug, so the rule here
 * is: never add synchronisation to a path this hot. A racing slot read can
 * miss an entry (a false negative, which is fine) or in principle see a stale
 * one, so verify any hit by inspection rather than trusting it blindly.
 */
enum { Ninflight = 32 };

static struct {
	void*	p;
	uintptr	len;
} inflight[Ninflight];

/* add != 0 to register, 0 to drop. Safe to call before poisonon() is
 * meaningful; it simply does nothing when the flag is off. */
void
poolinflight(void *v, uintptr len, int add)
{
	int i;

	if(!poisonon() || v == nil)
		return;
	for(i = 0; i < Ninflight; i++){
		if(add){
			if(inflight[i].p == nil){
				inflight[i].len = len;
				__atomic_store_n(&inflight[i].p, v, __ATOMIC_RELEASE);
				break;
			}
		}else if(__atomic_load_n(&inflight[i].p, __ATOMIC_ACQUIRE) == v){
			__atomic_store_n(&inflight[i].p, nil, __ATOMIC_RELEASE);
			break;
		}
	}
}

/* Called from poolfree before it takes the pool lock. */
static void
inflightcheck(Bhdr *b)
{
	uchar *lo, *hi, *q;
	int i;

	if(!poisonon())
		return;
	lo = (uchar*)b;
	hi = lo + b->size;
	for(i = 0; i < Ninflight; i++){
		q = __atomic_load_n(&inflight[i].p, __ATOMIC_ACQUIRE);
		if(q != nil && q >= lo && q < hi){
			print("POOLINFLIGHT: freeing block %p size %zud holding a live "
				"syscall buffer %p len %zud\n",
				b, (uintptr)b->size, q, inflight[i].len);
			break;
		}
	}
}

/*
 * Mutual-exclusion check for the pool lock, under the same INFERNO_POOLPOISON
 * flag. The corruption in doc/hpc-plan.md shows up as pooldel finding a block
 * whose poison has already been overwritten, which means the block was handed
 * out while still in the free tree - a double allocation, which can only
 * happen if two threads are inside the locked region at once. This says
 * whether that is what is happening. Per-pool, because two threads in two
 * different pools overlapping is perfectly legal.
 */
static void
poolenter(Pool *p)
{
	lock(&p->l);
	if(poisonon() && __atomic_add_fetch(&p->insec, 1, __ATOMIC_SEQ_CST) != 1)
		print("POOLLOCK: %d threads inside %s's locked region\n",
			p->insec, p->name);
}

static void
poolexit(Pool *p)
{
	if(poisonon())
		__atomic_sub_fetch(&p->insec, 1, __ATOMIC_SEQ_CST);
	unlock(&p->l);
}

void
pooldel(Pool *p, Bhdr *t)
{
	Bhdr *s, *f, *rp, *q;

	poisoncheck(t, "pooldel");
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

	/* Before the links are written, and covering every return path below.
	 * The poison range starts after u.s, so it never touches them. */
	poisonfill(q);
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

static void*
dopoolalloc(Pool *p, uintptr asize, uintptr pc)
{
	Bhdr *q, *t;
	intptr alloc, ldr, ns, frag;
	intptr osize, size;

	if(asize >= 1024*1024*1024)	/* for sanity and to avoid overflow */
		return nil;
	size = asize;
	osize = size;
	size = (size + BHDRSIZE + p->quanta) & ~(p->quanta);

	poolenter(p);
	p->nalloc++;

	t = p->root;
	q = nil;
	while(t) {
		if(t->size == size) {
			t = t->fwd;
			pooldel(p, t);
			t->magic = MAGIC_A;
			p->cursize += t->size;
			if(p->cursize > p->hw)
				p->hw = p->cursize;
			poolexit(p);
			if(p->monitor)
				MM(p->pnum, pc, B2D(t), size);
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
		pooldel(p, q);
		q->magic = MAGIC_A;
		frag = q->size - size;
		if(frag < (size>>2) && frag < 0x8000) {
			p->cursize += q->size;
			if(p->cursize > p->hw)
				p->hw = p->cursize;
			poolexit(p);
			if(p->monitor)
				MM(p->pnum, pc, B2D(q), size);
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
		poolexit(p);
		if(p->monitor)
			MM(p->pnum, pc, B2D(q), size);
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
				poolexit(p);
				return poolalloc(p, osize);
			}

			poolexit(p);
			print("arena %s too large: size %zd maxsize %zud ressize %zud"
				" cursize %zud arenasize %zud\n",
				 p->name, size, p->maxsize, p->ressize,
				 p->cursize, p->arenasize);
			return nil;
		}
		alloc = ns+ldr+ldr;
		p->arenasize += alloc;
	}

	p->nbrk++;
	t = (Bhdr *)sbrk(alloc);
	if(t == (void*)-1) {
		p->nbrk--;
		poolexit(p);
		return nil;
	}
#ifdef __NetBSD__
	/* Align allocations to 16 bytes */
	{
		const size_t off = __builtin_offsetof(struct Bhdr, u.data);
		struct assert_align {
			unsigned int align_ok : (off % 8 == 0) ? 1 : -1;
		};

		const uintptr align = (off - 1) % 16;
		t = (Bhdr *)(((uintptr)t + align) & ~align);
	}
#else
	/* Double alignment */
	t = (Bhdr *)(((uintptr)t + 7) & ~7);
#endif
	if(p->chain != nil && (char*)t-(char*)B2LIMIT(p->chain)-ldr == 0){
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
		poolexit(p);
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
	poolexit(p);
	if(p->monitor)
		MM(p->pnum, pc, B2D(t), size);
	return B2D(t);
}

void *
poolalloc(Pool *p, uintptr asize)
{
	Prog *prog;

	if(p->cursize > p->ressize && (prog = currun()) != nil && prog->flags&Prestricted)
		return nil;
	return dopoolalloc(p, asize, getcallerpc(&p));
}

void
poolfree(Pool *p, void *v)
{
	Bhdr *b, *c;
	extern Bhdr *ptr;

	D2B(b, v);
	inflightcheck(b);
	if(p->monitor)
		MM(p->pnum|(1<<8), getcallerpc(&p), v, b->size);

	poolenter(p);
	p->nfree++;
	p->cursize -= b->size;
	c = B2NB(b);
	if(c->magic == MAGIC_F) {	/* Join forward */
		if(c == ptr)
			ptr = b;
		pooldel(p, c);
		c->magic = 0;
		b->size += c->size;
		B2T(b)->hdr = b;
	}

	c = B2PT(b)->hdr;
	if(c->magic == MAGIC_F) {	/* Join backward */
		if(b == ptr)
			ptr = c;
		pooldel(p, c);
		b->magic = 0;
		c->size += b->size;
		b = c;
		B2T(b)->hdr = b;
	}
	pooladd(p, b);
	poolexit(p);
}

void *
poolrealloc(Pool *p, void *v, uintptr size)
{
	Bhdr *b;
	void *nv;
	intptr osize;

	if(size >= 1024*1024*1024)	/* for sanity and to avoid overflow */
		return nil;
	if(size == 0){
		poolfree(p, v);
		return nil;
	}
	SET(osize);
	if(v != nil){
		lock(&p->l);
		D2B(b, v);
		osize = b->size - BHDRSIZE;
		unlock(&p->l);
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

	if(v == nil)
		return 0;
	lock(&p->l);
	D2B(b, v);
	size = b->size - BHDRSIZE;
	unlock(&p->l);
	return size;
}

static uintptr
poolmax(Pool *p)
{
	Bhdr *t;
	uintptr size;

	lock(&p->l);
	size = p->maxsize - p->cursize;
	t = p->root;
	if(t != nil) {
		while(t->right != nil)
			t = t->right;
		if(size < t->size)
			size = t->size;
	}
	if(size >= BHDRSIZE)
		size -= BHDRSIZE;
	unlock(&p->l);
	return size;
}

uintptr
poolmaxsize(void)
{
	int i;
	uintptr total;

	total = 0;
	for(i = 0; i < nelem(table.pool); i++)
		total += table.pool[i].maxsize;
	return total;
}

int
poolread(char *va, int count, uintptr offset)
{
	Pool *p;
	int n, i, signed_off;

	n = 0;
	signed_off = offset;
	for(i = 0; i < table.n; i++) {
		p = &table.pool[i];
		n += snprint(va+n, count-n, "%11zud %11zud %11zud %11zud %11zud %11d %11zud %s\n",
			p->cursize,
			p->maxsize,
			p->hw,
			p->nalloc,
			p->nfree,
			p->nbrk,
			poolmax(p),
			p->name);

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

void*
smalloc(uintptr size)
{
	void *v;

	for(;;){
		v = malloc(size);
		if(v != nil)
			break;
		if(0)
			print("smalloc waiting from %zx\n", getcallerpc(&size));
		osenter();
		osmillisleep(100);
		osleave();
	}
	setmalloctag(v, getcallerpc(&size));
	setrealloctag(v, 0);
	return v;
}

void*
kmalloc(uintptr size)
{
	void *v;

	v = dopoolalloc(mainmem, size, getcallerpc(&size));
	if(v != nil){
		ML(v, size, getcallerpc(&size));
		setmalloctag(v, getcallerpc(&size));
		setrealloctag(v, 0);
		memset(v, 0, size);
		MM(0, getcallerpc(&size), v, size);
	}
	return v;
}

/* this function signature is tied to the system's libc.h */
void*
__wrap_malloc(ulong size)
{
	void *v;

	v = poolalloc(mainmem, size);
	if(v != nil){
		ML(v, size, getcallerpc(&size));
		setmalloctag(v, getcallerpc(&size));
		setrealloctag(v, 0);
		memset(v, 0, size);
		MM(0, getcallerpc(&size), v, size);
	} else 
		print("malloc failed from %zx\n", getcallerpc(&size));
	return v;
}

/* this function signature is tied to the system's libc.h */
void*
__wrap_mallocz(ulong size, int clr)
{
	void *v;

	v = poolalloc(mainmem, size);
	if(v != nil){
		ML(v, size, getcallerpc(&size));
		setmalloctag(v, getcallerpc(&size));
		setrealloctag(v, 0);
		if(clr)
			memset(v, 0, size);
		MM(0, getcallerpc(&size), v, size);
	} else 
		print("mallocz failed from %zx\n", getcallerpc(&size));
	return v;
}

void
__wrap_free(void *v)
{
	Bhdr *b;

	if(v != nil) {
		D2B(b, v);
		ML(v, 0, 0);
		MM(1<<8|0, getcallerpc(&v), (uintptr*)v, b->size);
		poolfree(mainmem, v);
	}
}

/* this function signature is tied to the system's libc.h */
void*
__wrap_realloc(void *v, ulong size)
{
	void *nv;

	if(size == 0)
		return malloc(size);	/* temporary change until realloc calls can be checked */
	nv = poolrealloc(mainmem, v, size);
	ML(v, 0, 0);
	ML(nv, size, getcallerpc(&v));
	if(nv != nil) {
		setrealloctag(nv, getcallerpc(&v));
		if(v == nil)
			setmalloctag(v, getcallerpc(&v));
	} else 
		print("realloc failed from %zx\n", getcallerpc(&v));
	return nv;
}

void
setmalloctag(void *v, uintptr pc)
{
	Bhdr *b;

	if(v != nil){
		D2B(b, v);
		b->allocpc = pc;
	}
}

uintptr
getmalloctag(void *v)
{
	Bhdr *b;

	if(v == nil)
		abort();
	D2B(b, v);
	return b->allocpc;
}

void
setrealloctag(void *v, uintptr pc)
{
	Bhdr *b;

	if(v != nil){
		D2B(b, v);
		b->reallocpc = pc;
	}
}

uintptr
getrealloctag(void *v)
{
	Bhdr *b;

	if(v == nil)
		abort();
	D2B(b, v);
	return b->reallocpc;
}

ulong
msize(void *v)
{
	if(v == nil)
		return 0;
	return poolmsize(mainmem, v);
}

/* this function signature is tied to the system's libc.h */
void*
__wrap_calloc(ulong n, ulong szelem)
{
	return malloc(n*szelem);
}

void
pooldump(Pool *p)
{
	Bhdr *b, *base, *limit, *ptr;

	b = p->chain;
	if(b == nil)
		return;
	base = b;
	ptr = b;
	limit = B2LIMIT(b);

	while(base != nil) {
		print("\tbase #%.8p ptr #%.8p", base, ptr);
		if(ptr->magic == MAGIC_A || ptr->magic == MAGIC_I)
			print("\tA%.5d pc 0x%p\n", ptr->size, getmalloctag(ptr));
		else if(ptr->magic == MAGIC_E)
			print("\tE\tL#%.8p\tS#%.8lx\n", ptr->clink, ptr->csize);
		else
			print("\tF%.5d\tL#%.8p\tR#%.8p\tF#%.8p\tP#%.8p\tT#%.8p\n",
				ptr->size, ptr->left, ptr->right, ptr->fwd, ptr->prev, ptr->parent);
		ptr = B2NB(ptr);
		if(ptr >= limit) {
			print("link to #%.8p\n", base->clink);
			base = base->clink;
			if(base == nil)
				break;
			ptr = base;
			limit = B2LIMIT(base);
		}
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
				if(nb < pool->quanta+1){
					print("poolcompact: leftover too small\n");
					abort();
				}
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

static void
_poolfault(void *v, char *msg, uintptr c)
{
	auditmemloc(msg, v);
	panic("%s %lux (from %lux/%lux)", msg, v, getcallerpc(&v), c);
}

static void
dumpvl(char *msg, uintptr *v, int n)
{
	int i, l;

	l = print("%s at %p: ", msg, v);
	for (i = 0; i < n; i++) {
		if (l >= 60) {
			print("\n");
			l = print("    %p: ", v);
		}
		l += print(" %zx", *v++);
	}
	print("\n");
}

static void
corrupted(char *str, char *msg, Pool *p, Bhdr *b, void *v)
{
	print("%s(%p): pool %s CORRUPT: %s at %p'%ud(magic=%ux)\n",
		str, v, p->name, msg, b, b->size, b->magic);
	dumpvl("bad Bhdr", (uintptr *)((uintptr)b & ~3)-4, 10);
}

static void
_auditmemloc(char *str, void *v)
{
	Pool *p;
	Bhdr *bc, *ec, *b, *nb, *fb = nil;
	char *fmsg, *msg;
	ulong fsz;

	SET(fsz);
	SET(fmsg);
	for (p = &table.pool[0]; p < &table.pool[nelem(table.pool)]; p++) {
		lock(&p->l);
		for (bc = p->chain; bc != nil; bc = bc->clink) {
			if (bc->magic != MAGIC_E) {
				unlock(&p->l);
				corrupted(str, "chain hdr!=MAGIC_E", p, bc, v);
				goto nextpool;
			}
			ec = B2LIMIT(bc);
			if (((Bhdr*)v >= bc) && ((Bhdr*)v < ec))
				goto found;
		}
		unlock(&p->l);
nextpool:	;
	}
	print("%s: %p not in pools\n", str, v);
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
			unlock(&p->l);
			corrupted(str, "bad magic", p, b, v);
			goto badchunk;
		}
		if (b->size <= 0 || (b->size & p->quanta)) {
			unlock(&p->l);
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
	unlock(&p->l);
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
			print(" is %s '%lux\n", fmsg, fsz);
		else
			print(" in %s at %p'%lux\n", fmsg, fb, fsz);
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
		lock(&p->l);
		for (bc = p->chain; bc != nil; bc = bc->clink) {
			if (bc->magic != MAGIC_E) {
				unlock(&p->l);
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
					unlock(&p->l);
					return r;
				}
			}
			if (b != ec || b->magic != MAGIC_E) {
				unlock(&p->l);
				return "bad chain ending";
			}
		}
		unlock(&p->l);
	}
	return r;
}
