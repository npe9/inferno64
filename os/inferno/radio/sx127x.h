/*
 * Semtech SX127x LoRa transceiver: the chip half.
 *
 * The part is a register file on SPI with a 256-byte FIFO and no
 * processor of its own, so this driver is all of the radio's behaviour
 * and none of any board's wiring.  A board fills in a Spidev and hands
 * it over; everything below the Spidev -- which controller, which chip
 * select, which pin DIO0 arrived on -- is the board's business.
 *
 * That split is the point.  The controller under this changes with the
 * machine (an MPS2 shield is a PL022, a PyCubed is a SAMD51 SERCOM) and
 * is thrown away with it; this file is what carries over.
 *
 * os/inferno/radio/radio.h has the part #W sees: a Radio begins with
 * its driver's operations and its receive queue, and everything below
 * is this driver's and is declared here.
 */

#include "../radio/radio.h"

typedef struct Sx127x Sx127x;

enum {
	Maxpayload	= 255,		/* what the FIFO holds */
	Carriertries	= 8,		/* listens before going anyway */
	Carrierwait	= 20,		/* ms between them, plus as much again */
};

struct Sx127x
{
	Radio;				/* dev, rq: what #W sees */
	Spidev	*spi;
	int	version;		/* RegVersion, 0x12 for an SX1276 */
	int	present;

	/* parameters, as set through ctl */
	u32	freq;			/* Hz */
	int	power;			/* dBm */
	int	sf;			/* spreading factor 6..12 */
	u32	bw;			/* Hz */
	int	cr;			/* coding rate denominator 5..8 */
	int	duty;			/* per cent of air permitted, 0 off */
	int	carrier;		/* listen before transmitting */

	/* what the last received packet looked like */
	int	rssi;
	int	snr;

	/* duty cycle */
	uvlong	airms;			/* time on the air, total */
	uvlong	nextok;			/* ms when a transmit is allowed */
	u32	nwaited;		/* transmits made to wait for it */
	u32	nbusy;			/* transmits that found the air busy */
	u32	ngaveup;		/* and went out over it anyway */

	/* counters */
	u32	nsent;
	u32	nrecv;
	u32	ncrcerr;
	u32	ntoobig;
	u32	ntxtimeout;		/* transmits that never reported done */

	QLock	qlock;			/* one user of the part at a time */
	Rendez	r;			/* a packet arrived */
	Rendez	txr;			/* the last one went */
	int	txdone;
};

Radio*	sx127xinit(Spidev*, int irq);
void	sx127xinterrupt(Radio*);
