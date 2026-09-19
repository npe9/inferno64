#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/sx127x.h"

/*
 * The MPS2's SPI and GPIO, and the radio shield on Shield0.
 *
 * This file is a test fixture and says so.  An MPS2 carries five ARM
 * PrimeCell PL022 controllers and four CMSDK AHB GPIO blocks; a PyCubed
 * carries a SAMD51 SERCOM and SAMD51 port pins.  Nothing here survives
 * contact with the real board.  What survives is os/inferno/port/
 * sx127x.c above it, which is why the two are separate files and why
 * everything below is reached through a Spidev.
 *
 * The board is real, the shield is not: an MPS2 has the Arduino-style
 * expansion headers this uses and no radio plugged into them.  See
 * doc/radio-plan.ms and tools/qemu-patches/0029.
 */

enum {
	/* PL022, ARM PrimeCell SSP */
	Sspcr0		= 0x00,
	  Dss8bit	= 0x07,		/* data size select: 8 bits */
	  Frfspi	= 0<<4,		/* Motorola SPI frame format */
	Sspcr1		= 0x04,
	  Sspenable	= 1<<1,
	Sspdr		= 0x08,
	Sspsr		= 0x0c,
	  Sspttfe	= 1<<0,		/* transmit FIFO empty */
	  Ssptnf	= 1<<1,		/* transmit FIFO not full */
	  Ssprne	= 1<<2,		/* receive FIFO not empty */
	  Ssprff	= 1<<3,
	  Sspbsy	= 1<<4,
	Sspcpsr		= 0x10,

	/* CMSDK AHB GPIO */
	Gpiodata	= 0x000,
	Gpiodataout	= 0x004,
	Gpiooutenset	= 0x010,
	Gpiooutenclr	= 0x014,
	Gpiointenset	= 0x020,
	Gpiointenclr	= 0x024,
	Gpiointtypeset	= 0x028,
	Gpiointtypeclr	= 0x02c,
	Gpiointpolset	= 0x030,
	Gpiointpolclr	= 0x034,
	Gpiointstatus	= 0x038,	/* read status, write one to clear */

	/*
	 * The shield's wiring, which is this board's invention: an MPS2
	 * header has no radio on it, so which pin is chip select and
	 * which is DIO0 is whatever the shield says it is.  These two
	 * match tools/qemu-patches/0029.  A PyCubed uses PB30 and PB05.
	 */
	Rfcspin		= 0,
	Rfdio0pin	= 1,
	Rfresetpin	= 4,
};

static Radio *radio0;

typedef struct Pl022 Pl022;
struct Pl022
{
	u32	*ssp;
	u32	*gpio;
	int	cspin;
	Lock	l;			/* the bus is shared with storage */
};

static Pl022 shield0;

static void
pl022select(Spidev *s, int on)
{
	Pl022 *p = s->aux;

	/* chip select is active low, and it is a GPIO, not the PL022's */
	if(on)
		p->gpio[Gpiodataout/4] &= ~(1 << p->cspin);
	else
		p->gpio[Gpiodataout/4] |= 1 << p->cspin;
}

static int
pl022byte(Spidev *s, int out)
{
	Pl022 *p = s->aux;
	u32 *r = p->ssp;

	while((r[Sspsr/4] & Ssptnf) == 0)
		;
	r[Sspdr/4] = out & 0xff;
	while((r[Sspsr/4] & Ssprne) == 0)
		;
	return r[Sspdr/4] & 0xff;
}

/*
 * ilock, not lock: the bus is touched from the DIO0 interrupt handler
 * as well as from a process, so a plain Lock held by a process would
 * deadlock against the handler that interrupted it.  Nothing may sleep
 * while this is held, which is why sx127xsend() drops it around its
 * wait rather than holding it across one.
 */
static void
pl022lock(Spidev *s)
{
	Pl022 *p = s->aux;

	ilock(&p->l);
}

static void
pl022unlock(Spidev *s)
{
	Pl022 *p = s->aux;

	iunlock(&p->l);
}

static Spidev shield0spi = {
	"shield0",
	&shield0,
	pl022select,
	pl022byte,
	pl022lock,
	pl022unlock,
};

/*
 * Wait n microseconds by the clock rather than by counting
 * instructions.  fastticks() reads SysTick and reports its frequency,
 * so this is a real interval on hardware and under an emulator alike.
 */
static void
usdelay(int n)
{
	uvlong hz, now, end;

	now = fastticks(&hz);
	end = now + ((hz / 1000000) * n);
	while(fastticks(nil) < end)
		;
}

static void
rfinterrupt(Ureg*, void *a)
{
	Pl022 *p = &shield0;

	USED(a);
	/* write one to clear, then let the chip driver look */
	p->gpio[Gpiointstatus/4] = 1 << Rfdio0pin;
	if(radio0 != nil)
		sx127xinterrupt(radio0);
}

/*
 * Bring up Shield0's PL022 and the GPIO pins the shield uses, then ask
 * the chip driver whether anything is actually out there.  A board with
 * no radio fitted -- which is every MPS2 run without "-machine radio=on"
 * -- reads RegVersion as 0 and sx127xinit() says so and returns nil.
 */
void
spipl022link(void)
{
	Pl022 *p = &shield0;

	p->ssp = (u32*)SPISHIELD0;
	p->gpio = (u32*)GPIO0;
	p->cspin = Rfcspin;

	/* chip select idles high, so drive it before enabling the output */
	p->gpio[Gpiodataout/4] |= 1 << Rfcspin;
	p->gpio[Gpiooutenset/4] = 1 << Rfcspin;
	/* NRESET idles high too */
	p->gpio[Gpiodataout/4] |= 1 << Rfresetpin;
	p->gpio[Gpiooutenset/4] = 1 << Rfresetpin;
	/* DIO0 is an input, rising edge */
	p->gpio[Gpiooutenclr/4] = 1 << Rfdio0pin;
	p->gpio[Gpiointtypeset/4] = 1 << Rfdio0pin;	/* edge */
	p->gpio[Gpiointpolset/4] = 1 << Rfdio0pin;	/* rising */
	p->gpio[Gpiointstatus/4] = 1 << Rfdio0pin;	/* clear any stale one */

	p->ssp[Sspcpsr/4] = 2;			/* the minimum even divisor */
	p->ssp[Sspcr0/4] = Dss8bit | Frfspi;
	p->ssp[Sspcr1/4] = Sspenable;

	/*
	 * Reset the part before talking to it.  NRESET is active low and
	 * the datasheet (7.2.2) wants it held at least 100us, with the
	 * part left alone for 5ms after it is released.
	 *
	 * Not microdelay(): os/inferno/armv7m/clock.c computes a loop
	 * count from m->cpuhz and assumes four cycles an iteration, which
	 * is an instruction count and not a time.  Under QEMU it is out by
	 * a factor of seventeen -- a delay(1) for the hold above measured
	 * 58us against the 1000us it was asked for, which the model said
	 * so in as many words.  usdelay() below waits on SysTick instead,
	 * which is a clock either way.
	 */
	p->gpio[Gpiodataout/4] &= ~(1 << Rfresetpin);
	usdelay(200);
	p->gpio[Gpiodataout/4] |= 1 << Rfresetpin;
	usdelay(5000);

	radio0 = sx127xinit(&shield0spi, GPIO0IRQ);
	if(radio0 == nil)
		return;

	p->gpio[Gpiointenset/4] = 1 << Rfdio0pin;
	intrenable(GPIO0IRQ, rfinterrupt, nil, 0, "rf0");
}

Radio*
radioget(int i)
{
	if(i != 0)
		return nil;
	return radio0;
}
