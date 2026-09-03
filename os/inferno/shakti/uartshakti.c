#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

/*
 * Shakti UART (QEMU's shakti_uart, hw/char/shakti_uart.c): 32-bit
 * registers, not the 16550 the virt board's UART is.  TX and RX are
 * separate word registers; STATUS carries a TX-full and an
 * RX-not-empty bit.  This is the one piece that differs from the virt
 * board - the SRAM/PLIC/CLINT and the whole M-mode boot are identical.
 */
enum {
	ShBaud		= 0x00,
	ShTx		= 0x04,
	ShRx		= 0x08,
	ShStatus	= 0x0c,
	ShDelay		= 0x10,
	ShControl	= 0x14,
	ShIntEn		= 0x18,

	ShTxFull	= 1<<1,
	ShRxNotEmpty	= 1<<2,

	ShIntTx		= 1<<0,
	ShIntRx		= 1<<1,
};

extern PhysUart shaktiphysuart;

typedef struct Ctlr Ctlr;
struct Ctlr {
	u32	*base;
};

static Ctlr shaktictlr = {
	.base	= (u32*)(uintptr)UART0,
};

static Uart shaktiuart = {
	.regs	= &shaktictlr,
	.name	= "eia0",
	.freq	= 1843200,
	.phys	= &shaktiphysuart,
};

#define csr32r(c, r)	((c)->base[(r)/4])
#define csr32w(c, r, v)	((c)->base[(r)/4] = (v))

static Uart*
shakti_pnp(void)
{
	return &shaktiuart;
}

static void
uartintr(Ureg*, void *arg)
{
	Uart *uart;
	Ctlr *c;
	int i;

	uart = arg;
	c = uart->regs;
	for(i = 0; i < 128; i++){
		if(!(csr32r(c, ShStatus) & ShRxNotEmpty))
			break;
		uartrecv(uart, csr32r(c, ShRx) & 0xff);
	}
}

static void
shakti_enable(Uart *uart, int)
{
	Ctlr *c = uart->regs;
	csr32w(c, ShIntEn, 0);
}

static void
shakti_disable(Uart *uart)
{
	Ctlr *c = uart->regs;
	csr32w(c, ShIntEn, 0);
}

static void
shakti_kick(Uart *uart)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < 128; i++){
		if(csr32r(c, ShStatus) & ShTxFull)
			break;
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		csr32w(c, ShTx, *uart->op++);
	}
}

static void	shakti_break(Uart*, int){}
static int	shakti_baud(Uart*, int){ return 0; }
static int	shakti_bits(Uart*, int){ return 0; }
static int	shakti_stop(Uart*, int){ return 0; }
static int	shakti_parity(Uart*, int){ return 0; }
static void	shakti_modemctl(Uart*, int){}
static void	shakti_rts(Uart*, int){}
static void	shakti_dtr(Uart*, int){}
static long	shakti_status(Uart*, void*, long, long){ return 0; }
static void	shakti_fifo(Uart*, int){}

static int
shakti_getc(Uart *uart)
{
	Ctlr *c = uart->regs;

	if(csr32r(c, ShStatus) & ShRxNotEmpty)
		return csr32r(c, ShRx) & 0xff;
	return -1;
}

static void
shakti_putc(Uart *uart, int ch)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < 100000; i++)
		if(!(csr32r(c, ShStatus) & ShTxFull))
			break;
	csr32w(c, ShTx, ch & 0xff);
}

PhysUart shaktiphysuart = {
	.name		= "shakti",
	.pnp		= shakti_pnp,
	.enable		= shakti_enable,
	.disable	= shakti_disable,
	.kick		= shakti_kick,
	.dobreak	= shakti_break,
	.baud		= shakti_baud,
	.bits		= shakti_bits,
	.stop		= shakti_stop,
	.parity		= shakti_parity,
	.modemctl	= shakti_modemctl,
	.rts		= shakti_rts,
	.dtr		= shakti_dtr,
	.status		= shakti_status,
	.fifo		= shakti_fifo,
	.getc		= shakti_getc,
	.putc		= shakti_putc,
};

void
serialputc(int c)
{
	shakti_putc(&shaktiuart, c);
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

	uart = &shaktiuart;
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
	intrenable(Uart0IRQ, uartintr, consuart, 0, "uart0");
	c = consuart->regs;
	csr32w(c, ShIntEn, ShIntRx);
}
