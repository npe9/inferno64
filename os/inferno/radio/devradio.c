#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../radio/radio.h"

/*
 * #W, a packet radio.
 *
 *	/dev/radio0/data	one write is one packet, one read is one
 *	/dev/radio0/pkt		a read is one packet and what was known
 *				about it when it arrived
 *	/dev/radio0/ctl		text: freq, power, sf, bw, cr, ...
 *	/dev/radio0/stats	text: parameters, RSSI, SNR, counters
 *
 * The shape is the one #D ssl, #l ether and #u usb already use: a
 * numbered directory per interface with data, ctl and a status file.
 *
 * This is the frame layer and nothing above it.  It carries atomic
 * packets, the radio's configuration, and the receive metadata; it has
 * no addresses, no ports, no acknowledgement, no retry, no routing and
 * no fragmentation.  Those belong to whatever speaks through it, the
 * way IP belongs above #l ether rather than inside it.  A packet
 * written here goes out exactly as written, and a packet read here is
 * exactly what the modem demodulated.
 *
 * data is message-delimited and that is the whole design.  A radio is
 * not a byte stream, and everything that would be layered on this
 * depends on the boundary surviving: ssl(3) is a filter over a file
 * descriptor, and Styx is a request and a reply.
 *
 * pkt is data with its ancillary information, and exists because a
 * packet radio has per-packet facts a stream has nowhere to put: the
 * signal strength and signal-to-noise ratio it arrived at, whether its
 * CRC checked, and when it landed.  A second file would race -- two
 * readers, or one reader and two packets, could pair the wrong header
 * with the wrong payload -- so the two come out of one read, in the
 * order recvmsg(2) uses: Pkthdrlen bytes of
 *
 *	len[2] rssi[2] snr[2] flags[2] tick[4]
 *
 * little-endian, rssi and snr signed, then the payload.  A reader that
 * does not care opens data instead and the header is skipped for it.
 *
 * Two things are refused rather than accommodated, because a device
 * that quietly did either would hide the problem somewhere it could not
 * be found:
 *
 *   - a read whose buffer is smaller than the packet.  ssl(3) states
 *     the contract this inherits -- "as long as reads always specify
 *     buffers that are of equal or greater lengths than the writes at
 *     the other end of the connection, one write will correspond to one
 *     read" -- and a device that returned the first n bytes would break
 *     it long after the read that did it.
 *
 *   - a write longer than the payload budget.  Splitting it across two
 *     packets is the segmentation layer, and doing that silently would
 *     hide the message-size question in doc/pycubed-plan.ms rather than
 *     making someone decide about it.  The error names the budget.
 *
 * The iounit of data is that budget, which is not decoration:
 * os/inferno/port/exportfs.c adopts a transport's iounit when it is
 * above 64 and below the requested msize, so a Styx server over this
 * negotiates a radio-sized message without being told to.
 */

enum {
	Qdir,
	Qradiodir,
	Qdata,
	Qpkt,
	Qctl,
	Qstats,
	Qtxtest,

	/*
	 * Sockets this kernel will serve.  A board fits as many as it
	 * has and radioget() answers nil for the rest, so a directory
	 * appears only for a part that was actually found.  A PyCubed
	 * has two on one SPI bus, RF1 and RF2.
	 */
	Nradio		= 2,
	Statlen		= 512,
};

#define TYPE(q)		((ulong)(q).path & 0x0f)
#define NUM(q)		(((ulong)(q).path >> 4) & 0xff)
#define QID(n, t)	(((n) << 4) | (t))

extern Radio* radioget(int);

static int
radiogen(Chan *c, char *unused, Dirtab *d, int nd, int s, Dir *dp)
{
	Qid q;
	int n;

	USED(unused); USED(d); USED(nd);

	if(s == DEVDOTDOT){
		switch(TYPE(c->qid)){
		case Qdir:
			mkqid(&q, QID(0, Qdir), 0, QTDIR);
			devdir(c, q, "#W", 0, eve, 0555, dp);
			break;
		case Qradiodir:
			mkqid(&q, QID(0, Qdir), 0, QTDIR);
			devdir(c, q, "#W", 0, eve, 0555, dp);
			break;
		default:
			return -1;
		}
		return 1;
	}

	switch(TYPE(c->qid)){
	case Qdir:
		if(s >= Nradio)
			return -1;
		if(radioget(s) == nil)
			return -1;
		snprint(up->genbuf, sizeof up->genbuf, "radio%d", s);
		mkqid(&q, QID(s, Qradiodir), 0, QTDIR);
		devdir(c, q, up->genbuf, 0, eve, 0555, dp);
		return 1;

	case Qradiodir:
	case Qdata:
	case Qpkt:
	case Qctl:
	case Qstats:
	case Qtxtest:
		n = NUM(c->qid);
		switch(s){
		case 0:
			mkqid(&q, QID(n, Qdata), 0, QTFILE);
			devdir(c, q, "data", 0, eve, 0660, dp);
			return 1;
		case 1:
			mkqid(&q, QID(n, Qpkt), 0, QTFILE);
			devdir(c, q, "pkt", 0, eve, 0440, dp);
			return 1;
		case 2:
			mkqid(&q, QID(n, Qctl), 0, QTFILE);
			devdir(c, q, "ctl", 0, eve, 0660, dp);
			return 1;
		case 3:
			mkqid(&q, QID(n, Qstats), 0, QTFILE);
			devdir(c, q, "stats", 0, eve, 0444, dp);
			return 1;
		case 4:
			if(radioget(n) == nil || radioget(n)->dev->txtest == nil)
				return 0;
			mkqid(&q, QID(n, Qtxtest), 0, QTFILE);
			devdir(c, q, "txtest", 0, eve, 0440, dp);
			return 1;
		}
		return -1;
	}
	return -1;
}

static Chan*
radioattach(char *spec)
{
	Chan *c;

	c = devattach('W', spec);
	mkqid(&c->qid, QID(0, Qdir), 0, QTDIR);
	return c;
}

static Walkqid*
radiowalk(Chan *c, Chan *nc, char **name, s32 nname)
{
	return devwalk(c, nc, name, nname, nil, 0, radiogen);
}

static s32
radiostat(Chan *c, uchar *db, s32 n)
{
	return devstat(c, db, n, nil, 0, radiogen);
}

/*
 * data and pkt are one queue, so a second reader is not a second
 * stream: it is two processes taking alternate packets and each
 * missing the other's.  #L's reader kproc holds the radio for the life
 * of a boot, and a program that opened data afterwards would block for
 * ever on packets that had already gone somewhere else.
 *
 * So the read side is claimed, once, and a second claim is refused
 * naming what has it.  A silent hang is exactly what this device
 * refuses to do everywhere else, and there is no reason for the one
 * case that is hardest to diagnose to be the exception.  A writer is
 * not a claimant: transmitting is serialised in the part and two
 * processes may do it.
 */
static int
claimsread(int omode)
{
	return (omode & 3) != OWRITE;
}

static Chan*
radioopen(Chan *c, u32 omode)
{
	Radio *rr;
	int claimed, t;

	t = TYPE(c->qid);
	rr = nil;
	if(t != Qdir && t != Qradiodir){
		rr = radioget(NUM(c->qid));
		if(rr == nil)
			error(Enonexist);
	}

	claimed = 0;
	if((t == Qdata || t == Qpkt) && claimsread(omode)){
		lock(&rr->rl);
		if(rr->reading){
			unlock(&rr->rl);
			error("radio: the receive path is already open; "
				"#L holds it once a packet device is attached");
		}
		rr->reading = 1;
		unlock(&rr->rl);
		claimed = 1;
	}
	if(waserror()){
		if(claimed)
			rr->reading = 0;
		nexterror();
	}
	c = devopen(c, omode, nil, 0, radiogen);
	poperror();

	if(TYPE(c->qid) == Qdata)
		c->iounit = rr->dev->maxpayload;
	else if(TYPE(c->qid) == Qpkt)
		c->iounit = Pkthdrlen + rr->dev->maxpayload;
	return c;
}

static void
radioclose(Chan *c)
{
	Radio *rr;
	int t;

	if((c->flag & COPEN) == 0)
		return;
	t = TYPE(c->qid);
	if(t != Qdata && t != Qpkt)
		return;
	if(!claimsread(c->mode))
		return;
	rr = radioget(NUM(c->qid));
	if(rr == nil)
		return;
	lock(&rr->rl);
	rr->reading = 0;
	unlock(&rr->rl);
}

static s32
radioread(Chan *c, void *a, s32 n, s64 offset)
{
	Radio *rr;
	Block *b;
	char *buf;
	int rv, off;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, nil, 0, radiogen);

	rr = radioget(NUM(c->qid));
	if(rr == nil)
		error(Enonexist);

	switch(TYPE(c->qid)){
	case Qdata:
	case Qpkt:
		/*
		 * Ask for a whole packet, not for what the caller's buffer
		 * happens to hold.  qbread() on a Qmsg queue hands back n
		 * bytes and throws the rest of the message away, which is
		 * exactly the silent truncation this device must not do --
		 * so take the packet, and if it does not fit, put it back
		 * and say so.  The packet is still there for a read that
		 * is big enough.
		 *
		 * A queue entry is the ancillary data then the payload.
		 * data skips the first and pkt returns both, out of the
		 * same entry, so a reader of pkt gets the packet and what
		 * was known about it together and races nobody.
		 */
		b = qbread(rr->rq, Pkthdrlen + rr->dev->maxpayload);
		if(b == nil)
			return 0;
		rv = BLEN(b);
		off = TYPE(c->qid) == Qdata ? Pkthdrlen : 0;
		if(rv < Pkthdrlen){
			freeb(b);
			error("radio: short queue entry");
		}
		rv -= off;
		if(rv > n){
			ilock((Lock*)rr->rq);
			qputback(rr->rq, b);
			iunlock((Lock*)rr->rq);
			snprint(up->genbuf, sizeof up->genbuf,
				"radio: %d byte packet needs a read that big",
				rv);
			error(up->genbuf);
		}
		if(waserror()){
			freeb(b);
			nexterror();
		}
		memmove(a, b->rp + off, rv);
		poperror();
		freeb(b);
		return rv;

	case Qctl:
		snprint(up->genbuf, sizeof up->genbuf, "radio%ld\n",
			NUM(c->qid));
		return readstr(offset, a, n, up->genbuf);

	case Qstats:
	case Qtxtest:
		/*
		 * txtest transmits.  A read with a side effect is not
		 * something to do lightly, and this one is deliberate:
		 * writing a ctl file needs a redirection, a redirection
		 * needs a process, and a board that can spawn one
		 * process in a boot can therefore run one bench session
		 * between resets.  A read costs nothing, so the bench
		 * can be driven as often as it takes.  It only exists
		 * on a driver that offers it, and the file is 0440.
		 *
		 * offset is ignored for the transmit itself: every open
		 * and read sends one packet, and a reader that comes
		 * back for a second bufferful of the same report would
		 * otherwise send another.  readstr sees the whole
		 * report, so a short read still gets a consistent one.
		 */
		if(TYPE(c->qid) == Qtxtest && rr->dev->txtest == nil)
			error(Egreg);
		buf = malloc(Statlen);
		if(buf == nil)
			error(Enomem);
		if(waserror()){
			free(buf);
			nexterror();
		}
		if(TYPE(c->qid) == Qtxtest){
			if(offset == 0)
				rr->dev->txtest(rr, buf, Statlen);
			else
				buf[0] = 0;
		}else
			rr->dev->stat(rr, buf, Statlen);
		rv = readstr(offset, a, n, buf);
		poperror();
		free(buf);
		return rv;
	}
	error(Egreg);
	return 0;
}

static s32
radiowrite(Chan *c, void *a, s32 n, s64)
{
	Radio *rr;

	rr = radioget(NUM(c->qid));
	if(rr == nil)
		error(Enonexist);

	switch(TYPE(c->qid)){
	case Qdata:
		if(n > rr->dev->maxpayload){
			snprint(up->genbuf, sizeof up->genbuf,
				"radio: %d bytes is past the %d byte payload",
				n, rr->dev->maxpayload);
			error(up->genbuf);
		}
		if(rr->dev->send(rr, a, n) < 0)
			error("radio: transmit refused");
		return n;

	case Qctl:
		return rr->dev->ctl(rr, a, n);
	}
	error(Egreg);
	return 0;
}

Dev radiodevtab = {
	'W',
	"radio",

	devreset,
	devinit,
	devshutdown,
	radioattach,
	radiowalk,
	radiostat,
	radioopen,
	devcreate,
	radioclose,
	radioread,
	devbread,
	radiowrite,
	devbwrite,
	devremove,
	devwstat,
};
