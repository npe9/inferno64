#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"../radio/cc1120.h"

/*
 * The STM32F4's SPI and GPIO, and the radio in a mikroBUS socket.
 *
 * This file is the board half and says so.  A clicker 2 for STM32 has
 * two mikroBUS sockets, an SPI on each -- SPI3 on socket 1, SPI2 on
 * socket 2 -- and every other line of a socket is an ordinary GPIO.
 * Nothing here survives contact with a different board; what survives
 * is os/inferno/radio/cc1120.c above it, which is why the two are
 * separate files and why everything below is reached through a Spidev.
 *
 * The socket pinout is the clicker 2's, from its manual:
 *
 *		mikroBUS 1	mikroBUS 2
 *	AN	PA2		PA3		the click's GPIO0
 *	RST	PE7		PE13		its reset
 *	CS	PE8		PE11
 *	SCK	PC10 (SPI3)	PB13 (SPI2)
 *	MISO	PC11 (SPI3)	PB14 (SPI2)
 *	MOSI	PC12 (SPI3)	PB15 (SPI2)
 *	PWM	PE9		PD12		its GPIO2
 *	INT	PE10		PE14		its GPIO3
 *
 * Socket 2 only, for now: that is where the radio is, and a second
 * socket is worth having only when there is a second part to put in it.
 */

enum {
	/* STM32F4 SPI, RM0090 28.5 */
	Spicr1		= 0x00,
	  Cpha		= 1<<0,
	  Cpol		= 1<<1,
	  Mstr		= 1<<2,
	  Br0		= 1<<3,		/* fPCLK/2 << (BR+1) */
	  Spe		= 1<<6,
	  Ssi		= 1<<8,
	  Ssm		= 1<<9,
	Spicr2		= 0x04,
	Spisr		= 0x08,
	  Rxne		= 1<<0,
	  Txe		= 1<<1,
	  Bsy		= 1<<7,
	Spidr		= 0x0c,

	/* mikroBUS 2 on a clicker 2 */
	Cspin		= 11,		/* PE11 */
	Rstpin		= 13,		/* PE13 */
	Intpin		= 14,		/* PE14, the click's GPIO3 */
};

static u32 *spi;
static Lock buslock;
static Radio *radio;

static s32 spi2read(Chan*, void*, s32, s64);
static s32 spi2write(Chan*, void*, s32, s64);

static void
gpioout(ulong port, int pin)
{
	ulong v;

	v = *(volatile ulong*)(port+GPIO_MODER);
	v &= ~(3UL << (2*pin));
	v |= 1UL << (2*pin);			/* output */
	*(volatile ulong*)(port+GPIO_MODER) = v;
}

static void
gpioset(ulong port, int pin, int on)
{
	ulong v;

	v = *(volatile ulong*)(port+GPIO_ODR);
	if(on)
		v |= 1UL << pin;
	else
		v &= ~(1UL << pin);
	*(volatile ulong*)(port+GPIO_ODR) = v;
}

static void
gpioaf(ulong port, int pin, int af)
{
	ulong v, reg;
	int sh;

	v = *(volatile ulong*)(port+GPIO_MODER);
	v &= ~(3UL << (2*pin));
	v |= 2UL << (2*pin);			/* alternate function */
	*(volatile ulong*)(port+GPIO_MODER) = v;

	v = *(volatile ulong*)(port+GPIO_OSPEEDR);
	v |= 3UL << (2*pin);
	*(volatile ulong*)(port+GPIO_OSPEEDR) = v;

	reg = pin < 8? GPIO_AFRL: GPIO_AFRH;
	sh = 4 * (pin % 8);
	v = *(volatile ulong*)(port+reg);
	v &= ~(0xfUL << sh);
	v |= (ulong)af << sh;
	*(volatile ulong*)(port+reg) = v;
}

static void
spiselect(Spidev*, int on)
{
	/* chip select is active low and is a GPIO, not the SPI's NSS */
	gpioset(GPIOE, Cspin, !on);
}

/*
 * One byte out, one byte in.
 *
 * The transfer belongs to the write: DR written, a byte goes out and a
 * byte comes back, and RXNE says so.  Reading DR takes what arrived.
 * The spins are bounded because a bus with nothing on it should give a
 * board a nil radio and not a hang.
 */
static int
spibyte(Spidev*, int out)
{
	int i;

	for(i = 0; i < 100000; i++)
		if(spi[Spisr/4] & Txe)
			break;
	spi[Spidr/4] = out & 0xff;
	for(i = 0; i < 100000; i++)
		if(spi[Spisr/4] & Rxne)
			break;
	return spi[Spidr/4] & 0xff;
}

/*
 * ilock, not lock: the bus is touched from the INT handler as well as
 * from a process, so a plain Lock held by a process would deadlock
 * against the handler that interrupted it.  Nothing may sleep while
 * this is held.
 */
static void
spilock(Spidev*)
{
	ilock(&buslock);
}

static void
spiunlock(Spidev*)
{
	iunlock(&buslock);
}

/*
 * The click's GPIO3, on PE14.  It is already an input with an EXTI
 * rising edge on it for the packet interrupt; this just reads it.
 */
static int
spigpio(Spidev*)
{
	return (*(volatile ulong*)(GPIOE+GPIO_IDR) >> Intpin) & 1;
}

static Spidev spidev = {
	.name	= "mikrobus2",
	.select	= spiselect,
	.byte	= spibyte,
	.lock	= spilock,
	.unlock	= spiunlock,
	.gpio	= spigpio,
};

/*
 * Wait n microseconds by the clock rather than by counting
 * instructions, and poll it while waiting: fastticks() is fastcount
 * plus however far SysTick has counted down, and fastcount only moves
 * when somebody notices the counter has wrapped.  clockpoll() is what
 * notices, and this runs in links(), before spllo.  Spinning on
 * fastticks() alone, a delay that begins near the end of a SysTick
 * period asks for a time the counter reaches only after a wrap that is
 * never counted, and the loop never ends.  os/inferno/mps2/spipl022.c
 * has the same comment for the same reason: it was an intermittent
 * hang at boot there.
 */
static void
usdelay(int n)
{
	uvlong hz, end;

	fastticks(&hz);
	end = fastticks(nil) + ((hz / 1000000) * n);
	while(fastticks(nil) < end)
		clockpoll();
}

static void
rfinterrupt(Ureg*, void*)
{
	/* write one to clear before looking, so an edge during the
	 * handler is not lost */
	*(volatile ulong*)EXTI_PR = 1UL << Intpin;
	if(radio != nil)
		cc1120interrupt(radio);
}

void
spistm32f4link(void)
{
	ulong v;

	/* clocks: GPIOB for the SPI pins, GPIOE for CS, reset and INT,
	 * SPI2 itself, and SYSCFG so EXTI can be pointed at a port */
	*(volatile ulong*)RCC_AHB1ENR |= Ahb1Gpiob | Ahb1Gpioe;
	*(volatile ulong*)RCC_APB1ENR |= Apb1Spi2;
	*(volatile ulong*)RCC_APB2ENR |= Apb2Syscfg;
	coherence();

	/* SCK, MISO, MOSI on alternate function 5 */
	gpioaf(GPIOB, 13, 5);
	gpioaf(GPIOB, 14, 5);
	gpioaf(GPIOB, 15, 5);

	/* chip select idles high, reset idles high */
	gpioout(GPIOE, Cspin);
	gpioset(GPIOE, Cspin, 1);
	gpioout(GPIOE, Rstpin);
	gpioset(GPIOE, Rstpin, 1);

	spi = (u32*)SPI2;
	/*
	 * Master, software chip select -- the CS line is a GPIO, so the
	 * SPI's own NSS must be held high or the part drops out of
	 * master mode -- and APB1/16, which is 2.6MHz.
	 *
	 * This was APB1/256, the slowest the part has, with a comment
	 * saying it was fast enough because the CC1120 will take 10MHz.
	 * That was true of everything the driver did at the time, which
	 * was register writes at boot and a packet now and then, and it
	 * stopped being true the moment anything wanted to sample.
	 * 42MHz/256 is 164kHz, a byte is 49us, and the six bytes of the
	 * two extended reads that make up one RSSI sample are 293us --
	 * which is exactly the 296us per sample the "capture" verb
	 * measured for itself on the board.  So the resolution of every
	 * envelope this board can record was set by this line, and the
	 * bursts at 881MHz are under a millisecond.
	 *
	 * 16 rather than 4 because nothing here needs 10MHz and a
	 * mikroBUS socket is a connector and a cable; this is the
	 * smallest change that stops the bus being the limit.
	 */
	spi[Spicr1/4] = Mstr | Ssm | Ssi | (3 * Br0);
	spi[Spicr2/4] = 0;
	spi[Spicr1/4] |= Spe;
	coherence();

	/*
	 * Reset the part.  The CC112x user's guide (SWRU295E, 3.2) says
	 * RESET_N low for at least two microseconds and the part ready
	 * when SO goes low after it is released.  Held far longer than
	 * that here, because a board that is slow to start a radio
	 * costs nothing and one that is quick costs a bring-up.
	 */
	gpioset(GPIOE, Rstpin, 0);
	usdelay(200);
	gpioset(GPIOE, Rstpin, 1);
	usdelay(5000);

	/*
	 * Before the part is looked for, not after: when it is not
	 * found this function returns, and that is exactly when a file
	 * that says what the bus read is worth having.
	 */
	addarchfile("spi2", 0664, spi2read, spi2write);

	radio = cc1120init(&spidev, EXTI15_10IRQ);
	if(radio == nil)
		return;

	/*
	 * INT is an input, rising edge, routed to EXTI.  SYSCFG's
	 * EXTICR picks which port owns each of the sixteen lines;
	 * EXTI14 is in EXTICR4, nibble 2, and port E is 4.
	 */
	v = *(volatile ulong*)(GPIOE+GPIO_MODER);
	v &= ~(3UL << (2*Intpin));		/* input */
	*(volatile ulong*)(GPIOE+GPIO_MODER) = v;

	v = *(volatile ulong*)(SYSCFG_EXTICR4);
	v &= ~(0xfUL << (4 * (Intpin % 4)));
	v |= 4UL << (4 * (Intpin % 4));		/* port E */
	*(volatile ulong*)(SYSCFG_EXTICR4) = v;

	*(volatile ulong*)EXTI_RTSR |= 1UL << Intpin;
	*(volatile ulong*)EXTI_PR = 1UL << Intpin;
	*(volatile ulong*)EXTI_IMR |= 1UL << Intpin;
	coherence();

	intrenable(EXTI15_10IRQ, rfinterrupt, nil, 0, "rf");
}

Radio*
radioget(int i)
{
	if(i != 0)
		return nil;
	return radio;
}

/*
 * What the bus says right now, at #P/spi2.
 *
 * When cc1120init() finds no part, #W serves an empty directory and
 * the only account of why is a line printed at boot, which on a board
 * has usually scrolled away by the time anybody wants it.  This does
 * the same transaction again on demand and reports the raw bytes, so
 * the question "is the click there" can be asked at a shell prompt.
 *
 * What the numbers mean:
 *	0x00 everywhere -- SO is low the whole time.  Either the part
 *	is holding it low because it is not ready, or MISO is not
 *	reaching this pin at all.  The miso field distinguishes them:
 *	it is the pin read directly, and a floating input with nothing
 *	driving it reads whatever it last saw.
 *	0xff everywhere -- nothing is driving SO and it is pulled up,
 *	which is what an empty socket looks like.
 *	partnumber 0x48 -- a CC1120.  0x40 is a CC1121 and 0x58 a
 *	CC1125, which are the same interface and a different radio.
 *
 * status is the byte the part returns while the header is going out:
 * bit 7 is CHIP_RDYn, so a zero there means the part is awake, and
 * bits 6 to 4 are its state (SWRU295E 3.1.2).
 */
static int
extrd(int addr)
{
	int v;

	spilock(&spidev);
	spiselect(&spidev, 1);
	spibyte(&spidev, 0x80|0x2f);		/* read, extended space */
	spibyte(&spidev, addr);
	v = spibyte(&spidev, 0);
	spiselect(&spidev, 0);
	spiunlock(&spidev);
	return v;
}

static s32
spi2read(Chan*, void *a, s32 n, s64 offset)
{
	char buf[128];
	int st, pn, pv, miso;

	spilock(&spidev);
	spiselect(&spidev, 1);
	st = spibyte(&spidev, 0x3d);		/* SNOP: returns the status */
	spiselect(&spidev, 0);
	spiunlock(&spidev);

	pn = extrd(0x8f);			/* PARTNUMBER */
	pv = extrd(0x90);			/* PARTVERSION */
	miso = (*(volatile ulong*)(GPIOB+GPIO_IDR) >> 14) & 1;

	snprint(buf, sizeof buf,
		"status 0x%.2x partnumber 0x%.2x partversion 0x%.2x miso %d\n",
		st, pn, pv, miso);
	return readstr(offset, a, n, buf);
}

/*
 * Pulse RESET_N and say what the part looks like afterwards: the only
 * thing that can be done to a part that is not answering, short of
 * moving it to the other socket.
 */
static s32
spi2write(Chan *c, void *a, s32 n, s64 offset)
{
	char buf[32];

	if(n <= 0 || n >= sizeof buf)
		error(Ebadarg);
	memmove(buf, a, n);
	buf[n] = 0;
	if(strncmp(buf, "reset", 5) != 0)
		error(Ebadctl);
	gpioset(GPIOE, Rstpin, 0);
	usdelay(200);
	gpioset(GPIOE, Rstpin, 1);
	usdelay(5000);
	USED(c); USED(offset);
	return n;
}


