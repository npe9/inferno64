#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../radio/radio.h"

/*
 * #k, KISS: a packet device over a byte stream.
 *
 *	/net/kiss/ctl		fd n, txdelay, persist, slottime, txtail,
 *				duplex
 *	/net/kiss/data		one KISS data frame per read and per write
 *	/net/kiss/stats		counters
 *
 * A TNC speaks KISS over a serial line, and a KISS data frame carries
 * exactly what ax25(3) builds: the address field, the control byte,
 * the PID and the information, with no flags, no bit stuffing and no
 * frame check sequence, because the TNC puts those on the air itself.
 * So this is the shortest path from this tree to a real amateur
 * station: #a attaches to a file descriptor, #k is one, and the
 * hardware on the other side of the serial line does HDLC and the
 * modulation that ax25(3) says it does not do.
 *
 * It is also the only honest way to drive the link layers with no
 * radio in the room.  doc/radio-interface.ms records that #L could not
 * be run over a pipe because a pipe is a byte stream and does not keep
 * a message boundary -- os/inferno/port/devpipe.c:73 opens its queues
 * as streams.  KISS is precisely the framing that was missing, so a
 * pipe with this on one end is a packet device, and the whole stack
 * above it runs in one kernel with nothing else fitted.
 *
 * The framing is SLIP's, from the KISS specification:
 *
 *	FEND  0xc0	frame delimiter
 *	FESC  0xdb	escape
 *	TFEND 0xdc	FEND, escaped
 *	TFESC 0xdd	FESC, escaped
 *
 * A frame is FEND, a type byte, the data, FEND.  The type byte's low
 * four bits are the command and the high four the TNC port; 0 is a
 * data frame and the rest configure the TNC, which is what txdelay and
 * the others below send.  Nothing is acknowledged and nothing is
 * retried: KISS is a way of putting a boundary on a byte stream and
 * claims to be nothing else.
 */

enum {
	Qdir,
	Qkissdir,
	Qdata,
	Qctl,
	Qstats,

	Nkiss		= 1,

	Fend		= 0xc0,
	Fesc		= 0xdb,
	Tfend		= 0xdc,
	Tfesc		= 0xdd,

	/* KISS commands, in the type byte's low four bits */
	Cdata		= 0,
	Ctxdelay	= 1,
	Cpersist	= 2,
	Cslottime	= 3,
	Ctxtail		= 4,
	Cduplex		= 5,

	/*
	 * What one frame may carry.  AX.25 2.2's N1 defaults to 256
	 * bytes of information, and an address field with two
	 * digipeaters, a control byte and a PID is 30 more, so 272 is
	 * the number at which a conversation on #a lands on the
	 * specification's own default with no path and a little under
	 * it with one.  A TNC's own buffer is usually larger; this is
	 * the promise this device makes and not the far end's.
	 */
	Maxframe	= 272,
	Statlen		= 512,
	Qmax		= 8,
};

#define TYPE(q)		((ulong)(q).path & 0x0f)
#define NUM(q)		(((ulong)(q).path >> 4) & 0xff)
#define QID(n, t)	(((n) << 4) | (t))

static struct
{
	QLock	l;		/* attaching the serial line */
	Chan	*c;
	int	started;
	Queue	*rq;
	QLock	tx;		/* one writer on the line at a time */

	/* the un-escaping state machine */
	uchar	in[Maxframe + 1];
	int	nin;
	int	esc;
	int	over;		/* this frame has already overrun */

	u32	nin_frames;
	u32	nout;
	u32	nother;		/* a frame that was not a data frame */
	u32	nrunt;		/* a frame with no type byte */
	u32	ntoobig;
	u32	nbadesc;	/* FESC followed by neither TFEND nor TFESC */
} kiss;

static char Enotattached[] = "no serial line attached";

static void
kissqueue(void)
{
	Block *b;
	int n;

	if(kiss.nin < 1){
		kiss.nrunt++;
		return;
	}
	if((kiss.in[0] & 0x0f) != Cdata){
		/*
		 * A TNC sends these back at us on some hardware.  Not
		 * an error and not data, so counted and dropped rather
		 * than handed to whoever is reading packets.
		 */
		kiss.nother++;
		return;
	}
	n = kiss.nin - 1;
	if(n == 0)
		return;			/* an empty data frame says nothing */
	b = iallocb(n);
	if(b == nil)
		return;
	memmove(b->wp, kiss.in + 1, n);
	b->wp += n;
	kiss.nin_frames++;
	qpass(kiss.rq, b);
}

/*
 * One byte off the line.  Runs in the reader process; it never
 * transmits and never waits.
 */
static void
kissbyte(int ch)
{
	if(ch == Fend){
		if(kiss.nin > 0 && !kiss.over)
			kissqueue();
		kiss.nin = 0;
		kiss.esc = 0;
		kiss.over = 0;
		return;
	}
	if(ch == Fesc){
		kiss.esc = 1;
		return;
	}
	if(kiss.esc){
		kiss.esc = 0;
		if(ch == Tfend)
			ch = Fend;
		else if(ch == Tfesc)
			ch = Fesc;
		else{
			/*
			 * The specification says nothing else may follow
			 * an escape.  Drop the frame rather than guess:
			 * a byte taken as data here is a byte in the
			 * middle of somebody's address field.
			 */
			kiss.nbadesc++;
			kiss.over = 1;
			return;
		}
	}
	if(kiss.over)
		return;
	if(kiss.nin >= Maxframe + 1){
		kiss.ntoobig++;
		kiss.over = 1;
		return;
	}
	kiss.in[kiss.nin++] = ch;
}

static void
kissreader(void*)
{
	uchar buf[256];
	Chan *c;
	int n, i;

	for(;;){
		c = kiss.c;
		if(c == nil)
			break;
		if(waserror())
			continue;
		n = devtab[c->type]->read(c, buf, sizeof buf, 0);
		poperror();
		if(n <= 0)
			continue;
		for(i = 0; i < n; i++)
			kissbyte(buf[i]);
	}
	pexit("", 0);
}

/* one frame onto the line, escaped */
static void
kissput(int type, uchar *p, int n)
{
	Block *b;
	Chan *c;
	int i;

	c = kiss.c;
	if(c == nil)
		error(Enotattached);

	b = allocb(2*n + 3);
	if(waserror()){
		freeb(b);
		nexterror();
	}
	*b->wp++ = Fend;
	*b->wp++ = type;
	for(i = 0; i < n; i++){
		if(p[i] == Fend){
			*b->wp++ = Fesc;
			*b->wp++ = Tfend;
		}else if(p[i] == Fesc){
			*b->wp++ = Fesc;
			*b->wp++ = Tfesc;
		}else
			*b->wp++ = p[i];
	}
	*b->wp++ = Fend;

	qlock(&kiss.tx);
	if(waserror()){
		qunlock(&kiss.tx);
		nexterror();
	}
	devtab[c->type]->write(c, b->rp, BLEN(b), 0);
	poperror();
	qunlock(&kiss.tx);
	poperror();
	freeb(b);
	if(type == Cdata)
		kiss.nout++;
}

static int
kissgen(Chan *c, char *unused, Dirtab *d, int nd, int s, Dir *dp)
{
	Qid q;

	USED(unused); USED(d); USED(nd);

	if(s == DEVDOTDOT){
		mkqid(&q, QID(0, Qdir), 0, QTDIR);
		devdir(c, q, "#k", 0, eve, 0555, dp);
		return 1;
	}

	switch(TYPE(c->qid)){
	case Qdir:
		if(s >= Nkiss)
			return -1;
		snprint(up->genbuf, sizeof up->genbuf, "kiss%d", s);
		mkqid(&q, QID(s, Qkissdir), 0, QTDIR);
		devdir(c, q, up->genbuf, 0, eve, 0555, dp);
		return 1;

	case Qkissdir:
	case Qdata:
	case Qctl:
	case Qstats:
		switch(s){
		case 0:
			mkqid(&q, QID(0, Qdata), 0, QTFILE);
			devdir(c, q, "data", 0, eve, 0660, dp);
			return 1;
		case 1:
			mkqid(&q, QID(0, Qctl), 0, QTFILE);
			devdir(c, q, "ctl", 0, eve, 0660, dp);
			return 1;
		case 2:
			mkqid(&q, QID(0, Qstats), 0, QTFILE);
			devdir(c, q, "stats", 0, eve, 0444, dp);
			return 1;
		}
		return -1;
	}
	return -1;
}

static Chan*
kissattach(char *spec)
{
	Chan *c;

	c = devattach('k', spec);
	mkqid(&c->qid, QID(0, Qdir), 0, QTDIR);
	return c;
}

static Walkqid*
kisswalk(Chan *c, Chan *nc, char **name, s32 nname)
{
	return devwalk(c, nc, name, nname, nil, 0, kissgen);
}

static s32
kissstat(Chan *c, uchar *db, s32 n)
{
	return devstat(c, db, n, nil, 0, kissgen);
}

static Chan*
kissopen(Chan *c, u32 omode)
{
	c = devopen(c, omode, nil, 0, kissgen);
	if(TYPE(c->qid) == Qdata){
		if(kiss.c == nil)
			error(Enotattached);
		c->iounit = Maxframe;
	}
	return c;
}

static void
kissclose(Chan*)
{
}

static int
kissstats(char *buf, int len)
{
	char *p, *e;

	p = buf;
	e = buf + len;
	p = seprint(p, e, "attached %s\n", kiss.c != nil ? "yes" : "no");
	p = seprint(p, e, "iounit %d\n", Maxframe);
	p = seprint(p, e, "in %ud\nout %ud\n", kiss.nin_frames, kiss.nout);
	p = seprint(p, e, "notdata %ud\nrunt %ud\n", kiss.nother, kiss.nrunt);
	p = seprint(p, e, "toobig %ud\nbadescape %ud\n",
		kiss.ntoobig, kiss.nbadesc);
	return p - buf;
}

static s32
kissread(Chan *c, void *a, s32 n, s64 offset)
{
	Block *b;
	char *buf;
	int rv;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, nil, 0, kissgen);

	switch(TYPE(c->qid)){
	case Qctl:
		snprint(up->genbuf, sizeof up->genbuf, "%ld\n", NUM(c->qid));
		return readstr(offset, a, n, up->genbuf);

	case Qstats:
		buf = malloc(Statlen);
		if(buf == nil)
			error(Enomem);
		if(waserror()){
			free(buf);
			nexterror();
		}
		kissstats(buf, Statlen);
		rv = readstr(offset, a, n, buf);
		poperror();
		free(buf);
		return rv;

	case Qdata:
		/*
		 * The same refusal radio(3) makes, and for the same
		 * reason: a read that does not fit is an error and not
		 * a truncation, and the frame waits for one that does.
		 */
		b = qbread(kiss.rq, Maxframe);
		if(b == nil)
			return 0;
		rv = BLEN(b);
		if(rv > n){
			ilock((Lock*)kiss.rq);
			qputback(kiss.rq, b);
			iunlock((Lock*)kiss.rq);
			snprint(up->genbuf, sizeof up->genbuf,
				"kiss: %d byte frame needs a read that big",
				rv);
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
	}
	error(Egreg);
	return 0;
}

/* get the channel behind a file descriptor, as devssl does */
static Chan*
buftochan(char *p)
{
	Chan *c;
	int fd;

	if(p == nil)
		error(Ebadarg);
	fd = strtoul(p, 0, 0);
	if(fd < 0)
		error(Ebadarg);
	c = fdtochan(up->fgrp, fd, -1, 0, 1);
	return c;
}

static void
attachfd(char *arg)
{
	Chan *c;

	qlock(&kiss.l);
	if(waserror()){
		qunlock(&kiss.l);
		nexterror();
	}
	if(kiss.c != nil)
		error("a serial line is already attached");
	c = buftochan(arg);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	/*
	 * No iounit is asked of it, unlike lora(3) and ax25(3) of what
	 * is under them.  What is under this is a byte stream, and a
	 * byte stream carries no messages and has no size to publish;
	 * putting a boundary on it is the whole of what this device
	 * does.
	 */
	if(kiss.rq == nil){
		kiss.rq = qopen(Qmax * Maxframe, Qmsg, nil, nil);
		if(kiss.rq == nil)
			error(Enomem);
	}
	kiss.c = c;
	poperror();

	if(!kiss.started){
		kiss.started = 1;
		kproc("kissrecv", kissreader, nil, 0);
	}
	poperror();
	qunlock(&kiss.l);
}

static s32
kisswrite(Chan *c, void *a, s32 n, s64)
{
	Cmdbuf *cb;
	uchar v;
	char *p;
	int i;

	switch(TYPE(c->qid)){
	case Qctl:
		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf < 1)
			error(Ebadarg);
		p = cb->f[0];
		if(strcmp(p, "fd") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			attachfd(cb->f[1]);
		}else{
			/*
			 * The rest are the TNC's own parameters and go
			 * to it as command frames.  What they mean is
			 * the TNC's business: txdelay and txtail are
			 * tens of milliseconds of transmitter keying,
			 * persist and slottime are its channel access.
			 * Nothing here interprets them, and a TNC that
			 * ignores one says nothing about it.
			 */
			if(cb->nf != 2)
				error(Ebadarg);
			i = atoi(cb->f[1]);
			if(strcmp(p, "txdelay") == 0)
				v = Ctxdelay;
			else if(strcmp(p, "persist") == 0)
				v = Cpersist;
			else if(strcmp(p, "slottime") == 0)
				v = Cslottime;
			else if(strcmp(p, "txtail") == 0)
				v = Ctxtail;
			else if(strcmp(p, "duplex") == 0){
				v = Cduplex;
				i = strcmp(cb->f[1], "on") == 0;
			}else
				error(Ebadarg);
			if(i < 0 || i > 255)
				error("a KISS parameter is one byte");
			v = v;
			{
				uchar b = i;
				kissput(v, &b, 1);
			}
		}
		poperror();
		free(cb);
		return n;

	case Qdata:
		if(kiss.c == nil)
			error(Enotattached);
		if(n > Maxframe){
			snprint(up->genbuf, sizeof up->genbuf,
				"kiss: %d bytes is past the %d byte frame",
				n, Maxframe);
			error(up->genbuf);
		}
		kissput(Cdata, a, n);
		return n;
	}
	error(Egreg);
	return 0;
}

Dev kissdevtab = {
	'k',
	"kiss",

	devreset,
	devinit,
	devshutdown,
	kissattach,
	kisswalk,
	kissstat,
	kissopen,
	devcreate,
	kissclose,
	kissread,
	devbread,
	kisswrite,
	devbwrite,
	devremove,
	devwstat,
};
