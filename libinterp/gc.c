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
ulong	gcranheld;	/* collections that ran inside a gclock; see rungc() */

static int gce, gct = 1;

ulong	chainwalks, chainshort;	/* likewise; see rootset() */
ulong	shortstate[8];
ulong	shortringok, shortringshort, shortnoring, shortsynctold;


typedef struct Ptrhash Ptrhash;
struct Ptrhash
{
	Heap	*value;
	Ptrhash	*next;
};

	int	nprop;
	int	gchalt;
	ulong	rootnomod;	/* Progs skipped for having no module */
	ulong	rootraced;	/* INSTRUMENTATION - temporary: see rootset() */
	int	gcdepth;	/* this context's destroy recursion depth */
	int	gcdepthmax;	/* high-water mark of it, for #%/memgc */
	ulong	gcdeferred;	/* frees the depth guard handed to the collector */
	int	mflag;
	int	fpchain = 0;	/* see rootset(); off, measured not assumed */
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
	/*
	 * ref == 0 was part of "bad" here, and stopped being so when
	 * destroy() started handing objects to the collector rather than
	 * freeing them under it (see the gcstopped branch there).  A
	 * deferred object has reached zero and is still allocated, with
	 * its type header intact, which is exactly this shape.  Measured
	 * before it is asserted: "marklist: bad container ... ref 0"
	 * appears in no boot at parallelvm=0, in no boot at
	 * parallelvm=1 before the deferral landed, and in six after it.
	 *
	 * A negative count and a wrong type are still reported, and they
	 * are what this was for -- a stale cell whose memory has been
	 * reused reads as neither &Tlist nor a count the allocator would
	 * ever leave.
	 */
	if(h->t == &Tlist && h->ref >= 0)
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
	uchar *fp, *sp, *sp0, *ex, *ex0, *mp;

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
		 * progreg(), not &root->reg: for a program that is
		 * executing right now, the saved register file is a
		 * quantum out of date and the roots that matter are in the
		 * context's.  See the comment on progreg() in xec.c.
		 */
		rr = progreg(root);
		ml = rr->M;
		/*
		 * A Prog on this list need not have a module.
		 *
		 * destroystack() ends with "reg->M = H" and both its callers
		 * -- progexit()'s teardown and vmachine()'s error handler --
		 * run it before delprog() unlinks the Prog.  With one
		 * interpreter the VM lock meant no collection could be in
		 * progress across that window, and gclock() covered the rest
		 * by making rungc() decline to start.  gclock() only sets
		 * gchalt, which rungc() tests on entry; it does not stop a
		 * collection already running.  The teardown itself runs with
		 * a quantum open, so no collection walks during it (see
		 * entertear() in dis.c) -- but delprog() releases the
		 * interpreter before it unlinks the Prog, and a collection
		 * that runs then finds this one still on the list.
		 *
		 * So at parallelvm=1 this walk reaches a Prog whose register
		 * file has M == H, takes D2H of it -- H is (void*)-1 and Heap
		 * is 24 bytes, so that is exactly -25 -- and Setmark()
		 * dereferences it.  Eight captured faults across two kernels,
		 * every one of them CR2 ffffffffffffffe7 with CX holding the
		 * same, at this instruction.
		 *
		 * A Prog with no module has no module roots to mark, so
		 * skipping is not a lost root; it is the same guard that mp
		 * has had three lines below all along.  nil as well as H,
		 * because addprog()'s placeholder Prog is zeroed rather than
		 * filled with H.
		 */
		if(ml == H || ml == nil) {
			/*
			 * The positive control, and it is the point.  A run
			 * with no panics says nothing about whether this
			 * guard did anything unless something says the arm
			 * was taken -- "no faults" and "the case never
			 * arose" look identical from outside.  Same reason
			 * chanlock() prints its first contention.
			 */
			if(rootnomod++ == 0)
				print("rootset: first Prog with no module"
					" (M %s), skipped\n",
					ml == H ? "H" : "nil");
			root = root->next;
			continue;
		}
		h = D2H(ml);
		Setmark(h);
		mp = ml->MP;
		if(mp != H) {
			h = D2H(mp);
			Setmark(h);
		}

		sp = rr->SP;
		sp0 = sp;	/* INSTRUMENTATION: rr->SP as first read */
		ex = rr->EX;
		ex0 = ex;
		/*
		 * INSTRUMENTATION - temporary.  Does the frame chain reach
		 * the bottom of the newest extent?  The range walk below
		 * assumes it does -- that frames tile tos.fu..SP -- and the
		 * bad-frame captures say otherwise for the Progs that fail.
		 * Asking it of every Prog says whether that is the failure or
		 * the normal case.
		 */
		if(ex != nil){
			Stkext *cx;
			uchar *cf;
			int cn;

			cx = (Stkext*)ex;
			chainwalks++;
			for(cf = rr->FP, cn = 0;
			    cn < 4096 && cf >= cx->reg.tos.fu && cf < rr->SP; cn++){
				if(cf == cx->reg.tos.fu)
					break;
				cf = ((Frame*)cf)->fp;
				if(cf == nil)
					break;
			}
			if(cf != cx->reg.tos.fu){
				uchar *rf;
				int rn, rk, rwn;

				/*
				 * The same walk from where the Prog last
				 * actually executed, which its own instruction
				 * ring records.  Whole there and short here
				 * means the stack is intact and the register
				 * file stale, which is what this was; short
				 * both ways would mean the stack really is
				 * broken.  Kept: it is the check that would
				 * catch the fault coming back.
				 */
				chainshort++;
				if((uint)root->state < 8)
					shortstate[root->state]++;
				rwn = nelem(root->wmtrace);
				rk = (root->wmtracei - 1 + rwn) % rwn;
				rf = root->wmtrace[rk].fp2;
				if(root->wmtracen == 0 || rf == nil)
					shortnoring++;
				else{
					for(rn = 0; rn < 4096; rn++){
						if(rf == cx->reg.tos.fu)
							break;
						if(rf < cx->reg.tos.fu || rf >= rr->SP)
							break;
						rf = ((Frame*)rf)->fp;
						if(rf == nil)
							break;
					}
					if(rf == cx->reg.tos.fu || rf == nil)
						shortringok++;
					else
						shortringshort++;
				}
				if(chainshort < 4)
					print("rootset: pid %d chain from FP %#p"
						" stops at %#p, not tos.fu %#p;"
						" state %d regsrc %d, %d"
						" instructions since its last"
						" sync\n",
						root->pid, rr->FP, cf,
						cx->reg.tos.fu, root->state,
						root->regsrc,
						root->wmtracen - root->syncn);
			}
		}
		/*
		 * INSTRUMENTATION - temporary.  The positive control for
		 * rootraced below: widen the gap between reading EX and
		 * walking it, so that a teardown which is not excluded lands
		 * inside it.  A counter that has never been made to fire says
		 * nothing when it reads zero.  nil unless the kernel was
		 * booted with *gcwalkdelay set.
		 */
		if(ex != nil && gcwalkdelay != nil)
			gcwalkdelay();
		while(ex != nil) {
			sx = (Stkext*)ex;
			fp = sx->reg.tos.fu;
			/*
			 * fpchain: walk the frames the f->fp chain names
			 * rather than the address range tos.fu..sp.
			 *
			 * The chain is what the frames are; the range is
			 * where they are assumed to be, and a stale SP makes
			 * the assumption false -- measured, one live frame
			 * with a bound claiming eight frames' worth.  A chain
			 * cannot be made wrong by a bad bound, so this is
			 * correct whatever leaves SP stale.
			 *
			 * Off by default.  It changes what the root set is,
			 * which is not a thing to alter on a spot check: too
			 * few roots and the sweeper takes a live object, and
			 * that failure is silent.  It is here to be measured
			 * against the range walk, not to ship untested.
			 */
			if(fpchain){
				uchar *cf;
				int cn;

				for(cf = rr->FP, cn = 0;
				    cf >= sx->reg.tos.fu && cf < sp && cn < 4096;
				    cn++){
					f = (Frame*)cf;
					t = f->t;
					if(t == nil)
						t = sx->reg.TR;
					if(t == nil)
						break;
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
					cf = (uchar*)f->fp;
					if(cf == nil)
						break;
				}
				ex = sx->reg.EX;
				sp = sx->reg.SP;
				continue;
			}
			/*
			 * Ordering, not equality.  The frames are meant to tile
			 * tos.fu..sp exactly and fp advances by t->size, so one
			 * wrong size steps past sp, "!=" never holds, and the walk
			 * runs on through whatever follows -- reading each block as
			 * a Frame and Setmark()ing whatever it takes for a root.
			 * That is how one bad frame became a jump into the Dis heap
			 * through t->mark: the frame reported was the first garbage
			 * reached, several frames past the wrong one.
			 *
			 * Measured before changing it: a 1632-byte span walked to
			 * 0xf380d60, eight frames in, in 2 boots of 60 at
			 * *parallelvm=1 and none at parallelvm=0.
			 *
			 * This does not make the root set right -- the frames after
			 * the bad one go unwalked and their roots unmarked, which is
			 * its own hazard and is reported below.  It stops the walk
			 * marking arbitrary memory, which is the worse of the two.
			 */
			while(fp < sp) {
				f = (Frame*)fp;
				t = f->t;
				if(t == nil){
					t = sx->reg.TR;
				}
				{	/* INSTRUMENTATION - temporary */
					extern uchar etext[];
					static int badtold;

					/*
					 * The two failures in ninety-six boots
					 * are a jump into the Dis heap reached
					 * from here: this is rootset+0x112, and
					 * t->mark is the indirect call.
					 *
					 * What is not yet known is whether t is
					 * a freed Type or whether the frame
					 * itself is corrupt and t was never a
					 * Type at all.  freetype() was asked
					 * and answered no -- it frees nothing
					 * under a collection in twenty boots --
					 * so this asks the frame instead, and
					 * prints what it found rather than
					 * jumping through it.
					 */
					/*
					 * t->mark is a function pointer and
					 * function pointers are not aligned:
					 * markheap sits at 0x2f4139 in this
					 * build.  An alignment check on it
					 * rejected every correct Type and
					 * reported 41 faults that were the
					 * check's own.  What can be said about
					 * a code pointer is that it is inside
					 * the text segment, so that is what is
					 * asked.
					 */
					if(((uintptr)t & 7) != 0
					|| (uintptr)t < 0x100000
					|| (uintptr)t->mark < 0x200000
					|| (uintptr)t->mark >= (uintptr)etext){
						if(badtold++ == 0){
							uchar *q;
							Type *qt;
							Frame *qf;
							int qn;

							print("rootset: bad frame"
								" type t %#p mark %#p"
								" size %d f %#p"
								" f->t %#p TR %#p"
								" pid %d\n",
								t, t->mark,
								t->size, f, f->t,
								sx->reg.TR,
								root->pid);
							/*
							 * The same stack read two
							 * ways.  The walk tiles up
							 * from tos.fu; the chain is
							 * what the frames say they
							 * are.  Where they part is
							 * the question, and one
							 * list beside the other is
							 * the only way to see it.
							 */
							print("rootset: EX %#p TS %#p"
								" FP %#p SP %#p walk sp %#p;"
								" this extent %#p..%#p,"
								" prior EX %#p, TR %#p\n",
								rr->EX, rr->TS, rr->FP,
								rr->SP, sp, (uchar*)sx,
								sx->reg.TS, sx->reg.EX,
								sx->reg.TR);
							print("rootset: tiled from %#p:",
								sx->reg.tos.fu);
							for(q = sx->reg.tos.fu, qn = 0;
							    q < sp && qn < 12; qn++){
								qt = ((Frame*)q)->t;
								if(qt == nil)
									qt = sx->reg.TR;
								if(qt == nil
								|| ((uintptr)qt & 7) != 0
								|| (uintptr)qt < 0x100000
								|| qt->size <= 0){
									print(" %#p t %#p BAD",
										q, qt);
									break;
								}
								print(" %#p t %#p sz %d",
									q, qt, qt->size);
								q += qt->size;
							}
							print("\n");
							print("rootset: chain from %#p:",
								rr->FP);
							for(q = rr->FP, qn = 0;
							    qn < 12 && q >= sx->reg.tos.fu
							    && q < sp; qn++){
								qf = (Frame*)q;
								qt = qf->t;
								print(" %#p t %#p sz %d",
									q, qt,
									(qt != nil
									 && ((uintptr)qt & 7) == 0
									 && (uintptr)qt >= 0x100000)
									  ? qt->size : -1);
								q = qf->fp;
								if(q == nil)
									break;
							}
							print("\n");
						}
						/*
						 * Report and stop walking this
						 * extent rather than abort.
						 * Aborting here pre-empted the
						 * tile report below on the same
						 * boot -- the two could never
						 * both be seen, which is why
						 * "do not tile" read 0 of 40
						 * while a bad frame read 1.
						 */
						break;
					}
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
			if(fp != sp){
				static int told;

				/*
				 * The frames did not tile the extent, so this
				 * stack's root set is short by whatever was
				 * skipped and an object only it refers to can be
				 * swept.  Said once.
				 */
				if(told++ == 0){
					uchar *q;
					Type *qt;
					int n;

					/*
					 * Which frame overstepped, and where
					 * its type came from.  f->t is set by
					 * OP(frame) and counted by framerefs;
					 * a type reached through sx->reg.TR
					 * is never counted, so if the
					 * oversized frame is a TR one then
					 * reference counting was never going
					 * to protect it -- which would
					 * explain why completing framerefs
					 * changed nothing.
					 */
					for(q = sx->reg.tos.fu, n = 0;
					    q < sp && n < 4096; n++){
						qt = ((Frame*)q)->t;
						if(qt == nil)
							qt = sx->reg.TR;
						if(qt == nil
						|| ((uintptr)qt & 7) != 0
						|| (uintptr)qt < 0x100000
						|| qt->size <= 0){
							/*
							 * A zero size does not
							 * overstep, it fails to
							 * step at all -- fp +=
							 * 0 never advances, so
							 * neither the old loop
							 * nor the bounded one
							 * terminates.  The
							 * first version of this
							 * pre-walk had the same
							 * bug and reported
							 * nothing.
							 */
							print("rootset: frame %d"
								" of %#p..%#p at %#p"
								" has type %#p"
								" size %d from %s,"
								" pid %d\n",
								n,
								sx->reg.tos.fu, sp,
								q, qt,
								qt ? qt->size : -1,
								((Frame*)q)->t
								  ? "f->t"
								  : "reg.TR",
								root->pid);
							break;
						}
						if(q + qt->size > sp){
							print("rootset: frame %d"
								" of %#p..%#p"
								" at %#p steps"
								" %d to %#p;"
								" type %#p from"
								" %s, pid %d\n",
								n,
								sx->reg.tos.fu,
								sp, q, qt->size,
								q + qt->size,
								qt,
								((Frame*)q)->t
								  ? "f->t"
								  : "reg.TR",
								root->pid);
							break;
						}
						q += qt->size;
					}
					{
						int ci;

						/*
						 * Where did the bound come
						 * from?  sp is rr->SP, and rr
						 * is progreg(root), which
						 * hands back a context's
						 * register file when that
						 * context's curprog names this
						 * Prog.  curprog is allowed to
						 * dangle -- vmachine() says so
						 * where it clears it -- so a
						 * stale one gives this walk
						 * another program's SP, and a
						 * bound past the live frames
						 * makes the frames after them
						 * leftover stack rather than
						 * frames.  Frames 0..6 tiling
						 * and 7 holding a Dis heap
						 * pointer is that shape.
						 */
						for(ci = 0; ci < npctx; ci++)
							if(rr == &pctxs[ci]->reg)
								break;
						/*
						 * Did progreg() miss a context
						 * that is running this Prog?
						 * It scans i < npctx, and
						 * claimctx() publishes with
						 * "pctxs[npctx++] = c" -- the
						 * store and the increment are
						 * not ordered and progreg reads
						 * npctx without the lock.  A
						 * missed context means the
						 * stale entry snapshot is used
						 * as the bound, which is a
						 * stack that has moved on.
						 *
						 * Scanning the whole array, not
						 * npctx, is the point.
						 */
						{
							int cj;

							for(cj = 0; cj < MAXPCTX; cj++)
								if(pctxs[cj] != nil
								&& pctxs[cj]->curprog == root){
									print("rootset:"
										" ctx %d IS"
										" running pid"
										" %d (npctx %d,"
										" inxec %d)\n",
										cj, root->pid,
										npctx,
										pctxs[cj]->inxec);
									break;
								}
						}
						{
							uchar *cf;
							int cn;

							/*
							 * The f->fp chain is
							 * authoritative about
							 * which frames are live;
							 * the walk above only
							 * assumes they tile
							 * tos.fu..sp.  If the
							 * chain stops short of
							 * sp then sp is too high
							 * and the frames past
							 * the chain are not
							 * frames -- which is a
							 * bound that is wrong,
							 * not memory that is.
							 */
							/*
							 * SP - FP is 0x660 and
							 * the chain holds one
							 * frame, so that frame
							 * is 0x660 -- and the
							 * walk stepped seven
							 * times inside it, so it
							 * read a size far
							 * smaller than the frame
							 * is.  Print the first
							 * frame's type and size
							 * against the span it
							 * has to cover.
							 */
							{
								Frame *f0 = (Frame*)rr->FP;
								Type *t0 = f0->t;

								if(t0 == nil)
									t0 = sx->reg.TR;
								Frame *fs;

								print("rootset: FP %#p"
									" SP %#p span %ld;"
									" frame0 t %#p"
									" (%s) size %d\n",
									rr->FP, sp,
									(long)(sp - rr->FP),
									t0,
									f0->t ? "f->t"
									      : "reg.TR",
									t0 ? t0->size : -1);
								/*
								 * Two candidates, both
								 * checkable here.
								 *
								 * propex()'s loop leaves
								 * SP at the last frame it
								 * popped and FP at that
								 * frame's caller, so the
								 * frame sitting at SP
								 * should have fp == FP
								 * and FP + caller size
								 * should equal SP.  If
								 * the frame at SP points
								 * elsewhere, the chain
								 * disagrees with the
								 * bound; if it points at
								 * FP, then reg.TR's 152
								 * is not the size of the
								 * frame at the bottom of
								 * this extent.
								 */
								/*
								 * Is the pair moving
								 * under the read?
								 *
								 * rootset takes rr->SP
								 * and rr->FP as
								 * separate reads, and
								 * propex() writes
								 * p->reg with a memmove
								 * that is not atomic --
								 * from inside
								 * vmachine()'s waserror
								 * handler, which clears
								 * inxec first, so
								 * stoptheworld() does
								 * not stop it.  A torn
								 * pair would read
								 * consistent at the
								 * source and
								 * inconsistent here.
								 *
								 * Re-read both.  Changed
								 * means a live writer;
								 * unchanged means the
								 * snapshot really does
								 * hold a mismatched
								 * pair.
								 */
								/*
								 * sp is a loop variable
								 * -- reassigned to
								 * sx->reg.SP for each
								 * extent after the first
								 * -- so comparing it
								 * against a fresh
								 * rr->SP compares two
								 * different fields and
								 * says nothing about
								 * tearing.  sp0 is
								 * rr->SP as first read;
								 * this compares that
								 * with rr->SP now.
								 */
								print("rootset: rr->SP"
									" first %#p now %#p"
									" %s; walk sp %#p"
									" FP %#p\n",
									sp0, rr->SP,
									sp0 == rr->SP
									  ? "UNCHANGED"
									  : "CHANGED",
									sp, rr->FP);
								fs = (Frame*)sp;
								print("rootset: frame at"
									" SP: fp %#p t %#p"
									" (FP is %#p); TR %#p"
									" tos.fu %#p\n",
									fs->fp, fs->t, rr->FP,
									sx->reg.TR,
									sx->reg.tos.fu);
							}
							print("rootset: fp chain"
								" from %#p:", rr->FP);
							cf = rr->FP;
							for(cn = 0; cn < 16
							    && cf >= sx->reg.tos.fu
							    && cf < sp; cn++){
								print(" %#p", cf);
								cf = ((Frame*)cf)->fp;
								if(cf == nil)
									break;
							}
							print(" (%d shown)\n", cn);
						}
						{
							Bhdr *xb;

							/*
							 * Is the extent itself
							 * still allocated?
							 *
							 * unextend() and
							 * unframe() free(sx) a
							 * stack extent back to
							 * mainmem during
							 * ordinary OP(ret), not
							 * under gclock, and only
							 * xec()'s exit, isave()
							 * and propex() sync
							 * p->reg -- so a
							 * snapshot can name an
							 * extent the program has
							 * since freed and the
							 * allocator has reused.
							 * That is what memory
							 * changing between two
							 * reads looks like.
							 *
							 * MAGIC_A allocated,
							 * MAGIC_F free; anything
							 * else is not a block
							 * header at all.
							 */
							xb = (Bhdr*)((uchar*)sx -
								(BHDRSIZE - sizeof(Btail)));
							print("rootset: extent %#p"
								" hdr magic %#lux"
								" (A %#ux F %#ux)\n",
								sx, (ulong)xb->magic,
								MAGIC_A, MAGIC_F);
						}
						print("rootset: frames do not"
							" tile %#p..%#p,"
							" stopped %#p, pid %d,"
							" state %d, gchalt %d,"
							" regs from"
							" %s%d (1 xec 2 isave"
							" 3 propex 4 dbg)\n",
							sx->reg.tos.fu, sp, fp,
							root->pid, root->state,
							gchalt,
							rr == &root->reg
							  ? "p->reg" : "ctx ",
							rr == &root->reg
							  ? root->regsrc : ci);
					}
				}
			}
			ex = sx->reg.EX;
			sp = sx->reg.SP;
		}
		/*
		 * INSTRUMENTATION - temporary.  The walk above read EX and
		 * then walked extents; if EX is nil now, destroystack() ran
		 * during the walk and freed what was being walked.  Nothing
		 * else writes EX while the world is stopped.
		 *
		 * EX alone was blind to one of the two sites: progexit()
		 * tears down R, the context's register file, after
		 * vmachine()'s handler has cleared curprog, so progreg()
		 * hands this walk root->reg, whose EX nobody nils.  So a
		 * Prog marked torn counts too.  The mark is on the Prog and
		 * never cleared, not on the context: a teardown takes
		 * microseconds and was over, its context's mark gone, long
		 * before a walk held by *gcwalkdelay reached this line.  The
		 * Prog cannot be freed under the walk, because delprog()
		 * reacquires, and so waits for the collection, first.
		 * The kernel's entertear() counts the upper bound.
		 */
		if(ex0 != nil && (rr->EX == nil || root->torn))
			if(rootraced++ == 0)
				print("rootset: extents freed during the walk,"
					" pid %d\n", root->pid);

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

	/*
	 * The invariant Phase 1b of doc/dis-parallel-plan.ms depends on.
	 * The collector takes Prog->reg as its root set, and while a
	 * quantum runs p->reg is the entry snapshot -- the live values are
	 * in R.  A root the mark phase cannot see is an object the sweeper
	 * takes, and a missing root is not a data race, so no sanitizer
	 * will find it.
	 *
	 * inxec (xec.c) is set for exactly that window and cleared both at
	 * the end of the quantum and in vmachine()'s waserror() loop,
	 * where every non-local exit from the interpreter lands.
	 *
	 * Two earlier versions of this check tested curP->curprog instead,
	 * first for nil and then by comparing its saved registers against
	 * the live ones.  Both were unsound, and the second proved it: it
	 * reported prog 5 with state 0xdeadbeef, which is what delprog()
	 * writes into a Prog it is about to free.  curprog is allowed to
	 * dangle -- vmachine() says so where it clears it, "progreg() only
	 * compares the pointer, never follows it" -- so a check that
	 * follows it reads freed memory.  A flag cannot dangle.
	 */
	if(curP->inxec && curP->syncpc != R.PC) {
		static int said;

		if(!said) {
			said = 1;
			print("rungc: collecting inside a quantum with p->reg "
				"stale (snapshot PC %#p live %#p), called from "
				"%#p -- the live roots are not in the root set\n",
				curP->syncpc, R.PC, getcallerpc(&p));
		}
	}

	gcnruns++;
	if(gchalt) {
		gchalted++;
		return;
	}
	{
		/*
		 * The direction of the gchalt bug that nothing counted.  A
		 * lost decrement switches the collector off, which every
		 * table in doc/multicore-plan.ms measures.  A lost increment
		 * lets this run while a context is inside a gclock() region
		 * -- a teardown, or a t->free() partway through destroy() --
		 * and it leaves no missing collection and no counter behind.
		 * Past the test above, gchalt says nobody has asked the
		 * collector to stay out; if a context still holds one, the
		 * global lost an increment and this collection is the
		 * exposure.
		 *
		 * Not a race in the reading: the sites that hold a gclock()
		 * with a quantum open are the two teardowns, and
		 * stoptheworld() waits for those, so they cannot be what this
		 * sees.
		 */
		int i, held;

		held = 0;
		for(i = 0; i < npctx; i++)
			held += pctxs[i]->gcheld;
		if(held > 0)
			if(gcranheld++ == 0)
				print("rungc: collecting with %d gclock(s)"
					" held and gchalt %d\n", held, gchalt);
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
