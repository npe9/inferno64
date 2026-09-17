/*
 * BCM2835 AUX mini UART (UART1) at 0x3f215040.
 *
 * NOT LINKED: the console is the PL011 (uartpl011.c), and this driver's
 * enable takes GPIO 14/15 for itself, so it must not be opened while the
 * PL011 owns the header.  One physical boot with it as the console
 * (build 1789434335, config.txt without disable-bt) printed nothing at
 * all; that has not been explained.  Kept for the Bluetooth arrangement
 * below, where it would be the header UART again.
 *
 * On a Pi 3B the PL011 (UART0) is wired to the Bluetooth part and the
 * mini UART is what reaches GPIO 14/15 (header pins 8/10), which is
 * the firmware's default arrangement: config.txt says enable_uart=1
 * and names no uart overlay.  (disable-bt and miniuart-bt both do the
 * opposite -- each puts the PL011 back on the header.)  Keeping the
 * PL011 on Bluetooth is what a later Bluetooth driver needs.
 *
 * Ported from 9front's sys/src/9/bcm/uartmini.c, with what this board
 * needs on top of it:
 *
 * AUX_ENABLES gates the registers, not just the function: until bit 0
 * is set every mini UART register reads zero and ignores writes.  It
 * is the first write, always.
 *
 * The line control data-length field is two bits, not the one the
 * datasheet documents: 8-bit data is LCR = 3.
 *
 * The divisor is core/(8*baud) - 1 from the VideoCore core clock,
 * 250MHz when core_freq=250 pins it (enable_uart=1 does that on a
 * Pi 3).  The firmware has already programmed it by the time the ARM
 * runs, so a non-zero divisor that already gives the wanted rate is
 * left alone rather than recomputed from an assumed clock.
 *
 * Receive is interrupt driven (AUX is BCM2835 interrupt 29, pending
 * bank 1) and also polled through getc from clockpoll() -- the idle
 * loop and the clock -- so console input does not depend on the
 * interrupt route alone.  Both paths take the byte with interrupts
 * masked, so they cannot split a status check from its read.
 *
 * Transmit paces itself against LSR for a bounded time rather than
 * relying on the transmit interrupt: devuart calls kick() under ilock
 * (interrupts masked), and the kernel prints a great deal during
 * chandevreset before init0 first enables interrupts.  Output only
 * falls back to the transmit interrupt if the FIFO stays full for the
 * whole bound.
 *
 * QEMU's bcm2835_aux model ignores LCR, MCR, CNTL and BAUD (they read
 * back zero) and transmits instantly, so the emulator exercises the
 * register protocol, the interrupt and the console path, but only the
 * Pi can validate the baud rate and 8N1 framing.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

extern void gpiofsel(int, int);		/* gpiobcm.c */
extern void gpiopull(int, int);

enum {
	IRQaux	= 29,

	TxPin	= 14,
	RxPin	= 15,
	Alt5	= 2,		/* GPFSEL code for alt5: mini UART on 14/15 */
	Pulloff	= 0,
	Pullup	= 2,

	Consbaud	= 115200,
	Coreclk	= 250000000,

	Txwait	= 1000000,	/* LSR polls per byte before giving up */
	Rxbatch	= 64,
};

/* AUX regs, word offsets from AUX0 */
enum {
	Irq	= 0x00/4,
		UartIrq	= 1<<0,
	Enables	= 0x04/4,
		UartEn	= 1<<0,
	MuIo	= 0x40/4,
	MuIer	= 0x44/4,
		RxIen	= 1<<0,
		TxIen	= 1<<1,
		/*
		 * The BCM2835 erratum: bits 3:2, documented as don't-care,
		 * are needed for receive interrupts to be raised.  Linux's
		 * 8250 driver sets them as its line- and modem-status
		 * enables; QEMU ignores them.
		 */
		RxIenx	= RxIen|1<<2|1<<3,
	MuIir	= 0x48/4,
		Clrfifos	= 6,
	MuLcr	= 0x4c/4,
		Bitsmask	= 3<<0,
		Bits7	= 2<<0,
		Bits8	= 3<<0,
	MuMcr	= 0x50/4,
		RtsN	= 1<<1,
	MuLsr	= 0x54/4,
		RxRdy	= 1<<0,
		RxOver	= 1<<1,
		TxRdy	= 1<<5,		/* FIFO can take a byte */
		TxDone	= 1<<6,		/* FIFO empty, transmitter idle */
	MuMsr	= 0x58/4,
	MuCntl	= 0x60/4,
		RxEn	= 1<<0,
		TxEn	= 1<<1,
		CtsFlow	= 1<<3,
	MuStat	= 0x64/4,
	MuBaud	= 0x68/4,
};

typedef struct Ctlr Ctlr;
struct Ctlr {
	volatile u32	*reg;
	u32	ier;		/* shadow: IER does not read back faithfully */
	ulong	intrs;
	ulong	rxintr;
	ulong	rxpoll;
	ulong	overruns;
	int	fwdivisor;	/* divisor the firmware left, 0 if none */
};

extern PhysUart miniphysuart;

static Ctlr minictlr = {
	.reg	= (volatile u32*)AUX0,
};

Uart miniuart = {
	.regs	= &minictlr,
	.name	= "eia0",
	.freq	= Coreclk,
	.baud	= Consbaud,
	.bits	= 8,
	.stop	= 1,
	.parity	= 'n',
	.phys	= &miniphysuart,
};

static int minibaud(Uart*, int);

static void
setier(Ctlr *c, u32 ier)
{
	c->ier = ier;
	c->reg[MuIer] = ier;
}

static void
miniintr(Ureg*, void *arg)
{
	Uart *uart;
	Ctlr *c;
	int n, lsr;

	uart = arg;
	c = uart->regs;
	c->intrs++;
	for(n = 0; n < Rxbatch; n++){
		lsr = c->reg[MuLsr];
		if(lsr & RxOver)
			c->overruns++;
		if((lsr & RxRdy) == 0)
			break;
		c->rxintr++;
		uartrecv(uart, c->reg[MuIo] & 0xff);
	}
	if((c->ier & TxIen) && (c->reg[MuLsr] & TxRdy))
		uartkick(uart);
}

static Uart*
minipnp(void)
{
	return &miniuart;
}

/* Rate the divisor gives, or 0 for no divisor. */
static int
divrate(Uart *uart, int div)
{
	if(div <= 0)
		return 0;
	return uart->freq / (8 * (div + 1));
}

static void
minienable(Uart *uart, int ie)
{
	Ctlr *c;
	volatile u32 *ap;
	int i, div, rate;

	c = uart->regs;
	ap = c->reg;

	ap[Enables] |= UartEn;		/* first: nothing else works before it */

	/* let whatever the firmware or early boot queued leave the wire */
	for(i = 0; i < Txwait; i++)
		if(ap[MuLsr] & TxDone)
			break;

	div = ap[MuBaud] & 0xffff;
	rate = divrate(uart, div);

	gpiofsel(TxPin, Alt5);
	gpiofsel(RxPin, Alt5);
	gpiopull(TxPin, Pulloff);
	gpiopull(RxPin, Pullup);

	ap[MuCntl] = 0;			/* stop tx and rx while reconfiguring */
	setier(c, 0);
	ap[MuLcr] = Bits8;
	ap[MuMcr] = 0;
	ap[MuIir] = Clrfifos;

	/*
	 * Keep a firmware divisor within 2% of the wanted rate: the
	 * firmware knows its own core clock, and this driver only
	 * assumes one.
	 */
	if(div != 0 && rate > uart->baud - uart->baud/50 && rate < uart->baud + uart->baud/50){
		ap[MuBaud] = div;
		c->fwdivisor = div;
	}else
		minibaud(uart, uart->baud);

	ap[MuCntl] = TxEn|RxEn;

	if(ie){
		intrenable(IRQaux, miniintr, uart, BUSUNKNOWN, uart->name);
		setier(c, RxIenx);
	}
}

static void
minidisable(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	setier(c, 0);
	c->reg[MuCntl] = 0;
	intrdisable(IRQaux, miniintr, uart, BUSUNKNOWN, uart->name);
}

static void
minikick(Uart *uart)
{
	Ctlr *c;
	volatile u32 *ap;
	int i;

	c = uart->regs;
	ap = c->reg;
	if(uart->cts == 0 || uart->blocked)
		return;
	for(;;){
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		for(i = 0; i < Txwait; i++)
			if(ap[MuLsr] & TxRdy)
				break;
		if(i == Txwait)
			break;
		ap[MuIo] = *uart->op++;
	}
	if(uart->op < uart->oe || qlen(uart->oq) != 0)
		setier(c, c->ier | TxIen);
	else if(c->ier & TxIen)
		setier(c, c->ier & ~TxIen);
}

static void
minidobreak(Uart*, int)
{
}

static int
minibaud(Uart *uart, int n)
{
	Ctlr *c;

	c = uart->regs;
	if(uart->freq == 0 || n <= 0)
		return -1;
	c->reg[MuBaud] = (uart->freq + 4*n) / (8*n) - 1;
	c->fwdivisor = 0;
	uart->baud = n;
	return 0;
}

static int
minibits(Uart *uart, int n)
{
	Ctlr *c;
	int set;

	c = uart->regs;
	switch(n){
	case 7:
		set = Bits7;
		break;
	case 8:
		set = Bits8;
		break;
	default:
		return -1;
	}
	c->reg[MuLcr] = (c->reg[MuLcr] & ~Bitsmask) | set;
	uart->bits = n;
	return 0;
}

static int
ministop(Uart *uart, int n)
{
	if(n != 1)
		return -1;
	uart->stop = n;
	return 0;
}

static int
miniparity(Uart *uart, int n)
{
	if(n != 'n')
		return -1;
	uart->parity = n;
	return 0;
}

static void
minimodemctl(Uart *uart, int on)
{
	Ctlr *c;

	c = uart->regs;
	if(on)
		c->reg[MuCntl] |= CtsFlow;
	else
		c->reg[MuCntl] &= ~CtsFlow;
	uart->modem = on;
}

static void
minirts(Uart *uart, int on)
{
	Ctlr *c;

	c = uart->regs;
	if(on)
		c->reg[MuMcr] &= ~RtsN;
	else
		c->reg[MuMcr] |= RtsN;
}

static void
minidonothing(Uart*, int)
{
}

static long
ministatus(Uart *uart, void *buf, long n, long offset)
{
	Ctlr *c;
	char *p;
	int len;

	c = uart->regs;
	p = malloc(READSTR);
	if(p == nil)
		error(Enomem);
	len = snprint(p, READSTR,
		"b%d c0 d0 e0 l%d m%d p%c r0 s%d i1\n"
		"dev(%d) type(mini) framing(0) overruns(%lud) berr(0) serr(0)\n"
		"intrs %lud rxintr %lud rxpoll %lud divisor %ud%s lsr %#ux ier %#ux\n",
		uart->baud, uart->bits, uart->modem, uart->parity, uart->stop,
		uart->dev, c->overruns,
		c->intrs, c->rxintr, c->rxpoll,
		c->reg[MuBaud] & 0xffff, c->fwdivisor? " (firmware)": "",
		c->reg[MuLsr], c->ier);
	n = readstr(offset, buf, n, p);
	USED(len);
	free(p);
	return n;
}

static int
minigetc(Uart *uart)
{
	Ctlr *c;
	int s, ch;

	c = uart->regs;
	s = splhi();
	ch = -1;
	if(c->reg[MuLsr] & RxRdy){
		ch = c->reg[MuIo] & 0xff;
		c->rxpoll++;
	}
	splx(s);
	return ch;
}

static void
miniputc(Uart *uart, int ch)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < Txwait; i++)
		if(c->reg[MuLsr] & TxRdy)
			break;
	c->reg[MuIo] = ch & 0xff;
}

PhysUart miniphysuart = {
	.name		= "mini",
	.pnp		= minipnp,
	.enable		= minienable,
	.disable	= minidisable,
	.kick		= minikick,
	.dobreak	= minidobreak,
	.baud		= minibaud,
	.bits		= minibits,
	.stop		= ministop,
	.parity		= miniparity,
	.modemctl	= minimodemctl,
	.rts		= minirts,
	.dtr		= minidonothing,
	.status		= ministatus,
	.fifo		= minidonothing,
	.getc		= minigetc,
	.putc		= miniputc,
};
