#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include <isa.h>
#include <interp.h>
#include <kernel.h>
#include "raise.h"

static int debug = 0;

void	vmachine(void*);

struct
{
	Lock	l;
	Prog*	head;
	Prog*	tail;
	Rendez	irend;
	int	nidle;		/* interpreters parked on idlevmq */
	int	nyield;
	int	creating;
	Proc*	idlevmq;	/* interpreters with no program to run */
	Atidle*	idletasks;
	Prog*	ghead;		/* global run queue; see gput() */
	Prog*	gtail;
	int	ngq;
} isched;

/*
 * The global run queue, on Go's shape.
 *
 * A per-P local run queue cannot simply replace the shared one: a Prog
 * that one context queues would be invisible to another, and if that
 * context then blocks, the program never runs.  Go does not split it
 * either -- runqput overflows a bounded local queue into a global one
 * and runqget falls back to the global queue before stealing.  The
 * global queue is not a remnant there; it is what makes the local ones
 * correct.
 *
 * So it is built first, while there is still one P, because it is the
 * only piece of that design that can be exercised before the last one
 * lands.  Runqmax is the local bound.  At its default nothing overflows
 * -- the deepest local queue this workload produces is 2, measured --
 * so this path is inert unless the bound is lowered, and it is lowered
 * on purpose to test it.  That is the point of having it: a mechanism
 * whose default is "never runs" is untested, and the bound is the
 * constant to falsify.
 */
int Runqmax = 256;	/* MULTICORE - local run queue bound, Go's is 256 */
/*
 * A context per interpreter -- Go's P, one held by each M that runs.
 *
 * There is still exactly one vmlock, so only one interpreter executes
 * at a time and only one of these is live at a time.  That is what
 * makes this safe to land before the collector: a second P exists, is
 * claimed, and is used, but never concurrently with the first.
 *
 * The local run queue has to be flushed back to the global queue when
 * an interpreter gives up the lock.  A Prog left on the local queue of
 * an M that does not run again is stranded -- invisible to every other
 * M, exactly the hazard that made the global queue a prerequisite.
 * Go's answer at this point is stealing; under a global lock, handing
 * the work back is simpler and is correct for the same reason.
 */
static void gput(Prog*);	/* defined below */

extern int parallelvm;		/* defined below, with stoptheworld() */

static Pctx pctxpool[MAXPCTX];
static int npctxused;

ulong ctxreused, ctxreleased, ctxnone;	/* MULTICORE INSTRUMENTATION - temporary */

static Pctx*
claimctx(void)
{
	Pctx *c;
	int i;

	lock(&isched.l);
	/*
	 * The first interpreter takes the context that already exists.
	 * xec.c's _pctx is what curP has pointed at since boot, and the
	 * programs queued before any interpreter ran are on its local
	 * queue.  Handing the first claimer a fresh context orphans them:
	 * the run queue is abandoned, nothing is ever picked, and the boot
	 * dies with zero scheduler passes.  Measured, not reasoned -- that
	 * is exactly what the first version of this did.
	 */
	if(npctxused == 0){
		npctxused = 1;
		pctxs[0]->owner = up;
		unlock(&isched.l);
		return pctxs[0];	/* == &_pctx, already in pctxs[] */
	}
	/*
	 * A context an interpreter gave up when it parked.
	 *
	 * Contexts used to be claimed once and held for the life of the
	 * kproc, so the pool only ever shrank: every blocking Dis system
	 * call can spawn an interpreter (see release()), and with the
	 * collector running continuously -smp 4 boots reached all 64 and
	 * started sharing register files, which is the one thing the pool
	 * exists to prevent.  An interpreter needs a context while it
	 * interprets, not while it sleeps.
	 */
	for(i = 0; i < npctx; i++)
		if(pctxs[i]->owner == nil){
			c = pctxs[i];
			c->owner = up;
			ctxreused++;
			unlock(&isched.l);
			return c;
		}
	if(npctxused >= MAXPCTX){
		static int said;

		/*
		 * Sharing here was described as "correct, just not
		 * parallel".  That is true with the VM lock and false
		 * without it: two executors on one Pctx are two executors on
		 * one Dis register file, which is the whole thing curP was
		 * made per-executor to avoid.  It was measured doing damage
		 * -- a heap object dropped twice, by executors 15 and 17,
		 * both reporting the same context.
		 *
		 * MAXPCTX is now large enough that this should not be
		 * reached.  If it is, say so once rather than silently
		 * handing out a shared register file: at parallelvm=0 the
		 * old behaviour is still correct, and at parallelvm=1 this
		 * line is the warning that the pool needs to be bigger or
		 * that contexts need releasing when an interpreter blocks.
		 */
		if(said++ == 0)
			print("claimctx: pool of %d exhausted, sharing"
				" (unsafe while parallelvm=%d)\n",
				MAXPCTX, parallelvm);
		unlock(&isched.l);
		return pctxs[0];
	}
	c = &pctxpool[npctxused - 1];
	c->owner = up;
	c->idx = npctx;		/* its own Rendez; see enterquantum() */
	pctxs[npctx++] = c;
	npctxused++;
	unlock(&isched.l);
	return c;
}

/*
 * Flush THIS process's context, not the global curP.
 *
 * curP is a global.  While the VM lock is held that is safe, because
 * only one interpreter runs and the global names its context.  With
 * parallelvm forced to 1 it is not: every interpreter assigns the
 * global when it acquires, so vmrelease() flushed whichever context
 * ran last rather than its own, walked a run queue belonging to
 * someone else, and took an alignment fault on a link field that held
 * string bytes.  The pc was flushlocal+0x18 under vmrelease+0x1c.
 *
 * up->pctx is the right answer here and is correct in both modes.  It
 * does not fix the general case: every other use of curP in the
 * interpreter has the same problem the moment contexts run at once,
 * which is why the plan's Phase 1b is "curR becomes per-executor" and
 * why that is what has to land next.
 */
static void
flushlocal(void)
{
	Pctx *c;
	Prog *p;

	c = (Pctx*)up->pctx;
	if(c == nil)
		return;
	while(c->runhd != nil){
		p = c->runhd;
		c->runhd = p->link;
		if(c->runhd == nil)
			c->runtl = nil;
		c->nlocal--;
		gput(p);
	}
}

/*
 * Stop-the-world, the shape Phase 5 of doc/dis-parallel-plan.ms chose
 * and the shape Go uses for the phases that need it.
 *
 * It exists because of what the VM lock still protects.  With a context
 * per interpreter the allocator is already safe (poolalloc takes the
 * pool's own ilock) and the refcounts are already atomic; what is left
 * is libinterp/gc.c's mark state, which lives in file-scope statics --
 * one sweep position, one pointer table, one epoch.  Two contexts
 * inside rungc() would interleave on all of it.  Stopping the others
 * for the duration makes a serial marker correct without giving that
 * state a per-collection home first, and parallel marking can follow.
 *
 * A context is at a safepoint when no quantum is open on it: curP->inxec
 * is 0, which means isave() has written its registers back and the
 * collector can trust p->reg.  A context blocked in a system call is
 * therefore already at a safepoint and does not have to be waited for,
 * which is the same reasoning Go uses to avoid waiting on an M in a
 * syscall.
 *
 * parallelvm is the switch.  At 0 the VM lock is taken as before and
 * this is inert -- nothing else can be running, so stopping the world
 * stops nothing.  At 1 the lock is not taken and this is what keeps the
 * collector correct.  It defaults to 0 because that is the tested
 * configuration, and the other one is turned on to test it.
 */
int parallelvm = 0;	/* MULTICORE: 1 = no VM lock, stop-the-world GC */
int gcstw;		/* a collection wants every other context stopped */
int stwwaits;		/* MULTICORE INSTRUMENTATION - temporary: turns round
			 * the wait loop.  It used to count sched() spins and
			 * ran to five figures in a boot; since the collector
			 * parks it counts 20ms naps, so the same number here
			 * means something very different.  stwparks/stwwakes
			 * below separate "how often did it have to wait" from
			 * "how often did a closing quantum wake it". */

/* how many contexts other than this one have a quantum open */
static int
othersrunning(void)
{
	int i, n;

	n = 0;
	for(i = 0; i < npctx; i++)
		if(pctxs[i] != curP && pctxs[i]->inxec)
			n++;
	return n;
}

static Proc *gcstwproc;

/*
 * libinterp/heap.c's hook: a collection is running and this process is
 * not the one running it, so destroy() must hand the object over
 * rather than free it underneath the collector.
 */
static int
gcstwothers(void)
{
	return gcstw != 0 && up != gcstwproc;
}

void	safepoint(void);	/* defined below, with the rest of the handshake */

/*
 * What keeps the collector out while a Prog's stack is dismantled.
 *
 * destroystack() nils reg->EX as its second statement, frees every
 * extent, and sets reg->M = H last.  rootset() reads M, then SP, then
 * EX, then walks.  So a collector that read EX before the nil would walk
 * Stkexts that free() is handing back underneath it -- a use-after-free
 * that looks like "bad frame type", "frames do not tile" and a jump into
 * the Dis heap through t->mark from the other end.  That is not
 * hypothetical: *teardrop below opens it on demand.
 *
 * inxec closes it, and nothing more is needed.  Both teardowns run with
 * a quantum open: killprog() under progwrite()'s acquire(), and
 * progexit() after vmachine()'s handler has called enterquantum().  A
 * collector cannot walk while a quantum is open -- stoptheworld() waits
 * for it, and if it gives up it returns without calling rungc() at all.
 *
 * There used to be an exclusion here as well, an intear flag that
 * othersrunning() counted and a wait for gcstw to clear.  It was written
 * when the handler still cleared inxec before the teardown, and by the
 * time it was measured it was guarding nothing: 0 walks over freed
 * extents in 16 boots with it and 0 in 16 without, 0 teardowns without a
 * quantum in either.  Its cost was real, because a teardown that met a
 * pending collection held a quantum the collector was waiting for and
 * then waited for the collector -- 15 of 16 boots abandoned a
 * collection with it, 5 of 16 without.  See doc/multicore-plan.ms.
 *
 * What is left is instrumentation, all temporary: counters for
 * teardowns, for those that met a collection and for any that arrive
 * without a quantum -- that last is the invariant the above rests on --
 * and the positive control.
 */

/*
 * *gcwalkdelay=N: rootset() waits N ms between reading a Prog's EX and
 * walking it.  The positive control for its rootraced counter; see
 * there.
 */
int gcwalkms;

static void
gcwalkdelayfn(void)
{
	delay(gcwalkms);
}

ulong tears;
ulong tearoverlap;
ulong tearnoquantum;	/* teardowns entered without inxec */
int teardrop;		/* *teardrop=N: the positive control; see below */

static void enterquantum(void);

static void
entertear(Prog *p)
{
	tears++;
	if(curP->inxec == 0)
		if(tearnoquantum++ == 0)
			print("entertear: teardown without a quantum\n");
	if(gcstwothers())
		tearoverlap++;
	/*
	 * *teardrop=N gives the quantum up for the length of the teardown,
	 * which is what vmachine()'s handler did before it took
	 * enterquantum() ahead of handler(), and waits N ms so that a
	 * pending collector can start and reach this Prog before
	 * destroystack() nils EX.  With *gcwalkdelay it is the case
	 * rootset()'s rootraced counter exists to see: measured, the counter
	 * and the bad-frame tripwire agreed boot for boot.
	 */
	if(teardrop){
		curP->inxec = 0;
		coherence();
		safepoint();
		delay(teardrop);
	}
	p->torn = 1;	/* see rootset() */
	coherence();
}

static void
leavetear(void)
{
	if(teardrop)
		enterquantum();		/* take back what entertear() gave up */
}

int stwgaveup;		/* MULTICORE INSTRUMENTATION - temporary */
ulong stwparks;		/* MULTICORE INSTRUMENTATION - temporary */
ulong stwwakes;		/* MULTICORE INSTRUMENTATION - temporary */

/*
 * Where the collector waits for the last quantum to close.
 *
 * The wait used to be "while somebody has a quantum open, sched()",
 * which spends a context switch per turn and measured up to 56500 of
 * them in a single parallelvm=1 -smp 4 boot -- the wait was costing more
 * than the collection it was waiting for.  A context that closes a
 * quantum while gcstw is set wakes this instead.
 */
static Rendez stwr;

/*
 * And one per context for the other side of the handshake.  A context
 * that wants to enter a quantum while a collection is running used to
 * sched() round enterquantum()'s withdraw-and-retry loop until the
 * collection finished -- so parking the collector moved the spin rather
 * than removing it, and the two were measured apart: with the collector
 * parked and the give-up bound reading a per-CPU clock (so that it fired
 * on the first migration and the world was almost never actually
 * stopped) the shell loop ran 442 iterations in sixteen boots; with the
 * clock honest, so that the collector waits its quarter second and every
 * other context spins through it, the same sixteen boots ran 0.
 *
 * A Rendez holds exactly one sleeper, so this cannot be a single one.
 * One per context works because claimctx() hands each interpreter its
 * own; the exception is pool exhaustion, where contexts are shared, and
 * that path already prints that it is unsafe under parallelvm.
 */
static Rendez ctxr[MAXPCTX];

static int
worldrunning(void *a)
{
	USED(a);
	return gcstw == 0;
}

/*
 * Let the world run again, and wake everyone waiting to enter a quantum.
 *
 * npctx is read without isched.l, as othersrunning() and progreg() also
 * do.  A context claimed between this read and the loop is missed, and
 * that costs it the 5ms timeout on its own tsleep rather than anything
 * worse -- which is the same reason the timeout is there.  wakeup() on a
 * Rendez with no sleeper is a no-op, so the loop is safe to run over
 * contexts that are not waiting.
 */
static void
releaseworld(void)
{
	int i;

	gcstw = 0;
	coherence();
	for(i = 0; i < npctx; i++)
		wakeup(&ctxr[i]);
}

static int
allstopped(void *a)
{
	USED(a);
	return othersrunning() == 0;
}

/*
 * Called by a context that has just cleared inxec.  Both halves of the
 * handshake read the other's write after their own: the closer clears
 * inxec and then tests gcstw, stoptheworld() sets gcstw and then reads
 * inxec, so a wake cannot be lost between them.  The timeout below
 * covers the cases this is not called from at all -- the error paths.
 */
void
safepoint(void)
{
	if(gcstw){
		stwwakes++;
		wakeup(&stwr);
	}
}
int gcidlegaveup;	/* idle collections abandoned; see execatidle() */

/*
 * Stop every other context, or give up trying.
 *
 * Bounded, and that is the point.  The wait was "while somebody has a
 * quantum open, sched()", which is a spin: this process yields, every
 * other interpreter yields in enterquantum()'s withdraw-and-retry loop,
 * and the one process that has to finish its quantum to clear the flag
 * is the one that does not get a processor.  Measured, not supposed --
 * 44 of 51 stalls across a 28-boot comparison named the same blocker,
 * a context whose owner sat in Ready with a quantum open while the
 * collector logged "stw: 200000 waits".
 *
 * Returning 0 abandons the collection, and that is safe in a way that
 * waiting is not: a collection that does not happen costs memory until
 * the next one, and there is always a next one, while a collection
 * that cannot start costs the boot.  Parking rather than spinning, as
 * Go does with an M, is the better answer and a larger change.
 *
 * Bounded by time, not by a count of tries, and the difference is not
 * cosmetic.  A count measures how fast this loop goes round, which is
 * whatever the compiler and the console happen to make it: with an
 * unrelated print in the loop, two thousand tries spanned long enough
 * for other contexts to finish their quanta and the world stopped;
 * with the print removed the same two thousand tries elapsed too
 * quickly to ever succeed, the collector gave up every time, and shell
 * loop iterations fell from 22 to 4 across nine boots.  What the
 * waiting is for is wall-clock time for somebody else's quantum to
 * end, so that is what to bound.
 */
int
stoptheworld(void)
{
	ulong start;
	int tries;

	if(parallelvm == 0)
		return 1;	/* the VM lock already is one */
	if(gcstopped == nil)
		gcstopped = gcstwothers;	/* the handover; see heap.c */
	gcstwproc = up;
	gcstw = 1;
	coherence();
	/*
	 * MACHP(0)->ticks, not m->ticks.
	 *
	 * m is the per-CPU Mach and each CPU's clock handler increments its
	 * own copy (portclock.c).  This loop reschedules every turn, so the
	 * process can be on a different CPU when it reads the clock than it
	 * was when it set `start' -- and then the subtraction is between two
	 * unrelated counters.  One tick behind reads as 0xffffffff, which is
	 * greater than HZ/4, so the collection is abandoned on the first
	 * migration rather than after a quarter second.
	 *
	 * Measured, not reasoned: of 21 give-ups logged across the
	 * parallelvm=1 batches, 13 printed an elapsed time of 4294967295 or
	 * 4294967294 and only 8 printed the honest 26.  Nearly two thirds of
	 * the collector's give-ups were this bug, and each one is a
	 * collection that did not happen.
	 *
	 * proc.c uses MACHP(0)->ticks where it needs a system-wide count,
	 * for the same reason.
	 */
	start = MACHP(0)->ticks;
	for(tries = 0; othersrunning() > 0; tries++){
		stwwaits++;
		if((ulong)(MACHP(0)->ticks - start) > HZ/4){
			releaseworld();	/* let them run; collect next time */
			if(stwgaveup++ == 0)
				print("stw: gave up after %d tries, %lud ticks,"
					" cpu%d %s\n", tries,
					(ulong)(MACHP(0)->ticks - start),
					m->machno, up->text);
			return 0;
		}
		/*
		 * Park, do not spin.  tsleep() re-tests the condition before
		 * sleeping, so a context that clears inxec between the test
		 * above and this call is not a lost wakeup.  The timeout is
		 * what makes safepoint() an optimisation rather than a
		 * correctness requirement: a quantum closed on a path that
		 * does not call it costs 20ms here, not the boot.
		 */
		stwparks++;
		tsleep(&stwr, allstopped, nil, 20);
	}
	/*
	 * MULTICORE INSTRUMENTATION - temporary.  A watermark, at 1, 10,
	 * 100 parks and so on, so a boot log carries how much the
	 * collector had to wait without a print in the loop itself.  That
	 * distinction is not pedantry here: a print inside this loop once
	 * throttled the spin enough to change the result it was measuring,
	 * and removing it cut shell iterations from 18 to 2.  Six lines a
	 * boot does not.
	 */
	{
		static ulong said;

		if(stwparks >= said){
			said = said != 0 ? said*10 : 1;
			print("stw: %lud parks, %lud wakes, %d waits,"
				" %d gave up\n",
				stwparks, stwwakes, stwwaits, stwgaveup);
		}
	}
	return 1;
}

/*
 * Claim a quantum on this context, and do not return while a collection
 * is running.  The other half of stoptheworld().
 *
 * Publish first, then re-check.  Testing gcstw and only afterwards
 * setting inxec leaves a window: a context can pass the test, the
 * collector can then set gcstw and find othersrunning() == 0 because
 * inxec is not set yet, and marking begins while this context enters a
 * quantum.  The panic that showed up with parallelvm forced to 1 was in
 * poolalloc and poolfree, which is what a collector running against a
 * live mutator looks like.
 *
 * So claim the quantum first, make the claim visible, and only then
 * look at gcstw; if a collection has started, withdraw the claim and
 * wait.  The collector sets gcstw and then reads inxec, so the two
 * orderings cannot both miss.
 *
 * Two callers: vmachine() before each quantum, and acquire(), where an
 * interpreter coming back from a blocking Dis system call is entering a
 * quantum just as much -- isave() gave the claim up on the way in.
 */
static void
enterquantum(void)
{
	if(curP->inchan)
		panic("enterquantum: channel region still open");
	for(;;){
		curP->inxec = 1;
		coherence();
		if(gcstw == 0)
			return;
		curP->inxec = 0;
		coherence();
		safepoint();	/* the collector may be waiting for this */
		/*
		 * Park rather than spin, for the same reason the collector
		 * does.  This context is already at a safepoint -- inxec is
		 * clear -- so sleeping here delays nothing the collector is
		 * waiting for.  The 5ms timeout means a wake that does not
		 * arrive costs that, not the collection.
		 */
		tsleep(&ctxr[curP->idx], worldrunning, nil, 5);
	}
}

/*
 * One collection at a time.
 *
 * stoptheworld() waits for contexts that have a quantum open.  A second
 * collector has none -- it withdrew its own claim before calling -- so
 * it walks straight through, and two collectors mark and sweep the same
 * heap at once.  That is a double free: "alloc:D2B:poolfree 78faf58
 * (from poolfree+0x1dd/rungc+0x322)", a block swept twice.
 *
 * gclock() does not prevent it and is not meant to.  It is a counter
 * that says "do not collect now", which rungc() honours by returning;
 * two collectors both read gchalt as 0 and both proceed.
 *
 * A QLock, not a Lock: this is held for a whole collection, and the
 * holder can sleep in the allocator.  A process waiting here is
 * Queueing with no quantum open, so it does not hold up the collection
 * it is waiting for.  Go has one collector at a time for the same
 * reason and gates it the same way.
 */
static QLock gcsema;

static void	starttheworld(void);
int		stoptheworld(void);

/*
 * Returns whether it actually collected.  A caller that loops until the
 * collector has made progress has to know, or it spins: execatidle()
 * waits for gccolor to advance, gccolor only advances when rungc()
 * runs, and rungc() does not run when the world will not stop.  That
 * turned the bounded give-up below into a tighter loop than the
 * unbounded wait it replaced -- collect(), two thousand sched() calls,
 * give up, collect() again, yielding only every 256th pass.
 *
 * Measured by its absence: removing an unrelated print from the wait
 * loop made each pass cheaper, sped the spin up, and cut shell loop
 * iterations from 18 to 2 across eight boots.  The print had been
 * throttling it.
 */
int gcphase;	/* MULTICORE INSTRUMENTATION - temporary; see stalldump() */

/*
 * Closes the collector must not make while it holds the world stopped.
 *
 * freeFD() is TFD's finaliser and does release(); close; acquire().
 * Reached from rungc() with gcstw set, that was a self-deadlock, found
 * by sampling every CPU of a stalled parallelvm=1 -smp 4 boot through
 * the QEMU monitor: execatidle -> collect -> rungc -> freeFD ->
 * acquire -> vmacquire, whose "while(gcstw) sched()" waited for the
 * collection the same process was in the middle of.  13 boots of 16
 * stalled that way, with gcsema held and every other interpreter queued
 * on it.
 *
 * Exempting the collector from that wait would not be enough.  The
 * close can block -- on a Styx server that is itself a Dis program,
 * one this collection has stopped -- and then the collector waits for a
 * program that waits for the collector.  So the close is not made
 * inside the stopped world at all: freeFD() queues it here and
 * fdcloseproc() makes it once collect() has let the world go.
 */
typedef struct Fdclose Fdclose;
struct Fdclose
{
	Fgrp*	grp;
	int	fd;
	Fdclose*	next;
};
static Lock fdclosel;
static Fdclose *fdcloseq;
ulong fdclosedeferred;	/* MULTICORE INSTRUMENTATION - temporary */
ulong freefds, freefdstw;	/* likewise; counted in freeFD() */
ulong vmspawns;		/* interpreters made by release(); temporary */
int fddefer = 1;	/* *fddefer=0: close inline, as before; temporary */

/* this process is the collector and the world is stopped for it */
int
gcworldheld(void)
{
	return gcstw != 0 && up == gcstwproc;
}

/*
 * Returns 0 if the close could not be queued, and then the caller must
 * make it itself.  Only when malloc fails, and it says so.
 */
int
deferfdclose(Fgrp *grp, int fd)
{
	Fdclose *c;

	c = malloc(sizeof *c);
	if(c == nil){
		print("deferfdclose: no memory, closing fd %d in the stopped world\n", fd);
		return 0;
	}
	c->grp = grp;
	c->fd = fd;
	lock(&fdclosel);
	c->next = fdcloseq;
	fdcloseq = c;
	fdclosedeferred++;
	unlock(&fdclosel);
	return 1;
}

/*
 * The queued closes are made by a kernel process of their own, not by
 * the interpreter that collected.  The first version made them at the
 * end of collect() under release()/acquire(), as freeFD() had, and
 * that was wrong in a way only a live collector shows: every release()
 * there may spawn an interpreter, the collector runs every 256 quanta,
 * and the pool of contexts ran out -- "claimctx: pool of 64 exhausted,
 * sharing" in every panicking -smp 4 boot of six, two interpreters on
 * one register file.  A process that only closes needs no interpreter,
 * no context and no quantum, and a close that blocks stalls nobody.
 */
static Rendez fdcloser;

static int
fdclosepending(void *a)
{
	USED(a);
	return fdcloseq != nil;
}

static void
fdcloseproc(void *a)
{
	Fdclose *c, *next;

	USED(a);
	/*
	 * Its own context and the creator's groups, because a close can
	 * reach progclose(), which acquire()s the interpreter: without a
	 * context it would push its placeholder Prog onto whatever context
	 * curP names, and without groups release()'s spawn incref()s a nil
	 * Pgrp -- "incref: bad r 0x0 pc=kproc+100", four boots of eight.
	 */
	if(up->pctx == nil)
		up->pctx = claimctx();
	for(;;){
		while(waserror())
			;
		sleep(&fdcloser, fdclosepending, nil);
		poperror();
		lock(&fdclosel);
		c = fdcloseq;
		fdcloseq = nil;
		unlock(&fdclosel);
		for(; c != nil; c = next){
			next = c->next;
			if(c->fd >= 0)
				kfgrpclose(c->grp, c->fd);
			closefgrp(c->grp);
			free(c);
		}
	}
}

int
collect(Prog *head)
{
	int stopped;

	qlock(&gcsema);
	/*
	 * stoptheworld() now sleeps, and tsleep() raises the note that
	 * interrupts it -- so this function acquired a way to leave by
	 * longjmp that it did not have when it spun.  Without this handler
	 * that leaves gcsema held forever and the world stopped, which is
	 * every future collection deadlocked and every other interpreter
	 * parked in enterquantum().  This is the waserror()/nexterror()
	 * idiom in its usual form: the allocation cannot be hoisted out of
	 * the region here, because the sleep is the region.
	 */
	if(waserror()){
		starttheworld();
		qunlock(&gcsema);
		nexterror();
	}
	gcphase = 1;
	stopped = stoptheworld();
	gcphase = 2;
	if(stopped)
		rungc(head);
	gcphase = 3;
	poperror();
	starttheworld();
	gcphase = 4;
	qunlock(&gcsema);
	gcphase = 5;
	if(fdcloseq != nil)	/* unlocked peek; the next collection catches a miss */
		wakeup(&fdcloser);
	return stopped;
}

static void
starttheworld(void)
{
	if(parallelvm == 0)
		return;
	releaseworld();
}

enum { Gqevery = 61 };	/* Go's schedule() uses 61 for the same reason */
int gqtick;
int gqput, gqget;	/* MULTICORE INSTRUMENTATION - temporary */

static void
gput(Prog *p)
{
	lock(&isched.l);
	p->link = nil;
	if(isched.gtail != nil)
		isched.gtail->link = p;
	else
		isched.ghead = p;
	isched.gtail = p;
	isched.ngq++;
	gqput++;
	unlock(&isched.l);
}

static Prog*
gget(void)
{
	Prog *p;

	lock(&isched.l);
	p = isched.ghead;
	if(p != nil){
		isched.ghead = p->link;
		if(isched.ghead == nil)
			isched.gtail = nil;
		isched.ngq--;
		gqget++;
		p->link = nil;
	}
	unlock(&isched.l);
	return p;
}

/* is p on the global queue?  used only by delrunq() */
static int
gdel(Prog *p)
{
	Prog *f, *prev;

	lock(&isched.l);
	prev = nil;
	for(f = isched.ghead; f != nil; f = f->link){
		if(f == p)
			break;
		prev = f;
	}
	if(f == nil){
		unlock(&isched.l);
		return 0;
	}
	if(prev == nil)
		isched.ghead = p->link;
	else
		prev->link = p->link;
	if(p == isched.gtail)
		isched.gtail = prev;
	isched.ngq--;
	unlock(&isched.l);
	return 1;
}

int	bflag;
int	cflag;
uvlong	gcbusy;
uvlong	gcidle;
uvlong	gcidlepass;
uvlong	gcpartial;
int keepbroken = 1;
int nvm;	/* MULTICORE INSTRUMENTATION - temporary: VM holders */
int maxnvm;
/*
 * MULTICORE INSTRUMENTATION - temporary.  nvm above answers "how many
 * processes hold the VM lock", and with one global vmlock that is 1 by
 * construction, which says nothing about whether there is parallelism
 * to win.  maxnrunq answers the question that actually decides whether
 * Phase 1b and Phase 5 are worth their risk: how many Dis programs are
 * READY at the same moment.  A high-water mark of 1 on this workload
 * would mean a per-executor register file buys nothing here, and the
 * measurement is much cheaper than the work.
 *
 * Measured by walking curP->runhd at the scheduler's own pick rather
 * than by a counter incremented in addrun().  The queue is inserted
 * into and removed from in five places, not just addrun()/delrun()/
 * delrunq() -- delprog() unlinks a head directly, and the Prog that
 * takes the VM lock is pushed on the front -- so a maintained counter
 * would drift.  The walk is once per quantum, not once per queue
 * operation, and is capped so its cost is bounded whatever the queue
 * does.  It runs under the VM lock, which is what serialises the queue.
 */
enum { Runqcap = 64 };
int maxnrunq;
int nrunqmismatch;	/* MULTICORE INSTRUMENTATION - temporary */
int maxvmq;
int vmqbad;
uvlong vmpasses;	/* MULTICORE INSTRUMENTATION - temporary */
uvlong vmblocked;

/*
 * Dis executes one program at a time, system-wide.
 *
 * This is not a scaling choice, it is what the interpreter is.  The
 * virtual machine's register set is the single global REG R
 * (libinterp/xec.c:11); irestore() loads it from a Prog and isave()
 * stores it back (libinterp/xec.c:2280); and every JIT backend
 * compiles the absolute address of that one object into the code it
 * emits -- comp-amd64.c alone has eight con((uintptr)&R, RTMP).  Two
 * processors interpreting at once share one register file.
 *
 * The isched.idle/vmq/idlevmq handshake this replaces was meant to be
 * that exclusion and was not.  Instrumenting vmachine()'s xec() call
 * with a counter showed ten kernel processes inside xec() at once on a
 * four processor boot; "movp: bad sv", "movp: bad dv-freed" and the
 * decref underflows all came from there.
 *
 * A QLock, not a Lock: the holder blocks in Dis system calls, and
 * qunlock() hands the lock to the head of its own FIFO queue rather
 * than dropping it, which is what makes iyield() a real yield.
 *
 * vmheld is per-process and makes both operations idempotent.  That is
 * what lets this survive the error path: propex()/nexterror() longjmps
 * out of xec() straight back to vmachine()'s waserror() block, over
 * any unlock in between.  An earlier attempt at a single Dis lock was
 * reverted for exactly that reason -- the history is in the long
 * comment in emu/port/dis.c's vmachine() -- and the flag is the answer
 * to it: the recovery path calls vmrelease() and it does the right
 * thing whether or not the lock survived the jump.
 */
static QLock vmlock;

static void
vmacquire(void)
{
	if(up->vmheld == 0){
		if(parallelvm == 0)
			qlock(&vmlock);
		else
			while(gcstw)	/* do not start while a collection runs */
				sched();
		up->vmheld = 1;
		if(up->pctx != nil){
			curP = (Pctx*)up->pctx;
#ifndef DISCTXREG
			curR = &curP->reg;
#endif
		}
		{	/* MULTICORE INSTRUMENTATION - temporary */
			int n = ainc(&nvm);
			if(n > maxnvm){
				maxnvm = n;
				print("nvm: %d hold the vm, cpu%d %s\n",
					n, m->machno, up->text);
			}
		}
	}
}

/*
 * Give the context back where an interpreter parks with no work.
 *
 * The caller holds isched.l, which claimctx() also takes, and
 * vmrelease() has already flushed the local queue -- so the context
 * holds nothing and another interpreter can have it.  It is taken again
 * the instant this process is scheduled, before anything else touches
 * curP: the first version of this reclaimed at the top of the loop,
 * which is after vmacquire(), and an interpreter with no context ran
 * against the shared defpctx and pushed its placeholder Prog onto it --
 * "delrunq: prog 0 was on another context's queue" in 11 boots of 12,
 * with panics to match.
 */
static void
releasectx(void)
{
	Pctx *c;

	if((c = (Pctx*)up->pctx) == nil)
		return;
	if(c->runhd != nil || c->inxec || c->inchan || c->curprog != nil)
		return;		/* not idle after all; keep it */
	c->owner = nil;
	up->pctx = nil;
	/*
	 * curP must stop naming it here, not at the next sched(): another
	 * interpreter can claim this context immediately, and currun() is
	 * curP->runhd -- so a stale curP would hand this process somebody
	 * else's current program for the length of a blocking system call.
	 * defpctx is what a process with no context uses anyway.
	 */
	curP = defpctx;
	ctxreleased++;
}

/*
 * An interpreter with nothing to run parks itself on isched.idlevmq and
 * gives up the processor; this is what restarts one.  It is not the VM
 * lock -- a woken interpreter still has to take that -- it only says
 * "there is work now".
 *
 * A Rendez holds exactly one sleeper, so the idle interpreters cannot
 * simply sleep() on a shared one; doing that produced "double sleep
 * called from vmachine+0x22b" the moment a second interpreter went
 * idle.  Parking with state Queueing and restarting with ready() is
 * what the code this replaced already did, and it takes any number.
 */
static void
wakeidle(void)
{
	Proc *p;

	lock(&isched.l);
	p = isched.idlevmq;
	if(p != nil){
		isched.idlevmq = p->vmnext;
		p->vmnext = nil;
		isched.nidle--;
	}
	unlock(&isched.l);
	if(p != nil)
		ready(p);
}

static void
vmrelease(void)
{
	if(up->vmheld){
		adec(&nvm);	/* MULTICORE INSTRUMENTATION - temporary */
		flushlocal();	/* do not strand work on a context that stops */
		up->vmheld = 0;
		if(parallelvm == 0)
			qunlock(&vmlock);
	}
}
static Prog*	proghash[64];

/*
 * delprog() release()s the interpreter token while it closes p's
 * pgrp/fgrp/egrp/sigs, but does not unlink p from proghash[]/isched
 * until it reacquires -- so p is still reachable by pid through
 * progpid() during that window, while o->pgrp etc may already be
 * freed.  disracepid names the pid currently inside that window (-1
 * when none is); devprog.c's progpid()-based read paths report a hit
 * if they find it, and delprog itself reports whether the GC was
 * blocked from running (via gchalt/gchalted, see include/interp.h and
 * libinterp/gc.c) during the same window.  Diagnostic only, capped;
 * see doc/inferno-ports.ms.
 */
int	disracepid = -1;
int	disracehits;
int	disracewindows;	/* delprog windows opened, total */
int	disraceoverlaps;	/* windows opened while another was already open */
extern ulong gchalted;


static Progs*	delgrp(Prog*);
static void	addgrp(Prog*, Prog*);
void	printgrp(Prog*, char*);

static Prog**
pidlook(int pid)
{
	ulong h;
	Prog **l;

	h = (ulong)pid % nelem(proghash);
	for(l = &proghash[h]; *l != nil && (*l)->pid != pid; l = &(*l)->pidlink)
		;
	return l;
}

int
tready(void *a)
{
	USED(a);
	return curP->runhd != nil || isched.ghead != nil;
}

Prog*
progpid(int pid)
{
	return *pidlook(pid);
}

Prog*
progn(int n)
{
	Prog *p;

	for(p = isched.head; p && n--; p = p->next)
		;
	return p;
}

int
nprog(void)
{
	int n;
	Prog *p;

	n = 0;
	for(p = isched.head; p; p = p->next)
		n++;
	return n;
}

static void
accountant(void)
{
	Prog *p;

	p = curP->runhd;
	if(p != nil)
		p->ticks++;
}

static void
execatidle(void)
{
	int done;

	if(tready(nil))
		return;

	gcidle++;
	up->type = IdleGC;
	up->iprog = nil;
	addrun(up->prog);

	done = gccolor+3;
	while(gccolor < done && gcruns()) {
		if(curP->runhd != curP->runtl) {
			gcpartial++;
			break;
		}
		if(!collect(isched.head)){
			/*
			 * The world would not stop, so gccolor has not moved
			 * and this loop's condition is exactly as true as it
			 * was.  Retrying now is a spin; there is nothing to
			 * collect until whoever holds a quantum open finishes
			 * it, and the way to let that happen is to stop
			 * asking.
			 */
			gcidlegaveup++;
			break;
		}
		gcidlepass++;
		if(((ulong)gcidlepass&0xFF) == 0)
			sched();
	}

	up->type = Interp;
	delrunq(up->prog);
}

Prog*
newprog(Prog *p, Modlink *m)
{
	Heap *h;
	Prog *n, **ph;
	Osenv *on, *op;
	static int pidnum;

	if(p != nil){
		if(p->group != nil)
			p->flags |= p->group->flags & Pkilled;
		if(p->kill != nil)
			error(p->kill);
		if(p->flags & Pkilled)
			error("");
	}
	n = malloc(sizeof(Prog)+sizeof(Osenv));
	if(n == 0){
		if(p == nil)
			panic("no memory");
		else
			error(exNomem);
	}

	n->group = nil;

	/*
	 * pidnum, the isched list and proghash[] are shared by every
	 * executor, and nothing here took a lock: the VM lock was doing
	 * it, and it is the lock parallelvm=1 removes.  rungc() walks
	 * isched.head, so a torn list is a collector walking off into
	 * freed memory -- page faults and general protection violations,
	 * which is how *parallelvm=1 fails once the earlier bugs are out
	 * of the way.
	 *
	 * isched.l is the lock the global run queue and claimctx() already
	 * use.  Nothing in here sleeps, which a Lock requires.
	 */
	lock(&isched.l);
	n->pid = ++pidnum;
	if(n->pid <= 0)
		panic("no pids");

	if(isched.tail != nil) {
		n->prev = isched.tail;
		isched.tail->next = n;
	}
	else {
		isched.head = n;
		n->prev = nil;
	}
	isched.tail = n;

	ph = pidlook(n->pid);
	if(*ph != nil)
		panic("dup pid");
	n->pidlink = nil;
	*ph = n;
	unlock(&isched.l);

	n->osenv = (Osenv*)((uchar*)n + sizeof(Prog));
	n->xec = xec;
	n->quanta = PQUANTA;
	n->flags = 0;
	n->exval = H;

	h = D2H(m);
	/*
	 * AINC, not h->ref++.  Every other reference count in the Dis heap
	 * goes through AINC/ADEC because two executors really do touch the
	 * same object's count at once (interp.h says so where the macros
	 * are defined); these two sites in this file were the exceptions,
	 * and a lost update here frees a Modlink that is still linked --
	 * "alloc:D2B:destroy-entry", which is one of the ways
	 * *parallelvm=1 fails.
	 */
	AINC(&h->ref);
	Setmark(h);
	n->reg.M = m;
	n->reg.MP = m->MP;
	if(m->MP != H)
		Setmark(D2H(m->MP));
	addrun(n);

	if(p == nil){
		newgrp(n);
		return n;
	}

	addgrp(n, p);
	n->flags = p->flags;
	if(p->flags & Prestrict)
		n->flags |= Prestricted;
	memmove(n->osenv, p->osenv, sizeof(Osenv));
	op = p->osenv;
	on = n->osenv;
	on->waitq = op->childq;
	on->childq = nil;
	on->debug = nil;
	incref(on->pgrp);
	incref(on->fgrp);
	if(on->egrp != nil)
		incref(on->egrp);
	if(on->sigs != nil)
		incref(on->sigs);
	on->user = nil;
	kstrdup(&on->user, op->user);
	on->errstr = on->errbuf0;
	on->syserrstr = on->errbuf1;

	return n;
}

void
delprog(Prog *p, char *msg)
{
	Osenv *o;
	Prog **ph;

	if(p->exstr != nil)
		DBG("delprog p->pid %d msg %s p->exstr %s\n", p->pid, msg, p->exstr);
	else
		DBG("delprog p->pid %d msg --%s--\n", p->pid, msg);
	tellsomeone(p, msg);	/* call before being removed from prog list */

	o = p->osenv;
	{
		ulong gcbefore;

		gcbefore = gchalted;
		disracewindows++;
		if(disracepid != -1) {
			disraceoverlaps++;
			if(disraceoverlaps <= 8)
				print("delprog: pid %d opening window while pid %d's was still open (overlap %d)\n",
					p->pid, disracepid, disraceoverlaps);
		}
		disracepid = p->pid;
		release();
		closepgrp(o->pgrp);
		closefgrp(o->fgrp);
		closeegrp(o->egrp);
		closesigs(o->sigs);
		acquire();
		disracepid = -1;
		if(disracehits < 8 && gchalted != gcbefore) {
			disracehits++;
			print("delprog: pid %d gchalted %lud->%lud during close window\n",
				p->pid, gcbefore, gchalted);
		}
	}

	delgrp(p);

	lock(&isched.l);	/* see newprog(); the same list */
	if(p->prev)
		p->prev->next = p->next;
	else
		isched.head = p->next;

	if(p->next)
		p->next->prev = p->prev;
	else
		isched.tail = p->prev;

	ph = pidlook(p->pid);
	if(*ph == nil)
		panic("lost pid");
	*ph = p->pidlink;
	unlock(&isched.l);

	/*
	 * This removed p only when it was the head of the run queue, so a
	 * Prog deleted from anywhere else stayed linked into a list whose
	 * every other reader -- vmachine()'s own pick, and disdump()'s
	 * walk -- then dereferences it after free().  delrunq() already
	 * removes from anywhere in the list and returns harmlessly when p
	 * is not on it, which is exactly this job.
	 *
	 * Found while looking for unguarded dereferences in disdump()
	 * rather than from a capture: the faults this hunt has in hand
	 * come through the isched.head walk, and that list is unlinked
	 * correctly here.  So this is a real use-after-free with no
	 * observed instance, fixed on inspection.
	 */
	delrunq(p);
	/*
	 * vmachine()'s waserror() loop clears curprog because a Dis
	 * exception leaves xec() by longjmp and "a later Prog allocated at
	 * the same address would be handed the wrong register file" -- its
	 * own words.  That covers non-local exits from the interpreter and
	 * not this: a Prog can reach delprog() while curprog still names
	 * it, and then the name outlives the object with nothing to clear
	 * it.  Observed, not deduced: an assertion in rungc() that
	 * dereferenced curprog printed state 0xdeadbeef, which is the
	 * value written two lines below.
	 *
	 * progreg() compares curprog by pointer, so the damage is exactly
	 * what that comment describes -- once the allocator hands this
	 * address to a new Prog, progreg() gives out curR for a program
	 * whose live registers are somewhere else.
	 */
	if(p == curP->curprog){
		curP->curprog = nil;
		/*
		 * And the quantum with it: there is no quantum once the
		 * program running in it has been freed.
		 *
		 * delprog() releases and reacquires the interpreter while it
		 * closes p's groups (see the comment above disracepid), and
		 * acquire()'s irestore() re-opens a quantum on a Prog that is
		 * about to be destroyed.  Nothing afterwards closes it:
		 * vmachine()'s handler cleared inxec before progexit() ran,
		 * and this path never returns to xec().  The context is then
		 * never at a safepoint again -- with parallelvm=1
		 * stoptheworld() waited on it for the rest of the boot,
		 * "ctx 2 curprog 0x0 set by irestore from closeegrp+0xe,
		 * owner pid 9 dis state Queueing vmheld 0".
		 */
		curP->inxec = 0;
		coherence();
		safepoint();
	}
	p->state = 0xdeadbeef;
	free(o->user);
	free(p->killstr);
	free(p->exstr);
	free(p);
}

void
renameproguser(char *old, char *new)
{
	Prog *p;
	Osenv *o;

	acquire();
	for(p = isched.head; p; p = p->next){
		o = p->osenv;
		if(o->user != nil && strcmp(o->user, old) == 0)
			kstrdup(&o->user, new);
	}
	release();
}

void
tellsomeone(Prog *p, char *buf)
{
	Osenv *o;
	int ret, woke;

	if(waserror())
		return;
	o = p->osenv;
	woke = 0;
	if(o->childq != nil){
		ret = qproduce(o->childq, buf, strlen(buf));
		if(ret == strlen(buf))
			woke = 1;
		else if(ret != strlen(buf))
			print("tellsomeone childq %d/%lud\n", ret, (ulong)strlen(buf));
	}
	if(o->waitq != nil){
		ret = qproduce(o->waitq, buf, strlen(buf));
		if(ret == strlen(buf))
			woke = 1;
		else
			print("tellsomeone waitq %d/%lud\n", ret, (ulong)strlen(buf));
	}
	poperror();
	/*
	 * On a uniprocessor, qproduce's wakeup only readies the waiter.
	 * Yield so the parent can finish Sys_read/acquire before we
	 * release() in delprog and risk a VM handoff deadlock.
	 */
	if(woke && anyready())
		sched();
}

static void
swiprog(Prog *p)
{
	Proc *q, *eq;
	char c[ERRMAX];

	snprint(c, ERRMAX, "interrupted by swiprog 0x%p\n", getcallerpc(&p));
	/* print("swiprog: %s\n", c); */
	q = proctab(0);
	for(eq = q+conf.nproc; q < eq; q++) {
		if(q->iprog == p) {
			/*	postnote(q, 1, "interrupted by swiprog", NUser); */
			postnote(q, 1, c, NUser);
			/* dumpstack(); */
			return;
		}
	}
	print("swigrog: didn't find proc\n");
}

static Prog*
grpleader(Prog *p)
{
	Progs *g;
	Prog *l;

	g = p->group;
	if(g != nil && (l = g->head) != nil && l->pid == g->id)
		return l;
	return nil;
}

int
exprog(Prog *p, char *exc)
{
	switch(p->state) {
	case Palt:
		chanlock();		/* p is queued on every channel of its alt */
		altdone(p->reg.s, p, nil, -1);
		chanunlock();
		break;
	case Psend:
		chanlock();
		cqdelp(&p->chan->send, p);
		chanunlock();
		break;
	case Precv:
		chanlock();
		cqdelp(&p->chan->recv, p);
		chanunlock();
		break;
	case Pready:
		break;
	case Prelease:
		swiprog(p);
		break;
	case Pexiting:
	case Pbroken:
	case Pdebug:
		return 0;
	default:
		panic("exprog - bad state 0x%x\n", p->state);
	}
	if(p->state != Pready && p->state != Prelease)
		addrun(p);
	if(p->kill == nil){
		if(p->killstr == nil){
			p->killstr = malloc(ERRMAX);
			if(p->killstr == nil){
				p->kill = Enomem;
				return 1;
			}
		}
		kstrcpy(p->killstr, exc, ERRMAX);
		p->kill = p->killstr;
	}
	return 1;
}

static void
propex(Prog *p, char *estr)
{
	Prog *f, *nf, *pgl;

	if(!(p->flags & (Ppropagate|Pnotifyleader)) || p->group == nil)
		return;
	if(*estr == 0){
		if((p->flags & Pkilled) == 0)
			return;
		estr = "killed";
	}
	pgl = grpleader(p);
	if(pgl == nil)
		pgl = p;
	if(!(pgl->flags & (Ppropagate|Pnotifyleader)))
		return;	/* exceptions are local; don't propagate */
	for(f = p->group->head; f != nil; f = nf){
		nf = f->grpnext;
		if(f != p && f != pgl){
			if(pgl->flags & Ppropagate)
				exprog(f, estr);
			else{
				f->flags &= ~(Ppropagate|Pnotifyleader);	/* prevent recursion */
				killprog(f, "killed");
			}
		}
	}
	if(p != pgl)
		exprog(pgl, estr);
}

int
killprog(Prog *p, char *cause)
{
	Osenv *env;
	char msg[ERRMAX+2*KNAMELEN];

	if(p == curP->runhd) {
		p->kill = "";
		p->flags |= Pkilled;
		p->state = Pexiting;
		return 0;
	}

	switch(p->state) {
	case Palt:
		chanlock();
		altdone(p->reg.s, p, nil, -1);
		chanunlock();
		break;
	case Psend:
		chanlock();
		cqdelp(&p->chan->send, p);
		chanunlock();
		break;
	case Precv:
		chanlock();
		cqdelp(&p->chan->recv, p);
		chanunlock();
		break;
	case Pready:
		delrunq(p);
		break;
	case Prelease:
		p->kill = "";
		p->flags |= Pkilled;
		p->state = Pexiting;
		swiprog(p);
		/* No break */
	case Pexiting:
		return 0;
	case Pbroken:
	case Pdebug:
		break;
	default:
		panic("killprog - bad state 0x%x\n", p->state);
	}

	if(p->addrun != nil) {
		p->kill = "";
		p->flags |= Pkilled;
		p->addrun(p);
		p->addrun = nil;
		return 0;
	}

	env = p->osenv;
	if(env->debug != nil) {
		p->state = Pbroken;
		dbgexit(p, 0, cause);
		return 0;
	}

	propex(p, "killed");

	/* KenC LP64: one homogeneous arg per snprint */
	{
		int i;

		i = snprint(msg, sizeof(msg), "%d \"", p->pid);
		i += snprint(msg+i, sizeof(msg)-i, "%s", p->reg.M->m->name);
		i += snprint(msg+i, sizeof(msg)-i, "\":");
		snprint(msg+i, sizeof(msg)-i, "%s", cause);
	}

	p->state = Pexiting;
	entertear(p);
	gclock();
	destroystack(&p->reg);
	leavetear();
	delprog(p, msg);
	gcunlock();

	return 1;
}

void
newgrp(Prog *p)
{
	Progs *pg, *g;

	if(p->group != nil && p->group->id == p->pid)
		return;
	g = malloc(sizeof(*g));
	if(g == nil)
		error(Enomem);
	p->flags &= ~(Ppropagate|Pnotifyleader);
	g->id = p->pid;
	g->flags = 0;
	g->child = nil;
	pg = delgrp(p);
	g->head = g->tail = p;
	p->group = g;
	if(pg != nil){
		g->sib = pg->child;
		pg->child = g;
	}
	g->parent = pg;
}

static void
addgrp(Prog *n, Prog *p)
{
	Progs *g;

	n->group = p->group;
	if((g = n->group) != nil){
		n->grpnext = nil;
		if(g->head != nil){
			n->grpprev = g->tail;
			g->tail->grpnext = n;
		}else{
			n->grpprev = nil;
			g->head = n;
		}
		g->tail = n;
	}
}

static Progs*
delgrp(Prog *p)
{
	Progs *g, *pg, *cg, **l;

	g = p->group;
	if(g == nil)
		return nil;
	if(p->grpprev)
		p->grpprev->grpnext = p->grpnext;
	else
		g->head = p->grpnext;
	if(p->grpnext)
		p->grpnext->grpprev = p->grpprev;
	else
		g->tail = p->grpprev;
	p->grpprev = p->grpnext = nil;
	p->group = nil;

	if(g->head == nil){
		/* move up, giving subgroups of groups with no Progs to their parents */
		do{
			if((pg = g->parent) != nil){
				pg = g->parent;
				for(l = &pg->child; *l != nil && *l != g; l = &(*l)->sib)
					;
				*l = g->sib;
			}
			/* put subgroups in new parent group */
			while((cg = g->child) != nil){
				g->child = cg->sib;
				cg->parent = pg;
				if(pg != nil){
					cg->sib = pg->child;
					pg->child = cg;
				}
			}
			free(g);
		}while((g = pg) != nil && g->head == nil);
	}
	return g;
}

void
printgrp(Prog *p, char *v)
{
	Progs *g;
	Prog *q;

	g = p->group;
	print("%s pid %d grp %d pgrp %d: [pid", v, p->pid, g->id, g->parent!=nil?g->parent->id:0);
	for(q = g->head; q != nil; q = q->grpnext)
		print(" %d", q->pid);
	print(" subgrp");
	for(g = g->child; g != nil; g = g->sib)
		print(" %d", g->id);
	print("]\n");
}

int
killgrp(Prog *p, char *msg)
{
	int i, npid, *pids;
	Prog *f;
	Progs *g;

	/* interpreter has been acquired */
	g = p->group;
	if(g == nil || g->head == nil)
		return 0;
	while(g->flags & Pkilled){
		release();
		acquire();
	}
	npid = 0;
	for(f = g->head; f != nil; f = f->grpnext)
		if(f->group != g)
			panic("killgrp");
		else
			npid++;
	/* use pids not Prog* because state can change during killprog (eg, in delprog) */
	pids = malloc(npid*sizeof(int));
	if(pids == nil)
		error(Enomem);
	npid = 0;
	for(f = g->head; f != nil; f = f->grpnext)
		pids[npid++] = f->pid;
	g->flags |= Pkilled;
	if(waserror()) {
		g->flags &= ~Pkilled;
		free(pids);
		nexterror();
	}
	for(i = 0; i < npid; i++) {
		f = progpid(pids[i]);
		if(f != nil && f != currun())
			killprog(f, msg);
	}
	poperror();
	g->flags &= ~Pkilled;
	free(pids);
	return 1;
}

char	changup[] = "channel hangup";

void
killcomm(Progq **q)
{
	Prog *p;
	Progq *f;

	/*
	 * This wakes every prog queued on a channel that has just become
	 * garbage, which means touching run queues and -- for a prog in an
	 * alt -- every other channel that alt names.  It therefore runs
	 * inside the region, and opens one itself: its callers (freechan()
	 * from chanunlock()'s drain, or from the collector's sweep) are all
	 * at depth 0.  chandefer() in this file is what makes that true.
	 */
	chanlock();
	for (f = *q; f != nil; f = *q) {
		*q = f->next;
		p = f->prog;
		free(f);
		if(p == nil)
			break;
		p->ptr = nil;
		switch(p->state) {
		case Prelease:
			/*
			 * swiprog() posts a note, and postnote() qlocks:
			 * a sleeping lock cannot be taken under a spinlock.
			 * Dropping the region here is safe because this
			 * channel's count has already reached zero -- nothing
			 * can reach it to queue on it while the lock is down,
			 * and the queue head has already been advanced past
			 * this cell.
			 */
			chanunlock();
			swiprog(p);
			chanlock();
			break;
		case Psend:
		case Precv:
			p->kill = changup;
			addrun(p);
			break;
		case Palt:
			altgone(p);
			break;
		}
	}
	chanunlock();
}

/*
 * What a placeholder Prog does when somebody runs it: nothing.
 *
 * addprog() builds a zeroed Prog with no module and no code -- it is
 * not a program.  It is queued (execatidle()'s addrun(up->prog), the
 * BusyGC path's pushrun) so the scheduler counts this executor as
 * having work while it collects, and taken off again by delrunq().
 * With the VM lock it could only ever be picked by its own owner, who
 * does not run it.  Without the lock another executor picks it off the
 * queue and calls r->xec, which is nil: "panic: invalid opcode", PC 0,
 * from vmachine+0x47d.  Instrumenting the call named the object
 * outright -- "prog 0x7a7f038 xec 0x0 state 0x4 pid 0 link 0x0" --
 * zeroed, Pready, and not a freed Prog, which carries 0xdeadbeef.
 *
 * Returning is right, not just safe: vmachine() rotates the queue
 * after a quantum, so the placeholder goes to the tail and the real
 * programs behind it run.
 */
static void
idlexec(Prog*)
{
}

void
addprog(Proc *p)
{
	Prog *n;

	if((n = p->prog) == nil) {
		n = malloc(sizeof(Prog));
		if(n == nil)
			panic("no memory");
		p->prog = n;
	} else
		memset(n, 0, sizeof(Prog));
	n->osenv = p->env;
	n->xec = idlexec;
	n->quanta = PQUANTA;
}

static void
cwakeme(Prog *p)
{
	Osenv *o;

	p->addrun = nil;
	o = p->osenv;
	wakeup(o->rend);
}

static int
cdone(void *vp)
{
	Prog *p = vp;

	return p->addrun == nil || p->kill != nil;
}

void
cblock(Prog *p)
{
	Osenv *o;

	p->addrun = cwakeme;
	o = p->osenv;
	o->rend = &up->sleep;
	release();

	/*
	 * To allow cdone(p) safely after release,
	 * p must be currun before the release.
	 * Exits in the error case with the vm acquired.
	 */
	if(waserror()) {
		acquire();
		p->addrun = nil;
		nexterror();
	}
	sleep(o->rend, cdone, p);
	if (p->kill != nil)
		error(Eintr);
	poperror();
	acquire();
}

/*
 * Does this executor own the context curP names?
 *
 * curP follows up (proc.c's sched()), and a process that has never
 * interpreted has no context of its own: sched() leaves it on defpctx,
 * which is also pctxs[0], the context the first interpreter claimed.
 * So a kernel process waking a Dis program -- #p writes (devprog.c),
 * devprof, devbench -- reaches addrun() with curP naming somebody
 * else's local run queue, and links into it.  Under the VM lock that
 * was serialised with the owner and harmless.  Without it, two
 * executors write runhd, runtl and nlocal at once.
 *
 * Go has the same case and the same answer: a wakeup from an M with no
 * P goes on the global queue (globrunqput), not on a P's local one.
 */
/*
 * The channel region.
 *
 * A Dis channel operation -- isend, irecv, alt -- reads a channel's send
 * and recv queues, takes a prog off one of them, moves the value between
 * the two progs' operands, and puts the woken prog on a run queue.  With
 * one interpreter that needed no lock: nothing else could be inside a
 * channel operation at the same time.  With more than one, two
 * interpreters on the same channel both see `c->recv->prog == nil`, both
 * queue themselves to send, and the second's `(*q)->prog = p` in cqadd()
 * overwrites the first -- a prog queued on nothing, never woken -- or one
 * hands the value over while the other is unmarking the same alt, and a
 * prog is put on a run queue twice.  A Prog on two queues is the shape
 * three separate faults in this tree resolved to: it gets freed while
 * still linked, and the context that picks it calls through r->xec into
 * freed memory.  "panic: invalid opcode".
 *
 * This is a single lock for every channel in the system, not one per
 * channel.  An alt spans every channel in the alt at once, so per-channel
 * locks would need an ordering to take them in, and the handoff touches
 * two progs' queues besides.  One lock is the version whose correctness
 * can be read off the code; making it per-channel is a separate change
 * with a measurement to justify it.
 *
 * It is a Lock, not a QLock, so nothing inside the region may sleep or
 * error().  That is not a hope: the three things in there that could
 * were moved out.  cqadd()'s malloc/error(exNomem) became cqfill()
 * before the region (xec.c); altrdy()'s error() became a string returned
 * to xecalt(), raised after the unlock (alt.c); and freeing a Channel
 * inside the region -- which reaches killcomm() and from there every alt
 * the dying channel appears in -- is deferred to chanunlock() by
 * chandefer() below.  What is left reaches lock(&isched.l) through
 * addrun()/gput() and free() through poolfree, both leaf spinlocks; a
 * transitive walk of the region's callees for error/sleep/qlock/malloc
 * comes back with nothing else.
 */
static Lock chanl;
int chanlockon = 1;		/* *chanlock=0 on the boot line; see main.c */
ulong	chandeferred;		/* channel frees moved out of the region */
static ulong chanpendfull;	/* chpend[] was not big enough */
static ulong chanregions;	/* channel operations run */
static ulong chancontend;	/* found another executor already inside one */

void
chanlock(void)
{
	chanregions++;
	if(chanlockon){
		/*
		 * A deliberately racy read of the lock word: it is this
		 * change's positive control.  A clean parallelvm=1 run says
		 * nothing about whether the lock mattered unless something
		 * says two executors were inside a channel operation at the
		 * same time; without this line the measurement cannot tell
		 * "the lock fixed it" from "the race never happened".
		 * Reading key without the lock can only be wrong in the
		 * direction of under-reporting, which is the safe one.
		 */
		if(chanl.key != 0 && chancontend++ == 0)
			print("chanlock: first contention: two executors in a"
				" channel operation at once\n");
		lock(&chanl);		/* lock() bumps up->nlocks: no preemption */
	}
	curP->inchan = 1;
}

void
chanunlock(void)
{
	curP->inchan = 0;
	if(chanlockon)
		unlock(&chanl);
	/*
	 * Now that the region is closed, free the channels destroy() handed
	 * over.  This runs killcomm(), which takes the lock itself -- which
	 * is why it cannot happen above this line.  A killcomm() that opens
	 * a region of its own pushes above nchpend and pops back to it, so
	 * draining by index is safe against that nesting.
	 *
	 * One case reads oddly and is nonetheless right.  killcomm() drops
	 * the region around swiprog(), and the chanunlock() that does so
	 * drains too -- so entries this loop has not reached yet can be
	 * freed there, in the middle of killcomm()'s own loop, rather than
	 * here.  That is the same condition either way: the lock is
	 * released and the depth is zero, which is the whole contract.
	 * They are freed once, earlier, and this loop then finds nothing
	 * left.  Recursion terminates because every entry is a distinct
	 * Channel whose count has already reached zero and the graph is
	 * finite.
	 */
	while(curP->nchpend > 0)
		destroy(curP->chpend[--curP->nchpend]);
}

/*
 * heap.c's destroy() asks this before freeing a Channel.  1 means "not
 * here": either this took a reference and chanunlock() will free it, or
 * the count is already zero and the collector will sweep it.
 */
static int
chandeferfn(void *vh)
{
	Heap *h;

	if(curP == nil || curP->inchan == 0)
		return 0;
	if(curP->nchpend >= nelem(curP->chpend)){
		if(chanpendfull++ == 0)
			print("chanlock: chpend full, channel left to the collector\n");
		return 1;
	}
	h = vh;
	AINC(&h->ref);		/* first: a count of zero is sweepable */
	curP->chpend[curP->nchpend++] = H2D(void*, h);
	if(chandeferred++ == 0)
		print("chanlock: first channel free deferred past the region\n");
	return 1;
}

static int
ownctx(void)
{
	return up != nil && up->pctx != nil && (Pctx*)up->pctx == curP;
}

ulong addrunbroken;	/* MULTICORE INSTRUMENTATION - temporary */
ulong quantumbroke;	/* likewise */
ulong shortran;		/* progs the collector saw short that ran again */
ulong regmoved;		/* saved registers changed between quanta */
ulong regmovedsrc[8], spregress, regmovedtold;
ulong unsynced, unsyncedtold, unsyncedran, unsyncedrantold;
/*
 * *syncfix=0 turns the sync above off, so one kernel measures both
 * arms of it in one batch.  Temporary, like *tearlock and *chanlock.
 */
int syncfix = 1;
static int chainok(Prog*);

void
addrun(Prog *p)
{
	if(up != nil && up->pctx == nil && up->type != Unknown)
		ctxnone++;	/* INSTRUMENTATION: queueing with no context */
	/*
	 * MULTICORE INSTRUMENTATION - temporary.  A Prog made runnable
	 * with a broken frame chain was broken while it sat blocked, by
	 * whoever is readying it now -- the caller pc says which path.
	 * Quanta are already checked on the way in and out and never
	 * fail, so this is the remaining place the damage can be done.
	 */
	p->chainok0 = 1;	/* INSTRUMENTATION: watch it from here */
	if(p != (Prog*)up->prog && !chainok(p))
		if(addrunbroken++ < 4)
			print("addrun: prog %d state %d has a broken chain,"
				" from %#p\n", p->pid, p->state,
				getcallerpc(&p));
	if(p->addrun != 0) {
		p->addrun(p);
		return;
	}
	if(p->state == Pready && p != (Prog *)up->prog)
		panic("addrun of ready prog %8.8p by %8.8zux\n", p, getcallerpc(&p));
	p->state = Pready;
	p->link = nil;
	if(!ownctx()){
		gput(p);		/* not our queue to touch; see ownctx() */
		return;
	}
	if(curP->nlocal >= Runqmax){
		gput(p);		/* local queue full; see gput() */
		return;
	}
	if(curP->runhd == nil)
		curP->runhd = p;
	else
		curP->runtl->link = p;

	curP->runtl = p;
	curP->nlocal++;
}

Prog*
delrun(int state)
{
	Prog *p;

	p = curP->runhd;
	p->state = state;
	curP->runhd = p->link;
	if(p->link == nil)
		curP->runtl = nil;
	curP->nlocal--;

	return p;
}

/* unlink p from c's local queue; 1 if it was there */
static int
unlinkctx(Pctx *c, Prog *p)
{
	Prog *prev, *f;

	prev = nil;
	for(f = c->runhd; f != nil; f = f->link) {
		if(f == p)
			break;
		prev = f;
	}
	if(f == nil)
		return 0;
	if(prev == nil)
		c->runhd = p->link;
	else
		prev->link = p->link;
	if(p == c->runtl)
		c->runtl = prev;
	c->nlocal--;
	return 1;
}

int delrunqother;	/* MULTICORE INSTRUMENTATION - temporary */
int twoctx;		/* progs picked while another context runs them */
ulong chainin, chainout;	/* quanta entered/left with a broken chain */

/*
 * MULTICORE INSTRUMENTATION - temporary.  Does this Prog's frame chain
 * still reach the bottom of its newest extent?  rootset() asks the same
 * question of every Prog it walks; asking it on the way into a quantum
 * and again on the way out says whether a stack was already broken when
 * a context picked it up, or was broken by the quantum just run.
 */
int
progchainokfn(Prog *r)
{
	return chainok(r);
}

static int
chainok(Prog *r)
{
	Stkext *cx;
	uchar *cf;
	int n;

	if(r->reg.EX == nil || r->reg.FP == nil)
		return 1;
	cx = (Stkext*)r->reg.EX;
	for(cf = r->reg.FP, n = 0;
	    n < 4096 && cf >= cx->reg.tos.fu && cf < r->reg.SP; n++){
		if(cf == cx->reg.tos.fu)
			return 1;
		cf = ((Frame*)cf)->fp;
		if(cf == nil)
			return 1;
	}
	return cf == cx->reg.tos.fu;
}

/*
 * Take p off whatever queue it is on.
 *
 * It searched this context's queue and then the global one, and gave
 * up.  With one context that was every queue there was.  With more, a
 * Prog killed while it sits on another context's local queue -- a #p
 * write, a group exiting -- was found nowhere, and delprog() freed it
 * while it was still linked.  The context that owned that queue then
 * picked it and called through r->xec: "panic: invalid opcode", PC
 * 0xb, from vmachine+0x47d.  That is the same fault, with the same
 * signature, that three separate hunts this session ran into.
 *
 * Searching the other contexts reads their queues without their
 * owner's cooperation, which is a race of its own under parallelvm=1;
 * it is a smaller one than freeing a linked Prog, and the right answer
 * -- a Prog naming the context it is queued on, so this asks one queue
 * -- is a change to Prog, not to this function.
 */
void
delrunq(Prog *p)
{
	int i;

	if(unlinkctx(curP, p))
		return;
	for(i = 0; i < npctx; i++)
		if(pctxs[i] != curP && unlinkctx(pctxs[i], p)){
			if(delrunqother++ < 4)
				print("delrunq: prog %d was on another "
					"context's queue: ctx %d owner %d, by proc %d"
					" type %d from %#p\n", p->pid, i,
					pctxs[i]->owner != nil ?
					  ((Proc*)pctxs[i]->owner)->pid : -1,
					up->pid, up->type, getcallerpc(&p));
			return;
		}
	gdel(p);	/* it may be on the global queue instead */
}

Prog*
delruntail(int state)
{
	Prog *p;

	p = curP->runtl;
	delrunq(curP->runtl);
	p->state = state;
	return p;
}

Prog*
currun(void)
{
	return curP->runhd;
}

Prog*
schedmod(Module *m)
{
	Heap *h;
	Type *t;
	Prog *p;
	Modlink *ml;
	Frame *f, *fp;

	ml = mklinkmod(m, 0);

	if(m->origmp != H && m->ntype > 0) {
		t = m->type[0];
		h = nheap(t->size);
		h->t = t;
		AINC(&t->ref);		/* heap.c's own heaptype() does the same */
		ml->MP = H2D(uchar*, h);
		if(ml->MP != H && (uintptr)ml->MP < 0x1000)
			print("schedmod: bad ml->MP %#p right after H2D, h %#p ml %#p\n",
				ml->MP, h, ml);
		newmp(ml->MP, m->origmp, t);
	}

	p = newprog(nil, ml);
	h = D2H(ml);
	ADEC(&h->ref);		/* see newprog(); the count cannot reach 0 here */
	p->reg.PC = m->entry;
	/*
	 * newstack() (libinterp/stack.c) does memmove(p->reg.FP, f, f->t->size)
	 * -- f->t is m->entryt here, the *complete* entry-frame type covering
	 * every local the root module's init() declares, routinely far
	 * bigger than sizeof(Frame).  This used to pass a bare on-stack
	 * `Frame f`, only ever big enough for the Frame header, so the copy
	 * read straight past it into whatever this C function's own stack
	 * frame happened to hold next -- garbage into every local of the
	 * very first Dis Prog run at boot, on every single native startup.
	 * emu/port/dis.c's own schedmod() already carries this exact fix
	 * (and the comment explaining it) from an earlier hunt; this native
	 * copy never got the same fix.  Allocate the real entry-frame size
	 * instead, same as emu.  See doc/inferno-ports.ms.
	 */
	f = mallocz(m->entryt->size, 1);
	fp = f;
	R.s = &fp;
	f->t = m->entryt;
	newstack(p);
	free(f);
	initmem(m->entryt, p->reg.FP);

	return p;
}

void
acquire(void)
{
	Prog *p;

	if(up->pctx == nil && up->type != Unknown)
		up->pctx = claimctx();	/* given up in release(); see claimctx() */
	vmacquire();

	if(up->type == Interp) {
		p = up->iprog;
		up->iprog = nil;
		/*
		 * isave() cleared inxec on the way into the blocking call,
		 * so this context has been at a safepoint for as long as it
		 * slept.  Take the quantum back before touching R, and wait
		 * here if a collection started while it slept: vmacquire()
		 * above waits too, but between that wait and the claim there
		 * is a window, which is what enterquantum() closes.
		 */
		enterquantum();
		irestore(p);
	}
	else
		p = up->prog;

	/*
	 * Unlocked on purpose: the VM lock is held from here until the
	 * matching release(), and nothing touches the run queue without
	 * it.
	 */
	p->state = Pready;
	p->link = curP->runhd;
	curP->runhd = p;
	if(p->link == nil)
		curP->runtl = p;
	curP->nlocal++;
}

void
release(void)
{
	int spawn;

	if(up->type == Interp){
		if(up->iprog != nil)
			panic("Double release (Interp)?");
		up->iprog = isave();
	}else{
		if(((Prog *)up->prog)->state != Pready) panic("double release (GC)?");
		{	/* MULTICORE INSTRUMENTATION - temporary */
			static int told;

			if(curP->runhd != (Prog*)up->prog && told++ < 4)
				print("release: GC proc %d type %d, head is prog %d not its own"
					" (ownctx %d nlocal %d gcworldheld %d) from %#p\n",
					up->pid, up->type,
					curP->runhd != nil ? curP->runhd->pid : -1,
					ownctx(), curP->nlocal, gcworldheld(),
					getcallerpc(&spawn));
		}
		delrun(Prelease);
	}

	/*
	 * This process is about to block.  If programs are left on the run
	 * queue and no interpreter is sitting idle to pick them up, make
	 * one: otherwise a single blocking Dis system call stops every
	 * Limbo program in the system, which is the whole reason this
	 * kernel spawns "dis" processes at all.  isched.creating keeps two
	 * releases in a row from making two.
	 */
	lock(&isched.l);
	spawn = 0;
	/*
	 * The global queue counts as work here.  Testing curP->runhd alone
	 * asks "is there work on THIS context's local queue", which stopped
	 * being the same question as "is there work" the moment a bounded
	 * local queue could overflow.  With Runqmax forced to 1 the boot
	 * stalled: programs sat on the global queue, this test saw an empty
	 * local one, no further interpreter was spawned, and the only one
	 * running parked.  88 scheduler passes in a whole boot, against
	 * 8318 for the same boot at the default bound.
	 */
	if((curP->runhd != nil || isched.ghead != nil)
	&& isched.nidle == 0 && isched.creating == 0){
		isched.creating = 1;
		spawn = 1;
		vmspawns++;	/* MULTICORE INSTRUMENTATION - temporary */
	}
	unlock(&isched.l);

	vmrelease();
	/*
	 * And the context, for the same reason it is given up at the park
	 * point: this process is about to block in a Dis system call and
	 * will not interpret again until acquire().  Holding one across a
	 * blocking call is what kept the high-water mark at 50 to 64 even
	 * once parking returned them -- an interpreter in a syscall never
	 * reaches the park point.  vmrelease() above has flushed the local
	 * queue, so the context holds nothing.  acquire() takes one again
	 * before anything touches curP.
	 */
	lock(&isched.l);
	releasectx();
	unlock(&isched.l);
	wakeidle();

	if(spawn)
		kproc("dis", vmachine, nil, KPDUP);
}

void
iyield(void)
{
	if(up->vmheld == 0)
		return;
	if(up->iprog != nil)
		panic("iyield but iprog, type %d", up->type);
	isched.nyield++;
	vmrelease();
	vmacquire();
}

void
startup(void)
{
	up->type = Interp;
	up->iprog = nil;

	lock(&isched.l);
	isched.creating = 0;
	unlock(&isched.l);

	vmacquire();
}

void
progexit(void)
{
	Prog *r;
	Module *m;
	int broken;
	char *estr, msg[ERRMAX+2*KNAMELEN] = {'\0'};

	estr = up->env->errstr;
	broken = 0;
	DBG("progexit estr %s\n", estr);
	if(emptystr(up->env->errstr) == 0 && strcmp(estr, Eintr) != 0 && strncmp(estr, "fail:", 5) != 0)
		broken = 1;

	r = up->iprog;
	if(r != nil)
		acquire();
	else
		r = currun();

	if(*estr == '\0' && r->flags & Pkilled)
		estr = "killed";

	m = R.M->m;
	if(broken){
		print("[%s] Broken: \"%s\" at 0x%p pid %d\n", m->name, estr, up->env->errpc, up->pid);
		if(1) dumpstack();
	}
	if(r->exval != H)
		DBG("progexit pid %d name %s estr %s exval %p exstr %s\n",
			r->pid, m->name, estr, r->exval, r->exstr);

	// sh.b is matching on fail: not on "<pid> fail: "
	/* KenC LP64: one homogeneous arg per snprint */
	{
		int i;

		i = snprint(msg, sizeof(msg), "%d \"", r->pid);
		i += snprint(msg+i, sizeof(msg)-i, "%s", m->name);
		i += snprint(msg+i, sizeof(msg)-i, "\":");
		snprint(msg+i, sizeof(msg)-i, "%s", estr);
	}
	// snprint(msg, sizeof(msg), "%s", estr);
	DBG("progexit msg %s\n", msg);

	if(up->env->debug != nil) {
		DBG("progexit debug set\n");
		dbgexit(r, broken, estr);
		broken = 1;
		/* must force it to break if in debug */
	}else if(broken && (!keepbroken || strncmp(estr, "out of memory", 13)==0 || memusehigh()))
		broken = 0;	/* don't want them or short of memory */

	if(broken){
		tellsomeone(r, msg);
		r = isave();
		r->state = Pbroken;
		return;
	}
	entertear(r);
	gclock();
	destroystack(&R);
	leavetear();
	delprog(r, msg);
	gcunlock();
}

void
disfault(void *reg, char *msg)
{
	Prog *p;

	USED(reg);

	if(strncmp(msg, Eintr, 6) == 0 || up == nil) {
		print("EMU: faults: %s\n", msg);
		panic("disfault");
	}
	if(up->type != Interp) {
		print("SYS: process %s faults: %s\n", up->text, msg);
		panic("disfault");
	}

	if(up->iprog != nil)
		acquire();

	p = currun();
	if(p == nil)
		panic("Interp faults with no dis prog");

	/* cause an exception in the dis prog. */
print("disfault caller 0x%p\n", getcallerpc(&reg));
	error(msg);
}

void
vmachine(void*)
{
	Prog *r;
	Osenv *o;
	int cycles;
	static int gccounter;

	if(up->pctx == nil)
		up->pctx = claimctx();
	startup();

	/* cleans out the exception stack (error labels) */
	while(waserror()) {
		/*
		 * A Dis exception leaves xec() by longjmp, so the
		 * curP->curprog = nil at the bottom of the handler never
		 * runs and the name would dangle -- past the Prog's own
		 * destruction, in the exit case.  progreg() only compares
		 * the pointer, never follows it, but a later Prog allocated
		 * at the same address would be handed the wrong register
		 * file.  Clear it here, where every non-local exit from the
		 * interpreter lands.  The answer this restores is the right
		 * one: exception.c has already synced p->reg from R on the
		 * path that carries on executing.
		 */
		{	/* MULTICORE INSTRUMENTATION - temporary */
			Prog *was;

			/*
			 * Which longjmp out of xec() leaves a Prog alive with
			 * registers older than its own stack?  The collector
			 * reports Progs that ran hundreds of instructions
			 * since their last sync and are still Pready; this
			 * names the path, the state and the error.
			 */
			was = curP->curprog;
			/*
			 * Sync the registers before this context becomes
			 * stoppable.
			 *
			 * xec()'s exit sync does not run when a Dis exception
			 * leaves by longjmp, so the Prog keeps the register
			 * file it entered the quantum with -- measured, up to
			 * 359 instructions out of date -- while it sits Pready
			 * on a run queue.  Clearing inxec two lines below then
			 * lets a collection start, and rootset() walks that
			 * snapshot: an FP into frames the Prog has since
			 * popped and re-used, a chain that stops on a frame
			 * whose fp a later frame's initmem() overwrote with H,
			 * and the range walk reading a dead call sequence as
			 * live frames.  That is the "bad frame type" tripwire,
			 * and with it every root above the bad frame is lost.
			 *
			 * R is still this Prog's live state here: the longjmp
			 * does not restore it, and handler() below reads it.
			 * handler() syncs again when it rewinds, and progexit()
			 * destroys the Prog; this only makes the snapshot
			 * consistent for the window in between.
			 */
			if(was != nil && syncfix){
				was->reg = R;
				REGSYNCED();
				was->regsrc = 5;	/* INSTRUMENTATION: here */
				was->syncn = was->wmtracen;
			}
			if(was != nil && was->wmtracen > was->syncn){
				unsynced++;
				was->unsyncedmark = 1;
				if(unsyncedtold++ < 6)
					print("vmachine: prog %d left xec without"
						" syncing after %d instructions,"
						" state %d, iprog pid %d, currun pid"
						" %d, err \"%s\"\n",
						was->pid,
						was->wmtracen - was->syncn,
						was->state,
						up->iprog != nil ? ((Prog*)up->iprog)->pid : -1,
						currun() != nil ? currun()->pid : -1,
						up->env->errstr);
			}
		}
		curP->curprog = nil;
		/*
		 * A Dis exception leaves xec() by longjmp, so the clear after
		 * r->xec(r) never runs: without this, onctx stays set on the
		 * Prog that raised and the next legitimate pick reports a
		 * double-run that did not happen -- and real overlaps after
		 * it are masked.  chantest raises constantly, so the counter
		 * was polluted both ways from the first exception on.
		 */
		if(currun() != nil){
			currun()->onctx = 0;
			currun()->xecby = nil;	/* same reason; see xec() */
		}
		curP->inxec = 0;	/* the quantum did not finish; see xec.c */
		coherence();
		safepoint();
		DBG("vmachine waserror() loop up->env->errstr %s\n",  up->env->errstr);
		if(up->type != Interp)
			panic("vmachine: non-interp kproc");
		/*
		 * swiprog() posts a note to the kproc a killed Prog was last
		 * running on, to break it out of a blocking system call.  If
		 * that Prog has since left this kproc and the note lands on
		 * the idle sleep below instead, the Eintr it raises has no
		 * Prog to be delivered to: propex(nil) faulted at +0xb4 here
		 * on riscv64 under smoke.sh, right after a shell script
		 * finished.  It is nobody's exception; go back to the loop.
		 */
		if(up->iprog == nil && currun() == nil && strcmp(up->env->errstr, Eintr) == 0){
			up->env = &up->defenv;
			continue;
		}
		if(up->iprog != nil){
			DBG("vmachine waserror() before acquire up->env->errstr %s\n",  up->env->errstr);
			acquire();
		}
		DBG("vmachine waserror() after acquire up->env->errstr %s\n",  up->env->errstr);
		/*
		 * handler() is what rewrites the Prog's saved registers --
		 * its memmove(&p->reg, &R, sizeof(R)) -- and the collector
		 * reads them.  inxec was cleared at the top of this handler,
		 * so stoptheworld() does not wait for this process and
		 * rootset() can walk p->reg while handler() is partway
		 * through writing it.
		 *
		 * Measured with the corrected probe, which compares rr->SP
		 * against itself rather than against the walk's loop
		 * variable:
		 *
		 *   rr->SP first 0x7a80738 now 0x7a80170 CHANGED
		 *
		 * and 0x7a80170 is FP plus 152, the live frame's size: the
		 * right value, arriving after the walk had taken a stale
		 * one.  Everything downstream -- a bound over popped frames,
		 * stale frame data tiling six steps, a type that is not a
		 * Type, a jump through it -- follows from that.
		 *
		 * An earlier attempt put this around propex() instead, which
		 * is group propagation and touches no registers, and duly
		 * changed nothing over 70 boots.
		 *
		 * Bounded: stoptheworld() gives up after HZ/4 rather than
		 * waiting on this forever.
		 */
		enterquantum();
		if(handler(up->env->errstr) == 0) {
			if(currun() == nil)
				panic("vmachine: error \"%s\" with no current prog", up->env->errstr);
			propex(currun(), up->env->errstr);
			DBG("vmachine waserror() after propex up->env->errstr %s\n",  up->env->errstr);
			progexit();
			DBG("vmachine waserror() after progexit\n");
		}
		curP->inxec = 0;	/* the claim taken before handler() */
		coherence();
		safepoint();
		up->env = &up->defenv;
	}

	cycles = 0;
	for(;;) {
		/*
		 * Keep the clock moving under CPU-bound Dis (Bounce tk update).
		 * On virt, soft timers used to advance only via idlehands→WFI→
		 * clockpoll; a busy interpreter never idled so sys->sleep stalled.
		 */
		clockcheck();

		if(tready(nil) == 0) {
			/*
			 * execatidle() collects and calls addrun/delrunq, so
			 * it wants the VM held.  Parking must not hold it, or
			 * every Limbo program in the system stops here.
			 */
			execatidle();
			vmrelease();
			lock(&isched.l);
			if(tready(nil) == 0){
				/*
				 * Re-checked under isched.l: the VM was given
				 * up above, so another process may have made a
				 * program ready and called wakeidle() before
				 * this one was on the list to be found.
				 */
				up->vmnext = isched.idlevmq;
				isched.idlevmq = up;
				isched.nidle++;
				up->state = Queueing;
				up->pc = getcallerpc(&r);
				releasectx();	/* isched.l held; see claimctx() */
				unlock(&isched.l);
				sched();
				if(up->pctx == nil)	/* before anything uses curP */
					up->pctx = claimctx();
			} else
				unlock(&isched.l);
			vmacquire();
		}

		/*
		 * MULTICORE INSTRUMENTATION - temporary.  maxnrunq says how
		 * many Dis programs are ready at once; this says how much
		 * that costs.  vmlock.head is the queue of kernel processes
		 * blocked in vmacquire(), so a pass that sees it non-nil is
		 * a pass where a runnable interpreter was waiting on the one
		 * global VM lock.  The ratio is the answer to "what would a
		 * per-executor register file buy on this workload", in the
		 * only units that matter: passes spent with someone blocked
		 * over passes total.
		 */
		vmpasses++;
		if(vmlock.head != nil) {
			Proc *w;
			int d = 0;

			vmblocked++;
			/*
			 * The control this counter lacked.  vmblocked rests on
			 * vmlock.head meaning "processes blocked in
			 * qlock(&vmlock)", and would report a plausible
			 * fraction whether or not that is what the field
			 * holds.  qlock() appends up to the head/tail chain
			 * through up->qnext and sleeps it, so every process on
			 * that chain must be in Queueing; one that is not
			 * would mean the field is stale or means something
			 * else, and the fraction above would be measuring
			 * nothing.
			 *
			 * The depth is worth having for its own sake too: the
			 * boolean says a runnable interpreter was waiting, the
			 * depth says how many, which is what a per-executor
			 * register file would actually release.
			 */
			for(w = vmlock.head; w != nil && d < 64; w = w->qnext) {
				d++;
				if(w->state != Queueing && vmqbad++ == 0)
					print("vmq: waiter %d %s state %d, not Queueing"
						" -- vmlock.head is not the wait queue\n",
						w->pid, w->text, w->state);
			}
			if(d > maxvmq) {
				maxvmq = d;
				print("vmq: %d interpreters blocked on the vm lock at once\n", d);
			}
		}

		if(vmlock.head != nil && (curP->runhd == nil || ++cycles > 2)){
			iyield();
			cycles = 0;
		}

		/*
		 * Take from the global queue when the local one is empty,
		 * and every Gqevery picks even when it is not.
		 *
		 * The second half is not optional, and a forced-bound test
		 * proved it: with Runqmax 1 the boot stalled after the shell
		 * spawned.  The round-robin at the foot of this loop only
		 * rotates when runhd != runtl, so a local queue of one never
		 * rotates, the same Prog is picked forever, and everything
		 * that overflowed to the global queue starves.  Go has the
		 * same hazard and the same answer -- schedule() takes from
		 * the global queue every 61st tick regardless of the local
		 * one, precisely so a busy local queue cannot starve it.
		 *
		 * Linked directly rather than through addrun(), which panics
		 * on a Prog already in Pready, and one that reached the
		 * global queue is.
		 */
		if(curP->runhd == nil || (++gqtick % Gqevery) == 0){
			Prog *g;

			if((g = gget()) != nil){
				g->link = curP->runhd;
				curP->runhd = g;
				if(g->link == nil)
					curP->runtl = g;
				curP->nlocal++;
			}
		}

		enterquantum();

		r = curP->runhd;
		if(r != nil) {
			{	/* MULTICORE INSTRUMENTATION - temporary */
				Prog *q;
				int i, n = 0, ready = 0;

				for(q = r; q != nil && n < Runqcap; q = q->link)
					n++;
				/*
				 * The same quantity by an independent path, as
				 * a control on the walk above.  maxnrunq counts
				 * the run-queue links; this counts Progs in
				 * state Pready over isched.head, which is the
				 * list of every Prog and is maintained by
				 * different code.  Two counts that agree are a
				 * measurement; one count is an assertion about
				 * a data structure.
				 *
				 * They should agree, because addrun() sets
				 * Pready exactly when it links, and delrun()
				 * and delrunq() unlink.  A persistent
				 * disagreement would mean one of those paths
				 * leaves a Prog on the queue in another state
				 * or in a state without being queued -- which
				 * is the shape of the delprog() bug fixed
				 * above, where a freed Prog stayed linked.
				 */
				for(q = isched.head; q != nil; q = q->next)
					if(q->state == Pready)
						ready++;
				/*
				 * Every context's local queue, not just this
				 * one.  A Prog on another context's queue is
				 * Pready and invisible to the walk above, so
				 * comparing against this context alone made
				 * the control fire the moment a second
				 * context could hold work -- which is the
				 * control noticing, correctly, that the
				 * structures changed meaning again.  It did
				 * the same when the global queue arrived.
				 */
				for(i = 0; i < npctx; i++)
					if(pctxs[i] != curP)
						n += pctxs[i]->nlocal;
				if(n > maxnrunq){
					maxnrunq = n;
					print("runq: %d dis programs ready at once "
						"(%d by state), cpu%d\n",
						n, ready, m->machno);
				}
				/*
				 * Pready counts Progs on the global queue too,
				 * so the local walk is short by exactly ngq.
				 * Comparing without that term made this fire
				 * the moment the global queue was first used,
				 * which is the control working -- it noticed a
				 * real change in what the structures mean.
				 */
				if(ready != n + isched.ngq && nrunqmismatch++ == 0)
					print("runq: %d linked + %d global but %d in "
						"Pready -- the counts disagree\n",
						n, isched.ngq, ready);
			}
			o = r->osenv;
			/*
			 * A placeholder belongs to the Proc that made it, and
			 * addprog() gave it that Proc's own env -- not a Dis
			 * program's.  idlexec() made it safe to call; this
			 * makes it safe to pick.  Adopting o here would take
			 * another process's pgrp, fgrp and egrp, write
			 * fpuostate into that Osenv below, and leave up->fgrp
			 * pointing there afterwards, since only up->env is put
			 * back.  "incref: bad r 0x300000003" from
			 * fdtochan+0x63 is what a borrowed Fgrp looks like.
			 *
			 * Its own owner still adopts it, which is the case
			 * that existed before any of this and is unchanged.
			 */
			if(r->xec == idlexec && r != (Prog*)up->prog)
				o = up->env;
			up->env = o;
			/* Keep Proc.*grp in sync for #e/#p and namec (pctl updates Osenv). */
			up->pgrp = o->pgrp;
			up->fgrp = o->fgrp;
			up->egrp = o->egrp;

			{	/* MULTICORE INSTRUMENTATION - temporary */
				static int told;

				/*
				 * Naming the object beats inferring it: this
				 * probe identified the placeholder Prog by
				 * printing it, and one *parallelvm=1 run in
				 * three still faults here, so something else
				 * reaches this call without a usable xec.
				 * state 0xdeadbeef separates freed-while-queued
				 * from a second placeholder class.
				 */
				if(r->xec != xec && r->xec != idlexec && told++ < 6)
					print("vmachine: prog %#p xec %#p"
						" state %#x pid %d link %#p"
						" osenv %#p ctx %#p cpu%d\n",
						r, r->xec, r->state, r->pid,
						r->link, r->osenv, curP,
						m->machno);
			}
			{	/* MULTICORE INSTRUMENTATION - temporary */
				int was, okin;

				/*
				 * MULTICORE INSTRUMENTATION - temporary.  Are
				 * the registers this quantum starts from the
				 * ones the last quantum left?  A frame laid
				 * over a live one is what a Prog resuming on a
				 * stale SP would do, and this is the direct
				 * test for that rather than another way of
				 * finding the damage afterwards.
				 */
				if(r->lastsp != nil)
				if(r->reg.FP != r->lastfp || r->reg.SP != r->lastsp
				|| r->reg.EX != r->lastex){
					regmoved++;
					if((uint)r->regsrc < 8)
						regmovedsrc[r->regsrc]++;
					if(r->reg.FP == r->lastfp
					&& r->reg.SP < r->lastsp)
						spregress++;
					if(regmovedtold++ < 4)
						print("vmachine: prog %d resumes"
							" with FP %#p SP %#p EX %#p,"
							" left with %#p %#p %#p,"
							" state %d regsrc %d\n",
							r->pid, r->reg.FP, r->reg.SP,
							r->reg.EX, r->lastfp,
							r->lastsp, r->lastex,
							r->state, r->regsrc);
				}
				if(r->unsyncedmark){
					r->unsyncedmark = 0;
					unsyncedran++;
					if(unsyncedrantold++ < 4)
						print("vmachine: prog %d runs again"
							" after leaving xec unsynced,"
							" %d instructions behind,"
							" state %d\n", r->pid,
							r->wmtracen - r->syncn,
							r->state);
				}
				okin = chainok(r);
				if(r->chainok0 == 2){
					r->chainok0 = 1;
					if(shortran++ < 4)
						print("vmachine: a prog the"
							" collector saw short (pid"
							" %d) is running again,"
							" chain %s\n", r->pid,
							okin ? "intact" : "broken");
				}
				if(!okin)
					if(chainin++ < 3)
						print("vmachine: prog %d entered a"
							" quantum with a broken chain,"
							" state %d, ctx %d\n",
							r->pid, r->state, curP->idx);
				r->chainwasok = okin;
				was = r->onctx;
				if(was != 0 && was != curP->idx + 1){
					if(twoctx++ < 4)
						print("vmachine: prog %d picked by"
							" ctx %d while running on"
							" ctx %d, state %d\n",
							r->pid, curP->idx,
							was - 1, r->state);
				}
				r->onctx = curP->idx + 1;
			}
			fpurestore(up->env->fpuostate);
			r->xec(r);
			up->env->fpuostate = fpusave();
			r->onctx = 0;
			r->lastfp = r->reg.FP;
			r->lastsp = r->reg.SP;
			r->lastex = r->reg.EX;
			if(r->chainwasok && !chainok(r))
				if(chainout++ < 3)
					print("vmachine: prog %d left a quantum"
						" with a broken chain, state %d,"
						" ctx %d\n",
						r->pid, r->state, curP->idx);
			{	/* MULTICORE INSTRUMENTATION - temporary */
				Prog *q;
				int n;

				/*
				 * Every other Prog on this context's queue,
				 * after every quantum: the damage is done to a
				 * Prog that is not running, by something, and
				 * this narrows "something" to one quantum and
				 * names what was running when it happened.
				 */
				for(q = curP->runhd, n = 0; q != nil && n < 64;
				    q = q->link, n++){
					if(q == r || q->chainok0 == 0)
						continue;
					if(chainok(q))
						continue;
					q->chainok0 = 0;
					if(quantumbroke++ < 4)
						print("vmachine: prog %d broken"
							" during a quantum of pid"
							" %d (%s inst %ld), state"
							" %d, ctx %d\n",
							q->pid, r->pid,
							(r->reg.M != H
							 && r->reg.M != nil
							 && r->reg.M->m != nil)
							  ? r->reg.M->m->name : "?",
							(r->reg.M != H
							 && r->reg.M != nil
							 && r->reg.M->m != nil
							 && r->reg.M->m->prog != nil)
							  ? (long)(r->reg.PC
							     - r->reg.M->m->prog)
							  : -1L,
							q->state, curP->idx);
				}
			}

			if(curP->runhd != nil)
			if(r == curP->runhd)
			if(curP->runhd != curP->runtl) {
				curP->runhd = r->link;
				r->link = nil;
				curP->runtl->link = r;
				curP->runtl = r;
			}
			up->env = &up->defenv;
		}
		curP->inxec = 0;	/* claim withdrawn; xec() clears it too */
		coherence();
		safepoint();
		/*
		 * BusyGC like emu (throttled).  Never pushrun when addrun is
		 * set — that panics "pushrun addrun" (seen on virt at
		 * interactive sh with wm/toolbar load).
		 */
		if(curP->runhd != nil)
		if(up->iprog == nil)
		if((++gccounter & 0xFF) == 0){
			r = (Prog*)up->prog;
			if(r != nil && r->addrun == nil){
				gcbusy++;
				up->type = BusyGC;
				pushrun(r);
				collect(isched.head);
				up->type = Interp;
				delrunq(r);
			}
		}
	}
}

void
disinit(void *a)
{
	Prog *p;
	Osenv *o;
	Module *root;
	char *initmod = a;

	/*
	 * Unconditionally, not under parallelvm: a channel operation takes
	 * chanl whatever the setting, so a Channel freed inside one must be
	 * deferred whatever the setting too.  Without this, freechan() ->
	 * killcomm() -> chanlock() is a Lock taken twice by its own holder.
	 */
	chandefer = chandeferfn;
	kproc("fdclose", fdcloseproc, nil, KPDUP);	/* see deferfdclose() */
	atsafepoint = safepoint;	/* see stoptheworld() */
	progchainok = progchainokfn;	/* INSTRUMENTATION - temporary */
	if(gcwalkms > 0)
		gcwalkdelay = gcwalkdelayfn;

	if(waserror()){
		/*
		 * Every "disinit error:" capture this hunt has ever seen
		 * printed no text after the colon -- %r does nothing in
		 * kernel context on this port (libkern/print.c's own
		 * errfmt() unconditionally returns -1; the comment there
		 * says as much: it "works from limbo" via lib9's own
		 * errfmt(), never here).  This swallowed the actual error
		 * on every single capture.  Use the same kgerrstr()+%s
		 * idiom the "loading %s: %s" panic two dozen lines below
		 * already uses instead.  pc64-only, temporary.  See
		 * doc/inferno-ports.ms.
		 */
		kgerrstr(up->genbuf, sizeof up->genbuf);
		panic("disinit error: %s", up->genbuf);
	}

	print("Initial Dis: \"%s\"\n", initmod);

	fmtinstall('D', Dconv);

	addclock0link(accountant, MS2HZ);

	// TODO obsolete? cpuidentify calls fpuinit() fpinit();
	// TODO obsolete? fpsave(&up->env->fpu);

	opinit();
	modinit();
	excinit();

	root = load(initmod);
	if(root == 0) {
		kgerrstr(up->genbuf, sizeof up->genbuf);
		panic("loading \"%s\": %s", initmod, up->genbuf);
	}

	p = schedmod(root);

	memmove(p->osenv, up->env, sizeof(Osenv));
	o = p->osenv;
	incref(o->pgrp);
	incref(o->fgrp);
	if(o->egrp != nil)
		incref(o->egrp);
	if(o->sigs != nil)
		incref(o->sigs);
	o->user = nil;
	kstrdup(&o->user, up->env->user);
	o->errstr = o->errbuf0;
	o->syserrstr = o->errbuf1;

	if(kopen("#c/cons", OREAD) != 0)
		panic("failed to make fd0 from #c/cons");
	kopen("#c/cons", OWRITE);
	kopen("#c/cons", OWRITE);

	poperror();
	vmachine(nil);
}

void
pushrun(Prog *p)
{
	if(p->addrun != nil){
		/* Was panic; under virt+wm this raced BusyGC.  Skip. */
		print("pushrun: prog %#p has addrun (skipped)\n", p);
		return;
	}
	p->state = Pready;
	if(!ownctx()){
		p->link = nil;
		gput(p);		/* not our queue to touch; see ownctx() */
		return;
	}
	p->link = curP->runhd;
	curP->runhd = p;
	if(p->link == nil)
		curP->runtl = p;
	curP->nlocal++;
}

/*
 * One dump of the Dis scheduler's state: who holds the interpreter, who
 * is parked waiting for work, every live Prog, and every live kernel
 * process with the Rendez it is asleep on.  Meant to be called once,
 * from a clock handler, after a stall has set in.
 *
 * NOTE: this is a reimplementation.  An earlier disdump() existed in
 * this tree as uncommitted work and was destroyed by a bad edit while
 * the multicore work was going on; it could not be recovered from any
 * commit or worktree.  os/inferno/raspi3b/clock.c calls this and needs
 * it to link.  What it prints is what its caller's comment said it
 * printed, written fresh against the structures here -- it is not the
 * original text.
 */
void
disdump(void)
{
	static char *pstate[] = {
		"alt", "send", "recv", "debug",
		"ready", "release", "exiting", "broken",
	};
	extern char *statename[];
	char mbuf[64];
	Prog *p;
	Proc *q;
	int i;

	print("\ndis: vmlocked %d nidle %d creating %d runhd %#p runtl %#p\n",
		vmlock.locked, isched.nidle, isched.creating,
		curP->runhd, curP->runtl);
	/* MULTICORE INSTRUMENTATION - temporary */
	print("dis: maxrunq %d, %llud of %llud scheduler passes had an "
		"interpreter blocked on the vm lock\n",
		maxnrunq, vmblocked, vmpasses);
	/* MULTICORE INSTRUMENTATION - temporary */
	print("dis: global runq: %d put, %d got, %d now, bound %d\n",
		gqput, gqget, isched.ngq, Runqmax);
	print("dis: %d contexts claimed of %d, curP %#p, parallelvm %d, stw waits %d\n",
		npctx, MAXPCTX, curP, parallelvm, stwwaits);
	print("dis: stw waits %d, parks %lud, wakes %lud, gave up %d\n",
		stwwaits, stwparks, stwwakes, stwgaveup);
	print("dis: chan regions %lud, contended %lud, frees deferred %lud,"
		" pending overflow %lud, lock %s\n",
		chanregions, chancontend, chandeferred, chanpendfull,
		chanlockon ? "on" : "off");
	{
		extern ulong rootraced;

		print("dis: teardowns %lud, during a collection %lud,"
			" freed under the walk %lud\n",
			tears, tearoverlap, rootraced);
		print("dis: teardowns without a quantum %lud, teardrop %d,"
			" gcwalkdelay %d\n", tearnoquantum, teardrop, gcwalkms);
	}

	/*
	 * Every context's queue, not just this one's.  A stall where a Prog
	 * is Pready and nothing runs it is a question about which queue it
	 * is on and who owns that queue; one context's runhd cannot answer
	 * it.  MULTICORE INSTRUMENTATION - temporary.
	 */
	for(i = 0; i < npctx; i++){
		Pctx *cx = pctxs[i];

		print("dis: ctx %d %#p owner %#p nlocal %d inxec %d inchan %d%s",
			i, cx, cx->owner, cx->nlocal, cx->inxec, cx->inchan,
			cx == curP ? " (this one)" : "");
		for(p = cx->runhd; p != nil; p = p->link)
			print(" [prog %d %s]", p->pid,
				(uint)p->state < nelem(pstate)? pstate[p->state]: "?");
		print("\n");
	}

	for(p = isched.head; p != nil; p = p->next){
		modstatus(&p->reg, mbuf, sizeof mbuf);
		print("dis: prog %d %s %s\n", p->pid,
			(uint)p->state < nelem(pstate)? pstate[p->state]: "?", mbuf);
	}

	for(q = vmlock.head; q != nil; q = q->qnext)
		print("dis: waiting for the vm: proc %d %s\n", q->pid, q->text);

	for(q = isched.idlevmq; q != nil; q = q->vmnext)
		print("dis: parked for work: proc %d %s\n", q->pid, q->text);

	for(i = 0; i < conf.nproc; i++){
		q = proctab(i);
		if(q->state == Dead)
			continue;
		print("dis: proc %d %s %s type %d vmheld %d iprog %#p r %#p sleeppc %#p qpc %#p\n",
			q->pid, q->text, statename[q->state], q->type,
			q->vmheld, q->iprog, q->r, q->sleeppc, q->qpc);
	}
}

/*
 * MULTICORE INSTRUMENTATION - temporary.  A second look, twenty seconds
 * after disdump(), at why a parallelvm=1 -smp 4 boot sits idle with
 * interpreters queued on gcsema and a proc Ready while CPUs halt: what
 * each CPU's clock says, who holds gcsema, and for every proc which CPU
 * it is on, which it last ran on, and whether a timer is pending for it.
 */
void
stalldump(void)
{
	extern int nrdy;
	Proc *q;
	Mach *mm;
	int i;

	print("stall: fastticks %lld nrdy %d\n", (vlong)fastticks(nil), nrdy);
	for(i = 0; i < conf.nmach; i++){
		mm = MACHP(i);
		if(mm == nil)
			continue;
		print("stall: cpu%d ticks %lud proc %d\n", i, (ulong)mm->ticks,
			mm->proc != nil ? mm->proc->pid : -1);
	}
	print("stall: contexts reused %lud, released %lud, queued with none"
		" %lud\n", ctxreused, ctxreleased, ctxnone);
	print("stall: gcsema locked %d head %d gcstw %d by %d npctx %d"
		" phase %d\n",
		gcsema.locked, gcsema.head != nil ? gcsema.head->pid : -1,
		gcstw, gcstwproc != nil ? gcstwproc->pid : -1, npctx, gcphase);
	{
		extern ulong gcnruns;

		print("stall: gcnruns %lud stwwaits %d gcidlepass %llud"
			" gcpartial %llud gaveup %d idlegaveup %d\n",
			gcnruns, stwwaits, gcidlepass, gcpartial, stwgaveup,
			gcidlegaveup);
	}
	{
		extern ulong regstale, handlerbroke, regstalesrc[8];

		print("stall: quanta resumed at an FP the Prog had left %lud"
			" (by regsrc %lud %lud %lud %lud %lud),"
			" handlers leaving a short chain %lud,"
			" longjmps leaving a Prog unsynced %lud (of which ran"
			" again %lud)\n",
			regstale, regstalesrc[0], regstalesrc[1],
			regstalesrc[2], regstalesrc[3], regstalesrc[4],
			handlerbroke, unsynced, unsyncedran);
	}
	{
		extern ulong chainwalks, chainshort;
		extern ulong shortstate[8];
		extern ulong shortringok, shortringshort, shortnoring;
		int si;

		print("stall: stacks walked %lud, chain short of tos.fu %lud,"
			" progs picked while running %d, quanta entered broken"
			" %lud, left broken %lud, readied broken %lud;"
			" broken during a quantum %lud, short ones that ran"
			" again %lud, registers moved between quanta %lud"
			" (by regsrc %lud %lud %lud %lud %lud; SP alone went"
			" back %lud)\n",
			chainwalks, chainshort, twoctx, chainin, chainout,
			addrunbroken, quantumbroke,
			shortran, regmoved, regmovedsrc[0], regmovedsrc[1],
			regmovedsrc[2], regmovedsrc[3], regmovedsrc[4],
			spregress);
		print("stall: short by state:");
		for(si = 0; si < 8; si++)
			print(" %lud", shortstate[si]);
		print("; walked from where it last ran: whole %lud, short %lud,"
			" no ring %lud\n",
			shortringok, shortringshort, shortnoring);
	}
	{
		print("stall: freeFD %lud, in the stopped world %lud, deferred %lud,"
			" fddefer %d, interpreters spawned %lud\n",
			freefds, freefdstw, fdclosedeferred, fddefer, vmspawns);
	}
	for(i = 0; i < npctx; i++)
		print("stall: ctx %d owner %d inxec %d inchan %d nlocal %d\n",
			i, pctxs[i]->owner != nil ? ((Proc*)pctxs[i]->owner)->pid : -1,
			pctxs[i]->inxec, pctxs[i]->inchan, pctxs[i]->nlocal);
	for(i = 0; i < conf.nproc; i++){
		q = proctab(i);
		if(q->state == Dead)
			continue;
		print("stall: proc %d %s %s type %d mach %d mp %d wired %d"
			" tt %d twhen %lld tf %#p pc %#p qpc %#p\n",
			q->pid, q->text, statename[q->state], q->type,
			q->mach != nil ? q->mach->machno : -1,
			q->mp != nil ? q->mp->machno : -1,
			q->wired != nil ? q->wired->machno : -1,
			q->tt != nil, (vlong)q->twhen, q->tf,
			q->sleeppc, q->qpc);
	}
}
