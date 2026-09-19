#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/sx127x.h"

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

static void
setmodem(Radio *rr)
{
	int c;

	c = bwcode(rr->bw);
	if(c < 0)
		c = 7;			/* 125kHz, the part's own default */
	wr(rr, Sxmodemconfig1, (c << 4) | ((rr->cr - 4) << 1));
	/* bit 2 is RxPayloadCrcOn: on, so a corrupt packet says so */
	wr(rr, Sxmodemconfig2, (rr->sf << 4) | (1 << 2));
	/* bit 2 is AgcAutoOn */
	wr(rr, Sxmodemconfig3, 1 << 2);
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

int
sx127xsend(Radio *rr, uchar *p, int n)
{
	uchar hdr[Rhhdrlen];

	if(n <= 0 || n > Maxpayload - Rhhdrlen){
		rr->ntoobig++;
		return -1;
	}

	qlock(&rr->qlock);
	if(waserror()){
		qunlock(&rr->qlock);
		nexterror();
	}

	/*
	 * The bus lock is an ilock, shared with the DIO0 handler, so
	 * nothing may sleep while it is held.  Take it for the register
	 * work, drop it to wait, take it again to finish.
	 */
	rr->spi->lock(rr->spi);
	setmode(rr, Mstdby);
	wr(rr, Sxirqflags, 0xff);		/* write one to clear */
	wr(rr, Sxfifotxbase, 0x00);
	wr(rr, Sxfifoaddrptr, 0x00);

	hdr[0] = rr->dest;
	hdr[1] = rr->node;
	hdr[2] = 0;				/* id: no retries yet */
	hdr[3] = 0;				/* flags */
	wrburst(rr, Sxfifo, hdr, Rhhdrlen);
	wrburst(rr, Sxfifo, p, n);
	wr(rr, Sxpayloadlength, n + Rhhdrlen);

	rr->txdone = 0;
	wr(rr, Sxdiomapping1, 0x40);		/* DIO0 = TxDone */
	setmode(rr, Mtx);
	rr->spi->unlock(rr->spi);

	/*
	 * Wait for DIO0 rather than polling RegIrqFlags.  Polling is what
	 * this did first, and it never saw the flag: mapping DIO0 to
	 * TxDone means the interrupt arrives the moment the bit sets, and
	 * the handler clears it -- so the poll was racing its own
	 * interrupt handler and always lost.  The part tells you it is
	 * done; there is no reason to ask.
	 */
	tsleep(&rr->txr, txdone, rr, 1000);
	if(!rr->txdone)
		print("sx127x %s: no TxDone after a second\n", rr->spi->name);

	rr->spi->lock(rr->spi);
	listen(rr);
	rr->spi->unlock(rr->spi);
	rr->nsent++;

	poperror();
	qunlock(&rr->qlock);
	return n;
}

/*
 * DIO0 fired.  Read whatever arrived into a block and queue it whole:
 * the device above hands out one packet per read, so a packet has to
 * stay one thing all the way up.
 */
void
sx127xinterrupt(Radio *rr)
{
	uchar buf[Maxpayload];
	Block *b;
	int flags, n;

	rr->spi->lock(rr->spi);
	flags = rd(rr, Sxirqflags);

	if(flags & Irxdone){
		n = rd(rr, Sxrxnbbytes);
		if(flags & Icrcerror){
			rr->ncrcerr++;
		}else if(n <= Rhhdrlen || n > Maxpayload){
			/*
			 * Shorter than a RadioHead header, so it is not one
			 * of ours however well it was received.
			 */
			rr->nrunt++;
		}else{
			wr(rr, Sxfifoaddrptr, rd(rr, Sxfiforxcurrent));
			rdburst(rr, Sxfifo, buf, n);
			rr->rssi = rd(rr, Sxpktrssi) - 157;
			rr->snr = (schar)rd(rr, Sxpktsnr) / 4;
			/*
			 * Strip the RadioHead header and keep the payload.
			 * A packet not addressed to this station or to the
			 * broadcast address is not ours.
			 */
			if(buf[0] == rr->node || buf[0] == 0xff){
				b = iallocb(n - Rhhdrlen);
				if(b != nil){
					memmove(b->wp, buf + Rhhdrlen,
						n - Rhhdrlen);
					b->wp += n - Rhhdrlen;
					qpass(rr->rq, b);
					rr->nrecv++;
				}
			}else{
				/*
				 * Counted rather than merely dropped.  A
				 * packet from a sender that does not speak
				 * the RadioHead header -- a bare LoRa
				 * transmitter, which Semtech's own driver
				 * is -- lands here, and without a counter
				 * it looks exactly like a dead link.  That
				 * is not a distinction to make an operator
				 * guess at from the ground.
				 */
				rr->nnotours++;
			}
		}
	}

	/*
	 * Clear exactly the bits that were read, not everything: a flag
	 * that set between the read and the write would otherwise be
	 * thrown away without anyone having looked at it.
	 */
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
		{ 6,	"node",		2 },
		{ 7,	"dest",		2 },
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
		rr->node = v & 0xff;
		break;
	case 7:
		rr->dest = v & 0xff;
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
	p = seprint(p, e, "node %d\n", rr->node);
	p = seprint(p, e, "dest %d\n", rr->dest);
	p = seprint(p, e, "rssi %d\n", rr->rssi);
	p = seprint(p, e, "snr %d\n", rr->snr);
	p = seprint(p, e, "sent %ud\n", rr->nsent);
	p = seprint(p, e, "received %ud\n", rr->nrecv);
	p = seprint(p, e, "crcerrors %ud\n", rr->ncrcerr);
	p = seprint(p, e, "toobig %ud\n", rr->ntoobig);
	p = seprint(p, e, "notours %ud\n", rr->nnotours);
	p = seprint(p, e, "runt %ud\n", rr->nrunt);
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
	rr->node = 1;
	rr->dest = 0xff;

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
