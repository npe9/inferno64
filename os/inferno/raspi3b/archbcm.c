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

/* l.s _tas branches here if a lock is taken before mmuinit(). */
void
tasbeforemmu(void)
{
	serialputs("PANIC: spinlock taken before mmuinit(); this hangs a Cortex-A53\n", -1);
	for(;;)
		;
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

/*
 * cmpswap(), ainc() and adec() are in l.s, as LDXR/STXR loops.  They
 * used to be here, in C, with interrupts masked -- which is an atomic
 * only while MAXMACH is 1, because masking interrupts stops this core
 * and says nothing about the other three.  Now that a secondary core
 * runs kernel code (smpbcm.c), a counter that two cores can reach has
 * to be incremented with the instructions that were built for it; the
 * spl-masked versions were correct for a uniprocessor and are exactly
 * the kind of thing that keeps working for months after it stops being
 * true.
 */

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
