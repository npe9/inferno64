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

/*
 * Which function a pin is in.  The firmware sets these before the
 * kernel runs, and on this board that is how it says which UART it put
 * on the header; see uartconsole().
 */
int
gpiofselget(int pin)
{
	volatile u32 *r = gpio();

	return (r[Gpfsel0 + pin/10] >> ((pin%10)*3)) & 7;
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
 * Prove the GPIO block: configure pin 21 as an output, drive it high and
 * low, and read the level back each way.
 */
void
gpioinit(void)
{
	enum { Pin = 21 };
	int hi, lo;

	gpiofsel(Pin, Fout);
	gpioout(Pin, 1);
	hi = gpiolev(Pin);
	gpioout(Pin, 0);
	lo = gpiolev(Pin);
	print("gpio: gpio at %#p: pin%d high=%d low=%d %s\n",
		(void*)GPIO0, Pin, hi, lo,
		(hi == 1 && lo == 0)? "(ok)": "(FAIL)");
}
