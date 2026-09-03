#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

/*
 * The USART of an STM32F3, on the NUCLEO-64's PA2 and PA3, which are
 * wired to the ST-LINK's virtual serial port.  A byte at a time in and
 * out, and a receive interrupt.
 */

extern PhysUart stm32physuart;

typedef struct Ctlr Ctlr;
struct Ctlr {
	ulong	*base;
	int	irq;
};

static Ctlr stm32ctlr = {
	.base	= (ulong*)UART0,
	.irq	= UART0IRQ,
};

static Uart stm32uart = {
	.regs	= &stm32ctlr,
	.name	= "eia0",
	.freq	= UARTCLK,
	.phys	= &stm32physuart,
};

#define csrr(c, r)	((c)->base[(r)/4])
#define csrw(c, r, v)	((c)->base[(r)/4] = (v))

/*
 * Bring the port up before the kernel has a console, so that the first
 * line main() prints comes out.  archreset calls this, after it has
 * turned the clocks on.
 */
void
uartboardinit(void)
{
	Ctlr *c;
	ulong v;

	/*
	 * PA2 and PA3 to alternate function 7, which is USART2, at the
	 * fastest slew the pin will do.
	 */
	v = *(volatile ulong*)(GPIOA+GPIO_MODER);
	v &= ~((3UL<<(2*2)) | (3UL<<(2*3)));
	v |= (2UL<<(2*2)) | (2UL<<(2*3));		/* alternate function */
	*(volatile ulong*)(GPIOA+GPIO_MODER) = v;
	v = *(volatile ulong*)(GPIOA+GPIO_OSPEEDR);
	v |= (3UL<<(2*2)) | (3UL<<(2*3));
	*(volatile ulong*)(GPIOA+GPIO_OSPEEDR) = v;
	v = *(volatile ulong*)(GPIOA+GPIO_AFRL);
	v &= ~((0xfUL<<(4*2)) | (0xfUL<<(4*3)));
	v |= (7UL<<(4*2)) | (7UL<<(4*3));		/* AF7 */
	*(volatile ulong*)(GPIOA+GPIO_AFRL) = v;

	c = &stm32ctlr;
	csrw(c, UartCr1, 0);			/* the rate cannot be set
						 * while it is enabled */
	csrw(c, UartCr2, 0);
	csrw(c, UartCr3, 0);
	csrw(c, UartBrr, (UARTCLK + UARTBAUD/2) / UARTBAUD);
	csrw(c, UartCr1, UartUe|UartTe|UartRe);
	coherence();
}

static Uart*
stm32_pnp(void)
{
	return &stm32uart;
}

static void
uartintr(Ureg*, void *arg)
{
	Uart *uart;
	Ctlr *c;
	int i;

	uart = arg;
	c = uart->regs;
	if(csrr(c, UartIsr) & UartOre)
		csrw(c, UartIcr, UartOre);
	for(i = 0; i < 64; i++){
		if(!(csrr(c, UartIsr) & UartRxne))
			break;
		uartrecv(uart, csrr(c, UartRdr) & 0xff);
	}
}

static void
stm32_enable(Uart *uart, int ie)
{
	USED(uart, ie);
	uartboardinit();
}

static void
stm32_disable(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	csrw(c, UartCr1, 0);
}

static void
stm32_kick(Uart *uart)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < 128; i++){
		if(!(csrr(c, UartIsr) & UartTxe))
			break;
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		csrw(c, UartTdr, *uart->op++);
	}
}

static void
stm32_break(Uart*, int)
{
}

static int
stm32_baud(Uart *uart, int baud)
{
	Ctlr *c;
	ulong cr1;

	if(baud <= 0)
		return -1;
	c = uart->regs;
	cr1 = csrr(c, UartCr1);
	csrw(c, UartCr1, 0);
	csrw(c, UartBrr, (UARTCLK + baud/2) / baud);
	csrw(c, UartCr1, cr1);
	uart->baud = baud;
	return 0;
}

static int
stm32_bits(Uart*, int)
{
	return 0;
}

static int
stm32_stop(Uart*, int)
{
	return 0;
}

static int
stm32_parity(Uart*, int)
{
	return 0;
}

static void
stm32_modemctl(Uart*, int)
{
}

static void
stm32_rts(Uart*, int)
{
}

static void
stm32_dtr(Uart*, int)
{
}

static long
stm32_status(Uart*, void*, long, long)
{
	return 0;
}

static void
stm32_fifo(Uart*, int)
{
}

static int
stm32_getc(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	if(csrr(c, UartIsr) & UartRxne)
		return csrr(c, UartRdr) & 0xff;
	return -1;
}

static void
stm32_putc(Uart *uart, int ch)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < 100000; i++)
		if(csrr(c, UartIsr) & UartTxe)
			break;
	csrw(c, UartTdr, ch & 0xff);
}

PhysUart stm32physuart = {
	.name		= "stm32",
	.pnp		= stm32_pnp,
	.enable		= stm32_enable,
	.disable	= stm32_disable,
	.kick		= stm32_kick,
	.dobreak	= stm32_break,
	.baud		= stm32_baud,
	.bits		= stm32_bits,
	.stop		= stm32_stop,
	.parity		= stm32_parity,
	.modemctl	= stm32_modemctl,
	.rts		= stm32_rts,
	.dtr		= stm32_dtr,
	.status		= stm32_status,
	.fifo		= stm32_fifo,
	.getc		= stm32_getc,
	.putc		= stm32_putc,
};

void
serialputc(int c)
{
	stm32_putc(&stm32uart, c);
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

	uart = &stm32uart;
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
	csrw(c, UartCr1, csrr(c, UartCr1)|UartRxneie);
}
