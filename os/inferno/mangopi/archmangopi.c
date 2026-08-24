#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

/*
 * What only the MangoPi MQ-Pro has.  The board arrives here with its
 * DRAM already brought up -- either by the SPL the boot ROM loaded off
 * the card, or by xfel over USB -- so there is no memory controller work
 * to do; see mangopi(6) for how it is loaded.
 *
 * The clocks are left where the loader put them.  The D1's UARTs hang
 * off a 24MHz APB out of reset and stay there, and the CLINT counts at
 * the 24MHz the device tree calls timebase-frequency, so nothing here
 * has to touch the clock control unit to get a console and a clock.
 */

void
archreset(void)
{
	extern void uartboardinit(void);

	uartboardinit();
}

void
archconfinit(void)
{
	conf.topofmem = PHYSDRAM + DRAMSIZE;
	conf.cpuspeed = 24000000;	/* CLINT timebase-frequency */
}

void
archconsole(void)
{
}

void
archreboot(void)
{
	for(;;)
		idle();
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

void
cycles(uvlong *u)
{
	*u = rdcycle();
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
