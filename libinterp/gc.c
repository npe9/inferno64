#include "lib9.h"
#include "interp.h"
#include "pool.h"

#define DP if(1){}else print

enum
{
	Quanta		= 50,		/* Allocated blocks to sweep each time slice usually */
	MaxQuanta	= 15*Quanta,
	PTRHASH		= (1<<5)
};

static int quanta = Quanta;
static int gce, gct = 1;

typedef struct Ptrhash Ptrhash;
struct Ptrhash
{
	Heap	*value;
	Ptrhash	*next;
};

	int	nprop;
	int	gchalt;
	int	mflag;
	int	mutator = 0;
	int	gccolor = 3;

	ulong	gcnruns;
	ulong	gcsweeps;
	ulong	gcbroken;
	ulong	gchalted;
	ulong	gcepochs;
	uvlong	gcdestroys;
	uvlong	gcinspects;

static	int	marker  = 1;
static	int	sweeper = 2;
static	Bhdr*	base;
static	Bhdr*	limit;
Bhdr*	ptr;
static	int	visit;
extern	Pool*	heapmem;
static	Ptrhash	*ptrtab[PTRHASH];
static	Ptrhash	*ptrfree;

#define	HASHPTR(p)	(((uintptr)(p) >> 6) & (PTRHASH - 1))

void
ptradd(Heap *v)
{
	int h;
	Ptrhash *p;

	if ((p = ptrfree) != nil)
		ptrfree = p->next;
	else if ((p = malloc(sizeof (Ptrhash))) == nil)
		error("ptradd malloc");
	h = HASHPTR(v);
	p->value = v;
	p->next = ptrtab[h];
	ptrtab[h] = p;
}

void
ptrdel(Heap *v)
{
	Ptrhash	*p, **l;

	for (l = &ptrtab[HASHPTR(v)]; (p = *l) != nil; l = &p->next) {
		if (p->value == v) {
			*l = p->next;
			p->next = ptrfree;
			ptrfree = p;
			return;
		}
	}
	/* ptradd must have failed */
}

static void
ptrmark(void)
{
	int	i;
	Heap	*h;
	Ptrhash	*p;

	for (i = 0; i < PTRHASH; i++) {
		for (p = ptrtab[i]; p != nil; p = p->next) {
			h = p->value;
			Setmark(h);
		}
	}
}

void
noptrs(Type *t, void *vw)
{
	USED(t);
	USED(vw);
}

static int markdepth;

/*
 * markheap() trusts every declared-pointer word it's handed: if it's
 * not H, it's D2H()'d and Setmark()'d (h->color written) with no
 * validation at all -- unlike freeptrs(), which has had checkfreeptr()
 * guarding the same kind of word since earlier in this hunt.  A small,
 * non-H garbage value here (this hunt's whole population: 0, 0x18,
 * 0x80, ...) computes a garbage Heap*, and Setmark() then WRITES to
 * whatever h->color happens to resolve to -- a live, unrelated
 * object's memory, corrupting it, with no crash at the write site
 * itself (an ordinary store, not a fault) to point at what happened.
 * rootset() calls markheap() on every live process's every stack
 * frame every GC pass (libinterp/gc.c's rootset()), so if this is the
 * mechanism, it explains the shape this hunt has chased for four-plus
 * sessions: a legitimate word somewhere holds transient garbage for
 * an instant mid-computation (register spill, uninitialized temp,
 * whatever), a GC pass lands on exactly that instant, and the mark
 * write lands on a frame that has nothing to do with the code that
 * produced the garbage.  Checked here, not assumed: see
 * doc/inferno-ports.ms.
 */
static void
checkmarkptr(WORD **q, Type *t, void *vw)
{
	extern void dumpstack(void);
	uintptr silent[8];
	uintptr val;
	int wordidx, i, n;

	/*
	 * Both earlier passes at this (one with a print() between each
	 * reread, one calling itself "silent") still had two full
	 * print() calls -- bad-word and object-type, each real kernel
	 * I/O -- between the *first* read (the one that decided this was
	 * worth reporting) and the reread loop.  Neither pass actually
	 * tested "immediately after, nothing run in between" at all; both
	 * left the print()-yields hypothesis open by accident.  This is
	 * the real version: every read, the first included, happens back
	 * to back in one tight loop with no function call of any kind
	 * between them, into a local array, volatile-qualified against
	 * ordinary compiler caching -- decided and reported only after.
	 * pc64-only, temporary.  See doc/inferno-ports.ms.
	 */
	for(n = 0; n < 8; n++)
		silent[n] = (uintptr)*(WORD*volatile*)q;
	val = silent[0];
	if(val == (uintptr)H || val >= 0x1000)
		return;
	/*
	 * Sanity check on the diagnostic itself, before trusting a single
	 * further line of this: val and silent[0] are the same variable
	 * by construction (the line above). If they ever print as
	 * different values in the very same print() call, that is proof
	 * the mismatch is in how this print() marshals a uintptr through
	 * %zx / FmtVLong, not in memory -- and would mean this whole
	 * multi-session hunt's every %zx-based capture needs rereading
	 * with that in mind. pc64-only, temporary.  See
	 * doc/inferno-ports.ms.
	 */
	print("markheap: sanity val %#zx silent0 %#zx eq %d\n",
		val, silent[0], val == silent[0]);
	wordidx = (int)(q - (WORD**)vw);
	print("markheap: bad word %#p (word %d of object %#p) val %#zx, "
		"running Dis pid %d module %s PC %#p inst %d\n",
		q, wordidx, vw, val,
		currun() != nil ? currun()->pid : -1,
		R.M != nil && R.M->m != nil ? R.M->m->name : "?", R.PC,
		R.M != nil && R.M->m != nil ? (int)((R.PC - 1) - R.M->m->prog) : -1);
	print("markheap: object type %#p size %d np %d map", t, t->size, t->np);
	for(i = 0; i < t->np; i++)
		print(" %#.2ux", t->map[i]);
	print("\n");
	for(n = 0; n < 8; n++)
		print("markheap: tight reread %d val %#zx\n", n, silent[n]);
	/*
	 * Two genuinely different shapes have been showing up under this
	 * one checker, conflated until now: word 0 of a size-8/np-1/map-
	 * {0x80} object (Tptr, OP(consp)'s own list cells) reads bad once
	 * and then reads as a valid pointer on literally the next access,
	 * every single capture so far, regardless of how the write inside
	 * OP(consp) is ordered (checked: reordering data-before-type made
	 * no difference to the rate). Every other shape seen (word 8, 14,
	 * 550, ... of larger objects, values like 0x18 matching this
	 * hunt's own original landmark) reads the same bad value on every
	 * one of the 8 tight rereads -- stable, not transient. Only the
	 * second kind gets treated as the real signal now: the first
	 * looks increasingly like it resolves before anything ever acts
	 * on the bad intermediate value, so continuing past it (instead
	 * of stopping the boot) is how the stable kind gets isolated for
	 * enough captures to say anything about it. pc64-only, temporary.
	 * See doc/inferno-ports.ms.
	 */
	for(n = 1; n < 8; n++)
		if(silent[n] != silent[0])
			return;
	dumpstack();
	abort();
}

/* code simpler with a depth search compared to a width search*/
void
markheap(Type *t, void *vw)
{
	Heap *h;
	uchar *p;
	int i, c, m;
	WORD **w, **q;
	Type *t1;

	if(t == nil || t->np == 0)
		return;

	markdepth++;
	w = (WORD**)vw;
	p = t->map;
	for(i = 0; i < t->np; i++) {
		c = *p++;
		if(c != 0) {
			q = w;
			for(m = 0x80; m != 0; m >>= 1) {
				/*
				 * Probe: a silent, back-to-back reread of a
				 * word checkmarkptr() has just flagged bad
				 * shows the correct value immediately and
				 * stably, every capture so far -- consistent
				 * with a stale/cached read at exactly this
				 * first touch, not a real writer catching up
				 * (nothing runs between the two reads that
				 * could write here).  This one forces a fresh
				 * load via volatile instead of trusting the
				 * compiler's normal (and normally correct,
				 * single-threaded) assumption that nothing
				 * changed *q since some earlier point.  If
				 * this alone makes the whole signal vanish,
				 * that is the answer.  pc64-only, temporary.
				 * See doc/inferno-ports.ms.
				 */
				if((c & m) && *(WORD*volatile*)q != H) {
					checkmarkptr(q, t, vw);
					h = D2H(*q);
					Setmark(h);
					if(h->color == propagator && --visit >= 0 && markdepth < 64){
						gce--;
						h->color = mutator;
						if((t1 = h->t) != nil)
							t1->mark(t1, H2D(void*, h));
					}
				}
				q++;
			}
		}
		w += 8;
	}
	markdepth--;
}

/*
 * This routine should be modified to be incremental, but how?
 */
void
markarray(Type *t, void *vw)
{
	int i;
	Heap *h;
	uchar *v;
	Array *a;

	USED(t);

	a = vw;
	t = a->t;
	if(a->root != H) {
		h = D2H(a->root);
		Setmark(h);
	}

	if(t->np == 0)
		return;

	v = a->data;
	for(i = 0; i < a->len; i++) {
		markheap(t, v);
		v += t->size;
	}
	visit -= a->len;
}

/*
 * Probe: checkmarkptr() (below) only ever sees l->data, a field
 * *inside* a list cell's own single allocation, with no way back to
 * that cell's own Heap header from there.  So it can't tell "this
 * cell is intact and something wrote garbage straight into l->data"
 * from "this cell itself is stale -- freed, its memory reused, and
 * l->data is just whatever the new occupant left there" apart.  This
 * checks the one place that has the cell itself in hand: poolcompact()
 * was checked and ruled out separately (heapmem's pool never gets
 * poolsetcompact() wired up in this port, only imagmem does, so it's
 * permanently a no-op here) -- this is the next item, the container's
 * own sanity, right before each cell's payload gets walked.  pc64-only,
 * temporary.  See doc/inferno-ports.ms.
 */
static void
checklistcell(List *l)
{
	extern void dumpstack(void);
	Heap *h;

	h = D2H(l);
	if(h->t == &Tlist && h->ref > 0)
		return;
	print("marklist: bad container %#p t %#p (want %#p) ref %d color %d\n",
		l, h->t, &Tlist, h->ref, h->color);
	dumpstack();
	abort();
}

void
marklist(Type *t, void *vw)
{
	List *l;
	Heap *h;

	USED(t);
	l = vw;
	checklistcell(l);
	markheap(l->t, l->data);
	while(visit > 0) {
		l = l->tail;
		if(l == H)
			return;
		h = D2H(l);
		Setmark(h);
		checklistcell(l);
		markheap(l->t, l->data);
		visit--;
	}
	l = l->tail;
	if(l != H) {
		D2H(l)->color = propagator;
		nprop = 1;
	}
}

static void
rootset(Prog *root)
{
	Heap *h;
	Type *t;
	Frame *f;
	Module *m;
	Stkext *sx;
	Modlink *ml;
	uchar *fp, *sp, *ex, *mp;

	mutator = gccolor % 3;
	marker = (gccolor-1)%3;
	sweeper = (gccolor-2)%3;

/* for debugging
	DP("rootset root=0x%p\n", root);
	while(root != nil) {
		DP("Prog state %d pid %d ticks %ld\n",
			root->state, root->pid, root->ticks);
		DP("\tpc 0x%p module %s %s\n",
			root->R.PC, root->R.M->m->name, root->R.M->m->path);
		sp = root->R.SP;
		ex = root->R.EX;
		while(ex != nil) {
			sx = (Stkext*)ex;
			fp = sx->reg.tos.fu;
			DP("Stkext stack extent 0x%p sp stack pointer 0x%p TR type register 0x%p \n"
				"\tEX previous stack extent 0x%p\n"
				"\tSP 0x%p TS top of stack 0x%p fp 0x%p\n",
				sx, sp, sx->reg.TR, sx->reg.EX,
				sx->reg.SP, sx->reg.TS, fp);
			while(fp != sp) {
				f = (Frame*)fp;
				t = f->t;
				if(t == nil){
					DP("t == nil\n");
					t = sx->reg.TR;
				}
				fp += t->size;
				showframe((void*)f, t);
			}
			ex = sx->reg.EX;
			sp = sx->reg.SP;
		}
		root = root->next;
	}*/
	while(root != nil) {
		ml = root->R.M;
		h = D2H(ml);
		Setmark(h);
		mp = ml->MP;
		if(mp != H) {
			h = D2H(mp);
			Setmark(h);
		}

		sp = root->R.SP;
		ex = root->R.EX;
		while(ex != nil) {
			sx = (Stkext*)ex;
			fp = sx->reg.tos.fu;
			while(fp != sp) {
				f = (Frame*)fp;
				t = f->t;
				if(t == nil){
					t = sx->reg.TR;
				}
				fp += t->size;
				t->mark(t, f);
				ml = f->mr;
				if(ml != nil) {
					h = D2H(ml);
					Setmark(h);
					mp = ml->MP;
					if(mp != H) {
						h = D2H(mp);
						Setmark(h);
					}
				}
			}
			ex = sx->reg.EX;
			sp = sx->reg.SP;
		}

		root = root->next;
	}

	for(m = modules; m != nil; m = m->link) {
		if(m->origmp != H) {
			h = D2H(m->origmp);
			Setmark(h);
		}
	}

	ptrmark();
}

static int
okbhdr(Bhdr *b)
{
	if(b == nil)
		return 0;
	switch(b->magic) {
	case MAGIC_A:
	case MAGIC_F:
	case MAGIC_E:
	case MAGIC_I:
		return 1;
	}
	return 0;
}

static void
domflag(Heap *h)
{
	int i;
	Module *m;

	print("sweep h=0x%zx t=0x%zx c=%d", (uintptr)h, (uintptr)h->t, h->color);
	for(m = modules; m != nil; m = m->link) {
		for(i = 0; i < m->ntype; i++) {
			if(m->type[i] == h->t) {
				print(" module %s desc %d", m->name, i);
				break;
			}
		}
	}
	print("\n");
	if(mflag > 1)
		abort();
}

void
rungc(Prog *p)
{
	Type *t;
	Heap *h;
	Bhdr *b;

	gcnruns++;
	if(gchalt) {
		gchalted++;
		return;
	}
	if(base == nil) {
		gcsweeps++;
		b = poolchain(heapmem);
		base = b;
		ptr = b;
		limit = B2LIMIT(b);
	}

	/* Chain broken ? */
	if(!okbhdr(ptr)) {
		base = nil;
		gcbroken++;
		return;
	}

	for(visit = quanta; visit > 0; ) {
		if(ptr->magic == MAGIC_A) {
			visit--;
			gct++;
			gcinspects++;
			h = B2D(ptr);
			t = h->t;
			if(h->color == propagator) {
				gce--;
				h->color = mutator;
				if(t != nil)
					t->mark(t, H2D(void*, h));
			}
			else
			if(h->color == sweeper) {
				gce++;
				if(0 && mflag)
					domflag(h);
				if(heapmonitor != nil)
					heapmonitor(2, h, 0);
				if(t != nil) {
					gclock();
					t->free(h, 1);
					gcunlock();
					freetype(t);
				}
				gcdestroys++;
				poolfree(heapmem, h);
			}
		}
		ptr = B2NB(ptr);
		if(ptr >= limit) {
			base = base->clink;
			if(base == nil)
				break;
			ptr = base;
			limit = B2LIMIT(base);
		}
	}

	quanta = (MaxQuanta+Quanta)/2 + ((MaxQuanta-Quanta)/20)*((100*gce)/gct);
	if(quanta < Quanta)
		quanta = Quanta;
	if(quanta > MaxQuanta)
		quanta = MaxQuanta;

	if(base != nil){		/* Completed this iteration ? */
		return;
	}
	if(nprop == 0) {	/* Completed the epoch ? */
		gcepochs++;
		gccolor++;
		rootset(p);
		gce = 0;
		gct = 1;
		return;
	}
	nprop = 0;
}
