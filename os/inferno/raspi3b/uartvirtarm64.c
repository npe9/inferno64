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
	int i, ch, mis;

	uart = arg;
	c = uart->regs;
	mis = csr32r(c, UartMIS);

	for(i = 0; i < 128; i++){
		if(csr32r(c, UartFR) & UartFRRXFE)
			break;
		ch = csr32r(c, UartDR) & 0xff;
		uartrecv(uart, ch);
	}
	csr32w(c, UartICR, UartICRALL);

	/*
	 * Restart transmission.  Without this the console output queue is
	 * drained only as a side effect of qbwrite()'s wakeup path, which
	 * fires when a reader was starving and not otherwise: nothing
	 * reads serialoq, so under load the queue grows without bound and
	 * every byte written to the console is silently lost while the
	 * machine runs on.  See the comment on virtarm64_kick().
	 */
	if(mis & UartIMSCTX)
		uartkick(uart);
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

	/*
	 * Ask for a transmit interrupt exactly while there is something
	 * left to send.
	 *
	 * This is what makes output independent of who happens to call
	 * the kick.  qbwrite() invokes a queue's kick only when a starving
	 * reader is being woken or when Qkick is set, and nothing sets
	 * Qkick anywhere in the tree; nothing reads the console output
	 * queue either, since the uart drains it from here.  So without a
	 * transmit interrupt the queue is drained only by coincidence,
	 * and a workload that stops producing those coincidences -- kfs
	 * running, say -- loses every byte of console output from that
	 * point on while the machine carries on perfectly well.
	 *
	 * Leaving the mask set once the FIFO has drained would have the
	 * PL011 re-assert immediately and storm, so it is cleared as soon
	 * as there is nothing left.
	 */
	if(uart->op < uart->oe || (uart->oq != nil && qlen(uart->oq) > 0))
		csr32w(c, UartIMSC, UartIMSCRX|UartIMSCTX);
	else
		csr32w(c, UartIMSC, UartIMSCRX);
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
	volatile int i;

	ctlr = uart->regs;
	/* QEMU raspi3b PL011 FR flags are unreliable; pace with a short
	 * fixed delay (the garbling was the other cores, now parked). */
	csr32w(ctlr, UartDR, c);
	for(i = 0; i < 30000; i++)
		;
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
