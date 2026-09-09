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
 * Minimal stubs for 9front/port symbols not yet wired on armv7,
 * mirroring os/inferno/virt/stubs.c.  Unlike virt, there is no
 * separate C-level timerset(vlong) wrapper here: l.s's own
 * timerset(uvlong*) writes CNTP_CVAL directly and clock.c calls it,
 * so only the softirq timer queue (timeradd/timerdel/timercheck/
 * timersoon) lives here.
 */

/*
 * port/portfns.h declares void timerset(s64) -- the generic port-layer
 * hook for arming the next hardware deadline directly.  l.s's own raw
 * CP15 writer is hwtimerset(uvlong*) (named apart specifically to avoid
 * this collision); bridge the two here the same way virt's stubs.c
 * bridges its own vlong-arg timerset into a CLINT store.
 */
void
timerset(s64 when)
{
	uvlong w;

	w = (uvlong)when;
	hwtimerset(&w);
}

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

/* EDF scheduler optional -- classic Inferno ready queue only */
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
 * Lightweight timers for tsleep -- enough for a uniprocessor armv7
 * virt board.  twhen is absolute fastticks; clockintr calls
 * timercheck().
 */
static Lock	timerlock;
static Timer	*timerhead;

/*
 * Nanoseconds to fastticks, without the overflow the obvious
 * expression has.  tns*hz overflows a signed 64-bit multiply once tns
 * passes 2^63/hz -- about 147 seconds against a 62.5MHz counter -- and
 * dhcpclient's thebigsleep() asks for 32400 seconds (T1 of an
 * 86400-second lease) the moment DHCP succeeds.  The wrapped product
 * makes twhen negative, timerinsert() sorts Tval signed so the bad
 * timer takes the head of the queue, and timercheck()'s test against
 * an unsigned now then reads that negative deadline as enormous and
 * stops at the head -- so every timer queued behind it is unreachable
 * and every timed sleep on the machine hangs for good.  Split the
 * conversion into whole seconds plus a scaled remainder: exact, and it
 * cannot overflow for any deadline this side of a thousand years.
 */
static Tval
ns2ticks(vlong ns, uvlong hz)
{
	uvlong s, r;

	if(ns <= 0)
		return 0;
	s = (uvlong)ns / 1000000000ULL;
	r = (uvlong)ns % 1000000000ULL;
	return (Tval)(s * hz + (r * hz) / 1000000000ULL);
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
	Tval now;
	uvlong hz;

	ilock(&timerlock);
	if(nt->tt != nil){
		/* already queued -- remove first */
		for(l = &timerhead; (t = *l) != nil; l = &t->tnext){
			if(t == nt){
				*l = nt->tnext;
				break;
			}
		}
		nt->tt = nil;
	}
	now = (Tval)fastticks(&hz);
	if(nt->tns <= 0)
		nt->tns = 1;
	if(nt->tmode == Tperiodic){
		if(nt->twhen == 0)
			nt->twhen = now;
		nt->twhen += ns2ticks(nt->tns, hz);
	}else
		nt->twhen = now + ns2ticks(nt->tns, hz);
	if(nt->twhen <= now)
		nt->twhen = now + 1;
	timerinsert(nt);
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
	Tval now;
	uvlong hz;
	int mode;

	now = (Tval)fastticks(&hz);
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
			now = (Tval)fastticks(&hz);
			t->twhen += ns2ticks(t->tns, hz);
			if(t->twhen <= now)
				t->twhen = now + 1;
			timerinsert(t);
		}
		now = (Tval)fastticks(&hz);
	}
	/*
	 * Do not program CNTP_CVAL here -- clockintr picks
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
