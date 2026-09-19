#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../radio/sx127x.h"

/*
 * #W, a packet radio.
 *
 *	/dev/radio0/data	one write is one packet, one read is one
 *	/dev/radio0/ctl		text: freq, power, sf, bw, cr, node, dest
 *	/dev/radio0/stat	text: parameters, RSSI, SNR, counters
 *
 * The shape is the one #D ssl, #l ether and #u usb already use: a
 * numbered directory per interface with data, ctl and a status file.
 *
 * data is message-delimited and that is the whole design.  A radio is
 * not a byte stream, and everything that would be layered on this
 * depends on the boundary surviving: ssl(3) is a filter over a file
 * descriptor, and Styx is a request and a reply.
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
	Qctl,
	Qstat,

	Nradio		= 1,		/* sockets this kernel knows about */
	Statlen		= 512,
	Maxwrite	= Maxpayload - Rhhdrlen,
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
	case Qctl:
	case Qstat:
		n = NUM(c->qid);
		switch(s){
		case 0:
			mkqid(&q, QID(n, Qdata), 0, QTFILE);
			devdir(c, q, "data", 0, eve, 0660, dp);
			return 1;
		case 1:
			mkqid(&q, QID(n, Qctl), 0, QTFILE);
			devdir(c, q, "ctl", 0, eve, 0660, dp);
			return 1;
		case 2:
			mkqid(&q, QID(n, Qstat), 0, QTFILE);
			devdir(c, q, "stat", 0, eve, 0444, dp);
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

static Chan*
radioopen(Chan *c, u32 omode)
{
	if(TYPE(c->qid) != Qdir && TYPE(c->qid) != Qradiodir)
		if(radioget(NUM(c->qid)) == nil)
			error(Enonexist);
	c = devopen(c, omode, nil, 0, radiogen);
	if(TYPE(c->qid) == Qdata)
		c->iounit = Maxwrite;
	return c;
}

static void
radioclose(Chan*)
{
}

static s32
radioread(Chan *c, void *a, s32 n, s64 offset)
{
	Radio *rr;
	Block *b;
	char *buf;
	int rv;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, nil, 0, radiogen);

	rr = radioget(NUM(c->qid));
	if(rr == nil)
		error(Enonexist);

	switch(TYPE(c->qid)){
	case Qdata:
		/*
		 * Ask for a whole packet, not for what the caller's buffer
		 * happens to hold.  qbread() on a Qmsg queue hands back n
		 * bytes and throws the rest of the message away, which is
		 * exactly the silent truncation this device must not do --
		 * so take the packet, and if it does not fit, put it back
		 * and say so.  The packet is still there for a read that
		 * is big enough.
		 */
		b = qbread(rr->rq, Maxpayload);
		if(b == nil)
			return 0;
		rv = BLEN(b);
		if(rv > n){
			ilock((Lock*)rr->rq);
			qputback(rr->rq, b);
			iunlock((Lock*)rr->rq);
			snprint(up->genbuf, sizeof up->genbuf,
				"radio: %d byte packet needs a %d byte read",
				rv, rv);
			error(up->genbuf);
		}
		if(waserror()){
			freeb(b);
			nexterror();
		}
		memmove(a, b->rp, rv);
		poperror();
		freeb(b);
		return rv;

	case Qctl:
		snprint(up->genbuf, sizeof up->genbuf, "radio%ld\n",
			NUM(c->qid));
		return readstr(offset, a, n, up->genbuf);

	case Qstat:
		buf = malloc(Statlen);
		if(buf == nil)
			error(Enomem);
		if(waserror()){
			free(buf);
			nexterror();
		}
		sx127xstat(rr, buf, Statlen);
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
		if(n > Maxwrite){
			snprint(up->genbuf, sizeof up->genbuf,
				"radio: %d bytes is past the %d byte payload",
				n, Maxwrite);
			error(up->genbuf);
		}
		if(sx127xsend(rr, a, n) < 0)
			error("radio: transmit refused");
		return n;

	case Qctl:
		return sx127xctl(rr, a, n);
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
