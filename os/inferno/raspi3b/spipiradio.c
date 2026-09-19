#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../radio/sx127x.h"

/*
 * An RFM9x on the Pi's SPI0 header, and the board half of the radio.
 *
 * This is the same job os/inferno/mps2/spipl022.c does for the MPS2 and
 * shares no code with it: a different controller (a BCM2835 SPI against
 * an ARM PrimeCell PL022), different GPIO, different interrupt numbers.
 * What is shared is everything above the Spidev -- all of
 * os/inferno/port/sx127x.c -- which is the claim that file has been
 * making since it was written and which nothing until now could test.
 *
 * Wiring, which on a board where the radio is a module rather than a
 * fitted part is a choice and not a datasheet:
 *
 *	MOSI  GPIO10   MISO GPIO9   SCLK GPIO11   (SPI0, alt0)
 *	CS    GPIO8    DIO0 GPIO24  NRESET GPIO25
 *
 * The same three that tools/qemu-patches 0036 fits under
 * "-machine raspi3b,radio=on", and the ones Adafruit's wiring guide
 * suggests for their breakout.
 */

enum {
	SpiCs	= 0x00/4,
	SpiFifo	= 0x04/4,
	SpiClk	= 0x08/4,

	CsTa	= 1<<7,
	ClearTx	= 1<<4,
	ClearRx	= 1<<5,

	Cspin	= 8,
	Dio0pin	= 24,
	Resetpin = 25,

	Alt0	= 4,		/* GPFSEL: SPI0 function */
};

static Radio *radio0;

typedef struct Pibus Pibus;
struct Pibus
{
	u32	*spi;
	Lock	l;
};

static Pibus bus0;

/*
 * Chip select is a GPIO and not the controller's, because the part
 * needs CS held across a whole transaction -- address byte then data --
 * and the BCM2835 controller drops its own between frames.  CsTa stays
 * set for the duration so the controller keeps clocking.
 */
static void
piselect(Spidev *s, int on)
{
	Pibus *p = s->aux;

	if(on){
		p->spi[SpiCs] = ClearTx|ClearRx|CsTa;
		gpioout(Cspin, 0);
	}else{
		gpioout(Cspin, 1);
		p->spi[SpiCs] = 0;
	}
}

static int
pibyte(Spidev *s, int out)
{
	Pibus *p = s->aux;

	p->spi[SpiFifo] = out & 0xff;
	return p->spi[SpiFifo] & 0xff;
}

static void
pilock(Spidev *s)
{
	Pibus *p = s->aux;

	ilock(&p->l);
}

static void
piunlock(Spidev *s)
{
	Pibus *p = s->aux;

	iunlock(&p->l);
}

static Spidev spi0radio = {
	"spi0",
	&bus0,
	piselect,
	pibyte,
	pilock,
	piunlock,
};

static void
rfinterrupt(Ureg*, void*)
{
	if(!gpioevent(Dio0pin))
		return;			/* somebody else's pin on this line */
	gpioeventclear(Dio0pin);
	if(radio0 != nil)
		sx127xinterrupt(radio0);
}

static void
usdelay(int n)
{
	uvlong hz, end;

	end = fastticks(&hz) + ((hz / 1000000) * n);
	while(fastticks(nil) < end)
		;
}

void
spipiradiolink(void)
{
	Pibus *p = &bus0;

	p->spi = (u32*)SPI0;

	/* the three bus pins to their alternate function */
	gpiofsel(10, Alt0);
	gpiofsel(9, Alt0);
	gpiofsel(11, Alt0);

	/* chip select and reset idle high, as outputs */
	gpiofsel(Cspin, 1);
	gpioout(Cspin, 1);
	gpiofsel(Resetpin, 1);
	gpioout(Resetpin, 1);
	/* DIO0 an input, rising edge */
	gpiofsel(Dio0pin, 0);
	gpiodetect(Dio0pin, Grise);

	p->spi[SpiClk] = 8;

	/*
	 * Reset, held for the datasheet's 100us with 5ms after.  Not
	 * microdelay(): the same instruction-counted loop that measured
	 * 58us for a millisecond on the other board.
	 */
	gpioout(Resetpin, 0);
	usdelay(200);
	gpioout(Resetpin, 1);
	usdelay(5000);

	radio0 = sx127xinit(&spi0radio, IRQgpio0);
	if(radio0 == nil)
		return;

	intrenable(IRQgpio0, rfinterrupt, nil, 0, "rf0");
}

Radio*
radioget(int i)
{
	if(i != 0)
		return nil;
	return radio0;
}
