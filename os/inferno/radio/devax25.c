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
 * Connected mode is here: SABM, UA, DISC, DM, I with N(S) and N(R),
 * RR, RNR and REJ, modulo 8, with T1, T3, N2 and a window of k.  UI is
 * still here too, as a mode of a conversation rather than a separate
 * file, because the addressing, the digipeater path and the PID are
 * the same in both.
 *
 * Three processes, which is not decoration.  The reader takes frames
 * off the packet device and must never stop, so it never transmits and
 * never waits for the air.  The sender drains an output queue, and the
 * air is the only thing it waits for.  The ticker runs T1 and T3 at
 * 100ms.  Everything the protocol decides is decided under a
 * conversation's lock and queued; nothing holds a lock across a
 * transmit, which at SF12 and one per cent duty is over two minutes.
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
 *
 * T1 is a number this cannot compute.  lora(3) found that a station
 * which has just transmitted cannot answer until it has served its
 * duty cycle, so a timeout shorter than that debt expires before the
 * reply can go out; working it out means knowing the modem's
 * parameters, which is the coupling this layering exists to avoid.  So
 * T1 is set and status reports it.
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
	Qlisten,

	Nconv		= 4,	/* conversations at once */
	Ncall		= 6,	/* callsign characters */
	Addrlen		= 7,	/* callsign and SSID on the wire */
	Ndigi		= 2,	/* what AX.25 2.2 allows */
	/*
	 * Minframe is an address field and a control byte, which is a
	 * whole U or S frame; Minhdr adds the PID that only I and UI
	 * carry, and is what the information field is measured against.
	 * Asking for Minhdr everywhere counts every SABM as a runt,
	 * which is how this was found.
	 */
	Minframe	= 2*Addrlen + 1,
	Minhdr		= 2*Addrlen + 2,
	Maxhdr		= (2 + Ndigi)*Addrlen + 2,

	/*
	 * Control field, modulo 8.  An I frame has bit 0 clear, an S
	 * frame has 01 in the low two bits and a U frame 11.
	 */
	Cpf		= 0x10,	/* poll/final */
	Cui		= 0x03,	/* unnumbered information */
	Csabm		= 0x2f,
	Cdisc		= 0x43,
	Cdm		= 0x0f,
	Cua		= 0x63,
	Ctest		= 0xe3,
	Crr		= 0x01,
	Crnr		= 0x05,
	Crej		= 0x09,
	Cumask		= 0xef,	/* U type with the poll/final bit out */
	Csmask		= 0x0f,	/* S type with N(R) and P/F out */
	Pidnol3		= 0xf0,	/* no layer 3 */

	Modulus		= 8,
	Defk		= 4,	/* what the specification suggests */
	Defn2		= 10,
	Deft1		= 4000,	/* ms; see the note on T1 above */
	Deft2		= 1000,	/* ms to wait before acknowledging */
	Deft3		= 300000,
	Tick		= 100,	/* ms the ticker sleeps */

	Aend		= 0x01,	/* end of address field */
	Acmd		= 0x80,	/* command, or has-been-repeated */
	Arsvd		= 0x60,	/* the two reserved bits, sent as ones */

	Qmax		= 8,
	Statlen		= 512,
};

/* the states of the data-link state machine */
enum {
	Sdisc,			/* disconnected */
	Ssetup,			/* SABM sent, waiting for UA */
	Srelease,		/* DISC sent, waiting for UA */
	Sconn,			/* connected */
};

static char *ax25state[] = {
	"disconnected", "setup", "release", "connected",
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

	/* the data link */
	int	ui;		/* connectionless: no state machine at all */
	int	state;
	int	vs;		/* V(S), the next N(S) to send */
	int	vr;		/* V(R), the N(S) expected next */
	int	va;		/* V(A), the oldest unacknowledged */
	int	k;		/* window */
	int	n2;		/* retries before giving up */
	int	t1ms;
	int	t2ms;
	int	t3ms;
	int	rc;		/* retries so far */
	int	t1;		/* ms left, 0 stopped */
	int	t2;
	int	t3;
	int	ackpending;
	int	peerbusy;	/* RNR heard */
	int	rejsent;
	int	ownbusy;
	Block	*sent[Modulus];	/* awaiting acknowledgement */
	Rendez	r;		/* state changed, or the window moved */

	/* listen */
	int	listening;
	Conv	*pending;	/* connections accepted and not taken */
	Conv	*nextpend;
	Conv	*owner;		/* the announcer this came from */
	Rendez	lr;

	u32	nsent;
	u32	nrecv;
	u32	nretrans;
	u32	nrejin;
	u32	nrejout;
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
	Queue	*oq;		/* frames waiting for the air */

	Conv	conv[Nconv];

	u32	nin;
	u32	nout;
	u32	nnotours;	/* heard, addressed to somebody else */
	u32	nrunt;		/* too short to carry an address field */
	u32	nbad;		/* an address field that does not end */
	u32	nnotui;		/* a control field this does not implement */
	u32	nnoconv;	/* for us, and nobody had announced */
	u32	ndigi;		/* for a digipeater we are not */
	u32	noqdrop;	/* a control frame with no room to queue */
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

/*
 * Build one frame.  cmd says whether the command bit goes on the
 * destination or the source -- AX.25 2.0 onwards tells a command from a
 * response by which of the two carries it, which is how an RR that
 * polls is told from an RR that answers.  pid < 0 means no PID field,
 * which is every frame but I and UI.
 */
static Block*
mkframe(Conv *cv, int cmd, int ctl, int pid, uchar *info, int n)
{
	Block *b;
	uchar *w;
	int i, hl;

	hl = (2 + cv->ndigi)*Addrlen + 1 + (pid >= 0);
	b = allocb(hl + n);
	w = b->wp;
	putcall(w, &cv->remote, cmd ? Acmd : 0, cv->ndigi == 0);
	w += Addrlen;
	putcall(w, &ax25.me, cmd ? 0 : Acmd, cv->ndigi == 0);
	w += Addrlen;
	for(i = 0; i < cv->ndigi; i++){
		putcall(w, &cv->digi[i], 0, i == cv->ndigi-1);
		w += Addrlen;
	}
	*w++ = ctl;
	if(pid >= 0)
		*w++ = pid;
	if(n > 0)
		memmove(w, info, n);
	w += n;
	b->wp = w;
	return b;
}

/*
 * Queue a frame for the air.  Control frames go in without waiting,
 * because they are built while a conversation's lock is held and the
 * reader must not stop; if there is no room the frame is dropped and
 * counted, which the protocol survives -- that is what T1 is for.
 * Information frames are queued by the writing process, which may
 * wait, and that wait is the backpressure a duty-cycled link needs.
 */
static void
sendctl(Block *b)
{
	if(ax25.oq == nil){
		freeb(b);
		ax25.noqdrop++;
		return;
	}
	if(qpass(ax25.oq, b) < 0)	/* qpass frees what it refuses */
		ax25.noqdrop++;
}

static void
senddata(Block *b)
{
	if(ax25.oq == nil){
		freeb(b);
		error(Enotattached);
	}
	qbwrite(ax25.oq, b);
}

static void
ax25sender(void*)
{
	Block *b;
	Chan *c;

	for(;;){
		b = qbread(ax25.oq, Maxhdr + 512);
		if(b == nil)
			break;
		c = ax25.c;
		if(c == nil){
			freeb(b);
			break;
		}
		if(waserror()){
			freeb(b);
			continue;
		}
		devtab[c->type]->bwrite(c, b, 0);
		poperror();
		ax25.nout++;
	}
	pexit("", 0);
}

/* the frames with no information field */
static void
sendu(Conv *cv, int cmd, int ctl)
{
	sendctl(mkframe(cv, cmd, ctl, -1, nil, 0));
}

static void
sends(Conv *cv, int cmd, int type, int pf)
{
	sendctl(mkframe(cv, cmd, (cv->vr << 5) | (pf ? Cpf : 0) | type,
		-1, nil, 0));
}

/* forget everything about a connection that has gone */
static void
clearlink(Conv *cv)
{
	int i;

	for(i = 0; i < Modulus; i++){
		if(cv->sent[i] != nil){
			freeb(cv->sent[i]);
			cv->sent[i] = nil;
		}
	}
	cv->vs = cv->vr = cv->va = 0;
	cv->rc = 0;
	cv->t1 = cv->t2 = cv->t3 = 0;
	cv->ackpending = 0;
	cv->peerbusy = 0;
	cv->rejsent = 0;
}

/*
 * N(R) acknowledges everything before it.  Modulo 8 arithmetic is done
 * by walking rather than by subtracting, because a peer that sends an
 * N(R) outside the window is misbehaving and walking simply stops.
 */
static void
ackupto(Conv *cv, int nr)
{
	while(cv->va != nr){
		if(cv->sent[cv->va] != nil){
			freeb(cv->sent[cv->va]);
			cv->sent[cv->va] = nil;
		}
		cv->va = (cv->va + 1) % Modulus;
		if(cv->va == cv->vs)
			break;
	}
	if(cv->va == cv->vs){
		cv->t1 = 0;
		cv->t3 = cv->t3ms;
		cv->rc = 0;
	}else
		cv->t1 = cv->t1ms;
	wakeup(&cv->r);
}

/* go back to N(R) and send it all again */
static void
retransmit(Conv *cv, int from)
{
	int i;

	for(i = from; i != cv->vs; i = (i + 1) % Modulus){
		if(cv->sent[i] == nil)
			continue;
		sendctl(copyblock(cv->sent[i], BLEN(cv->sent[i])));
		cv->nretrans++;
	}
	cv->t1 = cv->t1ms;
}

/*
 * Room for another frame.  A disconnection also counts, because the
 * writer has to wake up to fail; a connection still being set up does
 * not, because there is nothing to do but wait.
 */
static int
windowopen(void *a)
{
	Conv *cv = a;

	if(cv->state == Sdisc)
		return 1;
	if(cv->state != Sconn)
		return 0;
	if(cv->peerbusy)
		return 0;
	return ((cv->vs - cv->va + Modulus) % Modulus) < cv->k;
}

static int
settled(void *a)
{
	Conv *cv = a;

	return cv->state == Sconn || cv->state == Sdisc;
}

/*
 * The ticker: T1 is the retransmission timer and T3 says the link has
 * been idle long enough to be worth checking.  One process for every
 * conversation, because four timers are not worth four processes and
 * because a hundred milliseconds is finer than anything this link does.
 */
static void
ax25ticker(void*)
{
	Conv *cv, *e;

	e = &ax25.conv[Nconv];
	for(;;){
		tsleep(&up->sleep, return0, 0, Tick);
		for(cv = ax25.conv; cv < e; cv++){
			if(!cv->inuse || cv->ui)
				continue;
			qlock(&cv->l);
			if(waserror()){
				qunlock(&cv->l);
				continue;
			}
			if(cv->t1 > 0){
				cv->t1 -= Tick;
				if(cv->t1 <= 0){
					cv->t1 = 0;
					if(++cv->rc >= cv->n2){
						/*
						 * N2 tries and no answer.
						 * Say so and stop; a link
						 * that is gone is not made
						 * present by asking again.
						 */
						if(cv->state == Sconn)
							sendu(cv, 0, Cdm|Cpf);
						cv->state = Sdisc;
						clearlink(cv);
						if(cv->rq != nil)
							qhangup(cv->rq, "ax25: no answer");
						wakeup(&cv->r);
					}else switch(cv->state){
					case Ssetup:
						sendu(cv, 1, Csabm|Cpf);
						cv->t1 = cv->t1ms;
						break;
					case Srelease:
						sendu(cv, 1, Cdisc|Cpf);
						cv->t1 = cv->t1ms;
						break;
					case Sconn:
						if(cv->va == cv->vs)
							sends(cv, 1, Crr, 1);
						else
							retransmit(cv, cv->va);
						cv->t1 = cv->t1ms;
						break;
					}
				}
			}
			if(cv->t2 > 0 && cv->state == Sconn){
				cv->t2 -= Tick;
				if(cv->t2 <= 0){
					cv->t2 = 0;
					if(cv->ackpending){
						cv->ackpending = 0;
						sends(cv, 0, cv->ownbusy ?
							Crnr : Crr, 0);
					}
				}
			}
			if(cv->t3 > 0 && cv->state == Sconn){
				cv->t3 -= Tick;
				if(cv->t3 <= 0){
					cv->t3 = 0;
					sends(cv, 1, Crr, 1);
					cv->t1 = cv->t1ms;
				}
			}
			poperror();
			qunlock(&cv->l);
		}
	}
}

static Conv* newconv(void);

/*
 * Which conversation a frame belongs to.  One that named this station
 * owns it; failing that, one that announced takes it.  A conversation
 * in connected mode only answers to the peer it is connected to, so an
 * announced conversation is where a SABM from somebody new arrives.
 */
static Conv*
convfor(Call *from, Conv **ann)
{
	Conv *cv, *e;

	*ann = nil;
	e = &ax25.conv[Nconv];
	for(cv = ax25.conv; cv < e; cv++){
		if(!cv->inuse)
			continue;
		if(!cv->announced && cv->haveremote && samecall(&cv->remote, from))
			return cv;
		if(cv->announced && *ann == nil)
			*ann = cv;
	}
	return nil;
}

/*
 * A SABM for an announced conversation.  AX.25 wants a UA promptly, and
 * a connection is per peer, so the answer cannot be "this conversation
 * is now yours" -- two stations calling one server would interleave,
 * which is the bug lora(3) carries because #L has announce and no
 * listen.  So a new conversation is made, acknowledged at once, and
 * left on the announcer's queue for whoever reads listen.
 */
static Conv*
accept(Conv *ann, Call *from)
{
	Conv *cv, **pp;

	/*
	 * newconv() locks each conversation in turn looking for a free
	 * one, and the announcer is one of them -- usually the first,
	 * since it was the first to be cloned.  So this must not be
	 * called with the announcer's lock held: it would wait for
	 * itself, in the reader process, which then stops reading and
	 * the link simply goes quiet.  That is what happened.
	 */
	cv = newconv();
	if(cv == nil)
		return nil;
	qlock(&ann->l);
	if(!ann->inuse || !ann->announced){
		qunlock(&ann->l);
		qlock(&cv->l);
		cv->inuse = 0;
		qunlock(&cv->l);
		return nil;
	}
	cv->remote = *from;
	cv->haveremote = 1;
	cv->ndigi = ann->ndigi;
	memmove(cv->digi, ann->digi, sizeof cv->digi);
	cv->pid = ann->pid;
	cv->k = ann->k;
	cv->n2 = ann->n2;
	cv->t1ms = ann->t1ms;
	cv->t2ms = ann->t2ms;
	cv->t3ms = ann->t3ms;
	cv->state = Sconn;
	cv->t3 = cv->t3ms;
	cv->owner = ann;

	for(pp = &ann->pending; *pp != nil; pp = &(*pp)->nextpend)
		;
	*pp = cv;
	qunlock(&ann->l);
	wakeup(&ann->lr);
	return cv;
}

static void
uiframe(Conv *cv, Block *b)
{
	cv->nrecv++;
	qpass(cv->rq, b);
}

/*
 * One received frame, with the address field already stripped off and
 * p at the control byte.  Everything here runs under the conversation's
 * lock and queues what it wants to send; nothing waits for the air.
 */
static void
input(Conv *cv, Block *b, uchar *p, uchar *e, int cmd)
{
	int ctl, ns, nr, pf;

	ctl = *p++;
	pf = (ctl & Cpf) != 0;

	if((ctl & 1) == 0){			/* information */
		if(cv->state != Sconn){
			/*
			 * Data with no connection behind it.  DM says
			 * so, which is what makes a peer that thinks it
			 * is connected give up rather than retry for N2.
			 */
			sendu(cv, 0, Cdm | (pf ? Cpf : 0));
			freeb(b);
			return;
		}
		if(p >= e){
			ax25.nrunt++;
			freeb(b);
			return;
		}
		p++;				/* PID */
		ns = (ctl >> 1) & 7;
		nr = (ctl >> 5) & 7;
		ackupto(cv, nr);
		if(ns != cv->vr){
			/*
			 * A frame already taken is a retransmission whose
			 * acknowledgement was lost, and the answer to it
			 * is an RR saying how far we have got -- not a
			 * REJ, which would ask for frames we already
			 * have.  Anything else is a gap, and that gets
			 * one REJ and no more until it is filled: a REJ
			 * per frame would ask for the same retransmission
			 * several times over on a link where every frame
			 * costs airtime.
			 */
			if(((cv->vr - ns + Modulus) % Modulus) <= cv->k)
				sends(cv, 0, Crr, pf);
			else if(!cv->rejsent){
				cv->rejsent = 1;
				cv->nrejout++;
				sends(cv, 0, Crej, pf);
			}else if(pf)
				sends(cv, 0, Crr, 1);
			freeb(b);
			return;
		}
		cv->rejsent = 0;
		cv->vr = (cv->vr + 1) % Modulus;
		b->rp = p;
		cv->nrecv++;
		qpass(cv->rq, b);
		cv->t3 = cv->t3ms;
		/*
		 * Do not answer yet.  The other end is half duplex and
		 * is very likely still transmitting the rest of its
		 * window: an acknowledgement sent now lands on a deaf
		 * receiver and is simply lost, which is what happened
		 * before T2 existed here -- three I frames went out, the
		 * three RRs went out, and the sender heard none of them
		 * and retransmitted until N2.  T2 is the specification's
		 * answer and it pays twice, because one RR after the
		 * burst acknowledges the whole burst.
		 *
		 * A poll is different: P=1 asks for an answer now, and
		 * the station that sent it has stopped to listen for one.
		 */
		if(pf){
			cv->t2 = 0;
			cv->ackpending = 0;
			sends(cv, 0, cv->ownbusy ? Crnr : Crr, 1);
		}else{
			cv->ackpending = 1;
			if(cv->t2 == 0)
				cv->t2 = cv->t2ms;
		}
		return;
	}

	if((ctl & 3) == 1){			/* supervisory */
		nr = (ctl >> 5) & 7;
		if(cv->state != Sconn){
			if(cmd && pf)
				sendu(cv, 0, Cdm|Cpf);
			freeb(b);
			return;
		}
		switch(ctl & Csmask){
		case Crr:
			cv->peerbusy = 0;
			ackupto(cv, nr);
			break;
		case Crnr:
			cv->peerbusy = 1;
			ackupto(cv, nr);
			cv->t1 = cv->t1ms;
			break;
		case Crej:
			cv->peerbusy = 0;
			cv->nrejin++;
			ackupto(cv, nr);
			retransmit(cv, nr);
			break;
		}
		if(cmd && pf)
			sends(cv, 0, cv->ownbusy ? Crnr : Crr, 1);
		freeb(b);
		return;
	}

	switch(ctl & Cumask){			/* unnumbered */
	case Cui:
		if(p >= e){
			ax25.nrunt++;
			break;
		}
		b->rp = p + 1;			/* past the PID */
		uiframe(cv, b);
		return;
	case Csabm:
		clearlink(cv);
		cv->state = Sconn;
		cv->t3 = cv->t3ms;
		sendu(cv, 0, Cua | (pf ? Cpf : 0));
		wakeup(&cv->r);
		break;
	case Cdisc:
		clearlink(cv);
		cv->state = Sdisc;
		sendu(cv, 0, Cua | (pf ? Cpf : 0));
		if(cv->rq != nil)
			qhangup(cv->rq, nil);
		wakeup(&cv->r);
		break;
	case Cua:
		if(cv->state == Ssetup){
			clearlink(cv);
			cv->state = Sconn;
			cv->t3 = cv->t3ms;
		}else if(cv->state == Srelease){
			clearlink(cv);
			cv->state = Sdisc;
			if(cv->rq != nil)
				qhangup(cv->rq, nil);
		}
		wakeup(&cv->r);
		break;
	case Cdm:
		clearlink(cv);
		cv->state = Sdisc;
		if(cv->rq != nil)
			qhangup(cv->rq, "ax25: refused");
		wakeup(&cv->r);
		break;
	case Ctest:
		/*
		 * The only thing in the protocol that answers "are you
		 * there" without changing any state.  The information
		 * field comes back as it went out.
		 */
		sendctl(mkframe(cv, 0, Ctest | (pf ? Cpf : 0), -1,
			p, e - p));
		break;
	default:
		ax25.nnotui++;
		break;
	}
	freeb(b);
}

static void
ax25reader(void*)
{
	Block *b;
	Conv *cv, *ann;
	Chan *c;
	Call dest, src, digi;
	uchar *p, *e;
	int n, repeated, ndigi, cmd, ctl;

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
		if(n < Minframe){
			ax25.nrunt++;
			freeb(b);
			continue;
		}
		p = b->rp;
		e = b->rp + n;
		getcall(p, &dest);
		getcall(p + Addrlen, &src);
		cmd = (p[Ncall] & Acmd) != 0;

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
		}
		if(p + 1 > e){
			ax25.nrunt++;
			freeb(b);
			continue;
		}

		/*
		 * A path with a hop still to go is addressed to that
		 * digipeater and not to the destination, whoever the
		 * destination is.  This does not repeat, so it is not
		 * ours; counted apart from a frame for another station,
		 * because the two mean different things about a link.
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

		ctl = *p;
		cv = convfor(&src, &ann);
		if(cv == nil){
			/*
			 * Nobody is connected to this station.  A SABM
			 * to an announced conversation makes one; a UI
			 * frame goes to the announcer as it always did;
			 * anything else has no connection to belong to
			 * and is told so, which is what stops the far
			 * end retrying for N2.
			 */
			if(ann == nil){
				ax25.nnoconv++;
				freeb(b);
				continue;
			}
			if((ctl & Cumask) == Cui || ann->ui){
				qlock(&ann->l);
				if(!waserror()){
					ann->remote = src;
					ann->haveremote = 1;
					input(ann, b, p, e, cmd);
					poperror();
					qunlock(&ann->l);
				}else
					qunlock(&ann->l);
				continue;
			}
			if((ctl & Cumask) != Csabm){
				ax25.nnoconv++;
				freeb(b);
				continue;
			}
			cv = accept(ann, &src);
			if(cv == nil){
				/*
				 * No room for another conversation, which
				 * is a refusal and not a silence: DM is
				 * exactly the frame for it.
				 */
				ax25.nnoconv++;
				qlock(&ann->l);
				ann->remote = src;
				ann->haveremote = 1;
				sendu(ann, 0, Cdm|Cpf);
				qunlock(&ann->l);
				freeb(b);
				continue;
			}
			qlock(&cv->l);
			sendu(cv, 0, Cua | ((ctl & Cpf) ? Cpf : 0));
			qunlock(&cv->l);
			freeb(b);
			continue;
		}

		qlock(&cv->l);
		if(waserror()){
			qunlock(&cv->l);
			continue;
		}
		input(cv, b, p, e, cmd);
		poperror();
		qunlock(&cv->l);
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
		cv->k = Defk;
		cv->n2 = Defn2;
		cv->t1ms = Deft1;
		cv->t2ms = Deft2;
		cv->t3ms = Deft3;
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
	case Qlisten:
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
		case 5:
			mkqid(&q, QID(n, Qlisten), 0, QTFILE);
			devdir(c, q, "listen", 0, eve, 0666, dp);
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
			cv->ui = 0;
			cv->state = Sdisc;
			cv->k = Defk;
			cv->n2 = Defn2;
			cv->t1ms = Deft1;
			cv->t2ms = Deft2;
			cv->t3ms = Deft3;
			cv->ownbusy = 0;
			cv->listening = 0;
			cv->pending = nil;
			cv->nextpend = nil;
			cv->owner = nil;
			clearlink(cv);
			cv->nsent = cv->nrecv = 0;
			cv->nretrans = cv->nrejin = cv->nrejout = 0;
			qunlock(&cv->l);
			return cv;
		}
		qunlock(&cv->l);
	}
	return nil;
}

static int
haspending(void *a)
{
	Conv *ann = a;

	return ann->pending != nil || !ann->inuse;
}

static Chan*
ax25open(Chan *c, u32 omode)
{
	Conv *cv, *ann;

	if(TYPE(c->qid) == Qclone){
		cv = newconv();
		if(cv == nil)
			error("no free ax25 conversations");
		mkqid(&c->qid, QID(cv->x, Qcctl), 0, QTFILE);
	}

	/*
	 * Opening listen waits for somebody to connect and hands back
	 * that connection's ctl, which is #I's shape and the reason
	 * this device has a listen file at all: a connection is per
	 * peer, so a second station calling an announced conversation
	 * has to become a second conversation.  #L has announce and no
	 * listen, and lora(3) carries that as a bug.
	 */
	if(TYPE(c->qid) == Qlisten){
		ann = &ax25.conv[NUM(c->qid)];
		if(!ann->announced)
			error("listen wants a conversation that announced");
		qlock(&ann->l);
		if(waserror()){
			ann->listening--;
			qunlock(&ann->l);
			nexterror();
		}
		ann->listening++;
		while(ann->pending == nil){
			qunlock(&ann->l);
			if(waserror()){
				qlock(&ann->l);
				nexterror();
			}
			sleep(&ann->lr, haspending, ann);
			poperror();
			qlock(&ann->l);
			if(!ann->inuse)
				error("the announcing conversation closed");
		}
		cv = ann->pending;
		ann->pending = cv->nextpend;
		cv->nextpend = nil;
		ann->listening--;
		poperror();
		qunlock(&ann->l);
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
	/*
	 * Closing a connected conversation is a disconnection, and it
	 * is said rather than merely stopped: a peer left waiting for
	 * frames that will never come spends N2 retries finding out.
	 */
	if(cv->state == Sconn && !cv->ui)
		sendu(cv, 1, Cdisc|Cpf);
	clearlink(cv);
	cv->state = Sdisc;
	cv->inuse = 0;
	cv->announced = 0;
	cv->haveremote = 0;
	cv->ndigi = 0;
	if(cv->rq != nil)
		qhangup(cv->rq, nil);
	wakeup(&cv->r);
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
	p = seprint(p, e, "\nstate %s%s\n", ax25state[cv->state],
		cv->ui ? " ui" : "");
	p = seprint(p, e, "vs %d\nvr %d\nva %d\n", cv->vs, cv->vr, cv->va);
	p = seprint(p, e, "window %d\nn2 %d\nretries %d\n",
		cv->k, cv->n2, cv->rc);
	p = seprint(p, e, "t1 %d\nt2 %d\nt3 %d\n",
		cv->t1ms, cv->t2ms, cv->t3ms);
	p = seprint(p, e, "peerbusy %d\nheader %d\n",
		cv->peerbusy, hdrlen(cv));
	p = seprint(p, e, "sent %ud\nreceived %ud\n", cv->nsent, cv->nrecv);
	p = seprint(p, e, "retransmitted %ud\nrejin %ud\nrejout %ud\n",
		cv->nretrans, cv->nrejin, cv->nrejout);
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
	p = seprint(p, e, "ctldropped %ud\n", ax25.noqdrop);
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
	case Qlisten:
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
		ax25.oq = qopen(8*(Maxhdr + 256), Qmsg, nil, nil);
		if(ax25.oq == nil)
			error(Enomem);
		ax25.started = 1;
		kproc("ax25recv", ax25reader, nil, 0);
		kproc("ax25send", ax25sender, nil, 0);
		kproc("ax25tick", ax25ticker, nil, 0);
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
	Block *b;
	char *p;
	int budget, v;

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
			if(cv->state != Sdisc)
				error("already connected");
			parsecall(cb->f[1], &cv->remote);
			cv->haveremote = 1;
			cv->announced = 0;
			if(cb->nf == 4){
				if(strcmp(cb->f[2], "via") != 0)
					error(Ebadarg);
				setvia(cv, cb->f[3]);
			}
			if(!cv->ui){
				if(!ax25.haveaddr)
					error(Enoaddr);
				/*
				 * SABM, and the write waits for the
				 * answer.  A connect that returned
				 * before the peer agreed would let the
				 * next write fail for a reason that
				 * belonged to this one.
				 */
				qlock(&cv->l);
				clearlink(cv);
				cv->state = Ssetup;
				cv->rc = 0;
				sendu(cv, 1, Csabm|Cpf);
				cv->t1 = cv->t1ms;
				qunlock(&cv->l);
				sleep(&cv->r, settled, cv);
				if(cv->state != Sconn)
					error("ax25: connection refused "
						"or no answer");
			}
		}else if(strcmp(p, "disconnect") == 0){
			if(cv->ui)
				error("a connectionless conversation has "
					"nothing to disconnect");
			if(cv->state != Sconn)
				error("not connected");
			qlock(&cv->l);
			cv->state = Srelease;
			cv->rc = 0;
			sendu(cv, 1, Cdisc|Cpf);
			cv->t1 = cv->t1ms;
			qunlock(&cv->l);
			sleep(&cv->r, settled, cv);
		}else if(strcmp(p, "window") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			v = atoi(cb->f[1]);
			if(v < 1 || v > Modulus-1)
				error("window is 1 to 7, modulo 8");
			cv->k = v;
		}else if(strcmp(p, "n2") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			v = atoi(cb->f[1]);
			if(v < 1 || v > 64)
				error("n2 is 1 to 64");
			cv->n2 = v;
		}else if(strcmp(p, "t1") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			v = atoi(cb->f[1]);
			if(v < 100 || v > 600000)
				error("t1 is 100 to 600000 ms");
			cv->t1ms = v;
		}else if(strcmp(p, "t2") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			v = atoi(cb->f[1]);
			if(v < 0 || v > 60000)
				error("t2 is 0 to 60000 ms");
			cv->t2ms = v;
		}else if(strcmp(p, "t3") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			v = atoi(cb->f[1]);
			if(v < 0 || v > 3600000)
				error("t3 is 0 to 3600000 ms; 0 is off");
			cv->t3ms = v;
		}else if(strcmp(p, "busy") == 0){
			if(cb->nf != 2)
				error(Ebadarg);
			cv->ownbusy = strcmp(cb->f[1], "on") == 0;
			if(cv->state == Sconn)
				sends(cv, 0, cv->ownbusy ? Crnr : Crr, 0);
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
			if(cv->state != Sdisc)
				error("the mode cannot change under a "
					"connection");
			cv->ui = strcmp(cb->f[1], "on") == 0;
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

		if(cv->ui){
			qlock(&cv->wl);
			if(waserror()){
				qunlock(&cv->wl);
				nexterror();
			}
			b = mkframe(cv, 1, Cui, cv->pid, a, n);
			senddata(b);
			cv->nsent++;
			poperror();
			qunlock(&cv->wl);
			return n;
		}

		/*
		 * Connected mode.  A write waits for room in the window
		 * rather than failing, which is what a file interface
		 * has to say instead of EWOULDBLOCK, and is the same
		 * answer radio(3) gives for the duty cycle.  The frame
		 * is kept until N(R) acknowledges it, because that is
		 * what makes a retransmission possible.
		 */
		qlock(&cv->wl);
		if(waserror()){
			qunlock(&cv->wl);
			nexterror();
		}
		for(;;){
			qlock(&cv->l);
			if(cv->state == Sdisc){
				qunlock(&cv->l);
				error("ax25: not connected");
			}
			if(cv->state == Sconn && windowopen(cv))
				break;
			qunlock(&cv->l);
			sleep(&cv->r, windowopen, cv);
		}
		if(waserror()){
			qunlock(&cv->l);
			nexterror();
		}
		/*
		 * Every I frame carries N(R), so sending one pays any
		 * acknowledgement this end owed.  That is what
		 * piggybacking is, and here it costs nothing to get.
		 */
		cv->ackpending = 0;
		cv->t2 = 0;
		b = mkframe(cv, 1, (cv->vr << 5) | (cv->vs << 1), cv->pid,
			a, n);
		cv->sent[cv->vs] = copyblock(b, BLEN(b));
		cv->vs = (cv->vs + 1) % Modulus;
		cv->t1 = cv->t1ms;
		cv->t3 = 0;
		cv->nsent++;
		poperror();
		qunlock(&cv->l);
		senddata(b);
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
