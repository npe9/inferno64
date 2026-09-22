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
	Ragcgainadjust	= 0x19,		/* the RSSI offset */
	Rpktcfg0	= 0x1c,
	  Lenvariable	= 0x20,		/* PKT_CFG0.LENGTH_CONFIG = 01 */
	Rrfendcfg1	= 0x1e,
	Rrfendcfg0	= 0x1f,
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

	Txtries		= 100000,	/* spins waiting for a transmit */
	Rssitries	= 200000,	/* spins waiting for RSSI_VALID */
	/*
	 * Each try is a whole SPI byte -- 48us at this board's clock --
	 * so two thousand is a tenth of a second, against a crystal
	 * that starts in a few milliseconds.
	 */
	Readytries	= 2000,		/* spins waiting for CHIP_RDYn */

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
	strobe(rr, Sidle);
	strobe(rr, Sftx);

	s->select(s, 1);
	s->byte(s, Rfifo | Hburst);
	s->byte(s, n);
	for(i = 0; i < n; i++)
		s->byte(s, p[i]);
	s->select(s, 0);

	strobe(rr, Stx);
	s->unlock(s);

	/*
	 * Wait for the part to leave TX.  Bounded, and counted when it
	 * runs out: a transmit that never completes is a fault worth a
	 * number in the stat file rather than a process stuck for ever.
	 */
	for(i = 0; i < Txtries; i++){
		s->lock(s);
		st = state(rr);
		s->unlock(s);
		if(st != Sttx && st != Stsettle && st != Stcal)
			break;
	}
	if(i >= Txtries)
		rr->ntxtimeout++;

	s->lock(s);
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
	strobe(rr, Sidle);
	wrx(rr, Xfreq2, (v>>16) & 0xff);
	wrx(rr, Xfreq1, (v>>8) & 0xff);
	wrx(rr, Xfreq0, v & 0xff);
	strobe(rr, Scal);
	strobe(rr, Srx);
}

static int
cc1120ctl(Radio *r, char *buf, int n)
{
	Cc1120 *rr;
	Spidev *s;
	char *f[4], cbuf[64];
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
		ulong lo, hi, step;
		int r1, r0, i;

		r0 = 0;			/* Rssitries could be zero */

		lo = 868000000;
		hi = 928000000;
		step = 1000000;
		if(nf >= 4){
			lo = strtoul(f[1], nil, 0);
			hi = strtoul(f[2], nil, 0);
			step = strtoul(f[3], nil, 0);
		}
		if(step == 0 || lo > hi)
			error(Ebadctl);
		for(hz = lo; hz <= hi; hz += step){
			s->lock(s);
			setfreq(rr, hz);
			for(i = 0; i < Rssitries; i++){
				r0 = rdx(rr, Xrssi0);
				if(r0 & Rssivalid)
					break;
			}
			r1 = (schar)rdx(rr, Xrssi1);
			s->unlock(s);
			print("scan %lud %d%s%s\n", (ulong)hz, r1,
				(r0 & Rssivalid)? "": " invalid",
				(r0 & Carriersense)? " carrier": "");
		}
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
	int st, nrx, ntx, live, cs;

	rr = (Cc1120*)r;
	s = rr->spi;
	s->lock(s);
	st = state(rr);
	nrx = rdx(rr, Xnumrxbytes);
	ntx = rdx(rr, Xnumtxbytes);
	live = (schar)rdx(rr, Xrssi1);
	cs = rdx(rr, Xrssi0);
	s->unlock(s);

	return snprint(p, n,
		"part CC1120 0x%.2x rev 0x%.2x\n"
		"state 0x%.2x\n"
		"rssi %d%s offset %d last %d%s\n"
		"fifo rx %d tx %d\n"
		"sent %ud recv %ud\n"
		"crcerr %ud toobig %ud txtimeout %ud\n"
		"rxoverflow %ud txunderflow %ud\n",
		rr->partnum, rr->partversion,
		st >> 4,
		live, (cs & Rssivalid)? "": " invalid",
		rr->rssioffset, rr->rssi,
		(cs & Carriersense)? " carrier": "",
		nrx, ntx,
		rr->nsent, rr->nrecv,
		rr->ncrcerr, rr->ntoobig, rr->ntxtimeout,
		rr->nrxoverflow, rr->ntxunderflow);
}

static Radiodev cc1120dev = {
	"CC1120",
	Ccmaxpayload,
	cc1120send,
	cc1120ctl,
	cc1120stat,
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
	wr(rr, Riocfg3, Gpktsyncrxtx);
	wr(rr, Riocfg2, Ghighz);
	wr(rr, Riocfg1, Ghighz);
	wr(rr, Riocfg0, Ghighz);
	strobe(rr, Scal);
	strobe(rr, Srx);
	s->unlock(s);

	print("cc1120 %s: CC1120 rev 0x%.2x, listening\n",
		s->name, rr->partversion);
	return rr;
}
