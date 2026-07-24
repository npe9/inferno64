/*
 * Virtio-pci ethernet (QEMU -M virt -device virtio-net-pci).
 * Modern transport via capabilities discovered by pcivirt.c.
 * Ring/kproc path mirrors ethervirtiommio.c.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"
#include "../port/netif.h"
#include "../port/etherif.h"

typedef struct Vring Vring;
typedef struct Vdesc Vdesc;
typedef struct Vused Vused;
typedef struct Vqueue Vqueue;
typedef struct Ctlr Ctlr;

enum {
	VirtioPciVendor	= 0x1AF4,
	VirtioNetLegacy	= 0x1000,
	VirtioNetModern	= 0x1041,

	Sacknowledge	= 1,
	Sdriver		= 2,
	Sdriverok	= 4,
	Sfeatureok	= 8,
	Sfailed		= 0x80,

	/* common cfg offsets */
	CdevFeatSel	= 0,
	CdevFeat	= 4,
	CdrvFeatSel	= 8,
	CdrvFeat	= 12,
	CnumQueues	= 18,
	Cstatus		= 20,
	CqSelect	= 22,
	CqSize		= 24,
	CqEnable	= 28,
	CqNotifyOff	= 30,
	CqDescLo	= 32,
	CqDescHi	= 36,
	CqAvailLo	= 40,
	CqAvailHi	= 44,
	CqUsedLo	= 48,
	CqUsedHi	= 52,

	Nlinkup		= 1<<0,
	Fmac		= 1<<5,
	Fstatus		= 1<<16,
	Fversion1	= 1<<0,	/* in features word 1 */

	Unonotify	= 1,
	Rnointerrupt	= 1,
	Dnext		= 1,
	Dwrite		= 2,

	VheaderModern	= 12,
	VBY2PG		= 4096,
#define VPGROUND(s)	ROUND(s, VBY2PG)
	Vrxq		= 0,
	Vtxq		= 1,
};

struct Vring { u16int flags; u16int idx; };
struct Vdesc { u64int addr; u32 len; u16int flags; u16int next; };
struct Vused { u32 id; u32 len; };

struct Vqueue {
	int	qsize;
	int	qmask;
	int	lastused;
	int	nintr;
	int	nnote;
	int	notifyoff;
	Vdesc	*desc;
	Vring	*avail;
	u16int	*availent;
	u16int	*availevent;
	Vring	*used;
	Vused	*usedent;
	u16int	*usedevent;
	Rendez	*r;
};

struct Ctlr {
	int	attached;
	int	irq;
	int	hdrsize;
	int	active;
	int	nqueue;
	u32	feat;
	u32	notify_mul;
	uchar	*common;
	uchar	*notify;
	uchar	*isr;
	uchar	*device;
	Ctlr	*next;
	Vqueue	*queue[2];
};

#define cr8(c,o)	(*(volatile u8*)((c)->common+(o)))
#define cr16(c,o)	(*(volatile u16*)((c)->common+(o)))
#define cr32(c,o)	(*(volatile u32*)((c)->common+(o)))
#define cw8(c,o,v)	(*(volatile u8*)((c)->common+(o)) = (u8)(v))
#define cw16(c,o,v)	(*(volatile u16*)((c)->common+(o)) = (u16)(v))
#define cw32(c,o,v)	(*(volatile u32*)((c)->common+(o)) = (u32)(v))

static void
cw64(Ctlr *c, int low, uvlong v)
{
	cw32(c, low, (u32)v);
	cw32(c, low+4, (u32)(v>>32));
}

static Ctlr *ctlrhead;
static Lock attachlock;

static int
vhasroom(void *v)
{
	Vqueue *q = v;
	return q->lastused != q->used->idx;
}

static void
vqnotify(Ctlr *ctlr, int x)
{
	Vqueue *q;
	u16 *n;

	coherence();
	q = ctlr->queue[x];
	if(q->used->flags & Unonotify)
		return;
	q->nnote++;
	n = (u16*)(ctlr->notify + (uintptr)q->notifyoff * ctlr->notify_mul);
	*n = (u16)x;
}

static void
txproc(void *v)
{
	uchar *header;
	Block **blocks;
	Ether *edev;
	Ctlr *ctlr;
	Vqueue *q;
	Vused *u;
	Block *b;
	int i, j, hsz;

	edev = v;
	ctlr = edev->ctlr;
	q = ctlr->queue[Vtxq];
	hsz = ctlr->hdrsize;
	header = smalloc(hsz);
	memset(header, 0, hsz);
	blocks = smalloc(sizeof(Block*) * (q->qsize/2));

	for(i = 0; i < q->qsize/2; i++){
		j = i << 1;
		q->desc[j].addr = PADDR(header);
		q->desc[j].len = hsz;
		q->desc[j].next = j | 1;
		q->desc[j].flags = Dnext;
		q->availent[i] = q->availent[i + q->qsize/2] = j;
		j |= 1;
		q->desc[j].next = 0;
		q->desc[j].flags = 0;
	}
	q->avail->flags &= ~Rnointerrupt;

	while(waserror())
		;
	while((b = qbread(edev->oq, 1000000)) != nil){
		for(;;){
			while((i = q->lastused) != q->used->idx){
				u = &q->usedent[i & q->qmask];
				i = (u->id & q->qmask) >> 1;
				if(blocks[i] == nil)
					break;
				freeb(blocks[i]);
				blocks[i] = nil;
				q->lastused++;
			}
			i = q->avail->idx & (q->qmask >> 1);
			if(blocks[i] == nil)
				break;
			if(!vhasroom(q))
				tsleep(q->r, vhasroom, q, 100);
		}
		blocks[i] = b;
		j = (i << 1) | 1;
		q->desc[j].addr = PADDR(b->rp);
		q->desc[j].len = BLEN(b);
		coherence();
		q->avail->idx++;
		vqnotify(ctlr, Vtxq);
		if(!vhasroom(q))
			tsleep(q->r, vhasroom, q, 100);
	}
	pexit("ether out queue closed", 1);
}

static void
rxproc(void *v)
{
	uchar *header;
	Block **blocks;
	Ether *edev;
	Ctlr *ctlr;
	Vqueue *q;
	Vused *u;
	Block *b;
	int i, j, hsz;

	edev = v;
	ctlr = edev->ctlr;
	q = ctlr->queue[Vrxq];
	hsz = ctlr->hdrsize;
	header = smalloc(hsz);
	blocks = smalloc(sizeof(Block*) * (q->qsize/2));

	for(i = 0; i < q->qsize/2; i++){
		j = i << 1;
		q->desc[j].addr = PADDR(header);
		q->desc[j].len = hsz;
		q->desc[j].next = j | 1;
		q->desc[j].flags = Dwrite|Dnext;
		q->availent[i] = q->availent[i + q->qsize/2] = j;
		j |= 1;
		q->desc[j].next = 0;
		q->desc[j].flags = Dwrite;
	}
	q->avail->flags &= ~Rnointerrupt;

	while(waserror())
		;
	for(;;){
		do {
			i = q->avail->idx & (q->qmask >> 1);
			if(blocks[i] != nil)
				break;
			if((b = iallocb(ETHERMAXTU)) == nil)
				break;
			blocks[i] = b;
			j = (i << 1) | 1;
			q->desc[j].addr = PADDR(b->rp);
			q->desc[j].len = BALLOC(b);
			coherence();
			q->avail->idx++;
		} while(q->avail->idx != q->used->idx);
		vqnotify(ctlr, Vrxq);
		if(!vhasroom(q))
			tsleep(q->r, vhasroom, q, 100);
		while((i = q->lastused) != q->used->idx) {
			u = &q->usedent[i & q->qmask];
			i = (u->id & q->qmask) >> 1;
			if((b = blocks[i]) == nil)
				break;
			blocks[i] = nil;
			if(u->len < hsz){
				freeb(b);
				q->lastused++;
				continue;
			}
			b->wp = b->rp + u->len - hsz;
			etheriq(edev, b);
			q->lastused++;
		}
	}
}

static void
interrupt(Ureg*, void *arg)
{
	Ether *edev;
	Ctlr *ctlr;
	Vqueue *q;
	int i;
	u8 isr;

	edev = arg;
	ctlr = edev->ctlr;
	if(ctlr->isr == nil)
		return;
	isr = *ctlr->isr;	/* read clears */
	if(isr == 0)
		return;
	for(i = 0; i < ctlr->nqueue; i++){
		q = ctlr->queue[i];
		if(vhasroom(q)){
			q->nintr++;
			wakeup(q->r);
		}
	}
}

static void
attach(Ether *edev)
{
	char name[KNAMELEN];
	Ctlr *ctlr;

	ctlr = edev->ctlr;
	lock(&attachlock);
	if(ctlr->attached){
		unlock(&attachlock);
		return;
	}
	ctlr->attached = 1;
	unlock(&attachlock);
	cw8(ctlr, Cstatus, cr8(ctlr, Cstatus) | Sdriverok);
	snprint(name, sizeof name, "#l%drx", edev->ctlrno);
	kproc(name, rxproc, edev, 0);
	snprint(name, sizeof name, "#l%dtx", edev->ctlrno);
	kproc(name, txproc, edev, 0);
}

static void
shutdown(Ether *edev)
{
	Ctlr *ctlr;

	ctlr = edev->ctlr;
	cw8(ctlr, Cstatus, 0);
}

static long
ifstat(Ether *edev, void *a, long n, ulong offset)
{
	char buf[128];
	Ctlr *ctlr;

	ctlr = edev->ctlr;
	snprint(buf, sizeof buf, "virtiopci irq %d feat %#ux nq %d\n",
		ctlr->irq, ctlr->feat, ctlr->nqueue);
	return readstr(offset, a, n, buf);
}

static int
queuesize(int n)
{
	return VPGROUND(n*sizeof(Vdesc))
		+ VPGROUND(sizeof(Vring) + n*sizeof(u16int) + sizeof(u16int))
		+ VPGROUND(sizeof(Vring) + n*sizeof(Vused) + sizeof(u16int));
}

static Vqueue*
mkvqueue(int n)
{
	Vqueue *q;
	uchar *p;

	q = mallocz(sizeof(Vqueue), 1);
	if(q == nil)
		return nil;
	q->r = mallocz(sizeof(Rendez), 1);
	p = mallocalign(queuesize(n), VBY2PG, 0, 0);
	if(q->r == nil || p == nil){
		free(q->r);
		free(q);
		return nil;
	}
	q->qsize = n;
	q->qmask = n - 1;
	q->desc = (Vdesc*)p;
	p += VPGROUND(n*sizeof(Vdesc));
	q->avail = (Vring*)p;
	q->availent = (u16int*)(p + sizeof(Vring));
	q->availevent = q->availent + n;
	p += VPGROUND(sizeof(Vring) + n*sizeof(u16int) + sizeof(u16int));
	q->used = (Vring*)p;
	q->usedent = (Vused*)(p + sizeof(Vring));
	q->usedevent = (u16int*)(q->usedent + n);
	return q;
}

static int
vqsetup(Ctlr *c, int i)
{
	Vqueue *q;
	uvlong pa;

	q = c->queue[i];
	cw16(c, CqSelect, i);
	cw16(c, CqSize, q->qsize);
	q->notifyoff = cr16(c, CqNotifyOff);
	pa = PADDR(q->desc);
	cw64(c, CqDescLo, pa);
	pa = PADDR(q->avail);
	cw64(c, CqAvailLo, pa);
	pa = PADDR(q->used);
	cw64(c, CqUsedLo, pa);
	coherence();
	cw16(c, CqEnable, 1);
	return 0;
}

static Ctlr*
pciprobe(void)
{
	PciDev *d;
	Ctlr *c, *h, *t;
	Vqueue *q;
	u32 feat0, feat1, want;
	int i, n, nq;

	h = t = nil;
	want = Fmac | Fstatus;
	d = nil;
	for(;;){
		d = pcimatch(d, VirtioPciVendor, 0);
		if(d == nil)
			break;
		if(d->did != VirtioNetLegacy && d->did != VirtioNetModern)
			continue;
		if(d->common == nil || d->notify == nil || d->device == nil){
			print("ethervirtiopci: %d.%d.%d missing caps\n",
				d->bus, d->dev, d->fn);
			continue;
		}
		if((c = mallocz(sizeof(Ctlr), 1)) == nil)
			break;
		c->common = d->common;
		c->notify = d->notify;
		c->isr = d->isr;
		c->device = d->device;
		c->notify_mul = d->notify_off_mul ? d->notify_off_mul : 1;
		c->irq = d->irq;
		c->hdrsize = VheaderModern;

		cw8(c, Cstatus, 0);
		cw8(c, Cstatus, Sacknowledge|Sdriver);

		cw32(c, CdevFeatSel, 0);
		feat0 = cr32(c, CdevFeat);
		cw32(c, CdevFeatSel, 1);
		feat1 = cr32(c, CdevFeat);
		c->feat = feat0 & want;
		cw32(c, CdrvFeatSel, 0);
		cw32(c, CdrvFeat, c->feat);
		cw32(c, CdrvFeatSel, 1);
		cw32(c, CdrvFeat, feat1 & Fversion1);
		cw8(c, Cstatus, Sacknowledge|Sdriver|Sfeatureok);
		if(!(cr8(c, Cstatus) & Sfeatureok)){
			print("ethervirtiopci: FEATURES_OK rejected\n");
			cw8(c, Cstatus, Sfailed);
			free(c);
			continue;
		}

		for(i = 0; i < 2; i++){
			cw16(c, CqSelect, i);
			n = cr16(c, CqSize);
			if(n == 0 || (n & (n-1)) != 0)
				break;
			if(n > 256)
				n = 256;
			cw16(c, CqSize, n);
			if((q = mkvqueue(n)) == nil)
				break;
			c->queue[i] = q;
			if(vqsetup(c, i) < 0)
				break;
		}
		nq = i;
		if(nq < 2){
			print("ethervirtiopci: no queues\n");
			cw8(c, Cstatus, Sfailed);
			free(c);
			continue;
		}
		c->nqueue = nq;

		print("virtiopci: net");
		print(" irq "); print("%d", c->irq);
		print(" nq "); print("%d", nq);
		print(" qsz "); print("%d", c->queue[0]->qsize);
		print(" ea ");
		for(i = 0; i < Eaddrlen; i++)
			print("%.2ux", c->device[i]);
		print("\n");

		if(h == nil)
			h = c;
		else
			t->next = c;
		t = c;
	}
	return h;
}

static int
reset(Ether *edev)
{
	static uchar zeros[Eaddrlen];
	Ctlr *ctlr;
	int i;

	if(ctlrhead == nil)
		ctlrhead = pciprobe();

	for(ctlr = ctlrhead; ctlr != nil; ctlr = ctlr->next){
		if(ctlr->active)
			continue;
		ctlr->active = 1;
		break;
	}
	if(ctlr == nil)
		return -1;

	edev->ctlr = ctlr;
	edev->port = (ulong)(uintptr)ctlr->common;
	edev->irq = ctlr->irq;
	edev->tbdf = BUSUNKNOWN;
	edev->mbps = 1000;
	edev->link = 1;
	if((ctlr->feat & Fstatus) != 0)
		edev->link = (ctlr->device[6] & Nlinkup) != 0;
	if((ctlr->feat & Fmac) != 0 && memcmp(edev->ea, zeros, Eaddrlen) == 0){
		for(i = 0; i < Eaddrlen; i++)
			edev->ea[i] = ctlr->device[i];
	}
	edev->arg = edev;
	edev->attach = attach;
	edev->shutdown = shutdown;
	edev->ifstat = ifstat;
	intrenable(edev->irq, edev->tbdf, interrupt, edev, edev->name);
	return 0;
}

void
ethervirtiopcilink(void)
{
	addethercard("virtiopci", reset);
}
