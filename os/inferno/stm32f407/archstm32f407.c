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
void
ledpin(int pin, int on)
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

/*
 * Styx request sizes for a part with 192K of RAM.
 *
 * os/inferno/port/devmnt.c and os/inferno/port/exportfs.c both carry
 * 8216 as the message size to ask for and the buffer to read a request
 * into before any size has been negotiated, and devmnt then opens a
 * queue of ten times it -- 82160 bytes.  This board has about 80K of
 * main pool in total.  Measured, exporting a namespace over the radio:
 *
 *	exportproc 7: waiting for memory (8216) for request
 *	arena too large: main size 9176 cursize 38464
 *	  arenasize 79360 maxsize 81900, alloc = 9344
 *
 * and from the far end a mount that never answers, although its
 * Tversion had crossed the air -- nineteen bytes, logged at both ends.
 *
 * 512 because the messages this board will carry are small: the
 * carrier is a 125-byte packet and an AX.25 information field is 109,
 * so a Twrite of 489 bytes is already five frames of airtime.  It is
 * above devmnt's own floor of 256, which is the other number that has
 * to be cleared.
 *
 * Set here rather than in the conf because the port files must keep a
 * default for every other board, and two definitions of one symbol do
 * not link.  Called from archreset, which is this board's earliest
 * hook and runs long before anything mounts or exports.
 */
static void
styxsizes(void)
{
	extern int mntmaxrpc, mntqueuerpcs, exportmaxrpc;

	mntmaxrpc = 512;
	mntqueuerpcs = 10;
	exportmaxrpc = 512;
}

void
archreset(void)
{
	styxsizes();
	ulong hz;

	wr(RCC_AHB1ENR, rd(RCC_AHB1ENR) | Ahb1Gpioe | Ahb1Bkpsram);
	coherence();
	ledpin(12, 1);				/* LD1: the kernel is running */

	hz = setclock();
	if(m != nil)
		m->cpuhz = hz;
	wr(RCC_AHB1ENR, rd(RCC_AHB1ENR) | UARTGPIOEN);
	wr(UARTAPBENR, rd(UARTAPBENR) | UARTAPBBIT);
	coherence();
	uartboardinit();
	ledpin(15, 1);				/* LD2: the console is up;
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
	/*
	 * The third bank is declared and not used.  qemu's
	 * stm32f405_soc.c maps flash, SRAM and CCM and not the backup
	 * SRAM, so a guest that allocates out of 0x40024000 there takes
	 * a bus fault -- reached, once the root grew enough to get that
	 * far: "hard fault ... bfar 40024400".  The part has the
	 * region; the model does not.
	 *
	 * tools/qemu-patches/0041 adds it.  Until that is what this is
	 * tested against, agreeing with the emulator is worth more than
	 * 4096 bytes: set npage2 from BKPSRAMSIZE and the board has
	 * 176128 rather than 167936.
	 */
	conf.base2 = BKPSRAM;
	conf.npage2 = 0;
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
		ledpin(15, on);
#ifdef KSTACKWATCH
		{
			static int worst;
			int n;

			if((n = kstackused()) > worst){
				worst = n;
				print("kstack high water %d of %d\n",
					n, KSTACK);
			}
		}
#endif
	}
	idle();
}
