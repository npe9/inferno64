#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "armv7m.h"

/*
 * What only the NUCLEO-F303RE has: a clock tree to program and a
 * console.  Nothing here has been run on a board; it is written from
 * RM0316 and the NUCLEO-64 schematic.  See nucleof303(6).
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
 * The part comes out of reset on the 8MHz internal oscillator.  The PLL
 * takes half of that and multiplies by sixteen, which is the 64MHz
 * CPUHZ says SysTick will be counting; the flash needs two wait states
 * above 48MHz and APB1 has to be halved because it will not go above
 * 36MHz.
 */
static void
pllinit(void)
{
	wr(RCC_CR, rd(RCC_CR) | CrHsion);
	while((rd(RCC_CR) & CrHsirdy) == 0)
		;
	wr(FLASH_ACR, AcrPrftbe|AcrLatency2);
	wr(RCC_CFGR, CfgrPllsrcHsi|CfgrPllmul16|CfgrPpre1Div2);
	wr(RCC_CR, rd(RCC_CR) | CrPllon);
	while((rd(RCC_CR) & CrPllrdy) == 0)
		;
	wr(RCC_CFGR, rd(RCC_CFGR) | CfgrSwPll);
	while((rd(RCC_CFGR) & CfgrSwsMask) != CfgrSwsPll)
		;
	coherence();
}

void
archreset(void)
{
	pllinit();
	wr(RCC_AHBENR, rd(RCC_AHBENR) | AhbGpioa);
	wr(RCC_APB1ENR, rd(RCC_APB1ENR) | Apb1Usart2);
	coherence();
	uartboardinit();
}

void
archconfinit(void)
{
	/*
	 * Bank 0 is what is left of the SRAM above the bss.  The core
	 * coupled memory is a second bank: 16K at CCMRAM, which the
	 * F3 lets data live in as well as code.
	 */
	conf.topofmem = TOPOFMEM;
	conf.base1 = CCMRAM;
	conf.npage1 = CCMRAMSIZE/BY2PG;
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
