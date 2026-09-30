#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

/*
 * The USART of an STM32F4.  A byte at a time in and out, and a receive
 * interrupt.
 *
 * Not the F3's, which is why this is a second file rather than an
 * argument to the first: the F3 has ISR, RDR and TDR where this has
 * SR and DR, its enable bit is 0 where this is 13, and it clears an
 * overrun through an ICR this does not have.  The two parts share a
 * name and a manufacturer and not a register map.
 *
 * Which USART, on which pins, off which APB: all of it comes from
 * CONSUSART in mem.h, through the table in io.h.  Every pin any of
 * them can use here is alternate function 7.
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

enum {
	Tx	= UARTTX,
	Rx	= UARTRX,
	Afr	= UARTAFR,
	Port	= UARTPORT,
};

static ulong
uarthz(void)
{
	return UARTHZ;
}

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
	 * The two pins to alternate function 7, at the fastest slew the
	 * pin will do.
	 */
	v = *(volatile ulong*)(Port+GPIO_MODER);
	v &= ~((3UL<<(2*Tx)) | (3UL<<(2*Rx)));
	v |= (2UL<<(2*Tx)) | (2UL<<(2*Rx));		/* alternate function */
	*(volatile ulong*)(Port+GPIO_MODER) = v;
	v = *(volatile ulong*)(Port+GPIO_OSPEEDR);
	v |= (3UL<<(2*Tx)) | (3UL<<(2*Rx));
	*(volatile ulong*)(Port+GPIO_OSPEEDR) = v;
	v = *(volatile ulong*)(Port+Afr);
	v &= ~((0xfUL<<(4*(Tx%8))) | (0xfUL<<(4*(Rx%8))));
	v |= (7UL<<(4*(Tx%8))) | (7UL<<(4*(Rx%8)));	/* AF7 */
	*(volatile ulong*)(Port+Afr) = v;

	c = &stm32f4ctlr;
	csrw(c, UartCr1, 0);			/* the rate cannot be set
						 * while it is enabled */
	csrw(c, UartCr2, 0);
	csrw(c, UartCr3, 0);
	/*
	 * The divisor comes from the APB this USART is on, which
	 * archstm32f407.c sets to whatever clock the boot actually
	 * settled on.  A kernel that assumed the PLL had come up and
	 * had it not would have a console at a fraction of the baud it
	 * meant, which looks like a dead board rather than a clock that
	 * did not start.
	 */
	stm32f4uart.freq = uarthz();
	csrw(c, UartBrr, (uarthz() + UARTBAUD/2) / UARTBAUD);
	csrw(c, UartCr1, UartUe|UartTe|UartRe);
	coherence();
}

/*
 * TEMPORARY: bring up the three USARTs a clicker 2 brings out and
 * write one line to each, so that a board whose UART click is in the
 * other socket is not mistaken for a board that never booted.  Each is
 * alternate function 7 except UART4 on PA0/PA1, which is AF8.  Removed
 * once the socket is known; see the NOTE.
 */
static void
rawuart(ulong base, ulong port, int tx, int afr, int af, ulong hz, char *s)
{
	volatile ulong *r;
	ulong v;
	int i;

	v = *(volatile ulong*)(port+GPIO_MODER);
	v &= ~(3UL << (2*tx));
	v |= 2UL << (2*tx);
	*(volatile ulong*)(port+GPIO_MODER) = v;
	v = *(volatile ulong*)(port+afr);
	v &= ~(0xfUL << (4*(tx%8)));
	v |= (ulong)af << (4*(tx%8));
	*(volatile ulong*)(port+afr) = v;

	r = (volatile ulong*)base;
	r[UartCr1/4] = 0;
	r[UartCr2/4] = 0;
	r[UartCr3/4] = 0;
	r[UartBrr/4] = (hz + UARTBAUD/2) / UARTBAUD;
	r[UartCr1/4] = UartUe|UartTe;
	coherence();
	for(; *s; s++){
		for(i = 0; i < 100000; i++)
			if(r[UartSr/4] & UartTxe)
				break;
		r[UartDr/4] = *s & 0xff;
	}
}

/*
 * TEMPORARY, and the reason for it: everything above assumes that the
 * USART's transmit pin is the one wired to the click, and that the
 * alternate-function mux put the USART on it.  Neither has been
 * observed, only derived.  This drives the same pins as plain GPIO and
 * shifts a byte out by hand, so a pin that shows nothing here is not
 * connected to anything listening, whatever the USART thinks.
 *
 * 9600 rather than 115200: a bit is 104us instead of 8.7us, which is
 * far enough from the SysTick period that an interrupt landing in the
 * middle of a frame costs one character rather than all of them, and
 * splhi() keeps most of them out anyway.  The timing is taken from
 * fastticks(), which reports its own rate, so it is a real interval
 * whatever the clock turned out to be -- which is the point, since the
 * clock is one of the things in doubt.
 */
static void
bitdelay(uvlong ticksperbit)
{
	uvlong end;

	end = fastticks(nil) + ticksperbit;
	while(fastticks(nil) < end)
		clockpoll();
}

static void
bitbang(ulong port, int pin, char *s)
{
	uvlong hz, tpb;
	ulong v;
	int i, b, sp;

	v = *(volatile ulong*)(port+GPIO_MODER);
	v &= ~(3UL << (2*pin));
	v |= 1UL << (2*pin);			/* plain output */
	*(volatile ulong*)(port+GPIO_MODER) = v;
	*(volatile ulong*)(port+GPIO_ODR) |= 1UL << pin;	/* idle high */

	fastticks(&hz);
	tpb = hz / 9600;
	if(tpb == 0)
		return;
	for(; *s; s++){
		sp = splhi();
		b = *s & 0xff;
		*(volatile ulong*)(port+GPIO_ODR) &= ~(1UL << pin);
		bitdelay(tpb);				/* start bit */
		for(i = 0; i < 8; i++){
			if(b & 1)
				*(volatile ulong*)(port+GPIO_ODR) |= 1UL << pin;
			else
				*(volatile ulong*)(port+GPIO_ODR) &= ~(1UL << pin);
			b >>= 1;
			bitdelay(tpb);
		}
		*(volatile ulong*)(port+GPIO_ODR) |= 1UL << pin;
		bitdelay(tpb);				/* stop bit */
		bitdelay(tpb);
		splx(sp);
	}
}

/*
 * Every pin the part brings out, one at a time, each saying its own
 * name.  The six the mikroBUS sockets' UARTs use produced nothing and
 * did not so much as flicker the click's receive LED, which rules out
 * the baud, the alternate-function mux and the USART together and
 * leaves only the pin table -- which was read out of a manual and
 * never measured.  This does not assume it.
 *
 * Skipped, and why: PA11 and PA12 are USB D- and D+, which is how the
 * part is programmed; PA13 and PA14 are SWD, which is the other way in
 * if this goes wrong; PE12 and PE15 are the LEDs that are the only
 * thing still reporting.  And the six pins a click drives itself --
 * each socket's AN, MISO and INT -- because driving against a click's
 * output is a short through whatever is in the socket.
 */
static int
skip(int port, int pin)
{
	switch(port){
	case 0:					/* A */
		return pin==11 || pin==12 || pin==13 || pin==14
			|| pin==2 || pin==3;	/* AN of both sockets */
	case 1:					/* B */
		return pin==14;			/* mikroBUS 2 MISO */
	case 2:					/* C */
		return pin==11;			/* mikroBUS 1 MISO */
	case 4:					/* E */
		return pin==12 || pin==15	/* the LEDs */
			|| pin==10 || pin==14;	/* INT of both sockets */
	}
	return 0;
}

/*
 * TEMPORARY, and the last resort.  Driving every pin and listening on
 * the click found nothing, but streaming into the click from the host
 * lights its transmit LED, so the adapter is alive and something of it
 * is wired somewhere.  This turns the question round: make every pin
 * an input, watch which one moves while the host streams, and report
 * it on the two LEDs, which are the only channel that has ever
 * worked.  It assumes nothing about the pin table, the direction or
 * the baud -- any rate at all makes a connected pin toggle.
 *
 * LD1 blinks the port, A as one blink through E as five.  LD2 then
 * blinks the pin number, with sixteen quick blinks meaning zero.  The
 * two groups are separated by a pause and the whole report repeats.
 */
static int foundport = -1, foundpin = -1;

/*
 * Which pin is the click actually driving?
 *
 * The first cut of this made every pin an input and reported the first
 * one that changed over half a second.  It reported PA9, which is a
 * USART1 pin and so looked like an answer, and it was noise: an input
 * with no pull-up floats, and floating CMOS inputs toggle on their
 * own.  The board stayed silent on USART1 afterwards, which is what
 * said so.
 *
 * Two changes make it mean something.  Every pin gets a pull-up, so a
 * pin with nothing on it reads a steady one; and transitions are
 * counted over a whole second rather than noticed once, so the pin
 * with a host streaming into it wins by orders of magnitude rather
 * than by being first in the scan.  A pin must move at least Minmoves
 * times to be reported at all.
 */
enum { Minmoves = 50 };

void
findmovingpin(void)
{
	static ulong base[5] = { GPIOA, GPIOB, GPIOC, GPIOD, GPIOE };
	static ushort count[5][16];
	ulong prev[5], now, ch, v;
	uvlong hz, end;
	int port, pin, best;

	if(foundport >= 0)
		return;
	for(port = 0; port < 5; port++){
		v = *(volatile ulong*)(base[port]+GPIO_MODER);
		if(port == 4)
			v &= (3UL<<(2*12)) | (3UL<<(2*15));
		else
			v = 0;
		*(volatile ulong*)(base[port]+GPIO_MODER) = v;
		/* a pull-up on every pin, so nothing floats */
		*(volatile ulong*)(base[port]+GPIO_PUPDR) = 0x55555555;
		for(pin = 0; pin < 16; pin++)
			count[port][pin] = 0;
		prev[port] = *(volatile ulong*)(base[port]+GPIO_IDR);
	}
	fastticks(&hz);
	end = fastticks(nil) + hz;		/* a whole second */
	while(fastticks(nil) < end){
		clockpoll();
		for(port = 0; port < 5; port++){
			now = *(volatile ulong*)(base[port]+GPIO_IDR);
			ch = now ^ prev[port];
			prev[port] = now;
			if(ch == 0)
				continue;
			for(pin = 0; pin < 16; pin++)
				if((ch & (1UL<<pin)) && count[port][pin] < 60000)
					count[port][pin]++;
		}
	}
	/* USB, SWD and the LEDs are ours or float whatever we do */
	count[0][11] = count[0][12] = count[0][13] = count[0][14] = 0;
	count[4][12] = count[4][15] = 0;

	best = Minmoves;
	for(port = 0; port < 5; port++)
		for(pin = 0; pin < 16; pin++)
			if(count[port][pin] > best){
				best = count[port][pin];
				foundport = port;
				foundpin = pin;
			}
}

static void
blink(int n, int pin)
{
	uvlong hz, end;
	int i;

	fastticks(&hz);
	for(i = 0; i < n; i++){
		ledpin(pin, 1);
		end = fastticks(nil) + hz/8;
		while(fastticks(nil) < end)
			clockpoll();
		ledpin(pin, 0);
		end = fastticks(nil) + hz/8;
		while(fastticks(nil) < end)
			clockpoll();
	}
}

void
reportmovingpin(void)
{
	uvlong hz, end;

	if(foundport < 0)
		return;
	blink(foundport + 1, 12);		/* LD1: A=1 .. E=5 */
	fastticks(&hz);
	end = fastticks(nil) + hz;
	while(fastticks(nil) < end)
		clockpoll();
	blink(foundpin == 0? 16: foundpin, 15);	/* LD2: the pin number */
	end = fastticks(nil) + hz;
	while(fastticks(nil) < end)
		clockpoll();
}

/*
 * TEMPORARY.  The sweep proved PD5 reaches the click -- bit-banged as
 * a plain GPIO it arrives -- and the USART driving the same pin
 * arrives not at all.  So the pin and the wire are not in question and
 * the peripheral is.  Report its registers, and the clocks and the mux
 * it depends on, over the channel that does work.
 */
static char *
puthex(char *p, char *name, ulong v)
{
	static char hex[] = "0123456789abcdef";
	int i;

	while(*name)
		*p++ = *name++;
	*p++ = '=';
	for(i = 28; i >= 0; i -= 4)
		*p++ = hex[(v>>i) & 0xf];
	*p++ = ' ';
	return p;
}

void
bangregs(void)
{
	char buf[160], *p;
	Ctlr *c;

	c = &stm32f4ctlr;
	p = buf;
	p = puthex(p, "apb1en", *(volatile ulong*)RCC_APB1ENR);
	p = puthex(p, "ahb1en", *(volatile ulong*)RCC_AHB1ENR);
	p = puthex(p, "moder", *(volatile ulong*)(GPIOD+GPIO_MODER));
	p = puthex(p, "afrl", *(volatile ulong*)(GPIOD+GPIO_AFRL));
	*p++ = '\r'; *p++ = '\n';
	p = puthex(p, "brr", csrr(c, UartBrr));
	p = puthex(p, "cr1", csrr(c, UartCr1));
	p = puthex(p, "sr", csrr(c, UartSr));
	p = puthex(p, "apb1hz", uarthz());
	p = puthex(p, "cpuhz", m != nil? m->cpuhz: 0);
	*p++ = '\r'; *p++ = '\n';
	*p = 0;
	bitbang(GPIOD, 5, buf);
}

void
bangallpins(void)
{
	static ulong base[5] = { GPIOA, GPIOB, GPIOC, GPIOD, GPIOE };
	char buf[8];
	int port, pin;

	for(port = 0; port < 5; port++)
		for(pin = 0; pin < 16; pin++){
			if(skip(port, pin))
				continue;
			buf[0] = 'P';
			buf[1] = 'A' + port;
			if(pin < 10){
				buf[2] = '0' + pin;
				buf[3] = '\r';
				buf[4] = '\n';
				buf[5] = 0;
			} else {
				buf[2] = '1';
				buf[3] = '0' + pin - 10;
				buf[4] = '\r';
				buf[5] = '\n';
				buf[6] = 0;
			}
			bitbang(base[port], pin, buf);
		}
}

/*
 * Every USART a clicker 2 brings out, so that a board whose UART click
 * is in a socket this kernel is not configured for says which socket it
 * IS in, rather than looking like a board that never booted.  That case
 * is not hypothetical: a second board flashed with this kernel left its
 * bootloader, so it was certainly running, and printed nothing on any
 * serial port the host could see.
 *
 * The leading Us are deliberate.  0x55 is alternating bits, so it is
 * the character a receiver at the wrong baud rate most reliably shows
 * as something other than the right one, and eight of them give an
 * adapter time to settle before anything worth reading arrives.
 */
static struct {
	ulong	base;
	ulong	port;
	int	tx;
	ulong	afr;
	int	af;			/* AF7 for the USARTs, AF8 for UART4 */
	char	*say;
} allusarts[] = {
	{ 0x40004400, GPIOD, 5, GPIO_AFRL, 7,
		"UUUUUUUU\r\nInferno on USART2, PD5: mikroBUS 1\r\n" },
	{ 0x40004800, GPIOD, 8, GPIO_AFRH, 7,
		"UUUUUUUU\r\nInferno on USART3, PD8: mikroBUS 2\r\n" },
	{ 0x40004c00, GPIOA, 0, GPIO_AFRL, 8,
		"UUUUUUUU\r\nInferno on UART4, PA0: the pad\r\n" },
};

void
otherusarts(void)
{
	int i;

	for(i = 0; i < nelem(allusarts); i++){
		/*
		 * Never the console's own USART: rawuart() writes CR1 from
		 * scratch, which drops the receive enable and the receive
		 * interrupt, and the console would go deaf.  It has nothing
		 * to prove anyway -- everything the kernel says comes out
		 * of it.
		 *
		 * Compared against the console's own register base, and not
		 * decided by #ifndef on the CONSUSART names as this did
		 * before.  Two reasons.  A board moving its console to a
		 * USART nobody had written an #ifndef for here would have
		 * had its console quietly made deaf instead of being told
		 * anything, which is the worst way for a diagnostic to
		 * fail.  And conditional compilation is not how this tree
		 * selects anything: a board takes code by which files its
		 * config names, and values by what data it carries.
		 */
		if(allusarts[i].base == UART0)
			continue;
		rawuart(allusarts[i].base, allusarts[i].port,
			allusarts[i].tx, allusarts[i].afr,
			allusarts[i].af, apb1hz, allusarts[i].say);
	}
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
	ulong sr;
	int i, ch;

	uart = arg;
	c = uart->regs;
	/*
	 * DR has to be read whenever either RXNE or ORE is set, and not
	 * only when RXNE is.
	 *
	 * An overrun asserts this interrupt by itself -- on this part
	 * RXNEIE covers RXNE and ORE alike -- and ORE is cleared only
	 * by reading SR and then DR.  A handler that checks RXNE, finds
	 * it clear and returns has cleared nothing, so it is re-entered
	 * the instant it leaves, for ever.  The core then makes no
	 * progress at all.
	 *
	 * What that looks like is not a broken console.  It is a kernel
	 * that stops in the middle of a print: on os/inferno/stm32f407
	 * it stopped four bytes into "Inferno Fourth Edition",
	 * reproducibly, at exactly the same byte twice -- because
	 * uartconsolesetup() enables this interrupt a few lines earlier
	 * and the host had been sending while nothing was reading.
	 * Everything before that point came out perfectly, which is
	 * what made it look like a wiring fault for hours.
	 */
	for(i = 0; i < 64; i++){
		sr = csrr(c, UartSr);
		if((sr & (UartRxne|UartOre)) == 0)
			break;
		if(sr & UartOre)
			uart->oerr++;
		ch = csrr(c, UartDr) & 0xff;	/* clears RXNE and ORE */
		if(sr & UartRxne)
			uartrecv(uart, ch);
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

	/*
	 * Drain everything staged, waiting for room rather than giving
	 * up when there is none.
	 *
	 * This used to break out of the loop the moment TXE was clear,
	 * which puts one byte in the register and abandons the rest --
	 * and nothing ever comes back for them, because this driver
	 * enables no transmit interrupt.  While serialoq is nil that
	 * does not show: putstrn0() in os/inferno/port/devcons.c sends
	 * straight to uartputs().  devuart.c sets serialoq as soon as a
	 * uart is enabled as the console, and from that line on every
	 * print goes through the queue and through here.
	 *
	 * On os/inferno/stm32f407 the console stopped after exactly 408
	 * bytes, four into "Inferno Fourth Edition", on every boot --
	 * while the kernel carried on and reached the scheduler, which
	 * is what the blinking LED was saying all along.  It looked for
	 * hours like a board that had stopped, and it was a board
	 * talking into a queue nothing emptied.
	 *
	 * A bounded spin per byte and not TXEIE: 87us a byte at 115200,
	 * so a full console line is some seven milliseconds inside a
	 * qwrite from a process.  A transmit interrupt would be better
	 * and is more machinery than a board with one serial line and
	 * five processes needs.
	 */
	c = uart->regs;
	while(uart->op < uart->oe || uartstageoutput(uart) != 0){
		for(i = 0; i < 100000; i++)
			if(csrr(c, UartSr) & UartTxe)
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
	csrw(c, UartBrr, (uarthz() + baud/2) / baud);
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

	/*
	 * From here, and this took two goes to get right.
	 *
	 * It was in stm32f4_enable(), the PhysUart method, on the
	 * reasoning that the console is up by then.  It is, but
	 * uartenable() is called from devuart.c only when a uart is
	 * OPENED -- "if(p->opens++ == 0 && uartenable(p) == nil)" -- and
	 * nothing opens /dev/eia0 at boot.  So the method never ran, and
	 * a diagnostic that never runs is worse than none: it was cited
	 * as evidence that a silent board's click could not be in the
	 * wrong socket, which it could not support.
	 *
	 * uartconsolesetup() is this board's own and armv7m/main.c calls
	 * it unconditionally, after clockinit(), so apb1hz is the real
	 * one and the baud divisors are right.
	 */
	otherusarts();
}
