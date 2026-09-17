/*
 * BCM2837 PL011 (UART0, 0x3f201000): the raspi3b console, on GPIO 14/15
 * when config.txt says dtoverlay=disable-bt.  Its clock is the
 * firmware's fixed 48MHz UART clock; its interrupt is GPU IRQ 57.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

extern PhysUart pl011physuart;
extern void gpiofsel(int, int);		/* gpiobcm.c */

extern Uart miniuart;			/* uartmini.c */
extern int gpiofselget(int);		/* gpiobcm.c */

enum {
	Altpl011 = 4,		/* GPFSEL code for alt0: PL011 on GPIO 14/15 */
	Altmini	= 2,		/* GPFSEL code for alt5: mini UART there */
};

static char *consfrom = "pl011";

static int pl011_baud(Uart*, int);

enum {
	Putcspin = 1000000,	/* bound: a dead UART must not hang a panic */
	Consbaud = 115200,	/* what the far end of a Pi's serial cable expects */
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
	u32	*base;
};

static Ctlr pl011ctlr = {
	.base	= (u32*)UART0,
};

static Uart pl011uart = {
	.regs	= &pl011ctlr,
	.name	= "eia0",
	.freq	= 48000000,	/* BCM2837 PL011 UART clock set by the firmware */
	.phys	= &pl011physuart,
};

#define csr32r(c, r)	(((volatile u32*)(c)->base)[r])
#define csr32w(c, r, v)	(((volatile u32*)(c)->base)[r] = (v))

static Uart*
pl011_pnp(void)
{
	return &pl011uart;
}

static void
uartintr(Ureg*, void *arg)
{
	Uart *uart;
	Ctlr *c;
	u32 mis;
	int i, ch;

	uart = arg;
	c = uart->regs;
	mis = csr32r(c, UartMIS);
	/*
	 * RX fires only when the FIFO reaches its trigger level (half full,
	 * 8 bytes); a shorter line waits for the receive timeout, 32 bits of
	 * idle line after the last byte.
	 */
	if(mis & (UartIMSCRX|UartIMSCRT)){
		for(i = 0; i < 128; i++){
			if(csr32r(c, UartFR) & UartFRRXFE)
				break;
			ch = csr32r(c, UartDR) & 0xff;
			uartrecv(uart, ch);
		}
	}
	csr32w(c, UartICR, UartICRALL);
	if(mis & UartIMSCTX)
		uartkick(uart);
}

static void
pl011_enable(Uart *uart, int ie)
{
	Ctlr *c;

	c = uart->regs;
	USED(ie);
	/*
	 * The firmware leaves UART0 usable, which is why main's first banner
	 * appears on real hardware.  Do not then depend on its inherited baud
	 * divisors: program the BCM2837's 48MHz PL011 explicitly for 115200
	 * (48MHz/(16*115200) = 26 + 3/64).  QEMU ignores the baud rate but
	 * models these standard PL011 registers.
	 *
	 * The clock is the constant in pl011uart, not a mailbox query: this
	 * runs from uartconsole(), before mmuinit(), and on the Pi anything
	 * that takes a lock before the MMU is on hangs the A53 (the
	 * exclusive monitor is UNPREDICTABLE on Device memory).
	 *
	 * CR first: the divisors and LCR_H may only be changed while the
	 * UART is disabled, and LCR_H must be written last because writing
	 * it is what latches IBRD and FBRD.
	 */
	csr32w(c, UartCR, 0);
	csr32w(c, UartICR, UartICRALL);
	pl011_baud(uart, Consbaud);
	csr32w(c, UartLCRH, UartLCRHWLEN8|UartLCRHFEN);
	csr32w(c, UartCR, UartCRUARTEN|UartCRTXE|UartCRRXE);
}

static void
pl011_disable(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	csr32w(c, UartIMSC, 0);
}

static void
pl011_kick(Uart *uart)
{
	Ctlr *c;
	int i, lo;

	c = uart->regs;
	/*
	 * Fill the FIFO with what fits and stop; do not wait for room.
	 *
	 * This used to wait, bounded, for room after every byte, so that
	 * everything queued left in one call.  kick() runs under ilock,
	 * so a 500-byte burst held interrupts off for over 40ms, and the
	 * receive FIFO -- 16 bytes, 1.4ms at 115200 -- overran behind it:
	 * on the board, a command typed while it was printing arrived as
	 * "cat /n/dosuaex hKRE".
	 *
	 * The wait was there because output left to the transmit
	 * interrupt once stopped on the board.  That was
	 * uartconsolesetup() overwriting IMSC and clearing TXIM, fixed
	 * since.  The PL011 raises TX as its FIFO falls through the
	 * trigger level, which a FIFO filled here is certain to do, and
	 * uarttxpoll() below kicks again from the clock if an edge is
	 * ever missed, so a stall costs at most a tick.
	 */
	/*
	 * With interrupts off, waiting for the transmit interrupt is
	 * waiting for something that cannot come: nothing will run the
	 * handler and nothing will run the clock poll either.  That is
	 * the shutdown path -- a reboot printed "#S/sd" and stopped
	 * there, mid-line, because the rest of the line sat in the queue
	 * with no way out -- and it is panic()'s path too.  So when
	 * interrupts are off, drain by polling, bounded per byte.
	 */
	lo = islo();
	for(;;){
		if(csr32r(c, UartFR) & UartFRTXFF){
			if(lo)
				break;
			for(i = 0; i < Putcspin; i++)
				if((csr32r(c, UartFR) & UartFRTXFF) == 0)
					break;
			if(csr32r(c, UartFR) & UartFRTXFF)
				break;
		}
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		csr32w(c, UartDR, *uart->op++);
	}
	if(uart->op < uart->oe || qlen(uart->oq) != 0)
		csr32w(c, UartIMSC, csr32r(c, UartIMSC) | UartIMSCTX);
	else
		csr32w(c, UartIMSC, csr32r(c, UartIMSC) & ~UartIMSCTX);
}

/*
 * The transmit interrupt's safety net: on every clock tick, if output
 * is waiting and the FIFO has drained, kick.  A transmit interrupt the
 * PL011 did not raise -- its TX line is a transition through the
 * trigger level, not a level -- would otherwise leave the rest of a
 * line queued until some unrelated write came along.
 */
static void
uarttxpoll(void)
{
	Uart *uart;
	Ctlr *c;

	uart = consuart;
	if(uart == nil || uart->oq == nil || uart != &pl011uart)
		return;
	c = uart->regs;
	if((csr32r(c, UartFR) & UartFRTXFE) == 0)
		return;
	if(uart->op < uart->oe || qlen(uart->oq) != 0)
		uartkick(uart);
}

static void
pl011_break(Uart*, int)
{
}

/*
 * Program the baud divisors.  BAUDDIV = UARTCLK/(16*baud), split into a
 * 16-bit integer part in IBRD and a 6-bit fraction in FBRD; the pair is
 * only latched when LCR_H is written afterwards.  At 48MHz and 115200
 * this gives 26 and 3, the values the board was brought up with.
 */
static int
pl011_baud(Uart *uart, int baud)
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
	if(uart->enabled)
		csr32w(c, UartLCRH, csr32r(c, UartLCRH));	/* latch */
	uart->baud = baud;
	return 0;
}

static int
pl011_bits(Uart *uart, int bits)
{
	USED(uart, bits);
	return 0;
}

static int
pl011_stop(Uart *uart, int stop)
{
	USED(uart, stop);
	return 0;
}

static int
pl011_parity(Uart *uart, int parity)
{
	USED(uart, parity);
	return 0;
}

/*
 * Hardware flow control, which on this board is not optional.
 *
 * The BCM43438's Bluetooth side is an H4 controller on this same
 * PL011, and it drops bytes without RTS/CTS -- the radio has no other
 * way to say "stop".  The lines are GPIO 16 and 17 in alt3.  A console
 * does not need them and nothing asked for them before, so this was a
 * stub; asking for it is "m1" on the uart's ctl file (devuart(3)).
 */
static void
pl011_modemctl(Uart *uart, int on)
{
	Ctlr *c = uart->regs;
	u32 cr;

	cr = csr32r(c, UartCR);
	if(on){
		gpiofsel(16, Altpl011);		/* CTS */
		gpiofsel(17, Altpl011);		/* RTS */
		cr |= UartCRRTSEN|UartCRCTSEN;
	} else
		cr &= ~(UartCRRTSEN|UartCRCTSEN);
	/*
	 * CR may only be changed with the UART disabled, and LCR_H must
	 * be rewritten afterwards to latch the line settings.
	 */
	csr32w(c, UartCR, cr & ~UartCRUARTEN);
	csr32w(c, UartLCRH, csr32r(c, UartLCRH));
	csr32w(c, UartCR, cr);
	uart->modem = on;
	uart->cts = 1;
}

static void
pl011_rts(Uart*, int)
{
}

static void
pl011_dtr(Uart*, int)
{
}

static long
pl011_status(Uart*, void*, long, long)
{
	return 0;
}

static void
pl011_fifo(Uart*, int)
{
}

static int
pl011_getc(Uart *uart)
{
	Ctlr *c;

	c = uart->regs;
	if(!(csr32r(c, UartFR) & UartFRRXFE))
		return csr32r(c, UartDR) & 0xff;
	return -1;
}

static void
pl011_putc(Uart *uart, int c)
{
	Ctlr *ctlr;
	int i;

	ctlr = uart->regs;
	/*
	 * Real PL011 hardware must not have DR written while its transmit FIFO
	 * is full.  Bound the wait so a broken/emulator FR cannot deadlock the
	 * only diagnostic channel during bring-up.
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
 * character at a time through pl011_putc(), so if the wait is wrong
 * they arrive short, and the numbering says where.
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

PhysUart pl011physuart = {
	.name		= "pl011",
	.pnp		= pl011_pnp,
	.enable		= pl011_enable,
	.disable	= pl011_disable,
	.kick		= pl011_kick,
	.dobreak	= pl011_break,
	.baud		= pl011_baud,
	.bits		= pl011_bits,
	.stop		= pl011_stop,
	.parity		= pl011_parity,
	.modemctl	= pl011_modemctl,
	.rts		= pl011_rts,
	.dtr		= pl011_dtr,
	.status		= pl011_status,
	.fifo		= pl011_fifo,
	.getc		= pl011_getc,
	.putc		= pl011_putc,
};

void
serialputc(int c)
{
	Uart *uart = consuart != nil? consuart: &pl011uart;

	(*uart->phys->putc)(uart, c);
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

/* Decimal to the console with no fmt and no lock: safe before mmuinit. */
void
serialputdec(ulong v)
{
	char buf[24];
	int i;

	i = sizeof buf;
	do{
		buf[--i] = '0' + v%10;
		v /= 10;
	}while(v != 0 && i > 0);
	serialputs(buf+i, sizeof buf - i);
}

static void
puthex(uvlong v, int digits)
{
	char buf[16];
	int i;

	if(digits > sizeof buf)
		digits = sizeof buf;
	for(i = digits-1; i >= 0; i--){
		buf[i] = "0123456789abcdef"[v & 0xf];
		v >>= 4;
	}
	serialputs(buf, digits);
}

void
serialputreg(char *name, uvlong v, int digits)
{
	serialputs(" ", 1);
	serialputs(name, -1);
	serialputs(" ", 1);
	puthex(v, digits);
}

void
uartconsole(void)
{
	Uart *uart;

	/*
	 * Use the UART the firmware put on the header, and do not move it.
	 *
	 * On a Pi 3 the PL011 is Bluetooth's and the mini UART is the
	 * header's; config.txt's dtoverlay=disable-bt swaps them, and that
	 * overlay is a file on the card.  When this board's own file
	 * server damaged the FAT and the overlays directory lost its
	 * contents, the firmware silently fell back to the default: every
	 * kernel print went out the Bluetooth pins and the board looked
	 * dead, while the mini UART's one line came through perfectly.
	 *
	 * GPIO 14's function says which arrangement is in force -- alt0 is
	 * the PL011, alt5 the mini UART -- so the console follows the
	 * firmware rather than assuming, and a missing overlay costs
	 * nothing.  With no firmware at all (QEMU -kernel, where the pin
	 * is still an input) the PL011 is the one that is wired, and the
	 * kernel takes its pins.
	 *
	 * Leaving the PL011 alone when the firmware kept it for Bluetooth
	 * is also what makes Bluetooth possible later: it is that UART.
	 */
	if(gpiofselget(14) == Altmini){
		uart = &miniuart;
		consfrom = "mini uart, the firmware's choice";
	} else {
		uart = &pl011uart;
		consfrom = "pl011";
		gpiofsel(14, Altpl011);
		gpiofsel(15, Altpl011);
	}
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
	print("console: %s\n", consfrom);
	if(consuart != &pl011uart){
		/*
		 * The mini UART arms its own interrupt (AUX IRQ 29) from
		 * its enable, and drains from the clock poll like this one.
		 */
		(*consuart->phys->enable)(consuart, 1);
		addclock0link(uarttxpoll, 0);
		return;
	}
	/* BCM2837 PL011 is VideoCore/GPU interrupt 57 (pending bank 2). */
	intrenable(57, uartintr, consuart, 0, "uart0");
	c = consuart->regs;
	/*
	 * Add the receive interrupt; do not replace the mask.  The kernel
	 * has already queued console output during chandevreset, and kick()
	 * armed the transmit interrupt to drain it.  Writing IMSC = RX here
	 * cleared that, and since qio only kicks a queue that was empty,
	 * nothing re-armed it: on the Pi every later line stayed queued.
	 * QEMU's PL011 empties its FIFO instantly, so kick() never had
	 * output left over there and never needed the interrupt.  Kick once
	 * more in case the FIFO drained while the mask was being changed.
	 */
	csr32w(c, UartIMSC, csr32r(c, UartIMSC) | UartIMSCRX | UartIMSCRT);
	uartkick(consuart);
	addclock0link(uarttxpoll, 0);
}
