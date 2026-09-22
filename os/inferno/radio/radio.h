/*
 * A packet radio, as #W sees one.
 *
 * os/inferno/radio/devradio.c called sx127xsend(), sx127xctl() and
 * sx127xstat() by name, so "the chip driver is separable from the
 * layers above it" was a claim about the source rather than a property
 * of it.  It is a structure now: #W holds a Radio, a Radio begins with
 * the operations its driver fills in, and #W dereferences nothing
 * else.  What is behind the first two fields is the driver's, and #W
 * has no declaration for it.
 *
 * The layers above were already separable and had been measured so:
 * lora(3) and ax25(3) attach to a packet device by file descriptor and
 * include none of this.  It is only the device itself that knew which
 * part it was talking to.
 *
 * A board fills in a Spidev and hands it to a driver's init; everything
 * below the Spidev -- which controller, which chip select, which pin an
 * interrupt arrived on -- is the board's business, and a board may have
 * more than one socket on one bus.
 */

typedef struct Spidev Spidev;
typedef struct Radio Radio;
typedef struct Radiodev Radiodev;

struct Spidev
{
	char	*name;
	void	*aux;			/* the board's own */
	void	(*select)(Spidev*, int);	/* chip select: 1 asserted, 0 not */
	int	(*byte)(Spidev*, int);	/* clock one byte out, return the one in */
	void	(*lock)(Spidev*);	/* the bus is shared with storage */
	void	(*unlock)(Spidev*);
};

struct Radiodev
{
	char	*name;			/* the part, for a console line */
	int	maxpayload;		/* what one packet may carry */
	int	(*send)(Radio*, uchar*, int);
	int	(*ctl)(Radio*, char*, int);
	int	(*stat)(Radio*, char*, int);
	/*
	 * Optional: transmit a test packet and report what the part did
	 * with it, as a read rather than a write.
	 *
	 * A write to a ctl file needs a redirection and a redirection
	 * needs a process, and os/inferno/stm32f407 can spawn exactly
	 * one of those in a boot -- so a bench driven through ctl costs
	 * a reset for every session.  A read costs nothing: the shell
	 * runs cat in its own process.  nil if the driver has no bench.
	 */
	int	(*txtest)(Radio*, char*, int);
};

/*
 * Every driver's own structure begins with this, in the way
 * portdat.h's do: the common part first and the driver's behind it.
 */
struct Radio
{
	Radiodev *dev;
	Queue	*rq;			/* received packets, one block each */

	/*
	 * The claim on the receive path.  data and pkt are one queue,
	 * so a second reader is two processes taking alternate packets
	 * and each missing the other's; #W refuses the second rather
	 * than letting it block for ever on packets that went
	 * elsewhere.  It is the device's business and not the part's,
	 * which is why it is here.
	 */
	Lock	rl;
	int	reading;
};

enum {
	/*
	 * What a read of #W/radio0/pkt returns in front of the payload.
	 * recvmsg() rather than recv(): the things a radio knows about
	 * a packet that the packet does not contain -- how strong it
	 * was, how clean, whether its CRC checked, when it arrived --
	 * handed over with it, out of the same queue entry, so that
	 * nothing is looked up afterwards and nothing races.  None of
	 * it goes on the air.
	 *
	 *	uchar	len[2]		payload bytes following
	 *	uchar	rssi[2]		dBm, signed
	 *	uchar	snr[2]		dB, signed
	 *	uchar	flags[2]	Pcrcerr
	 *	uchar	tick[4]		arrival, in clock ticks
	 *
	 * It is #W's format and not any part's, which is why it is here
	 * and not in a chip driver's header.
	 */
	Pkthdrlen	= 12,
	Pcrcerr		= 1<<0,
};
