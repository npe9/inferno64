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
extern ulong	ticknoup, ticknotrun, tickrun;
extern int	schedclock;
extern void	(*kproftick)(ulong);

static uvlong
now(void)
{
	uvlong u;

	cycles(&u);
	return u;
}

/*
 * A cheap monotonic count for measuring short intervals.  CNTPCT runs
 * at CNTFRQ, 19.2MHz on this part, so one tick is about 52ns and a
 * 32-bit long wraps after about three and a half minutes -- which is
 * why only differences are ever taken from it.
 */
long
lcycles(void)
{
	uvlong u;

	cycles(&u);
	return (long)u;
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
	if(schedclock)
		accounttime();
	checkalarms();
	timercheck(u);

	/*
	 * The scheduler's clock, which no native Inferno board in this
	 * tree was wiring up.  hzsched() and accounttime() are both
	 * compiled into every one of these kernels -- they are in
	 * port/proc.c, they are in the link -- and nothing called either
	 * of them, so a process's priority never decayed with the time it
	 * used and its quantum never ended.  That is not a Raspberry Pi
	 * quirk; it is every board here, and it is why a process a device
	 * woke could wait milliseconds behind a Limbo loop.
	 *
	 * hzsched() does not switch anything.  It rebalances the run
	 * queues once a second and sets up->resched when the running
	 * process has had its 100ms or when something better is ready;
	 * vmachine() acts on that at the next Dis instruction boundary.
	 */
	if(up == nil)
		ticknoup++;
	else if(up->state != Running)
		ticknotrun++;
	else
		tickrun++;
	if(schedclock && up != nil && up->state == Running)
		hzsched();

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

void
clockinit(void)
{
	uvlong freq, when;

	cntfrq(&freq);
	m->cpuhz = (ulong)freq;
	m->delayloop = m->cpuhz/1000;
	conf.cpuspeed = m->cpuhz;
	m->ticks = 0;

	/*
	 * Route the non-secure physical timer (CNTPNSIRQ, bit 1) to core 0's
	 * IRQ line through the BCM2836 per-core interrupt controller.  This
	 * is what turns the periodic scheduler tick on.  It was long left off
	 * because a timer IRQ taken mid-transfer corrupted memory -- that was
	 * the vectrap argument-home / UR_R1 collision fixed in l.s (trap()'s
	 * Ureg* argument was spilled onto the saved R1 slot, clobbering a
	 * live loop counter in irestore's R = p->R copy).  With that fixed
	 * the tick is safe, so enable it.
	 */
	*(volatile ulong*)(0x40000040) = 1<<1;	/* Core0 timer int ctl: CNTPNSIRQ -> IRQ */

	when = now() + m->cpuhz/HZ;
	hwtimerset(&when);
	timerie();
}

/*
 * The same two things for a processor that is not processor 0.
 *
 * clockinitsecondary() is clockinit() minus everything that belongs to
 * the machine rather than to this processor: CNTFRQ, CNTP_CVAL, the
 * timer enable and the BCM2836 per-core routing register are all
 * per-processor state, and conf.cpuspeed and the soft-timer queues are
 * not.  The routing register is 0x40000040 + 4*machno -- one per core,
 * bit 1 being CNTPNSIRQ -- so each processor arms its own.
 *
 * clocksecondary() is clockintr() minus everything that touches a
 * process, a queue or a lock: it counts and re-arms.  That is the whole
 * handler, and it is deliberately not clockintr(): accounttime(),
 * checkalarms(), timercheck() and hzsched() all reach shared scheduler
 * state that this kernel's portable half has never been asked to
 * protect against a second processor.  What m->ticks rising on three
 * processors at once proves is narrow and real -- each is taking its
 * own timer interrupt, through its own vector table, into its own Mach.
 */
/*
 * l.s's secirq re-arms the timer with a constant, because a handler that
 * must not read memory cannot divide CNTFRQ by HZ for itself.  The constant
 * is right for this part and silent if it ever is not: under QEMU, whose
 * CNTFRQ is not 19.2MHz, it ran at fifty-one ticks in two hundred
 * milliseconds instead of twenty and nothing said so.  So say so.
 */
enum {
	Secirqperiod	= 192000,	/* the MOV in l.s's secirq */
};

extern int smpstart;

void
clockinitsecondary(void)
{
	uvlong freq, when;

	cntfrq(&freq);
	m->cpuhz = (ulong)freq;
	m->delayloop = m->cpuhz/1000;
	m->ticks = 0;
	*(volatile ulong*)(0x40000040 + 4*m->machno) = 1<<1;
	coherence();
	if(smpstart >= 3 && m->cpuhz/HZ != Secirqperiod)
		iprint("CPU%d SECIRQ-RATE: cpuhz/HZ is %lud, secirq re-arms at %d;"
			" its tick count is wrong by that ratio\n",
			m->machno, m->cpuhz/HZ, Secirqperiod);
	when = now() + m->cpuhz/HZ;
	hwtimerset(&when);
	timerie();
}

void
clocksecondary(Ureg*)
{
	uvlong when;

	m->ticks++;
	when = now() + m->cpuhz/HZ;
	hwtimerset(&when);
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

/*
 * Boot assertions, with interrupts on: the scheduler tick counts during
 * a 250ms busy wait (delay() waits on the counter, not on ticks), and a
 * timed sleep in this process wakes.  A dead tick prints TICK-FAIL with
 * the core's interrupt mask, the timer's enable/ISTATUS and deadline, and
 * the BCM2836 per-core route and pending registers.
 */
void
clockcheckboot(void)
{
	ulong t0, n;
	uvlong now, cval;
	extern ulong getcntpctl(void);
	extern ulong getdaif(void);
	extern void getcntpcval(uvlong*);

	t0 = m->ticks;
	delay(250);
	n = m->ticks - t0;
	if(n >= HZ/8)
		print("TICK-OK %lud ticks in 250ms\n", n);
	else{
		cycles(&now);
		getcntpcval(&cval);
		print("TICK-FAIL %lud ticks in 250ms: daif %#lux cntp_ctl %#lux "
			"cval-now %lld local route %#ux pending %#ux gpu route %#ux\n",
			n, getdaif(), getcntpctl(), (vlong)(cval - now),
			*(volatile u32*)0x40000040, *(volatile u32*)0x40000060,
			*(volatile u32*)0x4000000c);
	}
	t0 = m->ticks;
	tsleep(&up->sleep, return0, nil, 100);
	print("SLEEP-OK tsleep 100ms returned after %lud ticks\n", m->ticks - t0);
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
