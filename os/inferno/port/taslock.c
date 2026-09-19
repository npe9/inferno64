#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "edf.h"

long maxlockcycles;
long maxilockcycles;
/*
 * How long interrupts stay masked, which is the term every other
 * latency in this kernel sits on top of.  ilock() masks them and
 * iunlock() restores them, so the interval between the two is exactly
 * the window in which a device interrupt cannot be taken -- and
 * nothing in this tree had ever measured it.  A process admitted to a
 * deadline cannot beat the worst one of these, so it is the first
 * number the real-time work needs; see doc/raspi3b-completion-plan.ms.
 *
 * Off by default and switched on from the console --
 * "echo ilock on >/dev/sysctl", "echo ilock >/dev/sysctl" to read and
 * reset -- because it costs two counter reads on every ilock in the
 * kernel, which is every interrupt and every queue operation.  Off it
 * is one predictable branch.
 *
 * The Lock carries a separate armed bit rather than the sign of the
 * start time, which is what this did first and which does not work
 * here: lcycles() returns a long, kencc's long is 32 bits, and the
 * A53's counter runs at 19.2MHz, so its low half is "negative" for
 * half of every 223 seconds.  On the board the instrument counted 506
 * ilocks early in a boot and then zero for the rest of it, which reads
 * exactly like a quiet kernel and is not.  Subtracting two wrapped
 * 32-bit counts is still right for any interval shorter than that.
 *
 * ILOCKTRACE is defined in a board's mkfile, and a board that defines
 * it owes two things: a "long lockcycles" in its dat.h Lock, and an
 * lcycles() returning a cheap monotonic count (raspi3b/clock.c reads
 * CNTPCT).  Without them this does not compile, which is the intended
 * way to find out.
 */
int ilocktrace;
ulong nilocktraced;
long cumlockcycles;
long cumilockcycles;
uintptr maxlockpc;
uintptr maxilockpc;

struct
{
	ulong	locks;
	ulong	glare;
	ulong	inglare;
} lockstats;

static void
dumplockmem(char *tag, Lock *l)
{
	uchar *cp;
	int i;

	iprint("%s: ", tag);
	cp = (uchar*)l;
	for(i = 0; i < 64; i++)
		iprint("%2.2ux ", cp[i]);
	iprint("\n");
}

void
lockloop(Lock *l, uintptr pc)
{
	extern int panicking;
	Proc *p;

	if(panicking)
		return;

	p = l->p;
	print("lock %#p loop key %#ux pc %#p held by pc %#p proc %ud\n",
		l, l->key, pc, l->pc, p ? p->pid : 0);
	dumpaproc(up);
	if(p != nil)
		dumpaproc(p);
}

/*
	if looped to obtain a lock, return 1. else, return 0
	Why not have a sched() in the waiting loop to give up the processor?
	< ori> the idea is that going through the scheduler takes more time than
	waiting for the other cpu to do the few protected instructions
 */
int
lock(Lock *l)
{
	int i;
	uintptr pc;

	pc = getcallerpc(&l);

	lockstats.locks++;
	if(up)
		up->nlocks++;	/* prevent being scheded */
	if(tas(&l->key) == 0){ /* got the lock on the 1st attempt, done */
		if(up)
			up->lastlock = l;
		l->pc = pc;
		l->p = up;
		l->m = MACHP(m->machno);
		l->isilock = 0;
#ifdef LOCKCYCLES
		l->lockcycles = -lcycles();
#endif
		return 0;
	}
	if(up)
		up->nlocks--;

	lockstats.glare++;
	for(;;){
		lockstats.inglare++;
		i = 0;
		while(l->key){
			if(conf.nmach < 2 && up && up->edf && (up->edf->flags & Admitted)){
				/*
				 * Priority inversion, yield on a uniprocessor; on a
				 * multiprocessor, the other processor will unlock
				 */
				print("inversion %#p pc %#p proc %ud held by pc %#p proc %ud\n",
					l, pc, up != nil ? up->pid : 0, l->pc, l->p != nil ? ((Proc*)l->p)->pid : 0);
				up->edf->d = todget(nil);	/* yield to process with lock */
				up->pc = pc;
				sched();
			}
			if(i++ > 100000000){
				i = 0;
				lockloop(l, pc);
			}
		}
		if(up)
			up->nlocks++;
		if(tas(&l->key) == 0){
			if(up)
				up->lastlock = l;
			l->pc = pc;
			l->p = up;
			l->m = MACHP(m->machno);
			l->isilock = 0;
#ifdef LOCKCYCLES
			l->lockcycles = -lcycles();
#endif
			return 1;
		}
		if(up)
			up->nlocks--;
	}
}

void
ilock(Lock *l)
{
	ulong x;
	uintptr pc;

	pc = getcallerpc(&l);
	lockstats.locks++;

	x = splhi();
	if(tas(&l->key) != 0){
		lockstats.glare++;
		/*
		 * Cannot also check l->pc, l->m, or l->isilock here
		 * because they might just not be set yet, or
		 * (for pc and m) the lock might have just been unlocked.
		 */
		for(;;){
			lockstats.inglare++;
			splx(x);
			while(l->key)
				;
			x = splhi();
			if(tas(&l->key) == 0)
				goto acquire;
		}
	}
acquire:
	m->ilockdepth++;
	if(up)
		up->lastilock = l;
	l->sr = x;
	l->pc = pc;
	l->p = up;
	l->m = MACHP(m->machno);
	l->isilock = 1;
#ifdef ILOCKTRACE
	if(ilocktrace){
		l->lockcycles = lcycles();
		l->lcarmed = 1;
	}
#endif
#ifdef LOCKCYCLES
	l->lockcycles = -lcycles();
#endif
}

int
canlock(Lock *l)
{
	if(up)
		up->nlocks++;
	if(tas(&l->key) != 0){
		if(up)
			up->nlocks--;
		return 0;
	}

	if(up)
		up->lastlock = l;
	/*
	 * This used to raise the caller to PriLock, the top of the
	 * ordinary range, and save what it had in l->priority.  Nothing
	 * ever put it back: l->priority is written here and read
	 * nowhere in the tree, unlock() does not touch the priority, and
	 * lock() never did any of this -- so a successful canlock()
	 * pinned its caller at 20 until the next sched() recomputed it
	 * from basepri.
	 *
	 * That is not an abstract leak.  clockintr() ends with
	 * "if(canlock(&clock0lock))", in interrupt context, where up is
	 * whatever process was interrupted -- so every clock tick left
	 * the running process at priority 20.  Counted on this board:
	 * up->priority was 14 or above on 138 of 256 ticks, and
	 * anyhigher(), which asks whether anything strictly above the
	 * runner is ready, was therefore true on 22.  That is the whole
	 * of the "33 times in 10000" this tree recorded as a fact about
	 * kprocs all sharing PriKproc.  It was a fact about this line.
	 *
	 * Removed rather than repaired, because what it was for --
	 * do not reschedule a process holding a spin lock -- is
	 * up->nlocks, which lock(), canlock() and unlock() maintain
	 * symmetrically and which sched() already honours.  A lock
	 * holder is running, not queued, so its queue priority does not
	 * arise until it has let go.
	 */
	l->pc = getcallerpc(&l);
	l->p = up;
	l->m = MACHP(m->machno);
	l->isilock = 0;
#ifdef LOCKCYCLES
	l->lockcycles = -lcycles();
#endif
	return 1;
}

void
unlock(Lock *l)
{
#ifdef LOCKCYCLES
	l->lockcycles += lcycles();
	cumlockcycles += l->lockcycles;
	if(l->lockcycles > maxlockcycles){
		maxlockcycles = l->lockcycles;
		maxlockpc = l->pc;
	}
#endif
	if(l->key == 0)
		print("unlock(%#p): not locked: pc %#p up->pid %d up->text %s\n",
			l, getcallerpc(&l), up->pid, up->text);
	if(l->isilock)
		print("unlock(%#p) of ilock: pc %#p, held by %#p up->pid %d up->text %s\n",
			l, getcallerpc(&l), l->pc, up->pid, up->text);
	if(l->p != up){
		print("unlock(%#p): up changed: pc %#p, acquired at pc %#p,"
				" lock p %#p, unlock up %#p up->pid %d up->text %s up->mach->machno %d\n",
			l, getcallerpc(&l), l->pc, l->p, up, up->pid, up->text, up->mach->machno);
		dumpaproc(l->p);
		dumpaproc(up);
	}
	l->m = nil;
	coherence();
	l->key = 0;

	if(up && --up->nlocks >= 0 && up->delaysched && islo()){
		/*
		 * Call sched if the need arose while locks were held
		 * But, don't do it from interrupt routines, hence the islo() test
		 */
		sched();
	}
}

uintptr ilockpcs[0x100] = { [0xff] = 1 };
static int n;

void
iunlock(Lock *l)
{
	ulong sr;

#ifdef ILOCKTRACE
	if(ilocktrace && l->lcarmed){
		long d;

		d = lcycles() - l->lockcycles;
		l->lcarmed = 0;
		if(d >= 0){
			cumilockcycles += d;
			nilocktraced++;
			if(d > maxilockcycles){
				maxilockcycles = d;
				maxilockpc = l->pc;
			}
		}
	}
#endif

#ifdef LOCKCYCLES
	l->lockcycles += lcycles();
	cumilockcycles += l->lockcycles;
	if(l->lockcycles > maxilockcycles){
		maxilockcycles = l->lockcycles;
		maxilockpc = l->pc;
	}
	if(l->lockcycles > 2400)
		ilockpcs[n++ & 0xff]  = l->pc;
#endif
	if(l->key == 0)
		print("iunlock(%#p): not locked: pc %#p\n", l, getcallerpc(&l));
	if(!l->isilock)
		print("iunlock(%#p) of lock: pc %#p, held by %#p\n", l, getcallerpc(&l), l->pc);
	if(islo())
		print("iunlock(%#p) while lo: pc %#p, held by %#p\n", l, getcallerpc(&l), l->pc);

	sr = l->sr;
	l->m = nil;
	coherence();
	l->key = 0;
	m->ilockdepth--;
	if(up)
		up->lastilock = nil;
	splx(sr);
}
