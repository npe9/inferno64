#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

void
archreset(void)
{
}

/*
 * The PL031 RTC's data register (offset 0) is a 32-bit count of seconds
 * since the epoch.  main() seeds the time-of-day clock from it, scaled
 * to nanoseconds, so wall time is calendar-correct rather than relative
 * to boot.
 */
vlong
rtctime(void)
{
	return -1;	/* raspi3b: no RTC here */
}

void
pciarchinit(void)
{
	/* raspi3b has no PCI */
}

void
archconfinit(void)
{
	conf.topofmem = PHYSDRAM + DRAMSIZE;
	conf.cpuspeed = 100000000;	/* refined once cntfrq() is read, see clockinit */
}

void
archconsole(void)
{
	/* uartconsole already set consuart / serwrite */
}

void
archreboot(void)
{
	/* PSCI SYSTEM_RESET (0x84000009); QEMU restarts the machine */
	psci(0x84000009ULL, 0, 0, 0);
	for(;;)
		idle();
}

void
archshutdown(void)
{
	/* PSCI SYSTEM_OFF (0x84000008); QEMU powers the machine off */
	psci(0x84000008ULL, 0, 0, 0);
}

void
kbdinit(void)
{
}

void
idlehands(void)
{
	idle();
	clockpoll();
}

void
delay(int ms)
{
	uvlong end;

	if(ms <= 0)
		return;
	end = fastticks(nil) + (uvlong)ms * (m->cpuhz / 1000);
	while(fastticks(nil) < end)
		clockpoll();
}

void
microdelay(int us)
{
	int i, n;

	n = (m->delayloop * us) / 1000;
	if(n <= 0)
		n = 1;
	for(i = 0; i < n; i++)
		;
	if(us >= 100)
		clockpoll();
}

int
cmpswap(s32 *addr, s32 old, s32 new)
{
	int s, r;

	s = splhi();
	if(*addr == old){
		*addr = new;
		r = 1;
	}else
		r = 0;
	splx(s);
	return r;
}

/*
 * interp.h's AINC/ADEC (libinterp's Dis reference-counting primitives)
 * -- spl-masked, same uniprocessor assumption cmpswap above already
 * makes (MAXMACH is 1 on this board).  Nothing in os/inferno provides
 * these for the "arm" (5c) objtype yet; every other board either
 * never actually links a caller of them or has its own equivalent
 * this port didn't inherit.
 */
int
ainc(int *addr)
{
	int s, r;

	s = splhi();
	r = ++*addr;
	splx(s);
	return r;
}

int
adec(int *addr)
{
	int s, r;

	s = splhi();
	r = --*addr;
	splx(s);
	return r;
}

long
archkprofmicrosecondspertick(void)
{
	return 1000000 / HZ;
}

void
archkprofenable(int on)
{
	USED(on);
}
