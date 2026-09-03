/*
 * The DesignWare UART of an Allwinner D1: the 16550 register set with
 * the registers a word apart, and a divisor that has to be programmed
 * because nothing before this kernel necessarily did.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

extern PhysUart dwphysuart;

typedef struct Ctlr Ctlr;
struct Ctlr {
	uchar	*base;
	int	irq;
};

static Ctlr dwctlr = {
	.base	= (uchar*)(uintptr)UART0,
	.irq	= Uart0IRQ,
};

static Uart dwuart = {
	.regs	= &dwctlr,
	.name	= "eia0",
	.freq	= UARTCLK,
	.phys	= &dwphysuart,
};

/*
 * The registers are a word apart on this part and have to be read a word
 * at a time -- the D1 wires the UART up with reg-io-width four -- which
 * is the only way it differs from any other 16550.
 */
#define csrr(c, r)	(((volatile ulong*)(c)->base)[r])
#define csrw(c, r, v)	(((volatile ulong*)(c)->base)[r] = (v))

/*
 * Bring the port up before the kernel has a console, so that the first
 * line main() prints comes out.  archreset calls this.
 */
void
uartboardinit(void)
{
	Ctlr *c;
	ulong div;

	c = &dwctlr;
	div = (UARTCLK + 8*UARTBAUD) / (16*UARTBAUD);
	if(div == 0)
		div = 1;
	csrw(c, UartIER, 0);
	csrw(c, UartLCR, UartLCR8N1|UartLCRDLAB);
	csrw(c, UartDLL, div & 0xff);
	csrw(c, UartDLH, (div>>8) & 0xff);
	csrw(c, UartLCR, UartLCR8N1);
	csrw(c, UartFCR, UartFCRENABLE);
	csrw(c, UartMCR, 0);
}

static Uart*
dw_pnp(void)
{
	return &dwuart;
}

static void
uartintr(Ureg*, void *arg)
{
	Uart *uart;
	Ctlr *c;
	int i, ch;

	uart = arg;
	c = uart->regs;
	USED(csrr(c, UartIIR));	/* ack */
	for(i = 0; i < 128; i++){
		if(!(csrr(c, UartLSR) & UartLSRDR))
			break;
		ch = csrr(c, UartRBR);
		uartrecv(uart, ch);
	}
}

static void
dw_enable(Uart *uart, int ie)
{
	USED(uart, ie);
	uartboardinit();
}

static void
dw_disable(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	csrw(c, UartIER, 0);
}

static void
dw_kick(Uart *uart)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < 128; i++){
		if(!(csrr(c, UartLSR) & UartLSRTHRE))
			break;
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		csrw(c, UartTHR, *uart->op++);
	}
}

static void
dw_break(Uart*, int)
{
}

static int
dw_baud(Uart *uart, int baud)
{
	USED(uart, baud);
	return 0;
}

static int
dw_bits(Uart *uart, int bits)
{
	USED(uart, bits);
	return 0;
}

static int
dw_stop(Uart *uart, int stop)
{
	USED(uart, stop);
	return 0;
}

static int
dw_parity(Uart *uart, int parity)
{
	USED(uart, parity);
	return 0;
}

static void
dw_modemctl(Uart*, int)
{
}

static void
dw_rts(Uart*, int)
{
}

static void
dw_dtr(Uart*, int)
{
}

static long
dw_status(Uart*, void*, long, long)
{
	return 0;
}

static void
dw_fifo(Uart*, int)
{
}

static int
dw_getc(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	if(csrr(c, UartLSR) & UartLSRDR)
		return csrr(c, UartRBR);
	return -1;
}

static void
dw_putc(Uart *uart, int c)
{
	Ctlr *ctlr;
	int i;

	ctlr = uart->regs;
	for(i = 0; i < 100000; i++)
		if(csrr(ctlr, UartLSR) & UartLSRTHRE)
			break;
	csrw(ctlr, UartTHR, c);
}

PhysUart dwphysuart = {
	.name		= "virt",
	.pnp		= dw_pnp,
	.enable		= dw_enable,
	.disable	= dw_disable,
	.kick		= dw_kick,
	.dobreak	= dw_break,
	.baud		= dw_baud,
	.bits		= dw_bits,
	.stop		= dw_stop,
	.parity		= dw_parity,
	.modemctl	= dw_modemctl,
	.rts		= dw_rts,
	.dtr		= dw_dtr,
	.status		= dw_status,
	.fifo		= dw_fifo,
	.getc		= dw_getc,
	.putc		= dw_putc,
};

void
serialputc(int c)
{
	dw_putc(&dwuart, c);
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

	uart = &dwuart;
	consuart = uart;
	uart->console = 1;
	/* leave screenputs nil — putstrn0 also uartputs when serialoq==nil */
}

/*
 * Wire console RX into kbdq after consinit has created the queue.
 * Called from main after chandevreset().
 */
void
uartconsolesetup(void)
{
	Ctlr *c;

	if(consuart == nil)
		return;
	consuart->putc = consolerx;
	c = consuart->regs;
	intrenable(c->irq, uartintr, consuart, 0, "uart0");
	csrw(c, UartIER, UartIER_RDA);
}
