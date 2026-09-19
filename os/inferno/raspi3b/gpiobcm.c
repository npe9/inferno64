/*
 * BCM2835 GPIO (bcm2835_gpio) at 0x3f200000, as modelled by QEMU -M
 * raspi3b.  GPFSELn selects each pin's function (000 in, 001 out);
 * writing a bit in GPSETn/GPCLRn drives an output pin high/low and
 * updates the level register GPLEVn, which reads the pin state back.
 * QEMU keeps GPLEVn faithful to GPSET/GPCLR, so a pin configured as an
 * output can be driven and read back entirely on-chip.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

enum {
	Gpfsel0	= 0x00/4,	/* function select, 6 regs, 10 pins each */
	Gpset0	= 0x1c/4,	/* output set, 2 regs */
	Gpclr0	= 0x28/4,	/* output clear, 2 regs */
	Gplev0	= 0x34/4,	/* pin level, 2 regs */
	Gpeds0	= 0x40/4,	/* event detect status, 2 regs, write 1 to clear */
	Gpren0	= 0x4c/4,	/* rising edge detect enable, 2 regs */
	Gpfen0	= 0x58/4,	/* falling edge detect enable, 2 regs */
	Gphen0	= 0x64/4,	/* high level detect enable, 2 regs */
	Gplen0	= 0x70/4,	/* low level detect enable, 2 regs */
	Gppud	= 0x94/4,	/* pull-up/down control (BCM2835/7 only) */
	Gppudclk0 = 0x98/4,	/* pull-up/down clock, 2 regs */

	Fin	= 0,		/* fsel: input */
	Fout	= 1,		/* fsel: output */
};

static volatile u32*
gpio(void)
{
	return (volatile u32*)GPIO0;
}

/* Set pin's function (Fin/Fout/altN). */
void
gpiofsel(int pin, int fn)
{
	volatile u32 *r = gpio();
	int reg = pin/10, sh = (pin%10)*3;
	u32 v;

	v = r[Gpfsel0 + reg];
	v &= ~(7u << sh);
	v |= (fn & 7u) << sh;
	r[Gpfsel0 + reg] = v;
}

/*
 * Set a pin's pull: 0 none, 1 down, 2 up.  The BCM2835/7 latches the
 * control value into a pin on a clock pulse, and needs the control
 * held for ~150 cycles on each side of it; there is no read-back.
 * QEMU accepts these registers and ignores them.
 */
void
gpiopull(int pin, int pull)
{
	volatile u32 *r = gpio();
	int reg = pin/32, bit = pin%32;
	volatile int i;

	r[Gppud] = pull & 3;
	for(i = 0; i < 1000; i++)
		;
	r[Gppudclk0 + reg] = 1u << bit;
	for(i = 0; i < 1000; i++)
		;
	r[Gppud] = 0;
	r[Gppudclk0 + reg] = 0;
}

/* Drive an output pin high (on=1) or low (on=0). */
void
gpioout(int pin, int on)
{
	volatile u32 *r = gpio();
	int reg = pin/32, bit = pin%32;

	if(on)
		r[Gpset0 + reg] = 1u << bit;
	else
		r[Gpclr0 + reg] = 1u << bit;
}

/* Read a pin's level. */
int
gpiolev(int pin)
{
	volatile u32 *r = gpio();
	int reg = pin/32, bit = pin%32;

	return (r[Gplev0 + reg] >> bit) & 1;
}

/*
 * Event detection.  A pin can be told to latch a rising edge, a falling
 * edge, or a level; the latch is GPEDS and it stays set until a one is
 * written to it, so an edge arriving while a handler runs is not lost.
 *
 * This is what a SPI peripheral with an interrupt line needs, and it is
 * most of them: an RFM9x raises DIO0, a CC-series part raises GDO0 or
 * its own IRQ pin, and without this the only way to notice is to poll.
 * The four detect lines go to GPU interrupts 49 to 52; everything here
 * arms the first, which is the one every other system takes.
 */
void
gpiodetect(int pin, int how)
{
	volatile u32 *r = gpio();
	int reg = pin / 32, bit = pin % 32;

	r[Gpren0 + reg] &= ~(1 << bit);
	r[Gpfen0 + reg] &= ~(1 << bit);
	r[Gphen0 + reg] &= ~(1 << bit);
	r[Gplen0 + reg] &= ~(1 << bit);
	switch(how){
	case Grise:
		r[Gpren0 + reg] |= 1 << bit;
		break;
	case Gfall:
		r[Gpfen0 + reg] |= 1 << bit;
		break;
	case Ghigh:
		r[Gphen0 + reg] |= 1 << bit;
		break;
	case Glow:
		r[Gplen0 + reg] |= 1 << bit;
		break;
	}
	/* clear anything already latched for this pin */
	r[Gpeds0 + reg] = 1 << bit;
}

int
gpioevent(int pin)
{
	volatile u32 *r = gpio();

	return (r[Gpeds0 + pin/32] >> (pin%32)) & 1;
}

void
gpioeventclear(int pin)
{
	volatile u32 *r = gpio();

	r[Gpeds0 + pin/32] = 1 << (pin%32);
}

/*
 * Prove the GPIO block: configure pin 21 as an output, drive it high and
 * low, and read the level back each way.  Then arm rising-edge detection
 * on it and drive it again, which latches GPEDS -- the detect logic
 * watches the pin and not its direction, so a pin the kernel drives
 * itself is a complete test of the path with no wire between two pins.
 */
void
gpioinit(void)
{
	enum { Pin = 21 };
	int hi, lo, ev0, ev1;

	gpiofsel(Pin, Fout);
	gpioout(Pin, 1);
	hi = gpiolev(Pin);
	gpioout(Pin, 0);
	lo = gpiolev(Pin);
	print("gpio: gpio at %#p: pin%d high=%d low=%d %s\n",
		(void*)GPIO0, Pin, hi, lo,
		(hi == 1 && lo == 0)? "(ok)": "(FAIL)");

	gpiodetect(Pin, Grise);
	ev0 = gpioevent(Pin);
	gpioout(Pin, 1);
	ev1 = gpioevent(Pin);
	gpioeventclear(Pin);
	gpioout(Pin, 0);
	gpiodetect(Pin, Gnone);
	print("gpio: pin%d rising edge: before=%d after=%d %s\n",
		Pin, ev0, ev1,
		(ev0 == 0 && ev1 == 1)? "GPIOEDGE-OK": "GPIOEDGE-FAIL");
}
