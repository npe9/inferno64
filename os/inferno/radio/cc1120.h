/*
 * TI CC1120 narrowband transceiver: the chip half.
 *
 * The part is a register file on SPI with two 128-byte FIFOs and no
 * processor of its own, so this driver is all of the radio's behaviour
 * and none of any board's wiring.  A board fills in a Spidev and hands
 * it over; everything below the Spidev -- which controller, which chip
 * select, which pin the interrupt arrived on -- is the board's
 * business.
 *
 * That split is the point.  The controller under this changes with the
 * machine and is thrown away with it; this file is what carries over.
 *
 * os/inferno/radio/radio.h has the part #W sees: a Radio begins with
 * its driver's operations and its receive queue, and everything below
 * is this driver's and is declared here.
 */

#include "../radio/radio.h"

typedef struct Cc1120 Cc1120;

enum {
	Ccmaxpayload	= 125,		/* a FIFO holds 128; length and
					 * two status bytes are the rest */
};

struct Cc1120
{
	Radio;				/* dev, rq: what #W sees */
	Spidev	*spi;
	int	partnum;		/* PARTNUMBER, 0x48 for a CC1120 */
	int	partversion;
	int	ready;			/* status byte once CHIP_RDYn cleared */
	int	rssioffset;		/* dB, in AGC_GAIN_ADJUST */
	int	csthr;			/* dBm, in AGC_CS_THR */
	int	txstaged;		/* NUM_TXBYTES after the FIFO write */
	int	txmarc;			/* MARC_STATUS1 after the transmit */
	uchar	txtrace[6];		/* state through the last transmit */
	int	txleft;			/* NUM_TXBYTES after it went wrong */
	int	fixedlen;		/* fixed packet length, not variable */
	int	present;

	/* what the last received packet looked like */
	int	rssi;
	uvlong	hz;			/* what setfreq() last tuned to */
	ulong	symrate;		/* symbols a second, read from DRATE */
	int	serial;		/* transparent mode: bits on GPIO3 */
	uchar	lastrx[32];	/* the last packet's first bytes, for lastrx */
	int	nlastrx;
	int	ledon;		/* what the lamp is showing */
	int	ppb;		/* crystal error, parts per billion */
	int	lqi;

	/* counters */
	u32	nsent;
	u32	nrecv;
	u32	ncrcerr;
	u32	ntoobig;
	u32	ntxtimeout;
	u32	nrxoverflow;
	u32	ntxunderflow;
	u32	ntxnever;		/* strobed TX and never got there */
	/*
	 * Interrupts delivered, split by the level the pin was at.
	 *
	 * PKT_SYNC_RXTX rises on the sync word and falls at the end of
	 * the packet, so a high pin means there is nothing complete to
	 * read yet and a low one means there is.  A board that enables
	 * only one edge receives perfectly and counts nothing, and the
	 * two numbers say which edge arrived -- recv alone cannot tell
	 * "never heard it" from "heard it and was never told".
	 */
	u32	nintrhigh;		/* edge taken with the pin high */
	u32	nintrlow;		/* edge taken with the pin low */
	/*
	 * Transmits the part refused because the channel was busy.
	 * SWRU295E 6.11: an STX from RX only reaches TX if CCA says the
	 * channel is clear, and this driver's CCA_MODE is 001 -- so
	 * every transmit goes through carrier sense whether anybody
	 * asked for it or not, and a refusal leaves the part in RX.
	 */
	u32	nccabusy;
	/*
	 * Latched RX or TX FIFO errors cleared.  See rxarm() in
	 * cc1120.c: this counts a fault the driver used to be unable to
	 * notice at all, because the only recovery was inside the
	 * interrupt handler the fault stops being called.
	 */
	u32	nfifoerr;
	/*
	 * Of those, the ones the clock watchdog cleared rather than a
	 * transmit or a ctl write -- which is to say the ones that would
	 * have been permanent.
	 */
	u32	nfifowatch;
	uchar	rxstatus[2];		/* the two bytes APPEND_STATUS adds */

	QLock	qlock;			/* one user of the part at a time */
	Rendez	r;
	int	txdone;
};

Radio*	cc1120init(Spidev*, int irq);
void	cc1120interrupt(Radio*);
