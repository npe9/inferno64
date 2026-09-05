#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

#include "ip.h"
#include "ipv6.h"

/*
 * The real stack on a real wire, the exokernel way: an ethernet medium
 * whose device is the virtio network card the kernel exposed to this
 * container and netvirtio.c drives from user space.  It is
 * ethermedium.c with the three channels to a kernel ether device
 * replaced by calls into that driver - IPv4 and ARP, which is what the
 * wire between two of these machines needs - and with its reading not
 * in a kproc that blocks in a device but in ospreyvnetpump, which the
 * server loop calls when the device's interrupt gives its semaphore and
 * on every tick, in the loop's own context, like ospreymedium's pump.
 * One device, so one interface.
 */
enum {
	ETHERHDRSIZE	= 14,
	ETHERMINTU	= 60,
	ETARP		= 0x0806,
	ETIP4		= 0x0800,
	ARPREQUEST	= 1,
	ARPREPLY	= 2,
	Maxframe	= 1514,
};

typedef struct Etherhdr Etherhdr;
struct Etherhdr { uchar d[6]; uchar s[6]; uchar t[2]; };

typedef struct Etherarp Etherarp;
struct Etherarp {
	uchar	d[6], s[6], type[2];
	uchar	hrd[2], pro[2], hln, pln, op[2];
	uchar	sha[6], spa[4], tha[6], tpa[4];
};

typedef struct Vnetrock Vnetrock;
struct Vnetrock { Fs *f; Ipifc *ifc; };

static Ipifc *vnetifc;		/* the one interface on the one device */
static Queue *vnettxq;		/* frames the device had no slot for, in order, until it has */
static long vnetqueued, vnetdrained;

extern int vnet_ready(void);
extern void vnet_mac(uchar*);
extern int vnet_send(uchar*, long);
extern long vnet_recv(uchar*, long);
extern int vnet_cansend(void);

static int shown;		/* the first few frames each way, said, as evidence of the wire */

/*
 * A frame out: to the device if it has a slot and nothing is waiting
 * ahead of it, else onto the medium's transmit queue, which the pump
 * drains in order when the device's interrupt says a slot is free.
 * The driver neither drops nor waits.
 */
static void
vnetout(Block *bp)
{
	uchar *f;

	if(BLEN(bp) < ETHERMINTU)
		bp = adjustblock(bp, ETHERMINTU);
	f = bp->rp;
	if(shown < 6){
		shown++;
		print("vnet: out %ld bytes, type %#.4ux, to %02x:%02x:%02x:%02x:%02x:%02x\n",
			BLEN(bp), (f[12]<<8)|f[13], f[0], f[1], f[2], f[3], f[4], f[5]);
	}
	if(vnettxq != nil && qlen(vnettxq) == 0 && vnet_send(bp->rp, BLEN(bp)) == 0){
		freeb(bp);
		return;
	}
	if(vnettxq == nil || qpass(vnettxq, bp) < 0){
		if(vnetifc != nil)
			vnetifc->outerr++;
		return;			/* qpass frees it */
	}
	vnetqueued++;
}

/* what waited for a slot, to the device now that it has one */
static void
vnetdrain(void)
{
	Block *bp;

	if(vnettxq == nil)
		return;
	while(vnet_cansend() && (bp = qget(vnettxq)) != nil){
		if(vnet_send(bp->rp, BLEN(bp)) < 0){
			qputback(vnettxq, bp);	/* the slot went meanwhile: next time */
			break;
		}
		freeb(bp);
		vnetdrained++;
	}
}

static void
vnetbind(Ipifc *ifc, int, char**)
{
	Vnetrock *er;

	if(!vnet_ready())
		error("no network device was exposed to this container");
	if(vnetifc != nil)
		error("the device is bound already");
	er = smalloc(sizeof(*er));
	er->f = ifc->conv->p->f;
	er->ifc = ifc;
	vnet_mac(ifc->mac);
	ifc->arg = er;
	if(vnettxq == nil)
		vnettxq = qopen(256*1024, Qmsg, nil, nil);
	vnetifc = ifc;
}

static void
vnetunbind(Ipifc *ifc)
{
	free(ifc->arg);
	ifc->arg = nil;
	vnetifc = nil;
}

static Block*
newEARP(void)
{
	Block *bp;

	bp = allocb(ETHERMINTU);
	bp->wp += ETHERMINTU;
	memset(bp->rp, 0, ETHERMINTU);
	return bp;
}

static void
sendarpreq(Fs *f, Arpent *a)
{
	Block *bp;
	Etherarp *e;
	Ipifc *ifc = a->ifc;
	uchar targ[IPv4addrlen], src[IPv4addrlen];

	memmove(targ, a->ip+IPv4off, IPv4addrlen);
	arpcontinue(f->arp, a);
	if(!ipv4local(ifc, src, 0, targ))
		return;
	bp = newEARP();
	e = (Etherarp*)bp->rp;
	memmove(e->tpa, targ, sizeof(e->tpa));
	memmove(e->spa, src, sizeof(e->spa));
	memmove(e->sha, ifc->mac, sizeof(e->sha));
	memset(e->d, 0xff, sizeof(e->d));
	memmove(e->s, ifc->mac, sizeof(e->s));
	hnputs(e->type, ETARP);
	hnputs(e->hrd, 1);
	hnputs(e->pro, ETIP4);
	e->hln = sizeof(e->sha);
	e->pln = sizeof(e->spa);
	hnputs(e->op, ARPREQUEST);
	vnetout(bp);
}

static void
sendgarp(Ipifc *ifc, uchar *ip)
{
	Block *bp;
	Etherarp *e;

	bp = newEARP();
	e = (Etherarp*)bp->rp;
	memmove(e->tpa, ip+IPv4off, sizeof(e->tpa));
	memmove(e->spa, ip+IPv4off, sizeof(e->spa));
	memmove(e->sha, ifc->mac, sizeof(e->sha));
	memset(e->d, 0xff, sizeof(e->d));
	memmove(e->s, ifc->mac, sizeof(e->s));
	hnputs(e->type, ETARP);
	hnputs(e->hrd, 1);
	hnputs(e->pro, ETIP4);
	e->hln = sizeof(e->sha);
	e->pln = sizeof(e->spa);
	hnputs(e->op, ARPREQUEST);
	vnetout(bp);
}

static int
multicastea(uchar *ea, uchar *ip)
{
	if(ipismulticast(ip) == V4){
		ea[0] = 0x01; ea[1] = 0x00; ea[2] = 0x5e;
		ea[3] = ip[13] & 0x7f; ea[4] = ip[14]; ea[5] = ip[15];
		return V4;
	}
	return 0;
}

static Block*
multicastarp(Fs *f, Arpent *a, uchar *mac, Routehint *rh)
{
	if(ipforme(f, a->ip) == Rbcast){
		memset(mac, 0xff, a->ifc->m->maclen);
		return arpresolve(f->arp, a, mac, rh);
	}
	if(multicastea(mac, a->ip) == V4)
		return arpresolve(f->arp, a, mac, rh);
	return nil;
}

static void
vnetbwrite(Ipifc *ifc, Block *bp, int version, uchar *ip, Routehint *rh)
{
	Etherhdr *eh;
	Arpent *a;
	uchar mac[6];
	Vnetrock *er = ifc->arg;

	if(version != V4){
		freeb(bp);
		return;
	}
	a = arpget(er->f->arp, bp, version, ifc, ip, mac, rh);
	if(a != nil){
		bp = multicastarp(er->f, a, mac, rh);
		if(bp == nil){
			if(a->utime - a->ctime < RETRANS_TIMER){
				arprelease(er->f->arp, a);
				return;
			}
			sendarpreq(er->f, a);	/* unlocks arp; the packet waits on the entry */
			return;
		}
	}
	bp = padblock(bp, ETHERHDRSIZE);
	eh = (Etherhdr*)bp->rp;
	memmove(eh->s, ifc->mac, sizeof(eh->s));
	memmove(eh->d, mac, sizeof(eh->d));
	eh->t[0] = 0x08;
	eh->t[1] = 0x00;
	vnetout(bp);
	ifc->out++;
}

static void
recvarp(Ipifc *ifc, Block *ebp)
{
	int forme;
	Block *rbp;
	Etherarp *e, *r;
	static uchar eprinted[4];
	Vnetrock *er = ifc->arg;

	rlock(ifc);
	e = (Etherarp*)ebp->rp;
	switch(nhgets(e->op)){
	default:
		break;
	case ARPREPLY:
		if(e->sha[0] & 1)
			break;
		if(arpforme(er->f, V4, e->spa, e->tpa, ifc)){
			if(memcmp(e->sha, ifc->mac, sizeof(e->sha)) != 0){
				print("arprep: 0x%E/0x%E also has ip addr %V\n", e->s, e->sha, e->spa);
				break;
			}
		}
		arpenter(er->f, V4, e->spa, e->sha, sizeof(e->sha), e->tpa, ifc, 1);
		break;
	case ARPREQUEST:
		if(e->sha[0] & 1)
			break;
		if(ifc->lifc == nil)
			break;
		if(arpforme(er->f, V4, e->spa, e->tpa, ifc)){
			if(memcmp(e->sha, ifc->mac, sizeof(e->sha)) != 0){
				if(memcmp(eprinted, e->spa, sizeof(e->spa)) != 0){
					print("arpreq: 0x%E also has ip addr %V\n", e->sha, e->spa);
					memmove(eprinted, e->spa, sizeof(e->spa));
				}
				break;
			}
		} else if(memcmp(e->sha, ifc->mac, sizeof(e->sha)) == 0){
			print("arpreq: %V also has ether addr %E\n", e->spa, e->sha);
			break;
		}
		forme = arpforme(er->f, V4, e->tpa, e->spa, ifc);
		if(arpenter(er->f, V4, e->spa, e->sha, sizeof(e->sha), e->tpa, ifc, !forme) < 0 || !forme)
			break;
		rbp = newEARP();
		r = (Etherarp*)rbp->rp;
		hnputs(r->type, ETARP);
		hnputs(r->hrd, 1);
		hnputs(r->pro, ETIP4);
		r->hln = sizeof(r->sha);
		r->pln = sizeof(r->spa);
		hnputs(r->op, ARPREPLY);
		memmove(r->tha, e->sha, sizeof(r->tha));
		memmove(r->tpa, e->spa, sizeof(r->tpa));
		memmove(r->sha, ifc->mac, sizeof(r->sha));
		memmove(r->spa, e->tpa, sizeof(r->spa));
		memmove(r->d, e->sha, sizeof(r->d));
		memmove(r->s, ifc->mac, sizeof(r->s));
		runlock(ifc);
		freeb(ebp);
		vnetout(rbp);
		return;
	}
	runlock(ifc);
	freeb(ebp);
}

/*
 * Everything the device has received: ARP to the resolver, IPv4 into
 * the stack, the rest dropped.  Called from the server loop when the
 * device's semaphore is given and on every tick.
 */
void
ospreyvnetpump(void)
{
	Ipifc *ifc;
	Vnetrock *er;
	Block *bp;
	uchar frame[Maxframe];
	long n;
	int type;

	if((ifc = vnetifc) == nil || (er = ifc->arg) == nil)
		return;
	vnetdrain();			/* the device's interrupt: slots may have freed */
	while((n = vnet_recv(frame, sizeof frame)) > 0){
		if(n < ETHERHDRSIZE)
			continue;
		bp = allocb(n);
		memmove(bp->wp, frame, n);
		bp->wp += n;
		type = (frame[12]<<8) | frame[13];
		if(shown < 6){
			shown++;
			print("vnet: in %ld bytes, type %#.4ux, from %02x:%02x:%02x:%02x:%02x:%02x\n",
				n, type, frame[6], frame[7], frame[8], frame[9], frame[10], frame[11]);
		}
		if(type == ETARP){
			recvarp(ifc, bp);
			continue;
		}
		if(type != ETIP4){
			freeb(bp);
			continue;
		}
		rlock(ifc);
		if(waserror()){
			runlock(ifc);
			continue;
		}
		ifc->in++;
		if(ifc->lifc == nil)
			freeb(bp);
		else {
			bp->rp += ETHERHDRSIZE;
			ipiput4(er->f, ifc, bp);
		}
		runlock(ifc);
		poperror();
	}
}

static void
vnetaddmulti(Ipifc*, uchar*, uchar*)
{
}

static void
vnetdelmulti(Ipifc*, uchar*, uchar*)
{
}

static void
vnetareg(Fs*, Ipifc *ifc, Iplifc*, uchar *ip)
{
	if(ipcmp(ip, IPnoaddr) == 0 || ipcmp(ip, v4prefix) == 0)
		return;
	if(isv4(ip))
		sendgarp(ifc, ip);
}

/* how many frames waited for a slot and were sent later, for the record */
void
ospreyvnetqstats(long *queued, long *drained)
{
	*queued = vnetqueued;
	*drained = vnetdrained;
}

Medium ospreyvnetmedium =
{
.name=		"vnet",
.hsize=		ETHERHDRSIZE,
.mintu=		ETHERMINTU,
.maxtu=		ETHERHDRSIZE+1500,
.maclen=	6,
.bind=		vnetbind,
.unbind=	vnetunbind,
.bwrite=	vnetbwrite,
.addmulti=	vnetaddmulti,
.delmulti=	vnetdelmulti,
.areg=		vnetareg,
};

void
ospreyvnetmediumlink(void)
{
	addipmedium(&ospreyvnetmedium);
}
