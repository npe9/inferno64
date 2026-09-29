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
	int	nwoken;		/* woken from it and not yet running again */
	int	nblocked;	/* interpreters between release() and acquire() */
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

/*
 * *disdump=1 on the boot line turns the multicore instrumentation's
 * reporting on.  It is off by default because it is not silent: a dump
 * of every process, every run queue and every VM waiter, once a boot,
 * plus a line each time the VM-lock queue, the run queue or the number
 * of VM holders reaches a new maximum.  The consistency checks beside
 * them -- runq counts that disagree, a waiter not Queueing, a Prog
 * with no usable xec -- are not behind it: those report a fault
 * rather than a measurement, and something is wrong if they print.  That
 * was written for a laptop with a scrollback; on a rented instance the
 * serial console is the only interface there is, and forty seconds
 * into every boot it filled with kernel internals.  The counters run
 * either way -- they cost an increment -- so asking for the dump is
 * all that is behind the flag.
 */
int disdumpon;

/*
 * The scheduler lock, counted the way chanlock() counts itself.
 *
 * With the allocator measured and not the bottleneck -- 8 contended
 * arrivals per thousand at sixteen processors on real hardware -- the
 * next candidates are this lock and the channel lock, and the honest
 * way to choose between them is to count rather than to argue.  The
 * read of the key is racy and can only under-report, which is the safe
 * direction.  Gated on *poolstat, which is now the switch for "measure
 * the locks" generally rather than the pools alone.
 */
ulong schedlocks, schedcontend;

static void
schedlock(void)
{
	extern int poolstat;

	if(poolstat){
		schedlocks++;
		if(isched.l.key != 0)
			schedcontend++;
	}
	lock(&isched.l);
}

/*
 * soakline() is a measurement, not a debugging dump, and it is the only
 * way to divide work done by the quanta it took.  That division is what
 * separates a kernel change from a host that handed the guest fewer
 * cycles per tick, so a measurement boot must be able to have it
 * without also turning on the stall dumps whose cost it would then be
 * measuring.  *soak=... sets this; the line follows the workload.
 */
int soakon;
vlong hostspin;	/* soakline()'s calibration loop writes here */

/*
 * The instrumentation's own print.  Everything this branch added to
 * find its way -- the stall dumps, the soak line, the run-queue
 * watermark, the VM-lock counts, the stopped-world audit -- says what
 * it has to say through here, and says nothing unless *disdump=1 asked
 * for it.  A kernel that prints its own diary at a customer is not a
 * kernel anybody ships, and the counters are worth keeping for the
 * next hunt, so the switch is the answer rather than deletion.
 *
 * Panics, real errors and the boot's own lines still use print().
 */
int
dprint(char *fmt, ...)
{
	int n;
	va_list arg;
	char buf[PRINTSIZE];

	if(!disdumpon)
		return 0;
	va_start(arg, fmt);
	n = vseprint(buf, buf+sizeof(buf), fmt, arg) - buf;
	va_end(arg);
	putstrn(buf, n);
	return n;
}



static Pctx pctxpool[MAXPCTX];
static int npctxused;
int ctxcap = MAXPCTX;	/* how many to hand out; *ctxcap=64 is the old pool */


static Pctx*
claimctx(void)
{
	Pctx *c;

	schedlock();
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
	if(npctxused >= ctxcap || npctxused >= MAXPCTX){
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
		if(said++ == 0){
			if(parallelvm)
				dprint("claimctx: pool of %d exhausted, sharing"
					" -- UNSAFE at parallelvm=1\n", ctxcap);
			else
				dprint("claimctx: pool of %d exhausted, sharing"
					" (correct while the VM lock is held;"
					" the pool wants to be bigger)\n", ctxcap);
		}
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
 * parallelvm is the switch.  At 1 the VM lock is not taken and this is
 * what keeps the collector correct.  At 0 the lock is taken as before
 * and this is inert -- nothing else can be running, so stopping the
 * world stops nothing.
 *
 * It defaults to 1.  The evidence, all of it on rented hardware rather
 * than an emulator, is in doc/multicore-plan.ms:
 *
 *	channel traffic, amd64, 4 Xeons       2.5x   6 instances
 *	module loading, amd64, 4 Xeons        3.7x   6 instances
 *	channel traffic, arm64, 4 Neoverse    4.1x   6 instances
 *
 * Eighteen instances with it on, no panic on any of them, and the
 * lock-on controls returning the same numbers they always have.  The
 * arm64 figures are the tightest of the three -- 21.1, 21.7, 22.5
 * against 88.2, 88.7, 89.1 Dis quanta per tick -- which is half a per
 * cent of spread inside each arm.
 *
 * It defaulted to 0 for a long time and was right to.  The first run of
 * this same measurement panicked on three instances of four, and the
 * cause was real: addgrp() and delgrp() maintained the process-group
 * list with no lock, because a global vmlock had always meant one
 * executor at a time.  Turning this on is only honest now because that
 * is found and fixed, and because *parallelvm=0 still selects the old
 * behaviour for anyone who needs it.
 */
int parallelvm = 1;	/* MULTICORE: 1 = no VM lock, stop-the-world GC */
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
/*
 * How many other contexts are running Dis.
 *
 * inxec, and only inxec, and that is the right predicate rather than a
 * shortcut -- which is worth writing down, because "stoptheworld()
 * waits only for contexts with inxec set, so stopped does not mean
 * quiescent" has been on the open list as a correctness worry since the
 * parallel VM was built.  It is not one, for the collector.
 *
 * What the stopped world is for is rootset(), and what rootset() reads
 * from another context is progreg(): the live register file of a
 * program that is executing right now, because the copy saved in the
 * Prog is a quantum out of date.  inxec is exactly the statement "this
 * context's register file is live", so it is precisely the set that has
 * to be parked.
 *
 * What a context outside xec can still do is two things, and neither
 * costs the collector anything:
 *
 * It can mutate the Dis heap from a system call.  Marking tolerates
 * that by design -- that is what the write barrier and nprop are for --
 * and not by the world being stopped.
 *
 * It can call addrun(), which sets p->state = Pready before it links
 * the Prog onto any queue.  A run-queue audit running in that window
 * sees a program that is ready and in no queue.  That is the one-in-ten
 * thousand disagreement the audit reports: over ten thousand stopped
 * worlds the transient fires about once, and the persistence check that
 * asks whether the SAME pid is still like that at the next audit has
 * never fired at all.  It cannot cost a root either, because roots come
 * from isched.head -- which newprog() and delprog() maintain under
 * isched.l -- and never from the run queues.
 *
 * So the narrow answer is that the audit has a window, not the kernel.
 */
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
int gcidlebusy;		/* idle collections skipped: one already running */
int gcsemaheld;		/* set when collectq() could not take gcsema */

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
/*
 * The same question asked where it can be answered: see auditrunq().
 * *runqaudit=0 turns it off.
 */
int runqaudit = 1;
ulong nrunqaudits, nrunqauditbad, nrunqaudittick;
ulong nrunqauditdup, nrunqauditself, nrunqauditnotlisted, nrunqauditplace;
ulong nrunqauditstuck;	/* ready and unqueued at two audits running */
int nrunqauditsaid;
enum { Runqauditevery = 1000 };
static void auditrunq(void);
static void idlexec(Prog*);	/* the placeholder's xec; see addprog() */

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
				dprint("stw: gave up after %d tries, %lud ticks,"
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
	/*
	 * MULTICORE INSTRUMENTATION - temporary.  The stopped world is the
	 * one instant at which the run-queue counts are comparable: every
	 * other executor is parked at a safepoint, so nothing links,
	 * unlinks or changes state underneath the walk.  The check in
	 * vmachine()'s own loop cannot say that -- it walks structures the
	 * other executors are changing -- so this is where an answer about
	 * the queues themselves comes from.  Every
	 * Runqauditevery'th collection, because it walks every Prog and
	 * every queue and the collector runs hundreds of thousands of times
	 * a boot.
	 */
	if(runqaudit && (++nrunqaudittick % Runqauditevery) == 0)
		auditrunq();
	{
		static ulong said;

		if(stwparks >= said){
			said = said != 0 ? said*10 : 1;
			dprint("stw: %lud parks, %lud wakes, %d waits,"
				" %d gave up\n",
				stwparks, stwwakes, stwwaits, stwgaveup);
		}
	}
	return 1;
}

/*
 * The run queues, counted while the world is stopped.
 *
 * Two things are checked.  The lengths: Progs in state Pready over
 * isched.head, against every context's local queue plus the global one.
 * And the states: a Prog sitting in a queue must be Pready, which is
 * the shape of a leak the length check alone can miss when two errors
 * cancel.
 */
static void
auditrunq(void)
{
	Prog *p, *seen[64];
	int i, j, nq = 0, ready = 0, badstate = 0, dup = 0, self = 0;
	int notlisted = 0, placeheld = 0, unqueuedready = 0;
	static int unqueuedpid;		/* the one seen at the last audit */
	int nextunqueued = 0;

	for(i = 0; i < npctx; i++)
		for(p = pctxs[i]->runhd; p != nil; p = p->link){
			/*
			 * The placeholder Prog addprog() builds is queued on
			 * purpose and is deliberately not on isched.head -- it
			 * is not a program (see the comment on addprog()).  It
			 * is queued and Pready, so counting it made every
			 * audit disagree by exactly the number of executors
			 * collecting: 723 of 723 audits, "queued prog 0 state
			 * 4 is not on isched.head".  An instrument that fires
			 * every time is measuring its own assumption.
			 */
			if(p->xec == idlexec){
				placeheld++;
				continue;
			}
			if(nq < nelem(seen)){
				/*
				 * A Prog in two queues at once, or twice in
				 * one, is the thing a count can only hint at.
				 * The queues are a handful of entries, so the
				 * quadratic scan costs nothing and says which
				 * Prog it is rather than that a number is off.
				 */
				for(j = 0; j < nq; j++)
					if(seen[j] == p){
						dup++;
						if(p == (Prog*)up->prog)
							self++;
						break;
					}
				seen[nq] = p;
			}
			nq++;
			if(p->state != Pready)
				badstate++;
		}
	for(p = isched.ghead; p != nil; p = p->link){
		if(p->xec == idlexec){
			placeheld++;
			continue;
		}
		if(nq < nelem(seen)){
			for(j = 0; j < nq; j++)
				if(seen[j] == p){
					dup++;
					if(p == (Prog*)up->prog)
						self++;
					break;
				}
			seen[nq] = p;
		}
		nq++;
		if(p->state != Pready)
			badstate++;
	}
	for(p = isched.head; p != nil; p = p->next){
		if(p->state != Pready)
			continue;
		ready++;
		/*
		 * Ready and in no queue.  addrun() sets Pready and only
		 * then links, and the stopped world does not exclude an
		 * executor between quanta (see stoptheworld()), so this
		 * is reachable without anything being wrong.  What tells
		 * a transient from a leak is whether the SAME program is
		 * still like this at the next audit, so remember the pid
		 * -- not the pointer, which may be freed by then -- and
		 * look it up again below.
		 */
		for(j = 0; j < nq && j < nelem(seen); j++)
			if(seen[j] == p)
				break;
		if(j == nq || j == nelem(seen)){
			if(p->pid == unqueuedpid && unqueuedpid != 0){
				if(nrunqauditstuck++ == 0)
					dprint("audit: prog %d was ready and unqueued"
						" at two audits running\n", p->pid);
			}
			nextunqueued = p->pid;
			unqueuedready++;
		}
	}
	unqueuedpid = nextunqueued;
	/*
	 * Which Prog, not how many.  A queued Prog that is not on
	 * isched.head is the whole difference between a counting artefact
	 * and a Prog that outlived the list, so ask that question
	 * directly rather than inferring it from two totals.
	 */
	for(j = 0; j < nq && j < nelem(seen); j++){
		for(p = isched.head; p != nil; p = p->next)
			if(p == seen[j])
				break;
		if(p == nil){
			notlisted++;
			if(nrunqauditsaid < 4){
				nrunqauditsaid++;
				dprint("audit: queued prog %d state %d is not on"
					" isched.head (curprog %d, up->prog %d)\n",
					seen[j]->pid, seen[j]->state,
					curP->curprog != nil ? curP->curprog->pid : -1,
					up->prog != nil ? ((Prog*)up->prog)->pid : -1);
			}
		}
	}
	nrunqaudits++;
	nrunqauditnotlisted += notlisted;
	nrunqauditplace += placeheld;
	if(dup != 0)
		nrunqauditdup++;
	if(self != 0)
		nrunqauditself++;
	if((ready != nq && ready != nq - dup) || badstate != 0){
		if(nrunqauditbad++ == 0)
			dprint("audit: %d queued (%d not ready, %d twice, %d of"
				" them this interpreter's own) but %d in Pready"
				" -- the stopped world disagrees\n",
				nq, badstate, dup, self, ready);
	}
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
/*
 * *spawnwoken=0 restores the old spawn test, so one kernel measures
 * both.  The test is "work is ready and no interpreter is idle", and an
 * interpreter that wakeidle() has just taken off the idle queue is
 * neither idle nor running until a processor gets to it -- so on a guest
 * with fewer processors the test is true more often, and the interpreter
 * count grows with scheduler latency rather than with demand.  Measured
 * over twenty minutes: contexts 42, 83, 134 at -smp 2 against 33, 44, 49
 * at -smp 4, same workload.  Temporary, like the rest.
 */
int spawnwoken = 1;
/*
 * A ceiling on interpreters, which the pool size was only ever a
 * mitigation for (*ctxcap raised 64 to 256 and the doc says a harder
 * workload exhausts that too).  The reason to have more interpreters
 * than processors is that some are blocked in a Dis system call and
 * cannot use one; so the rule is that interpreters NOT blocked never
 * outnumber the processors, and each blocked one justifies at most one
 * more.  That is Go's model -- GOMAXPROCS runnable Ms, plus one per M
 * in a syscall -- and unlike a pool size it does not have to be guessed
 * per workload.
 *
 * nvmprocs counts interpreters that have entered vmachine();
 * isched.nblocked counts those between release() and acquire().  A
 * blocked interpreter always leaves room for a new one, so the case
 * this exists for -- every interpreter in a blocking call and work
 * ready -- still spawns.  *spawncap=0 removes the ceiling.
 */
int spawncap = 1;
ulong nvmprocs;		/* interpreters that reached vmachine(); isched.l */
ulong vmspawnsby[8];	/* and by the type of process that made them */
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
			gcunwind();	/* a close can destroy under gclock() */
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
/*
 * *idlesingle=0 lets every idle interpreter queue for its own
 * collection, as before, so one kernel measures both.  Temporary.
 */
int idlesingle = 1;

static int collectq(Prog*, int);

int
collect(Prog *head)
{
	return collectq(head, 0);
}

/*
 * try: do not queue on gcsema, give up if a collection is already
 * running.  execatidle() uses it, because an idle interpreter has
 * nothing to gain by waiting to run a collection somebody else is
 * already running -- and with tens of interpreters idling, queueing is
 * how 6000 collections a boot became 800000, each one a full
 * stop-the-world.
 */
static int
collectq(Prog *head, int try)
{
	int stopped;

	if(try){
		if(!canqlock(&gcsema)){
			gcsemaheld = 1;
			return 0;
		}
		gcsemaheld = 0;
	}else
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
ulong disquanta[MAXMACH];	/* quanta run, per processor; likewise */

static void
gput(Prog *p)
{
	schedlock();
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

	schedlock();
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

	schedlock();
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
				if(disdumpon)
					dprint("nvm: %d hold the vm, cpu%d %s\n",
						n, m->machno, up->text);
			}
		}
	}
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

	schedlock();
	p = isched.idlevmq;
	if(p != nil){
		isched.idlevmq = p->vmnext;
		p->vmnext = nil;
		isched.nidle--;
		isched.nwoken++;	/* see release(); it is not idle and not running */
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
		if(!collectq(isched.head, idlesingle)){
			/*
			 * Two different events, and they were one counter
			 * until this split them: a collection already
			 * running (this interpreter parks, which is the
			 * point of *idlesingle) and stoptheworld() giving
			 * up, which is a collection that did not happen.
			 */
			if(idlesingle && gcsemaheld)
				gcidlebusy++;
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
	schedlock();
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
		/*
		 * Seen once in twelve boots, at the very first Dis process
		 * ("Initial Dis: /osinit.dis"), where proghash cannot
		 * legitimately hold anything yet -- l.s's _clearbss does
		 * clear edata..end, so it is not an unzeroed table.  Say
		 * what is in the way rather than only that something is.
		 * pc64-only, temporary.  See doc/inferno-cloud-plan.ms.
		 */
		panic("dup pid %d: pidnum %d, slot %#p holds prog %#p pid %d",
			n->pid, pidnum, ph, *ph, (*ph)->pid);
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


/*
 * Quarantine for freed Progs, and the reason it exists.
 *
 * A soak run at eight processors with parallelvm=1 died in the
 * allocator: "poolfree:badhdr ... pool main CORRUPT: bad size at
 * 1b223398'3(magic=a110c)".  The block header was otherwise intact --
 * a live MAGIC_A and a plausible allocating pc -- with only the size
 * field holding 3, which is not a size.  The allocating pc resolved to
 * newprog+0x72, so the block was a Prog, and 3 is the sort of number a
 * small enum holds.  That is a write through a Prog pointer whose Prog
 * had already been freed, landing on whatever the allocator had since
 * put there.
 *
 * Freeing immediately makes that invisible: by the time anything
 * notices, the memory belongs to someone else and the evidence is the
 * damage rather than its cause.  So with *progquar=1 a freed Prog is
 * filled with a position-dependent poison and held for Nquar more
 * frees before it goes back.  When it does go back the poison is
 * checked, and a word that changed names its own offset -- and an
 * offset into Prog names a field, and a field names the code that
 * writes it.
 *
 * Off by default; it holds memory and costs a fill per exit.
 */
enum {
	Nquar		= 256,
	Progpoison	= 0x5150524F47444541ULL,	/* "QPROGDEA" */
};

/*
 * The process-group lists, and what they were relying on.
 *
 * addgrp() and delgrp() thread Progs onto a doubly-linked group list
 * and keep g->head and g->tail.  Neither has ever taken a lock.  They
 * did not need one: newprog() calls addgrp() after it has released
 * isched.l, delprog() calls delgrp() before it takes it, and both run
 * with the interpreter acquired -- which, while one global vmlock
 * existed, meant one executor at a time and nothing to race with.
 *
 * parallelvm=1 removes exactly that.  Two executors then run addgrp()
 * and delgrp() on the same group at once, the doubly-linked list tears,
 * and g->tail is left naming a Prog that delprog() has since freed.
 * The next addgrp() to that group does
 *
 *	g->tail->grpnext = n;
 *
 * which writes a Prog pointer into freed memory at offset 0x110 -- and
 * that is precisely what the quarantine caught, repeatedly, word 34 of
 * a poisoned Prog holding a live Prog address.  From there it is the
 * allocator's problem: "pool main CORRUPT: bad size", or a page fault,
 * or a queue block with an impossible wp, depending on what the pool
 * had put in that memory.
 *
 * So the lists get their own lock.  Not isched.l: delgrp() ends by
 * freeing empty parent groups and free() takes the pool's ilock, and
 * keeping that nesting separate from the scheduler's list lock is
 * worth a second lock.  The walks in killgrp(), printgrp() and
 * tellsomeone() call killprog() and exprog() from inside the loop and
 * so cannot hold a spin lock; they are not fixed here, and what
 * protects them for now is that a Prog is unlinked under this lock
 * before it is freed.
 */
static Lock grpl;

int progquar;				/* *progquar=1 */
static Prog *quarbuf[Nquar];
static int quarhd;
static Lock quarl;
static ulong nquarbad, nquarheld;

/*
 * Name the field an offset lands in, from the compiler rather than from
 * arithmetic on the header.  The first capture was read by hand as
 * "0x110 is grpnext, 0x118 is exval", which was a guess about padding
 * and alignment made away from the compiler that did the padding.
 */
static struct {
	char	*name;
	int	off;
} progfield[] = {
	{"reg",		(int)(uintptr)&((Prog*)0)->reg.PC},
	{"xecby",	(int)(uintptr)&((Prog*)0)->xecby},
	{"lastfp",	(int)(uintptr)&((Prog*)0)->lastfp},
	{"link",	(int)(uintptr)&((Prog*)0)->link},
	{"chan",	(int)(uintptr)&((Prog*)0)->chan},
	{"ptr",		(int)(uintptr)&((Prog*)0)->ptr},
	{"state",	(int)(uintptr)&((Prog*)0)->state},
	{"kill",	(int)(uintptr)&((Prog*)0)->kill},
	{"killstr",	(int)(uintptr)&((Prog*)0)->killstr},
	{"pid",		(int)(uintptr)&((Prog*)0)->pid},
	{"prev",	(int)(uintptr)&((Prog*)0)->prev},
	{"next",	(int)(uintptr)&((Prog*)0)->next},
	{"pidlink",	(int)(uintptr)&((Prog*)0)->pidlink},
	{"group",	(int)(uintptr)&((Prog*)0)->group},
	{"grpprev",	(int)(uintptr)&((Prog*)0)->grpprev},
	{"grpnext",	(int)(uintptr)&((Prog*)0)->grpnext},
	{"exval",	(int)(uintptr)&((Prog*)0)->exval},
	{"exstr",	(int)(uintptr)&((Prog*)0)->exstr},
	{"addrun",	(int)(uintptr)&((Prog*)0)->addrun},
	{"xec",		(int)(uintptr)&((Prog*)0)->xec},
	{"osenv",	(int)(uintptr)&((Prog*)0)->osenv},
	{"wmtrace",	(int)(uintptr)&((Prog*)0)->wmtrace[0]},
};

static char*
progfieldat(int off)
{
	int i, best;

	best = -1;
	for(i = 0; i < nelem(progfield); i++)
		if(progfield[i].off <= off
		&& (best < 0 || progfield[i].off > progfield[best].off))
			best = i;
	return best < 0 ? "?" : progfield[best].name;
}

static void
quarantine(Prog *p)
{
	Prog *old;
	uintptr *w;
	int i, n, nq;

	n = (sizeof(Prog)+sizeof(Osenv))/sizeof(uintptr);
	w = (uintptr*)p;
	for(i = 0; i < n; i++)
		w[i] = (uintptr)(Progpoison + i);
	/*
	 * The ring is as deep as the flag says, because a ring that never
	 * wraps is an instrument that cannot fail: hold 256 Progs on a
	 * workload that frees 40 and nothing is ever checked, and the
	 * clean result looks exactly like a clean kernel.  *progquar=16
	 * turns it over quickly and is the setting to start with.
	 */
	nq = progquar;
	if(nq < 1 || nq > Nquar)
		nq = Nquar;
	ilock(&quarl);
	old = quarbuf[quarhd];
	quarbuf[quarhd] = p;
	quarhd = (quarhd+1) % nq;
	nquarheld++;
	iunlock(&quarl);
	if(old == nil)
		return;
	w = (uintptr*)old;
	for(i = 0; i < n; i++)
		if(w[i] != (uintptr)(Progpoison + i)){
			nquarbad++;
			if(nquarbad < 20){
				int j;

				print("progquar: freed Prog %#p word %d offset %#ux"
					" (field %s): expected %#p, found %#p"
					" (%lud bad of %lud held)\n",
					old, i, (int)(i*sizeof(uintptr)),
					progfieldat((int)(i*sizeof(uintptr))),
					(void*)(uintptr)(Progpoison+i), (void*)w[i],
					nquarbad, nquarheld);
				/*
				 * And who still has a name for it.  delprog()
				 * clears curprog only when the Prog being
				 * destroyed is the one THIS context is running;
				 * with parallelvm=1 there are several contexts
				 * and any of them may hold the same pointer,
				 * with nothing to clear it.  If one does, that
				 * is the cause and not just the damage.
				 */
				for(j = 0; j < npctx; j++)
					if(pctxs[j] != nil && pctxs[j]->curprog == old)
						print("progquar: ctx %d still names"
							" the freed Prog %#p, inxec %d\n",
							j, old, pctxs[j]->inxec);
			}
			break;
		}
	free(old);
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
	release();
	closepgrp(o->pgrp);
	closefgrp(o->fgrp);
	closeegrp(o->egrp);
	closesigs(o->sigs);
	acquire();

	delgrp(p);

	schedlock();	/* see newprog(); the same list */
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
		 * closes p's groups while p is still reachable by pid, and
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
	if(progquar)
		quarantine(p);
	else
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

/*
 * A full wait queue is a normal thing under load, and saying so on
 * every occurrence is not a diagnostic, it is a console flood.
 *
 * Measured on a t2a: this one line was most of the output the arm64
 * soak produced, and the parallelvm=1 arm -- which exits more programs
 * per second -- generated about six times the console traffic of the
 * lock-on control.  The arm that drowns its console is the arm whose
 * console dies, which made a uart bug look like a scheduler one.  Four
 * lines and then a count, which is the convention the rest of this
 * file already uses.
 */
ulong nwaitqfull, nchildqfull;

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
		else if(nchildqfull++ < 4)
			print("tellsomeone childq %d/%lud (%lud so far)\n",
				ret, (ulong)strlen(buf), nchildqfull);
	}
	if(o->waitq != nil){
		ret = qproduce(o->waitq, buf, strlen(buf));
		if(ret == strlen(buf))
			woke = 1;
		else if(nwaitqfull++ < 4)
			print("tellsomeone waitq %d/%lud (%lud so far)\n",
				ret, (ulong)strlen(buf), nwaitqfull);
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

	lock(&grpl);
	g = p->group;
	if(g != nil && (l = g->head) != nil && l->pid == g->id){
		unlock(&grpl);
		return l;
	}
	unlock(&grpl);
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
	Prog *f, *pgl;

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
	/*
	 * Snapshot pids under the group lock, then act outside it.
	 *
	 * This used to walk the list live, holding f and its successor
	 * across exprog() and killprog() -- and killprog() reaches
	 * delprog(), which unlinks and frees.  With one executor that was
	 * safe because nothing else ran; with parallelvm=1 another
	 * executor can free f while this loop holds it, which is the same
	 * class of bug as the unlocked addgrp()/delgrp() (see grpl).
	 *
	 * Pids, not pointers, for the reason killgrp() already gives: a
	 * Prog's state can change while this loop runs, and progpid()
	 * returning nil is the correct answer for one that has gone.  No
	 * allocation, because this is an exception path: a fixed batch,
	 * repeated from where it left off, and groups are small.
	 */
	{
		enum { Nbatch = 32 };
		int pids[Nbatch], npid, i, after;

		after = -1;
		for(;;){
			npid = 0;
			lock(&grpl);
			for(f = p->group != nil ? p->group->head : nil;
			    f != nil && npid < Nbatch; f = f->grpnext)
				if(f->pid > after && f != p && f != pgl)
					pids[npid++] = f->pid;
			unlock(&grpl);
			if(npid == 0)
				break;
			after = pids[npid-1];
			for(i = 0; i < npid; i++){
				if((f = progpid(pids[i])) == nil)
					continue;
				if(pgl->flags & Ppropagate)
					exprog(f, estr);
				else{
					f->flags &= ~(Ppropagate|Pnotifyleader);	/* prevent recursion */
					killprog(f, "killed");
				}
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
	gclocksite = "killprog";
	gclock();
	destroystack(&p->reg);
	leavetear();
	delprog(p, msg);
	gcunlock();
	gclocksite = nil;

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
	pg = delgrp(p);		/* takes grpl itself */
	lock(&grpl);
	g->head = g->tail = p;
	p->group = g;
	if(pg != nil){
		g->sib = pg->child;
		pg->child = g;
	}
	g->parent = pg;
	unlock(&grpl);
}

static void
addgrp(Prog *n, Prog *p)
{
	Progs *g;

	lock(&grpl);
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
	unlock(&grpl);
}

static Progs*
delgrp(Prog *p)
{
	Progs *g, *pg, *cg, **l;

	lock(&grpl);
	g = p->group;
	if(g == nil){
		unlock(&grpl);
		return nil;
	}
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
	unlock(&grpl);
	return g;
}

void
printgrp(Prog *p, char *v)
{
	Progs *g;
	Prog *q;

	lock(&grpl);
	g = p->group;
	print("%s pid %d grp %d pgrp %d: [pid", v, p->pid, g->id, g->parent!=nil?g->parent->id:0);
	for(q = g->head; q != nil; q = q->grpnext)
		print(" %d", q->pid);
	print(" subgrp");
	for(g = g->child; g != nil; g = g->sib)
		print(" %d", g->id);
	print("]\n");
	unlock(&grpl);
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
	/*
	 * Both walks under the group lock: the list they count is the
	 * same list addgrp()/delgrp() are free to change on another
	 * processor once parallelvm=1 is set.  Separately, because
	 * malloc() must not run with a spin lock held, and the second
	 * walk clamps to what the first counted in case the group grew
	 * in between.
	 */
	npid = 0;
	lock(&grpl);
	for(f = g->head; f != nil; f = f->grpnext)
		if(f->group != g)
			panic("killgrp");
		else
			npid++;
	unlock(&grpl);
	/* use pids not Prog* because state can change during killprog (eg, in delprog) */
	pids = malloc(npid*sizeof(int));
	if(pids == nil)
		error(Enomem);
	{
		int max;

		max = npid;
		npid = 0;
		lock(&grpl);
		for(f = g->head; f != nil && npid < max; f = f->grpnext)
			pids[npid++] = f->pid;
		unlock(&grpl);
	}
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
/*
 * The scheduler lock, counted the same way chanlock() counts itself.
 *
 * With the allocator measured and not the bottleneck -- 8 contended
 * arrivals per thousand at sixteen processors on real hardware -- the
 * next candidates are this and the channel lock, and the honest way to
 * choose between them is to count rather than to argue.  Racy reads of
 * the key, which can only under-report.
 */

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
			dprint("chanlock: first contention: two executors in a"
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
			dprint("chanlock: chpend full, channel left to the collector\n");
		return 1;
	}
	h = vh;
	AINC(&h->ref);		/* first: a count of zero is sweepable */
	curP->chpend[curP->nchpend++] = H2D(void*, h);
	if(chandeferred++ == 0)
		dprint("chanlock: first channel free deferred past the region\n");
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
ulong gcleaks, gcleaktold;
ulong gcunwound;	/* gclock()s handed back by gcunwind(); see interp.h */
/*
 * *syncfix=0 turns the sync above off, so one kernel measures both
 * arms of it in one batch.  Temporary, like *tearlock and *chanlock.
 */
int syncfix = 1;
static int chainok(Prog*);

void
addrun(Prog *p)
{
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

	vmacquire();

	if(up->type == Interp) {
		schedlock();
		if(isched.nblocked > 0)
			isched.nblocked--;	/* see spawncap */
		unlock(&isched.l);
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
				dprint("release: GC proc %d type %d, head is prog %d not its own"
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
	schedlock();
	spawn = 0;
	if(up->type == Interp)
		isched.nblocked++;	/* see spawncap */
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
	&& isched.nidle == 0 && isched.creating == 0
	&& (spawnwoken == 0 || isched.nwoken == 0)
	&& (spawncap == 0
	   || (long)nvmprocs - isched.nblocked < conf.nmach)){
		isched.creating = 1;
		spawn = 1;
		vmspawns++;	/* MULTICORE INSTRUMENTATION - temporary */
		if((uint)up->type < 8)
			vmspawnsby[up->type]++;
	}
	unlock(&isched.l);

	vmrelease();
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

	schedlock();
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
	gclocksite = "progexit";
	gclock();
	destroystack(&R);
	leavetear();
	delprog(r, msg);
	gcunlock();
	gclocksite = nil;
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
	schedlock();
	nvmprocs++;		/* this interpreter exists from here; see spawncap */
	unlock(&isched.l);
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
		{
			ulong unwound;

			/*
			 * A longjmp out of a gclock() region leaks the count,
			 * and gchalt is a global: the collector is then off
			 * for the rest of the boot.  gcruns() is gchalt == 0,
			 * and boots that sit at a few thousand collections
			 * instead of hundreds of thousands are boots where
			 * this happened.
			 *
			 * Count what gcunwind() gave back, not what gchalt
			 * reads afterwards.  The old test was "gchalt != 0"
			 * here, which is true whenever ANY other executor
			 * holds a gclock at this instant -- so it reported 63
			 * leaks at -smp 2 and 16 at -smp 4 in boots whose
			 * collector ran nearly a million times.  Those were
			 * other contexts working, and this context had leaked
			 * nothing.
			 */
			unwound = gcunwound;
			gcunwind();	/* see gclock() in interp.h */
			unwound = gcunwound - unwound;
			if(unwound != 0){
				if(gcleaktold++ < 6)
					dprint("vmachine: gave back %lud gclock(s)"
						" at the handler, gcdepth %d, site %s,"
						" err \"%s\"\n",
						unwound, GCDEPTH,
						gclocksite != nil ? gclocksite : "none",
						up->env->errstr);
				gcleaks += unwound;
			}
		}
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
					dprint("vmachine: prog %d left xec without"
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
			schedlock();
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
				unlock(&isched.l);
				sched();
				schedlock();
				if(isched.nwoken > 0)	/* running again; see release() */
					isched.nwoken--;
				unlock(&isched.l);
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
					dprint("vmq: waiter %d %s state %d, not Queueing"
						" -- vmlock.head is not the wait queue\n",
						w->pid, w->text, w->state);
			}
			if(d > maxvmq) {
				maxvmq = d;
				if(disdumpon)
					dprint("vmq: %d interpreters blocked on"
						" the vm lock at once\n", d);
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
			if(disdumpon){	/* MULTICORE INSTRUMENTATION - temporary */
				Prog *q;
				int i, n = 0;

				/*
				 * Behind the flag, not merely quiet behind
				 * it: this walks the local queue and every
				 * context's nlocal on every quantum, and a
				 * measurement that costs something on a
				 * kernel nobody is measuring is a bug.
				 */
				for(q = r; q != nil && n < Runqcap; q = q->link)
					n++;
				/*
				 * Every context's local queue, not just this
				 * one.  A Prog on another context's queue is
				 * Pready and invisible to the walk above, so
				 * comparing against this context alone made
				 * the control fire the moment a second
				 * context could hold work.
				 */
				for(i = 0; i < npctx; i++)
					if(pctxs[i] != curP)
						n += pctxs[i]->nlocal;
				if(n > maxnrunq){
					maxnrunq = n;
					if(disdumpon)
						dprint("runq: %d dis programs ready"
							" at once, cpu%d\n",
							n, m->machno);
				}
				/*
				 * The control that used to live here -- the
				 * same total counted a second way, over Progs
				 * in state Pready on isched.head -- is gone,
				 * and not because it was expensive.  It walked
				 * two structures other executors change while
				 * it walked them, so at parallelvm=1 it
				 * disagreed on about three quarters of its
				 * comparisons and said nothing about the
				 * queues; holding isched.l did not help, since
				 * a local queue belongs to its own executor.
				 * auditrunq() asks the same question from
				 * inside stoptheworld(), where the answer
				 * means something, and costs nothing per
				 * quantum.  See doc/multicore-plan.ms.
				 */
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
					dprint("vmachine: prog %#p xec %#p"
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
						dprint("vmachine: prog %d resumes"
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
						dprint("vmachine: prog %d runs again"
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
						dprint("vmachine: a prog the"
							" collector saw short (pid"
							" %d) is running again,"
							" chain %s\n", r->pid,
							okin ? "intact" : "broken");
				}
				if(!okin)
					if(chainin++ < 3)
						dprint("vmachine: prog %d entered a"
							" quantum with a broken chain,"
							" state %d, ctx %d\n",
							r->pid, r->state, curP->idx);
				r->chainwasok = okin;
				was = r->onctx;
				if(was != 0 && was != curP->idx + 1){
					if(twoctx++ < 4)
						dprint("vmachine: prog %d picked by"
							" ctx %d while running on"
							" ctx %d, state %d\n",
							r->pid, curP->idx,
							was - 1, r->state);
				}
				r->onctx = curP->idx + 1;
			}
			/*
			 * MULTICORE INSTRUMENTATION - temporary.  Which
			 * processors actually interpret.  "No panic" on a
			 * second processor means nothing until something says
			 * that processor ran Dis at all -- and this document
			 * has caught a quieter number being a slower kernel
			 * three times already.
			 */
			if((uint)m->machno < nelem(disquanta)){
				if(disquanta[m->machno]++ == 0)
					dprint("dis: first Dis quantum on cpu%d\n",
						m->machno);
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
					dprint("vmachine: prog %d left a quantum"
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
						dprint("vmachine: prog %d broken"
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
	/*
	 * The JIT and the parallel VM together need the code generator to
	 * update Heap.ref atomically, and of the twelve in libinterp only
	 * comp-arm64.c does: it uses LDXRW/STXRW retry loops at all four
	 * sites.  comp-amd64.c and comp-386.c emit a plain Oincrm/Odecrm
	 * on the count -- not one LOCK prefix between them -- and the
	 * others were never audited.
	 *
	 * With one global vmlock that was fine, because only one executor
	 * ran Dis at a time.  parallelvm defaults to 1 now, so it is not,
	 * and the failure is silent: a lost decrement frees an object that
	 * is still referenced, a lost increment leaks one, and neither
	 * says anything at the time.
	 *
	 * Every kernel board in this tree ships cflag=0, so this cannot
	 * fire by default.  It exists because *cflag=1 on a boot line is
	 * one word, and the person typing it should be told rather than
	 * handed a corrupted heap.  The JIT is what gets turned off: it is
	 * a speed option, and running interpreted is slower while running
	 * with a torn reference count is wrong.
	 *
	 * And do not read this as "*parallelvm=0 gets you the JIT".  On
	 * pc64 it does not: "*cflag=1 *parallelvm=0" faults during *init*,
	 * with the VM lock held and no second executor anywhere, so the
	 * amd64 generator is broken on its own account and before any of
	 * this.  That is presumably why every board ships cflag=0 and why
	 * nobody noticed the refcounts.
	 *
	 * It used to say "invalid opcode" and now says "page fault", and
	 * the difference is one bug fixed and one named.  The invalid
	 * opcode was comp-amd64.c writing a four-byte x86 field and then
	 * advancing by IBY2WD, the Dis word size, which is eight here: four
	 * bytes of nothing after every immediate, displacement and branch
	 * offset.  What remains is larger -- it stores 32-bit halves of
	 * 64-bit Dis registers, so the top half of R.FP keeps whatever was
	 * there before -- and wants REX.W through the emitters.  On arm64
	 * the generator does work: all four cells of parallelvm crossed
	 * with cflag reach a shell on virtarm64.  See
	 * scripts/check-arm64-jitmatrix.sh and check-pc64-jitmatrix.sh.
	 */
	{
		extern int cflag, jitrefsatomic, jitpresent;

		/*
		 * No generator at all is the commoner case and it was
		 * silent.  comp-aarch64.c, comp-riscv32.c, comp-riscv64.c
		 * and comp-thumb.c are forty-odd lines whose compile()
		 * returns 0, so on every arm64, riscv and thumb board in
		 * this tree -- raspi3b, virtarm64, virt, virts, spike,
		 * shakti, mangopi, sifiveu, virt32, virt32s, mps2,
		 * teensy41, nucleof303 -- a boot with cflag=1 printed
		 * "jit 1" in its banner and then interpreted every
		 * instruction.  A boot option that reports the opposite of
		 * what it did is worse than one that is not offered.
		 *
		 * Said before the atomics check below, because "there is no
		 * JIT here" is the answer to the question the other message
		 * asks, and printing both would be confusing.
		 */
		if(cflag != 0 && jitpresent == 0){
			print("dis: this build has no code generator for its"
				" architecture -- JIT ignored.\n");
			cflag = 0;
		}
		if(cflag != 0 && parallelvm != 0 && jitrefsatomic == 0){
			print("dis: this code generator updates Heap.ref"
				" without atomics, and *parallelvm=1 would\n");
			print("dis: lose counts through it -- JIT disabled."
				"  See disinit() before turning it back on.\n");
			cflag = 0;
		}
	}
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

	{
		int mi;

		print("\ndis: quanta per cpu:");
		for(mi = 0; mi < conf.nmach && mi < nelem(disquanta); mi++)
			print(" cpu%d %lud", mi, disquanta[mi]);
		print("\n");
	}
	dprint("dis: vmlocked %d nidle %d creating %d runhd %#p runtl %#p\n",
		vmlock.locked, isched.nidle, isched.creating,
		curP->runhd, curP->runtl);
	/* MULTICORE INSTRUMENTATION - temporary */
	dprint("dis: maxrunq %d, %llud of %llud scheduler passes had an "
		"interpreter blocked on the vm lock\n",
		maxnrunq, vmblocked, vmpasses);
	/* MULTICORE INSTRUMENTATION - temporary */
	print("dis: global runq: %d put, %d got, %d now, bound %d\n",
		gqput, gqget, isched.ngq, Runqmax);
	print("dis: %d contexts claimed of %d, curP %#p, parallelvm %d, stw waits %d\n",
		npctx, MAXPCTX, curP, parallelvm, stwwaits);
	print("dis: stw waits %d, parks %lud, wakes %lud, gave up %d\n",
		stwwaits, stwparks, stwwakes, stwgaveup);
	print("dis: sched lock taken %lud, held on arrival %lud\n",
		schedlocks, schedcontend);
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

	dprint("stall: fastticks %lld nrdy %d\n", (vlong)fastticks(nil), nrdy);
	for(i = 0; i < conf.nmach; i++){
		mm = MACHP(i);
		if(mm == nil)
			continue;
		dprint("stall: cpu%d ticks %lud proc %d\n", i, (ulong)mm->ticks,
			mm->proc != nil ? mm->proc->pid : -1);
	}
	/*
	 * Is the collector keeping up?  A stop-the-world collector that
	 * runs less often than the one the VM lock allowed would show here
	 * as a Dis heap that keeps growing, and nothing else in this
	 * document measures that.
	 */
	{	/* pool sizes; Pool is opaque outside alloc.c, so use its own reader */
		char pbuf[400];
		int pn;

		pn = poolread(pbuf, sizeof pbuf - 1, 0);
		pbuf[pn] = 0;
		dprint("stall: pools (cursize maxsize hw nalloc nfree nbrk max name)\n%s\n",
			pbuf);
	}
	dprint("stall: gcsema locked %d head %d gcstw %d by %d npctx %d"
		" phase %d\n",
		gcsema.locked, gcsema.head != nil ? gcsema.head->pid : -1,
		gcstw, gcstwproc != nil ? gcstwproc->pid : -1, npctx, gcphase);
	{
		extern ulong gcnruns, gcranheld;
		extern int gchalt, gcdepth;

		dprint("stall: gcnruns %lud stwwaits %d gcidlepass %llud"
			" gcpartial %llud gaveup %d idlegaveup %d idlebusy %d,"
			" gchalt %d gcdepth %d, gclocks given back %lud, site %s,"
			" collections inside a gclock %lud\n",
			gcnruns, stwwaits, gcidlepass, gcpartial, stwgaveup,
			gcidlegaveup, gcidlebusy, gchalt, GCDEPTH, gcleaks,
			gclocksite != nil ? gclocksite : "none", gcranheld);
	}
	{
		extern ulong regstale, handlerbroke, regstalesrc[8];

		dprint("stall: quanta resumed at an FP the Prog had left %lud"
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

		dprint("stall: stacks walked %lud, chain short of tos.fu %lud,"
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
		dprint("stall: short by state:");
		for(si = 0; si < 8; si++)
			print(" %lud", shortstate[si]);
		print("; walked from where it last ran: whole %lud, short %lud,"
			" no ring %lud\n",
			shortringok, shortringshort, shortnoring);
	}
	{
		dprint("stall: stopped-world audits %lud, bad %lud,"
			" a Prog queued twice %lud (its own %lud), queued but not"
			" listed %lud, placeholders skipped %lud, ready and"
			" unqueued twice running %lud\n",
			nrunqaudits, nrunqauditbad, nrunqauditdup, nrunqauditself,
			nrunqauditnotlisted, nrunqauditplace, nrunqauditstuck);
		dprint("stall: freeFD %lud, in the stopped world %lud, deferred %lud,"
			" fddefer %d, nwoken %d, interpreters spawned %lud"
			" (by type %lud %lud %lud %lud %lud)\n",
			freefds, freefdstw, fdclosedeferred, fddefer,
			isched.nwoken, vmspawns,
			vmspawnsby[0], vmspawnsby[1], vmspawnsby[2],
			vmspawnsby[3], vmspawnsby[4]);
	}
	for(i = 0; i < npctx; i++)
		if(pctxs[i]->gcheld != 0 || pctxs[i]->inxec || pctxs[i]->nlocal)
			dprint("stall: ctx %d owner %d (%s) inxec %d inchan %d"
				" nlocal %d gcheld %d\n",
				i, pctxs[i]->owner != nil ? ((Proc*)pctxs[i]->owner)->pid : -1,
				pctxs[i]->owner != nil ? ((Proc*)pctxs[i]->owner)->text : "?",
				pctxs[i]->inxec, pctxs[i]->inchan,
				pctxs[i]->nlocal, pctxs[i]->gcheld);
	{
		int held = 0;

		for(i = 0; i < npctx; i++)
			held += pctxs[i]->gcheld;
		dprint("stall: gchalt %d, held by contexts %d, defpctx %d\n",
			gchalt, held, defpctx->gcheld);
	}
	for(i = 0; i < conf.nproc; i++){
		q = proctab(i);
		if(q->state == Dead)
			continue;
		dprint("stall: proc %d %s %s type %d mach %d mp %d wired %d"
			" tt %d twhen %lld tf %#p pc %#p qpc %#p\n",
			q->pid, q->text, statename[q->state], q->type,
			q->mach != nil ? q->mach->machno : -1,
			q->mp != nil ? q->mp->machno : -1,
			q->wired != nil ? q->wired->machno : -1,
			q->tt != nil, (vlong)q->twhen, q->tf,
			q->sleeppc, q->qpc);
	}
}

/*
 * MULTICORE INSTRUMENTATION - temporary.  One line every two minutes,
 * for the long run: is the heap flat, is the collector still running,
 * and how many contexts are in use.  The 60/70-second dump answers that
 * for a 90-second boot and says nothing about twenty minutes.
 */
void
soakline(void)
{
	extern ulong gcnruns;
	extern int gchalt;
	char pbuf[400];
	char *p, *e;
	int pn;

	pn = poolread(pbuf, sizeof pbuf - 1, 0);
	pbuf[pn] = 0;
	/*
	 * Find the heap pool by name, not by position: picking "the second
	 * line" prints a different pool's numbers the day one is added or
	 * reordered, and nothing in the log would say so.
	 */
	if((p = strstr(pbuf, " heap")) != nil){
		while(p > pbuf && p[-1] != '\n')
			p--;
		if((e = strchr(p, '\n')) != nil)
			*e = 0;
	}else
		p = pbuf;
	print("soak: %lud ticks, gcnruns %lud, gchalt %d, npctx %d, pools %s\n",
		(ulong)MACHP(0)->ticks, gcnruns, gchalt, npctx, p);
	/*
	 * How much machine did the host actually give us?
	 *
	 * Everything else on this line is work per guest tick, and a guest
	 * tick is wall time: on a shared machine it buys however many
	 * cycles the host felt like handing over, so two boots of the same
	 * kernel can differ by a quarter with nothing in the kernel to
	 * show for it.  That is not hypothetical, it is what four Compute
	 * Engine instances did.
	 *
	 * This loop is the control.  It runs a fixed number of times, it
	 * touches nothing but registers, and it is timed with the cycle
	 * counter -- so no mapping, allocator or scheduler decision can
	 * move it, and the only thing that can is the processor being
	 * taken away or run slower.  Interrupts off, and the smallest of
	 * five runs, because a sample that was interrupted is longer and
	 * never shorter.
	 *
	 * Divide quanta per tick by this and what is left is the kernel.
	 * Do not divide by anything the kernel itself produces: dividing
	 * chantest by Dis quanta looked like the same idea and was not,
	 * because chantest does a fixed amount of Dis work and the ratio
	 * is a constant of the program.  A normaliser has to be able to
	 * see the machine change.  This one was checked against a laptop
	 * loaded to half speed; that one could not.
	 */
	{
		static uvlong hostfloor = ~0ULL;
		uvlong c0, c1, best;
		int i, k, s;
		vlong v;

		best = ~0ULL;
		for(k = 0; k < 5; k++){
			s = splhi();
			v = k;
			cycles(&c0);
			for(i = 0; i < 100000; i++)
				v += i ^ (v >> 3);
			cycles(&c1);
			splx(s);
			hostspin = v;		/* v is live, so the loop stays */
			if(c1 - c0 < best)
				best = c1 - c0;
		}
		/*
		 * The floor across the whole boot, not just this sample.
		 *
		 * splhi() masks the guest's interrupts and does nothing
		 * about the hypervisor's: a vCPU can be taken away in the
		 * middle of the loop, and then the cycle counter -- which is
		 * the host's -- keeps running while the guest does not.  That
		 * inflates a sample and can never deflate one, so the minimum
		 * of five is only right when at least one of the five ran
		 * uninterrupted.
		 *
		 * Measured, and it is not rare.  Nine Compute Engine
		 * instances: one reported 452320 on its first line and 247086
		 * on its second, the same machine; and the two highest
		 * readings in the batch belonged to the two fastest
		 * instances.  A single high reading means "preempted during
		 * all five", not "slow host", and reading it the other way is
		 * how this branch nearly got a fourth number that measured
		 * something else.
		 *
		 * So keep the smallest ever seen.  It converges to the
		 * machine's uninterrupted speed and each later line can only
		 * lower it; this line's own minimum is printed beside it so a
		 * log still shows how much the host was taking away.
		 */
		if(best < hostfloor)
			hostfloor = best;
		print("soak: host %llud cycles for 100000 spins (floor %llud)\n",
			best, hostfloor);
	}
	/*
	 * Here as well as in stalldump(), because on a board whose console
	 * tail is unreliable a long dump loses its last lines and this one
	 * line does not.  MULTICORE INSTRUMENTATION - temporary.
	 */
	print("soak: interpreters %lud, blocked %d, idle %d, woken %d, nmach %d,"
		" spawncap %d, waitq full %lud, childq full %lud\n",
		nvmprocs, isched.nblocked, isched.nidle, isched.nwoken,
		conf.nmach, spawncap, nwaitqfull, nchildqfull);
	{
		extern void poolstatline(void);

		poolstatline();
		if(schedlocks != 0)
			print("soak: sched lock taken %lud times, held on"
				" arrival %lud (%lud per thousand);"
				" chan regions %lud, contended %lud\n",
				schedlocks, schedcontend,
				(schedcontend * 1000) / schedlocks,
				chanregions, chancontend);
	}
	print("soak: stopped-world audits %lud, bad %lud, a Prog queued twice"
		" %lud (its own %lud), queued but not listed %lud, placeholders"
		" skipped %lud, ready and unqueued twice running %lud; quanta",
		nrunqaudits, nrunqauditbad, nrunqauditdup, nrunqauditself,
		nrunqauditnotlisted, nrunqauditplace, nrunqauditstuck);
	{
		int mi;

		for(mi = 0; mi < conf.nmach && mi < nelem(disquanta); mi++)
			print(" cpu%d %lud", mi, disquanta[mi]);
		print("\n");
	}
}
