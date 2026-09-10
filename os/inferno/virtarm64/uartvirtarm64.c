#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

extern PhysUart virtarm64physuart;

typedef struct Ctlr Ctlr;
struct Ctlr {
	u32	*base;
};

static Ctlr virtarm64ctlr = {
	.base	= (u32*)UART0,
};

static Uart virtarm64uart = {
	.regs	= &virtarm64ctlr,
	.name	= "eia0",
	.freq	= 24000000,	/* apb-pclk, from the DTB (same as armv7) */
	.phys	= &virtarm64physuart,
};

#define csr32r(c, r)	((c)->base[r])
#define csr32w(c, r, v)	((c)->base[r] = (v))

static Uart*
virtarm64_pnp(void)
{
	return &virtarm64uart;
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
virtarm64_enable(Uart *uart, int ie)
{
	Ctlr *c;

	c = uart->regs;
	USED(ie);
	csr32w(c, UartCR, 0);
	csr32w(c, UartLCRH, UartLCRHWLEN8|UartLCRHFEN);
	csr32w(c, UartCR, UartCRUARTEN|UartCRTXE|UartCRRXE);
}

static void
virtarm64_disable(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	csr32w(c, UartIMSC, 0);
}

static void
virtarm64_kick(Uart *uart)
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
virtarm64_break(Uart*, int)
{
}

static int
virtarm64_baud(Uart *uart, int baud)
{
	USED(uart, baud);
	return 0;
}

static int
virtarm64_bits(Uart *uart, int bits)
{
	USED(uart, bits);
	return 0;
}

static int
virtarm64_stop(Uart *uart, int stop)
{
	USED(uart, stop);
	return 0;
}

static int
virtarm64_parity(Uart *uart, int parity)
{
	USED(uart, parity);
	return 0;
}

static void
virtarm64_modemctl(Uart*, int)
{
}

static void
virtarm64_rts(Uart*, int)
{
}

static void
virtarm64_dtr(Uart*, int)
{
}

static long
virtarm64_status(Uart*, void*, long, long)
{
	return 0;
}

static void
virtarm64_fifo(Uart*, int)
{
}

static int
virtarm64_getc(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	if(!(csr32r(c, UartFR) & UartFRRXFE))
		return csr32r(c, UartDR) & 0xff;
	return -1;
}

static void
virtarm64_putc(Uart *uart, int c)
{
	Ctlr *ctlr;
	int i;

	ctlr = uart->regs;
	for(i = 0; i < 1000000; i++)
		if(!(csr32r(ctlr, UartFR) & UartFRTXFF))
			break;
	csr32w(ctlr, UartDR, c);
}

PhysUart virtarm64physuart = {
	.name		= "virtarm64",
	.pnp		= virtarm64_pnp,
	.enable		= virtarm64_enable,
	.disable	= virtarm64_disable,
	.kick		= virtarm64_kick,
	.dobreak	= virtarm64_break,
	.baud		= virtarm64_baud,
	.bits		= virtarm64_bits,
	.stop		= virtarm64_stop,
	.parity		= virtarm64_parity,
	.modemctl	= virtarm64_modemctl,
	.rts		= virtarm64_rts,
	.dtr		= virtarm64_dtr,
	.status		= virtarm64_status,
	.fifo		= virtarm64_fifo,
	.getc		= virtarm64_getc,
	.putc		= virtarm64_putc,
};

void
serialputc(int c)
{
	virtarm64_putc(&virtarm64uart, c);
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

	uart = &virtarm64uart;
	(*uart->phys->enable)(uart, 0);
	consuart = uart;
	uart->console = 1;
}

/*
 * Move the console to the UART ACPI's SPCR names, the way
 * os/inferno/pc/uarti8250.c's i8250spcrconsole() does on the PC.  A
 * server does not put its console where this board's mem.h says, and
 * the SPCR is the only place that says where it is.
 *
 * Only the base moves.  The register layout does not: interface type 3
 * is a PL011 and 0x0D and 0x0E are the SBSA generic UART, which is a
 * PL011 with the modem and DMA parts removed and is register
 * compatible over everything this driver touches.  Anything else -- a
 * 16550, say -- this board has no driver for, so it leaves the console
 * where it is rather than writing PL011 registers at a 16550.
 *
 * Called from main() before uartconsole(), so it prints nothing: there
 * is no console yet, which is the whole point.  It records what it did
 * and acpiinit() prints that later.  Doing it the other way round --
 * reading the SPCR at acpiinit() time, after uartconsole() has already
 * programmed the UART -- cannot work on the machine it exists for: a
 * wrong base means uartconsole() faults before trapinit() has
 * installed a handler, the firmware's own handler takes it, and the
 * kernel never reaches acpiinit().
 */
int spcrstate;			/* see the strings in spcrwhy() */
uvlong spcrwas;			/* base before the move */

char*
spcrwhy(void)
{
	switch(spcrstate){
	case 0:	return "no SPCR";
	case 1:	return "console already where the SPCR says";
	case 2:	return "console moved to the SPCR's address";
	case 3:	return "SPCR address is not in system memory";
	case 4:	return "SPCR interface type is not a pl011";
	}
	return "unknown";
}

int
spcrconsole(void)
{
	Ctlr *c;

	spcrstate = 0;
	if(acpiuart == 0)
		return 0;
	if(acpiuartspace != 0){		/* not system memory */
		spcrstate = 3;
		return 0;
	}
	if(acpiuartiface != 3 && acpiuartiface != 0x0D && acpiuartiface != 0x0E){
		spcrstate = 4;
		return 0;
	}
	c = &virtarm64ctlr;
	spcrwas = (uvlong)(uintptr)c->base;
	if(spcrwas == acpiuart){
		spcrstate = 1;
		return 0;
	}
	c->base = (u32*)(uintptr)acpiuart;
	spcrstate = 2;
	return 1;
}

void
uartconsolesetup(void)
{
	Ctlr *c;
	int irq;

	if(consuart == nil)
		return;
	consuart->putc = consolerx;
	/*
	 * pl011@9000000's SPI is 1 -> GIC IRQ 33 is what the device tree
	 * says and what this board used before there was any ACPI; the
	 * SPCR's global system interrupt is what a server says.
	 */
	irq = 33;
	if(acpiuartgsi != 0 && acpiuartgsi != irq){
		print("spcr: console irq %d from the firmware, board says %d\n",
			acpiuartgsi, irq);
		irq = acpiuartgsi;
	}
	intrenable(irq, uartintr, consuart, 0, "uart0");
	c = consuart->regs;
	csr32w(c, UartIMSC, UartIMSCRX);
}
