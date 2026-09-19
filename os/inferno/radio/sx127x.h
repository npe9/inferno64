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
 */

typedef struct Spidev Spidev;
typedef struct Radio Radio;

struct Spidev
{
	char	*name;
	void	*aux;			/* the board's own */
	void	(*select)(Spidev*, int);	/* chip select: 1 asserted, 0 not */
	int	(*byte)(Spidev*, int);	/* clock one byte out, return the one in */
	void	(*lock)(Spidev*);	/* the bus is shared with storage */
	void	(*unlock)(Spidev*);
};

enum {
	Maxpayload	= 255,		/* what the FIFO holds */
	Rhhdrlen	= 4,		/* RadioHead: to, from, id, flags */
};

struct Radio
{
	Spidev	*spi;
	int	version;		/* RegVersion, 0x12 for an SX1276 */
	int	present;

	/* parameters, as set through ctl */
	u32	freq;			/* Hz */
	int	power;			/* dBm */
	int	sf;			/* spreading factor 6..12 */
	u32	bw;			/* Hz */
	int	cr;			/* coding rate denominator 5..8 */
	int	node;			/* RadioHead: this station */
	int	dest;			/* RadioHead: default destination */
	int	ackon;			/* send reliably, and acknowledge */
	int	acktries;		/* how many times before giving up */
	int	ackwait;		/* ms to wait for one */

	/* what the last received packet looked like */
	int	rssi;
	int	snr;

	/* counters */
	u32	nsent;
	u32	nrecv;
	u32	ncrcerr;
	u32	ntoobig;
	u32	nnotours;		/* heard, addressed to someone else */
	u32	ntxtimeout;		/* transmits that never reported done */
	u32	nacksent;
	u32	nackrecv;
	u32	nretry;			/* retransmissions */
	u32	nsendfail;		/* gave up after all the retries */
	u32	nrunt;			/* heard, too short to be a packet */

	QLock	qlock;			/* one user of the part at a time */
	Rendez	r;			/* a packet arrived */
	Rendez	txr;			/* the last one went */
	int	txdone;
	Rendez	ackr;			/* an acknowledgement arrived */
	int	gotack;
	uchar	seq;			/* RadioHead identifier, per packet */
	uchar	waitid;			/* the one being waited for */
	int	waiting;

	/* an acknowledgement the receive path owes somebody */
	Rendez	owed;
	int	oweack;
	uchar	oweto, oweid, oweflags;
	Queue	*rq;			/* received packets, one block each */
};

Radio*	sx127xinit(Spidev*, int irq);
int	sx127xsend(Radio*, uchar*, int);
int	sx127xctl(Radio*, char*, int);
int	sx127xstat(Radio*, char*, int);
void	sx127xinterrupt(Radio*);
