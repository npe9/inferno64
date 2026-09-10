#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"

typedef struct Clock0link Clock0link;
struct Clock0link {
	void		(*clock)(void);
	Clock0link*	link;
};

static Clock0link *clock0link;
static Lock clock0lock;

extern void	timercheck(Ureg*);
extern void	(*kproftick)(ulong);

static uvlong
now(void)
{
	uvlong u;

	cycles(&u);
	return u;
}

/* Next deadline: HZ period, or sooner soft timer if one is pending. */
uvlong
timernext(uvlong hznext)
{
	uvlong t;

	t = timersoon();
	if(t != 0 && t < hznext)
		return t;
	return hznext;
}

Timer*
addclock0link(void (*clock)(void), int)
{
	Clock0link *lp;

	if((lp = malloc(sizeof(Clock0link))) == 0){
		print("addclock0link: too many links\n");
		return nil;
	}
	ilock(&clock0lock);
	lp->clock = clock;
	lp->link = clock0link;
	clock0link = lp;
	iunlock(&clock0lock);
	return nil;
}

void
clockintr(Ureg *u)
{
	Clock0link *lp;
	uvlong n, hznext, when;

	n = now();
	hznext = n + m->cpuhz/HZ;
	hwtimerset(&hznext);		/* clear the condition; final deadline set below */

	if(kproftick != nil && u != nil)
		kproftick((ulong)u->pc);

	m->ticks++;
	checkalarms();
	timercheck(u);

	n = now();
	hznext = n + m->cpuhz/HZ;
	when = timernext(hznext);
	if(when <= n)
		when = n + 1;
	hwtimerset(&when);

	if(canlock(&clock0lock)){
		for(lp = clock0link; lp; lp = lp->link)
			if(lp->clock)
				lp->clock();
		unlock(&clock0lock);
	}
}

/*
 * A processor that is not in the scheduler, on its own timer.  It
 * re-arms and counts and does nothing else: clockintr()'s
 * checkalarms() and timercheck() belong to the scheduler, and the
 * clock0link list is one list for the machine.  m->ticks is per-Mach,
 * so this is the counter that says whether this processor's own
 * redistributor, its own PPI and its own generic timer are alive.
 */
void
clocksecondary(void)
{
	uvlong when;

	when = now() + m->cpuhz/HZ;
	hwtimerset(&when);
	m->ticks++;
}

void
clockinit(void)
{
	uvlong freq, when;

	cntfrq(&freq);
	m->cpuhz = (ulong)freq;
	m->delayloop = m->cpuhz/1000;
	conf.cpuspeed = m->cpuhz;
	m->ticks = 0;

	when = now() + m->cpuhz/HZ;
	hwtimerset(&when);
	timerie();
}

void
clockpoll(void)
{
	int c;

	if(consuart != nil && consuart->phys->getc != nil){
		while((c = consuart->phys->getc(consuart)) >= 0)
			uartrecv(consuart, c);
	}
}

void
clockcheck(void)
{
	clockpoll();
}

uvlong
fastticks(uvlong *hz)
{
	if(hz)
		*hz = m->cpuhz ? m->cpuhz : HZ;
	return now();
}

ulong
tk2ms(ulong ticks)
{
	uvlong t, hz;

	t = ticks;
	hz = HZ;
	t *= 1000L;
	t = t/hz;
	return (ulong)t;
}

ulong
ms2tk(ulong ms)
{
	if(ms >= 1000000000/HZ)
		return (ms/1000)*HZ;
	return (ms*HZ+500)/1000;
}
