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
ulong apb2hz = CPUHZ;

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

static int
waituntil(ulong reg, ulong mask, ulong want)
{
	int i;

	for(i = 0; i < 100000; i++){
		if((rd(reg) & mask) == want)
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
 *
 * setclock() is below hsionly(), which is the fallback it takes.
 */

/*
 * Go back to the reset state and stay there: the HSI undivided, no
 * wait states, the PLL off.  The APB dividers matter as much as the
 * switch back to the HSI does, and are easy to leave behind -- they
 * are written before the PLL is known to have locked, because CFGR
 * has to be right before the switch, and a fallback that clears only
 * SW leaves HCLK at 16MHz with APB1 divided by four and APB2 by two.
 * The console divisor is computed from those, so the board would come
 * up at a quarter of the baud it meant.
 */
static ulong
hsionly(void)
{
	wr(RCC_CFGR, CfgrHpreDiv1|CfgrPpre1Div1|CfgrPpre2Div1|CfgrSwHsi);
	wr(RCC_CR, rd(RCC_CR) & ~CrPllon);
	wr(FLASH_ACR, AcrPrften|AcrIcen|AcrDcen);
	coherence();
	apb1hz = CPUHZ;
	apb2hz = CPUHZ;
	return CPUHZ;
}

static ulong
setclock(void)
{
	wr(RCC_CR, rd(RCC_CR) | CrHsion);
	if(!waitfor(RCC_CR, CrHsirdy))
		return CPUHZ;			/* no HSI: nothing to do */

	/*
	 * Back to the reset state before configuring anything, because
	 * this kernel is not always the first thing to run.  A board
	 * with a bootloader in its flash is entered with that
	 * bootloader's clock tree already set up and its PLL running --
	 * a MikroElektronika one has to have a PLL, because it needs
	 * 48MHz for the USB it is reached over.  RM0090 7.3.2 says
	 * PLLCFGR may only be written while PLLON is clear, so the
	 * configuration below would be quietly ignored, the PLL would
	 * keep whatever the bootloader gave it, and this function would
	 * then return 168000000 and set apb1hz and apb2hz for a
	 * frequency it never actually set.  Every baud divisor and the
	 * clock rate follow from those.
	 *
	 * So: the system clock back to the HSI, the prescalers back to
	 * one, and the PLL off, each waited for.  On a board entered
	 * from reset this is all already true and costs a few reads.
	 */
	wr(RCC_CFGR, CfgrHpreDiv1|CfgrPpre1Div1|CfgrPpre2Div1|CfgrSwHsi);
	waituntil(RCC_CFGR, CfgrSwsMask, CfgrSwsHsi);
	wr(RCC_CR, rd(RCC_CR) & ~CrPllon);
	waituntil(RCC_CR, CrPllrdy, 0);

	wr(FLASH_ACR, AcrPrften|AcrIcen|AcrDcen|AcrLatency5);
	/* M=8, N=168, P=2 (the field is P/2-1, so 0), source HSI */
	wr(RCC_PLLCFGR, 8 | (168<<6) | (0<<16) | PllsrcHsi);
	wr(RCC_CFGR, CfgrHpreDiv1|CfgrPpre1Div4|CfgrPpre2Div2);
	wr(RCC_CR, rd(RCC_CR) | CrPllon);
	if(!waitfor(RCC_CR, CrPllrdy))
		return hsionly();
	wr(RCC_CFGR, rd(RCC_CFGR) | CfgrSwPll);
	if(!waitfor(RCC_CFGR, CfgrSwsPll))
		return hsionly();
	coherence();
	apb1hz = 168000000/4;
	apb2hz = 168000000/2;
	return 168000000;
}

/*
 * TEMPORARY, and it says so: a first-light diagnostic for a board
 * nothing has ever run on.  A clicker 2 for STM32 has two LEDs, LD1 on
 * PE12 and LD2 on PE15, and they are the only thing that can answer
 * the question a silent console cannot tell apart -- whether the
 * kernel is running at all, or running and talking to the wrong pins.
 * LD1 before the clock is touched, LD2 once the console is up.
 */
static void
led(int pin, int on)
{
	ulong v;

	v = rd(GPIOE+GPIO_MODER);
	v &= ~(3UL << (2*pin));
	v |= 1UL << (2*pin);			/* output */
	wr(GPIOE+GPIO_MODER, v);
	v = rd(GPIOE+GPIO_ODR);
	if(on)
		v |= 1UL << pin;
	else
		v &= ~(1UL << pin);
	wr(GPIOE+GPIO_ODR, v);
}

void
archreset(void)
{
	ulong hz;

	wr(RCC_AHB1ENR, rd(RCC_AHB1ENR) | Ahb1Gpioe);
	coherence();
	led(12, 1);				/* TEMPORARY: reached main */

	hz = setclock();
	if(m != nil)
		m->cpuhz = hz;
	wr(RCC_AHB1ENR, rd(RCC_AHB1ENR) | UARTGPIOEN);
	wr(UARTAPBENR, rd(UARTAPBENR) | UARTAPBBIT);
	/* TEMPORARY, for otherusarts(): ports A and D, USART2/3 and UART4 */
	wr(RCC_AHB1ENR, rd(RCC_AHB1ENR) | Ahb1Gpioa | Ahb1Gpiob |
		Ahb1Gpioc | Ahb1Gpiod | Ahb1Gpioe);
	wr(RCC_APB1ENR, rd(RCC_APB1ENR) | Apb1Usart2 | Apb1Usart3 | Apb1Uart4);
	coherence();
	uartboardinit();
	/*
	 * TEMPORARY, with the LEDs above: say the same thing on every
	 * USART a clicker 2 brings out, because which socket the USB
	 * UART click is in is not knowable from here.  mikroBUS 1 is
	 * USART2 on PD5/PD6, mikroBUS 2 is USART3 on PD8/PD9, and the
	 * 2x26 pad is UART4 on PA0/PA1.  Whichever shows the line is
	 * the one CONSUSART should name.
	 */
	otherusarts();
	led(15, 1);				/* TEMPORARY: console is up;
						 * idlehands() blinks it from
						 * here on */
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

/*
 * TEMPORARY, with led() above.  A steady LED can be a pin stuck high;
 * a blink cannot.  m->ticks is incremented by the SysTick handler in
 * os/inferno/armv7m/clock.c, so LD2 changing twice a second says three
 * things at once: the kernel reached the scheduler, the clock is
 * running, and interrupts are being taken.  HZ is 100.
 */
void
idlehands(void)
{
	static ulong last;
	static int on;

	if(m != nil && m->ticks/50 != last){
		last = m->ticks/50;
		on = !on;
		led(15, on);
		/*
		 * TEMPORARY, with the rest.  otherusarts() writes its
		 * lines once, in archreset(), microseconds after reset
		 * and before any host could have opened the port --
		 * which is indistinguishable from a port that is not
		 * connected at all.  Saying it again twice a second
		 * removes that doubt, and each line begins with a run
		 * of 0x55, which is the one byte whose framing a
		 * listener at the wrong baud can still be measured
		 * from.
		 */
		otherusarts();
		if(on)
			bangallpins();	/* TEMPORARY: once a second */
	}
	idle();
}
