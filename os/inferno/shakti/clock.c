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

/*
 * Where the CLINT is.
 *
 * mem.h's constant again, and this one is read on every timer tick and
 * every clockpoll() rather than once at boot -- main.c printed the
 * tree's address beside it for comparison and nothing used it.  The
 * node is "riscv,clint0"; QEMU's trees also claim "sifive,clint0" on
 * the same node, so one lookup finds it on both machines.
 *
 * Before clockinit(), which is the first read.
 */
uintptr clintaddr = CLINT;
static char *clintfrom = "mem.h";

void
clintdiscover(void)
{
	extern int fdtreg(char*, uvlong*, uvlong*);
	uvlong b;

	if(fdtreg("riscv,clint0", &b, nil) && b != 0){
		clintaddr = (uintptr)b;
		clintfrom = "the tree";
	}
}

void
clintreport(void)
{
	print("clint: @ %#p from %s, CLINT-ADDR-OK\n", clintaddr, clintfrom);
}

static uvlong
clintmtime(void)
{
	return *(volatile uvlong*)(clintaddr + ClintMtime);
}

static void
clintsetcmp(uvlong when)
{
	*(volatile uvlong*)(clintaddr + ClintMtimecmp) = when;
}

/*
 * Derive HZ ticks from CLINT mtime.  Soft-timer reprogramming used to
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
	cmp = *(volatile uvlong*)(clintaddr + ClintMtimecmp);
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
