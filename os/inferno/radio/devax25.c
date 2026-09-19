#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * #a, AX.25 over a packet device.
 *
 *	/net/ax25/ctl		fd n, addr CALL-n
 *	/net/ax25/addr		this station's callsign
 *	/net/ax25/stats		counters for the interface
 *	/net/ax25/clone		open it to get a conversation
 *	/net/ax25/N/ctl		connect, announce, via, pid
 *	/net/ax25/N/data	this conversation's information fields
 *	/net/ax25/N/local	our callsign
 *	/net/ax25/N/remote	theirs
 *	/net/ax25/N/status	what this conversation is doing
 *
 * The argument for this existing beside #L is in doc/ax25-plan.ms.  The
 * short of it: a RadioHead address is a byte a station picks, and an
 * AX.25 address is a callsign, and on an amateur band an unidentified
 * transmission is not permitted.  A satellite on 70cm has to say who it
 * is in a form a regulator and a receiving station both already read.
 * The other half is that direwolf, a TNC and a handheld with a KISS
 * port all decode AX.25 today and none of them has heard of RadioHead.
 *
 * This is the first of the five steps that document lists: the address
 * field and UI frames.  Connected mode -- SABM, UA, DISC, DM, I, RR,
 * REJ and the sequence numbers -- is not here, and a control field that
 * is not UI is counted and dropped rather than answered, because
 * answering it wrongly is worse than not answering it.
 *
 * What goes on the air is an AX.25 frame without the HDLC flags, the
 * bit stuffing or the FCS: the LoRa PHY already delimits the packet and
 * checks it, and a second CRC inside the first is paying twice.  So:
 *
 *	dest[7] src[7] [digi[7] ...] control[1] pid[1] info...
 *
 * Each address is six bytes of callsign, ASCII, shifted left one bit
 * and padded with spaces, then an SSID byte holding the command or
 * has-been-repeated bit, two reserved bits sent as ones, four bits of
 * SSID, and the end-of-address bit on the last address only.
 *
 * Like #L this attaches to a packet device by a file descriptor written
 * to its ctl, and includes no header of the chip driver's.  The two
 * cannot both hold one radio, because #W's receive path is a claim.
 */

enum {
	Qdir,
	Qclone,
	Qactl,
	Qaddr,
	Qastats,
	Qconvdir,
	Qcctl,
	Qcdata,
	Qlocal,
	Qremote,
	Qstatus,

	Nconv		= 4,	/* conversations at once */
	Ncall		= 6,	/* callsign characters */
	Addrlen		= 7,	/* callsign and SSID on the wire */
	Ndigi		= 2,	/* what AX.25 2.2 allows */
	Minhdr		= 2*Addrlen + 2,
	Maxhdr		= (2 + Ndigi)*Addrlen + 2,

	Cui		= 0x03,	/* unnumbered information */
	Cpf		= 0x10,	/* poll/final */
	Cutype		= 0x03,	/* the two bits that say "unnumbered" */
	Pidnol3		= 0xf0,	/* no layer 3 */

	Aend		= 0x01,	/* end of address field */
	Acmd		= 0x80,	/* command, or has-been-repeated */
	Arsvd		= 0x60,	/* the two reserved bits, sent as ones */

	Qmax		= 8,
	Statlen		= 512,
};

#define TYPE(q)		((ulong)(q).path & 0x0f)
#define NUM(q)		(((ulong)(q).path >> 4) & 0xff)
#define QID(n, t)	(((n) << 4) | (t))

typedef struct Call Call;
struct Call
{
	char	call[Ncall+1];
	int	ssid;
};

typedef struct Conv Conv;
struct Conv
{
	QLock	l;
	QLock	wl;
	int	x;
	int	inuse;
	int	announced;
	int	dataopen;
	int	haveremote;
	Call	remote;
	Call	digi[Ndigi];
	int	ndigi;
	int	pid;
	Queue	*rq;

	u32	nsent;
	u32	nrecv;
};

static struct
{
	QLock	l;
	Chan	*c;
	int	iounit;
	Call	me;
	int	haveaddr;
	int	started;

	QLock	tx;

	Conv	conv[Nconv];

	u32	nin;
	u32	nout;
	u32	nnotours;	/* heard, addressed to somebody else */
	u32	nrunt;		/* too short to carry an address field */
	u32	nbad;		/* an address field that does not end */
	u32	nnotui;		/* a control field this does not implement */
	u32	nnoconv;	/* for us, and nobody had announced */
	u32	ndigi;		/* for a digipeater we are not */
} ax25;

static char Enotattached[] = "no packet device attached";
static char Enoaddr[] = "this station has no callsign: write addr to ctl";

/*
 * QST is the destination a beacon uses and CQ is the one a call for
 * anybody uses.  Both are ordinary callsign-shaped destinations that
 * no station answers to, which is the whole of what broadcast means
 * here: there is no bit for it.
 */
static int
isbcast(Call *c)
{
	return strcmp(c->call, "QST") == 0 || strcmp(c->call, "CQ") == 0;
}

static int
samecall(Call *a, Call *b)
{
	return a->ssid == b->ssid && strcmp(a->call, b->call) == 0;
}

/*
 * CALL or CALL-n, where n is 0 to 15.  Upper case and alphanumeric,
 * because that is what a callsign is and because a lower-case letter
 * shifted left one bit is not a callsign character at the other end.
 */
static void
parsecall(char *s, Call *c)
{
	char *d;
	int n;

	memset(c, 0, sizeof *c);
	d = c->call;
	n = 0;
	for(; *s != 0 && *s != '-'; s++){
		if(n >= Ncall)
			error("callsign is at most six characters");
		if(*s >= 'a' && *s <= 'z')
			*d++ = *s - 'a' + 'A';
		else if((*s >= 'A' && *s <= 'Z') || (*s >= '0' && *s <= '9'))
			*d++ = *s;
		else
			error("callsign is letters and digits");
		n++;
	}
	*d = 0;
	if(n == 0)
		error("callsign is empty");
	if(*s == '-'){
		c->ssid = atoi(s+1);
		if(c->ssid < 0 || c->ssid > 15)
			error("SSID is 0 to 15");
	}
}

static int
callfmt(Call *c, char *buf, int len)
{
	if(c->ssid == 0)
		return snprint(buf, len, "%s", c->call);
	return snprint(buf, len, "%s-%d", c->call, c->ssid);
}

static void
putcall(uchar *p, Call *c, int flag, int last)
{
	int i;

	for(i = 0; i < Ncall; i++)
		p[i] = (c->call[i] != 0 ? c->call[i] : ' ') << 1;
	p[Ncall] = Arsvd | ((c->ssid & 0xf) << 1) | flag;
	if(last)
		p[Ncall] |= Aend;
}

static void
getcall(uchar *p, Call *c)
{
	int i, n;

	n = 0;
	for(i = 0; i < Ncall; i++)
		if((p[i] >> 1) != ' ')
			c->call[n++] = p[i] >> 1;
	c->call[n] = 0;
	c->ssid = (p[Ncall] >> 1) & 0xf;
}

/* how many bytes of header a conversation's frames carry */
static int
hdrlen(Conv *cv)
{
	return (2 + cv->ndigi)*Addrlen + 2;
}

static void
xmit(Conv *cv, uchar *p, int n)
{
	Block *b;
	Chan *c;
	uchar *w;
	int i;

	c = ax25.c;
	if(c == nil)
		error(Enotattached);

	b = allocb(hdrlen(cv) + n);
	w = b->wp;
	putcall(w, &cv->remote, Acmd, cv->ndigi == 0);
	w += Addrlen;
	putcall(w, &ax25.me, 0, cv->ndigi == 0);
	w += Addrlen;
	for(i = 0; i < cv->ndigi; i++){
		putcall(w, &cv->digi[i], 0, i == cv->ndigi-1);
		w += Addrlen;
	}
	*w++ = Cui;
	*w++ = cv->pid;
	if(n > 0)
		memmove(w, p, n);
	w += n;
	b->wp = w;

	qlock(&ax25.tx);
	if(waserror()){
		qunlock(&ax25.tx);
		freeb(b);
		nexterror();
	}
	devtab[c->type]->bwrite(c, b, 0);
	poperror();
	qunlock(&ax25.tx);
	ax25.nout++;
}

static Conv*
convfor(Call *from)
{
	Conv *cv, *e, *ann;

	ann = nil;
	e = &ax25.conv[Nconv];
	for(cv = ax25.conv; cv < e; cv++){
		if(!cv->inuse)
			continue;
		if(!cv->announced && cv->haveremote && samecall(&cv->remote, from))
			return cv;
		if(cv->announced && ann == nil)
			ann = cv;
	}
	if(ann != nil){
		ann->remote = *from;
		ann->haveremote = 1;
		return ann;
	}
	return nil;
}

static void
ax25reader(void*)
{
	Block *b;
	Conv *cv;
	Chan *c;
	Call dest, src, digi;
	uchar *p, *e;
	int n, ctl, repeated, ndigi;

	for(;;){
		c = ax25.c;
		if(c == nil)
			break;
		if(waserror())
			continue;
		b = devtab[c->type]->bread(c, ax25.iounit, 0);
		poperror();
		if(b == nil)
			continue;
		n = BLEN(b);
		ax25.nin++;
		if(n < Minhdr){
			ax25.nrunt++;
			freeb(b);
			continue;
		}
		p = b->rp;
		e = b->rp + n;
		getcall(p, &dest);
		getcall(p + Addrlen, &src);

		/*
		 * The end-of-address bit is on the last address, so the
		 * source's copy of it says whether a digipeater path
		 * follows.  A path that never ends inside the frame is a
		 * malformed frame and not a long one.
		 */
		ndigi = 0;
		repeated = 1;
		p += 2*Addrlen;
		if((b->rp[2*Addrlen - 1] & Aend) == 0){
			for(;;){
				if(p + Addrlen > e){
					ax25.nbad++;
					break;
				}
				getcall(p, &digi);
				if((p[Ncall] & Acmd) == 0)
					repeated = 0;
				ndigi++;
				p += Addrlen;
				if((p[-1] & Aend) != 0)
					break;
			}
			if(p + Addrlen > e && ndigi > 0 && (p[-1] & Aend) == 0){
				freeb(b);
				continue;
			}
		}
		if(p + 2 > e){
			ax25.nrunt++;
			freeb(b);
			continue;
		}

		/*
		 * A path with a hop still to go is addressed to that
		 * digipeater and not to the destination, whoever the
		 * destination is.  This does not repeat, so it is not
		 * ours; counted separately from a frame for another
		 * station, because the two mean different things about
		 * a link.
		 */
		if(!repeated){
			ax25.ndigi++;
			freeb(b);
			continue;
		}
		if(!samecall(&dest, &ax25.me) && !isbcast(&dest)){
			ax25.nnotours++;
			freeb(b);
			continue;
		}

		ctl = *p++;
		if((ctl & ~Cpf) != Cui){
			/*
			 * Connected mode is step two in doc/ax25-plan.ms.
			 * Until it is here, a supervisory or numbered
			 * frame is counted and dropped: replying to a
			 * SABM this cannot honour would promise a
			 * connection that does not exist.
			 */
			ax25.nnotui++;
			freeb(b);
			continue;
		}
		p++;			/* PID */

		cv = convfor(&src);
		if(cv == nil){
			ax25.nnoconv++;
			freeb(b);
			continue;
		}
		b->rp = p;
		cv->nrecv++;
		qpass(cv->rq, b);
	}
	pexit("", 0);
}

static void
ax25init(void)
{
	Conv *cv, *e;

	e = &ax25.conv[Nconv];
	for(cv = ax25.conv; cv < e; cv++){
		cv->x = cv - ax25.conv;
		cv->pid = Pidnol3;
	}
}

static int
ax25gen(Chan *c, char *unused, Dirtab *d, int nd, int s, Dir *dp)
{
	Qid q;
	int n;

	USED(unused); USED(d); USED(nd);

	if(s == DEVDOTDOT){
		mkqid(&q, QID(0, Qdir), 0, QTDIR);
		devdir(c, q, "#a", 0, eve, 0555, dp);
		return 1;
	}

	switch(TYPE(c->qid)){
	case Qdir:
		switch(s){
		case 0:
			mkqid(&q, QID(0, Qclone), 0, QTFILE);
			devdir(c, q, "clone", 0, eve, 0666, dp);
			return 1;
		case 1:
			mkqid(&q, QID(0, Qactl), 0, QTFILE);
			devdir(c, q, "ctl", 0, eve, 0660, dp);
			return 1;
		case 2:
			mkqid(&q, QID(0, Qaddr), 0, QTFILE);
			devdir(c, q, "addr", 0, eve, 0444, dp);
			return 1;
		case 3:
			mkqid(&q, QID(0, Qastats), 0, QTFILE);
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
ax25attach(char *spec)
{
	Chan *c;

	c = devattach('a', spec);
	mkqid(&c->qid, QID(0, Qdir), 0, QTDIR);
	return c;
}

static Walkqid*
ax25walk(Chan *c, Chan *nc, char **name, s32 nname)
{
	return devwalk(c, nc, name, nname, nil, 0, ax25gen);
}

static s32
ax25stat(Chan *c, uchar *db, s32 n)
{
	return devstat(c, db, n, nil, 0, ax25gen);
}

static Conv*
newconv(void)
{
	Conv *cv, *e;

	e = &ax25.conv[Nconv];
	for(cv = ax25.conv; cv < e; cv++){
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
			cv->haveremote = 0;
			cv->ndigi = 0;
			cv->dataopen = 0;
			cv->pid = Pidnol3;
			cv->nsent = cv->nrecv = 0;
			qunlock(&cv->l);
			return cv;
		}
		qunlock(&cv->l);
	}
	return nil;
}

static Chan*
ax25open(Chan *c, u32 omode)
{
	Conv *cv;

	if(TYPE(c->qid) == Qclone){
		cv = newconv();
		if(cv == nil)
			error("no free ax25 conversations");
		mkqid(&c->qid, QID(cv->x, Qcctl), 0, QTFILE);
	}

	c = devopen(c, omode, nil, 0, ax25gen);

	if(TYPE(c->qid) == Qcdata){
		if(ax25.c == nil)
			error(Enotattached);
		cv = &ax25.conv[NUM(c->qid)];
		/*
		 * The budget depends on the digipeater path, which is
		 * set on the conversation's ctl before data is opened.
		 * That ordering is not incidental: appl/lib/ssl.b opened
		 * data before pushing its descriptor and so published a
		 * budget computed from nothing, which is the mistake
		 * doc/radio-interface.ms records.  So via is refused
		 * while data is open, and this number is exact rather
		 * than a worst case.
		 */
		c->iounit = ax25.iounit - hdrlen(cv);
		cv->dataopen++;
	}
	return c;
}

static void
ax25close(Chan *c)
{
	Conv *cv;

	if((c->flag & COPEN) == 0)
		return;
	if(TYPE(c->qid) == Qcdata){
		cv = &ax25.conv[NUM(c->qid)];
		if(cv->dataopen > 0)
			cv->dataopen--;
		return;
	}
	if(TYPE(c->qid) != Qcctl)
		return;
	cv = &ax25.conv[NUM(c->qid)];
	qlock(&cv->l);
	cv->inuse = 0;
	cv->announced = 0;
	cv->haveremote = 0;
	cv->ndigi = 0;
	if(cv->rq != nil)
		qhangup(cv->rq, nil);
	qunlock(&cv->l);
}

static int
convstatus(Conv *cv, char *buf, int len)
{
	char *p, *e, cb[16];
	int i;

	p = buf;
	e = buf + len;
	p = seprint(p, e, "%d %s", cv->x, cv->inuse ? "open" : "closed");
	if(cv->announced)
		p = seprint(p, e, " announced");
	if(cv->haveremote){
		callfmt(&cv->remote, cb, sizeof cb);
		p = seprint(p, e, " remote %s", cb);
	}else
		p = seprint(p, e, " remote none");
	p = seprint(p, e, " pid %#.2ux", cv->pid);
	if(cv->ndigi > 0){
		p = seprint(p, e, " via");
		for(i = 0; i < cv->ndigi; i++){
			callfmt(&cv->digi[i], cb, sizeof cb);
			p = seprint(p, e, "%s%s", i == 0 ? " " : ",", cb);
		}
	}
	p = seprint(p, e, "\nstate disconnected ui\n");
	p = seprint(p, e, "header %d\n", hdrlen(cv));
	p = seprint(p, e, "sent %ud\nreceived %ud\n", cv->nsent, cv->nrecv);
	return p - buf;
}

static int
ax25stats(char *buf, int len)
{
	char *p, *e, cb[16];

	p = buf;
	e = buf + len;
	p = seprint(p, e, "attached %s\n", ax25.c != nil ? "yes" : "no");
	if(ax25.haveaddr){
		callfmt(&ax25.me, cb, sizeof cb);
		p = seprint(p, e, "addr %s\n", cb);
	}else
		p = seprint(p, e, "addr none\n");
	p = seprint(p, e, "iounit %d\npayload %d\n",
		ax25.iounit, ax25.iounit - Minhdr);
	p = seprint(p, e, "in %ud\nout %ud\n", ax25.nin, ax25.nout);
	p = seprint(p, e, "notours %ud\nrunt %ud\nbadaddr %ud\n",
		ax25.nnotours, ax25.nrunt, ax25.nbad);
	p = seprint(p, e, "notui %ud\nnoconv %ud\ntodigi %ud\n",
		ax25.nnotui, ax25.nnoconv, ax25.ndigi);
	return p - buf;
}

static s32
ax25read(Chan *c, void *a, s32 n, s64 offset)
{
	Conv *cv;
	Block *b;
	char *buf;
	int rv;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, nil, 0, ax25gen);

	switch(TYPE(c->qid)){
	case Qaddr:
	case Qlocal:
		if(!ax25.haveaddr)
			snprint(up->genbuf, sizeof up->genbuf, "none\n");
		else{
			rv = callfmt(&ax25.me, up->genbuf,
				sizeof up->genbuf - 1);
			up->genbuf[rv] = '\n';
			up->genbuf[rv+1] = 0;
		}
		return readstr(offset, a, n, up->genbuf);

	case Qactl:
	case Qcctl:
		snprint(up->genbuf, sizeof up->genbuf, "%ld\n", NUM(c->qid));
		return readstr(offset, a, n, up->genbuf);

	case Qremote:
		cv = &ax25.conv[NUM(c->qid)];
		if(!cv->haveremote)
			snprint(up->genbuf, sizeof up->genbuf, "none\n");
		else{
			rv = callfmt(&cv->remote, up->genbuf,
				sizeof up->genbuf - 1);
			up->genbuf[rv] = '\n';
			up->genbuf[rv+1] = 0;
		}
		return readstr(offset, a, n, up->genbuf);

	case Qastats:
	case Qstatus:
		buf = malloc(Statlen);
		if(buf == nil)
			error(Enomem);
		if(waserror()){
			free(buf);
			nexterror();
		}
		if(TYPE(c->qid) == Qastats)
			ax25stats(buf, Statlen);
		else
			convstatus(&ax25.conv[NUM(c->qid)], buf, Statlen);
		rv = readstr(offset, a, n, buf);
		poperror();
		free(buf);
		return rv;

	case Qcdata:
		cv = &ax25.conv[NUM(c->qid)];
		b = qbread(cv->rq, ax25.iounit);
		if(b == nil)
			return 0;
		rv = BLEN(b);
		if(rv > n){
			ilock((Lock*)cv->rq);
			qputback(cv->rq, b);
			iunlock((Lock*)cv->rq);
			snprint(up->genbuf, sizeof up->genbuf,
				"ax25: %d byte frame needs a read that big",
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

	qlock(&ax25.l);
	if(waserror()){
		qunlock(&ax25.l);
		nexterror();
	}
	if(ax25.c != nil)
		error("a packet device is already attached");
	c = buftochan(arg);
	if(waserror()){
		cclose(c);
		nexterror();
	}
	if(c->iounit < Maxhdr + 1)
		error("the packet device publishes no usable iounit");
	ax25.iounit = c->iounit;
	ax25.c = c;
	poperror();

	if(!ax25.started){
		ax25.started = 1;
		kproc("ax25recv", ax25reader, nil, 0);
	}
	poperror();
	qunlock(&ax25.l);
}

static void
setvia(Conv *cv, char *s)
{
	Call d[Ndigi];
	char *p;
	int n;

	if(cv->dataopen)
		error("via changes the frame size: set it before "
			"opening data");
	n = 0;
	while(*s != 0){
		if(n >= Ndigi)
			error("AX.25 2.2 allows two digipeaters");
		p = strchr(s, ',');
		if(p != nil)
			*p = 0;
		parsecall(s, &d[n++]);
		if(p == nil)
			break;
		s = p + 1;
	}
	memmove(cv->digi, d, sizeof d);
	cv->ndigi = n;
}

static s32
ax25write(Chan *c, void *a, s32 n, s64)
{
	Conv *cv;
	Cmdbuf *cb;
	char *p;
	int budget;

	switch(TYPE(c->qid)){
	case Qactl:
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
			parsecall(cb->f[1], &ax25.me);
			ax25.haveaddr = 1;
		}else
			error(Ebadarg);
		poperror();
		free(cb);
		return n;

	case Qcctl:
		cv = &ax25.conv[NUM(c->qid)];
		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf < 1)
			error(Ebadarg);
		p = cb->f[0];
		if(strcmp(p, "connect") == 0){
			if(cb->nf != 2 && cb->nf != 4)
				error(Ebadarg);
			parsecall(cb->f[1], &cv->remote);
			cv->haveremote = 1;
			cv->announced = 0;
			if(cb->nf == 4){
				if(strcmp(cb->f[2], "via") != 0)
					error(Ebadarg);
				setvia(cv, cb->f[3]);
			}
		}else if(strcmp(p, "announce") == 0){
			cv->announced = 1;
			cv->haveremote = 0;
		}else if(strcmp(p, "via") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			setvia(cv, cb->f[1]);
		}else if(strcmp(p, "pid") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			cv->pid = strtoul(cb->f[1], nil, 0) & 0xff;
		}else if(strcmp(p, "ui") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			if(strcmp(cb->f[1], "on") != 0)
				error("connected mode is not implemented: "
					"see doc/ax25-plan.ms");
		}else
			error(Ebadarg);
		poperror();
		free(cb);
		return n;

	case Qcdata:
		cv = &ax25.conv[NUM(c->qid)];
		if(ax25.c == nil)
			error(Enotattached);
		if(!ax25.haveaddr)
			error(Enoaddr);
		if(!cv->haveremote)
			error("nobody to send to: connect, or wait to be "
				"spoken to");
		budget = ax25.iounit - hdrlen(cv);
		if(n > budget){
			snprint(up->genbuf, sizeof up->genbuf,
				"ax25: %d bytes is past the %d byte "
				"information field", n, budget);
			error(up->genbuf);
		}
		qlock(&cv->wl);
		if(waserror()){
			qunlock(&cv->wl);
			nexterror();
		}
		xmit(cv, a, n);
		cv->nsent++;
		poperror();
		qunlock(&cv->wl);
		return n;
	}
	error(Egreg);
	return 0;
}

Dev ax25devtab = {
	'a',
	"ax25",

	devreset,
	ax25init,
	devshutdown,
	ax25attach,
	ax25walk,
	ax25stat,
	ax25open,
	devcreate,
	ax25close,
	ax25read,
	devbread,
	ax25write,
	devbwrite,
	devremove,
	devwstat,
};
