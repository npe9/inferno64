/*
 * A radio, as #W sees one.  The same file as os/inferno/radio/radio.h:
 * it is the contract between #W and a driver, and nothing in it
 * depends on which kernel is underneath.
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
 * A board fills in a transport and hands it to a driver's init;
 * everything below it -- which controller, which chip select, which pin
 * an interrupt arrived on, which uart -- is the board's business, and a
 * board may have more than one socket on one bus.
 *
 * WHAT A RADIO IS HERE.  Not a packet transceiver.  A CC1120 on a
 * clicker 2 and a Yaesu FT-891 on a serial line have nothing in common
 * except what this file says they do: a frequency, a mode, a transmit
 * key, and something to say about how strong what it hears is.  A
 * packet radio has more -- a payload size, a queue of received frames
 * -- and those are optional, because a transceiver with a microphone
 * socket has none of them.
 *
 *	maxpayload	0 if the radio does not carry packets.  #W then
 *			serves no data and no pkt file, allocates no
 *			receive queue, and the exclusive-reader claim
 *			never applies.  lora(3), ax25(3) and kiss(3)
 *			attach to data by file descriptor, so a radio
 *			without it cannot carry them.
 *	send		nil unless maxpayload is non-zero.
 *	ctl, stat	every radio has these.
 *	txtest		optional bench; see below.
 *
 * THE CTL VOCABULARY.  A driver is free to add its own, and every one
 * of these that applies to the part must mean the same thing on every
 * part:
 *
 *	freq <hz>	tune.  A driver that cannot reach a frequency
 *			must refuse it rather than tune somewhere else:
 *			os/inferno/radio/cc1120.c did the latter for a
 *			while by leaving FS_CFG's band select alone, so
 *			"freq 434000000" asked the synthesiser for a
 *			frequency it has no divider for and said nothing.
 *	mode <name>	fsk, msk, ook, cw, usb, lsb, am, fm ... what
 *			the part does.  A driver refuses a mode it has
 *			not got.
 *	power <dBm>	transmit power.
 *	ptt on|off	key the transmitter.  On a part that keys
 *			itself per packet this is a carrier, for
 *			tuning; on an HF set it is the PTT line.
 *	rx		receive.
 *	idle		neither.
 *	reset		start again.
 *
 * WHAT A RADIO CAN DO, AND SAYING SO.  Reading the ctl file gives the
 * settings that can be written to it, in the syntax they are written
 * in, and then what the radio will accept.  That is this system's
 * answer and not a new one: devvga's ctl, devaudio's audioctl and
 * devsd's ctl all read back what may be written, and devsd's reports
 * the geometry it will not let you set beside the partition table it
 * will.
 *
 * The other half of the question is answered by the directory.  A
 * radio with data and pkt in it carries packets and one without does
 * not; ls is the capability query, and that is why those two files
 * are conditional.
 *
 * The vocabulary is Hamlib's where Hamlib has one -- its rig_caps,
 * rx_range_list and tx_range_list, its RIG_LEVEL_* and RIG_FUNC_* --
 * because that is the accumulated answer across a couple of hundred
 * radios and there is no reason to invent a worse one.  What is not
 * taken is its shape: a bitmask of levels in a C structure is a
 * library's answer.
 *
 * Singular keys are settings and can be written back.  Plural keys
 * are what the radio has and cannot:
 *
 *	freq <hz>		tuned here
 *	mode <name>		doing this
 *	power <dBm>		transmitting at this
 *	ptt on|off
 *	band rx <lo> <hi>	a band it can receive, in hertz
 *	band tx <lo> <hi> <lo dBm> <hi dBm>
 *				a band it can transmit in, and how hard
 *	modes <name>...		the modes it has
 *	levels <name>...	what "level" can read or set
 *	funcs <name>...		what "func" can switch
 *
 * LEVELS AND FUNCS.  Hamlib's distinction and worth keeping: a level
 * has a value, a func is on or off.
 *
 *	level <name>		report it
 *	level <name> <value>	set it
 *	func <name>		report it
 *	func <name> on|off	switch it
 *
 * The names are Hamlib's where Hamlib has one -- strength, rfpower,
 * sql, swr, att, preamp -- so that a bridge to rigctl is a
 * translation and not an interpretation.  A part's own knobs keep
 * their own names beside those.
 *
 * THE STAT FORMAT.  Lines of "name value...", the first four common to
 * every radio so that a reader can say something about one it has
 * never heard of, the rest the driver's own:
 *
 *	part <name> ...		what it is
 *	freq <hz>		where it is tuned
 *	mode <name>		what it is doing
 *	state <n>		0 idle, 1 rx, 2 tx, and the driver's
 *				own numbers above that
 */

typedef struct Spidev Spidev;
typedef struct Serialport Serialport;
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

/*
 * A radio on a serial line rather than a bus: an HF set with a CAT
 * port, a TNC, a modem.  The driver above is written to this and does
 * not know whether the other end is a board uart, a USB adaptor or a
 * pipe -- which is the point, because an FT-891 is the same radio
 * whichever of those it is plugged into.
 *
 * read() returns what arrived within ms milliseconds, which may be
 * less than n and may be none: a CAT reply is a line ending in ';' and
 * a radio that is off answers nothing at all.  A driver must treat
 * silence as an answer rather than waiting for ever.
 */
struct Serialport
{
	char	*name;
	void	*aux;			/* the board's own */
	int	(*write)(Serialport*, void*, int);
	int	(*read)(Serialport*, void*, int, int);	/* n, ms */
	void	(*lock)(Serialport*);
	void	(*unlock)(Serialport*);
	/*
	 * Optional.  Settings that belong to the line rather than to
	 * the radio -- which device, what rate -- reach it here, after
	 * the driver has failed to recognise them.  A radio does not
	 * know what a serial port is and should not have to.
	 */
	int	(*ctl)(Serialport*, char*, int);
};

extern Radio* ft891init(Serialport*);

struct Radiodev
{
	char	*name;			/* the part, for a console line */
	int	maxpayload;		/* 0 if it does not carry packets */
	int	(*send)(Radio*, uchar*, int);	/* nil if no packets */
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
	/*
	 * What this radio is set to and what it will accept, in the
	 * format above; #W serves it as the ctl file's read.
	 * Optional -- a driver without one reads back only its name,
	 * as it always did.
	 */
	int	(*caps)(Radio*, char*, int);
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
