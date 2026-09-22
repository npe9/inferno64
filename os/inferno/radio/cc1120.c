#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../radio/cc1120.h"

/*
 * TI CC1120 narrowband transceiver.
 *
 * Written from the CC112x/CC1175 user's guide (SWRU295E) and the
 * CC1120 data sheet.  Variable packet length with a length byte and
 * hardware CRC, which is what the part does by default and what a
 * packet radio wants; the fixed-length and infinite-length modes exist
 * and this does not pretend to them.
 *
 * No RadioHead header here, unlike os/inferno/radio/sx127x.c.  That
 * header is in the SX127x driver because it is what the other end of a
 * PyCubed link speaks; nothing at the other end of this one has asked
 * for anything, so what goes out is what was written.  #a puts AX.25
 * on top and #L would put RadioHead on top, and either is a layer
 * above this file rather than inside it.
 *
 * What the part is for and is not: 164-192, 274-320, 410-480 and
 * 820-960MHz, and 2-FSK, 4-FSK, MSK or OOK.  It does not reach the
 * 144MHz amateur band and it does not produce the 1200-baud AFSK on an
 * FM carrier that an APRS handheld demodulates.  A radio-to-radio
 * AX.25 link on 868 is what this is good for.
 */

enum {
	/* the command/address byte, SWRU295E 3.1 */
	Hread		= 0x80,
	Hburst		= 0x40,

	/* primary registers this driver touches */
	Riocfg3		= 0x00,
	Riocfg2		= 0x01,
	Riocfg1		= 0x02,
	Riocfg0		= 0x03,
	Rsynccfg1	= 0x08,
	Ragccsthr	= 0x18,		/* carrier sense threshold */
	Ragccfg0	= 0x1d,
	  Agccfg0init	= 0xcf,		/* reset 0xc3, RSSI_VALID_CNT 9 */
	Ragcgainadjust	= 0x19,		/* the RSSI offset */
	Rpktcfg0	= 0x28,
	  Lenfixed	= 0x00,		/* PKT_CFG0.LENGTH_CONFIG = 00 */
	  Lenvariable	= 0x20,		/* PKT_CFG0.LENGTH_CONFIG = 01 */
	Rrfendcfg1	= 0x29,
	Rrfendcfg0	= 0x2a,
	Rpktlen		= 0x2e,

	/* the extended space, reached through 0x2f */
	Rext		= 0x2f,
	Xfreq2		= 0x0c,
	Xfreq1		= 0x0d,
	Xfreq0		= 0x0e,
	Xpartnumber	= 0x8f,
	Xpartversion	= 0x90,
	Xmarcstatus1	= 0x94,
	Xrssi1		= 0x71,		/* 8 MSB of RSSI[11:0], dBm */
	Xrssi0		= 0x72,
	  Rssivalid	= 1<<0,
	  Csvalid	= 1<<1,
	  Carriersense	= 1<<2,
	Rssiinvalid	= -128,		/* what RSSI1 reads when it is not */
	Xnumtxbytes	= 0xd6,
	Xnumrxbytes	= 0xd7,

	/* command strobes, SWRU295E table 4 */
	Sres		= 0x30,
	Sfstxon		= 0x31,
	Scal		= 0x33,
	Srx		= 0x34,
	Stx		= 0x35,
	Sidle		= 0x36,
	Sfrx		= 0x3a,
	Sftx		= 0x3b,
	Snop		= 0x3d,
	Rfifo		= 0x3f,

	/* the status byte, SWRU295E table 2 */
	Stchiprdyn	= 0x80,
	Ststate		= 0x70,
	  Stidle	= 0<<4,
	  Strx		= 1<<4,
	  Sttx		= 2<<4,
	  Stfstxon	= 3<<4,
	  Stcal		= 4<<4,
	  Stsettle	= 5<<4,
	  Strxerr	= 6<<4,
	  Sttxerr	= 7<<4,

	Partcc1120	= 0x48,

	/* what an IOCFG selects */
	Gpktsyncrxtx	= 0x06,
	Ghighz		= 0x30,

	/*
	 * Waits, in milliseconds, checked once a millisecond.
	 *
	 * These were spin counts -- 100000 turns of a loop whose body
	 * is an SPI strobe.  A strobe is one byte, and this board
	 * clocks the CC1120 at 164kHz, so a turn is 49us and the
	 * "bounded" wait after a transmit was four and nine tenths
	 * seconds of hammering the bus at splhi for half of it.  Typed
	 * at a shell that is a hang, and it was reported as one.
	 *
	 * A bound belongs in the unit the thing being waited for is
	 * measured in.  A packet of a hundred bytes at the slowest
	 * symbol rate this part will do is tens of milliseconds, so
	 * half a second is generous for a transmit and a tenth is
	 * generous for an RSSI estimate, whose own filter is nine
	 * internal estimates long.  A millisecond between looks costs
	 * one SPI byte instead of twenty.
	 */
	Txwaitms	= 500,		/* for a transmit to finish */
	Rssiwaitms	= 100,		/* for RSSI_VALID */
	/*
	 * Each try is a whole SPI byte -- 48us at this board's clock --
	 * so two thousand is a tenth of a second, against a crystal
	 * that starts in a few milliseconds.
	 */
	Readytries	= 2000,		/* spins waiting for CHIP_RDYn */
	Idlewaitus	= 2000,		/* strobes waiting to reach IDLE */

	/*
	 * The RSSI offset, in dB, written to AGC_GAIN_ADJUST.
	 *
	 * RSSI[11:0] out of reset is the level before the front end's
	 * gain is taken off it, so it reads about a hundred decibels
	 * high: this board, in a room, with no antenna, reported -6dBm
	 * on 868MHz, which would be a transmitter in the same hand.
	 * SWRU295E 6.10 says to add a calibrated offset and gives the
	 * worked example -102, which is the figure every TI example
	 * for this part uses.
	 *
	 * -102 IS NOT A MEASUREMENT OF THIS BOARD.  The offset is
	 * properly found by putting a signal of known strength into
	 * the antenna with the register at zero and subtracting, and
	 * nothing here has done that.  It is the manufacturer's
	 * reference figure, it puts a quiet 868MHz band at about
	 * -108dBm where it belongs rather than at -6, and the "offset"
	 * field in the stats says which number is in the part so that
	 * a reading is never mistaken for a calibrated one.  The
	 * "rssioffset" ctl changes it.
	 */
	Rssioffset	= -102,

	/*
	 * The carrier sense threshold, in the same dBm the RSSI is in
	 * once the offset above is programmed.  SWRU295E 6.9.1: CS is
	 * asserted while RSSI is above it, and it "should be set high
	 * enough so that CS is de-asserted when only background noise
	 * is present and low enough so that CS is asserted when a
	 * wanted signal is present".
	 *
	 * It resets to 0x00, which is 0dBm, which nothing this part
	 * will ever hear exceeds -- so out of reset the carrier sense
	 * this driver reports in its stats and in every line of a band
	 * sweep cannot assert at all.  That is worse than not
	 * reporting it: a field that always says no reads like an
	 * answer.  Found by sweeping 868 to 928MHz on a real board and
	 * getting sixty-one valid readings and not one "carrier".
	 *
	 * -90 is twenty decibels above the floor that sweep measured,
	 * which ran -101 to -123dBm with a median near -109.  High
	 * enough that thermal noise does not trip it, low enough that
	 * anything worth calling a signal does.  Like the offset it is
	 * a starting point and not a calibration; "csthr" changes it
	 * and the stats say what it is.
	 */
	Csthr		= -90,

	/*
	 * How long a band sweep sits on each step, in milliseconds.
	 * Sixty-one steps at a tenth of a second is about seven
	 * seconds for the default 868 to 928MHz sweep, which is worth
	 * it for a hundred samples a step instead of one.
	 */
	Dwellms		= 100,
	/*
	 * How many bytes "cat /dev/radio0/txtest" sends.  At the
	 * 1200 baud this part comes up at, 125 bytes is most of a
	 * second on the air, which is what an instrument watching for
	 * it needs.
	 */
	Txtestlen	= 125,

	/*
	 * Where the part is tuned when nothing has said otherwise.
	 *
	 * It had been left at whatever the FREQ registers hold out of
	 * reset, which is not a documented frequency and not the same
	 * question as "what band is this part for".  Two boards talked
	 * to each other only because both were undefined in the same
	 * way, and the stats reported "freq 0" because nothing had
	 * ever tuned it.  868MHz is the European SRD band and inside
	 * the 820-960MHz range a ccRF click's matching network is cut
	 * for.
	 */
	Deffreq		= 868000000,
};

static int
strobe(Cc1120 *rr, int cmd)
{
	Spidev *s;
	int st;

	s = rr->spi;
	s->select(s, 1);
	st = s->byte(s, cmd);
	s->select(s, 0);
	return st;
}

/*
 * Wait for the part to be able to answer.
 *
 * CHIP_RDYn, the top bit of the status byte every transaction returns,
 * is high until the crystal oscillator is running and the part is
 * ready (SWRU295E 3.1.1).  After a reset -- the RESET_N pin or the
 * SRES strobe -- it stays high for as long as the crystal takes to
 * start, which is milliseconds on a real part and depends on the
 * crystal, not on the radio.
 *
 * This is the one thing in this driver that an emulator cannot fail
 * on and a board cannot pass without.  qemu's model is ready the
 * instant it is reset, so reading PARTNUMBER straight after SRES
 * worked there for as long as this driver has existed; on a clicker 2
 * with a ccRF click in it the same sequence read 0x00 and the kernel
 * reported no CC1120 in a socket with a CC1120 in it, every boot.
 * Asked again a second later through #P/spi2, the same part answered
 * 0x48.  Nothing was wrong with the bus.
 *
 * Polling SNOP for the bit is the handshake the user's guide
 * describes as watching SO go low after CSn: it is the same signal,
 * and it needs no way to read the MISO pin, which a Spidev does not
 * have.  Returns the status byte, or -1.
 */
static int
chipready(Cc1120 *rr)
{
	int i, st;

	for(i = 0; i < Readytries; i++){
		st = strobe(rr, Snop);
		if((st & Stchiprdyn) == 0)
			return st;
	}
	return -1;
}

static int
rd(Cc1120 *rr, int addr)
{
	Spidev *s;
	int v;

	s = rr->spi;
	s->select(s, 1);
	s->byte(s, Hread | addr);
	v = s->byte(s, 0);
	s->select(s, 0);
	return v;
}

static void
wr(Cc1120 *rr, int addr, int val)
{
	Spidev *s;

	s = rr->spi;
	s->select(s, 1);
	s->byte(s, addr);
	s->byte(s, val);
	s->select(s, 0);
}

/*
 * The extended space.  The command byte is 0x2f, the next byte is the
 * extended address, and only then does data move; SO returns zeros
 * while the extended address is going out rather than the status byte,
 * which is worth knowing when reading this on a scope.
 */
static int
rdx(Cc1120 *rr, int addr)
{
	Spidev *s;
	int v;

	s = rr->spi;
	s->select(s, 1);
	s->byte(s, Hread | Rext);
	s->byte(s, addr);
	v = s->byte(s, 0);
	s->select(s, 0);
	return v;
}

static void
wrx(Cc1120 *rr, int addr, int val)
{
	Spidev *s;

	s = rr->spi;
	s->select(s, 1);
	s->byte(s, Rext);
	s->byte(s, addr);
	s->byte(s, val);
	s->select(s, 0);
}

static int
state(Cc1120 *rr)
{
	return strobe(rr, Snop) & Ststate;
}

/*
 * Send one packet.
 *
 * Variable length: the first byte into the FIFO is the length and is
 * not itself counted.  The part appends the CRC and strips it again at
 * the far end, so what a caller writes is what the far end reads.
 */
static int
cc1120send(Radio *r, uchar *p, int n)
{
	Cc1120 *rr;
	Spidev *s;
	int i, st;

	rr = (Cc1120*)r;
	if(n < 1 || n > Ccmaxpayload){
		rr->ntoobig++;
		return -1;
	}

	qlock(&rr->qlock);
	if(waserror()){
		qunlock(&rr->qlock);
		nexterror();
	}

	s = rr->spi;
	s->lock(s);
	/*
	 * SIDLE is a request, not an act: leaving RX means shutting the
	 * receiver down, and the part is in SETTLING until it has.
	 * SWRU295E's own sequence is idle, flush, fill, strobe, and
	 * flushing or filling a part that has not arrived in IDLE yet
	 * is not the same thing as doing it to one that has.  Bounded,
	 * because a part that never reaches IDLE is a fault and not a
	 * reason to spin.
	 */
	rr->txtrace[0] = state(rr) >> 4;
	strobe(rr, Sidle);
	for(i = 0; i < Idlewaitus; i++)
		if(state(rr) == Stidle)
			break;
	rr->txtrace[1] = state(rr) >> 4;
	strobe(rr, Sftx);
	rr->txtrace[2] = state(rr) >> 4;

	s->select(s, 1);
	s->byte(s, Rfifo | Hburst);
	if(!rr->fixedlen)
		s->byte(s, n);		/* variable: the length leads */
	for(i = 0; i < n; i++)
		s->byte(s, p[i]);
	s->select(s, 0);

	/*
	 * What went into the FIFO, before the part is told to send it.
	 * A transmit that underflows has either been given less than
	 * it was told to send or has not been given anything at all,
	 * and those are different faults: the first is a driver that
	 * has miscounted, the second a burst write that never reached
	 * the part.  One number tells them apart and it can only be
	 * read here, between the write and the strobe.
	 */
	rr->txstaged = rdx(rr, Xnumtxbytes);
	strobe(rr, Stx);
	rr->txtrace[3] = state(rr) >> 4;
	/*
	 * The part goes through SETTLING on its way into TX.  Watch
	 * for what it settles into, tightly, because the whole thing
	 * is over in less than the millisecond the wait below looks
	 * at: on this board the state a millisecond after STX is
	 * already TX FIFO error, so whether TX was ever reached is
	 * not visible there.
	 */
	rr->txtrace[4] = 0xf;
	for(i = 0; i < Idlewaitus; i++){
		st = state(rr);
		if(st != Stsettle){
			rr->txtrace[4] = st >> 4;
			break;
		}
	}
	s->unlock(s);

	/*
	 * Wait for the part to leave TX.  Bounded, and counted when it
	 * runs out: a transmit that never completes is a fault worth a
	 * number in the stat file rather than a process stuck for ever.
	 */
	for(i = 0; i < Txwaitms; i++){
		s->lock(s);
		st = state(rr);
		s->unlock(s);
		if(st != Sttx && st != Stsettle && st != Stcal)
			break;
		delay(1);
	}
	if(i >= Txwaitms)
		rr->ntxtimeout++;

	s->lock(s);
	/*
	 * MARC_STATUS1 is the part's own account of why it stopped:
	 * 0x40 finished the transmit, 0x07 overflowed the TX FIFO,
	 * 0x08 underflowed it, and so on (SWRU295E, MARC_STATUS1).
	 * Reading it clears it, so it is read once and kept.
	 */
	rr->txmarc = rdx(rr, Xmarcstatus1);
	rr->txtrace[5] = state(rr) >> 4;
	/*
	 * And what is left in the TX FIFO.  This is the number that
	 * says which fault it is: nothing left means the part read the
	 * packet out and then wanted more than the length byte
	 * promised, and everything still there means it never read the
	 * FIFO at all and errored for some other reason.
	 */
	rr->txleft = rdx(rr, Xnumtxbytes);
	if(state(rr) == Sttxerr){
		rr->ntxunderflow++;
		strobe(rr, Sftx);
	}
	/* back to listening */
	strobe(rr, Srx);
	s->unlock(s);

	rr->nsent++;
	poperror();
	qunlock(&rr->qlock);
	return n;
}

/*
 * A packet has arrived, or the part wants attention.  Called from the
 * board's interrupt handler with the part's GPIO3 asserted.
 */
void
cc1120interrupt(Radio *r)
{
	Cc1120 *rr;
	Spidev *s;
	Block *b;
	ulong tick;
	int n, i, st;

	rr = (Cc1120*)r;
	s = rr->spi;

	s->lock(s);
	st = state(rr);
	if(st == Strxerr){
		rr->nrxoverflow++;
		strobe(rr, Sfrx);
		strobe(rr, Srx);
		s->unlock(s);
		return;
	}

	n = rdx(rr, Xnumrxbytes);
	if(n < 1){
		s->unlock(s);
		return;
	}

	/* the length byte first, then that many */
	s->select(s, 1);
	s->byte(s, Hread | Hburst | Rfifo);
	n = s->byte(s, 0);
	if(n < 1 || n > Ccmaxpayload){
		s->select(s, 0);
		rr->ncrcerr++;
		strobe(rr, Sfrx);
		strobe(rr, Srx);
		s->unlock(s);
		return;
	}
	/*
	 * Every block on the queue begins with #W's twelve-byte header:
	 * length, rssi, snr, flags and arrival tick, in that order.  It
	 * is the device's format and not the part's -- see the note on
	 * Pkthdrlen in radio.h -- and #W/data hands out what follows it
	 * while #W/pkt hands out the whole thing.  A driver that queues
	 * a bare payload does not fail; it loses the first twelve bytes
	 * of every packet to a reader of data, which is a long way to
	 * look for a short header.
	 *
	 * snr is zero: the part reports a link quality indicator rather
	 * than a signal-to-noise ratio, and a number in the wrong units
	 * is worse than none.  rssi is read after the packet, from the
	 * extended space.
	 */
	b = iallocb(Pkthdrlen + n);
	if(b == nil){
		s->select(s, 0);
		strobe(rr, Sfrx);
		strobe(rr, Srx);
		s->unlock(s);
		return;
	}
	for(i = 0; i < n; i++)
		b->wp[Pkthdrlen + i] = s->byte(s, 0);
	s->select(s, 0);

	rr->rssi = (schar)rdx(rr, Xrssi1);
	rr->lqi = 0;
	strobe(rr, Srx);
	s->unlock(s);

	tick = fastticks(nil);
	b->wp[0] = n;
	b->wp[1] = n >> 8;
	b->wp[2] = rr->rssi;
	b->wp[3] = rr->rssi >> 8;
	b->wp[4] = 0;
	b->wp[5] = 0;
	b->wp[6] = 0;
	b->wp[7] = 0;
	b->wp[8] = tick;
	b->wp[9] = tick >> 8;
	b->wp[10] = tick >> 16;
	b->wp[11] = tick >> 24;
	b->wp += Pkthdrlen + n;

	rr->nrecv++;
	qpass(rr->rq, b);
}

/*
 * FREQ is a 24-bit word: the RF frequency times the LO divider,
 * scaled by 2^16 over the crystal.  The 820-960MHz band divides by 4,
 * and a ccRF 2 click has a 32MHz crystal.
 */
static void
setfreq(Cc1120 *rr, uvlong hz)
{
	u32 v;

	v = (u32)((hz * 4 * 65536) / 32000000);
	rr->hz = hz;
	strobe(rr, Sidle);
	wrx(rr, Xfreq2, (v>>16) & 0xff);
	wrx(rr, Xfreq1, (v>>8) & 0xff);
	wrx(rr, Xfreq0, v & 0xff);
	strobe(rr, Scal);
	strobe(rr, Srx);
}

/*
 * Sample the RSSI for ms milliseconds at whatever the part is tuned
 * to, and print one line of it.
 *
 * Fields, and nothing but fields, so awk(1) can have it: the tag, the
 * frequency, the peak, the mean, the floor, how many samples they are
 * of, and which sample the peak was, with the word "carrier" on the
 * end or nothing.  The mean is truncated toward zero, so it reads up
 * to a decibel high.
 *
 * The index is there to answer the question a peak alone cannot:
 * whether a loud sample was something on the air or the sweep hearing
 * its own retune.  setfreq() strobes SIDLE, SCAL and SRX, and the
 * first valid estimate after the AGC restarts could be a settling
 * artefact -- which would land at the beginning of every dwell, where
 * a signal is scattered through it.  Measured on a board: the indices
 * come out uniform across the dwell and the loud samples come and go
 * between sweeps, so they are not the tuning.
 *
 * One sample is not a measurement of anything.  Two sweeps of 868 to
 * 928MHz taken a sample a step correlated at r = -0.062, which is to
 * say not at all.
 *
 * The lock is taken per sample and not held across the dwell: it is
 * an ilock, and a tenth of a second at splhi would lose the console
 * and the radio's own interrupt.
 */
static void
dwell1(Cc1120 *rr, char *tag, ulong ms)
{
	Spidev *s;
	int r0, r1, j, peak, floor, nsamp, cs, peakat;
	long sum;

	s = rr->spi;
	peak = -128;
	floor = 127;
	sum = 0;
	nsamp = 0;
	cs = 0;
	peakat = -1;
	for(j = 0; j < ms; j++){
		s->lock(s);
		r0 = rdx(rr, Xrssi0);
		r1 = (schar)rdx(rr, Xrssi1);
		s->unlock(s);
		if(r0 & Rssivalid){
			if(r1 > peak){
				peak = r1;
				peakat = nsamp;
			}
			if(r1 < floor)
				floor = r1;
			sum += r1;
			nsamp++;
		}
		if((r0 & Csvalid) && (r0 & Carriersense))
			cs = 1;
		delay(1);
	}
	if(nsamp == 0){
		print("%s %lud invalid\n", tag, (ulong)rr->hz);
		return;
	}
	print("%s %lud %d %d %d %d %d%s\n", tag, (ulong)rr->hz,
		peak, (int)(sum/nsamp), floor, nsamp, peakat,
		cs? " carrier": "");
}

static int
cc1120ctl(Radio *r, char *buf, int n)
{
	Cc1120 *rr;
	Spidev *s;
	char *f[5], cbuf[64];
	uvlong hz;
	int nf;

	rr = (Cc1120*)r;
	if(n >= sizeof cbuf)
		n = sizeof cbuf - 1;
	memmove(cbuf, buf, n);
	cbuf[n] = 0;
	nf = tokenize(cbuf, f, nelem(f));
	if(nf < 1)
		error(Ebadctl);

	s = rr->spi;
	if(strcmp(f[0], "scan") == 0){
		/*
		 * Sweep the band and report what the receiver hears.
		 *
		 * RSSI[11:0] is two's complement dBm with 0.0625dB
		 * resolution, so the eight bits of RSSI1 are whole dBm,
		 * and -128 means the value is not valid yet (SWRU295E,
		 * RSSI1).  RSSI0 carries RSSI_VALID and a carrier sense
		 * that the part computes against its own threshold.
		 *
		 * Waiting for RSSI_VALID at each step rather than
		 * sleeping a fixed time: how long the estimate takes
		 * depends on AGC_CFG0.RSSI_VALID_CNT, which is a
		 * setting and not a constant.
		 */
		ulong lo, hi, step, dwell;
		int r0, i;

		lo = 868000000;
		hi = 928000000;
		step = 1000000;
		dwell = Dwellms;
		if(nf >= 4){
			lo = strtoul(f[1], nil, 0);
			hi = strtoul(f[2], nil, 0);
			step = strtoul(f[3], nil, 0);
		}
		if(nf >= 5)
			dwell = strtoul(f[4], nil, 0);
		if(step == 0 || lo > hi || dwell > 10000)
			error(Ebadctl);
		for(hz = lo; hz <= hi; hz += step){
			s->lock(s);
			setfreq(rr, hz);
			s->unlock(s);
			/*
			 * Let the estimate settle before the dwell
			 * starts, taking the lock for each look rather
			 * than holding it across the wait: it is an
			 * ilock, and the delay below would otherwise be
			 * a tenth of a second at splhi with no console
			 * and no interrupt from the radio.
			 */
			for(i = 0; i < Rssiwaitms; i++){
				s->lock(s);
				r0 = rdx(rr, Xrssi0);
				s->unlock(s);
				if(r0 & Rssivalid)
					break;
				delay(1);
			}

			dwell1(rr, "scan", dwell);
		}
		return n;
	}
	if(strcmp(f[0], "reg") == 0 || strcmp(f[0], "regx") == 0){
		/*
		 * Read or write one of the part's registers by number,
		 * in the normal space or the extended one.
		 *
		 * A bench, not an interface.  Every question asked of
		 * this part so far has cost a flash cycle and a reset,
		 * and the answers have been narrowing on something that
		 * one register read would settle.  With this the board
		 * answers at a prompt:
		 *
		 *	; cat >/dev/radio0/ctl
		 *	reg 0x28		PKT_CFG0
		 *	reg 0x28 0x20		set it
		 *	regx 0x8f		PARTNUMBER
		 *
		 * It can obviously be used to put the part into a state
		 * the driver above it does not expect.  That is the
		 * point of a bench.
		 */
		int ext, addr, val;

		ext = f[0][3] == 'x';
		if(nf < 2)
			error(Ebadctl);
		addr = strtoul(f[1], nil, 0);
		if(addr < 0 || addr > 0xff || (!ext && addr > 0x2e))
			error(Ebadctl);
		s->lock(s);
		if(nf >= 3){
			val = strtoul(f[2], nil, 0);
			if(ext)
				wrx(rr, addr, val);
			else
				wr(rr, addr, val);
		}
		val = ext? rdx(rr, addr): rd(rr, addr);
		s->unlock(s);
		print("%s 0x%.2x 0x%.2x\n", ext? "regx": "reg", addr, val);
		return n;
	}
	if(strcmp(f[0], "pktlen") == 0 && nf == 2){
		int len;

		len = atoi(f[1]);
		if(len < 1 || len > 255)
			error(Ebadctl);
		s->lock(s);
		wr(rr, Rpktlen, len);
		s->unlock(s);
		return n;
	}
	if(strcmp(f[0], "txmode") == 0 && nf == 2){
		/*
		 * Fixed or variable packet length, changed at a prompt,
		 * so the two can be compared on one board without a
		 * flash cycle between them.  In fixed mode the part
		 * sends PKT_LEN bytes and no length byte goes in the
		 * FIFO; in variable mode the length leads and PKT_LEN
		 * is only a maximum.
		 */
		if(strcmp(f[1], "fixed") == 0)
			rr->fixedlen = 1;
		else if(strcmp(f[1], "var") == 0)
			rr->fixedlen = 0;
		else
			error(Ebadctl);
		s->lock(s);
		wr(rr, Rpktcfg0, rr->fixedlen? Lenfixed: Lenvariable);
		if(!rr->fixedlen)
			wr(rr, Rpktlen, Ccmaxpayload);
		s->unlock(s);
		return n;
	}
	if(strcmp(f[0], "txtest") == 0){
		/*
		 * Send a packet of a given length and print what the
		 * part did with it, rather than leaving it in the stats
		 * to be read afterwards -- the console can hold one
		 * redirection at a time on this board, so a bench that
		 * reports as it goes is a bench that can be used.
		 */
		uchar buf[Ccmaxpayload];
		int len, j;

		len = 4;
		if(nf >= 2)
			len = atoi(f[1]);
		if(len < 1 || len > Ccmaxpayload)
			error(Ebadctl);
		for(j = 0; j < len; j++)
			buf[j] = 'a' + j % 26;
		if(rr->fixedlen){
			s->lock(s);
			wr(rr, Rpktlen, len);
			s->unlock(s);
		}
		cc1120send(r, buf, len);
		print("txtest %d %s staged %d trace %d %d %d %d %d %d"
			" left %d marc 0x%.2x\n",
			len, rr->fixedlen? "fixed": "var", rr->txstaged,
			rr->txtrace[0], rr->txtrace[1], rr->txtrace[2],
			rr->txtrace[3], rr->txtrace[4], rr->txtrace[5],
			rr->txleft, rr->txmarc);
		return n;
	}
	if(strcmp(f[0], "watch") == 0){
		/*
		 * Stay where the part is tuned and report a line every
		 * dwell, for as long as asked.  A sweep says what the
		 * band looked like once; this says what one frequency
		 * does over time, which is the only way to tell a
		 * transmitter that comes and goes from one that was
		 * never there.  It is what found nothing twice and
		 * something once at 100ms a step.
		 */
		ulong secs, i;

		secs = 10;
		if(nf >= 2)
			secs = strtoul(f[1], nil, 0);
		if(secs == 0 || secs > 600)
			error(Ebadctl);
		for(i = 0; i < secs*1000/Dwellms; i++)
			dwell1(rr, "watch", Dwellms);
		return n;
	}
	if(strcmp(f[0], "csthr") == 0 && nf == 2){
		int thr;

		thr = atoi(f[1]);
		if(thr < -128 || thr > 127)
			error(Ebadctl);
		s->lock(s);
		rr->csthr = thr;
		wr(rr, Ragccsthr, thr & 0xff);
		s->unlock(s);
		return n;
	}
	if(strcmp(f[0], "rssioffset") == 0 && nf == 2){
		int off;

		off = atoi(f[1]);
		if(off < -128 || off > 127)
			error(Ebadctl);
		s->lock(s);
		rr->rssioffset = off;
		wr(rr, Ragcgainadjust, off & 0xff);
		s->unlock(s);
		return n;
	}
	if(strcmp(f[0], "freq") == 0 && nf == 2){
		/*
		 * FREQ is a 24-bit word, the RF frequency divided by the
		 * frequency-synthesiser resolution: f * 2^16 / fxosc,
		 * with a 32MHz crystal and the LO divider for the band.
		 * The 820-960MHz band divides by 4, which is the only
		 * one a ccRF 2 click is matched for.
		 */
		hz = strtoul(f[1], nil, 0);
		if(hz < 820000000 || hz > 960000000)
			error("frequency outside the band this click is matched for");
		s->lock(s);
		setfreq(rr, hz);
		s->unlock(s);
		return n;
	}
	if(strcmp(f[0], "idle") == 0){
		s->lock(s);
		strobe(rr, Sidle);
		s->unlock(s);
		return n;
	}
	if(strcmp(f[0], "rx") == 0){
		s->lock(s);
		strobe(rr, Srx);
		s->unlock(s);
		return n;
	}
	if(strcmp(f[0], "reset") == 0){
		s->lock(s);
		strobe(rr, Sres);
		s->unlock(s);
		return n;
	}
	error(Ebadctl);
	return -1;
}

static int
cc1120stat(Radio *r, char *p, int n)
{
	Cc1120 *rr;
	Spidev *s;
	int st, nrx, ntx, live, cs, pktcfg0, pktlen;

	rr = (Cc1120*)r;
	s = rr->spi;
	s->lock(s);
	st = state(rr);
	/*
	 * Read back what the part actually holds rather than what this
	 * driver believes it wrote.  The two differed for as long as
	 * this file has existed.
	 */
	pktcfg0 = rd(rr, Rpktcfg0);
	pktlen = rd(rr, Rpktlen);
	nrx = rdx(rr, Xnumrxbytes);
	ntx = rdx(rr, Xnumtxbytes);
	live = (schar)rdx(rr, Xrssi1);
	cs = rdx(rr, Xrssi0);
	s->unlock(s);

	return snprint(p, n,
		"part CC1120 0x%.2x rev 0x%.2x\n"
		"state 0x%.2x\n"
		"freq %lud\n"
		"rssi %d%s offset %d csthr %d last %d%s\n"
		"fifo rx %d tx %d\n"
		"lasttx staged %d marc 0x%.2x\n"
		"pktcfg0 0x%.2x pktlen %d\n"
		"txtrace %d %d %d %d %d %d left %d\n"
		"sent %ud recv %ud\n"
		"crcerr %ud toobig %ud txtimeout %ud\n"
		"rxoverflow %ud txunderflow %ud\n",
		rr->partnum, rr->partversion,
		st >> 4,
		(ulong)rr->hz,
		live, (cs & Rssivalid)? "": " invalid",
		rr->rssioffset, rr->csthr, rr->rssi,
		(cs & Carriersense)? " carrier": "",
		nrx, ntx,
		rr->txstaged, rr->txmarc,
		pktcfg0, pktlen,
		rr->txtrace[0], rr->txtrace[1], rr->txtrace[2],
		rr->txtrace[3], rr->txtrace[4], rr->txtrace[5], rr->txleft,
		rr->nsent, rr->nrecv,
		rr->ncrcerr, rr->ntoobig, rr->ntxtimeout,
		rr->nrxoverflow, rr->ntxunderflow);
}

/*
 * The bench, as a read: send a packet and say what the part did with
 * it.  Same numbers the "txtest" ctl prints, in a buffer instead of on
 * the console, so it can be had from "cat /dev/radio0/txtest" without
 * the redirection a ctl write needs.
 */
static int
cc1120txtest(Radio *r, char *p, int n)
{
	Cc1120 *rr;
	uchar buf[Txtestlen];
	int i;

	rr = (Cc1120*)r;
	for(i = 0; i < Txtestlen; i++)
		buf[i] = 'a' + i % 26;
	cc1120send(r, buf, Txtestlen);
	return snprint(p, n,
		"txtest %d %s staged %d trace %d %d %d %d %d %d"
		" left %d marc 0x%.2x\n",
		Txtestlen, rr->fixedlen? "fixed": "var", rr->txstaged,
		rr->txtrace[0], rr->txtrace[1], rr->txtrace[2],
		rr->txtrace[3], rr->txtrace[4], rr->txtrace[5],
		rr->txleft, rr->txmarc);
}

static Radiodev cc1120dev = {
	"CC1120",
	Ccmaxpayload,
	cc1120send,
	cc1120ctl,
	cc1120stat,
	cc1120txtest,
};

Radio*
cc1120init(Spidev *s, int irq)
{
	Cc1120 *rr;

	USED(irq);
	rr = malloc(sizeof(Cc1120));
	if(rr == nil)
		return nil;
	rr->dev = &cc1120dev;
	rr->spi = s;

	s->lock(s);
	strobe(rr, Sres);
	rr->ready = chipready(rr);
	rr->partnum = rdx(rr, Xpartnumber);
	rr->partversion = rdx(rr, Xpartversion);
	s->unlock(s);

	if(rr->ready < 0){
		print("cc1120 %s: not ready after reset, status stays 0x%.2x\n",
			s->name, strobe(rr, Snop));
		free(rr);
		return nil;
	}

	if(rr->partnum != Partcc1120){
		/*
		 * Say what was found rather than what was hoped for.  A
		 * bus that is not reaching the part reads 0x00 or 0xff,
		 * and those are worth telling apart from a CC1121 or a
		 * CC1125, which answer 0x40 and 0x58.
		 */
		print("cc1120 %s: PARTNUMBER 0x%.2x, not a CC1120 (0x%.2x)\n",
			s->name, rr->partnum, Partcc1120);
		free(rr);
		return nil;
	}
	rr->present = 1;

	rr->rq = qopen(16*1024, Qmsg, nil, nil);
	if(rr->rq == nil){
		free(rr);
		return nil;
	}

	s->lock(s);
	/*
	 * Variable packet length, and GPIO3 -- the pin the socket's INT
	 * line carries -- asserted when a packet has been received or
	 * sent.  IOCFG3 is register 0x00 and selects the function of
	 * GPIO3, which is the reverse of what the numbering suggests.
	 * The other three are parked at high impedance so a board that
	 * wired them to something is not surprised.
	 */
	wr(rr, Rpktcfg0, Lenvariable);
	wr(rr, Rpktlen, Ccmaxpayload);
	rr->rssioffset = Rssioffset;
	wr(rr, Ragcgainadjust, rr->rssioffset & 0xff);
	rr->csthr = Csthr;
	wr(rr, Ragccsthr, rr->csthr & 0xff);
	/*
	 * RSSI_VALID_CNT: how many internal estimates the moving
	 * average takes before it updates the RSSI.  Reset is two and
	 * the maximum is nine, which is a quieter number for the same
	 * signal, at the cost of updating less often.  Carrier sense
	 * is compared against the same filtered value, so it steadies
	 * too (SWRU295E 6.10).  Nothing here gates reception on
	 * carrier sense, so a slower update costs nothing else.
	 */
	wr(rr, Ragccfg0, Agccfg0init);
	wr(rr, Riocfg3, Gpktsyncrxtx);
	wr(rr, Riocfg2, Ghighz);
	wr(rr, Riocfg1, Ghighz);
	wr(rr, Riocfg0, Ghighz);
	setfreq(rr, Deffreq);		/* calibrates and goes to RX */
	s->unlock(s);

	print("cc1120 %s: CC1120 rev 0x%.2x, listening\n",
		s->name, rr->partversion);
	return rr;
}
