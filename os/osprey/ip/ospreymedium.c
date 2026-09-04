#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

#include "ip.h"

/*
 * The osprey-interface medium.
 *
 * Unlike loopbackmedium, whose read kproc blocks in qbread on an internal
 * queue, and unlike netdevmedium, whose read kproc blocks in a kernel
 * device read, this medium's inbound is driven by the server loop, not by
 * a blocking kproc.  A kproc in the personality can only block in the
 * cooperative scheduler; only the server loop's oselect can wait on an
 * external event - a clock tick, a request, or (the point of this medium)
 * a frame arriving over an osprey ring.  So bwrite hands a frame off and
 * ospreymediumpump(), called from the server loop, injects whatever has
 * arrived into the stack in the loop's own context.
 *
 * Three forms of the wire, chosen at bind time:
 *
 *   bind osprey		a wire within one personality: the first such
 *				interface is looped to itself, and a second one
 *				bound is paired with it, so two stacks (two Fs)
 *				in one address space share a pair of queues.
 *   bind osprey ring		the server end of the device-carried wire: the
 *				peer is the container that asks over our ring.
 *				bwrite queues the frame for it, and the server
 *				loop returns one such frame on the reply to
 *				each of the peer's Reqframe requests
 *				(ospreymediumtake); a frame the peer sent
 *				arrives by ospreymediumreceive from the loop.
 *   bind osprey ring client	the client end: bwrite sends the frame to the
 *				server over the ring (ring9p_frame, a request)
 *				and whatever frame rides back on the reply is
 *				queued for the pump; the loop polls the ring on
 *				every tick for frames the far stack sent since
 *				(ospreymediumpoll), so the one-way request ring
 *				carries a two-way wire.
 *
 * The frame between the two containers crosses the ring the kernel only
 * routes: no medium code of the kernel's touches it, and each end is a
 * whole Plan 9 stack in its own container.
 */

/* ring9p.c, compiled against the user headers; the plain-typed seam */
extern long ring9p_frame(uchar *frame, long n, uchar *back, long backmax);


enum {
	Maxtu = 64*1024,	/* the in-personality wire */
	Ringmtu = 1500,		/* the ring wire: a frame each way fits the data area (ring9p.c's Maxframe) */
};

typedef struct Osrock Osrock;
struct Osrock
{
	Fs	*f;		/* the stack to inject into */
	Queue	*q;		/* frames arrived for this interface, to inject */
	Queue	*toring;	/* server end: frames the stack sent toward the peer container, until it asks */
	Ipifc	*ifc;
	Osrock	*peer;		/* the interface at the other end of the wire (in-personality form) */
	Osrock	*next;		/* all bound osprey interfaces, for the pump */
	int	ring;		/* the peer is the container across the ring */
	int	client;		/* ... and we reach it by request (else it reaches us) */
};

static Osrock *allos;		/* every bound osprey interface */
static long ringtx, ringrx;	/* frames that left and arrived over the ring, this end */

/* the one interface at this end whose wire is the ring, if any */
static Osrock*
ringrock(void)
{
	Osrock *er;

	for(er = allos; er != nil; er = er->next)
		if(er->ring)
			return er;
	return nil;
}

/*
 * Bind an interface to the osprey medium.  With no argument the wire is
 * within this personality: the first is looped to itself; when a second
 * binds, the two are paired into one wire, so a frame one writes arrives
 * at the other.  With two independent stacks (two Fs, devip's ipfs[dev])
 * each holding one end, this is a real two-endpoint link, not a
 * loopback.  "ring" makes the wire the ring to the peer container, this
 * end the server's; "ring client" this end the client's.
 */
static void
ospreybind(Ipifc *ifc, int argc, char **argv)
{
	Osrock *er, *o, *single;

	er = smalloc(sizeof(*er));
	er->f = ifc->conv->p->f;
	er->q = qopen(1024*1024, Qmsg, nil, nil);
	er->ifc = ifc;
	if(argc > 2 && strcmp(argv[2], "ring") == 0){
		er->ring = 1;
		er->client = argc > 3 && strcmp(argv[3], "client") == 0;
		er->toring = qopen(256*1024, Qmsg, nil, nil);
		ifc->maxtu = Ringmtu;		/* so tcp.c's mss keeps a segment inside one ring frame */
	} else {
		er->peer = er;			/* default: a wire looped to itself */
		single = nil;
		for(o = allos; o != nil; o = o->next)
			if(!o->ring){
				if(single == nil)
					single = o;
				else {
					single = nil;	/* two already: they are each other's */
					break;
				}
			}
		if(single != nil && single->peer == single){	/* exactly one, unpaired: pair with it */
			er->peer = single;
			single->peer = er;
		}
	}
	er->next = allos;
	allos = er;
	ifc->arg = er;
}

static void
ospreyunbind(Ipifc *ifc)
{
	Osrock **pp, *er;

	er = ifc->arg;
	for(pp = &allos; *pp != nil; pp = &(*pp)->next)
		if(*pp == er){
			*pp = er->next;
			break;
		}
	if(er->peer != nil && er->peer != er)
		er->peer->peer = er->peer;	/* the survivor is looped to itself again */
	if(er->q != nil)
		qfree(er->q);
	if(er->toring != nil)
		qfree(er->toring);
	free(er);
	ifc->arg = nil;
}

static int ospreyanswered;	/* logged once: the stack answered a frame from the ring */
static int ospreysentring;	/* logged once: the stack's own frame left over the ring */

/* a frame that came back on a reply, from the far stack: queue it for the pump */
static void
ringarrived(Osrock *er, uchar *frame, long n)
{
	Block *bp;

	bp = allocb(n);
	if(bp == nil)
		return;
	memmove(bp->wp, frame, n);
	bp->wp += n;
	ringrx++;
	if(qpass(er->q, bp) < 0)
		er->ifc->inerr++;
}

static void
ospreybwrite(Ipifc *ifc, Block *bp, int, uchar*, Routehint*)
{
	Osrock *er;
	uchar *ip;
	int ihl;
	long n, rn;
	uchar frame[Ringmtu], back[Ringmtu];

	/*
	 * If the stack is sending an ICMP echo reply, it answered a packet it
	 * received - and the only echo request in this boot is the one the
	 * client container put on the ring, so this is the proof the stack at
	 * this end accepted a real IP packet that crossed the ring, not just
	 * that the bytes arrived.  A raw-IP medium, so the frame is the IP
	 * packet itself.
	 */
	if(!ospreyanswered && BLEN(bp) >= 21){
		ip = bp->rp;
		ihl = (ip[0] & 0x0f) * 4;
		if((ip[0] >> 4) == 4 && ip[9] == 1 && BLEN(bp) >= ihl + 1 && ip[ihl] == 0){
			ospreyanswered = 1;
			print("osprey medium: the stack answered with an ICMP echo reply - it accepted a real IP packet that crossed the ring from the peer container\n");
		}
	}

	er = ifc->arg;
	if(er->ring && !er->client){
		/*
		 * The server end: the peer can only be reached on the reply to
		 * a request of its own, so the frame waits until it asks
		 * (ospreymediumtake, from the server loop).
		 */
		if(qpass(er->toring, bp) < 0)
			ifc->outerr++;
		ifc->out++;
		return;
	}
	if(er->ring){
		/*
		 * The client end: the frame is a request on the ring, answered
		 * by the server container when its loop injects it - a
		 * synchronous send, the whole personality waiting in the SLEEP
		 * call that services the ring, which is safe because nothing
		 * else in a cooperative personality can run meanwhile.  The
		 * reply may carry a frame the far stack sent toward us; it is
		 * queued, not injected here, so injection stays in the loop's
		 * context (the pump) and not inside whatever protocol path is
		 * sending.
		 */
		n = BLEN(bp);
		if(n > Ringmtu){
			ifc->outerr++;
			freeb(bp);
			return;
		}
		memmove(frame, bp->rp, n);
		freeb(bp);
		rn = ring9p_frame(frame, n, back, sizeof back);
		if(rn < 0){
			ifc->outerr++;
			return;
		}
		ringtx++;
		if(!ospreysentring){
			ospreysentring = 1;
			print("osprey medium: the stack's own %ld-byte frame left this container over the ring to the peer's stack - the client end of the device-carried wire\n", n);
		}
		ifc->out++;
		if(rn > 0)
			ringarrived(er, back, rn);
		return;
	}
	if(qpass(er->peer->q, bp) < 0)	/* out this end -> in at the other */
		ifc->outerr++;
	ifc->out++;
}

/*
 * Drain every osprey interface's inbound frames into the stack.  Called
 * from the server loop, so it runs in the loop's context, never blocks,
 * and returns when the queues are empty.
 */
void
ospreymediumpump(void)
{
	Osrock *er;
	Block *bp;

	for(er = allos; er != nil; er = er->next){
		while((bp = qget(er->q)) != nil){
			rlock(er->ifc);
			if(waserror()){
				runlock(er->ifc);
				continue;
			}
			er->ifc->in++;
			if(er->ifc->lifc == nil)
				freeb(bp);
			else
				ipiput4(er->f, er->ifc, bp);
			runlock(er->ifc);
			poperror();
		}
	}
}

/*
 * The client end's clock tick: ask the server for whatever frames its
 * stack has sent toward us since we last asked, queue each for the pump,
 * then pump.  Called from the client's loop on every tick.
 */
void
ospreymediumpoll(void)
{
	Osrock *er;
	uchar back[Ringmtu];
	long rn;
	int i;

	er = ringrock();
	if(er == nil || !er->client)
		return;
	for(i = 0; i < 64; i++){		/* bounded: a flood cannot keep the loop here */
		rn = ring9p_frame(nil, 0, back, sizeof back);
		if(rn <= 0)
			break;
		ringarrived(er, back, rn);
	}
	ospreymediumpump();
}

/*
 * A frame that arrived over the osprey ring from a peer container, for
 * the stack at this end: the device-carried form of the medium, where
 * the two ends are two containers and the ring carries the frame between
 * them.  It is injected into this container's ring-bound osprey
 * interface (the last bound, if none is) exactly as a locally-queued
 * frame is by the pump, so from the stack's point of view a frame from
 * the peer container is indistinguishable from one a paired interface
 * wrote.  Returns the count taken.  Called from the server loop when a
 * Reqframe request arrives on the ring.
 */
long
ospreymediumreceive(uchar *frame, long n, uvlong fromcontainer)
{
	Osrock *er;
	Block *bp;

	er = ringrock();
	if(er == nil)
		er = allos;
	if(er == nil || n <= 0)
		return -1;
	ringrx++;
	print("osprey medium: a %ld-byte frame arrived over the ring from container %llud and was handed to the stack at this end - the device-carried medium\n",
		n, fromcontainer);
	bp = allocb(n);
	if(bp == nil)
		return -1;
	memmove(bp->wp, frame, n);
	bp->wp += n;
	rlock(er->ifc);
	if(waserror()){
		runlock(er->ifc);
		return n;
	}
	er->ifc->in++;
	if(er->ifc->lifc == nil)
		freeb(bp);
	else
		ipiput4(er->f, er->ifc, bp);
	runlock(er->ifc);
	poperror();
	return n;
}

/*
 * The server end's outbound: one frame the stack sent toward the peer
 * container, copied out for the reply to the peer's request, or 0 when
 * there is none.  Called from the server loop answering Reqframe.
 */
long
ospreymediumtake(uchar *buf, long max)
{
	Osrock *er;
	Block *bp;
	long n;

	er = ringrock();
	if(er == nil || er->client || er->toring == nil)
		return 0;
	while((bp = qget(er->toring)) != nil){
		n = BLEN(bp);
		if(n > max){			/* cannot fit the reply: dropped, counted */
			er->ifc->outerr++;
			freeb(bp);
			continue;
		}
		memmove(buf, bp->rp, n);
		freeb(bp);
		ringtx++;
		return n;
	}
	return 0;
}

/* how many frames this end has put on and taken off the ring wire */
void
ospreymediumstats(long *tx, long *rx)
{
	*tx = ringtx;
	*rx = ringrx;
}

Medium ospreymedium =
{
.hsize=		0,
.mintu=		0,
.maxtu=		Maxtu,
.maclen=	0,
.name=		"osprey",
.bind=		ospreybind,
.unbind=	ospreyunbind,
.bwrite=	ospreybwrite,
};

void
ospreymediumlink(void)
{
	addipmedium(&ospreymedium);
}
