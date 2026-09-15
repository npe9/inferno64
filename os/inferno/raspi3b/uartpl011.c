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

ulong pl011intrs;
ulong pl011rxchars;

static void
uartintr(Ureg*, void *arg)
{
	Uart *uart;
	Ctlr *c;
	u32 mis;
	int i, ch;

	uart = arg;
	c = uart->regs;
	pl011intrs++;
	mis = csr32r(c, UartMIS);
	if(mis & UartIMSCRX){
		for(i = 0; i < 128; i++){
			if(csr32r(c, UartFR) & UartFRRXFE)
				break;
			ch = csr32r(c, UartDR) & 0xff;
			pl011rxchars++;
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
	 */
	csr32w(c, UartCR, 0);
	csr32w(c, UartICR, UartICRALL);
	csr32w(c, UartIBRD, 26);
	csr32w(c, UartFBRD, 3);
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
	int i;

	c = uart->regs;
	/*
	 * Send everything staged or queued now, waiting (bounded) for FIFO
	 * room rather than leaving the rest to the transmit interrupt.  On
	 * the Pi, output left to TXIM stopped: a TICK-OK line queued after
	 * interrupts were on never appeared, IMSC read back with TXIM clear
	 * and no PL011 interrupt arrived in the following half second.  The
	 * PL011 raises TX only as its FIFO level falls through the trigger,
	 * which QEMU (draining instantly, raising it as a level) never
	 * reproduces.  kick() runs under ilock, so this holds interrupts off
	 * for about 87us a byte; TXIM remains the fallback if the wait runs
	 * out.
	 */
	for(;;){
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		for(i = 0; i < 1000000; i++)
			if((csr32r(c, UartFR) & UartFRTXFF) == 0)
				break;
		if(csr32r(c, UartFR) & UartFRTXFF){
			((volatile uvlong*)0x20000000)[112+24]++;	/* crumb: kick wait ran out */
			break;
		}
		csr32w(c, UartDR, *uart->op++);
	}
	if(uart->op < uart->oe || qlen(uart->oq) != 0)
		csr32w(c, UartIMSC, csr32r(c, UartIMSC) | UartIMSCTX);
	else
		csr32w(c, UartIMSC, csr32r(c, UartIMSC) & ~UartIMSCTX);
}

static void
pl011_break(Uart*, int)
{
}

static int
pl011_baud(Uart *uart, int baud)
{
	USED(uart, baud);
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

static void
pl011_modemctl(Uart*, int)
{
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
	for(i = 0; i < 1000000; i++)
		if((csr32r(ctlr, UartFR) & UartFRTXFF) == 0)
			break;
	csr32w(ctlr, UartDR, c);
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
	pl011_putc(&pl011uart, c);
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
puthex(ulong v, int digits)
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
serialputreg(char *name, ulong v, int digits)
{
	serialputs(" ", 1);
	serialputs(name, -1);
	serialputs(" ", 1);
	puthex(v, digits);
}

/*
 * Receive bisection, one call per boot stage.  Typed input reached the
 * PL011 early in boot (a polled probe saw it) but its receive FIFO was
 * empty at the shell, so something between the two stops bytes arriving.
 * Each call asks for a key on the console, polls the FIFO for up to four
 * seconds with interrupts masked (so no handler can take the byte first),
 * and prints what it got with the UART's configuration, the pin
 * functions of GPIO 14/15 (GPFSEL1) and 32/33 (GPFSEL3, the Bluetooth
 * UART pins), and the live levels of all four pins.  The first stage that
 * reports none, with the key sent, is where receive was lost.
 * Output goes straight to the data register, not the output queue.
 */
void
uartrxprobe(char *stage)
{
	volatile u32 *u, *g;
	uvlong hz, t, end;
	int s, ch;
	u32 lev0, lev1;

	u = (volatile u32*)UART0;
	g = (volatile u32*)GPIO0;
	s = splhi();
	serialputs("RXPROBE ", -1);
	serialputs(stage, -1);
	serialputs(" send\n", -1);
	cntfrq(&hz);
	cycles(&t);
	end = t + 4*hz;
	ch = -1;
	while(t < end){
		if((u[UartFR] & UartFRRXFE) == 0){
			ch = u[UartDR] & 0xfff;
			break;
		}
		cycles(&t);
	}
	lev0 = g[0x34/4];
	lev1 = g[0x38/4];
	serialputs("RXPROBE ", -1);
	serialputs(stage, -1);
	if(ch >= 0){
		serialputs(" got ", -1);
		puthex(ch, 3);
	}else
		serialputs(" none", -1);
	serialputreg("cr", u[UartCR], 4);
	serialputreg("lcrh", u[UartLCRH], 2);
	serialputreg("ibrd", u[UartIBRD], 4);
	serialputreg("fbrd", u[UartFBRD], 2);
	serialputreg("imsc", u[UartIMSC], 3);
	serialputreg("fr", u[UartFR], 3);
	serialputreg("ris", u[UartRIS], 3);
	serialputreg("gpfsel1", g[1], 8);
	serialputreg("gpfsel3", g[3], 8);
	serialputreg("lev14", (lev0>>14)&1, 1);
	serialputreg("lev15", (lev0>>15)&1, 1);
	serialputreg("lev32", (lev1>>0)&1, 1);
	serialputreg("lev33", (lev1>>1)&1, 1);
	serialputs("\n", -1);
	splx(s);
}

void
uartconsole(void)
{
	Uart *uart;

	uart = &pl011uart;
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
	csr32w(c, UartIMSC, csr32r(c, UartIMSC) | UartIMSCRX);
	uartkick(consuart);
}
