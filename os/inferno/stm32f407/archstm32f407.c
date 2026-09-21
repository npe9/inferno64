#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "armv7m.h"

/*
 * What only an STM32F407 has: a clock tree to program and a console.
 *
 * Nothing here has been run on a board.  It is written from RM0090 and
 * checked against qemu's netduinoplus2, which is an STM32F405 -- the
 * same die family, and near enough for everything in this file except
 * the one thing said below about the clock.  See
 * os/inferno/stm32f407/NOTE.
 */

extern char bdata[];

ulong apb1hz = CPUHZ;			/* until the clock is settled */

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
 * Wait for a bit to appear, but not for ever.
 *
 * qemu's RCC is a register file: hw/misc/stm32_rcc.c returns what was
 * written and sets no ready bit of its own, so a boot that waits for
 * HSIRDY or PLLRDY the way the reference manual says to waits until
 * the machine is killed.  A bounded wait is also the right thing on a
 * real part -- an oscillator that never starts is a fault and not a
 * reason to hang with nothing on the console -- so this returns
 * whether the bit came, and the caller decides.
 */
static int
waitfor(ulong reg, ulong bit)
{
	int i;

	for(i = 0; i < 100000; i++){
		if(rd(reg) & bit)
			return 1;
	}
	return 0;
}

/*
 * The part comes out of reset on a 16MHz internal oscillator.  The PLL
 * takes it through /M *N /P: 16/8 = 2MHz into the loop, times 168,
 * divided by two, is 168MHz, which is the part's maximum at 3.3V and
 * wants five flash wait states.  APB1 may not exceed 42MHz and APB2
 * 84, so they are divided by four and two.
 *
 * The clock that is running at the end is returned, because the UART's
 * divisor is computed from it and SysTick is told it.  A kernel that
 * assumed the PLL had come up and had it not would have a console at
 * the wrong baud and a clock out by a factor of ten -- which is a
 * board that looks broken in a way that has nothing to do with the
 * fault.
 */
static ulong
setclock(void)
{
	wr(RCC_CR, rd(RCC_CR) | CrHsion);
	if(!waitfor(RCC_CR, CrHsirdy))
		return CPUHZ;			/* no HSI: nothing to do */

	wr(FLASH_ACR, AcrPrften|AcrIcen|AcrDcen|AcrLatency5);
	/* M=8, N=168, P=2 (the field is P/2-1, so 0), source HSI */
	wr(RCC_PLLCFGR, 8 | (168<<6) | (0<<16) | PllsrcHsi);
	wr(RCC_CFGR, CfgrHpreDiv1|CfgrPpre1Div4|CfgrPpre2Div2);
	wr(RCC_CR, rd(RCC_CR) | CrPllon);
	if(!waitfor(RCC_CR, CrPllrdy)){
		/* stay on the HSI, and say so by the number returned */
		wr(RCC_CR, rd(RCC_CR) & ~CrPllon);
		wr(FLASH_ACR, AcrPrften|AcrIcen|AcrDcen);
		apb1hz = CPUHZ;
		return CPUHZ;
	}
	wr(RCC_CFGR, rd(RCC_CFGR) | CfgrSwPll);
	if(!waitfor(RCC_CFGR, CfgrSwsPll)){
		apb1hz = CPUHZ;
		return CPUHZ;
	}
	coherence();
	apb1hz = 168000000/4;
	return 168000000;
}

void
archreset(void)
{
	ulong hz;

	hz = setclock();
	if(m != nil)
		m->cpuhz = hz;
	wr(RCC_AHB1ENR, rd(RCC_AHB1ENR) | Ahb1Gpioa);
	wr(RCC_APB1ENR, rd(RCC_APB1ENR) | Apb1Usart2);
	coherence();
	uartboardinit();
}

void
archconfinit(void)
{
	/*
	 * Bank 0 is what is left of the SRAM above the bss.  The core
	 * coupled memory is a second bank: 64K at CCMRAM, which the
	 * core reaches over its data bus.  Nothing else can -- no DMA
	 * and no instruction fetch -- so it holds data and not code.
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
