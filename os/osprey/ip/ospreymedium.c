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
 * This first form is a single task: bwrite enqueues onto the interface's
 * own inbound queue and the pump drains it, so a packet the stack sends
 * comes back to the stack through the loop - proving the loop-driven
 * inbound path end to end with the real stack.  The two-endpoint form
 * keeps the same shape: bwrite puts the frame on the ring to the peer,
 * and the pump drains frames the peer put on the ring to us, which the
 * loop learns about from a new oselect arm.
 */

enum { Maxtu = 64*1024 };

typedef struct Osrock Osrock;
struct Osrock
{
	Fs	*f;		/* the stack to inject into */
	Queue	*q;		/* frames arrived for this interface, to inject */
	Ipifc	*ifc;
	Osrock	*peer;		/* the interface at the other end of the wire */
	Osrock	*next;		/* all bound osprey interfaces, for the pump */
};

static Osrock *allos;		/* every bound osprey interface */

/*
 * Bind an interface to the osprey medium.  The first is a wire looped to
 * itself; when a second binds, the two are paired into one wire, so a
 * frame one writes arrives at the other.  With two independent stacks
 * (two Fs, devip's ipfs[dev]) each holding one end, this is a real
 * two-endpoint link, not a loopback.
 */
static void
ospreybind(Ipifc *ifc, int, char**)
{
	Osrock *er;

	er = smalloc(sizeof(*er));
	er->f = ifc->conv->p->f;
	er->q = qopen(1024*1024, Qmsg, nil, nil);
	er->ifc = ifc;
	er->peer = er;			/* default: a wire looped to itself */
	if(allos != nil && allos->next == nil){	/* exactly one so far: pair with it */
		er->peer = allos;
		allos->peer = er;
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
	if(er->q != nil)
		qfree(er->q);
	free(er);
	ifc->arg = nil;
}

static int ospreyanswered;	/* logged once: the stack answered a frame from the ring */

static void
ospreybwrite(Ipifc *ifc, Block *bp, int, uchar*, Routehint*)
{
	Osrock *er;
	uchar *ip;
	int ihl;

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
 * A frame that arrived over the osprey ring from a peer container, for
 * the stack at this end: the device-carried form of the medium, where
 * the two ends are two containers and the ring carries the frame between
 * them.  It is injected into this container's osprey interface exactly as
 * a locally-queued frame is by the pump, so from the stack's point of
 * view a frame from the peer container is indistinguishable from one a
 * paired interface wrote.  Returns the count taken.  Called from the
 * server loop when a Reqframe request arrives on the ring.
 */
long
ospreymediumreceive(uchar *frame, long n, uvlong fromcontainer)
{
	Osrock *er;
	Block *bp;

	er = allos;			/* this container's osprey interface */
	if(er == nil || n <= 0)
		return -1;
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
