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

/* A Pi 3B has no battery-backed clock; time of day starts at boot. */
vlong
rtctime(void)
{
	return -1;
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

/*
 * BCM2835 power manager watchdog (0x3f100000): the reset every Pi OS
 * uses, since the Pi's armstub8 provides no PSCI.  Every write carries
 * the 0x5a password; RSTC's WRCFG field set to full reset with a short
 * WDOG count resets the SoC when the count runs out.  QEMU's
 * bcm2835_powermgt models the same register.
 */
enum {
	PmRstc		= 0x1c/4,
	PmRsts		= 0x20/4,
	PmWdog		= 0x24/4,
	PmPasswd	= 0x5a000000,
	PmWrcfgMask	= 0x30,
	PmWrcfgFull	= 0x20,
	PmRstsPart	= 0x555,	/* partition bits: 63 = halt */
};

static void
pmreset(int halt)
{
	volatile u32 *pm = (volatile u32*)PM0;
	u32 v;

	splhi();
	if(halt){
		v = pm[PmRsts] & ~PmRstsPart;
		pm[PmRsts] = PmPasswd | v | PmRstsPart;
	}
	pm[PmWdog] = PmPasswd | 10;
	v = pm[PmRstc] & ~PmWrcfgMask;
	pm[PmRstc] = PmPasswd | v | PmWrcfgFull;
	for(;;)
		idle();
}

void
archreboot(void)
{
	pmreset(0);
}

/*
 * A Pi cannot switch its own power off.  Resetting into partition 63
 * is how the firmware is told to halt instead of booting again.
 */
void
archshutdown(void)
{
	pmreset(1);
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

/*
 * Timed against the generic timer's counter, like delay(), not an
 * uncalibrated loop: m->delayloop is cpuhz/1000 iterations, which took
 * roughly as long as asked under QEMU and a small fraction of it on a
 * real Cortex-A53.
 */
void
microdelay(int us)
{
	uvlong now, end, hz;

	if(us <= 0)
		return;
	cycles(&now);
	hz = m->cpuhz;
	if(hz == 0){
		cntfrq(&hz);
		if(hz == 0)
			hz = 1000000;
	}
	end = now + ((uvlong)us * hz + 999999) / 1000000;
	do
		cycles(&now);
	while(now < end);
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
