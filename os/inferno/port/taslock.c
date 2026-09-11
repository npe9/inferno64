#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "edf.h"

long maxlockcycles;
long maxilockcycles;
long cumlockcycles;
long cumilockcycles;
uintptr maxlockpc;
uintptr maxilockpc;

/*
 * What is left of the instruments this file carried while the pc64 SMP
 * fault was open.  The fault is fixed -- os/inferno/pc64/l.s's
 * _intrestore was reloading m and up out of the interrupted frame, so a
 * process resumed on another processor made that processor's m point at
 * the first one's Mach, and its own correct ilock/iunlock then counted
 * the other processor's depth -- so the per-level holder array, the
 * shadow counter kept outside Mach and the machno-collision detector
 * are gone with it; they cost two array writes on every ilock and their
 * question is answered.
 *
 * The three checks below stay because they are invariants rather than
 * instruments, they cost a compare each, and one of them could not fire
 * at all until pc64's Mach stopped shadowing PMach's ilockdepth with an
 * unsigned field.  A depth that goes negative is the signature the
 * whole hunt turned on, and it is worth catching where it happens
 * rather than at the next sched().
 */

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

	if(up){
		up->lastlock = l;
		l->priority = up->priority;
		up->priority = PriLock;
	}
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

	/*
	 * Released on a different processor than took it.  ilock()
	 * records MACHP(m->machno) in l->m and this is the only place
	 * that can compare the two, which makes it the direct test of
	 * the one story that fits everything seen so far: a balanced
	 * pair whose halves ran on different processors leaves one
	 * Mach's depth up by one and the other's down by one, and each
	 * half looks correct where it stands.
	 */
	if(l->m != nil && l->m != MACHP(m->machno))
		iprint("iunlock(%#p): locked on m %#p, released on m %#p (cpu%d), pc %#p, lock pc %#p\n",
			l, l->m, MACHP(m->machno), m->machno, getcallerpc(&l), l->pc);
	sr = l->sr;
	l->m = nil;
	coherence();
	l->key = 0;
	m->ilockdepth--;
	/*
	 * Caught here rather than at the next sched(), which is where
	 * proc.c notices and which is too late to say who did it: by
	 * then the caller has returned and getcallerpc() names the
	 * scheduler.  The three prints above cover an iunlock of a lock
	 * that is not held, is not an ilock, or is unlocked with
	 * interrupts enabled; none of them covers a depth that has gone
	 * negative while every individual unlock looked correct, which
	 * is what a Compute Engine e2-micro does with ipc64dev and this
	 * laptop does not.
	 */
	if(m->ilockdepth < 0)
		iprint("iunlock(%#p): cpu%d ilockdepth %d, pc %#p, lock pc %#p, m %#p\n",
			l, m->machno, m->ilockdepth,
			getcallerpc(&l), l->pc, m);
	if(up)
		up->lastilock = nil;
	splx(sr);
	/*
	 * The question this answers: something re-enables interrupts
	 * while an ilock is still held, and there is no other way to see
	 * it.  A lock that is simply leaked leaves interrupts masked --
	 * ilock() begins with splhi(), which on pc64 really is CLI --
	 * so no clock interrupt could arrive to trip sched()'s
	 * ilockdepth panic at all.  Yet that panic happens, repeatedly,
	 * with uartkick's tlock recorded as held.  So the enabling is
	 * the bug, not the holding, and this is where it becomes
	 * visible: an iunlock whose saved spl says "interrupts were on"
	 * running while an outer ilock is still held, which is an
	 * out-of-order release.
	 */
	if(m->ilockdepth > 0 && islo()){
		iprint("iunlock: interrupts on at ilockdepth %d, pc %#p, lock pc %#p\n",
			m->ilockdepth, getcallerpc(&l), l->pc);
	}
}
