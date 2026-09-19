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

	/*
	 * What a read of #W/radio0/pkt returns in front of the payload.
	 * recvmsg() rather than recv(): the things LoRa knows about a
	 * packet that the packet does not contain -- how strong it was,
	 * how clean, whether its CRC checked, when it arrived -- handed
	 * over with it, out of the same queue entry, so that nothing is
	 * looked up afterwards and nothing races.  None of it goes on
	 * the air.
	 *
	 *	uchar	len[2]		payload bytes following
	 *	uchar	rssi[2]		dBm, signed
	 *	uchar	snr[2]		dB, signed
	 *	uchar	flags[2]	Pcrcerr
	 *	uchar	tick[4]		arrival, in clock ticks
	 */
	Pkthdrlen	= 12,
	Pcrcerr		= 1<<0,
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

	/* what the last received packet looked like */
	int	rssi;
	int	snr;

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
	Queue	*rq;			/* received packets, one block each */
};

Radio*	sx127xinit(Spidev*, int irq);
int	sx127xsend(Radio*, uchar*, int);
Block*	sx127xrecv(Radio*, int);
int	sx127xctl(Radio*, char*, int);
int	sx127xstat(Radio*, char*, int);
void	sx127xinterrupt(Radio*);
