#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../radio/sx127x.h"

/*
 * Semtech SX127x LoRa transceiver.
 *
 * Written from the SX1276 datasheet.  Only LoRa mode: the part also
 * does FSK and OOK and this does not pretend to.
 *
 * The RadioHead-compatible four-byte header is here rather than above
 * because it is what the other end of a PyCubed link speaks --
 * lib/pycubed_rfm9x.py sends and expects it -- so a receiver that did
 * not know about it would see four bytes of rubbish in front of every
 * payload.  Acknowledgement and retry are not here yet, and the man
 * page says so.
 */

enum {
	Sxfifo		= 0x00,
	Sxopmode		= 0x01,
	  Olongrange	= 0x80,
	  Omode		= 0x07,
	  Msleep	= 0,
	  Mstdby	= 1,
	  Mfstx		= 2,
	  Mtx		= 3,
	  Mfsrx		= 4,
	  Mrxcont	= 5,
	  Mrxsingle	= 6,
	  Mcad		= 7,
	Sxfrfmsb		= 0x06,
	Sxfrfmid		= 0x07,
	Sxfrflsb		= 0x08,
	Sxpaconfig	= 0x09,
	  Paboost	= 0x80,
	Sxfifoaddrptr	= 0x0d,
	Sxfifotxbase	= 0x0e,
	Sxfiforxbase	= 0x0f,
	Sxfiforxcurrent	= 0x10,
	Sxirqflagsmask	= 0x11,
	Sxirqflags	= 0x12,
	  Irxtimeout	= 0x80,
	  Irxdone	= 0x40,
	  Icrcerror	= 0x20,
	  Ivalidheader	= 0x10,
	  Itxdone	= 0x08,
	  Icaddone	= 0x04,
	  Ifhss		= 0x02,
	  Icaddetected	= 0x01,
	Sxrxnbbytes	= 0x13,
	Sxmodemstat	= 0x18,
	  Msigdet	= 0x01,		/* a signal is on the channel */
	  Msigsync	= 0x02,
	  Mhdrvalid	= 0x08,
	Sxpktsnr		= 0x19,
	Sxpktrssi	= 0x1a,
	Sxrssi		= 0x1b,
	Sxmodemconfig1	= 0x1d,
	Sxmodemconfig2	= 0x1e,
	Sxpayloadlength	= 0x22,
	Sxmaxpayload	= 0x23,
	Sxmodemconfig3	= 0x26,
	Sxdiomapping1	= 0x40,
	Sxdiomapping2	= 0x41,
	Sxversion	= 0x42,
	Sxpadac		= 0x4d,

	Sx1276version	= 0x12,


	/*
	 * RegFrf counts in steps of the 32MHz crystal over 2^19, which is
	 * 61.03515625 Hz.  Multiply by 2^19 and divide by 32e6 without
	 * leaving 64 bits: 32e6/2^19 is not an integer, so scale by the
	 * greatest common divisor instead -- 32000000 = 2^11 * 15625, and
	 * 2^19/2^11 is 256, so frf = hz*256/15625.
	 */
	Fstepnum	= 256,
	Fstepden	= 15625,
};

static void
wr(Radio *rr, int addr, int val)
{
	Spidev *s = rr->spi;

	s->select(s, 1);
	s->byte(s, addr | 0x80);
	s->byte(s, val);
	s->select(s, 0);
}

static int
rd(Radio *rr, int addr)
{
	Spidev *s = rr->spi;
	int v;

	s->select(s, 1);
	s->byte(s, addr & 0x7f);
	v = s->byte(s, 0);
	s->select(s, 0);
	return v;
}

static void
wrburst(Radio *rr, int addr, uchar *p, int n)
{
	Spidev *s = rr->spi;
	int i;

	s->select(s, 1);
	s->byte(s, addr | 0x80);
	for(i = 0; i < n; i++)
		s->byte(s, p[i]);
	s->select(s, 0);
}

static void
rdburst(Radio *rr, int addr, uchar *p, int n)
{
	Spidev *s = rr->spi;
	int i;

	s->select(s, 1);
	s->byte(s, addr & 0x7f);
	for(i = 0; i < n; i++)
		p[i] = s->byte(s, 0);
	s->select(s, 0);
}

static void
setmode(Radio *rr, int mode)
{
	int v;

	v = rd(rr, Sxopmode);
	wr(rr, Sxopmode, (v & ~Omode) | (mode & Omode));
}

static void
setfreq(Radio *rr, u32 hz)
{
	uvlong frf;

	frf = ((uvlong)hz * Fstepnum) / Fstepden;
	wr(rr, Sxfrfmsb, (frf >> 16) & 0xff);
	wr(rr, Sxfrfmid, (frf >> 8) & 0xff);
	wr(rr, Sxfrflsb, frf & 0xff);
	rr->freq = hz;
}

/*
 * RegModemConfig1 bits 7:4 name a bandwidth from a table rather than
 * carrying a number.  The table is the datasheet's.
 */
static u32 bwtab[] = {
	7800, 10400, 15600, 20800, 31250, 41700,
	62500, 125000, 250000, 500000,
};

static int
bwcode(u32 bw)
{
	int i;

	for(i = 0; i < nelem(bwtab); i++)
		if(bwtab[i] == bw)
			return i;
	return -1;
}

/*
 * Symbol time in microseconds: 2^SF / BW.  Wanted in two places, and
 * both of them matter -- see lowdatarate() and timeonair().
 */
static u32
symbolus(Radio *rr)
{
	if(rr->bw == 0)
		return 0;
	return ((uvlong)(1 << rr->sf) * 1000000) / rr->bw;
}

static void
setmodem(Radio *rr)
{
	int c, ldro;

	c = bwcode(rr->bw);
	if(c < 0)
		c = 7;			/* 125kHz, the part's own default */
	wr(rr, Sxmodemconfig1, (c << 4) | ((rr->cr - 4) << 1));
	/* bit 2 is RxPayloadCrcOn: on, so a corrupt packet says so */
	wr(rr, Sxmodemconfig2, (rr->sf << 4) | (1 << 2));
	/*
	 * LowDataRateOptimize, bit 3, which the datasheet (4.1.1.6)
	 * requires whenever a symbol is longer than 16ms -- SF11 and SF12
	 * at 125kHz, and more of them at narrower bandwidths.  It is
	 * mandatory, not advisory: the receiver has to agree, so a link
	 * with one end setting it and the other not does not work.  This
	 * was missing, and nothing here could see it until the model
	 * started charging for time on air.  Bit 2 is AgcAutoOn.
	 */
	ldro = symbolus(rr) > 16000;
	wr(rr, Sxmodemconfig3, (ldro << 3) | (1 << 2));
}

/*
 * How long a packet of n bytes will be on the air, in milliseconds,
 * rounded up.  Datasheet 4.1.1.7.  A driver needs this because the
 * alternative is a fixed timeout, and a fixed timeout is either wrong
 * at SF12 or pointlessly long at SF7: at 125kHz a 20-byte packet is
 * 57ms at SF7 and 1319ms at SF12, which is a factor of twenty-three.
 */
/*
 * Milliseconds since boot.  TK2MS on the tick counter: this is a
 * duty-cycle clock, where being out by a tick does not matter and
 * being out by a factor does, so the coarse one is the right one.
 */
static uvlong
nowms(void)
{
	return TK2MS((uvlong)MACHP(0)->ticks);
}

/*
 * How long until a transmit is permitted, in milliseconds.  Zero when
 * the duty cycle is off or the silence has already been served.
 */
static vlong
dutyowed(Radio *rr)
{
	vlong owed;

	if(rr->duty <= 0 || rr->duty >= 100)
		return 0;
	owed = (vlong)rr->nextok - (vlong)nowms();
	return owed > 0 ? owed : 0;
}

static int
timeonair(Radio *rr, int n)
{
	uvlong ts, total;
	int num, den, nsym, ldro;

	ts = symbolus(rr);
	if(ts == 0)
		return 1000;
	ldro = symbolus(rr) > 16000;
	/* CRC on, explicit header */
	num = 8*n - 4*rr->sf + 28 + 16;
	den = 4 * (rr->sf - 2*ldro);
	nsym = 8;
	if(num > 0 && den > 0)
		nsym += ((num + den - 1) / den) * rr->cr;
	/* preamble is 8 + 4.25 symbols; keep the quarter */
	total = (ts * (4*8 + 17)) / 4 + ts * nsym;
	return (total + 999) / 1000;
}

static void
setpower(Radio *rr, int dbm)
{
	if(dbm < 2)
		dbm = 2;
	if(dbm > 17)
		dbm = 17;
	/* PA_BOOST, which is the output an RFM9x module bonds out */
	wr(rr, Sxpaconfig, Paboost | (dbm - 2));
	rr->power = dbm;
}

static void
listen(Radio *rr)
{
	wr(rr, Sxdiomapping1, 0x00);		/* DIO0 = RxDone */
	setmode(rr, Mrxcont);
}

static int
txdone(void *a)
{
	Radio *rr = a;

	return rr->txdone;
}

/*
 * One packet on the air, exactly as given.  No header: this is the
 * medium, and who a packet is for is not its business.  See
 * doc/radio-interface.ms.
 */
int
sx127xsend(Radio *rr, uchar *p, int n)
{
	int ms, i, busy;
	vlong owed;

	if(n <= 0 || n > Maxpayload){
		rr->ntoobig++;
		return -1;
	}

	/*
	 * Listen before transmitting, if asked to.  RegModemStat's
	 * signal-detected bit is what a part in receive says about the
	 * channel, and it is the only thing a station has to go on: the
	 * radio(3) rule is that nothing arbitrates the air, and this is
	 * the smallest thing that does.  It is off by default, because
	 * a station that defers is a station that can be talked over
	 * indefinitely, and which of the two is wanted depends on the
	 * band and not on the driver.
	 *
	 * Bounded: after Carriertries the packet goes out anyway.  A
	 * radio that refuses to transmit while anyone else is talking
	 * has no way to finish a conversation on a busy channel, and a
	 * silent satellite is worse than a collision.
	 */
	if(rr->carrier){
		for(i = 0; i < Carriertries; i++){
			rr->spi->lock(rr->spi);
			busy = rd(rr, Sxmodemstat) & Msigdet;
			rr->spi->unlock(rr->spi);
			if(!busy)
				break;
			rr->nbusy++;
			tsleep(&up->sleep, return0, 0,
				Carrierwait + nrand(Carrierwait));
		}
		if(i >= Carriertries)
			rr->ngaveup++;
	}

	/*
	 * Wait out the duty cycle before taking the lock, not after: a
	 * transmitter that has spent its allowance has no business
	 * holding the part while it waits, and a receiver on the same
	 * radio must go on receiving.
	 */
	if(rr->duty > 0){
		owed = dutyowed(rr);
		if(owed > 0)
			rr->nwaited++;
		while(owed > 0){
			if(owed > 1000)
				owed = 1000;
			tsleep(&up->sleep, return0, 0, (int)owed);
			owed = dutyowed(rr);
		}
	}

	qlock(&rr->qlock);
	if(waserror()){
		qunlock(&rr->qlock);
		nexterror();
	}

	rr->spi->lock(rr->spi);
	setmode(rr, Mstdby);
	wr(rr, Sxirqflags, 0xff);
	wr(rr, Sxfifotxbase, 0x00);
	wr(rr, Sxfifoaddrptr, 0x00);
	wrburst(rr, Sxfifo, p, n);
	wr(rr, Sxpayloadlength, n);

	rr->txdone = 0;
	wr(rr, Sxdiomapping1, 0x40);		/* DIO0 = TxDone */
	setmode(rr, Mtx);
	rr->spi->unlock(rr->spi);

	ms = timeonair(rr, n);
	tsleep(&rr->txr, txdone, rr, ms + ms/2 + 50);
	if(!rr->txdone){
		rr->ntxtimeout++;
		print("sx127x %s: no TxDone in %dms for a %dms packet\n",
			rr->spi->name, ms + ms/2 + 50, ms);
	}else
		rr->nsent++;

	/*
	 * Charge for the air whether or not TxDone arrived: the energy
	 * went out either way, and a regulator counts transmissions and
	 * not successes.  The rule is the one every LoRaWAN stack
	 * implements and it is stricter than the directive's: a packet
	 * of A milliseconds is followed by A*(100-D)/D of silence, so
	 * the ratio holds over every window rather than over an hour.
	 */
	rr->airms += ms;
	if(rr->duty > 0)
		rr->nextok = nowms() +
			((uvlong)ms * (100 - rr->duty)) / rr->duty;

	rr->spi->lock(rr->spi);
	listen(rr);
	rr->spi->unlock(rr->spi);

	poperror();
	qunlock(&rr->qlock);
	return rr->txdone ? n : -1;
}

/*
 * DIO0 fired.  Take whatever arrived, put the ancillary data in front
 * of it, and queue the two as one block: recvmsg() rather than recv(),
 * so that a reader gets the packet and what was known about it out of
 * the same queue entry and nothing is looked up afterwards.  #W's data
 * file skips the header, its pkt file returns it.  None of it was on
 * the air.
 *
 * No addressing here, and no acknowledgement.  This is the medium; see
 * doc/radio-interface.ms.
 */
void
sx127xinterrupt(Radio *rr)
{
	uchar buf[Maxpayload];
	Block *b;
	int flags, n, rssi, snr, pf;
	u32 tick;

	rr->spi->lock(rr->spi);
	flags = rd(rr, Sxirqflags);

	if(flags & Irxdone){
		n = rd(rr, Sxrxnbbytes);
		pf = 0;
		if(flags & Icrcerror){
			rr->ncrcerr++;
			pf |= Pcrcerr;
		}
		if(n > 0 && n <= Maxpayload){
			wr(rr, Sxfifoaddrptr, rd(rr, Sxfiforxcurrent));
			rdburst(rr, Sxfifo, buf, n);
			rssi = rd(rr, Sxpktrssi) - 157;
			snr = (schar)rd(rr, Sxpktsnr) / 4;
			rr->rssi = rssi;
			rr->snr = snr;
			tick = MACHP(0)->ticks;

			/*
			 * A packet whose CRC failed is queued with the flag
			 * set rather than thrown away: a receiver counting
			 * them is measuring its link, and a receiver that
			 * does not care ignores the flag.
			 */
			b = iallocb(Pkthdrlen + n);
			if(b != nil){
				b->wp[0] = n;
				b->wp[1] = n >> 8;
				b->wp[2] = rssi;
				b->wp[3] = rssi >> 8;
				b->wp[4] = snr;
				b->wp[5] = snr >> 8;
				b->wp[6] = pf;
				b->wp[7] = pf >> 8;
				b->wp[8] = tick;
				b->wp[9] = tick >> 8;
				b->wp[10] = tick >> 16;
				b->wp[11] = tick >> 24;
				memmove(b->wp + Pkthdrlen, buf, n);
				b->wp += Pkthdrlen + n;
				qpass(rr->rq, b);
				rr->nrecv++;
			}
		}
	}

	wr(rr, Sxirqflags, flags);
	rr->spi->unlock(rr->spi);

	if(flags & Itxdone){
		rr->txdone = 1;
		wakeup(&rr->txr);
	}
	if(flags & Irxdone)
		wakeup(&rr->r);
}

int
sx127xctl(Radio *rr, char *a, int n)
{
	Cmdbuf *cb;
	Cmdtab *ct;
	static Cmdtab ctltab[] = {
		{ 1,	"freq",		2 },
		{ 2,	"power",	2 },
		{ 3,	"sf",		2 },
		{ 4,	"bw",		2 },
		{ 5,	"cr",		2 },
		{ 6,	"duty",		2 },
		{ 7,	"carrier",	2 },
		{ 8,	"reset",	1 },
	};
	int v;

	cb = parsecmd(a, n);
	if(waserror()){
		free(cb);
		nexterror();
	}
	ct = lookupcmd(cb, ctltab, nelem(ctltab));

	qlock(&rr->qlock);
	if(waserror()){
		qunlock(&rr->qlock);
		nexterror();
	}

	/*
	 * Validate before touching the bus: error() longjmps, and doing
	 * that with an ilock held would leave it held for ever.
	 */
	v = cb->nf > 1 ? atoi(cb->f[1]) : 0;
	switch(ct->index){
	case 3:
		if(v < 6 || v > 12)
			error("spreading factor is 6 to 12");
		break;
	case 4:
		if(bwcode(v) < 0)
			error("bandwidth is not one the part has");
		break;
	case 5:
		if(v < 5 || v > 8)
			error("coding rate is 5 to 8");
		break;
	case 6:
		if(v < 0 || v > 100)
			error("duty cycle is 0 to 100 per cent; 0 is off");
		break;
	}

	rr->spi->lock(rr->spi);
	switch(ct->index){
	case 1:
		setfreq(rr, v);
		break;
	case 2:
		setpower(rr, v);
		break;
	case 3:
		rr->sf = v;
		setmodem(rr);
		break;
	case 4:
		rr->bw = v;
		setmodem(rr);
		break;
	case 5:
		rr->cr = v;
		setmodem(rr);
		break;
	case 6:
		rr->duty = v;
		rr->nextok = 0;
		break;
	case 7:
		rr->carrier = strcmp(cb->f[1], "on") == 0;
		break;
	case 8:
		setmode(rr, Msleep);
		wr(rr, Sxopmode, Olongrange | Msleep);
		setfreq(rr, rr->freq);
		setmodem(rr);
		setpower(rr, rr->power);
		break;
	}
	listen(rr);

	rr->spi->unlock(rr->spi);

	poperror();
	qunlock(&rr->qlock);
	poperror();
	free(cb);
	return n;
}

int
sx127xstat(Radio *rr, char *a, int n)
{
	char *p, *e;

	p = a;
	e = a + n;
	p = seprint(p, e, "version 0x%.2x\n", rr->version);
	p = seprint(p, e, "freq %ud\n", rr->freq);
	p = seprint(p, e, "power %d\n", rr->power);
	p = seprint(p, e, "sf %d\n", rr->sf);
	p = seprint(p, e, "bw %ud\n", rr->bw);
	p = seprint(p, e, "cr %d\n", rr->cr);
	p = seprint(p, e, "rssi %d\n", rr->rssi);
	p = seprint(p, e, "snr %d\n", rr->snr);
	p = seprint(p, e, "sent %ud\n", rr->nsent);
	p = seprint(p, e, "received %ud\n", rr->nrecv);
	p = seprint(p, e, "crcerrors %ud\n", rr->ncrcerr);
	p = seprint(p, e, "toobig %ud\n", rr->ntoobig);
	p = seprint(p, e, "txtimeout %ud\n", rr->ntxtimeout);
	p = seprint(p, e, "airtime-20B-ms %d\n", timeonair(rr, 20));
	if(rr->duty > 0)
		p = seprint(p, e, "duty %d\n", rr->duty);
	else
		p = seprint(p, e, "duty off\n");
	p = seprint(p, e, "airtime-total-ms %llud\n", rr->airms);
	p = seprint(p, e, "airtime-owed-ms %lld\n", dutyowed(rr));
	p = seprint(p, e, "dutywaits %ud\n", rr->nwaited);
	p = seprint(p, e, "carrier %s\n", rr->carrier ? "on" : "off");
	p = seprint(p, e, "busywaits %ud\nsentanyway %ud\n",
		rr->nbusy, rr->ngaveup);
	return p - a;
}

Radio*
sx127xinit(Spidev *s, int irq)
{
	Radio *rr;

	USED(irq);
	rr = malloc(sizeof(Radio));
	if(rr == nil)
		return nil;
	rr->spi = s;

	s->lock(s);
	rr->version = rd(rr, Sxversion);
	s->unlock(s);

	if(rr->version != Sx1276version){
		/*
		 * Say what was found rather than what was hoped for.  A
		 * bus that is not reaching the part reads 0x00 or 0xff,
		 * and those are worth telling apart from a different chip.
		 */
		print("sx127x %s: RegVersion 0x%.2x, not an SX1276 (0x%.2x)\n",
			s->name, rr->version, Sx1276version);
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
	/* LongRangeMode can only be set in sleep: datasheet 4.1.1.2 */
	wr(rr, Sxopmode, Msleep);
	wr(rr, Sxopmode, Olongrange | Msleep);

	rr->freq = 433000000;
	rr->power = 13;
	rr->sf = 7;
	rr->bw = 125000;
	rr->cr = 5;

	setfreq(rr, rr->freq);
	setmodem(rr);
	setpower(rr, rr->power);
	wr(rr, Sxmaxpayload, Maxpayload);
	wr(rr, Sxfiforxbase, 0x00);
	wr(rr, Sxfifotxbase, 0x00);
	wr(rr, Sxirqflagsmask, 0x00);
	wr(rr, Sxirqflags, 0xff);
	listen(rr);
	s->unlock(s);

	print("sx127x %s: SX1276, %ud Hz, sf%d, bw %ud\n",
		s->name, rr->freq, rr->sf, rr->bw);
	return rr;
}
