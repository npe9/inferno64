#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

extern PhysUart virtphysuart;

typedef struct Ctlr Ctlr;
struct Ctlr {
	uchar	*base;
};

static Ctlr virtctlr = {
	.base	= (uchar*)(uintptr)UART0,
};

static Uart virtuart = {
	.regs	= &virtctlr,
	.name	= "eia0",
	.freq	= 1843200,
	.phys	= &virtphysuart,
};

#define csr8r(c, r)	((c)->base[r])
#define csr8w(c, r, v)	((c)->base[r] = (v))

static Uart*
virt_pnp(void)
{
	return &virtuart;
}

static void
uartintr(Ureg*, void *arg)
{
	Uart *uart;
	Ctlr *c;
	int i, ch;

	uart = arg;
	c = uart->regs;
	USED(csr8r(c, UartIIR));	/* ack */
	for(i = 0; i < 128; i++){
		if(!(csr8r(c, UartLSR) & UartLSRDR))
			break;
		ch = csr8r(c, UartRBR);
		uartrecv(uart, ch);
	}
}

static void
virt_enable(Uart *uart, int ie)
{
	Ctlr *c;

	c = uart->regs;
	USED(ie);
	csr8w(c, UartFCR, UartFCRENABLE);
	csr8w(c, UartLCR, UartLCR8N1);
	csr8w(c, UartMCR, 0);
	csr8w(c, UartIER, 0);
}

static void
virt_disable(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	csr8w(c, UartIER, 0);
}

static void
virt_kick(Uart *uart)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < 128; i++){
		if(!(csr8r(c, UartLSR) & UartLSRTHRE))
			break;
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		csr8w(c, UartTHR, *uart->op++);
	}
}

static void
virt_break(Uart*, int)
{
}

static int
virt_baud(Uart *uart, int baud)
{
	USED(uart, baud);
	return 0;
}

static int
virt_bits(Uart *uart, int bits)
{
	USED(uart, bits);
	return 0;
}

static int
virt_stop(Uart *uart, int stop)
{
	USED(uart, stop);
	return 0;
}

static int
virt_parity(Uart *uart, int parity)
{
	USED(uart, parity);
	return 0;
}

static void
virt_modemctl(Uart*, int)
{
}

static void
virt_rts(Uart*, int)
{
}

static void
virt_dtr(Uart*, int)
{
}

static long
virt_status(Uart*, void*, long, long)
{
	return 0;
}

static void
virt_fifo(Uart*, int)
{
}

static int
virt_getc(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	if(csr8r(c, UartLSR) & UartLSRDR)
		return csr8r(c, UartRBR);
	return -1;
}

static void
virt_putc(Uart *uart, int c)
{
	Ctlr *ctlr;
	int i;

	ctlr = uart->regs;
	for(i = 0; i < 100000; i++)
		if(csr8r(ctlr, UartLSR) & UartLSRTHRE)
			break;
	csr8w(ctlr, UartTHR, c);
}

PhysUart virtphysuart = {
	.name		= "virt",
	.pnp		= virt_pnp,
	.enable		= virt_enable,
	.disable	= virt_disable,
	.kick		= virt_kick,
	.dobreak	= virt_break,
	.baud		= virt_baud,
	.bits		= virt_bits,
	.stop		= virt_stop,
	.parity		= virt_parity,
	.modemctl	= virt_modemctl,
	.rts		= virt_rts,
	.dtr		= virt_dtr,
	.status		= virt_status,
	.fifo		= virt_fifo,
	.getc		= virt_getc,
	.putc		= virt_putc,
};

void
serialputc(int c)
{
	virt_putc(&virtuart, c);
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

	uart = &virtuart;
	(*uart->phys->enable)(uart, 0);
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
	intrenable(Uart0IRQ, 0, uartintr, consuart, "uart0");
	c = consuart->regs;
	csr8w(c, UartIER, UartIER_RDA);
}
