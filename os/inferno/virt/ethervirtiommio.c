/*
 * Virtio-mmio ethernet (QEMU -M virt).  Rings from os/pc/ethervirtio.c;
 * MMIO transport from sdvirtiommio.c.  Negotiates Fmac|Fstatus only (no ctlq).
 *
 * Ctlr layout is KenC-friendly: scalar ints first, then pointers (no embedded
 * Lock/Rendez/Vqueue — those mis-offset fields under KenC LP64).
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
	TypNet		= 1,

	Sacknowledge	= 1,
	Sdriver		= 2,
	Sdriverok	= 4,
	Sfeatureok	= 8,
	Sfailed		= 0x80,

	/* virtio-mmio */
	Magic		= 0x00,
	Version		= 0x04,
	DeviceId	= 0x08,
	VendorId	= 0x0c,
	DevFeatures	= 0x10,
	DevFeaturesSel	= 0x14,
	DrvFeatures	= 0x20,
	DrvFeaturesSel	= 0x24,
	GuestPageSize	= 0x28,
	QueueSel	= 0x30,
	QueueNumMax	= 0x34,
	QueueNum	= 0x38,
	QueueAlign	= 0x3c,
	QueuePfn	= 0x40,
	QueueReady	= 0x44,
	QueueNotify	= 0x50,
	InterruptStatus	= 0x60,
	InterruptAck	= 0x64,
	Status		= 0x70,
	QueueDescLow	= 0x80,
	QueueDescHigh	= 0x84,
	QueueAvailLow	= 0x90,
	QueueAvailHigh	= 0x94,
	QueueUsedLow	= 0xa0,
	QueueUsedHigh	= 0xa4,
	Config		= 0x100,

	VirtMagic	= 0x74726976,	/* "virt" */

	Nlinkup		= 1<<0,

	Fmac		= 1<<5,
	Fstatus		= 1<<16,

	Unonotify	= 1,
	Rnointerrupt	= 1,

	Dnext		= 1,
	Dwrite		= 2,

	VringSize	= 4,
	VdescSize	= 16,
	VusedSize	= 8,
	/* legacy virtio_net_hdr is 10; VERSION_1 adds num_buffers → 12 */
	VheaderLegacy	= 10,
	VheaderModern	= 12,

	VBY2PG		= 4096,
#define VPGROUND(s)	ROUND(s, VBY2PG)

	Vrxq		= 0,
	Vtxq		= 1,
};

struct Vring
{
	u16int	flags;
	u16int	idx;
};

struct Vdesc
{
	u64int	addr;
	u32	len;
	u16int	flags;
	u16int	next;
};

struct Vused
{
	u32	id;
	u32	len;
};

struct Vqueue
{
	int	qsize;
	int	qmask;
	int	lastused;
	int	nintr;
	int	nnote;
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
	int	vers;
	int	irq;
	int	hdrsize;
	int	active;
	int	nqueue;
	u32	feat;
	uintptr	regs;
	Ctlr	*next;
	Vqueue	*queue[2];
};

#define csr32r(c, o)	(*(volatile u32*)((c)->regs+(o)))
#define csr32w(c, o, v)	(*(volatile u32*)((c)->regs+(o)) = (u32)(v))
#define csr8r(c, o)	(*(volatile u8*)((c)->regs+(o)))

static void
csr64w(Ctlr *c, int low, uvlong v)
{
	csr32w(c, low, (u32)v);
	csr32w(c, low+4, (u32)(v>>32));
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

	coherence();
	q = ctlr->queue[x];
	if(q->used->flags & Unonotify)
		return;
	q->nnote++;
	csr32w(ctlr, QueueNotify, x);
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
		/* poll for used ring — IRQs can be flaky under KenC/PLIC */
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

		/* poll: virtio-net IRQs can be missed under KenC/PLIC */
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
interrupt(Ureg*, void* arg)
{
	Ether *edev;
	Ctlr *ctlr;
	Vqueue *q;
	int i;

	edev = arg;
	ctlr = edev->ctlr;
	if(csr32r(ctlr, InterruptStatus) & 1){
		csr32w(ctlr, InterruptAck, 1);
		for(i = 0; i < ctlr->nqueue; i++){
			q = ctlr->queue[i];
			if(vhasroom(q)){
				q->nintr++;
				wakeup(q->r);
			}
		}
	}
}

static void
attach(Ether* edev)
{
	char name[KNAMELEN];
	Ctlr* ctlr;

	ctlr = edev->ctlr;
	lock(&attachlock);
	if(ctlr->attached){
		unlock(&attachlock);
		return;
	}
	ctlr->attached = 1;
	unlock(&attachlock);

	csr32w(ctlr, Status, csr32r(ctlr, Status) | Sdriverok);

	snprint(name, sizeof name, "#l%drx", edev->ctlrno);
	kproc(name, rxproc, edev, 0);
	snprint(name, sizeof name, "#l%dtx", edev->ctlrno);
	kproc(name, txproc, edev, 0);
}

static long
ifstat(Ether *edev, void *a, long n, ulong offset)
{
	int i, l;
	char *p;
	Ctlr *ctlr;
	Vqueue *q;

	ctlr = edev->ctlr;

	p = smalloc(READSTR);

	l = snprint(p, READSTR, "devfeat %ux\n", ctlr->feat);
	l += snprint(p+l, READSTR-l, "devstatus %ux\n", csr32r(ctlr, Status));
	if(ctlr->feat & Fstatus)
		l += snprint(p+l, READSTR-l, "netstatus %ux\n",
			csr8r(ctlr, Config+6));

	for(i = 0; i < ctlr->nqueue; i++){
		q = ctlr->queue[i];
		l += snprint(p+l, READSTR-l,
			"vq%d size %d avail %d used %d lastused %d nintr %d nnote %d\n",
			i, q->qsize, q->avail->idx, q->used->idx,
			q->lastused, q->nintr, q->nnote);
	}

	n = readstr(offset, a, n, p);
	free(p);

	return n;
}

static void
shutdown(Ether* edev)
{
	Ctlr *ctlr = edev->ctlr;
	csr32w(ctlr, Status, 0);
}

static ulong
queuesize(ulong size)
{
	return VPGROUND(VdescSize*size + sizeof(u16int)*(3+size))
		+ VPGROUND(sizeof(u16int)*3 + VusedSize*size);
}

static Vqueue*
mkvqueue(int size)
{
	Vqueue *q;
	uchar *p;

	assert(!(size & (size - 1)) && size <= 32768);

	q = mallocz(sizeof(Vqueue), 1);
	if(q == nil)
		return nil;
	q->r = mallocz(sizeof(Rendez), 1);
	p = mallocalign(queuesize(size), VBY2PG, 0, 0);
	if(p == nil || q->r == nil){
		print("ethervirtiommio: no memory for Vqueue\n");
		free(p);
		free(q->r);
		free(q);
		return nil;
	}

	q->desc = (void*)p;
	p += VdescSize*size;
	q->avail = (void*)p;
	p += VringSize;
	q->availent = (void*)p;
	p += sizeof(u16int)*size;
	q->availevent = (void*)p;
	p += sizeof(u16int);

	p = (uchar*)VPGROUND((uintptr)p);
	q->used = (void*)p;
	p += VringSize;
	q->usedent = (void*)p;
	p += VusedSize*size;
	q->usedevent = (void*)p;

	q->qsize = size;
	q->qmask = q->qsize - 1;
	q->lastused = 0;
	q->avail->idx = 0;
	q->used->idx = 0;
	q->avail->flags |= Rnointerrupt;

	return q;
}

static int
vqsetup(Ctlr *c, int i)
{
	uvlong pa;
	Vqueue *q;

	q = c->queue[i];
	csr32w(c, QueueSel, i);
	if(c->vers >= 2){
		csr32w(c, QueueNum, q->qsize);
		csr64w(c, QueueDescLow, PADDR(q->desc));
		csr64w(c, QueueAvailLow, PADDR(q->avail));
		csr64w(c, QueueUsedLow, PADDR(q->used));
		coherence();
		csr32w(c, QueueReady, 1);
		if(csr32r(c, QueueReady) != 1){
			print("ethervirtiommio: queue %d not ready\n", i);
			return -1;
		}
	}else{
		csr32w(c, GuestPageSize, BY2PG);
		csr32w(c, QueueNum, q->qsize);
		csr32w(c, QueueAlign, BY2PG);
		pa = PADDR(q->desc);
		if(pa & (BY2PG-1)){
			print("ethervirtiommio: desc not page aligned\n");
			return -1;
		}
		coherence();
		csr32w(c, QueuePfn, (u32)(pa/BY2PG));
	}
	return 0;
}

static Ctlr*
mmioprobe(void)
{
	Ctlr *c, *h, *t;
	Vqueue *q;
	uintptr base;
	u32 magic, vers, id, feat0, feat1, n, want;
	int slot, i, hsz, nq;

	h = t = nil;
	want = Fmac | Fstatus;

	for(slot = 0; slot < VIRTIO_NDEV; slot++){
		base = VIRTIO0 + (uintptr)slot*VIRTIO_SIZE;
		magic = *(volatile u32*)(base+Magic);
		if(magic != VirtMagic)
			continue;
		vers = *(volatile u32*)(base+Version);
		id = *(volatile u32*)(base+DeviceId);
		if(id != TypNet)
			continue;
		if(vers != 1 && vers != 2){
			print("ethervirtiommio: slot ");
			print("%d", slot);
			print(" bad version ");
			print("%d\n", vers);
			continue;
		}
		if((c = mallocz(sizeof(Ctlr), 1)) == nil){
			print("ethervirtiommio: no memory for Ctlr\n");
			break;
		}
		hsz = VheaderLegacy;
		c->vers = vers;
		c->regs = base;
		c->irq = Virtio0IRQ + slot;
		c->hdrsize = hsz;

		csr32w(c, Status, 0);
		csr32w(c, Status, Sacknowledge|Sdriver);

		if(vers >= 2){
			csr32w(c, DevFeaturesSel, 0);
			feat0 = csr32r(c, DevFeatures);
			csr32w(c, DevFeaturesSel, 1);
			feat1 = csr32r(c, DevFeatures);
			c->feat = feat0 & want;
			csr32w(c, DrvFeaturesSel, 0);
			csr32w(c, DrvFeatures, c->feat);
			csr32w(c, DrvFeaturesSel, 1);
			csr32w(c, DrvFeatures, feat1 & 1);	/* VERSION_1 */
			csr32w(c, Status, Sacknowledge|Sdriver|Sfeatureok);
			if(!(csr32r(c, Status) & Sfeatureok)){
				print("ethervirtiommio: FEATURES_OK rejected\n");
				csr32w(c, Status, Sfailed);
				free(c);
				continue;
			}
			/* modern MMIO ⇒ VERSION_1 hdr layout (num_buffers) */
			hsz = VheaderModern;
			c->hdrsize = hsz;
			USED(feat1);
		}else{
			csr32w(c, DevFeaturesSel, 0);
			feat0 = csr32r(c, DevFeatures);
			c->feat = feat0 & want;
			csr32w(c, DrvFeaturesSel, 0);
			csr32w(c, DrvFeatures, c->feat);
		}

		for(i = 0; i < 2; i++){
			csr32w(c, QueueSel, i);
			n = csr32r(c, QueueNumMax);
			if(n == 0 || (n & (n-1)) != 0){
				if(i < 2)
					print("ethervirtiommio: queue %d bad size %d\n", i, n);
				break;
			}
			if(n > 256)
				n = 256;
			if((q = mkvqueue(n)) == nil)
				break;
			c->queue[i] = q;
			if(vqsetup(c, i) < 0)
				break;
		}
		nq = i;
		if(nq < 2){
			print("ethervirtiommio: no queues\n");
			csr32w(c, Status, Sfailed);
			free(c);
			continue;
		}
		c->nqueue = nq;

		print("virtiommio: net");
		print(" irq "); print("%d", c->irq);
		print(" vers "); print("%d", (int)vers);
		print(" nq "); print("%d", nq);
		print(" qsz "); print("%d", c->queue[0]->qsize);
		print(" hdr "); print("%d", hsz);
		print(" ea ");
		for(i = 0; i < Eaddrlen; i++)
			print("%.2ux", csr8r(c, Config+i));
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
reset(Ether* edev)
{
	static uchar zeros[Eaddrlen];
	Ctlr *ctlr;
	int i;

	if(ctlrhead == nil)
		ctlrhead = mmioprobe();

	for(ctlr = ctlrhead; ctlr != nil; ctlr = ctlr->next){
		if(ctlr->active)
			continue;
		if(edev->port == 0 || edev->port == (ulong)ctlr->regs){
			ctlr->active = 1;
			break;
		}
	}

	if(ctlr == nil)
		return -1;

	edev->ctlr = ctlr;
	edev->port = (ulong)ctlr->regs;
	edev->irq = ctlr->irq;
	edev->tbdf = BUSUNKNOWN;
	edev->mbps = 1000;
	edev->link = 1;
	if((ctlr->feat & Fstatus) != 0)
		edev->link = (csr8r(ctlr, Config+6) & Nlinkup) != 0;

	if((ctlr->feat & Fmac) != 0 && memcmp(edev->ea, zeros, Eaddrlen) == 0){
		for(i = 0; i < Eaddrlen; i++)
			edev->ea[i] = csr8r(ctlr, Config+i);
	}

	edev->arg = edev;
	edev->attach = attach;
	edev->shutdown = shutdown;
	edev->ifstat = ifstat;

	intrenable(edev->irq, edev->tbdf, interrupt, edev, edev->name);

	return 0;
}

void
ethervirtiommiolink(void)
{
	addethercard("virtio", reset);
}
