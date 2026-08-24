#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "armv7m.h"

/*
 * SysTick.  Every ARMv7-M core has one, at the same address, counting
 * down from a reload value at the processor clock, so it is the clock
 * for all of these boards and nothing board-specific is needed.
 *
 * It is a plain periodic tick with no comparator, so unlike the RISC-V
 * boards there is no way to ask for an interrupt at an arbitrary future
 * time.  Soft timers are therefore serviced at the HZ tick, which puts a
 * floor of one tick on tsleep; see timerset in
 * os/inferno/armv7m/stubs.c.
 */

typedef struct Clock0link Clock0link;
struct Clock0link {
	void		(*clock)(void);
	Clock0link*	link;
};

static Clock0link *clock0link;
static Lock clock0lock;

static ulong	systreload;
static uvlong	fastcount;

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
clockinit(void)
{
	ulong n;

	m->ticks = 0;
	fastcount = 0;

	n = m->cpuhz/HZ;
	/*
	 * SysTick counts in 24 bits.  A core fast enough to overflow it
	 * at HZ has to divide, and dividing would make cpuhz a lie for
	 * everything that reads it, so say so rather than tick wrong.
	 */
	if(n == 0 || n > 0x1000000)
		panic("clockinit: cpuhz %lud will not fit SysTick at HZ %d",
			m->cpuhz, HZ);
	systreload = n - 1;

	*(ulong*)SYST_CSR = 0;
	*(ulong*)SYST_RVR = systreload;
	*(ulong*)SYST_CVR = 0;
	coherence();
	*(ulong*)SYST_CSR = SystClksrc|SystTickint|SystEnable;
	coherence();
}

void
clockintr(Ureg *u)
{
	Clock0link *lp;

	fastcount += (uvlong)systreload + 1;
	m->ticks++;

	if(kproftick != nil && u != nil)
		kproftick((ulong)u->pc);

	checkalarms();
	timercheck(u);

	if(canlock(&clock0lock)){
		for(lp = clock0link; lp; lp = lp->link)
			if(lp->clock)
				lp->clock();
		unlock(&clock0lock);
	}
}

/*
 * Poll the clock and the console from a busy wait.  The kernel uses this
 * where it cannot yet take an interrupt -- panics, and the boot path
 * before spllo.
 */
void
clockpoll(void)
{
	int c;

	if(consuart != nil && consuart->phys->getc != nil){
		while((c = consuart->phys->getc(consuart)) >= 0)
			uartrecv(consuart, c);
	}
	if(*(ulong*)SYST_CSR & SystCountflag){
		fastcount += (uvlong)systreload + 1;
		m->ticks++;
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
	uvlong t;
	ulong cvr;
	int s;

	if(hz)
		*hz = m->cpuhz? m->cpuhz: HZ;
	s = splhi();
	cvr = *(ulong*)SYST_CVR & 0xffffff;
	t = fastcount + (systreload - cvr);
	splx(s);
	return t;
}

ulong
tk2ms(ulong ticks)
{
	uvlong t;

	t = ticks;
	t *= 1000L;
	t = t/HZ;
	return (ulong)t;
}

ulong
ms2tk(ulong ms)
{
	if(ms >= 1000000000/HZ)
		return (ms/1000)*HZ;
	return (ms*HZ+500)/1000;
}

void
microdelay(int l)
{
	ulong i, n;

	n = (m->cpuhz/1000000)*l/4;
	for(i = 0; i < n; i++)
		;
}

void
delay(int l)
{
	while(l-- > 0)
		microdelay(1000);
}

void
cycles(uvlong *t)
{
	*t = fastticks(nil);
}

uvlong
rdcycle(void)
{
	return fastticks(nil);
}

long
archkprofmicrosecondspertick(void)
{
	return 1000000/HZ;
}

void
archkprofenable(int)
{
}
