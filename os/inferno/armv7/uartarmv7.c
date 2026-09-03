#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

extern PhysUart armv7physuart;

typedef struct Ctlr Ctlr;
struct Ctlr {
	u32	*base;
};

static Ctlr armv7ctlr = {
	.base	= (u32*)UART0,
};

static Uart armv7uart = {
	.regs	= &armv7ctlr,
	.name	= "eia0",
	.freq	= 24000000,	/* apb-pclk, from the DTB */
	.phys	= &armv7physuart,
};

#define csr32r(c, r)	((c)->base[r])
#define csr32w(c, r, v)	((c)->base[r] = (v))

static Uart*
armv7_pnp(void)
{
	return &armv7uart;
}

static void
uartintr(Ureg*, void *arg)
{
	Uart *uart;
	Ctlr *c;
	int i, ch;

	uart = arg;
	c = uart->regs;
	for(i = 0; i < 128; i++){
		if(csr32r(c, UartFR) & UartFRRXFE)
			break;
		ch = csr32r(c, UartDR) & 0xff;
		uartrecv(uart, ch);
	}
	csr32w(c, UartICR, UartICRALL);
}

static void
armv7_enable(Uart *uart, int ie)
{
	Ctlr *c;

	c = uart->regs;
	USED(ie);
	csr32w(c, UartCR, 0);
	csr32w(c, UartLCRH, UartLCRHWLEN8|UartLCRHFEN);
	csr32w(c, UartCR, UartCRUARTEN|UartCRTXE|UartCRRXE);
}

static void
armv7_disable(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	csr32w(c, UartIMSC, 0);
}

static void
armv7_kick(Uart *uart)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < 128; i++){
		if(csr32r(c, UartFR) & UartFRTXFF)
			break;
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		csr32w(c, UartDR, *uart->op++);
	}
}

static void
armv7_break(Uart*, int)
{
}

static int
armv7_baud(Uart *uart, int baud)
{
	USED(uart, baud);
	return 0;
}

static int
armv7_bits(Uart *uart, int bits)
{
	USED(uart, bits);
	return 0;
}

static int
armv7_stop(Uart *uart, int stop)
{
	USED(uart, stop);
	return 0;
}

static int
armv7_parity(Uart *uart, int parity)
{
	USED(uart, parity);
	return 0;
}

static void
armv7_modemctl(Uart*, int)
{
}

static void
armv7_rts(Uart*, int)
{
}

static void
armv7_dtr(Uart*, int)
{
}

static long
armv7_status(Uart*, void*, long, long)
{
	return 0;
}

static void
armv7_fifo(Uart*, int)
{
}

static int
armv7_getc(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	if(!(csr32r(c, UartFR) & UartFRRXFE))
		return csr32r(c, UartDR) & 0xff;
	return -1;
}

static void
armv7_putc(Uart *uart, int c)
{
	Ctlr *ctlr;
	int i;

	ctlr = uart->regs;
	for(i = 0; i < 1000000; i++)
		if(!(csr32r(ctlr, UartFR) & UartFRTXFF))
			break;
	csr32w(ctlr, UartDR, c);
}

PhysUart armv7physuart = {
	.name		= "armv7",
	.pnp		= armv7_pnp,
	.enable		= armv7_enable,
	.disable	= armv7_disable,
	.kick		= armv7_kick,
	.dobreak	= armv7_break,
	.baud		= armv7_baud,
	.bits		= armv7_bits,
	.stop		= armv7_stop,
	.parity		= armv7_parity,
	.modemctl	= armv7_modemctl,
	.rts		= armv7_rts,
	.dtr		= armv7_dtr,
	.status		= armv7_status,
	.fifo		= armv7_fifo,
	.getc		= armv7_getc,
	.putc		= armv7_putc,
};

void
serialputc(int c)
{
	armv7_putc(&armv7uart, c);
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

	uart = &armv7uart;
	(*uart->phys->enable)(uart, 0);
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
	/* pl011@9000000's SPI is 1 -> GIC IRQ 33 */
	intrenable(33, uartintr, consuart, 0, "uart0");
	c = consuart->regs;
	csr32w(c, UartIMSC, UartIMSCRX);
}
