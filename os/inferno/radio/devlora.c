#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * #L, the link layer that #W deliberately does not have.
 *
 *	/net/lora/ctl		fd n, addr n
 *	/net/lora/addr		this station's address
 *	/net/lora/stats		counters for the interface
 *	/net/lora/clone		open it to get a conversation
 *	/net/lora/N/ctl		connect n, announce, ack, retries, timeout
 *	/net/lora/N/data	this conversation's payloads
 *	/net/lora/N/local	this station's address
 *	/net/lora/N/remote	the address at the other end
 *	/net/lora/N/status	what this conversation is doing
 *
 * os/inferno/radio/sx127x.c used to do all of this itself, which put
 * addressing and reliability in the part that drives the modem.  The
 * argument for taking them out is in doc/radio-interface.ms; this is
 * where they went.  #W carries packets and knows nothing about who they
 * are for, the way #l ether does not know what an IP address is, and
 * everything that decides who a packet is for is here.
 *
 * What goes on the air is the RadioHead header, four bytes of
 *
 *	to from id flags
 *
 * because that is what the other end of a PyCubed link speaks --
 * lib/pycubed_rfm9x.py and RadioHead's RH_RF95 driver both put exactly
 * these four in front of the payload.  Address 255 is broadcast, flag
 * 0x80 marks an acknowledgement and 0x40 a retransmission.
 *
 * This device is not welded to #W.  It attaches to a file descriptor
 * written to its ctl, the way #D ssl does, so anything that delimits
 * messages will drive it -- which is what makes it testable over a pipe
 * with no radio in the room.  It includes no header of the chip driver's
 * on purpose: everything it needs about the thing underneath it, it
 * learns from the Chan.
 *
 * The iounit is republished rather than invented.  A conversation's
 * data carries whatever the packet device carries less these four
 * bytes, so a Styx server over a conversation negotiates a message size
 * that accounts for the header without being told there is one.
 */

enum {
	Qdir,
	Qclone,
	Qlctl,
	Qaddr,
	Qlstats,
	Qconvdir,
	Qcctl,
	Qcdata,
	Qlocal,
	Qremote,
	Qstatus,

	Nconv		= 4,	/* conversations at once */
	Rhhdrlen	= 4,	/* to, from, id, flags */
	Bcast		= 0xff,
	Fack		= 0x80,
	Fretry		= 0x40,
	Noaddr		= -1,

	Qmax		= 8,	/* packets a conversation may fall behind */
	Statlen		= 512,
	Nowed		= 8,	/* acknowledgements owed at once */
	Naddr		= 256,	/* addresses, for the duplicate table */

	Defretries	= 3,
	Defackwait	= 2000,	/* ms; SF12 airtime is over a second */
};

#define TYPE(q)		((ulong)(q).path & 0x0f)
#define NUM(q)		(((ulong)(q).path >> 4) & 0xff)
#define QID(n, t)	(((n) << 4) | (t))

typedef struct Conv Conv;
struct Conv
{
	QLock	l;		/* opening, closing, configuring */
	QLock	wl;		/* one writer at a time: waitid is shared */
	int	x;		/* which conversation this is */
	int	inuse;
	int	announced;	/* takes packets from anyone unclaimed */
	int	remote;		/* the address at the other end, or Noaddr */
	int	ackon;
	int	retries;
	int	ackwait;	/* ms */
	Queue	*rq;

	int	waiting;	/* a send is waiting for an acknowledgement */
	int	waitid;
	int	gotack;
	Rendez	ackr;

	u32	nsent;
	u32	nrecv;
	u32	nretry;
	u32	nsendfail;
	u32	nackrecv;
};

static struct
{
	QLock	l;		/* attaching the packet device */
	Chan	*c;		/* it, once attached */
	int	iounit;		/* what it said it carries */
	int	addr;		/* this station */
	int	started;
	int	seq;

	QLock	tx;		/* the air: one transmitter at a time */

	Conv	conv[Nconv];

	u32	nin;
	u32	nout;
	u32	nnotours;	/* heard, addressed to somebody else */
	u32	nrunt;		/* too short to carry a header */
	u32	nacksent;
	u32	nnoconv;	/* for us, and nobody had announced */
	u32	ndup;		/* a retransmission already delivered */
	u32	nowedlost;	/* an acknowledgement dropped for want of room */

	/*
	 * The acknowledgements the receive path owes, as a ring: two
	 * packets can arrive while one acknowledgement is still on the
	 * air -- at SF12 that takes over a second -- and a single slot
	 * would quietly lose the second, which is exactly the failure
	 * acknowledgement exists to prevent.
	 */
	Lock	owedl;
	int	owedrd;
	int	owedwr;
	struct {
		int	to;
		int	id;
		int	flags;
	} owed[Nowed];
	Rendez	owedr;

	/*
	 * The last identifier delivered from each address.  A
	 * retransmission arrives when an acknowledgement was lost rather
	 * than when a packet was, so it must be acknowledged again and
	 * not delivered again; without this a 50 per cent channel
	 * delivers a measurable fraction of packets twice, which was
	 * observed before it was written.  RadioHead keeps the same
	 * table and for the same reason.  512 bytes, flat, because a
	 * table that can fill has a failure mode and this one cannot.
	 */
	short	seen[Naddr];
} lora;

static char Enotattached[] = "no packet device attached";

static int
owed(void*)
{
	return lora.owedrd != lora.owedwr;
}

/*
 * Remember that an acknowledgement is owed.  Called from the reader, so
 * it must not block and must not transmit.
 */
static void
oweack(int to, int id, int flags)
{
	int nw;

	ilock(&lora.owedl);
	nw = (lora.owedwr + 1) % Nowed;
	if(nw == lora.owedrd){
		lora.nowedlost++;
		iunlock(&lora.owedl);
		return;
	}
	lora.owed[lora.owedwr].to = to;
	lora.owed[lora.owedwr].id = id;
	lora.owed[lora.owedwr].flags = flags;
	lora.owedwr = nw;
	iunlock(&lora.owedl);
	wakeup(&lora.owedr);
}

static int
gotack(void *a)
{
	Conv *cv = a;

	return cv->gotack;
}

/*
 * One packet on the air.  The lock is held across the write and no
 * longer: the write blocks for the packet's real time on the air, which
 * is what serialises the medium, and holding it over an acknowledgement
 * wait would stop this station answering anybody else for the length of
 * a whole exchange.  That was a BUG entry in radio(3) when this code
 * lived in the chip driver.
 */
static void
xmit(int to, int id, int flags, uchar *p, int n)
{
	Block *b;
	Chan *c;

	c = lora.c;
	if(c == nil)
		error(Enotattached);

	b = allocb(Rhhdrlen + n);
	b->wp[0] = to;
	b->wp[1] = lora.addr;
	b->wp[2] = id;
	b->wp[3] = flags;
	if(n > 0)
		memmove(b->wp + Rhhdrlen, p, n);
	b->wp += Rhhdrlen + n;

	qlock(&lora.tx);
	if(waserror()){
		qunlock(&lora.tx);
		freeb(b);
		nexterror();
	}
	devtab[c->type]->bwrite(c, b, 0);
	poperror();
	qunlock(&lora.tx);
	lora.nout++;
}

/*
 * The acknowledgements the receive path owes, sent from here because a
 * transmit blocks for the packet's airtime and the reader must not stop
 * reading: at SF12 that is more than a second, and every packet that
 * arrives meanwhile is lost.
 */
static void
loraackproc(void*)
{
	int to, id, flags;

	for(;;){
		tsleep(&lora.owedr, owed, nil, 1000);
		ilock(&lora.owedl);
		if(lora.owedrd == lora.owedwr){
			iunlock(&lora.owedl);
			continue;
		}
		to = lora.owed[lora.owedrd].to;
		id = lora.owed[lora.owedrd].id;
		flags = lora.owed[lora.owedrd].flags;
		lora.owedrd = (lora.owedrd + 1) % Nowed;
		iunlock(&lora.owedl);

		if(!waserror()){
			/* payload "!", which is what RadioHead sends */
			xmit(to, id, flags | Fack, (uchar*)"!", 1);
			lora.nacksent++;
			poperror();
		}
	}
}

/*
 * Where a received packet goes.  A conversation that named this sender
 * owns it; failing that, one that announced takes it and remembers who
 * it heard from, so a reply has somewhere to go.
 */
static Conv*
convfor(int from)
{
	Conv *cv, *e, *ann;

	ann = nil;
	e = &lora.conv[Nconv];
	for(cv = lora.conv; cv < e; cv++){
		if(!cv->inuse)
			continue;
		if(cv->remote == from && !cv->announced)
			return cv;
		if(cv->announced && ann == nil)
			ann = cv;
	}
	if(ann != nil){
		ann->remote = from;
		return ann;
	}
	return nil;
}

static void
lorareader(void*)
{
	Block *b;
	Conv *cv;
	Chan *c;
	int to, from, id, flags, n;

	for(;;){
		c = lora.c;
		if(c == nil)
			break;
		if(waserror()){
			/*
			 * A read that fails is not a reason to stop
			 * reading; a packet device says so for a packet
			 * and carries on.
			 */
			continue;
		}
		b = devtab[c->type]->bread(c, lora.iounit, 0);
		poperror();
		if(b == nil)
			continue;
		n = BLEN(b);
		lora.nin++;
		if(n < Rhhdrlen){
			lora.nrunt++;
			freeb(b);
			continue;
		}
		to = b->rp[0];
		from = b->rp[1];
		id = b->rp[2];
		flags = b->rp[3];
		if(to != lora.addr && to != Bcast){
			/*
			 * Counted rather than merely dropped.  A sender
			 * that does not speak this header -- a bare LoRa
			 * transmitter, which Semtech's own driver is --
			 * lands here, and without a counter that looks
			 * exactly like a dead link from the ground.
			 */
			lora.nnotours++;
			freeb(b);
			continue;
		}
		if(flags & Fack){
			cv = convfor(from);
			if(cv != nil){
				cv->nackrecv++;
				if(cv->waiting && cv->waitid == id){
					cv->gotack = 1;
					wakeup(&cv->ackr);
				}
			}
			freeb(b);
			continue;
		}
		cv = convfor(from);

		/*
		 * A retransmission of something already delivered means
		 * the acknowledgement was lost, not the packet.  Say so
		 * again and do not deliver it twice.
		 *
		 * This is asked before whether anybody wants the packet,
		 * because being a duplicate is a fact about the link and
		 * not about a conversation: a retransmission that arrived
		 * after its reader went away is still a retransmission,
		 * and counting it as unclaimed instead would put the
		 * wrong number in front of whoever is reading stats.
		 */
		if((flags & Fretry) && lora.seen[from] == id){
			lora.ndup++;
			freeb(b);
			if(cv != nil && cv->ackon && to != Bcast)
				oweack(from, id, 0);
			continue;
		}
		if(cv == nil){
			lora.nnoconv++;
			freeb(b);
			continue;
		}
		lora.seen[from] = id;

		b->rp += Rhhdrlen;
		cv->nrecv++;
		qpass(cv->rq, b);

		/*
		 * Owe the sender an acknowledgement, unless this was a
		 * broadcast, which nobody acknowledges.
		 */
		if(cv->ackon && to != Bcast)
			oweack(from, id, 0);
	}
	pexit("", 0);
}

static void
lorainit(void)
{
	Conv *cv, *e;

	int i;

	lora.addr = 1;
	for(i = 0; i < Naddr; i++)
		lora.seen[i] = -1;
	e = &lora.conv[Nconv];
	for(cv = lora.conv; cv < e; cv++){
		cv->x = cv - lora.conv;
		cv->remote = Noaddr;
		cv->retries = Defretries;
		cv->ackwait = Defackwait;
	}
}

static int
loragen(Chan *c, char *unused, Dirtab *d, int nd, int s, Dir *dp)
{
	Qid q;
	Conv *cv;
	int n;

	USED(unused); USED(d); USED(nd);

	if(s == DEVDOTDOT){
		switch(TYPE(c->qid)){
		case Qdir:
		case Qclone:
		case Qlctl:
		case Qaddr:
		case Qlstats:
			mkqid(&q, QID(0, Qdir), 0, QTDIR);
			devdir(c, q, "#L", 0, eve, 0555, dp);
			return 1;
		default:
			mkqid(&q, QID(0, Qdir), 0, QTDIR);
			devdir(c, q, "#L", 0, eve, 0555, dp);
			return 1;
		}
	}

	switch(TYPE(c->qid)){
	case Qdir:
		switch(s){
		case 0:
			mkqid(&q, QID(0, Qclone), 0, QTFILE);
			devdir(c, q, "clone", 0, eve, 0666, dp);
			return 1;
		case 1:
			mkqid(&q, QID(0, Qlctl), 0, QTFILE);
			devdir(c, q, "ctl", 0, eve, 0660, dp);
			return 1;
		case 2:
			mkqid(&q, QID(0, Qaddr), 0, QTFILE);
			devdir(c, q, "addr", 0, eve, 0444, dp);
			return 1;
		case 3:
			mkqid(&q, QID(0, Qlstats), 0, QTFILE);
			devdir(c, q, "stats", 0, eve, 0444, dp);
			return 1;
		}
		s -= 4;
		if(s < 0 || s >= Nconv)
			return -1;
		snprint(up->genbuf, sizeof up->genbuf, "%d", s);
		mkqid(&q, QID(s, Qconvdir), 0, QTDIR);
		devdir(c, q, up->genbuf, 0, eve, 0555, dp);
		return 1;

	case Qconvdir:
	case Qcctl:
	case Qcdata:
	case Qlocal:
	case Qremote:
	case Qstatus:
		n = NUM(c->qid);
		cv = &lora.conv[n];
		USED(cv);
		switch(s){
		case 0:
			mkqid(&q, QID(n, Qcctl), 0, QTFILE);
			devdir(c, q, "ctl", 0, eve, 0660, dp);
			return 1;
		case 1:
			mkqid(&q, QID(n, Qcdata), 0, QTFILE);
			devdir(c, q, "data", 0, eve, 0660, dp);
			return 1;
		case 2:
			mkqid(&q, QID(n, Qlocal), 0, QTFILE);
			devdir(c, q, "local", 0, eve, 0444, dp);
			return 1;
		case 3:
			mkqid(&q, QID(n, Qremote), 0, QTFILE);
			devdir(c, q, "remote", 0, eve, 0444, dp);
			return 1;
		case 4:
			mkqid(&q, QID(n, Qstatus), 0, QTFILE);
			devdir(c, q, "status", 0, eve, 0444, dp);
			return 1;
		}
		return -1;
	}
	return -1;
}

static Chan*
loraattach(char *spec)
{
	Chan *c;

	c = devattach('L', spec);
	mkqid(&c->qid, QID(0, Qdir), 0, QTDIR);
	return c;
}

static Walkqid*
lorawalk(Chan *c, Chan *nc, char **name, s32 nname)
{
	return devwalk(c, nc, name, nname, nil, 0, loragen);
}

static s32
lorastat(Chan *c, uchar *db, s32 n)
{
	return devstat(c, db, n, nil, 0, loragen);
}

static Conv*
newconv(void)
{
	Conv *cv, *e;

	e = &lora.conv[Nconv];
	for(cv = lora.conv; cv < e; cv++){
		qlock(&cv->l);
		if(!cv->inuse){
			if(cv->rq == nil){
				cv->rq = qopen(Qmax * 256, Qmsg, nil, nil);
				if(cv->rq == nil){
					qunlock(&cv->l);
					error(Enomem);
				}
			}
			qreopen(cv->rq);
			cv->inuse = 1;
			cv->announced = 0;
			cv->remote = Noaddr;
			cv->ackon = 0;
			cv->retries = Defretries;
			cv->ackwait = Defackwait;
			cv->nsent = cv->nrecv = cv->nretry = 0;
			cv->nsendfail = cv->nackrecv = 0;
			qunlock(&cv->l);
			return cv;
		}
		qunlock(&cv->l);
	}
	return nil;
}

static Chan*
loraopen(Chan *c, u32 omode)
{
	Conv *cv;

	if(TYPE(c->qid) == Qclone){
		cv = newconv();
		if(cv == nil)
			error("no free lora conversations");
		mkqid(&c->qid, QID(cv->x, Qcctl), 0, QTFILE);
	}

	c = devopen(c, omode, nil, 0, loragen);

	if(TYPE(c->qid) == Qcdata){
		if(lora.c == nil)
			error(Enotattached);
		c->iounit = lora.iounit - Rhhdrlen;
	}
	return c;
}

static void
loraclose(Chan *c)
{
	Conv *cv;

	if(TYPE(c->qid) != Qcctl)
		return;
	if((c->flag & COPEN) == 0)
		return;
	cv = &lora.conv[NUM(c->qid)];
	qlock(&cv->l);
	cv->inuse = 0;
	cv->announced = 0;
	cv->remote = Noaddr;
	if(cv->rq != nil)
		qhangup(cv->rq, nil);
	qunlock(&cv->l);
}

static int
convstatus(Conv *cv, char *buf, int len)
{
	char *p, *e;

	p = buf;
	e = buf + len;
	p = seprint(p, e, "%d %s", cv->x, cv->inuse ? "open" : "closed");
	if(cv->announced)
		p = seprint(p, e, " announced");
	if(cv->remote == Noaddr)
		p = seprint(p, e, " remote none");
	else
		p = seprint(p, e, " remote %d", cv->remote);
	p = seprint(p, e, " ack %s retries %d timeout %d\n",
		cv->ackon ? "on" : "off", cv->retries, cv->ackwait);
	p = seprint(p, e, "sent %ud\nreceived %ud\n", cv->nsent, cv->nrecv);
	p = seprint(p, e, "retried %ud\nsendfail %ud\nackrecv %ud\n",
		cv->nretry, cv->nsendfail, cv->nackrecv);
	return p - buf;
}

static int
lorastats(char *buf, int len)
{
	char *p, *e;

	p = buf;
	e = buf + len;
	p = seprint(p, e, "attached %s\n", lora.c != nil ? "yes" : "no");
	p = seprint(p, e, "addr %d\niounit %d\npayload %d\n",
		lora.addr, lora.iounit, lora.iounit - Rhhdrlen);
	p = seprint(p, e, "in %ud\nout %ud\n", lora.nin, lora.nout);
	p = seprint(p, e, "notours %ud\nrunt %ud\n",
		lora.nnotours, lora.nrunt);
	p = seprint(p, e, "acksent %ud\nnoconv %ud\n",
		lora.nacksent, lora.nnoconv);
	p = seprint(p, e, "duplicate %ud\nackdropped %ud\n",
		lora.ndup, lora.nowedlost);
	return p - buf;
}

static s32
loraread(Chan *c, void *a, s32 n, s64 offset)
{
	Conv *cv;
	Block *b;
	char *buf;
	int rv;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, nil, 0, loragen);

	switch(TYPE(c->qid)){
	case Qaddr:
		snprint(up->genbuf, sizeof up->genbuf, "%d\n", lora.addr);
		return readstr(offset, a, n, up->genbuf);

	case Qlctl:
		snprint(up->genbuf, sizeof up->genbuf, "%d\n", lora.addr);
		return readstr(offset, a, n, up->genbuf);

	case Qlstats:
		buf = malloc(Statlen);
		if(buf == nil)
			error(Enomem);
		if(waserror()){
			free(buf);
			nexterror();
		}
		lorastats(buf, Statlen);
		rv = readstr(offset, a, n, buf);
		poperror();
		free(buf);
		return rv;

	case Qcctl:
		snprint(up->genbuf, sizeof up->genbuf, "%ld\n", NUM(c->qid));
		return readstr(offset, a, n, up->genbuf);

	case Qlocal:
		snprint(up->genbuf, sizeof up->genbuf, "%d\n", lora.addr);
		return readstr(offset, a, n, up->genbuf);

	case Qremote:
		cv = &lora.conv[NUM(c->qid)];
		if(cv->remote == Noaddr)
			snprint(up->genbuf, sizeof up->genbuf, "none\n");
		else
			snprint(up->genbuf, sizeof up->genbuf, "%d\n",
				cv->remote);
		return readstr(offset, a, n, up->genbuf);

	case Qstatus:
		cv = &lora.conv[NUM(c->qid)];
		buf = malloc(Statlen);
		if(buf == nil)
			error(Enomem);
		if(waserror()){
			free(buf);
			nexterror();
		}
		convstatus(cv, buf, Statlen);
		rv = readstr(offset, a, n, buf);
		poperror();
		free(buf);
		return rv;

	case Qcdata:
		/*
		 * The same refusal #W makes, and for the same reason: a
		 * read that does not fit is an error, not a truncation,
		 * and the packet waits for one that does.
		 */
		cv = &lora.conv[NUM(c->qid)];
		b = qbread(cv->rq, lora.iounit);
		if(b == nil)
			return 0;
		rv = BLEN(b);
		if(rv > n){
			ilock((Lock*)cv->rq);
			qputback(cv->rq, b);
			iunlock((Lock*)cv->rq);
			snprint(up->genbuf, sizeof up->genbuf,
				"lora: %d byte packet needs a read that big",
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
	c = fdtochan(up->fgrp, fd, -1, 0, 1);	/* checks, and increfs */
	return c;
}

static void
attachfd(char *arg)
{
	Chan *c;

	qlock(&lora.l);
	if(waserror()){
		qunlock(&lora.l);
		nexterror();
	}
	if(lora.c != nil)
		error("a packet device is already attached");
	c = buftochan(arg);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	/*
	 * The iounit is not decoration here either.  Whatever is
	 * underneath says how much one packet carries; this layer spends
	 * four of it and republishes the rest, so a filter above lands on
	 * a number that accounts for a header it never sees.  A device
	 * that publishes none cannot be used, because guessing would put
	 * the error at the far end of a link.
	 */
	if(c->iounit < Rhhdrlen + 1)
		error("the packet device publishes no usable iounit");
	lora.iounit = c->iounit;
	lora.c = c;
	poperror();

	if(!lora.started){
		lora.started = 1;
		kproc("lorarecv", lorareader, nil, 0);
		kproc("loraack", loraackproc, nil, 0);
	}
	poperror();
	qunlock(&lora.l);
}

static s32
lorawrite(Chan *c, void *a, s32 n, s64)
{
	Conv *cv;
	Cmdbuf *cb;
	int try, id, flags, rv;
	char *p;

	switch(TYPE(c->qid)){
	case Qlctl:
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
		}else if(strcmp(p, "addr") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			try = atoi(cb->f[1]);
			if(try < 0 || try > 254)
				error("address is 0 to 254; 255 is broadcast");
			lora.addr = try;
		}else
			error(Ebadarg);
		poperror();
		free(cb);
		return n;

	case Qcctl:
		cv = &lora.conv[NUM(c->qid)];
		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf < 1)
			error(Ebadarg);
		p = cb->f[0];
		if(strcmp(p, "connect") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			try = atoi(cb->f[1]);
			if(try < 0 || try > 255)
				error("address is 0 to 255");
			cv->remote = try;
			cv->announced = 0;
		}else if(strcmp(p, "announce") == 0){
			cv->announced = 1;
			cv->remote = Noaddr;
		}else if(strcmp(p, "ack") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			cv->ackon = strcmp(cb->f[1], "on") == 0;
		}else if(strcmp(p, "retries") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			try = atoi(cb->f[1]);
			if(try < 1 || try > 16)
				error("retries is 1 to 16");
			cv->retries = try;
		}else if(strcmp(p, "timeout") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			try = atoi(cb->f[1]);
			if(try < 50 || try > 60000)
				error("timeout is 50 to 60000 ms");
			cv->ackwait = try;
		}else
			error(Ebadarg);
		poperror();
		free(cb);
		return n;

	case Qcdata:
		cv = &lora.conv[NUM(c->qid)];
		if(lora.c == nil)
			error(Enotattached);
		if(n > lora.iounit - Rhhdrlen){
			snprint(up->genbuf, sizeof up->genbuf,
				"lora: %d bytes is past the %d byte payload",
				n, lora.iounit - Rhhdrlen);
			error(up->genbuf);
		}
		if(cv->remote == Noaddr)
			error("nobody to send to: connect, or wait to be "
				"spoken to");

		qlock(&cv->wl);
		if(waserror()){
			cv->waiting = 0;
			qunlock(&cv->wl);
			nexterror();
		}
		id = ++lora.seq & 0xff;

		if(!cv->ackon || cv->remote == Bcast){
			xmit(cv->remote, id, 0, a, n);
			cv->nsent++;
			poperror();
			qunlock(&cv->wl);
			return n;
		}

		/*
		 * Reliable, in the manner of lib/pycubed_rfm9x.py's
		 * send_with_ack: the identifier carries a sequence number,
		 * the sender waits for a packet with the ACK flag and the
		 * same identifier, and a retransmission sets RETRY.
		 */
		flags = 0;
		rv = -1;
		for(try = 0; try < cv->retries; try++){
			if(try > 0){
				cv->nretry++;
				flags |= Fretry;
			}
			cv->gotack = 0;
			cv->waitid = id;
			cv->waiting = 1;
			xmit(cv->remote, id, flags, a, n);
			cv->nsent++;
			tsleep(&cv->ackr, gotack, cv, cv->ackwait);

			/*
			 * timeout is how long an acknowledgement is
			 * allowed to take, and means exactly what
			 * lora(3) says.  What follows is the backoff,
			 * which is a separate thing: a radio is half
			 * duplex, so two stations that collided once
			 * have no reason to stop unless one of them
			 * waits differently.  That is the standard
			 * answer to a shared medium and it costs two
			 * lines.
			 *
			 * It is not what fixed the failure it was
			 * written during -- that was a stalled queue in
			 * the SX1276 model, tools/qemu-patches/0037,
			 * which dropped the link at the first collision
			 * rather than the frame -- and nothing measured
			 * here has needed it.
			 *
			 * The wait is on the same rendezvous as the
			 * timeout, so an acknowledgement arriving during
			 * the backoff still ends the send.  Sleeping on
			 * anything else counts that acknowledgement and
			 * then retransmits anyway, which is what this
			 * did for one run.
			 */
			if(!cv->gotack && try + 1 < cv->retries)
				tsleep(&cv->ackr, gotack, cv,
					nrand(cv->ackwait/2) + 1);
			cv->waiting = 0;
			if(cv->gotack){
				rv = n;
				break;
			}
		}
		if(rv < 0)
			cv->nsendfail++;
		poperror();
		qunlock(&cv->wl);
		if(rv < 0)
			error("lora: no acknowledgement after every retry");
		return rv;
	}
	error(Egreg);
	return 0;
}

Dev loradevtab = {
	'L',
	"lora",

	devreset,
	lorainit,
	devshutdown,
	loraattach,
	lorawalk,
	lorastat,
	loraopen,
	devcreate,
	loraclose,
	loraread,
	devbread,
	lorawrite,
	devbwrite,
	devremove,
	devwstat,
};
