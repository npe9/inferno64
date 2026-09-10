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
 * The caller of each held ilock, innermost last.  See ilock().
 */
uintptr ilockpc[8];
void *ilockm[8];

/*
 * A shadow of m->ilockdepth kept outside Mach, one per processor,
 * moved at exactly the two places m->ilockdepth is moved.
 *
 * This exists to split one question in two.  Every ilock/iunlock pair
 * this hunt has caught is balanced and local -- poolalloc+0x5b with
 * poolalloc+0x141, timerintr+0x47 with timerintr+0x77, uartkick+0x2b
 * with uartkick+0x4b -- and yet cpu0's depth reaches -1.  Either
 * something writes Mach behind the counter's back, in which case the
 * shadow and the counter part company, or the count really is
 * unbalanced, in which case they go negative together.  They cannot
 * both be true, and until now there was no way to tell which.
 */
int ilockshadow[8];
int ilockshadowbad;

/*
 * The m each machno was first seen with, and a one-shot report when a
 * second Mach turns up claiming the same number.  ilockshadow above is
 * indexed by m->machno, so if two processors ever agree on a machno
 * while disagreeing on m, they race on one shadow word while keeping
 * separate depths -- which would make the shadow the corrupted half,
 * not Mach, and the whole reading backwards.  This says which.
 */
void *ilockmach[8];
int ilockmachbad;

void
ilockheldpcs(void)
{
	int i;

	/*
	 * Unconditional, and first.  A silent return from here reads
	 * exactly like a print that was lost on the way out of a
	 * Compute Engine serial console, and I drew a conclusion from
	 * that silence once already ("the array is all zeros while the
	 * depth is 1") without being able to tell the two apart.
	 */
	iprint("ilockheld: depth %d\n", m->ilockdepth);
	for(i = 0; i < nelem(ilockpc); i++)
		if(ilockpc[i] != 0)
			iprint("  ilock %d held from %#p, m was %#p, m now %#p\n",
				i, (void*)ilockpc[i], ilockm[i], m);
}

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
	/*
	 * Who is holding each level, so that a depth that never comes
	 * back down can be attributed.  sched() and qlock() report the
	 * depth and os/inferno/port/proc.c's panic prints up->lastilock,
	 * which is nil for a lock taken in interrupt context -- exactly
	 * the case that leaks one -- so the depth is all there was to go
	 * on.  ilockpc[] is that missing half; ilockheldpcs() prints it.
	 */
	/*
	 * m->ilockdepth > 0 first.  Written as an unsigned compare
	 * against nelem() alone this indexes ilockpc[-1] whenever the
	 * depth arrives at 0 -- which is to say every time an
	 * already-negative depth is incremented back through zero,
	 * which is the very state this instrument was added to catch.
	 * A tool that corrupts memory in the case it exists to observe
	 * is worse than no tool.
	 */
	if((uint)m->machno < nelem(ilockshadow)){
		if(ilockmach[m->machno] == nil)
			ilockmach[m->machno] = m;
		else if(ilockmach[m->machno] != m && ilockmachbad == 0){
			ilockmachbad = 1;
			iprint("ilock: machno %d claimed by m %#p and m %#p, pc %#p\n",
				m->machno, ilockmach[m->machno], m, pc);
		}
		ilockshadow[m->machno]++;
	}
	if(m->ilockdepth > 0 && m->ilockdepth <= nelem(ilockpc)){
		ilockpc[m->ilockdepth-1] = pc;
		ilockm[m->ilockdepth-1] = m;
	}
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
	if((uint)m->machno < nelem(ilockshadow)){
		ilockshadow[m->machno]--;
		if(ilockshadow[m->machno] != m->ilockdepth && ilockshadowbad == 0){
			ilockshadowbad = 1;
			iprint("iunlock: cpu%d shadow %d but m->ilockdepth %d, m %#p, pc %#p\n",
				m->machno, ilockshadow[m->machno], m->ilockdepth,
				m, getcallerpc(&l));
		}
	}
	if(m->ilockdepth >= 0 && m->ilockdepth < nelem(ilockpc))
		ilockpc[m->ilockdepth] = 0;
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
		iprint("iunlock(%#p): cpu%d ilockdepth %d shadow %d, pc %#p, lock pc %#p, m %#p\n",
			l, m->machno, m->ilockdepth,
			(uint)m->machno < nelem(ilockshadow)? ilockshadow[m->machno]: -1,
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
		/*
		 * And who still holds one.  That is the lock taken while
		 * interrupts were enabled, which is the state that makes
		 * the rest possible: this unlock only restores what its
		 * own ilock saved, so if it turns interrupts back on with
		 * a lock outstanding, the outstanding one was taken in a
		 * context that already had them on.
		 */
		ilockheldpcs();
	}
}
