/*
 * SiFive UART0 (sifive,uart0) — QEMU sifive_u / sifive_e.
 * Board mem.h: UART0 base; io.h: Uart0IRQ.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

extern PhysUart sifivephysuart;

typedef struct Ctlr Ctlr;
struct Ctlr {
	u32	*regs;
};

static Ctlr sifivectlr = {
	.regs	= (u32*)(uintptr)UART0,
};

static Uart sifiveuart = {
	.regs	= &sifivectlr,
	.name	= "eia0",
	.freq	= 16000000,
	.phys	= &sifivephysuart,
};

#define csr32r(c, r)	((c)->regs[(r)/4])
#define csr32w(c, r, v)	((c)->regs[(r)/4] = (v))

static Uart*
sifive_pnp(void)
{
	return &sifiveuart;
}

static void
uartintr(Ureg*, void *arg)
{
	Uart *uart;
	Ctlr *c;
	u32 v;
	int i;

	uart = arg;
	c = uart->regs;
	for(i = 0; i < 128; i++){
		v = csr32r(c, SfuRxdata);
		if(v & SfuRxEmpty)
			break;
		uartrecv(uart, v & 0xFF);
	}
	USED(csr32r(c, SfuIp));
}

static void
sifive_enable(Uart *uart, int ie)
{
	Ctlr *c;

	c = uart->regs;
	USED(ie);
	/* QEMU ignores baud; keep a sane divisor for real silicon. */
	csr32w(c, SfuDiv, 16);
	csr32w(c, SfuTxctrl, SfuTxen);
	csr32w(c, SfuRxctrl, SfuRxen);
	csr32w(c, SfuIe, 0);
}

static void
sifive_disable(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	csr32w(c, SfuIe, 0);
}

static int
txready(Ctlr *c)
{
	int i;

	for(i = 0; i < 1000000; i++)
		if(!(csr32r(c, SfuTxdata) & SfuTxFull))
			return 1;
	return 0;
}

static void
sifive_kick(Uart *uart)
{
	Ctlr *c;
	int i;

	/*
	 * SiFive UART TX FIFO is only 8 deep and QEMU models TxFull.
	 * After uartreset, print goes through serialoq → kick; if we
	 * return on TxFull, nothing re-kicks (no TX IRQ; uartclock does
	 * not).  Virt's NS16550 often drains fast enough to mask this.
	 * Wait for space so the console queue can empty.
	 */
	c = uart->regs;
	if(!(csr32r(c, SfuTxctrl) & SfuTxen))
		csr32w(c, SfuTxctrl, SfuTxen);
	for(i = 0; i < 1024; i++){
		if(!txready(c))
			break;
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		csr32w(c, SfuTxdata, *uart->op++);
	}
}

static void
sifive_break(Uart*, int)
{
}

static int
sifive_baud(Uart *uart, int baud)
{
	USED(uart, baud);
	return 0;
}

static int
sifive_bits(Uart *uart, int bits)
{
	USED(uart, bits);
	return 0;
}

static int
sifive_stop(Uart *uart, int stop)
{
	USED(uart, stop);
	return 0;
}

static int
sifive_parity(Uart *uart, int parity)
{
	USED(uart, parity);
	return 0;
}

static void
sifive_modemctl(Uart*, int)
{
}

static void
sifive_rts(Uart*, int)
{
}

static void
sifive_dtr(Uart*, int)
{
}

static long
sifive_status(Uart*, void*, long, long)
{
	return 0;
}

static void
sifive_fifo(Uart*, int)
{
}

static int
sifive_getc(Uart *uart)
{
	Ctlr *c;
	u32 v;

	c = uart->regs;
	v = csr32r(c, SfuRxdata);
	if(v & SfuRxEmpty)
		return -1;
	return v & 0xFF;
}

static void
sifive_putc(Uart *uart, int ch)
{
	Ctlr *c;
	int i;
	u32 tx;

	c = uart->regs;
	/* Keep TX enabled; some paths leave txctrl cleared. */
	if(!(csr32r(c, SfuTxctrl) & SfuTxen))
		csr32w(c, SfuTxctrl, SfuTxen);
	for(i = 0; i < 1000000; i++){
		tx = csr32r(c, SfuTxdata);
		if(!(tx & SfuTxFull))
			break;
	}
	csr32w(c, SfuTxdata, ch & 0xFF);
}

PhysUart sifivephysuart = {
	.name		= "sifive",
	.pnp		= sifive_pnp,
	.enable		= sifive_enable,
	.disable	= sifive_disable,
	.kick		= sifive_kick,
	.dobreak	= sifive_break,
	.baud		= sifive_baud,
	.bits		= sifive_bits,
	.stop		= sifive_stop,
	.parity		= sifive_parity,
	.modemctl	= sifive_modemctl,
	.rts		= sifive_rts,
	.dtr		= sifive_dtr,
	.status		= sifive_status,
	.fifo		= sifive_fifo,
	.getc		= sifive_getc,
	.putc		= sifive_putc,
};

void
serialputc(int c)
{
	sifive_putc(&sifiveuart, c);
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

	uart = &sifiveuart;
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
	/* RX via clockpoll; TX drained in kick (see sifive_kick). */
	intrenable(Uart0IRQ, 0, uartintr, consuart, "uart0");
	c = consuart->regs;
	csr32w(c, SfuIe, SfuIeRxwm);
}
