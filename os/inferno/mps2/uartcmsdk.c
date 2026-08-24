#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

/*
 * The CMSDK APB UART of the MPS2 FPGA images.  It has a one byte
 * transmit holding register and a one byte receive register, no fifo and
 * no modem lines, so most of what a PhysUart can be asked to do is not
 * there to do.
 */

extern PhysUart cmsdkphysuart;

typedef struct Ctlr Ctlr;
struct Ctlr {
	ulong	*base;
	int	irq;
};

static Ctlr cmsdkctlr = {
	.base	= (ulong*)UART0,
	.irq	= UART0IRQ,
};

static Uart cmsdkuart = {
	.regs	= &cmsdkctlr,
	.name	= "eia0",
	.freq	= CPUHZ,
	.phys	= &cmsdkphysuart,
};

#define csrr(c, r)	((c)->base[(r)/4])
#define csrw(c, r, v)	((c)->base[(r)/4] = (v))

/*
 * Bring the port up before the kernel has a console, so that the first
 * line main() prints comes out.  archreset calls this.
 */
void
uartboardinit(void)
{
	Ctlr *c;

	c = &cmsdkctlr;
	csrw(c, UartCtrl, 0);
	csrw(c, UartBauddiv, 16);	/* the model ignores the rate */
	csrw(c, UartCtrl, UartTxen|UartRxen);
}

static Uart*
cmsdk_pnp(void)
{
	return &cmsdkuart;
}

static void
uartintr(Ureg*, void *arg)
{
	Uart *uart;
	Ctlr *c;
	int i;

	uart = arg;
	c = uart->regs;
	csrw(c, UartIntstatus, UartRxirq);	/* write one to clear */
	for(i = 0; i < 64; i++){
		if(!(csrr(c, UartState) & UartRxfull))
			break;
		uartrecv(uart, csrr(c, UartData) & 0xff);
	}
}

static void
cmsdk_enable(Uart *uart, int ie)
{
	Ctlr *c;

	USED(ie);
	c = uart->regs;
	csrw(c, UartCtrl, 0);
	csrw(c, UartBauddiv, 16);	/* the model ignores the rate */
	csrw(c, UartCtrl, UartTxen|UartRxen);
}

static void
cmsdk_disable(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	csrw(c, UartCtrl, 0);
}

static void
cmsdk_kick(Uart *uart)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < 128; i++){
		if(csrr(c, UartState) & UartTxfull)
			break;
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		csrw(c, UartData, *uart->op++);
	}
}

static void
cmsdk_break(Uart*, int)
{
}

static int
cmsdk_baud(Uart*, int)
{
	return 0;
}

static int
cmsdk_bits(Uart*, int)
{
	return 0;
}

static int
cmsdk_stop(Uart*, int)
{
	return 0;
}

static int
cmsdk_parity(Uart*, int)
{
	return 0;
}

static void
cmsdk_modemctl(Uart*, int)
{
}

static void
cmsdk_rts(Uart*, int)
{
}

static void
cmsdk_dtr(Uart*, int)
{
}

static long
cmsdk_status(Uart*, void*, long, long)
{
	return 0;
}

static void
cmsdk_fifo(Uart*, int)
{
}

static int
cmsdk_getc(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	if(csrr(c, UartState) & UartRxfull)
		return csrr(c, UartData) & 0xff;
	return -1;
}

static void
cmsdk_putc(Uart *uart, int ch)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < 100000; i++)
		if(!(csrr(c, UartState) & UartTxfull))
			break;
	csrw(c, UartData, ch & 0xff);
}

PhysUart cmsdkphysuart = {
	.name		= "cmsdk",
	.pnp		= cmsdk_pnp,
	.enable		= cmsdk_enable,
	.disable	= cmsdk_disable,
	.kick		= cmsdk_kick,
	.dobreak	= cmsdk_break,
	.baud		= cmsdk_baud,
	.bits		= cmsdk_bits,
	.stop		= cmsdk_stop,
	.parity		= cmsdk_parity,
	.modemctl	= cmsdk_modemctl,
	.rts		= cmsdk_rts,
	.dtr		= cmsdk_dtr,
	.status		= cmsdk_status,
	.fifo		= cmsdk_fifo,
	.getc		= cmsdk_getc,
	.putc		= cmsdk_putc,
};

void
serialputc(int c)
{
	cmsdk_putc(&cmsdkuart, c);
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

	uart = &cmsdkuart;
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
	c = consuart->regs;
	intrenable(c->irq, 0, uartintr, consuart, "uart0");
	csrw(c, UartCtrl, UartTxen|UartRxen|UartRxirqen);
}
