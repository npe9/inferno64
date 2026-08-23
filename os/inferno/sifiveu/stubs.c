#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "interp.h"
#include <dynld.h>

/* jl has no -x export table yet; empty table for dynld/kdynloadfd. */
Dynsym _exporttab[] = { 0, 0, nil };

/*
 * Minimal stubs for 9front/port symbols not yet wired on virt.
 */

int
isaconfig(char *class, int ctlrno, void *isa)
{
	USED(class, ctlrno, isa);
	return 0;
}

int	rdbstarted;

void
notkilled(void)
{
}

ulong
perfticks(void)
{
	uvlong x;

	cycles(&x);
	return (ulong)x;
}

uintptr
dbgpc(Proc *p)
{
	USED(p);
	return 0;
}

void
rdb(void)
{
}

/* EDF scheduler optional — classic Inferno ready queue only */
Edf*
edflock(Proc *p)
{
	USED(p);
	return nil;
}

void
edfunlock(void)
{
}

void
edfrecord(Proc *p)
{
	USED(p);
}

void
edfrun(Proc *p, int edfpri)
{
	USED(p, edfpri);
}

void
edfstop(Proc *p)
{
	USED(p);
}

int
edfready(Proc *p)
{
	USED(p);
	return 0;
}

/*
 * Lightweight timers for tsleep — enough for a uniprocessor virt.
 * twhen is absolute fastticks; clockintr calls timercheck().
 */
static Lock	timerlock;
static Timer	*timerhead;

void
timerset(vlong when)
{
	uvlong now, hznext, w;

	now = fastticks(nil);
	hznext = now + m->cpuhz/HZ;
	if(hznext == now)
		hznext = now + 1;
	w = (uvlong)when;
	if(w < now + 1)
		w = now + 1;
	/* Never push MTIP past the next HZ tick — ticks/NOW must keep moving. */
	if(w > hznext)
		w = hznext;
	*(volatile uvlong*)(uintptr)(CLINT + ClintMtimecmp + 8*BOOT_HART) = w;
}

static void
timerinsert(Timer *nt)
{
	Timer *t, **l;

	for(l = &timerhead; (t = *l) != nil; l = &t->tnext){
		if(t->twhen > nt->twhen)
			break;
	}
	nt->tnext = *l;
	*l = nt;
	nt->tt = (Timers*)1;	/* mark queued; Timers incomplete */
}

void
timeradd(Timer *nt)
{
	Timer *t, **l;
	uvlong now;

	ilock(&timerlock);
	if(nt->tt != nil){
		/* already queued — remove first */
		for(l = &timerhead; (t = *l) != nil; l = &t->tnext){
			if(t == nt){
				*l = nt->tnext;
				break;
			}
		}
		nt->tt = nil;
	}
	now = fastticks(nil);
	if(nt->tns <= 0)
		nt->tns = 1;
	if(nt->tmode == Tperiodic){
		if(nt->twhen == 0)
			nt->twhen = now;
		nt->twhen += (uvlong)((nt->tns * (vlong)m->cpuhz) / 1000000000LL);
	}else
		nt->twhen = now + (uvlong)((nt->tns * (vlong)m->cpuhz) / 1000000000LL);
	if(nt->twhen <= now)
		nt->twhen = now + 1;
	timerinsert(nt);
	if(timerhead == nt)
		timerset(nt->twhen);
	iunlock(&timerlock);
}

void
timerdel(Timer *dt)
{
	Timer *t, **l;

	ilock(&timerlock);
	dt->tmode = Trelative;
	for(l = &timerhead; (t = *l) != nil; l = &t->tnext){
		if(t == dt){
			*l = dt->tnext;
			break;
		}
	}
	dt->tt = nil;
	dt->tnext = nil;
	iunlock(&timerlock);
}

void
timercheck(Ureg *u)
{
	Timer *t;
	uvlong now;
	int mode;

	now = fastticks(nil);
	ilock(&timerlock);
	while((t = timerhead) != nil && t->twhen <= now){
		timerhead = t->tnext;
		t->tt = nil;
		t->tnext = nil;
		mode = t->tmode;
		iunlock(&timerlock);
		if(t->tf)
			(*t->tf)(u, t);
		ilock(&timerlock);
		/* Requeue periodic timers (port/random seed sampling). */
		if(mode == Tperiodic && t->tmode == Tperiodic){
			now = fastticks(nil);
			t->twhen += (uvlong)((t->tns * (vlong)m->cpuhz) / 1000000000LL);
			if(t->twhen <= now)
				t->twhen = now + 1;
			timerinsert(t);
		}
		now = fastticks(nil);
	}
	/*
	 * Do not program mtimecmp here — clockintr picks
	 * min(HZ deadline, timersoon()) so long sleeps cannot starve ticks.
	 */
	iunlock(&timerlock);
}

/* Absolute fastticks of the soonest soft timer, or 0 if none. */
uvlong
timersoon(void)
{
	uvlong when;

	ilock(&timerlock);
	when = 0;
	if(timerhead != nil)
		when = timerhead->twhen;
	iunlock(&timerlock);
	return when;
}
