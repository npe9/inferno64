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
	Rdcfiltcfg	= 0x0c,
	Riqic		= 0x10,
	Rsync3		= 0x04,		/* sync word, 3 is the first on air */
	Rsync2		= 0x05,
	Rsync1		= 0x06,
	Rsync0		= 0x07,
	Rsynccfg1x	= 0x08,		/* SYNC_MODE in 4:0 */
	Rdeviationm	= 0x0a,
	Rmodcfgdeve	= 0x0b,		/* DEV_E in 2:0 */
	Rchanbw		= 0x11,
	Rdrate2		= 0x14,		/* DRATE_E in 7:4, DRATE_M's top 4 in 3:0 */
	Rdrate1		= 0x15,
	Rdrate0		= 0x16,
	  Fxosc		= 32000000,	/* the crystal these boards fit */
	Rmdmcfg0	= 0x13,
	  Transparenten	= 0x08,		/* MDMCFG0.TRANSPARENT_MODE_EN */
	  Transpintfact	= 0x30,		/* MDMCFG0.TRANSPARENT_INTFACT */
	Ragcref		= 0x17,
	Ragccfg1	= 0x1c,
	Rfifocfg	= 0x1e,
	Rsettlingcfg	= 0x20,
	Rfscfg		= 0x21,
	Rpktcfg1	= 0x27,
	Rpacfg2		= 0x2b,
	Rpacfg1		= 0x2c,
	Rpacfg0		= 0x2d,
	Ragccsthr	= 0x18,		/* carrier sense threshold */
	Ragccfg0	= 0x1d,
	/*
	 * AGC_CFG0.  Bits 3:2 are RSSI_VALID_CNT: how many internal
	 * estimates the RSSI averages before it updates, 2, 3, 5 or 9
	 * for 00, 01, 10 and 11.  Reset is 0xc3 and this is 0xcf, which
	 * is the slowest and steadiest.
	 *
	 * That is what the comment here said originally, and for most
	 * of a day it looked wrong, because writing this register makes
	 * the part report nonsense: 0xc3 gave a peak of +78dBm and a
	 * floor of +48 at 881MHz, and 0xcb gave a sane -84dBm once and
	 * +113dBm an hour later from the same write.  The name was
	 * taken off the constant on the strength of that.
	 *
	 * It is not the value, it is the state.  AGC_CFG0 has to be
	 * written with the part in IDLE; written while it is receiving
	 * it leaves the AGC somewhere the RSSI does not come back from.
	 * Written from IDLE and followed by a retune, every one of
	 * 0xc3, 0xc7, 0xcb and 0xcf reads a sane -93 to -110dBm at
	 * 881MHz, repeatably.
	 *
	 * And then the field measures itself.  The shortest carrier
	 * sense assertion the part will make is one RSSI update, so
	 * with "gcapture" at 881MHz the shortest burst is 0.608ms at
	 * 0xc3, 0.927 at 0xc7, 1.568 at 0xcb and 2.79 at 0xcf --
	 * ratios of 1.52, 1.69 and 1.78 against the 1.5, 1.67 and 1.8
	 * that 2, 3, 5 and 9 estimates predict, and 0.304, 0.309,
	 * 0.314 and 0.310ms an estimate.  So one estimate is 0.309ms
	 * here, and the datasheet's own numbers came back out of the
	 * board.
	 */
	  Agccfg0init	= 0xcf,
	Ragcgainadjust	= 0x19,		/* the RSSI offset */
	Rpktcfg2	= 0x26,
	  Fmtnormal	= 0x04,		/* CCA_MODE 001, PKT_FORMAT 00 */
	  Fmtrandom	= 0x06,		/* PKT_FORMAT 10: random data, TX only */
	  Fmttransparent = 0x07,	/* PKT_FORMAT 11: the bits, on a pin */
	Rpktcfg0	= 0x28,
	  Lenfixed	= 0x00,		/* PKT_CFG0.LENGTH_CONFIG = 00 */
	  Leninfinite	= 0x40,		/* PKT_CFG0.LENGTH_CONFIG = 10 */
	  Lenvariable	= 0x20,		/* PKT_CFG0.LENGTH_CONFIG = 01 */
	Rrfendcfg1	= 0x29,
	Rrfendcfg0	= 0x2a,
	Rpktlen		= 0x2e,

	/* the extended space, reached through 0x2f */
	Rext		= 0x2f,
	Xifmixcfg	= 0x00,
	Xfreqoffcfg	= 0x01,
	Xfreq2		= 0x0c,
	Xfreq1		= 0x0d,
	Xfreq0		= 0x0e,
	Xfsdig1		= 0x12,
	Xfsdig0		= 0x13,
	Xfscal0		= 0x17,
	Xfsdivtwo	= 0x19,
	Xfsdsm0		= 0x1b,
	Xfsdvc0		= 0x1d,
	Xfspfd		= 0x1f,
	Xfspre		= 0x20,
	Xfsregdivcml	= 0x21,
	Xfsspare	= 0x22,
	Xxosc5		= 0x32,
	Xxosc3		= 0x34,
	Xxosc1		= 0x36,
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
	Gserialrx	= 0x09,		/* the demodulated bit stream */
	Gcarriersense	= 0x11,		/* swept for; see gsweep */
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
	Probemargin	= 6,		/* dB over the measured floor */
	/*
	 * How many runs a "capture" keeps.  512 shorts of bss,
	 * because the kernel stack here is 4096 bytes in total
	 * and a ctl write already has a shell and a device
	 * underneath it.
	 */
	Ncaprun		= 256,
	Nholdstep	= 64,		/* steps a "hold" sweep may have */
	Nhbin		= 24,		/* powers of two a "ghist" counts to */
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
 * The register settings a CC1120 needs before it is a radio.
 *
 * Taken from TI's own cc112x_easy_link_reg_config.h for 868.000000MHz
 * 2-FSK, in SWRC253 -- the export SmartRF Studio produces and the one
 * every TI example for this part begins with.  They are not
 * optimisations.  SWRU295E 9.16 says "one should always use SmartRF
 * Studio to get the correct settings for a specific frequency before
 * doing a calibration", and a dozen fields in this part's register map
 * carry the words "For test purposes only, use values from SmartRF
 * Studio" against their reset values.
 *
 * What running without them looks like, measured on a clicker 2 with a
 * ccRF click and a Pulse W3312 on it, against a tinySA:
 *
 *	the synthesiser reports locked, FSCAL_CTRL.LOCK = 1
 *	FREQ reads 6c 80 00, which is 868.000000MHz exactly
 *	PA_CFG2 reads 0x7f, which is +14dBm
 *	and the only thing on the air is 755.902MHz at -31dBm,
 *	48dB over the floor, in the same bin whether the part is
 *	told 868, 902 or 830, with the broadband floor 11dB up
 *
 * An output that does not move when the frequency register does is not
 * coming through the transmit chain.  Sixteen of the registers below
 * -- FS_DIG1 and FS_DIG0, FS_CAL0, FS_DIVTWO, FS_DSM0, FS_DVC0,
 * FS_PFD, FS_PRE, FS_REG_DIV_CML, FS_SPARE, XOSC5, XOSC3, XOSC1,
 * PA_CFG1 and PA_CFG0 -- are the synthesiser's and the amplifier's
 * analogue settings, and this driver had never written one of them.
 *
 * Four entries are deliberately left out of this table and written
 * afterwards, because this board wants something else: IOCFG3, which
 * TI parks and the click wires to an interrupt; PKT_LEN, which is this
 * driver's payload maximum rather than 255; and AGC_CS_THR with
 * AGC_GAIN_ADJUST, which carry the RSSI offset and carrier sense
 * threshold worked out for this board.
 */

static const uchar cc1120cfg[] = {
	Riocfg2,	0x06,
	Riocfg1,	0xb0,
	Riocfg0,	0xb0,
	Rsynccfg1,	0x0b,
	Rdcfiltcfg,	0x1c,
	Riqic,		0xc6,
	Rchanbw,	0x08,
	Rmdmcfg0,	0x05,
	Ragcref,	0x20,
	Ragccfg1,	0xa9,
	Ragccfg0,	0xcf,
	Rfifocfg,	0x00,
	Rsettlingcfg,	0x03,
	Rfscfg,		0x12,
	Rpktcfg1,	0x05,
	Rpktcfg0,	Lenvariable,
	Rpacfg2,	0x4f,
	Rpacfg1,	0x56,
	Rpacfg0,	0x1c,
};

static const uchar cc1120cfgx[] = {
	Xifmixcfg,	0x00,
	Xfreqoffcfg,	0x22,
	Xfsdig1,	0x00,
	Xfsdig0,	0x5f,
	Xfscal0,	0x0e,
	Xfsdivtwo,	0x03,
	Xfsdsm0,	0x33,
	Xfsdvc0,	0x17,
	Xfspfd,		0x50,
	Xfspre,		0x6e,
	Xfsregdivcml,	0x14,
	Xfsspare,	0xac,
	Xxosc5,		0x0e,
	Xxosc3,		0xc7,
	Xxosc1,		0x07,
};

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
/*
 * The bands this part has, and the LO divider each one uses.  The VCO
 * runs at the RF times the divider and covers about 3.2 to 3.9GHz;
 * everything outside these ranges is a frequency the synthesiser
 * cannot make, whatever is written to FREQ.
 *
 * setfreq() used to write FREQ and leave FS_CFG alone, so a board
 * asked for 434MHz kept the divider of 4 that 868 needs, asked the
 * VCO for 1736MHz, and said nothing about it.  A radio that tunes
 * somewhere other than where it was told is worse than one that
 * refuses.
 */
static struct {
	uvlong	lo;
	uvlong	hi;
	int	sel;			/* FS_CFG.FSD_BANDSELECT */
	int	div;
} ccbands[] = {
	{ 820000000ULL, 960000000ULL, 0x2,  4 },
	{ 410000000ULL, 480000000ULL, 0x4,  8 },
	{ 273300000ULL, 320000000ULL, 0x6, 12 },
	{ 205000000ULL, 240000000ULL, 0x8, 16 },
	{ 164000000ULL, 192000000ULL, 0xa, 20 },
	{ 136700000ULL, 160000000ULL, 0xb, 24 },
};

/*
 * Frequency deviation, in hertz, from the part's own registers:
 *
 *	fdev = (256 + DEV_M) * 2^DEV_E * fxosc / 2^24
 *
 * Checked against an instrument rather than taken from a note.  With
 * what TI's table leaves -- DEVIATION_M 0x06, DEV_E 3 -- this says
 * 3998Hz, so a 2-FSK carrier should show two tones 7996Hz apart; on a
 * tinySA, with the board transmitting random data at 915MHz, they are
 * 8.20kHz apart.  Two and a half per cent, which is the instrument's
 * bin and the crystal, not the formula.
 */
static ulong
readdev(Cc1120 *rr)
{
	uvlong x;

	x = (uvlong)(256 + rd(rr, Rdeviationm)) << (rd(rr, Rmodcfgdeve) & 7);
	return (ulong)((x * Fxosc) >> 24);
}

/*
 * Receive filter bandwidth, in hertz:
 *
 *	bw = fxosc / (decfact * DEC_M * 8)
 *
 * with decfact 20 or 32 by CHAN_BW's top two bits and DEC_M in the
 * bottom six.  What the table leaves is 0x08, which is 20 and 8, and
 * 32MHz/(20*8*8) is 25kHz -- the figure TI publishes for this
 * configuration, which is the check.
 */
static ulong
readbw(Cc1120 *rr)
{
	int v, d;

	v = rd(rr, Rchanbw);
	d = (v >> 6) == 0? 20: 32;
	v &= 0x3f;
	if(v == 0)
		v = 1;
	return Fxosc / (d * v * 8);
}

/*
 * The symbol rate the part is actually set to, from its own
 * registers, by SWRU295E's formula:
 *
 *	R = (2^20 + DRATE_M) * 2^DRATE_E * fxosc / 2^39
 *
 * Read rather than remembered.  What is in these registers at boot is
 * TI's easy-link table and not anything this driver chose, and a
 * driver that reports the rate it meant to set is the same mistake as
 * one that reports the register it meant to write.
 */
static ulong
readrate(Cc1120 *rr)
{
	uvlong x;
	int e;

	e = rd(rr, Rdrate2);
	x = ((uvlong)(e & 0xf) << 16) | (rd(rr, Rdrate1) << 8) | rd(rr, Rdrate0);
	e >>= 4;
	x = ((x + (1UL<<20)) << e);
	/* rounded, not truncated: 38400 set reads back 38399 otherwise */
	return (ulong)(((x * Fxosc) + (1ULL<<38)) >> 39);
}

static int
setfreq(Cc1120 *rr, uvlong hz)
{
	u32 v;
	int i, fscfg;

	for(i = 0; i < nelem(ccbands); i++)
		if(hz >= ccbands[i].lo && hz <= ccbands[i].hi)
			break;
	if(i >= nelem(ccbands))
		return -1;
	fscfg = (rd(rr, Rfscfg) & ~0xf) | ccbands[i].sel;
	wr(rr, Rfscfg, fscfg);
	v = (u32)((hz * ccbands[i].div * 65536) / 32000000);
	rr->hz = hz;
	strobe(rr, Sidle);
	wrx(rr, Xfreq2, (v>>16) & 0xff);
	wrx(rr, Xfreq1, (v>>8) & 0xff);
	wrx(rr, Xfreq0, v & 0xff);
	strobe(rr, Scal);
	strobe(rr, Srx);
	return 0;
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
	/*
	 * Eight, not five.  tokenize() stops at the size of this array
	 * and drops the rest without saying so, so a verb with five
	 * arguments silently got four and used a default for the
	 * fifth -- which is a hard thing to see when the default is
	 * reasonable.
	 */
	char *f[8], cbuf[64];
	uvlong hz;
	int nf, i;

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
			i = setfreq(rr, hz);
			s->unlock(s);
			if(i < 0){
				print("scan %lud noband\n", (ulong)hz);
				continue;
			}
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
	if(strcmp(f[0], "serial") == 0 && nf == 2){
		/*
		 * Put the demodulated bit stream on the pin, or take it
		 * off again.
		 *
		 * Everything else this driver can measure is the
		 * receiver's own opinion of the air: an RSSI, a carrier
		 * sense, a packet that did or did not pass a sync word
		 * and a CRC.  Every one of them has a threshold or a
		 * comparison in it, and this session spent three
		 * separate measurements discovering that what looked
		 * like structure on the air was the quantisation of the
		 * instrument -- 2.8ms because that is nine RSSI
		 * estimates, 1343us because that is two resolution
		 * cells, 9.94us because that is the sampling grid.
		 *
		 * PKT_CFG2.PKT_FORMAT = 11 is transparent serial mode,
		 * where the packet engine is out of the path entirely
		 * and the slicer's output goes straight to a GPIO.  No
		 * sync word has to match and no CRC has to check, so a
		 * transmission this radio cannot decode is still a
		 * transmission it can measure -- and a run length is a
		 * symbol period, which is a property of what is
		 * transmitting rather than of what is listening.
		 *
		 * That is what makes "ghist" worth pointing at it.  A
		 * preamble is an alternating pattern at the symbol rate,
		 * so it arrives as a pile of runs all one length: 833us
		 * is 1200 symbols a second, 625us is 1600 and 1953us is
		 * 512.  Noise has no such pile.
		 *
		 *	serial on		bits on GPIO3
		 *	serial off		back to packets
		 *
		 * The receiver is left in RX either way, because a mode
		 * that has to be followed by a strobe to be useful is a
		 * mode half the callers will get wrong.
		 *
		 * NOT DEMONSTRATED ON SILICON, and what was tried.
		 *
		 * Both registers the mode needs are set and read back off
		 * the part: PKT_CFG2 0x07, which is CCA_MODE 001 and
		 * PKT_FORMAT 11, and MDMCFG0 0x0d, which has
		 * TRANSPARENT_MODE_EN.  GPIO3 does not move.  Over half a
		 * second and 405000 samples at 1.23us it stays at one
		 * level, at every one of the four TRANSPARENT_INTFACT
		 * settings, and with SERIAL_CLK configured on IOCFG2, and
		 * again with SERIAL_CLK on IOCFG1 and SERIAL_RX on IOCFG0
		 * as well, in case the interface needs more than one pin
		 * before it runs at all.
		 *
		 * The control that makes that mean something is the
		 * sweep.  All sixty-four IOCFG3 selections, with the mode
		 * off and with it on: exactly three move either way, and
		 * they move the same amount both times \- 0x28 at 353 and
		 * 239 runs, 0x2e at 3011 and 4350, 0x31 at 38424 and
		 * 38375.  So the instrument works, and the mode changes
		 * nothing observable.
		 *
		 * Nor is one of those three the bit stream.  0x2e and
		 * 0x31 run in ones and twos of a 1.3us sample and are
		 * identical at 1200 and at 4800 symbols a second, which
		 * is a clock and not data.  0x28 pulses high for one
		 * sample with gaps from 32 to 2048, and its gaps do move
		 * with the symbol rate \- but upward as the rate rises,
		 * which is not what a symbol period does.
		 *
		 * One thing this board cannot rule out: it wires one of
		 * the part's four GPIOs, GPIO3 to PE14.  A mode that
		 * delivers on another pin would look exactly like this.
		 */
		s->lock(s);
		strobe(rr, Sidle);
		for(i = 0; i < Idlewaitus; i++)
			if(state(rr) == Stidle)
				break;
		if(strcmp(f[1], "on") == 0){
			rr->serial = 1;
			wr(rr, Rpktcfg2, Fmttransparent);
			/*
			 * PKT_FORMAT alone is not the mode.
			 *
			 * Setting PKT_CFG2 to 0x07 and IOCFG3 to 0x09 and
			 * reading both back off the part gave a pin that
			 * did not move at all, over two seconds and 1.6
			 * million samples, on a channel where a survey
			 * had found a carrier.  The registers were right
			 * and the mode was not on: MDMCFG0 carries
			 * TRANSPARENT_MODE_EN, TI's table leaves it
			 * clear, and until it is set the demodulator's
			 * output does not reach a GPIO however PKT_FORMAT
			 * is programmed.
			 */
			wr(rr, Rmdmcfg0, rd(rr, Rmdmcfg0) | Transparenten);
			wr(rr, Riocfg3, Gserialrx);
		}else if(strcmp(f[1], "off") == 0){
			rr->serial = 0;
			wr(rr, Rpktcfg2, Fmtnormal);
			wr(rr, Rmdmcfg0, rd(rr, Rmdmcfg0) & ~Transparenten);
			wr(rr, Riocfg3, Gcarriersense);
		}else{
			s->unlock(s);
			error(Ebadctl);
		}
		strobe(rr, Sfrx);
		strobe(rr, Srx);
		s->unlock(s);
		return n;
	}
	if(strcmp(f[0], "carrier") == 0 && nf == 2){
		/*
		 * Transmit continuously, or stop.
		 *
		 * PKT_CFG2.PKT_FORMAT = 10 is the part's random mode: in
		 * TX it modulates pseudo-random data for as long as it
		 * is in TX and never looks at the FIFO, so there is
		 * nothing to run out of and nothing to underflow.  That
		 * makes it the one test that separates "this driver
		 * cannot build a packet" from "nothing leaves this
		 * chip": a carrier either appears on an instrument or it
		 * does not, and no part of the packet engine is involved
		 * in the answer.
		 *
		 * It occupies the channel for as long as it is left on,
		 * which is why it is a command and not a mode anything
		 * enters by itself.
		 */
		s->lock(s);
		if(strcmp(f[1], "on") == 0){
			strobe(rr, Sidle);
			for(i = 0; i < Idlewaitus; i++)
				if(state(rr) == Stidle)
					break;
			/*
			 * Infinite packet length as well as random
			 * data.  Random mode still ends the packet
			 * when the length is reached -- the first
			 * attempt put one byte in the FIFO, the part
			 * read 0x55 as a length of 85, transmitted for
			 * the 567ms that is at 1200 baud and went back
			 * to IDLE before an instrument was pointed at
			 * it.  A carrier that stops before it can be
			 * looked at answers nothing.
			 */
			wr(rr, Rpktcfg0, Leninfinite);
			wr(rr, Rpktcfg2, Fmtrandom);
			/*
			 * "Set TXLAST != TXFIRST before strobing STX"
			 * (SWRU295E, PKT_CFG2.PKT_FORMAT): the random
			 * generator feeds the modulator, but the part
			 * still wants the FIFO to be non-empty before
			 * it will leave IDLE.  One byte is enough and
			 * none of it goes on the air.
			 */
			strobe(rr, Sftx);
			s->select(s, 1);
			s->byte(s, Rfifo | Hburst);
			s->byte(s, 0x55);
			s->select(s, 0);
			strobe(rr, Stx);
		}else if(strcmp(f[1], "off") == 0){
			strobe(rr, Sidle);
			for(i = 0; i < Idlewaitus; i++)
				if(state(rr) == Stidle)
					break;
			wr(rr, Rpktcfg2, Fmtnormal);
			wr(rr, Rpktcfg0, rr->fixedlen? Lenfixed: Lenvariable);
			strobe(rr, Sfrx);
			strobe(rr, Sftx);
			strobe(rr, Srx);
		}else{
			s->unlock(s);
			error(Ebadctl);
		}
		i = state(rr) >> 4;
		s->unlock(s);
		print("carrier %s state %d\n", f[1], i);
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
		 * Which band, and so which divider, setfreq() picks from
		 * the frequency itself.  It refuses one the synthesiser
		 * cannot make, and that refusal arrives here rather
		 * than being swallowed.
		 *
		 * The part reaches six bands; a ccRF 2 click is matched
		 * for 868 to 928 and will radiate poorly outside it,
		 * which is a property of the board and not of the chip,
		 * so it is not enforced here.
		 */
		hz = strtoul(f[1], nil, 0);
		s->lock(s);
		i = setfreq(rr, hz);
		s->unlock(s);
		if(i < 0)
			error("radio: no band for that frequency");
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
	if(strcmp(f[0], "capture") == 0){
		/*
		 * Record the envelope, as run lengths.
		 *
		 * dwell1() above samples once a millisecond and keeps
		 * the peak, the mean and the floor, which says how loud
		 * a frequency is and nothing about when.  Everything on
		 * this air is bursts -- tools/tinysa/survey.py puts the
		 * duty cycle of the busiest thing in the 868 band at
		 * about a sixth -- and the shape of a burst in time is
		 * the first thing about an unknown transmitter that can
		 * be read without knowing its modulation.  An on-off
		 * keyed remote is its envelope, and even for an FSK
		 * burst the envelope gives the packet length and the
		 * gap between packets.
		 *
		 * So: sample RSSI as fast as the bus allows, compare
		 * against a threshold, and print how long each run above
		 * and below it lasted.
		 *
		 * AND THE BUS IS IN THE MEASUREMENT.  Polling this way
		 * desensitises the part it is polling.  Measured at
		 * 893MHz, where nothing is transmitting and "watch"
		 * reports a floor of -118dBm and a mean of -115: a
		 * capture at 27us a sample crosses -106 after 124
		 * samples, about 3.3ms, and stays above it for the rest
		 * of the run.  Same kernel, same bus clock, same
		 * frequency -- what differs is that watch samples once a
		 * millisecond and this samples continuously, so it is
		 * the duty of the SPI and not its speed.  The 3.3ms is
		 * the AGC settling to the new noise.
		 *
		 * So a capture reads about 15 to 20dB hot and its floor
		 * is this loop.  It still shows structure that is real
		 * -- at 881MHz it crosses a threshold that it never
		 * crosses at 893, which is the control -- but the levels
		 * are not the levels, and a threshold has to be chosen
		 * against a capture of a quiet frequency rather than
		 * against what watch says.
		 *
		 * The way out is not a faster bus: it is not to use the
		 * bus.  This part can put its demodulated data or its
		 * carrier sense on a GPIO, and GPIO3 is already wired to
		 * this board's interrupt pin, so the envelope can be
		 * read with no SPI traffic at all and at the resolution
		 * of a timer rather than of a register read.  That is
		 * the next piece of work and it is why this one is
		 * called a bench verb.  The sample rate is measured over
		 * the capture and printed rather than assumed, because
		 * it is a property of the SPI clock and the loop and not
		 * a number this can know.
		 *
		 *	capture 200		200ms at the carrier
		 *				sense threshold
		 *	capture 200 -95		and at -95dBm
		 */
		static ushort runs[Ncaprun];	/* bss, not the 4K kstack */
		uvlong t0, t1, tickhz;
		ulong ms, us;
		int thresh, above, cur, nrun, nsamp, nvalid;
		int r0, r1, first;

		ms = 200;
		thresh = rr->csthr;
		if(nf >= 2)
			ms = strtoul(f[1], nil, 0);
		if(nf >= 3)
			thresh = atoi(f[2]);
		if(ms < 1 || ms > 2000)
			error(Ebadctl);

		/*
		 * AGC_CFG0 is left alone.
		 *
		 * This used to put RSSI_VALID_CNT back to its reset
		 * value for the duration, reasoning that nine estimates
		 * is a moving average and a capture is trying to see
		 * through it.  The reasoning was right and the way it
		 * was done was wrong: it wrote AGC_CFG0 while the part
		 * was receiving, which leaves the AGC somewhere the
		 * RSSI does not come back from, and the first capture
		 * on silicon reported every sample of 200ms above
		 * -85dBm while watch on the same frequency said the
		 * peak was -101.
		 *
		 * The register is fine; it has to be written from IDLE.
		 * Doing that here would mean taking the part out of
		 * receive to watch it receive, so the verb leaves it
		 * alone and the ctl file can set it beforehand:
		 *
		 *	idle
		 *	reg 0x1d 0xc3
		 *	freq 881000000
		 *	gcapture 500 0x11
		 */
		nrun = nsamp = nvalid = 0;
		cur = -1;
		t0 = fastticks(&tickhz);
		t1 = t0 + (tickhz/1000) * ms;
		while(fastticks(nil) < t1){
			s->lock(s);
			r0 = rdx(rr, Xrssi0);
			r1 = (schar)rdx(rr, Xrssi1);
			s->unlock(s);
			nsamp++;
			if((r0 & Rssivalid) == 0)
				continue;
			nvalid++;
			above = r1 > thresh;
			if(cur < 0){
				cur = above;
				runs[0] = 1;
				nrun = 1;
				continue;
			}
			if(above != cur){
				if(nrun >= Ncaprun)
					break;
				cur = above;
				runs[nrun++] = 1;
			}else if(runs[nrun-1] < 0xffff)
				runs[nrun-1]++;
		}
		us = (ulong)(((fastticks(nil) - t0) * 1000000) / tickhz);

		if(nvalid == 0){
			print("capture %lud invalid\n", (ulong)rr->hz);
			return n;
		}
		/*
		 * The run lengths are in samples.  One sample is
		 * us/nsamp microseconds, which is printed with them so
		 * the numbers can be turned into time without knowing
		 * anything about this board's SPI.
		 */
		/*
		 * Runs alternate, so the first one's polarity follows
		 * from the last one's and how many there were.
		 */
		first = cur ^ ((nrun - 1) & 1);
		print("capture %lud thresh %d us %lud samples %d valid %d "
			"runs %d first %s\n", (ulong)rr->hz, thresh, us,
			nsamp, nvalid, nrun, first? "high": "low");
		for(i = 0; i < nrun; i++){
			print(" %ud", runs[i]);
			if((i % 16) == 15)
				print("\n");
		}
		if((nrun % 16) != 0)
			print("\n");
		return n;
	}
	if(strcmp(f[0], "gcapture") == 0){
		/*
		 * The same envelope, off the part's own pin.
		 *
		 * "capture" above polls RSSI over the SPI, and the bus
		 * traffic is in the measurement: at 893MHz, where
		 * nothing transmits, a continuous capture raises the
		 * part's own floor 15 to 20dB in about three
		 * milliseconds.  That is not a thing a faster bus fixes.
		 *
		 * This part will drive one of its GPIO pins with
		 * something it knows -- carrier sense, the demodulated
		 * bit stream, a packet boundary -- and this board wires
		 * GPIO3 to PE14.  Reading a port register is no bus
		 * traffic at all, so the receiver is not listening to
		 * its own controller, and the sample period is a memory
		 * read rather than six bytes at the SPI clock.
		 *
		 *	gcapture 200 0x11	set IOCFG3 to 0x11 for
		 *				the run and sample the pin
		 *	gcapture 200		sample it as it is
		 *
		 * The selection number is an argument because which
		 * value of IOCFG3 is which signal was a question for
		 * the bench rather than for this file.  Answered, by
		 * sweeping it:
		 *
		 * 0x11 is the carrier sense.  It is the only selection
		 * of the thirty tried that follows the air rather than
		 * sitting still -- static low over 200ms at 893MHz,
		 * where nothing transmits, on every run, and toggling
		 * at 881MHz, where something does -- and it moves with
		 * AGC_CS_THR exactly as a threshold should: at a csthr
		 * of -112, which is under the noise, it toggles at both
		 * frequencies; at -105, which is between the two
		 * floors, it separates them.
		 *
		 * 0x0c, 0x0d, 0x0f and 0x10 read high at both, so they
		 * are status that is simply always true.  0x00 to 0x0b
		 * read low at both: FIFO and packet signals, which is
		 * right, since nothing here is receiving packets.
		 *
		 * The read path was checked before any of that was
		 * believed, using the part rather than reasoning: bit 6
		 * of IOCFG inverts the output, and 0x06 reads low while
		 * 0x46 reads high, so the pin and the register both
		 * work and a selection that does not move is a
		 * selection that is not asserting.
		 *
		 * Whatever is passed is restored afterwards, so the
		 * packet interrupt still works after a run.
		 */
		static ushort gruns[Ncaprun];
		uvlong t0, t1, tickhz;
		ulong ms, us;
		int above, cur, nrun, nsamp, sel, old, first;

		if(s->gpio == nil)
			error("radio: this board does not wire the part's GPIO");
		ms = 200;
		sel = -1;
		if(nf >= 2)
			ms = strtoul(f[1], nil, 0);
		if(nf >= 3)
			sel = strtoul(f[2], nil, 0);
		if(ms < 1 || ms > 2000 || sel > 0xff)
			error(Ebadctl);

		/*
		 * Masked before the selection is changed, and unmasked
		 * after it is put back.  See gsweep for what a fast pin
		 * does to this board; the order matters as much as the
		 * mask, because the window between writing IOCFG3 and
		 * masking is enough.  The first version of this masked
		 * second and unmasked first and hung the machine on the
		 * one selection it was written to look at.
		 */
		if(s->irq != nil)
			s->irq(s, 0);
		s->lock(s);
		old = rd(rr, Riocfg3);
		if(sel >= 0)
			wr(rr, Riocfg3, sel);
		s->unlock(s);

		nrun = nsamp = 0;
		cur = -1;
		t0 = fastticks(&tickhz);
		t1 = t0 + (tickhz/1000) * ms;
		while(fastticks(nil) < t1){
			above = s->gpio(s);
			nsamp++;
			if(cur < 0){
				cur = above;
				gruns[0] = 1;
				nrun = 1;
				continue;
			}
			if(above != cur){
				if(nrun >= Ncaprun)
					break;
				cur = above;
				gruns[nrun++] = 1;
			}else if(gruns[nrun-1] < 0xffff)
				gruns[nrun-1]++;
		}
		us = (ulong)(((fastticks(nil) - t0) * 1000000) / tickhz);

		s->lock(s);
		wr(rr, Riocfg3, old);
		s->unlock(s);
		if(s->irq != nil)
			s->irq(s, 1);

		first = cur ^ ((nrun - 1) & 1);
		print("gcapture %lud iocfg3 0x%.2x us %lud samples %d "
			"runs %d first %s\n", (ulong)rr->hz,
			sel >= 0? sel: old, us, nsamp, nrun,
			first? "high": "low");
		for(i = 0; i < nrun; i++){
			print(" %ud", gruns[i]);
			if((i % 16) == 15)
				print("\n");
		}
		if((nrun % 16) != 0)
			print("\n");
		return n;
	}
	if(strcmp(f[0], "gsweep") == 0){
		/*
		 * Every GPIO selection, one line each.
		 *
		 * Finding which value of IOCFG3 carries which signal is
		 * a sweep, and done a command at a time over a console
		 * that types at five milliseconds a character it is
		 * sixty round trips and five minutes.  The part can do
		 * it in a third of a second.  That is the difference
		 * between asking the question once and asking it
		 * whenever the answer might have changed -- and it does
		 * change, because most of these signals only assert in
		 * a particular packet format or receive state, which is
		 * exactly what makes a table in a datasheet hard to use
		 * and a sweep easy.
		 *
		 * "runs" is how many times the pin changed in the
		 * window: 1 is a pin sitting still, and the interesting
		 * ones are everything else.
		 */
		ulong ms;
		int sel, oldsel, cur, v, nrun, nsamp;
		uvlong t0, t1, tickhz;

		if(s->gpio == nil)
			error("radio: this board does not wire the part's GPIO");
		ms = 5;
		if(nf >= 2)
			ms = strtoul(f[1], nil, 0);
		if(ms < 1 || ms > 200)
			error(Ebadctl);

		s->lock(s);
		oldsel = rd(rr, Riocfg3);
		s->unlock(s);
		/*
		 * With the interrupt masked for the whole sweep.
		 *
		 * This board takes a rising edge on the pin as "a
		 * packet happened", and some of the selections below
		 * change fast.  Without the mask the sweep reached
		 * 0x27, printed that line, and the machine stopped: no
		 * prompt, no echo, nothing, because every instruction
		 * it might have run was an interrupt handler for a
		 * signal that was never a packet.  Not recoverable by
		 * ^R^R either, that being a keystroke and there being
		 * no room left to service the uart.  It cost the reset
		 * button, which is the one thing this tree has spent
		 * the day removing from the loop.
		 */
		if(s->irq != nil)
			s->irq(s, 0);
		for(sel = 0; sel < 0x40; sel++){
			s->lock(s);
			wr(rr, Riocfg3, sel);
			s->unlock(s);
			nrun = 1;
			nsamp = 0;
			cur = -1;
			t0 = fastticks(&tickhz);
			t1 = t0 + (tickhz/1000) * ms;
			while(fastticks(nil) < t1){
				v = s->gpio(s);
				nsamp++;
				if(cur < 0)
					cur = v;
				else if(v != cur){
					cur = v;
					nrun++;
				}
			}
			print("gsweep 0x%.2x runs %d samples %d now %s\n",
				sel, nrun, nsamp, cur? "high": "low");
		}
		s->lock(s);
		wr(rr, Riocfg3, oldsel);
		s->unlock(s);
		if(s->irq != nil)
			s->irq(s, 1);
		return n;
	}
	if(strcmp(f[0], "rate") == 0 && nf == 2){
		/*
		 * The symbol rate, in symbols a second.
		 *
		 * SWRU295E gives it as
		 *
		 *	R = (2^20 + DRATE_M) * 2^DRATE_E * fxosc / 2^39
		 *
		 * with DRATE_M twenty bits across DRATE2[3:0], DRATE1
		 * and DRATE0, and DRATE_E four bits in DRATE2[7:4].
		 * Inverting it: X = R * 2^39 / fxosc, then the exponent
		 * is whatever shift brings X into [2^20, 2^21) and the
		 * mantissa is what is left over.
		 *
		 * This driver has never written these registers.  What
		 * is in them is TI's easy-link table, which reads back
		 * as exactly 1200 symbols a second -- a demonstration
		 * value, not a choice, and the first thing that has to
		 * match a transmitter somebody else built.  A radio
		 * whose data rate is whatever the example used is not a
		 * radio that can be pointed at anything.
		 *
		 * Written from IDLE.  AGC_CFG0 taught that lesson
		 * expensively, and the modem registers are the same
		 * kind of thing; setfreq() below puts it back in RX.
		 */
		uvlong x;
		ulong sym;
		int e;

		sym = strtoul(f[1], nil, 0);
		if(sym < 10 || sym > 250000)
			error("radio: outside this part's symbol rates");
		x = ((uvlong)sym << 39) / Fxosc;
		for(e = 0; e < 16; e++)
			if((x >> e) < (1UL<<21))
				break;
		if(e >= 16 || (x >> e) < (1UL<<20))
			error("radio: no exponent fits that rate");
		x = (x >> e) - (1UL<<20);
		s->lock(s);
		strobe(rr, Sidle);
		for(i = 0; i < Idlewaitus; i++)
			if(state(rr) == Stidle)
				break;
		wr(rr, Rdrate2, (e<<4) | ((x>>16) & 0xf));
		wr(rr, Rdrate1, (x>>8) & 0xff);
		wr(rr, Rdrate0, x & 0xff);
		s->unlock(s);
		setfreq(rr, rr->hz);		/* recalibrate and listen */
		rr->symrate = sym;
		return n;
	}
	if(strcmp(f[0], "probe") == 0 && nf >= 2){
		/*
		 * Characterise one channel, in one command.
		 *
		 * The division of labour this ends up in: a tinySA
		 * sweeps a band and says where something is, and this
		 * says what it is doing there.  The instrument is better
		 * at finding -- it looks at 450 places at once and this
		 * looks at one -- and this is better at watching, by two
		 * orders of magnitude: 1.37us a sample against 111 at
		 * the instrument's fastest sweep, a receive filter that
		 * is a channel wide rather than a sweep bin, and no
		 * 450-point limit on how long it can look.
		 *
		 * One command because the console is the expensive
		 * part.  Typing at five milliseconds a character, a
		 * frequency's worth of tune, threshold, capture and
		 * read is half a minute of round trips and a tenth of a
		 * second of measurement, so the loop belongs here.
		 *
		 *	probe 881000000		200ms, threshold picked
		 *	probe 881000000 500	from the noise it finds
		 *
		 * Two passes.  The first samples RSSI a millisecond
		 * apart -- slowly, because sampling continuously over
		 * the bus raises this part's own floor 15 to 20dB --
		 * and takes the floor and the peak.  The second sets
		 * carrier sense a little over that floor and watches
		 * the pin, which costs no bus traffic at all.
		 */
		uvlong t0, t1, tickhz;
		ulong ms, us, hi, lo, nb, nsamp, nsper;
		ulong run, bmin, bmax, gmin, gmax;
		int floor, peak, r0, r1, thr, oldthr, oldsel;
		int cur, first, weak;

		if(s->gpio == nil)
			error("radio: this board does not wire the part's GPIO");
		hz = strtoul(f[1], nil, 0);
		ms = nf >= 3? strtoul(f[2], nil, 0): 200;
		if(ms < 10 || ms > 2000)
			error(Ebadctl);
		/*
		 * AGC_CFG0 is not touched, and this is a retreat.
		 *
		 * Dropping RSSI_VALID_CNT to two estimates takes the
		 * finest event this can see from 2.8ms to 0.62ms, which
		 * is worth having, and at 868MHz it worked.  Outside
		 * that band it does not: the first measurement at
		 * 446MHz came back with a floor of -128, which is the
		 * part's "not valid" value, and the next with a peak of
		 * +127, which is 0x7f and not a level -- while watch,
		 * which never writes this register, read the same
		 * frequency as a clean -123dBm floor in the same minute.
		 * Writing it after the tune rather than before did not
		 * help.
		 *
		 * That is the third time this register has produced
		 * nonsense here, and a measurement that silently reports
		 * +127dBm is worse than one with a coarse floor.  So
		 * this leaves it alone, and the shortest event it
		 * resolves is however many RSSI updates AGC_CFG0
		 * happens to be set to.  Set it by hand, from IDLE, if
		 * the finer floor is wanted:
		 *
		 *	idle
		 *	reg 0x1d 0xc3
		 *	freq 868000000
		 *	probe 868000000 2000
		 */
		s->lock(s);
		i = setfreq(rr, hz);
		s->unlock(s);
		if(i < 0)
			error("radio: outside this part's bands");

		/*
		 * What the channel sounds like before anything is
		 * decided, over a quarter of the asked-for time rather
		 * than a fixed forty milliseconds.  These signals come
		 * and go: a fixed short look at 881MHz gave a floor of
		 * -111 and a peak of -92 once and -118 and -102 a
		 * minute later, which moves any threshold derived from
		 * it by seven decibels.
		 *
		 * A millisecond apart, not continuously.  Polling RSSI
		 * over the bus as fast as it will go raises this part's
		 * own floor 15 to 20dB -- measured -- so the pass that
		 * decides the threshold has to be the slow kind.
		 */
		floor = 127;
		peak = -128;
		for(i = 0; i < ms/4; i++){
			s->lock(s);
			r0 = rdx(rr, Xrssi0);
			r1 = (schar)rdx(rr, Xrssi1);
			s->unlock(s);
			if(r0 & Rssivalid){
				if(r1 > peak)
					peak = r1;
				if(r1 < floor)
					floor = r1;
			}
			delay(1);
		}
		if(peak == -128){
			print("probe %lud invalid\n", (ulong)hz);
			return n;
		}
		/*
		 * Half way between the floor and the peak, but never
		 * closer to the floor than Probemargin.  A fixed margin
		 * is wrong in both directions: six decibels over a
		 * floor that a real signal is twenty above says the
		 * channel is busy 87% of the time, which is the AGC
		 * breathing and not a transmitter, and a wide fixed
		 * margin finds nothing on a weak one.  With no signal
		 * the peak is near the floor and this falls back to the
		 * margin, which is what keeps it from triggering on
		 * noise.
		 */
		thr = peak - floor > 2*Probemargin?
			floor + (peak - floor)/2: floor + Probemargin;


		s->lock(s);
		oldthr = (schar)rd(rr, Ragccsthr);
		oldsel = rd(rr, Riocfg3);
		wr(rr, Ragccsthr, thr & 0xff);
		s->unlock(s);
		if(s->irq != nil)
			s->irq(s, 0);
		s->lock(s);
		wr(rr, Riocfg3, Gcarriersense);
		s->unlock(s);

		hi = lo = nb = 0;
		bmin = gmin = 0x7fffffff;
		bmax = gmax = 0;
		cur = -1;
		run = 0;
		first = 0;
		t0 = fastticks(&tickhz);
		t1 = t0 + (tickhz/1000) * ms;
		while(fastticks(nil) < t1){
			i = s->gpio(s);
			if(cur < 0){
				cur = i;
				first = i;
				run = 1;
				continue;
			}
			if(i == cur){
				run++;
				continue;
			}
			/* a run ended: account for it */
			if(cur){
				hi += run;
				nb++;
				if(run < bmin)
					bmin = run;
				if(run > bmax)
					bmax = run;
			}else{
				lo += run;
				if(run < gmin)
					gmin = run;
				if(run > gmax)
					gmax = run;
			}
			cur = i;
			run = 1;
		}
		us = (ulong)(((fastticks(nil) - t0) * 1000000) / tickhz);

		s->lock(s);
		wr(rr, Riocfg3, oldsel);
		wr(rr, Ragccsthr, oldthr & 0xff);
		s->unlock(s);
		if(s->irq != nil)
			s->irq(s, 1);

		/*
		 * Run lengths are in samples and the sample period is
		 * measured over the run, so everything is printed in
		 * microseconds and nothing here has to know what this
		 * board's bus does.  The trailing runs are left out of
		 * the extremes on purpose: the first and last are cut
		 * off by the window rather than by the signal.
		 */
		/*
		 * Everything in microseconds, through a sample period
		 * in nanoseconds, and all of it in 32 bits.
		 *
		 * Not because 64-bit division breaks anything.  A
		 * comment here used to say that the obvious way --
		 * (run * us) / samples in 64 bits -- stopped the kernel
		 * booting, and that was wrong: put back, on the part
		 * and under qemu, the kernel boots and runs commands.
		 * What was actually being read was a screen captured
		 * while the conf line was still printing, taken for a
		 * machine that had stopped.  See the note in
		 * doc/radio-plan.ms.
		 *
		 * It stays in 32 bits because it costs nothing to: a
		 * sample here is about 1.4 microseconds and a run is at
		 * most a couple of million of them, so nanoseconds per
		 * sample times a run fits a ulong and calls no helper.
		 */
		nsamp = hi + lo;
		if(nsamp == 0)
			nsamp = 1;
		nsper = (us*1000)/nsamp;
		/*
		 * NOISE when the run has the shape threshold-crossing
		 * noise has rather than the shape transmissions have.
		 *
		 * The first pass only catches a burst if one happens
		 * while it is looking, and on a channel busy a few per
		 * cent of the time it often does not.  The threshold
		 * then sits close enough to the floor that the AGC
		 * breathing across it is counted, and the run reports a
		 * channel busy half the time with hundreds of bursts.
		 * Three runs at 918MHz within a minute gave 89%, 0% and
		 * 0% for that reason alone.
		 *
		 * Comparing peak against floor does not separate them:
		 * the bad runs had 14 and 20dB between the two.  What
		 * does is that noise crossing a line gives a shortest
		 * burst and a shortest gap of the same order -- both
		 * near whatever this receiver can resolve -- in numbers
		 * no transmitter sends.  A real burst train rests
		 * between transmissions, so its shortest gap is far
		 * longer than its shortest burst: 794 against 12953
		 * microseconds on the one run here that repeated.  The
		 * noise runs were 637 against 506, 635 against 579, 631
		 * against 533 and 626 against 627.
		 */
		weak = nb > 20 && gmin < 2*bmin && bmin < 2*gmin;
		print("probe %lud floor %d peak %d thr %d%s us %lud "
			"duty %lud%% bursts %lud", (ulong)hz, floor, peak,
			thr, weak? " NOISE": "", us, (hi*100)/nsamp, nb);
		if(nb > 0)
			print(" burst %lud..%ludus gap %lud..%ludus",
				(bmin*nsper)/1000, (bmax*nsper)/1000,
				gmin == 0x7fffffff? 0UL: (gmin*nsper)/1000,
				(gmax*nsper)/1000);
		print(" first %s\n", first? "high": "low");
		return n;
	}
	if(strcmp(f[0], "deviation") == 0 && nf == 2){
		/*
		 * Inverting the formula in readdev(): x is fdev scaled
		 * by 2^24/fxosc, and the exponent is whatever shift
		 * brings it into [256, 512).
		 *
		 * The 64-bit divide is by a constant on purpose.  A
		 * uvlong divided by a variable is a called helper on
		 * this part, and one of those in a ctl verb that never
		 * ran stopped the kernel booting; see the probe verb.
		 */
		uvlong x;
		ulong want;
		int e;

		want = strtoul(f[1], nil, 0);
		if(want < 100 || want > 200000)
			error("radio: outside this part's deviations");
		x = ((uvlong)want << 24) / Fxosc;
		for(e = 0; e < 8; e++)
			if((x >> e) < 512)
				break;
		if(e >= 8 || (x >> e) < 256)
			error("radio: no exponent fits that deviation");
		s->lock(s);
		strobe(rr, Sidle);
		for(i = 0; i < Idlewaitus; i++)
			if(state(rr) == Stidle)
				break;
		wr(rr, Rdeviationm, (x >> e) - 256);
		wr(rr, Rmodcfgdeve, (rd(rr, Rmodcfgdeve) & ~7) | e);
		s->unlock(s);
		setfreq(rr, rr->hz);
		return n;
	}
	if(strcmp(f[0], "bw") == 0 && nf == 2){
		/* the receive filter, as near as its two factors reach */
		ulong want, dm;
		int d, m, best, bestd, bestm;

		want = strtoul(f[1], nil, 0);
		if(want < 8000 || want > 200000)
			error("radio: outside this part's bandwidths");
		/*
		 * best starts negative and not zero.  Zero is a perfect
		 * match, so a zero sentinel means the first exact hit is
		 * overwritten by the next candidate that comes along:
		 * asking for 100kHz, which 20 and 2 give exactly, got
		 * 125kHz.
		 */
		best = -1;
		bestd = 20;
		bestm = 1;
		for(d = 20; d <= 32; d += 12)
			for(m = 1; m < 64; m++){
				dm = Fxosc / (d * m * 8);
				i = dm > want? dm - want: want - dm;
				if(best < 0 || i < best){
					best = i;
					bestd = d;
					bestm = m;
				}
			}
		s->lock(s);
		strobe(rr, Sidle);
		for(i = 0; i < Idlewaitus; i++)
			if(state(rr) == Stidle)
				break;
		wr(rr, Rchanbw, (bestd == 32? 1<<6: 0) | bestm);
		s->unlock(s);
		setfreq(rr, rr->hz);
		return n;
	}
	if(strcmp(f[0], "sync") == 0 && nf >= 2){
		/*
		 * The sync word, most significant byte on the air
		 * first, and how many of its bits have to match.
		 *
		 *	sync 0x904e 16		802.15.4g's SFD
		 *	sync 0x930b 16		what the table leaves
		 *
		 * SYNC_MODE 2 is sixteen bits and 5 is thirty-two, and
		 * which registers each of them reads is the whole of the
		 * bug this comment used to carry.  SYNC_MODE 5 is
		 * SYNC31_0, so a 32-bit word goes to SYNC3 down to
		 * SYNC0 with SYNC3 on the air first.  SYNC_MODE 2 is
		 * SYNC15_0, which is SYNC1 and SYNC0 -- the other half
		 * of the register file -- and this wrote sixteen bits to
		 * SYNC3 and SYNC2 and set mode 2 anyway.
		 *
		 * So every sixteen-bit sync word this driver was ever
		 * asked for was written where the part was not looking,
		 * and the part went on comparing against whatever
		 * SYNC1:SYNC0 held.  Read off silicon after asking for
		 * 0xaaaa: SYNC3 0xaa, SYNC2 0xaa, SYNC1 0x51, SYNC0
		 * 0xde -- the reset value, which is what it was actually
		 * hunting for.  No packet has ever been received on this
		 * board and this is at least one reason why.
		 *
		 * The qemu model had the same convention and its own
		 * comment said so: that taking SYNC3 and SYNC2 for
		 * sixteen bits was "a convention and not a reading of
		 * the part", and that whether it agreed with silicon
		 * "needs silicon".  It does not agree, and both ends
		 * move together here, since a model and a driver that
		 * are wrong in the same direction pass every test
		 * between them.
		 *
		 * A wrong sync word is the control for any claim made
		 * with a right one: the same configuration listening for
		 * a number nobody sends should find nothing, and if it
		 * finds as much as the real one then what was found was
		 * noise.
		 */
		ulong w;
		int bits, mode;

		w = strtoul(f[1], nil, 0);
		bits = nf >= 3? atoi(f[2]): 16;
		if(bits != 16 && bits != 32)
			error("radio: sync is 16 or 32 bits");
		mode = bits == 16? 2: 5;	/* SYNC_MODE: 16 or 32 bits */
		s->lock(s);
		strobe(rr, Sidle);
		for(i = 0; i < Idlewaitus; i++)
			if(state(rr) == Stidle)
				break;
		if(bits == 16){
			/* SYNC_MODE 2 reads SYNC15_0, which is these two */
			wr(rr, Rsync1, (w>>8) & 0xff);
			wr(rr, Rsync0, w & 0xff);
		}else{
			wr(rr, Rsync3, (w>>24) & 0xff);
			wr(rr, Rsync2, (w>>16) & 0xff);
			wr(rr, Rsync1, (w>>8) & 0xff);
			wr(rr, Rsync0, w & 0xff);
		}
		/*
		 * SYNC_MODE is bits 7:5 and SYNC_THR is 4:0.  Writing
		 * the mode into the low bits sets the threshold
		 * instead and leaves the mode at whatever it was --
		 * which, here, was zero, meaning no sync word at all.
		 */
		wr(rr, Rsynccfg1x, (rd(rr, Rsynccfg1x) & 0x1f) | (mode<<5));
		s->unlock(s);
		setfreq(rr, rr->hz);
		return n;
	}
	if(strcmp(f[0], "hold") == 0 && nf >= 5){
		/*
		 * A sweep that keeps the highest each step ever saw,
		 * over many passes.
		 *
		 * "scan" visits each step once, and for a signal that
		 * is on a few per cent of the time that measures when
		 * the visit happened rather than where the energy is.
		 * Scanning 908.4 to 908.8MHz at 25kHz and half a second
		 * a step gave a peak of -106dBm at 908.600 and -108 at
		 * 908.525, which is not a spectrum, it is seventeen
		 * unrelated half-seconds.  The shape of an intermittent
		 * signal only appears if every step gets enough looks
		 * to catch a burst, so this sweeps the range over and
		 * over and keeps the maximum.
		 *
		 *	hold 908400000 908800000 25000 50 12
		 *
		 * Twelve passes of fifty milliseconds is the same six
		 * hundred milliseconds a step as one pass of six
		 * hundred, spread out over the whole sweep instead of
		 * spent in one place.
		 */
		static schar hold[Nholdstep];
		ulong lo, hi, step, ms, passes, k;
		int nstep, r0, r1, nrun;

		lo = strtoul(f[1], nil, 0);
		hi = strtoul(f[2], nil, 0);
		step = strtoul(f[3], nil, 0);
		ms = strtoul(f[4], nil, 0);
		passes = nf >= 6? strtoul(f[5], nil, 0): 8;
		if(step == 0 || lo > hi || ms < 1 || ms > 1000 ||
		   passes < 1 || passes > 100)
			error(Ebadctl);
		nstep = (hi - lo)/step + 1;
		if(nstep > Nholdstep)
			error("radio: too many steps for one hold");
		for(i = 0; i < nstep; i++)
			hold[i] = -128;

		for(k = 0; k < passes; k++)
			for(i = 0; i < nstep; i++){
				s->lock(s);
				if(setfreq(rr, lo + (ulong)i*step) < 0){
					s->unlock(s);
					continue;
				}
				s->unlock(s);
				for(nrun = 0; nrun < ms; nrun++){
					s->lock(s);
					r0 = rdx(rr, Xrssi0);
					r1 = (schar)rdx(rr, Xrssi1);
					s->unlock(s);
					if((r0 & Rssivalid) && r1 > hold[i])
						hold[i] = r1;
					delay(1);
				}
			}
		s->lock(s);
		setfreq(rr, rr->hz);		/* back where it was */
		s->unlock(s);
		for(i = 0; i < nstep; i++)
			print("hold %lud %d\n", lo + (ulong)i*step, hold[i]);
		return n;
	}
	if(strcmp(f[0], "gread") == 0){
		/*
		 * How much of a window the pin spent high, rather than
		 * how often it changed.
		 *
		 * "ghist" bins completed runs, so a pin that goes high
		 * and stays high for the whole window has no completed
		 * run in it and reads as "static" -- indistinguishable
		 * from a pin that never moved at all.  That is exactly
		 * the case this exists for: PKT_SYNC_RXTX is named for
		 * both directions and asserts from the sync word to the
		 * end of a packet, so during a continuous transmission
		 * it should sit high and ghist would report nothing.
		 *
		 *	gread 200 0x06		how much of 200ms was
		 *				high on PKT_SYNC_RXTX
		 *	gread 200		whatever IOCFG3 is
		 */
		uvlong t0, t1, tickhz;
		ulong ms, us, high;
		int sel, oldsel, nsamp;

		if(s->gpio == nil)
			error("radio: this board does not wire the part's GPIO");
		ms = 200;
		sel = -1;
		if(nf >= 2)
			ms = strtoul(f[1], nil, 0);
		if(nf >= 3)
			sel = strtoul(f[2], nil, 0);
		if(ms < 1 || ms > 5000 || sel > 0xff)
			error(Ebadctl);

		if(s->irq != nil)
			s->irq(s, 0);
		s->lock(s);
		oldsel = rd(rr, Riocfg3);
		if(sel >= 0)
			wr(rr, Riocfg3, sel);
		s->unlock(s);

		high = 0;
		nsamp = 0;
		t0 = fastticks(&tickhz);
		t1 = t0 + (tickhz/1000) * ms;
		while(fastticks(nil) < t1){
			if(s->gpio(s))
				high++;
			nsamp++;
		}
		us = (ulong)(((fastticks(nil) - t0) * 1000000) / tickhz);

		s->lock(s);
		wr(rr, Riocfg3, oldsel);
		s->unlock(s);
		if(s->irq != nil)
			s->irq(s, 1);

		if(nsamp == 0)
			nsamp = 1;
		print("gread %lud iocfg3 0x%.2x us %lud samples %d high %lud "
			"pct %lud\n", (ulong)rr->hz, sel >= 0? sel: oldsel,
			us, nsamp, high, (high*100)/nsamp);
		return n;
	}
	if(strcmp(f[0], "ghist") == 0){
		/*
		 * How long the pin stays high and low, as a histogram
		 * over the whole window.
		 *
		 * "gcapture" keeps the sequence, and its array fills in
		 * about twelve milliseconds on a pin that changes at
		 * twenty kilohertz.  On a channel busy a few per cent of
		 * the time, twelve milliseconds almost never contains a
		 * burst, so the one measurement that is not limited by
		 * the RSSI filter could not be pointed at the channels
		 * worth pointing it at.
		 *
		 * Giving up the order buys the whole window.  Run
		 * lengths go into buckets a power of two apart, high and
		 * low kept separately, and two seconds of pin is a
		 * distribution rather than the first twelve
		 * milliseconds of one.  The order is what a decoder
		 * wants and the distribution is what telling signal from
		 * noise wants, which is the question here.
		 *
		 *	ghist 2000 0x28		the demodulator
		 *	ghist 2000		whatever IOCFG3 is
		 */
		static ulong hbin[2][Nhbin];
		uvlong t0, t1, tickhz;
		ulong ms, us, run;
		int sel, oldsel, cur, v, b, nsamp;

		if(s->gpio == nil)
			error("radio: this board does not wire the part's GPIO");
		ms = 200;
		sel = -1;
		if(nf >= 2)
			ms = strtoul(f[1], nil, 0);
		if(nf >= 3)
			sel = strtoul(f[2], nil, 0);
		if(ms < 1 || ms > 5000 || sel > 0xff)
			error(Ebadctl);
		for(i = 0; i < Nhbin; i++)
			hbin[0][i] = hbin[1][i] = 0;

		if(s->irq != nil)
			s->irq(s, 0);
		s->lock(s);
		oldsel = rd(rr, Riocfg3);
		if(sel >= 0)
			wr(rr, Riocfg3, sel);
		s->unlock(s);

		cur = -1;
		run = 0;
		nsamp = 0;
		t0 = fastticks(&tickhz);
		t1 = t0 + (tickhz/1000) * ms;
		while(fastticks(nil) < t1){
			v = s->gpio(s);
			nsamp++;
			if(cur < 0){
				cur = v;
				run = 1;
				continue;
			}
			if(v == cur){
				run++;
				continue;
			}
			for(b = 0; b < Nhbin-1 && (run >> b) > 1; b++)
				;
			hbin[cur][b]++;
			cur = v;
			run = 1;
		}
		us = (ulong)(((fastticks(nil) - t0) * 1000000) / tickhz);

		s->lock(s);
		wr(rr, Riocfg3, oldsel);
		s->unlock(s);
		if(s->irq != nil)
			s->irq(s, 1);

		if(nsamp == 0)
			nsamp = 1;
		print("ghist %lud iocfg3 0x%.2x us %lud samples %d nsper %lud\n",
			(ulong)rr->hz, sel >= 0? sel: oldsel, us, nsamp,
			(us*1000)/nsamp);
		for(i = 0; i < Nhbin; i++)
			if(hbin[0][i] || hbin[1][i])
				print(" %d: low %lud high %lud\n",
					1<<i, hbin[0][i], hbin[1][i]);
		return n;
	}
	if(strcmp(f[0], "gtrig") == 0 && nf >= 3){
		/*
		 * Wait for a burst, then record the pin through it.
		 *
		 * Neither of the other two can see a signal that is on
		 * five per cent of the time.  "gcapture" keeps the
		 * sequence and fills its array in twelve milliseconds,
		 * which usually contains no burst at all; "ghist" gives
		 * up the sequence to cover the whole window and then
		 * averages the burst away -- 918MHz at five per cent
		 * duty and 926MHz at one came out the same to within a
		 * few per cent, because in both cases the great
		 * majority of what it counted was silence.
		 *
		 * So: watch carrier sense until it asserts, switch the
		 * pin to whatever was asked for, and record from there.
		 * This board brings out one GPIO, so the trigger and the
		 * signal have to share it and the switch costs an SPI
		 * write between them -- twenty microseconds or so, which
		 * is inside a symbol at any rate this part is likely to
		 * be set to, and is the price of a board with one pin.
		 *
		 *	gtrig 2000 0x28		wait up to 2s for a
		 *				burst, then the
		 *				demodulator through it
		 */
		static ushort trun[Ncaprun];
		uvlong t0, t1, tickhz;
		ulong ms, us;
		int sel, oldsel, cur, v, nrun, nsamp, first, armed;

		if(s->gpio == nil)
			error("radio: this board does not wire the part's GPIO");
		ms = strtoul(f[1], nil, 0);
		sel = strtoul(f[2], nil, 0);
		if(ms < 1 || ms > 5000 || sel < 0 || sel > 0xff)
			error(Ebadctl);

		if(s->irq != nil)
			s->irq(s, 0);
		s->lock(s);
		oldsel = rd(rr, Riocfg3);
		wr(rr, Riocfg3, Gcarriersense);
		s->unlock(s);

		armed = 0;
		t0 = fastticks(&tickhz);
		t1 = t0 + (tickhz/1000) * ms;
		while(fastticks(nil) < t1)
			if(s->gpio(s)){
				armed = 1;
				break;
			}
		if(!armed){
			s->lock(s);
			wr(rr, Riocfg3, oldsel);
			s->unlock(s);
			if(s->irq != nil)
				s->irq(s, 1);
			print("gtrig %lud no burst in %ludms\n",
				(ulong)rr->hz, ms);
			return n;
		}
		s->lock(s);
		wr(rr, Riocfg3, sel);
		s->unlock(s);

		nrun = nsamp = 0;
		cur = -1;
		t0 = fastticks(nil);
		/*
		 * Bounded by time as well as by runs, and the missing
		 * bound is what wedged this board over and over.
		 *
		 * This used to be "while(nrun < Ncaprun)" and nothing
		 * else, so it ran until the pin had changed two hundred
		 * and fifty-six times.  Pointed at a selection that does
		 * not assert -- PQT_REACHED, which is exactly what one
		 * wants to watch when asking whether a preamble is ever
		 * detected -- nrun stays at one and the loop never ends.
		 * Interrupts stay on, so the console goes on echoing and
		 * the board looks alive; the shell never comes back, and
		 * everything typed afterwards queues in a console nobody
		 * is reading until the kernel reaches "allocb: no
		 * memory" and only the reset button can help.  Several
		 * trips across the room went on this.
		 *
		 * The same window the caller already gave for the
		 * trigger serves for the capture: it asked to look for
		 * this long, and a pin that never moves is an answer
		 * rather than a reason to wait for ever.
		 */
		t1 = t0 + (tickhz/1000) * ms;
		while(nrun < Ncaprun && fastticks(nil) < t1){
			v = s->gpio(s);
			nsamp++;
			if(cur < 0){
				cur = v;
				first = v;
				trun[0] = 1;
				nrun = 1;
				continue;
			}
			if(v != cur){
				cur = v;
				trun[nrun++] = 1;
			}else if(trun[nrun-1] < 0xffff)
				trun[nrun-1]++;
		}
		us = (ulong)(((fastticks(nil) - t0) * 1000000) / tickhz);

		s->lock(s);
		wr(rr, Riocfg3, oldsel);
		s->unlock(s);
		if(s->irq != nil)
			s->irq(s, 1);

		print("gtrig %lud iocfg3 0x%.2x us %lud samples %d runs %d "
			"first %s\n", (ulong)rr->hz, sel, us, nsamp, nrun,
			first? "high": "low");
		for(i = 0; i < nrun; i++){
			print(" %ud", trun[i]);
			if((i % 16) == 15)
				print("\n");
		}
		if((nrun % 16) != 0)
			print("\n");
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
		"rate %lud\n"
		"deviation %lud bw %lud\n"
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
		(ulong)rr->hz, readrate(rr), readdev(rr), readbw(rr),
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

/*
 * Write a register and say so if the part disagrees.  Returns 1 for a
 * register that did not take, so a caller can count them.
 */
static int
verify(Cc1120 *rr, int addr, int val)
{
	int got;

	got = rd(rr, addr);
	if(got == (val & 0xff))
		return 0;
	print("cc1120: reg 0x%.2x wrote 0x%.2x, reads 0x%.2x\n",
		addr, val & 0xff, got);
	return 1;
}

/*
 * What this part is set to and what it will accept, which #W serves
 * as the ctl file's read.  The bands are the synthesiser's, from
 * ccbands[] above, and are the same list setfreq() refuses a
 * frequency against -- so what the file says and what the driver will
 * accept cannot drift apart.
 *
 * The power range is the PA's: PA_POWER_RAMP 3 to 63 is -16 to
 * +14dBm by the equation in SWRU295E.  A ccRF 2 click is matched for
 * 868 to 928 and will radiate poorly outside it; that is the board's
 * business, not the chip's, so it is not narrowed here.
 */
static int
cc1120caps(Radio *r, char *p, int n)
{
	Cc1120 *rr;
	Spidev *s2;
	char *e, *q;
	int i, gain, thr, raw;

	rr = (Cc1120*)r;
	q = p;
	e = p + n;
	/*
	 * Read back, do not report what was written.  The two differed
	 * for as long as PKT_CFG0 was being written to AGC_CFG1's
	 * address, and a ctl file that reports the driver's belief
	 * cannot show that.  These come out of the part.
	 */
	s2 = rr->spi;
	s2->lock(s2);
	gain = (schar)rd(rr, Ragcgainadjust);
	thr = (schar)rd(rr, Ragccsthr);
	raw = (schar)rdx(rr, Xrssi1);
	s2->unlock(s2);

	q = seprint(q, e, "freq %llud\n", rr->hz);
	q = seprint(q, e, "mode 2fsk\n");
	q = seprint(q, e, "rate %lud\n", readrate(rr));
	q = seprint(q, e, "deviation %lud\n", readdev(rr));
	q = seprint(q, e, "bw %lud\n", readbw(rr));
	q = seprint(q, e, "csthr %d\n", thr);
	q = seprint(q, e, "rssioffset %d\n", gain);
	q = seprint(q, e, "strength %d\n", raw);
	for(i = 0; i < nelem(ccbands); i++)
		q = seprint(q, e, "band rx %llud %llud\n",
			ccbands[i].lo, ccbands[i].hi);
	for(i = 0; i < nelem(ccbands); i++)
		q = seprint(q, e, "band tx %llud %llud -16 14\n",
			ccbands[i].lo, ccbands[i].hi);
	q = seprint(q, e, "modes 2fsk 4fsk msk ook\n");
	q = seprint(q, e, "levels strength rfpower csthr rssioffset\n");
	q = seprint(q, e, "funcs carrier\n");
	return q - p;
}

static Radiodev cc1120dev = {
	"CC1120",
	Ccmaxpayload,
	cc1120send,
	cc1120ctl,
	cc1120stat,
	cc1120txtest,
	cc1120caps,
};

Radio*
cc1120init(Spidev *s, int irq)
{
	Cc1120 *rr;
	int i, nbad;

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
	/*
	 * TI's settings first, then this board's over the top of them.
	 * See the tables above for where they come from and what this
	 * part does without them.
	 */
	for(i = 0; i < nelem(cc1120cfg); i += 2)
		wr(rr, cc1120cfg[i], cc1120cfg[i+1]);
	for(i = 0; i < nelem(cc1120cfgx); i += 2)
		wrx(rr, cc1120cfgx[i], cc1120cfgx[i+1]);

	/*
	 * Wait for the part again before writing anything else.
	 *
	 * The last three entries of the extended table are XOSC5, XOSC3
	 * and XOSC1 -- the crystal oscillator's own configuration -- and
	 * on silicon the eight writes that used to follow them did not
	 * reach the part while everything before them and everything
	 * from setfreq() onward did.  Measured after a boot: PKT_LEN 3
	 * where 125 was written, AGC_CS_THR and AGC_GAIN_ADJUST 0 where
	 * -90 and -102 were, IOCFG1 and IOCFG2 still the table's, and
	 * FREQ holding 0x6c8000, which is setfreq()'s own arithmetic for
	 * 868MHz.  Eight two-byte writes is on the order of a hundred
	 * microseconds, which is the shape of a part that has taken its
	 * oscillator down and back up and is not answering meanwhile.
	 *
	 * None of it reproduces at a shell prompt, where the same writes
	 * are a tenth of a second apart and all take, which is the same
	 * evidence from the other side.
	 *
	 * CHIP_RDYn in the status byte is what the part says about this,
	 * and cc1120init() already waits on it after SRES for the same
	 * reason -- a PARTNUMBER of 0x00 read before the part was
	 * awake.  This is the second time on this chip that the answer
	 * was "ask whether it is ready".
	 */
	if(chipready(rr) < 0)
		print("cc1120 %s: not ready after the register tables\n",
			s->name);

	wr(rr, Rpktlen, Ccmaxpayload);
	rr->rssioffset = Rssioffset;
	wr(rr, Ragcgainadjust, rr->rssioffset & 0xff);
	rr->csthr = Csthr;
	wr(rr, Ragccsthr, rr->csthr & 0xff);
	/*
	 * Read back what was just written.
	 *
	 * This driver has twice now been wrong about what it had put in
	 * a register -- once because the constant named the wrong
	 * register, and once because a whole run of writes did not
	 * reach the part while the table before them did -- and both
	 * times it was found days later by an instrument, not by the
	 * board.  A register write is a thing the part can be asked
	 * about, so ask.  Six reads at boot.
	 */

	/*
	 * RSSI_VALID_CNT: how many internal estimates the moving
	 * average takes before it updates the RSSI.  Reset is two and
	 * the maximum is nine, which is a quieter number for the same
	 * signal, at the cost of updating less often.  Carrier sense
	 * is compared against the same filtered value, so it steadies
	 * too (SWRU295E 6.10).  Nothing here gates reception on
	 * carrier sense, so a slower update costs nothing else.
	 */
	/*
	 * A sync word, so the part can find the start of a packet.
	 *
	 * SYNC_CFG1's top three bits are SYNC_MODE and TI's table
	 * leaves them zero, which is "no sync word".  With that, the
	 * packet engine never frames anything: this driver has never
	 * received a packet on silicon and could not have.  The
	 * receive path, the interrupt, the queue and the counters were
	 * all in place and the part was never told what to listen for.
	 * Found by reading SYNC_CFG1 back off the part while trying to
	 * identify something on the air -- 0x05, which is SYNC_MODE 0
	 * and SYNC_THR 5.
	 *
	 * 16 bits, keeping the threshold the table chose.  The word
	 * itself stays at the part's reset value; "sync" on the ctl
	 * file changes both.
	 */
	wr(rr, Rsynccfg1x, (rd(rr, Rsynccfg1x) & 0x1f) | (2<<5));
	wr(rr, Ragccfg0, Agccfg0init);
	wr(rr, Riocfg3, Gpktsyncrxtx);
	wr(rr, Riocfg2, Ghighz);
	wr(rr, Riocfg1, Ghighz);
	wr(rr, Riocfg0, Ghighz);
	/*
	 * All six read back here and not beside their writes: a read is
	 * a bus transaction too, and three of them in the middle of the
	 * run would give the second half of it a lead-in the
	 * uninstrumented kernel does not have.  An instrument that
	 * changes what it measures answers a different question.
	 */
	rr->symrate = readrate(rr);
	nbad = 0;
	nbad += verify(rr, Rpktlen, Ccmaxpayload);
	nbad += verify(rr, Ragcgainadjust, rr->rssioffset & 0xff);
	nbad += verify(rr, Ragccsthr, rr->csthr & 0xff);
	nbad += verify(rr, Ragccfg0, Agccfg0init);
	nbad += verify(rr, Riocfg3, Gpktsyncrxtx);
	nbad += verify(rr, Riocfg2, Ghighz);
	setfreq(rr, Deffreq);		/* calibrates and goes to RX */
	s->unlock(s);

	print("cc1120 %s: CC1120 rev 0x%.2x, listening%s\n",
		s->name, rr->partversion,
		nbad == 0? "": " (SETTINGS NOT APPLIED, see above)");
	return rr;
}
