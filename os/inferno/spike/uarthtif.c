/*
 * HTIF console for QEMU -M spike (ucb,htif0).
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"

extern void	htifputc(int);
extern int	htifgetc(void);
extern void	htifputs(char*, int);

extern PhysUart htifphysuart;

static Uart htifuart = {
	.name	= "eia0",
	.freq	= 0,
	.phys	= &htifphysuart,
};

static Uart*
htif_pnp(void)
{
	return &htifuart;
}

static void
htif_enable(Uart*, int)
{
}

static void
htif_disable(Uart*)
{
}

static void
htif_kick(Uart *uart)
{
	int i;

	for(i = 0; i < 128; i++){
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		htifputc(*uart->op++);
	}
}

static void htif_break(Uart*, int) {}
static int htif_baud(Uart*, int) { return 0; }
static int htif_bits(Uart*, int) { return 0; }
static int htif_stop(Uart*, int) { return 0; }
static int htif_parity(Uart*, int) { return 0; }
static void htif_modemctl(Uart*, int) {}
static void htif_rts(Uart*, int) {}
static void htif_dtr(Uart*, int) {}
static long htif_status(Uart*, void*, long, long) { return 0; }
static void htif_fifo(Uart*, int) {}

static int
htif_getc1(Uart*)
{
	return htifgetc();
}

static void
htif_putc1(Uart*, int c)
{
	htifputc(c);
}

PhysUart htifphysuart = {
	.name		= "htif",
	.pnp		= htif_pnp,
	.enable		= htif_enable,
	.disable	= htif_disable,
	.kick		= htif_kick,
	.dobreak	= htif_break,
	.baud		= htif_baud,
	.bits		= htif_bits,
	.stop		= htif_stop,
	.parity		= htif_parity,
	.modemctl	= htif_modemctl,
	.rts		= htif_rts,
	.dtr		= htif_dtr,
	.status		= htif_status,
	.fifo		= htif_fifo,
	.getc		= htif_getc1,
	.putc		= htif_putc1,
};

void
serialputc(int c)
{
	htifputc(c);
}

void
serialputs(char *s, int n)
{
	htifputs(s, n);
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
	consuart = &htifuart;
	htifuart.console = 1;
}

void
uartconsolesetup(void)
{
	if(consuart == nil)
		return;
	consuart->putc = consolerx;
}
