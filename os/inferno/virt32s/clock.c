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

extern ulong	rdtimelo(void);		/* l.s: time CSR low 32 */
extern ulong	rdtimehi(void);		/* l.s: timeh CSR high 32 */
extern void	sbisettimer(void);	/* l.s: SBI set_timer via the globals below */

/*
 * The deadline handed to SBI, split into two 32-bit halves so no uvlong
 * has to pass through a single register on this 32-bit core; l.s reads
 * these.  lastcmp remembers it for clockpoll(), since S-mode cannot read
 * mtimecmp back.
 */
ulong		sbitimerlo, sbitimerhi;
static uvlong	lastcmp;

static uvlong
clintmtime(void)
{
	ulong hi, lo, hi2;

	do {
		hi = rdtimehi();
		lo = rdtimelo();
		hi2 = rdtimehi();
	} while(hi != hi2);		/* reread if it rolled between halves */
	return ((uvlong)hi << 32) | lo;
}

void
clintsetcmp(uvlong when)
{
	lastcmp = when;
	sbitimerlo = (ulong)when;
	sbitimerhi = (ulong)(when >> 32);
	sbisettimer();
}

/*
 * Derive HZ ticks from the S-mode time CSR.  Soft-timer reprogramming used to
 * leave mtimecmp far in the future (KenC uvlong compare was unreliable),
 * so IRQ-driven m->ticks++ froze while wall time advanced.  NOW/sendarp
 * then rate-limited forever.
 */
static void
ticksync(void)
{
	uvlong mt, tk, div;

	div = m->cpuhz / HZ;
	if(div == 0)
		div = 1;
	mt = clintmtime();
	tk = mt / div;
	if(tk > (uvlong)m->ticks)
		m->ticks = (ulong)tk;
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

extern void timercheck(Ureg*);
extern void	(*kproftick)(ulong);

void
clockintr(Ureg *u)
{
	Clock0link *lp;
	uvlong now, hznext, when;

	now = clintmtime();
	hznext = now + m->cpuhz/HZ;
	/* Clear MTIP; final deadline set after timercheck. */
	clintsetcmp(hznext);

	/* Sample interrupted PC for #K; skip soft clockpoll(nil) path. */
	if(kproftick != nil && u != nil)
		kproftick((ulong)u->pc);

	ticksync();
	checkalarms();
	timercheck(u);

	now = clintmtime();
	hznext = now + m->cpuhz/HZ;
	when = timernext(hznext);
	if(when <= now)
		when = now + 1;
	clintsetcmp(when);

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
	m->ticks = 0;
	clintsetcmp(clintmtime() + m->cpuhz/HZ);
	mtimerie();			/* mie.MTIE; mstatus.MIE via spllo */
}

void
clockpoll(void)
{
	int c;
	uvlong cmp;

	/* poll UART RX into uartrecv → kbdq */
	if(consuart != nil && consuart->phys->getc != nil){
		while((c = consuart->phys->getc(consuart)) >= 0)
			uartrecv(consuart, c);
	}
	mtimerie();	/* Bounce busy-path used to leave MTIE clear */
	ticksync();
	cmp = lastcmp;
	if(clintmtime() >= cmp)
		clockintr(nil);
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
	return clintmtime();
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
