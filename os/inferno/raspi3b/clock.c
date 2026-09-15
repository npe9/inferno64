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

static void
sleepcheck(void*)
{
	ulong t0;

	t0 = m->ticks;
	tsleep(&up->sleep, return0, nil, 100);
	print("SLEEP-OK tsleep 100ms returned after %lud ticks\n", m->ticks - t0);
	pexit("", 0);
}

/*
 * Boot assertion for the scheduler tick, taken with interrupts on.
 * delay() busy-waits on the counter, not on ticks, so a dead timer
 * interrupt shows as TICK-FAIL with the state of every stage it
 * crosses: the core's IRQ mask, the timer's own enable/ISTATUS and
 * deadline, the BCM2836 per-core route and pending registers.  A
 * timed sleep is then left to report itself: SLEEP-OK never printing
 * means timers never wake anyone, which is the same fault seen from a
 * process.
 */
/*
 * The first half second with interrupts on, reported straight to the
 * UART data register: console output after chandevreset goes through
 * a queue that only the transmit interrupt drains, so if interrupts do
 * not arrive nothing queued ever appears and this is the only word.
 */
static void
irqcheck(void)
{
	uvlong hz, t, end;
	ulong t0, i0, u0;
	extern ulong irqentries, pl011intrs;
	extern ulong getcntpctl(void), getdaif(void), getcurrentel(void), getvbar(void);
	extern void getcntpcval(uvlong*);
	uvlong cval;
	volatile u32 *ic = (volatile u32*)IRQBASE;

	t0 = m->ticks;
	i0 = irqentries;
	u0 = pl011intrs;
	cntfrq(&hz);
	cycles(&t);
	end = t + hz/2;
	while(t < end)
		cycles(&t);
	getcntpcval(&cval);
	serialputs("IRQCHECK 500ms: irqs ", -1);
	serialputdec(irqentries - i0);
	serialputs(" ticks ", -1);
	serialputdec(m->ticks - t0);
	serialputs(" uartintr ", -1);
	serialputdec(pl011intrs - u0);
	serialputreg("el", getcurrentel(), 1);
	serialputreg("daif", getdaif(), 3);
	serialputreg("vbar", getvbar(), 8);
	serialputreg("cntp_ctl", getcntpctl(), 1);
	serialputreg("cval>now", cval > t, 1);
	serialputreg("l40", *(volatile u32*)0x40000040, 2);
	serialputreg("l60", *(volatile u32*)0x40000060, 3);
	serialputreg("l0c", *(volatile u32*)0x4000000c, 2);
	serialputreg("basic", ic[0], 3);
	serialputreg("pend1", ic[1], 8);
	serialputreg("pend2", ic[2], 8);
	serialputreg("en1", ic[4], 8);
	serialputreg("en2", ic[5], 8);
	serialputs("\n", -1);
}

void
clockcheckboot(void)
{
	ulong t0, n;
	uvlong now, cval;
	extern ulong getcntpctl(void);
	extern ulong getdaif(void);
	extern void getcntpcval(uvlong*);

	irqcheck();
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
	kproc("sleepcheck", sleepcheck, nil, 0);
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
