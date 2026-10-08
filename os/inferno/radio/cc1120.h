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
	/*
	 * A length byte whose payload the FIFO did not hold yet.
	 *
	 * The receive path samples NUM_RXBYTES, finds at least one byte,
	 * reads the length and then reads that many -- and the count
	 * said nothing about whether they had arrived.  The packet
	 * interrupt is suppressed on this board and the FIFO is drained
	 * by a clock watchdog instead, so it is looked at MID-PACKET as
	 * a matter of course: at 1200 baud a 109-byte frame is 730
	 * milliseconds in the air and the watchdog runs many times
	 * inside that.  Reading past the end underflows the part, which
	 * returns rubbish for the rest of the payload and leaves the
	 * FIFO in RX_FIFO_ERR.
	 *
	 * So the count is checked now and a packet that is not all there
	 * is flushed and tallied here rather than delivered corrupt.
	 * Losing it costs an AX.25 retransmission, which the connected
	 * mode is for; delivering it corrupt costs a diagnosis.
	 */
	u32	nrxpartial;
	/*
	 * A frame whose length byte has been read and whose payload has
	 * not all arrived: the length, kept until it has.
	 *
	 * The length byte cannot be put back -- reading the FIFO pops it
	 * -- so the only alternatives are to finish the frame later or
	 * to throw it away, and throwing it away loses a frame AX.25
	 * then has to recover.  Measured: a 284-byte Styx reply goes out
	 * as 109, 109 and 66, the receiver took the first two and
	 * dropped the third HERE, and the conversation timed out.
	 *
	 * Zero means nothing is pending.  rxpendtick is when it was set,
	 * so a frame that never finishes arriving is given up on by the
	 * clock watchdog rather than blocking the FIFO for ever.
	 */
	int	pendon;			/* keep a half-read frame (1) or flush it (0) */
	u32	nrxresume;		/* pended frames whose payload turned up */
	int	rxstaleat;		/* ... and what it held when taken */
	int	rxstaleln;		/* the last giveup's length ... */
	int	rxstalenavail;		/* ... and what the FIFO held then */
	int	rxpendat;		/* navail when the pend was taken */
	int	rxpendst;		/* and the part's state then */
	int	rxpendmarc;		/* and MARC_STATUS1: why it stopped */
	u32	nrxkilled;		/* pends dropped because we transmitted */
	u32	ntxskip;		/* drains skipped: the part was not in RX */
	int	idlelast;		/* what it said instead of IDLE */
	int	idlepoll;		/* worst polls SIDLE has ever needed */
	u32	nnotidle;		/* flushes where SIDLE did not arrive */
	u32	nrxunder;		/* payload read past the end of the FIFO */
	u32	nrxstale;		/* rxpend given up on by the watchdog */
	int	rxpend;
	ulong	rxpendtick;
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
	/* and how many times the watchdog looked, so that a zero
	 * nfifowatch can be told from a watchdog that never ran */
	u32	nwatchtick;
	/*
	 * A receiver that is in RX, has bytes in its FIFO, and is not
	 * being drained -- the edge was missed and no further one is
	 * coming.  See cc1120tick.
	 */
	u32	nrxstall;
	int	lastnavail;
	uchar	rxstatus[2];		/* the two bytes APPEND_STATUS adds */
	u32	nstatus;		/* frames those two bytes were read from */
	u32	ncrcbad;		/* frames the part says failed their CRC */

	QLock	qlock;			/* one user of the part at a time */
	Rendez	r;
	int	txdone;
};

Radio*	cc1120init(Spidev*, int irq);
void	cc1120interrupt(Radio*);
