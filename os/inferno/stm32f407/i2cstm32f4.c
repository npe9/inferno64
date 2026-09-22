#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/i2c.h"

/*
 * The STM32F4's I2C, as a bus under #J.
 *
 * Two of them come out on a clicker 2's mikroBUS sockets: I2C2 on PB10
 * and PB11 is socket 2's SCL and SDA, I2C3 on PA8 and PC9 is socket
 * 1's.  Both are alternate function 4, open drain -- I2C has no
 * push-pull driver, the pull-ups make the high -- and a click board
 * brings its own pull-ups, so the weak internal ones are enabled only
 * so that a bus with nothing on it idles high instead of floating.
 *
 * THE PART OF THIS PERIPHERAL THAT IS NOT OBVIOUS, and the reason the
 * code below looks fussier than one-byte-in-one-byte-out:
 *
 * SB, ADDR and BTF are cleared by reading one register and then
 * touching another, in that order and no other.  SB by reading SR1 and
 * writing DR; ADDR by reading SR1 and then SR2.  Until ADDR is cleared
 * the part holds SCL low -- so a receive does not begin when the
 * address is acknowledged, it begins when SR2 is read, and everything
 * that has to be arranged for the end of a read must be arranged
 * before that.  That is why there are three receive procedures and not
 * one: with one byte to fetch, ACK must already be off and STOP must
 * follow immediately; with two, POS says "the ACK bit means the next
 * byte, not this one"; with more, the last three are taken with the
 * shift register kept one ahead.  RM0090 27.3.3 sets all three out and
 * this follows them.
 *
 * Getting that wrong gives a driver that reads one byte too many, or
 * acknowledges a byte it meant to refuse and leaves the part holding
 * the bus -- which is a hang at the next transfer, not at this one.
 *
 * Not implemented: ten-bit addressing (io() refuses it), slave mode,
 * SMBus, DMA, interrupts.  Transfers are polled.  A byte at 100kHz is
 * 90us, and the longest transfer #J will ask for is 138 bytes, so the
 * spin bound below is generous rather than tight.
 */

enum {
	/* RM0090 27.6 */
	Cr1	= 0x00/4,
	  Pe	= 1<<0,
	  Start	= 1<<8,
	  Stop	= 1<<9,
	  Ack	= 1<<10,
	  Pos	= 1<<11,
	  Swrst	= 1<<15,
	Cr2	= 0x04/4,
	Oar1	= 0x08/4,
	Oar2	= 0x0c/4,
	Dr	= 0x10/4,
	Sr1	= 0x14/4,
	  Sb	= 1<<0,
	  Addr	= 1<<1,
	  Btf	= 1<<2,
	  Rxne	= 1<<6,
	  Txe	= 1<<7,
	  Berr	= 1<<8,
	  Arlo	= 1<<9,
	  Af	= 1<<10,
	  Ovr	= 1<<11,
	  Errors= Berr|Arlo|Af|Ovr,
	Sr2	= 0x18/4,
	  Msl	= 1<<0,
	  Busy	= 1<<1,
	Ccr	= 0x1c/4,
	  Fast	= 1<<15,
	Trise	= 0x20/4,

	Spins	= 200000,	/* bounded: an absent part is not a hang */
	I2chz	= 100000,	/* standard mode */
};

typedef struct Ctlr Ctlr;
struct Ctlr
{
	u32	*r;
	ulong	base;
	ulong	apbbit;
	ulong	sclport;
	ulong	sclclk;
	int	sclpin;
	ulong	sdaport;
	ulong	sdaclk;
	int	sdapin;
	int	af;
};

static void
gpioaf(ulong port, int pin, int af)
{
	ulong v, reg;
	int sh;

	v = *(volatile ulong*)(port+GPIO_MODER);
	v &= ~(3UL << (2*pin));
	v |= 2UL << (2*pin);			/* alternate function */
	*(volatile ulong*)(port+GPIO_MODER) = v;

	*(volatile ulong*)(port+GPIO_OTYPER) |= 1UL << pin;	/* open drain */

	v = *(volatile ulong*)(port+GPIO_OSPEEDR);
	v |= 3UL << (2*pin);
	*(volatile ulong*)(port+GPIO_OSPEEDR) = v;

	v = *(volatile ulong*)(port+GPIO_PUPDR);
	v &= ~(3UL << (2*pin));
	v |= 1UL << (2*pin);			/* pull up */
	*(volatile ulong*)(port+GPIO_PUPDR) = v;

	reg = pin < 8? GPIO_AFRL: GPIO_AFRH;
	sh = 4 * (pin % 8);
	v = *(volatile ulong*)(port+reg);
	v &= ~(0xfUL << sh);
	v |= (ulong)af << sh;
	*(volatile ulong*)(port+reg) = v;
}

/*
 * Wait for one of bits in SR1.  A NAK or a bus error ends the wait as
 * surely as success does, and is reported as failure after the sticky
 * bit is cleared -- writing zero is how these are cleared, which is
 * the opposite of nearly everything else on this part.
 */
static int
waitsr1(Ctlr *c, ulong bits)
{
	ulong sr;
	int i;

	for(i = 0; i < Spins; i++){
		sr = c->r[Sr1];
		if(sr & bits)
			return sr;
		if(sr & Errors){
			c->r[Sr1] = 0;
			return -1;
		}
	}
	return -1;
}

static void
clearaddr(Ctlr *c)
{
	ulong v;

	v = c->r[Sr1];			/* the pair, in this order */
	v = c->r[Sr2];
	USED(v);
}

static void
stop(Ctlr *c)
{
	c->r[Cr1] |= Stop;
}

static int
start(Ctlr *c)
{
	c->r[Cr1] |= Start;
	if(waitsr1(c, Sb) < 0)
		return -1;
	return 0;
}

/*
 * The address byte: SB is cleared by the SR1 read and this DR write
 * together, so the read is not decoration.  ADDR is left set for the
 * caller, because what has to happen before it is cleared depends on
 * which way the transfer goes and how long it is.
 */
static int
sendaddr(Ctlr *c, int b)
{
	ulong v;

	v = c->r[Sr1];
	USED(v);
	c->r[Dr] = b & 0xff;
	if(waitsr1(c, Addr) < 0)
		return -1;
	return 0;
}

static int
senddata(Ctlr *c, int b)
{
	if(waitsr1(c, Txe) < 0)
		return -1;
	c->r[Dr] = b & 0xff;
	return 0;
}

/*
 * Receive n bytes and stop.  ADDR is still set on entry: this arranges
 * ACK and POS for the length wanted, clears it, and only then does the
 * part start clocking bytes in.  RM0090 27.3.3, "Master receiver".
 */
static int
recvdata(Ctlr *c, uchar *buf, int n)
{
	int i;

	if(n <= 0){
		clearaddr(c);
		stop(c);
		return 0;
	}
	if(n == 1){
		c->r[Cr1] &= ~Ack;
		clearaddr(c);
		stop(c);
		if(waitsr1(c, Rxne) < 0)
			return -1;
		buf[0] = c->r[Dr];
		return 1;
	}
	if(n == 2){
		c->r[Cr1] = (c->r[Cr1] & ~Ack) | Pos;
		clearaddr(c);
		if(waitsr1(c, Btf) < 0){
			c->r[Cr1] &= ~Pos;
			return -1;
		}
		stop(c);
		buf[0] = c->r[Dr];
		buf[1] = c->r[Dr];
		c->r[Cr1] &= ~Pos;
		return 2;
	}
	c->r[Cr1] |= Ack;
	clearaddr(c);
	for(i = 0; i < n-3; i++){
		if(waitsr1(c, Rxne) < 0)
			return -1;
		buf[i] = c->r[Dr];
	}
	if(waitsr1(c, Btf) < 0)
		return -1;
	c->r[Cr1] &= ~Ack;		/* the byte still coming is refused */
	buf[n-3] = c->r[Dr];
	stop(c);
	buf[n-2] = c->r[Dr];
	if(waitsr1(c, Rxne) < 0)
		return -1;
	buf[n-1] = c->r[Dr];
	return n;
}

/*
 * Put the controller back to idle after an error or an interrupted
 * transfer.  A STOP is enough if the part still has the bus; if it has
 * been left holding SDA low -- the classic stuck bus -- only a reset
 * of the peripheral gets it back, and this does that rather than
 * leaving every later transfer to fail.
 */
static void
recover(Ctlr *c)
{
	int i;

	c->r[Sr1] = 0;
	stop(c);
	for(i = 0; i < Spins; i++)
		if((c->r[Sr2] & Busy) == 0)
			return;
	c->r[Cr1] = Swrst;
	c->r[Cr1] = 0;
	c->r[Cr1] = Pe;
}

static int
i2cinit(I2Cbus *bus)
{
	Ctlr *c;
	ulong pclk, ccr;

	c = bus->ctlr;
	*(volatile ulong*)RCC_AHB1ENR |= c->sclclk | c->sdaclk;
	*(volatile ulong*)RCC_APB1ENR |= c->apbbit;
	coherence();

	gpioaf(c->sclport, c->sclpin, c->af);
	gpioaf(c->sdaport, c->sdapin, c->af);

	c->r = (u32*)c->base;
	c->r[Cr1] = Swrst;			/* a known state first */
	c->r[Cr1] = 0;

	/*
	 * FREQ is the APB1 clock in megahertz and is what the part
	 * times everything from; CCR is the half period in those
	 * ticks, so the bus rate is pclk/(2*CCR); TRISE is the maximum
	 * SCL rise time in ticks plus one, 1000ns in standard mode.
	 */
	if(bus->speed == 0)
		bus->speed = I2chz;
	pclk = apb1hz;
	ccr = pclk / (2 * bus->speed);
	if(ccr < 4)
		ccr = 4;
	c->r[Cr2] = pclk / 1000000;
	c->r[Ccr] = ccr;
	c->r[Trise] = pclk / 1000000 + 1;
	c->r[Cr1] = Pe;
	coherence();
	return 0;
}

/*
 * One transfer.  See ../port/i2c.h for what the packet means.  A
 * combined transfer -- registers to write, then a read -- is a write
 * phase, a repeated START, and a read phase, which is why the address
 * appears twice with its low bit set differently each time.
 */
static int
i2cio(I2Cdev *dev, uchar *pkt, int olen, int ilen)
{
	Ctlr *c;
	int i, n;

	c = dev->bus->ctlr;
	if(pkt == nil){
		recover(c);
		return 0;
	}
	if(dev->a10)
		return -1;		/* ten-bit addressing: not here */
	if(olen < 1)
		return -1;

	if(olen > 1 || ilen <= 0){
		if(start(c) < 0)
			goto Fail;
		if(sendaddr(c, pkt[0] & ~1) < 0)
			goto Fail;
		clearaddr(c);
		for(i = 1; i < olen; i++)
			if(senddata(c, pkt[i]) < 0)
				goto Fail;
		if(olen > 1 && waitsr1(c, Btf) < 0)
			goto Fail;
		if(ilen <= 0){
			stop(c);
			return olen;
		}
	}

	if(start(c) < 0)		/* repeated, if there was a write */
		goto Fail;
	if(sendaddr(c, pkt[0] | 1) < 0)
		goto Fail;
	n = recvdata(c, pkt+olen, ilen);
	if(n < 0)
		goto Fail;
	return olen + n;

Fail:
	recover(c);
	return -1;
}

static Ctlr ctlr2 = {
	.base	= I2C2,
	.apbbit	= Apb1I2c2,
	.sclport= GPIOB, .sclclk = Ahb1Gpiob, .sclpin = 10,
	.sdaport= GPIOB, .sdaclk = Ahb1Gpiob, .sdapin = 11,
	.af	= 4,
};

static Ctlr ctlr3 = {
	.base	= I2C3,
	.apbbit	= Apb1I2c3,
	.sclport= GPIOA, .sclclk = Ahb1Gpioa, .sclpin = 8,
	.sdaport= GPIOC, .sdaclk = Ahb1Gpioc, .sdapin = 9,
	.af	= 4,
};

static I2Cbus i2c2bus = {
	.name	= "i2c2",
	.ctlr	= &ctlr2,
	.init	= i2cinit,
	.io	= i2cio,
};

static I2Cbus i2c3bus = {
	.name	= "i2c3",
	.ctlr	= &ctlr3,
	.init	= i2cinit,
	.io	= i2cio,
};

/*
 * Registering a bus costs nothing: the clocks, the pins and the probe
 * happen when something first opens #J, so a board with no I2C part
 * fitted never drives the pins at all.
 */
void
i2cstm32f4link(void)
{
#ifndef CONSUSART3
	addi2cbus(&i2c2bus);		/* PB10/PB11 are USART3 otherwise */
#endif
	addi2cbus(&i2c3bus);
}
