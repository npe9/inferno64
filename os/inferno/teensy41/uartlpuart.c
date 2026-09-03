#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

/*
 * The LPUART of an i.MX RT, on the Teensy 4.1's pins 0 and 1 -- LPUART6,
 * which is what that board calls Serial1.  There is no fifo watermark
 * work here: a character at a time in and out, and a receive interrupt.
 */

extern PhysUart lpuartphysuart;

typedef struct Ctlr Ctlr;
struct Ctlr {
	ulong	*base;
	int	irq;
};

static Ctlr lpuartctlr = {
	.base	= (ulong*)UART0,
	.irq	= UART0IRQ,
};

static Uart lpuartuart = {
	.regs	= &lpuartctlr,
	.name	= "eia0",
	.freq	= UARTCLK,
	.phys	= &lpuartphysuart,
};

#define csrr(c, r)	((c)->base[(r)/4])
#define csrw(c, r, v)	((c)->base[(r)/4] = (v))

/*
 * The baud rate is the clock divided by an oversampling ratio between
 * four and thirty-two and then by a thirteen bit divisor.  Pick the pair
 * that lands closest; an oversampling of eight or less also needs the
 * sampling on both edges of the clock.
 */
static void
setbaud(Ctlr *c, int baud)
{
	ulong best, bestosr, bestsbr, v;
	ulong osr, sbr, rate, err;

	best = ~0UL;
	bestosr = 16;
	bestsbr = 1;
	for(osr = 4; osr <= 32; osr++){
		sbr = (UARTCLK/osr + baud/2) / baud;
		if(sbr == 0)
			sbr = 1;
		if(sbr > UartSbrmask)
			continue;
		rate = UARTCLK / (osr * sbr);
		err = rate > (ulong)baud? rate - baud: baud - rate;
		if(err < best){
			best = err;
			bestosr = osr;
			bestsbr = sbr;
		}
	}
	v = ((bestosr-1) << UartOsrshift) | (bestsbr & UartSbrmask);
	if(bestosr <= 8)
		v |= UartBothedge;
	csrw(c, UartBaud, v);
}

/*
 * Bring the port up before the kernel has a console, so that the first
 * line main() prints comes out.  archreset calls this.
 */
void
uartboardinit(void)
{
	Ctlr *c;

	/*
	 * Pins first: AD_B0_02 and AD_B0_03 are LPUART6's transmit and
	 * receive on alternate function two.  The pad settings are a
	 * medium drive with the keeper off, which is what a serial line
	 * wants; 0x10b0 is the value every i.MX RT example uses for one.
	 */
	*(volatile ulong*)IOMUXC_MUX_AD_B0_02 = 2;
	*(volatile ulong*)IOMUXC_MUX_AD_B0_03 = 2;
	*(volatile ulong*)IOMUXC_PAD_AD_B0_02 = 0x10b0;
	*(volatile ulong*)IOMUXC_PAD_AD_B0_03 = 0x10b0;

	c = &lpuartctlr;
	csrw(c, UartGlobal, UartRst);		/* reset the port */
	csrw(c, UartGlobal, 0);
	csrw(c, UartCtrl, 0);			/* the baud rate cannot be
						 * changed while it is running */
	setbaud(c, UARTBAUD);
	csrw(c, UartFifo, UartRxflush|UartTxflush);
	csrw(c, UartCtrl, UartTe|UartRe);
	coherence();
}

static Uart*
lpuart_pnp(void)
{
	return &lpuartuart;
}

static void
uartintr(Ureg*, void *arg)
{
	Uart *uart;
	Ctlr *c;
	int i;

	uart = arg;
	c = uart->regs;
	if(csrr(c, UartStat) & UartOr)
		csrw(c, UartStat, UartOr);	/* write one to clear */
	for(i = 0; i < 64; i++){
		if(!(csrr(c, UartStat) & UartRdrf))
			break;
		uartrecv(uart, csrr(c, UartData) & 0xff);
	}
}

static void
lpuart_enable(Uart *uart, int ie)
{
	USED(uart, ie);
	uartboardinit();
}

static void
lpuart_disable(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	csrw(c, UartCtrl, 0);
}

static void
lpuart_kick(Uart *uart)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < 128; i++){
		if(!(csrr(c, UartStat) & UartTdre))
			break;
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		csrw(c, UartData, *uart->op++);
	}
}

static void
lpuart_break(Uart*, int)
{
}

static int
lpuart_baud(Uart *uart, int baud)
{
	Ctlr *c;
	ulong ctl;

	if(baud <= 0)
		return -1;
	c = uart->regs;
	ctl = csrr(c, UartCtrl);
	csrw(c, UartCtrl, 0);
	setbaud(c, baud);
	csrw(c, UartCtrl, ctl);
	uart->baud = baud;
	return 0;
}

static int
lpuart_bits(Uart*, int)
{
	return 0;
}

static int
lpuart_stop(Uart*, int)
{
	return 0;
}

static int
lpuart_parity(Uart*, int)
{
	return 0;
}

static void
lpuart_modemctl(Uart*, int)
{
}

static void
lpuart_rts(Uart*, int)
{
}

static void
lpuart_dtr(Uart*, int)
{
}

static long
lpuart_status(Uart*, void*, long, long)
{
	return 0;
}

static void
lpuart_fifo(Uart*, int)
{
}

static int
lpuart_getc(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	if(csrr(c, UartStat) & UartRdrf)
		return csrr(c, UartData) & 0xff;
	return -1;
}

static void
lpuart_putc(Uart *uart, int ch)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < 100000; i++)
		if(csrr(c, UartStat) & UartTdre)
			break;
	csrw(c, UartData, ch & 0xff);
}

PhysUart lpuartphysuart = {
	.name		= "lpuart",
	.pnp		= lpuart_pnp,
	.enable		= lpuart_enable,
	.disable	= lpuart_disable,
	.kick		= lpuart_kick,
	.dobreak	= lpuart_break,
	.baud		= lpuart_baud,
	.bits		= lpuart_bits,
	.stop		= lpuart_stop,
	.parity		= lpuart_parity,
	.modemctl	= lpuart_modemctl,
	.rts		= lpuart_rts,
	.dtr		= lpuart_dtr,
	.status		= lpuart_status,
	.fifo		= lpuart_fifo,
	.getc		= lpuart_getc,
	.putc		= lpuart_putc,
};

void
serialputc(int c)
{
	lpuart_putc(&lpuartuart, c);
}

void
serialputs(char *s, int n)
{
	if(n < 0){
		while(*s){
			if(*s == '\n')
				serialputc('\r');
			serialputc(*s++);
		}
		return;
	}
	while(--n >= 0){
		if(*s == '\n')
			serialputc('\r');
		serialputc(*s++);
	}
}

void (*serwrite)(char*, int) = serialputs;

static int
consolerx(Queue*, int ch)
{
	extern Queue *kbdq;

	if(kbdq == nil)
		return 0;
	return kbdcr2nl(kbdq, ch);
}

void
uartconsole(void)
{
	Uart *uart;

	uart = &lpuartuart;
	consuart = uart;
	uart->console = 1;
}

void
uartconsolesetup(void)
{
	Ctlr *c;

	if(consuart == nil)
		return;
	consuart->putc = consolerx;
	c = consuart->regs;
	intrenable(c->irq, uartintr, consuart, 0, "eia0");
	csrw(c, UartCtrl, UartTe|UartRe|UartRie);
}
