/*
 * BCM43438 Bluetooth on a Raspberry Pi 3B: power the radio, give it the
 * PL011, and ask it one question.
 *
 * The radio is not on any bus this kernel can enumerate.  It is an H4
 * controller wired to UART0 -- the PL011 -- on GPIO 32 and 33, with its
 * flow control on 30 and 31, and its enable line is not a SoC pin at
 * all: BT_ON is line 0 of the eight-line expander the VideoCore owns,
 * so the only way to it is a mailbox property call (mailbox.c).  A Pi
 * that has never been told to power the radio has a perfectly working
 * UART with nothing on the other end of it, which is exactly what a
 * broken driver looks like.  That is what this file is for: after it
 * runs, either the controller has answered or the console says it did
 * not, and the Limbo stack above (btfs(4)) starts from a known place.
 *
 * The console has to be somewhere else for any of this to happen.  On
 * a Pi 3 the firmware gives the header the mini UART and keeps the
 * PL011 for the radio, and uartpl011.c follows that arrangement rather
 * than assuming one; here the same test decides whether there is a
 * radio to talk to.  Under QEMU -M raspi3b there is no firmware, the
 * console is the PL011, and there is no radio: this says so and stops,
 * because writing HCI packets at the console is not a probe, it is
 * garbage on the only terminal the board has.
 *
 * What it does not do is load the controller's patch firmware
 * (BCM4345C0.hcd, a file on the card).  A cold controller answers HCI
 * Reset and the vendor commands that download the patch, and refuses
 * most else until it has one; proving it answers at all is the part
 * that needed hardware, and the download belongs above this, in Limbo,
 * where there is a filesystem.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

extern void gpiofsel(int, int);		/* gpiobcm.c */
extern int gpiofselget(int);
extern int mboxsetgpio(int, int);	/* mailbox.c */
extern int mboxgetgpio(int, int*);

enum {
	Btonpin	= 128,		/* firmware expander line 0: BT_ON */
	Alt3	= 7,		/* GPFSEL code for alt3 */
	Altmini	= 2,		/* GPFSEL code for alt5, the mini UART */
	Btcts	= 30,		/* GPIO 30-33 at alt3: CTS0, RTS0, TXD0, RXD0 */
	Btrts	= 31,
	Bttx	= 32,
	Btrx	= 33,
	Btbaud	= 115200,	/* the speed a cold BCM43438 comes up at */
	Powerms	= 200,		/* after BT_ON before the controller listens */
	Replyms	= 1000,		/* how long to wait for the whole event */
};

#define csr32r(r)	(((volatile u32*)UART0)[r])
#define csr32w(r, v)	(((volatile u32*)UART0)[r] = (v))

/* 01 03 0c 00 -- HCI Reset, the shortest command there is */
static uchar reset[] = { 0x01, 0x03, 0x0c, 0x00 };
/* 04 0e 04 01 03 0c 00 -- Command Complete, Reset, status success */
static uchar want[] = { 0x04, 0x0e, 0x04, 0x01, 0x03, 0x0c, 0x00 };

static void
btuart(void)
{
	int div;

	/*
	 * 48MHz UART clock: 48e6/(16*115200) = 26 + 3/64, the same
	 * arithmetic the console does.  CR first, LCRH last: the divisors
	 * may only be written while the UART is off, and writing LCRH is
	 * what latches them.
	 *
	 * RTSEN and CTSEN, which the console does not use: the BCM43438
	 * drops bytes without flow control, and it is the one thing about
	 * this link that cannot be tested by looking at what came back --
	 * a four-byte command fits in anybody's FIFO.
	 */
	div = (4 * 48000000 + Btbaud/2) / Btbaud;	/* 64*clk/(16*baud) */
	csr32w(UartCR, 0);
	csr32w(UartICR, UartICRALL);
	csr32w(UartIBRD, div >> 6);
	csr32w(UartFBRD, div & 0x3f);
	csr32w(UartLCRH, UartLCRHWLEN8|UartLCRHFEN);
	csr32w(UartIMSC, 0);
	csr32w(UartCR, UartCRUARTEN|UartCRTXE|UartCRRXE|UartCRRTSEN|UartCRCTSEN);
}

static void
btput(uchar *p, int n)
{
	int i, j;

	for(i = 0; i < n; i++){
		for(j = 0; j < 1000000; j++)
			if((csr32r(UartFR) & UartFRTXFF) == 0)
				break;
		csr32w(UartDR, p[i]);
	}
}

/*
 * Read n bytes, or as many as arrive inside Replyms.  Returns how many
 * came: a short answer is reported rather than retried, because the
 * only thing that makes this interesting is what the controller said.
 */
static int
btget(uchar *p, int n)
{
	int i, ms;

	for(i = 0; i < n; ){
		for(ms = 0; ms < Replyms; ms++){
			if((csr32r(UartFR) & UartFRRXFE) == 0)
				break;
			delay(1);
		}
		if(ms >= Replyms)
			break;
		p[i++] = csr32r(UartDR) & 0xff;
	}
	return i;
}

void
btinit(void)
{
	uchar buf[16];
	int i, n, on;

	if(gpiofselget(14) != Altmini){
		print("BT-NONE console has the pl011, no radio\n");
		return;
	}

	gpiofsel(Btcts, Alt3);
	gpiofsel(Btrts, Alt3);
	gpiofsel(Bttx, Alt3);
	gpiofsel(Btrx, Alt3);

	if(mboxsetgpio(Btonpin, 1) < 0){
		print("BT-FAIL firmware refused BT_ON (expander pin %d)\n", Btonpin);
		return;
	}
	on = 0;
	if(mboxgetgpio(Btonpin, &on) == 0 && on == 0){
		print("BT-FAIL BT_ON reads back low\n");
		return;
	}
	delay(Powerms);

	btuart();
	/* whatever the line held while the radio was powering up */
	while((csr32r(UartFR) & UartFRRXFE) == 0)
		csr32r(UartDR);

	btput(reset, sizeof reset);
	n = btget(buf, sizeof want);
	if(n != sizeof want){
		print("BT-FAIL HCI Reset answered with %d of %d bytes\n",
			n, (int)sizeof want);
		return;
	}
	for(i = 0; i < n; i++)
		if(buf[i] != want[i]){
			print("BT-FAIL HCI Reset answered %.2ux at %d, wanted %.2ux\n",
				buf[i], i, want[i]);
			return;
		}
	print("BT-OK BCM43438 answered HCI Reset on the pl011 at %d baud\n", Btbaud);
}
