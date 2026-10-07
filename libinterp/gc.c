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
	int	gcdepth;	/* interp.h: destroy() recursion, not heap suppression */
	int	gcdepthmax;
	int	gcstwcheck = 1;	/* check no quantum is open when collecting */
	ulong	gcinxecseen;	/* times one was, which should be never */
	int	mflag;
	int	mutator = 0;
	int	gccolor = 3;

	ulong	gcnruns;
	ulong	gcsweeps;
	ulong	gcbroken;
	ulong	gcbadptr;	/* words rejected before Setmark wrote through them */
	/*
	 * THE READER ON THE PATH THAT CREATES A CHAIN, which is what H4 in
	 * doc/open-issues-plan.ms said this item needed and did not have.  The
	 * guard in markheap() counts words it REFUSED and has always read zero,
	 * so whatever breaks the sweep's chain is not an implausible word.
	 *
	 * These three are written by poolfree() in os/inferno/port/alloc.c (and
	 * emu/port/alloc.c), not here, because the event is a COALESCE and only
	 * the allocator sees one.  `ptr' below is the incremental sweep's cursor
	 * and it is deliberately global for exactly this reason: poolfree() may
	 * merge away the block it points at, in which case the merge zeroes that
	 * block's magic and the cursor is left pointing into the interior of a
	 * free block.  Upstream Inferno's poolfree() fixes the cursor up when it
	 * does that; THIS KERNEL'S COPY HAD THE FIXUP COMMENTED OUT (emu's never
	 * did), which these counters confirmed and which is now back on.  They
	 * stay because they are the regression detector for it.
	 *
	 *	gcptrfwd	a forward join swallowed the block at ptr
	 *	gcptrback	a backward join swallowed the block at ptr
	 *	gcptrfwdgc	... of those, ones GCSWEEP ITSELF caused
	 *	gcptrbackgc
	 *
	 * THE SPLIT IS THE WHOLE MEASUREMENT, and the first version of this file
	 * did not have it.  The sweep loop below frees the block AT the cursor
	 * (h = B2D(ptr); poolfree(heapmem, h)) and then advances with
	 * ptr = B2NB(ptr) on the next line -- so a backward join there zeroes
	 * ptr->magic, leaves ptr->size alone, and the advance is still correct.
	 * The collector swallowing its own cursor is repaired by construction and
	 * means nothing.  Only a swallow by the MUTATOR, between quanta, leaves a
	 * cursor that is still there when the sweep resumes.
	 *
	 * Without the split the first reading was 252 backward swallows on a
	 * boot with ZERO broken chains, which reads as a mechanism firing
	 * constantly and being harmless -- when in fact it was the sweeper's own
	 * frees, counted by an instrument that could not tell them from the
	 * event it was built to find.  It also explains the forward count being
	 * exactly 0: inside the loop b IS ptr, so c never is.
	 *
	 * Then the three resume classifications, which count RESUMES and not
	 * swallows (gcptrstale is one flag, so several swallows between two
	 * quanta collapse into one):
	 *
	 *	gcstaleok	resumed on a swallowed cursor, okbhdr PASSED
	 *	gcstalebrk	resumed on a swallowed cursor, okbhdr FAILED
	 *	gcstaleidle	swallowed while NO sweep was in progress
	 *
	 * gcstaleok is the only dangerous tier and the only number worth being
	 * surprised by: the interior word happened to look like a header and the
	 * sweep walked from a position nothing vouched for, which would make the
	 * two candidates H4 could not separate ONE mechanism rather than two.
	 * Measured, with the fixup off, at 3 and 2 over two runs, and the tail
	 * test said all of them were a real header put back at that address.
	 * gcstalebrk is the benign one -- a wasted re-sweep -- and it matched
	 * gcbroken exactly, 17 and 12, which is what settled the item.
	 * gcstaleidle is neither: ptr was a leftover from a finished sweep and
	 * the next rungc() replaces it from poolchain() before reading it.
	 *
	 * With the fixup on, all three are 0 by construction and gcptrfixed
	 * below is where those events land instead.
	 *
	 * gcstaleidle exists because the first version did not have it and
	 * reported 55 dangerous hits that were all this: the check sat AFTER the
	 * if(base == nil) restart, so it tested a cursor the restart had just
	 * replaced and called the fresh value's validity a survival.
	 */
	ulong	gcptrfwd;
	ulong	gcptrback;
	ulong	gcptrfwdgc;
	ulong	gcptrbackgc;
	ulong	gcstaleok;
	ulong	gcstalebrk;
	ulong	gcstaleidle;
	/*
	 * And once the fixup is ON, the swallows the mutator caused that
	 * poolfree() REPAIRED, which is where the three classifications above
	 * used to come from.  It replaces gcptrstale rather than adding to it:
	 * with the cursor repaired there is nothing stale to classify, and
	 * leaving the flag set would have made the repaired cursor pass
	 * okbhdr() at the next resume and be counted as the DANGEROUS tier --
	 * a fix whose own instrument reports it as the bug.
	 *
	 * So after the fix the expectation is exact: gcbroken 0, all three
	 * gcstale* 0, gcptrfixed roughly what the mutator counts were before,
	 * and the collector's own swallows unchanged.  Any nonzero gcstale* now
	 * is a real finding.
	 */
	ulong	gcptrfixed;
	int	gcptrstale;	/* set by poolfree, cleared by rungc */
	int	gcinsweep;	/* the sweep loop's own poolfree is running */
	/*
	 * And the breaks themselves, bounded: the first NBROKE, each with the
	 * cursor, the word that failed okbhdr() and the size beside it.  The
	 * prediction being tested is specific -- a coalesced-away header reads
	 * magic 0 with its size field untouched -- and a count cannot test it.
	 * Bounded because an unbounded kernel print on this path denies service
	 * to the ring that is the only post-mortem channel this board has.
	 */
	uintptr	gcbrokeptr[8];
	u32	gcbrokemagic[8];
	uintptr	gcbrokesize[8];
	int	gcnbroke;
	/*
	 * And the same for the resumes that DID pass okbhdr(), which is the one
	 * tier that can still be either thing.  A swallowed header reads magic 0
	 * at the moment of the merge, so a swallowed cursor that later passes
	 * okbhdr() is a cursor whose ADDRESS has since been reused -- and that
	 * splits two ways the counter cannot:
	 *
	 *   poolalloc() split the merged free block and put a REAL header back
	 *   at that address, in which case the sweep resumes on a real block
	 *   and nothing is wrong; or
	 *
	 *   the address is now inside a block and the word there merely reads
	 *   like a magic.  okbhdr() runs ONCE, at entry; the loop below then
	 *   compares ptr->magic == MAGIC_A bare and advances by whatever size
	 *   is sitting there, until it passes limit.  That is H4's "plausible
	 *   bad word" candidate with a mechanism attached.
	 *
	 * B2T(ptr)->hdr == ptr tells them apart in one compare: the allocator
	 * writes that back-pointer on every block it makes, so a real block
	 * agrees with its own tail and an interior word almost never will.
	 * Recorded rather than counted, three events being worth three rows.
	 */
	uintptr	gcstaleptr[8];
	u32	gcstalemagic[8];
	uintptr	gcstalesize[8];
	int	gcstaletail[8];		/* 1 agrees, 0 does not, -1 unchecked */
	int	gcnstale;
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
	 * Board bring-up instrumentation, so it answers to the same
	 * switch heap.c's tracker does.  This probe and checklistcell()
	 * below both end in abort(), and both fire on a hosted emu
	 * within a second of starting a shell -- checklistcell() on a
	 * list cell whose type is right and whose ref is 0, which is a
	 * state the host reaches and pc64 apparently does not.  Left
	 * ungated they make emu unusable, which matters because running
	 * the same .dis under emu on the build host is how every dossrv
	 * bug in this port was found.  distrack is 1 everywhere except
	 * raspi3b and emu, so no board loses anything.
	 */
	if(!distrack)
		return;

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
	/*
	 * Was made non-fatal on this (stable) kind too for one round, to
	 * test whether it might be a benign mid-execution snapshot (a
	 * marked frame slot legitimately holding a non-pointer value
	 * while its lexical scope is live -- see doc/inferno-ports.ms,
	 * "A live, correctly-typed object, one field wrong" for the full
	 * argument for why that reading was even plausible here, unlike
	 * the retracted map-imprecision one).  The answer came back
	 * negative and decisive: with this non-fatal, boots that would
	 * previously have stopped cleanly here instead ran on and hit
	 * REAL native panics later -- page fault, general protection
	 * violation, invalid opcode, the pool allocator's own alloc:D2B
	 * consistency check, cclose on a nil c -- at a high rate (7 of 10
	 * in one batch).  That rules out "benign, resolves on its own"
	 * for this kind outright: whatever ml->MP (or the equivalent
	 * field on another capture) held instead of H got used later as
	 * if it were valid, and the boot paid for it downstream, just
	 * less legibly than stopping cleanly right here would have.
	 * Reverted to abort(), with the diagnostics (D2H(vw), the tight
	 * reread, the sanity print) all kept -- they're what got this
	 * far.  pc64-only, temporary.  See doc/inferno-ports.ms.
	 */
	{
		Heap *dh = D2H(vw);
		print("markheap: D2H(vw) %#p t %#p ref %d color %d\n",
			dh, dh->t, dh->ref, dh->color);
	}
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
	uintptr wv;
	WORD **w, **q;
	Type *t1;

	/*
	 * A 20-boot batch resolved 5/8 GPFs to markheap+26 -- this
	 * function's own t->np read, the very first dereference of t,
	 * right after the pre-existing "t == nil" half of the check
	 * below (which a wild-but-nonnil t sails past).  Every legal
	 * caller (marklist's l->t, markarray's a->t, the recursive
	 * h->t dispatch below) reaches here with t either a valid
	 * builtin Type's static address or a live heap Type*; neither
	 * shape is ever near-zero or misaligned, so a t that is either
	 * is already known-bad without needing to touch it further.
	 * auditmemloc() (alloc.c) -- report live/free/not-in-pools --
	 * on a confirmed-bad t, the same escalation chan.c's badref()
	 * uses for a bad Ref*.  pc64-only, temporary.  See
	 * doc/inferno-ports.ms.
	 */
	if(t != nil && ((uintptr)t < 0x1000 || ((uintptr)t & (sizeof(uintptr)-1)) != 0)){
		extern void dumpstack(void);
		extern void (*auditmemloc)(char*, void*);

		print("markheap: bad t %#p vw %#p\n", t, vw);
		auditmemloc("markheap-t", t);
		dumpstack();
		abort();
	}

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
					/*
					 * REJECT AN IMPLAUSIBLE WORD BEFORE
					 * WRITING THROUGH IT.
					 *
					 * Setmark(h) writes h->color.  With a
					 * garbage word here, h is garbage and
					 * that write lands in a live, unrelated
					 * object -- an ordinary store, so there
					 * is no fault at the write site to point
					 * at what happened.  The comment above
					 * this function describes the mechanism
					 * and the shape of the population it has
					 * seen: 0, 0x18, 0x80.
					 *
					 * The only guard until now was
					 * checkmarkptr(), which returns at once
					 * unless distrack is set -- and distrack
					 * is 0 on raspi3b, where it costs 7.5x
					 * (main.c says so).  So on that board
					 * nothing checked, and gcbroken counted
					 * 38 to 56 damaged chains per boot.
					 *
					 * This is the same test markheap's own
					 * entry already applies to t, for the
					 * same reason it gives: a real pointer
					 * is never near-zero and never
					 * misaligned, so a word that is either
					 * is known-bad without touching it.  Two
					 * compares, always on, against a write
					 * that corrupts the heap.
					 *
					 * Skipping is the right response: there
					 * is no object at a misaligned or
					 * near-zero address to mark, so nothing
					 * live is being dropped.  Counted rather
					 * than silent, because the count is the
					 * evidence for whether this is the
					 * mechanism.
					 */
					wv = (uintptr)*(WORD*volatile*)q;
					if(wv < 0x1000 ||
					   (wv & (sizeof(uintptr)-1)) != 0){
						gcbadptr++;
						q++;
						continue;
					}
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

	if(!distrack)		/* see checkmarkptr() above */
		return;
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
	REG *rr;
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
			root->reg.PC, root->reg.M->m->name, root->reg.M->m->path);
		sp = root->reg.SP;
		ex = root->reg.EX;
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
		/*
		 * progreg(), not &root->reg: for a program executing right
		 * now the saved register file is up to a quantum out of date,
		 * and the roots that matter are in the context's.  See the
		 * comment on progreg() in xec.c -- with one context this is
		 * the same pointer the old code took.
		 */
		rr = progreg(root);
		ml = rr->M;
		h = D2H(ml);
		Setmark(h);
		mp = ml->MP;
		if(mp != H) {
			h = D2H(mp);
			Setmark(h);
		}

		sp = rr->SP;
		ex = rr->EX;
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
	/*
	 * The invariant the whole root walk rests on: no context may have a
	 * quantum open while this runs.  rootset() reads a program's live
	 * registers through progreg(), and inxec is exactly "this context's
	 * register file is live" -- so a collection taken with a quantum
	 * open is one walking registers that the mutator is still writing,
	 * and the objects it misses are freed rather than marked.
	 *
	 * It holds today by construction: the collector is only ever reached
	 * between xec() calls, from vmachine()'s BusyGC block or from
	 * execatidle().  Checking it anyway is cheap, and it is the tripwire
	 * for the step that adds a second context -- where the bound is
	 * stoptheworld() waiting on this same flag rather than construction.
	 * The multicore branch kept the same assertion and it earned itself
	 * once, on the first boot where a second context existed.
	 */
	if(gcstwcheck){
		int i;

		for(i = 0; i < npctx; i++)
			if(pctxs[i]->inxec){
				if(gcinxecseen++ < 8)
					print("rungc: context %d has a quantum"
						" open (prog %#p); roots may be"
						" stale\n", i,
						pctxs[i]->curprog);
				break;
			}
	}
	/*
	 * READ THE SWALLOW FLAG BEFORE THE RESTART BELOW CAN REPLACE ptr.
	 * Putting this after the if(base == nil) block was the first version's
	 * bug: the restart assigns a fresh cursor from poolchain(), so the check
	 * tested a value that had just been replaced and counted its validity
	 * as the swallowed cursor surviving.  base is also the only thing that
	 * distinguishes a cursor in use from a leftover, and poolfree() cannot
	 * see it, so the classification has to happen here.
	 */
	if(gcptrstale){
		gcptrstale = 0;
		if(base == nil)
			gcstaleidle++;
		else if(okbhdr(ptr)){
			gcstaleok++;
			if(gcnstale < nelem(gcstaleptr)){
				int i = gcnstale++;

				gcstaleptr[i] = (uintptr)ptr;
				gcstalemagic[i] = ptr->magic;
				gcstalesize[i] = ptr->size;
				/*
				 * The bound comes first and is not optional: a
				 * cursor pointing into a block's payload has
				 * whatever size is sitting there, and B2T()
				 * indexes by it.  base and limit are the ARENA
				 * and a coalesce cannot move them, so they are
				 * the one thing still trustworthy here.
				 * MAGIC_E is skipped because an end-of-arena
				 * marker is not a block and need not have a
				 * tail to agree with.
				 */
				if(ptr->magic == MAGIC_E)
					gcstaletail[i] = -1;
				else if(ptr->size < (intptr)BHDRSIZE
				|| (uchar*)ptr + ptr->size > (uchar*)limit)
					gcstaletail[i] = -1;
				else
					gcstaletail[i] =
						B2T(ptr)->hdr == ptr;
			}
		}
		else
			gcstalebrk++;
	}
	if(base == nil) {
		gcsweeps++;
		b = poolchain(heapmem);
		base = b;
		ptr = b;
		limit = B2LIMIT(b);
	}

	if(!okbhdr(ptr)) {
		if(gcnbroke < nelem(gcbrokeptr)){
			gcbrokeptr[gcnbroke] = (uintptr)ptr;
			gcbrokemagic[gcnbroke] = ptr == nil? 0: ptr->magic;
			gcbrokesize[gcnbroke] = ptr == nil? 0: ptr->size;
			gcnbroke++;
		}
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
				/*
				 * gcinsweep spans the WHOLE destruction, not
				 * just the poolfree below: h is the block AT
				 * ptr, so that free's backward join swallows
				 * the cursor every time the block before it is
				 * free, and t->free() reaches poolfree() too
				 * through destroy().  Harmless either way --
				 * ptr->size is untouched and the advance below
				 * is correct -- but indistinguishable from the
				 * MUTATOR doing it unless poolfree() is told
				 * who is calling, and the mutator's is the only
				 * one that can outlive the quantum.
				 *
				 * One flag and not a per-context one, and the
				 * condition for that is stronger than it first
				 * looks: npctx is a hard-coded 1 in xec.c and
				 * there is no parallelvm switch in this tree to
				 * turn it up (see comp-aarch64.c's note on the
				 * same absence, and doc/parallel-allocator-
				 * survey.ms).  So the split cannot be wrong
				 * HERE under any configuration -- it is not a
				 * claim about the boots it was measured on.
				 *
				 * THE HAZARD IS THE MERGE, not a runtime
				 * setting.  On a tree where a second context
				 * can free concurrently, that free is
				 * attributed to the collector and the
				 * mutator-versus-collector split silently
				 * becomes meaningless -- which is exactly the
				 * number the whole H4 finding rests on.  A
				 * per-context flag is the fix and it is one
				 * line; it is not written here because an
				 * untestable fix for an absent configuration
				 * is how this tree accumulates comments that
				 * claim interlocks it does not have.
				 */
				gcinsweep = 1;
				if(t != nil) {
					gclock();
					t->free(h, 1);
					gcunlock();
					freetype(t);
				}
				gcdestroys++;
				poolfree(heapmem, h);
				gcinsweep = 0;
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
