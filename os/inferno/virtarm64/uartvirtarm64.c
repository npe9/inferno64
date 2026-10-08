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
	u32 mis;

	uart = arg;
	c = uart->regs;
	mis = csr32r(c, UartMIS);
	for(i = 0; i < 128; i++){
		if(csr32r(c, UartFR) & UartFRRXFE)
			break;
		ch = csr32r(c, UartDR) & 0xff;
		uartrecv(uart, ch);
	}
	/*
	 * Clear what was actually seen, not everything.
	 *
	 * This said UartICRALL, and with a console that receives as well
	 * as sends that is a transmit interrupt thrown away unhandled.
	 * The receive loop above runs until the receive fifo is empty or
	 * 128 characters have gone by, so under steady input it always
	 * runs its full bound -- and the transmit interrupt that asserted
	 * during those 128 characters is not in the mis sampled before
	 * the loop, so it is not serviced here, and UartICRALL then
	 * clears it anyway.  The PL011 raises TXI on the transition of
	 * the fifo level past its trigger; with the fifo already below
	 * the trigger there is no further transition, so it never asserts
	 * again.  Output stops for good and the kernel runs on.
	 *
	 * Writing mis back clears exactly the causes this pass is about
	 * to handle and leaves anything raised since, which the next
	 * interrupt will pick up.
	 *
	 * Reproduced rather than reasoned: the same kernel and workload
	 * for 400 seconds, once with serial input and once without.
	 * Without input the console produced 197,736 bytes; with input it
	 * produced 7,353 and stopped during boot.  Four t2a instances in
	 * five went quiet the same way and a Compute Engine serial
	 * console always has input.
	 */
	csr32w(c, UartICR, mis);
	/*
	 * Transmit side.  Without this the driver only ever pushed what
	 * fitted in the fifo at the moment something called kick, and
	 * whatever was left waited for the next print -- so the last burst
	 * of a boot sat in the queue forever and every log ended cut off
	 * mid-word.  See doc/multicore-plan.ms.
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

/*
 * How many times the transmit interrupt was kept enabled because the
 * QUEUE still had output although the staging buffer did not.  Each one
 * of these is a console that would have stopped for good before this
 * test looked past the staging buffer.
 *
 * THIS NUMBER GOING UP IS THE FIX WORKING, not a regression.  It counts
 * hangs avoided, so a larger value means the condition arose more often
 * and was handled every time; driving it to zero means removing the
 * test.  Said here because the obvious instinct on seeing a counter
 * climb is to make it stop, and because a sibling session had a case
 * where fixing a defect raised the diagnostic count from 4 to 15 and
 * "did my fix reduce the warnings" would have told it to revert.
 */
ulong uarttxsaved;

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
	 * Ask for a transmit interrupt while output remains, and only
	 * while it does.  Leaving TXIM enabled with an empty fifo is an
	 * interrupt every time the fifo drains past its trigger level,
	 * which on a quiet console is a storm; leaving it disabled is the
	 * bug this fixes.  uartintr() calls uartkick() when it fires, and
	 * that comes back here to push the rest or take the request away.
	 *
	 * "Output remains" means anywhere -- the staging buffer OR the
	 * queue behind it -- and testing only the staging buffer is how
	 * this driver lost a console for good.
	 *
	 * The loop above is bounded at 128 writes.  uartstageoutput()
	 * stages up to Stagesize, which is 1024, so op meets oe on every
	 * eighth full pass, and a pass runs to its bound whenever the fifo
	 * drains as fast as it is filled -- which is what a virtual serial
	 * port does.  Exit at the bound with op == oe and the old test
	 * said "nothing left" while blocks were still queued, so TXIM went
	 * off and nothing would ever turn it back on: a writer only kicks
	 * when Qstarve is set, and qconsume() sets Qstarve only when it
	 * finds the queue EMPTY, which it is not.  The console stops for
	 * good and the kernel runs on.
	 *
	 * That is exactly what four t2a instances in five did, on both
	 * *parallelvm arms, with the instances still RUNNING and Compute
	 * Engine's serial API reporting a frozen byte offset.
	 */
	if(uart->op < uart->oe || qlen(uart->oq) > 0){
		if(uart->op >= uart->oe)
			uarttxsaved++;	/* a hang avoided; see clock.c */
		csr32w(c, UartIMSC, UartIMSCRX|UartIMSCTX);
	}else
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
