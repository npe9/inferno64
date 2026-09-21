#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../radio/sx127x.h"

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
	 * which is DIO0 is whatever the shield says it is.  The first
	 * socket's three match tools/qemu-patches/0029; the second's
	 * match 0039 and avoid pins 2 and 3, which 0030's loopback
	 * strap uses.  A PyCubed wires RF1 to PB30/PB05/PB00 and has a
	 * second socket beside it, which is the whole reason a board
	 * half should be able to say "two".
	 */
	Nsocket		= 2,
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

/*
 * One PL022 and one GPIO block, shared by every socket on the header,
 * with one lock over the pair.  Two parts on one bus is what a PyCubed
 * has and is the only arrangement in which a second socket means
 * anything: they are told apart by chip select and by nothing else.
 */
static u32 *ssp;
static u32 *gpio;
static Lock buslock;			/* the bus is shared with storage */

static Socket socket[Nsocket] = {
	{ "shield0.rf1", 0, 1, 4 },
	{ "shield0.rf2", 6, 7, 8 },
};

static void
pl022select(Spidev *s, int on)
{
	Socket *sk = s->aux;

	/* chip select is active low, and it is a GPIO, not the PL022's */
	if(on)
		gpio[Gpiodataout/4] &= ~(1 << sk->cspin);
	else
		gpio[Gpiodataout/4] |= 1 << sk->cspin;
}

static int
pl022byte(Spidev *, int out)
{
	u32 *r = ssp;

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
pl022lock(Spidev*)
{
	ilock(&buslock);
}

static void
pl022unlock(Spidev*)
{
	iunlock(&buslock);
}

/*
 * Wait n microseconds by the clock rather than by counting
 * instructions.  fastticks() reads SysTick and reports its frequency,
 * so this is a real interval on hardware and under an emulator alike.
 *
 * clockpoll() inside the spin, and not for tidiness.  fastticks() is
 * fastcount plus however far SysTick has counted down, and fastcount
 * only moves when somebody notices the counter has wrapped --
 * clockpoll() is what notices, and os/inferno/armv7m/clock.c says it
 * is for "the boot path before spllo", which is where links() runs.
 * Spinning on fastticks() alone, a delay that begins near the end of a
 * SysTick period asks for a time the counter reaches only after a wrap
 * that is never counted, and the loop never ends.  That is an
 * intermittent hang at boot, between "procinit" and the first word
 * from the radio, which is a hard thing to be told anything about.
 */
static void
usdelay(int n)
{
	uvlong hz, now, end;

	now = fastticks(&hz);
	end = now + ((hz / 1000000) * n);
	while(fastticks(nil) < end)
		clockpoll();
}

static void
rfinterrupt(Ureg*, void *a)
{
	Socket *sk;
	u32 st;
	int i;

	USED(a);
	/*
	 * One interrupt line for the whole GPIO block, so the status
	 * register says which pins raised it and every socket whose
	 * DIO0 is among them is asked to look.  Write one to clear
	 * first, so an edge arriving during the handler is not lost.
	 */
	st = gpio[Gpiointstatus/4];
	for(i = 0; i < Nsocket; i++){
		sk = &socket[i];
		if(sk->radio == nil || (st & (1 << sk->dio0pin)) == 0)
			continue;
		gpio[Gpiointstatus/4] = 1 << sk->dio0pin;
		sx127xinterrupt(sk->radio);
	}
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
	Socket *sk;
	int i, n;

	ssp = (u32*)SPISHIELD0;
	gpio = (u32*)GPIO0;

	ssp[Sspcpsr/4] = 2;			/* the minimum even divisor */
	ssp[Sspcr0/4] = Dss8bit | Frfspi;
	ssp[Sspcr1/4] = Sspenable;

	n = 0;
	for(i = 0; i < Nsocket; i++){
		sk = &socket[i];
		sk->spi.name = sk->name;
		sk->spi.aux = sk;
		sk->spi.select = pl022select;
		sk->spi.byte = pl022byte;
		sk->spi.lock = pl022lock;
		sk->spi.unlock = pl022unlock;

		/* chip select idles high, so drive it before enabling */
		gpio[Gpiodataout/4] |= 1 << sk->cspin;
		gpio[Gpiooutenset/4] = 1 << sk->cspin;
		/* NRESET idles high too */
		gpio[Gpiodataout/4] |= 1 << sk->resetpin;
		gpio[Gpiooutenset/4] = 1 << sk->resetpin;
		/* DIO0 is an input, rising edge */
		gpio[Gpiooutenclr/4] = 1 << sk->dio0pin;
		gpio[Gpiointtypeset/4] = 1 << sk->dio0pin;
		gpio[Gpiointpolset/4] = 1 << sk->dio0pin;
		gpio[Gpiointstatus/4] = 1 << sk->dio0pin;

		/*
		 * Reset the part before talking to it.  NRESET is active
		 * low and the datasheet (7.2.2) wants it held at least
		 * 100us, with the part left alone for 5ms after it is
		 * released.
		 *
		 * Not microdelay(): os/inferno/armv7m/clock.c computes a
		 * loop count from m->cpuhz and assumes four cycles an
		 * iteration, which is an instruction count and not a
		 * time.  Under QEMU it is out by a factor of seventeen --
		 * a delay(1) for the hold above measured 58us against
		 * the 1000us it was asked for, which the model said so in
		 * as many words.  usdelay() waits on SysTick instead,
		 * which is a clock either way.
		 */
		gpio[Gpiodataout/4] &= ~(1 << sk->resetpin);
		usdelay(200);
		gpio[Gpiodataout/4] |= 1 << sk->resetpin;
		usdelay(5000);

		sk->radio = sx127xinit(&sk->spi, GPIO0IRQ);
		if(sk->radio == nil)
			continue;
		gpio[Gpiointenset/4] = 1 << sk->dio0pin;
		n++;
	}
	if(n > 0)
		intrenable(GPIO0IRQ, rfinterrupt, nil, 0, "rf");
}

Radio*
radioget(int i)
{
	if(i < 0 || i >= Nsocket)
		return nil;
	return socket[i].radio;
}
