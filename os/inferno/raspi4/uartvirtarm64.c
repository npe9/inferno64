#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

extern PhysUart virtarm64physuart;
extern int mboxgetclock(int, u32*);	/* mailbox.c: firmware clock rate */

static int virtarm64_baud(Uart*, int);

enum {
	Putcspin = 1000000,	/* bound: a dead UART must not hang a panic */
	Consbaud = 115200,	/* what the far end of a Pi's serial cable expects */
	Uartclkid = 2,		/* firmware clock id for the PL011 */
	Uartclkdflt = 48000000,	/* if the firmware will not say; Pi 3 default */
};

/*
 * How hard the polled path has had to wait.  Reported by
 * uartputccheck(); see the console chapter of
 * doc/raspi3b-completion-plan.ms.
 */
static int putcfull;		/* writes that met a full TX FIFO */
static int putcspin;		/* worst spin, in iterations */
static int putcdrop;		/* writes that gave up and wrote anyway */

typedef struct Ctlr Ctlr;
struct Ctlr {
	/*
	 * volatile, and it has to be.  A loop that polls FR and does
	 * nothing else -- which is what waiting for TX FIFO room is --
	 * lets the compiler hoist the load out and spin on a register.
	 * virtarm64_kick() never showed this because its loop also
	 * stores to UARTDR through the same pointer, which blocks the
	 * optimisation; virtarm64_putc()'s wait did nothing at all until
	 * this word was qualified.
	 */
	volatile u32	*base;
};

static Ctlr virtarm64ctlr = {
	.base	= (u32*)UART0,
};

static Uart virtarm64uart = {
	.regs	= &virtarm64ctlr,
	.name	= "eia0",
	/*
	 * Filled in from the firmware by virtarm64_enable().  The 24 MHz
	 * that used to sit here was the -M virt apb-pclk, copied in with
	 * the rest of the driver, and it is not this part's clock on any
	 * Pi; it never mattered only because nothing programmed the baud
	 * divisors either.
	 */
	.freq	= 0,
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
	 * Continue a transmission the kick could not finish.  Once the
	 * TX FIFO fills, virtarm64_kick() returns with bytes still on
	 * the queue and arms TXIM; this is what comes back for the
	 * remainder.  Without it a write longer than the FIFO stalls
	 * after the first FIFO-full and the tail of it is delivered
	 * only if some later, unrelated write happens to kick again.
	 *
	 * This is reached only because trap() dispatches the
	 * controller's second GPU bank; the PL011 is GPU IRQ 57.
	 */
	if(mis & UartIMSCTX)
		uartkick(uart);
}

static void
virtarm64_enable(Uart *uart, int ie)
{
	Ctlr *c;
	u32 clk;

	c = uart->regs;
	USED(ie);

	/*
	 * Ask the firmware for UARTCLK the first time through.  It is not
	 * a property of the part and it differs between Pi models, so a
	 * constant here would be programming the wrong baud rate on every
	 * board that disagrees with the constant.  If the mailbox will
	 * not answer -- it is up well before this on a Pi, but this runs
	 * early -- fall back to the Pi 3 default rather than leaving the
	 * divisors unwritten, and say so.
	 */
	if(uart->freq <= 0){
		if(mboxgetclock(Uartclkid, &clk) == 0)
			uart->freq = clk;
		else {
			uart->freq = Uartclkdflt;
			print("uart: firmware would not report the uart clock; "
				"assuming %d Hz\n", Uartclkdflt);
		}
	}

	/* CR first: the divisors and LCR_H may only be changed while
	 * the UART is disabled, and LCR_H must be written last because
	 * writing it is what latches IBRD and FBRD. */
	csr32w(c, UartCR, 0);
	virtarm64_baud(uart, Consbaud);
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

	c = uart->regs;
	for(;;){
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
	 * Two separate things have to hold for console output to drain,
	 * and each was broken here:
	 *
	 *   - something must call this kick in the first place.
	 *     qbwrite() calls a queue's kick only when it is waking a
	 *     starving reader or when Qkick is set, and nothing reads
	 *     serialoq, so devuart.c must open oq with Qkick -- it now
	 *     does.  That starts a burst.
	 *
	 *   - once the TX FIFO is full this returns with bytes still
	 *     queued, and only a transmit interrupt comes back for the
	 *     rest.  That continues the burst.  The loop above stops on
	 *     TXFF and nothing else, which is what a Pi does; it used to
	 *     be capped at sixteen as well, because QEMU's PL011 modelled
	 *     no transmit FIFO and never set TXFF, so an unbounded loop
	 *     always emptied the queue in one call and the continuation
	 *     below was never reached under emulation.  The model has the
	 *     FIFO now (tools/qemu-patches, 0018), so the cap is gone and
	 *     the loop here is the one that runs on the board.
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

/*
 * Program the baud divisors.  BAUDDIV = UARTCLK/(16*baud), split into a
 * 16-bit integer part in IBRD and a 6-bit fraction in FBRD; the pair is
 * only latched when LCR_H is written afterwards, which is why the
 * caller must write LCR_H last.
 *
 * This was a stub returning 0, so the divisors were never written at
 * all and the part ran at whatever the firmware left.  On a Pi that is
 * usually right by luck, since the firmware sets up the console before
 * the kernel starts; it is right by luck all the same, and it means
 * uart->baud reported a rate nothing had programmed.
 */
static int
virtarm64_baud(Uart *uart, int baud)
{
	Ctlr *c;
	u32 div;

	if(baud <= 0 || uart->freq <= 0)
		return -1;
	c = uart->regs;
	/* 64*UARTCLK/(16*baud) = 4*UARTCLK/baud, rounded. */
	div = (4 * (uvlong)uart->freq + baud/2) / baud;
	if(div < 64 || (div >> 6) > 0xffff)
		return -1;		/* outside what the divisors can express */
	csr32w(c, UartIBRD, div >> 6);
	csr32w(c, UartFBRD, div & 0x3f);
	uart->baud = baud;
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
	/*
	 * Wait for room in the transmit FIFO.  This wrote blind and then
	 * spun for a fixed count instead, which was safe only because
	 * QEMU's PL011 had no transmit FIFO to overrun and set TXFF
	 * never; on a Pi -- and now on the model, see
	 * tools/qemu-patches 0018 -- a blind write to a full FIFO is a
	 * character on the floor, and this is the path panic() and
	 * iprint() use.  Bounded, so a dead UART cannot hang a panic;
	 * uartputccheck() reports whether the bound is ever approached.
	 */
	for(i = 0; i < Putcspin; i++)
		if((csr32r(ctlr, UartFR) & UartFRTXFF) == 0)
			break;
	if(i > 0){
		putcfull++;
		if(i > putcspin)
			putcspin = i;
	}
	if(i == Putcspin)
		putcdrop++;
	csr32w(ctlr, UartDR, c);
}

/*
 * Drive the polled path hard enough to fill the transmit FIFO many
 * times over, and say what happened.  This is the path panic() and
 * iprint() take, and it is the one path that cannot report a dropped
 * character by any other means -- there is no queue behind it and no
 * interrupt in front of it, so a write to a full FIFO is simply gone.
 *
 * The eight numbered lines below are the evidence: they are written a
 * character at a time through virtarm64_putc(), so if the wait is
 * wrong they arrive short, and the numbering says where.
 */
void
uartputccheck(void)
{
	int i, full, spin, drop;
	char buf[64];

	putcfull = putcspin = putcdrop = 0;
	for(i = 0; i < 8; i++){
		snprint(buf, sizeof buf,
			"uart putc burst line %d 0123456789abcdefghijklmnopqr\n", i);
		serialputs(buf, -1);
	}
	full = putcfull;
	spin = putcspin;
	drop = putcdrop;

	if(drop > 0)
		print("UART-PUTC-FAIL %d of 8 lines hit the %d-iteration bound\n",
			drop, Putcspin);
	else if(full == 0)
		print("UART-PUTC-NONE the transmit FIFO never filled; "
			"nothing here was tested\n");
	else
		print("UART-PUTC-OK polled writes waited for FIFO room %d times, "
			"worst wait %d iterations of %d\n", full, spin, Putcspin);
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
	/*
	 * INTID 153, which is SPI 121.  The Pi 3B's 57 was a GPU IRQ on
	 * the legacy controller and means nothing here: on this board
	 * the PL011 is wired to the GIC directly.  Same part, same
	 * driver, different wire.
	 */
	intrenable(IrqUart0, uartintr, consuart, 0, "uart0");
	c = consuart->regs;
	csr32w(c, UartIMSC, UartIMSCRX);
}
