#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "armv7m.h"

/*
 * What the Teensy 4.1 has that the shared ARMv7-M code cannot know: a
 * clock tree to program, watchdogs to keep quiet, a FlexRAM to divide
 * up, and two blocks of memory that are not next to each other.
 *
 * None of this has been run on a board.  It is written from the i.MX
 * RT1062 reference manual, chapters 14 (clocks), 12 (pins and the
 * general purpose registers) and 9 (boot); see teensy41(6) for what that
 * means and what would be checked first.
 */

extern char bdata[];

static ulong
rd(ulong a)
{
	return *(volatile ulong*)a;
}

static void
wr(ulong a, ulong v)
{
	*(volatile ulong*)a = v;
}

/*
 * The FlexRAM is sixteen banks of 32K that can each be instruction
 * memory, data memory or on-chip RAM.  This kernel's text is in flash
 * and it runs nothing from ITCM, so every bank becomes DTCM: 512K of it
 * at DTCM, a second bank of memory for the pools.
 *
 * GPR17 holds two bits per bank -- 0 unused, 1 OCRAM, 2 DTCM, 3 ITCM --
 * and is only looked at when GPR16's bank select bit says to use it
 * rather than the fuses.  GPR14 says how big the two TCMs are, as
 * 2^(n-1) kilobytes; ten is 512K.
 */
static void
flexraminit(void)
{
	wr(IOMUXC_GPR17, 0xaaaaaaaa);		/* all sixteen banks are DTCM */
	wr(IOMUXC_GPR14, (0<<16) | (10<<20));	/* ITCM none, DTCM 512K */
	wr(IOMUXC_GPR16, (rd(IOMUXC_GPR16) & ~Gpr16Itcmen) | Gpr16Dtcmen | Gpr16Banksel);
	coherence();
}

/*
 * The boot ROM leaves the core running from a divided PLL2.  Take the
 * ARM PLL to 1200MHz and halve it, which is the 600MHz the part is rated
 * for and what CPUHZ in mem.h says SysTick will be counting.
 *
 * The divider select is the multiplier against the 24MHz crystal in
 * halves: 1200MHz is 24 * 100 / 2, so 100.
 */
static void
clockinitarm(void)
{
	ulong v;

	v = rd(PLL_ARM);
	v &= ~(PllArmDivSelect|PllArmPowerdown);
	v |= 100 | PllArmEnable;
	wr(PLL_ARM, v);
	while((rd(PLL_ARM) & PllArmLock) == 0)
		;
	wr(CCM_CACRR, 1);		/* ARM_PODF: divide by two */
	while(rd(CCM_CDHIPR) != 0)	/* wait for the handshake */
		;
	coherence();
}

/*
 * Every peripheral this kernel uses has to have its clock turned on.
 * The gate registers hold two bits per peripheral and 3 means "on in
 * every mode"; turning everything on is what the Teensy's own startup
 * does and costs nothing here but current.
 */
static void
clockgates(void)
{
	wr(CCM_CCGR0, 0xffffffff);
	wr(CCM_CCGR1, 0xffffffff);
	wr(CCM_CCGR2, 0xffffffff);
	wr(CCM_CCGR3, 0xffffffff);
	wr(CCM_CCGR4, 0xffffffff);
	wr(CCM_CCGR5, 0xffffffff);
	wr(CCM_CCGR6, 0xffffffff);
	coherence();
}

/*
 * The watchdogs are not running after a power-on reset, but they are
 * after some others, and a kernel that takes a while to reach its first
 * scheduling point would be reset by one.  Stop them.
 */
static void
watchdogsoff(void)
{
	*(volatile ushort*)(WDOG1+0) &= ~(1<<2);	/* WDOG_WCR.WDE */
	*(volatile ushort*)(WDOG2+0) &= ~(1<<2);
	wr(RTWDOG+0x08, 0xd928c520);			/* unlock */
	wr(RTWDOG+0x08, 0xd928c520);
	wr(RTWDOG+0x00, 0x00002120);			/* CS: disabled */
	coherence();
}

void
archreset(void)
{
	watchdogsoff();
	clockgates();
	clockinitarm();
	flexraminit();
	uartboardinit();
}

void
archconfinit(void)
{
	/*
	 * Bank 0 is what is left of OCRAM2 above the bss;
	 * os/inferno/armv7m/main.c works that out from end and topofmem.
	 * Bank 1 is the FlexRAM, all of which archreset made DTCM.
	 */
	conf.topofmem = TOPOFMEM;
	conf.base1 = DTCM;
	conf.npage1 = FLEXRAMSIZE/BY2PG;
	USED(bdata);
}

void
archconsole(void)
{
}

void
kbdinit(void)
{
}

void
idlehands(void)
{
	idle();
}
