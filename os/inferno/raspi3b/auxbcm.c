/*
 * BCM2835 AUX block (0x3f215000): the mini UART, and SPI1/SPI2.  Only
 * the mini UART is driven here.  It is the Pi's second serial port,
 * the one that ends up on GPIO 14/15 when the PL011 has been given to
 * the Bluetooth part -- which on a Pi 3B is the default arrangement,
 * so on real hardware this is usually the console.
 *
 * THE THINGS THIS BLOCK GETS WRONG ON PURPOSE.
 *
 * AUX_ENABLES gates the registers, not just the function.  Until bit 0
 * is set, every mini UART register reads as zero and writes are
 * discarded -- including the ones you would use to work out why
 * nothing is happening.  It is the first write, always.
 *
 * The line control register's data-length field is documented as one
 * bit, and that documentation is wrong: the BCM2835 datasheet erratum
 * has it, and 8-bit data needs LCR = 3, not 1.  A driver that follows
 * the datasheet gets 7-bit characters, which look like text that is
 * subtly and intermittently wrong rather than like an obvious failure.
 *
 * The baud rate divisor is derived from the *core* clock, not a fixed
 * oscillator, and the core clock moves when the firmware scales it.
 * That is why a Pi's mini UART console garbles when the CPU governor
 * changes speed unless core_freq is pinned.  Nothing here can fix
 * that; it is worth knowing it is the block's nature, not a bug.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

extern void gpiofsel(int, int);		/* gpiobcm.c */

enum {
	Irq	= 0x00/4,
	Enables	= 0x04/4,
	Io	= 0x40/4,
	Ier	= 0x44/4,
	Iir	= 0x48/4,
	Lcr	= 0x4c/4,
	Mcr	= 0x50/4,
	Lsr	= 0x54/4,
	Msr	= 0x58/4,
	Scratch	= 0x5c/4,
	Cntl	= 0x60/4,
	Stat	= 0x64/4,
	Baud	= 0x68/4,

	Enmuart	= 1<<0,		/* Enables: mini UART on */

	Lcr8bit	= 3,		/* NOT 1, whatever the datasheet says */

	Lsrrxready = 1<<0,
	Lsrtxempty = 1<<5,
	Lsrtxidle  = 1<<6,

	Cntlrx	= 1<<0,
	Cntltx	= 1<<1,

	Coreclk	= 250000000,	/* core clock the divisor is derived from */

	Alt5	= 2,		/* GPIO 14/15 alt5 = mini UART tx/rx */

	Timeout	= 100000,
};

static u32*
aux(void)
{
	return (u32*)AUX0;
}

/*
 * Bring the mini UART up at the given baud rate.  The divisor is
 * core / (8 * baud) - 1; the block samples eight times a bit, not
 * sixteen like a normal 16550, which is the other place an otherwise
 * correct 16550 driver goes wrong here.
 */
void
auxuartinit(int baud)
{
	u32 *r = aux();

	r[Enables] |= Enmuart;		/* first: nothing else works before it */
	r[Cntl] = 0;			/* stop tx and rx while reconfiguring */
	r[Ier] = 0;
	r[Lcr] = Lcr8bit;
	r[Mcr] = 0;
	r[Baud] = Coreclk / (8 * baud) - 1;

	gpiofsel(14, Alt5);		/* tx */
	gpiofsel(15, Alt5);		/* rx */

	r[Cntl] = Cntltx | Cntlrx;
}

void
auxuartputc(int c)
{
	u32 *r = aux();
	int i;

	for(i = 0; i < Timeout; i++)
		if(r[Lsr] & Lsrtxempty)
			break;
	r[Io] = c & 0xff;
}

int
auxuartgetc(void)
{
	u32 *r = aux();

	if((r[Lsr] & Lsrrxready) == 0)
		return -1;
	return r[Io] & 0xff;
}

/*
 * Prove the block is there and transmits.
 *
 * "Transmits" is as far as this can go on its own: where the bytes end
 * up is a property of what the second serial port is connected to, not
 * of this driver.  Under QEMU the AUX block is serial1, so running
 * with -serial mon:stdio -serial file:aux.log puts them in that file,
 * which is how this was checked.  With no second port they go nowhere
 * and the block still reports the transmitter idle, so this reports
 * what it can actually see.
 */
void
auxinit(void)
{
	u32 *r = aux();
	static char msg[] = "AUXUART-HELLO\r\n";
	int i;

	r[Enables] |= Enmuart;
	if((r[Enables] & Enmuart) == 0){
		print("AUX-NONE no AUX block at %#p\n", (void*)AUX0);
		return;
	}

	auxuartinit(115200);
	if((r[Lsr] & (Lsrtxempty|Lsrtxidle)) != (Lsrtxempty|Lsrtxidle)){
		print("AUX-FAIL transmitter not idle after init (lsr %#ux)\n", r[Lsr]);
		return;
	}
	for(i = 0; msg[i] != 0; i++)
		auxuartputc(msg[i]);
	if((r[Lsr] & Lsrtxempty) == 0){
		print("AUX-FAIL transmitter never drained (lsr %#ux)\n", r[Lsr]);
		return;
	}
	print("aux: mini uart at %#p, 115200 8n1, divisor %ud\n",
		(void*)AUX0, r[Baud]);
	print("AUX-OK mini uart enabled and sent %d bytes\n", i);
}
