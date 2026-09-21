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
 *	RF1: CS GPIO8   DIO0 GPIO24  NRESET GPIO25
 *	RF2: CS GPIO7   DIO0 GPIO23  NRESET GPIO22
 *
 * RF1's three are the ones tools/qemu-patches 0036 fits under
 * "-machine raspi3b,radio=on", and the ones Adafruit's wiring guide
 * suggests for their breakout.  RF2 is a second socket on the same
 * bus, told apart by chip select and by nothing else, which is what a
 * PyCubed has and what a Pi can have: GPIO7 is SPI0's other native
 * chip select, CE1, and the header brings it out beside CE0.  It is
 * probed like the first and is simply absent if nothing answers.
 */

enum {
	SpiCs	= 0x00/4,
	SpiFifo	= 0x04/4,
	SpiClk	= 0x08/4,

	CsTa	= 1<<7,
	ClearTx	= 1<<4,
	ClearRx	= 1<<5,

	Alt0	= 4,		/* GPFSEL: SPI0 function */

	Nsocket	= 2,
};

typedef struct Socket Socket;
struct Socket
{
	char	*name;
	int	cspin;
	int	dio0pin;
	int	resetpin;
	Spidev	spi;
	Radio	*radio;
};

/* one SPI0 and one lock, shared by every socket on the header */
static u32 *spi;
static Lock buslock;

static Socket socket[Nsocket] = {
	{ "spi0.rf1", 8, 24, 25 },
	{ "spi0.rf2", 7, 23, 22 },
};

/*
 * Chip select is a GPIO and not the controller's, because the part
 * needs CS held across a whole transaction -- address byte then data --
 * and the BCM2835 controller drops its own between frames.  CsTa stays
 * set for the duration so the controller keeps clocking.
 */
static void
piselect(Spidev *s, int on)
{
	Socket *sk = s->aux;

	if(on){
		spi[SpiCs] = ClearTx|ClearRx|CsTa;
		gpioout(sk->cspin, 0);
	}else{
		gpioout(sk->cspin, 1);
		spi[SpiCs] = 0;
	}
}

static int
pibyte(Spidev *, int out)
{
	spi[SpiFifo] = out & 0xff;
	return spi[SpiFifo] & 0xff;
}

static void
pilock(Spidev*)
{
	ilock(&buslock);
}

static void
piunlock(Spidev*)
{
	iunlock(&buslock);
}

static void
rfinterrupt(Ureg*, void*)
{
	Socket *sk;
	int i;

	/*
	 * One line for a bank of pins, so every socket whose DIO0 has
	 * an event is asked to look and a line raised by somebody
	 * else's pin is left alone.
	 */
	for(i = 0; i < Nsocket; i++){
		sk = &socket[i];
		if(sk->radio == nil || !gpioevent(sk->dio0pin))
			continue;
		gpioeventclear(sk->dio0pin);
		sx127xinterrupt(sk->radio);
	}
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
	Socket *sk;
	int i, n;

	spi = (u32*)SPI0;

	/* the three bus pins to their alternate function */
	gpiofsel(10, Alt0);
	gpiofsel(9, Alt0);
	gpiofsel(11, Alt0);

	spi[SpiClk] = 8;

	n = 0;
	for(i = 0; i < Nsocket; i++){
		sk = &socket[i];
		sk->spi.name = sk->name;
		sk->spi.aux = sk;
		sk->spi.select = piselect;
		sk->spi.byte = pibyte;
		sk->spi.lock = pilock;
		sk->spi.unlock = piunlock;

		/* chip select and reset idle high, as outputs */
		gpiofsel(sk->cspin, 1);
		gpioout(sk->cspin, 1);
		gpiofsel(sk->resetpin, 1);
		gpioout(sk->resetpin, 1);
		/* DIO0 an input, rising edge */
		gpiofsel(sk->dio0pin, 0);
		gpiodetect(sk->dio0pin, Grise);

		/*
		 * Reset, held for the datasheet's 100us with 5ms after.
		 * Not microdelay(): the same instruction-counted loop
		 * that measured 58us for a millisecond on the other
		 * board.
		 */
		gpioout(sk->resetpin, 0);
		usdelay(200);
		gpioout(sk->resetpin, 1);
		usdelay(5000);

		sk->radio = sx127xinit(&sk->spi, IRQgpio0);
		if(sk->radio != nil)
			n++;
	}
	if(n > 0)
		intrenable(IRQgpio0, rfinterrupt, nil, 0, "rf");
}

Radio*
radioget(int i)
{
	if(i < 0 || i >= Nsocket)
		return nil;
	return socket[i].radio;
}
