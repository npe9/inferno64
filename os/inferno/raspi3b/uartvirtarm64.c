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

/*
 * The PL011 is the Pi 3B's Bluetooth UART in the firmware's default
 * pin arrangement, so it is eia1 and not the console; uartmini.c is.
 */
static Uart virtarm64uart = {
	.regs	= &virtarm64ctlr,
	.name	= "eia1",
	.freq	= 48000000,	/* BCM2837 PL011 UART clock set by the firmware */
	.phys	= &virtarm64physuart,
};

#define csr32r(c, r)	(((volatile u32*)(c)->base)[r])
#define csr32w(c, r, v)	(((volatile u32*)(c)->base)[r] = (v))

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
	u32 mis;
	int i, ch;

	uart = arg;
	c = uart->regs;
	mis = csr32r(c, UartMIS);
	if(mis & UartIMSCRX){
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
virtarm64_enable(Uart *uart, int ie)
{
	Ctlr *c;

	c = uart->regs;
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
	if(ie){
		/* BCM2837 PL011 is VideoCore/GPU interrupt 57 (pending bank 2). */
		intrenable(57, uartintr, uart, 0, uart->name);
		csr32w(c, UartIMSC, UartIMSCRX);
	}
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
	/* Keep TX interrupts armed only while staged/queued output remains. */
	if(uart->op < uart->oe || qlen(uart->oq) != 0)
		csr32w(c, UartIMSC, csr32r(c, UartIMSC) | UartIMSCTX);
	else
		csr32w(c, UartIMSC, csr32r(c, UartIMSC) & ~UartIMSCTX);
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
