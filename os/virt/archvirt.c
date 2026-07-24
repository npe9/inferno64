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

void
pciarchinit(void)
{
	extern void pciinit(void);

	pciinit();
}

/*
 * KenC loads 32-bit immediates with MOVW (sign-extending).  Values with
 * bit31 set (e.g. 0x80000000) must come from static data so the high
 * word is zero, then loaded with a 64-bit MOV.  DRAMSIZE (256MiB) is fine
 * as an immediate; keep physdram in static storage.
 */
static uintptr physdram = (uintptr)8 << 28;

void
archconfinit(void)
{
	conf.topofmem = physdram + DRAMSIZE;
	conf.cpuspeed = 10000000;
}

void
archconsole(void)
{
	/* uartconsole already set consuart / serwrite */
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
	/* Timer (CLINT) + UART (PLIC) wake WFI; sync ticks after wake. */
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
