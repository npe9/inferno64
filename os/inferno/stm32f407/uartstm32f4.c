#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

/*
 * The USART of an STM32F4, on PA2 and PA3.  A byte at a time in and
 * out, and a receive interrupt.
 *
 * Not the F3's, which is why this is a second file rather than an
 * argument to the first: the F3 has ISR, RDR and TDR where this has
 * SR and DR, its enable bit is 0 where this is 13, and it clears an
 * overrun through an ICR this does not have.  The two parts share a
 * name and a manufacturer and not a register map.
 *
 * PA2 and PA3 on alternate function 7 are USART2, which is the
 * ST-Link virtual port on a NUCLEO-F407 and the first serial chardev
 * of qemu's netduinoplus2.  A board that brings the console out
 * somewhere else changes this and UART0 in mem.h and nothing more.
 */

extern PhysUart stm32f4physuart;

typedef struct Ctlr Ctlr;
struct Ctlr {
	ulong	*base;
	int	irq;
};

static Ctlr stm32f4ctlr = {
	.base	= (ulong*)UART0,
	.irq	= UART0IRQ,
};

static Uart stm32f4uart = {
	.regs	= &stm32f4ctlr,
	.name	= "eia0",
	.freq	= CPUHZ,		/* replaced by uartboardinit */
	.phys	= &stm32f4physuart,
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

	c = &stm32f4ctlr;
	csrw(c, UartCr1, 0);			/* the rate cannot be set
						 * while it is enabled */
	csrw(c, UartCr2, 0);
	csrw(c, UartCr3, 0);
	/*
	 * The divisor comes from apb1hz, which archstm32f407.c sets to
	 * whatever clock the boot actually settled on.  A kernel that
	 * assumed the PLL had come up and had it not would have a
	 * console at a tenth of the baud it meant, which looks like a
	 * dead board rather than a clock that did not start.
	 */
	stm32f4uart.freq = apb1hz;
	csrw(c, UartBrr, (apb1hz + UARTBAUD/2) / UARTBAUD);
	csrw(c, UartCr1, UartUe|UartTe|UartRe);
	coherence();
}

static Uart*
stm32f4_pnp(void)
{
	return &stm32f4uart;
}

static void
uartintr(Ureg*, void *arg)
{
	Uart *uart;
	Ctlr *c;
	int i;

	uart = arg;
	c = uart->regs;
	/*
	 * An overrun is cleared by reading SR and then DR, which is
	 * what the loop below does anyway; the F3's separate ICR does
	 * not exist here.
	 */
	USED(i);
	for(i = 0; i < 64; i++){
		if(!(csrr(c, UartSr) & UartRxne))
			break;
		uartrecv(uart, csrr(c, UartDr) & 0xff);
	}
}

static void
stm32f4_enable(Uart *uart, int ie)
{
	USED(uart, ie);
	uartboardinit();
}

static void
stm32f4_disable(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	csrw(c, UartCr1, 0);
}

static void
stm32f4_kick(Uart *uart)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < 128; i++){
		if(!(csrr(c, UartSr) & UartTxe))
			break;
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		csrw(c, UartDr, *uart->op++);
	}
}

static void
stm32f4_break(Uart*, int)
{
}

static int
stm32f4_baud(Uart *uart, int baud)
{
	Ctlr *c;
	ulong cr1;

	if(baud <= 0)
		return -1;
	c = uart->regs;
	cr1 = csrr(c, UartCr1);
	csrw(c, UartCr1, 0);
	csrw(c, UartBrr, (apb1hz + baud/2) / baud);
	csrw(c, UartCr1, cr1);
	uart->baud = baud;
	return 0;
}

static int
stm32f4_bits(Uart*, int)
{
	return 0;
}

static int
stm32f4_stop(Uart*, int)
{
	return 0;
}

static int
stm32f4_parity(Uart*, int)
{
	return 0;
}

static void
stm32f4_modemctl(Uart*, int)
{
}

static void
stm32f4_rts(Uart*, int)
{
}

static void
stm32f4_dtr(Uart*, int)
{
}

static long
stm32f4_status(Uart*, void*, long, long)
{
	return 0;
}

static void
stm32f4_fifo(Uart*, int)
{
}

static int
stm32f4_getc(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	if(csrr(c, UartSr) & UartRxne)
		return csrr(c, UartDr) & 0xff;
	return -1;
}

static void
stm32f4_putc(Uart *uart, int ch)
{
	Ctlr *c;
	int i;

	c = uart->regs;
	for(i = 0; i < 100000; i++)
		if(csrr(c, UartSr) & UartTxe)
			break;
	csrw(c, UartDr, ch & 0xff);
}

PhysUart stm32f4physuart = {
	.name		= "stm32f4",
	.pnp		= stm32f4_pnp,
	.enable		= stm32f4_enable,
	.disable	= stm32f4_disable,
	.kick		= stm32f4_kick,
	.dobreak	= stm32f4_break,
	.baud		= stm32f4_baud,
	.bits		= stm32f4_bits,
	.stop		= stm32f4_stop,
	.parity		= stm32f4_parity,
	.modemctl	= stm32f4_modemctl,
	.rts		= stm32f4_rts,
	.dtr		= stm32f4_dtr,
	.status		= stm32f4_status,
	.fifo		= stm32f4_fifo,
	.getc		= stm32f4_getc,
	.putc		= stm32f4_putc,
};

void
serialputc(int c)
{
	stm32f4_putc(&stm32f4uart, c);
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

	uart = &stm32f4uart;
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
