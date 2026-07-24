/*
 * Virtio-mmio RNG (QEMU virtio-rng-device).  TypRng=4, one request queue.
 * Fills guest buffers with host entropy and installs hwrandbuf for port/random.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

typedef struct Vring Vring;
typedef struct Vdesc Vdesc;
typedef struct Vused Vused;
typedef struct Vqueue Vqueue;
typedef struct Ctlr Ctlr;

enum {
	TypRng		= 4,

	Sacknowledge	= 1,
	Sdriver		= 2,
	Sdriverok	= 4,
	Sfeatureok	= 8,
	Sfailed		= 0x80,

	Magic		= 0x00,
	Version		= 0x04,
	DeviceId	= 0x08,
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

	VirtMagic	= 0x74726976,

	Dwrite		= 2,

	VringSize	= 4,
	VdescSize	= 16,
	VusedSize	= 8,
	VBY2PG		= 4096,
#define VPGROUND(s)	ROUND(s, VBY2PG)

	Qreq		= 0,
	Nbuf		= 8,
	Maxchunk	= 256,
};

struct Vring
{
	u16int	flags;
	u16int	idx;
};

struct Vdesc
{
	u64int	addr;
	u32int	len;
	u16int	flags;
	u16int	next;
};

struct Vused
{
	u32int	id;
	u32int	len;
};

struct Vqueue
{
	int	qsize;
	int	qmask;
	u16int	lastused;
	Vdesc	*desc;
	Vring	*avail;
	u16int	*availent;
	u16int	*availevent;
	Vring	*used;
	Vused	*usedent;
	u16int	*usedevent;
	uchar	*buf;
};

struct Ctlr
{
	int	vers;
	int	irq;
	uintptr	regs;
	Vqueue	*q;
};

static Ctlr	*rngctlr;
static QLock	rnglock;

static u32int
csr32r(Ctlr *c, int r)
{
	return *(volatile u32int*)(c->regs + r);
}

static void
csr32w(Ctlr *c, int r, u32int v)
{
	*(volatile u32int*)(c->regs + r) = v;
}

static void
csr64w(Ctlr *c, int r, u64int v)
{
	csr32w(c, r, (u32int)v);
	csr32w(c, r+4, (u32int)(v>>32));
}

static ulong
queuesize(ulong size)
{
	return VPGROUND(VdescSize*size + sizeof(u16int)*(3+size))
		+ VPGROUND(sizeof(u16int)*3 + VusedSize*size)
		+ VPGROUND(Maxchunk*size);
}

static Vqueue*
mkvqueue(int size)
{
	Vqueue *q;
	uchar *p;

	q = mallocz(sizeof(*q), 1);
	if(q == nil)
		return nil;
	p = mallocalign(queuesize(size), VBY2PG, 0, 0);
	if(p == nil){
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
	p += sizeof(u16int);
	p = (uchar*)VPGROUND((uintptr)p);
	q->buf = p;
	q->qsize = size;
	q->qmask = size - 1;
	q->lastused = 0;
	return q;
}

static int
vqsetup(Ctlr *c, Vqueue *q, int qi)
{
	u64int pa;

	csr32w(c, QueueSel, qi);
	if(c->vers >= 2){
		csr32w(c, QueueNum, q->qsize);
		csr64w(c, QueueDescLow, PADDR(q->desc));
		csr64w(c, QueueAvailLow, PADDR(q->avail));
		csr64w(c, QueueUsedLow, PADDR(q->used));
		coherence();
		csr32w(c, QueueReady, 1);
		if(csr32r(c, QueueReady) != 1)
			return -1;
	}else{
		csr32w(c, GuestPageSize, BY2PG);
		csr32w(c, QueueNum, q->qsize);
		csr32w(c, QueueAlign, BY2PG);
		pa = PADDR(q->desc);
		if(pa & (BY2PG-1))
			return -1;
		coherence();
		csr32w(c, QueuePfn, (u32int)(pa/BY2PG));
	}
	return 0;
}

static void
rnginterrupt(Ureg*, void *arg)
{
	Ctlr *c;

	c = arg;
	if(csr32r(c, InterruptStatus) & 1)
		csr32w(c, InterruptAck, 1);
}

/* Synchronous fill from virtio-rng into p[0..n). */
static void
rngfill(void *p, u32 n)
{
	Ctlr *c;
	Vqueue *q;
	uchar *a;
	ulong left, chunk, got, deadline;
	u16int idx;
	int id, mask;

	c = rngctlr;
	if(c == nil || n == 0)
		return;
	q = c->q;
	a = p;
	left = n;
	qlock(&rnglock);
	while(left > 0){
		chunk = left;
		if(chunk > Maxchunk)
			chunk = Maxchunk;
		id = 0;
		mask = q->qmask;
		q->desc[id].addr = PADDR(q->buf);
		q->desc[id].len = (u32int)chunk;
		q->desc[id].flags = Dwrite;
		q->desc[id].next = 0;
		q->availent[q->avail->idx & mask] = id;
		coherence();
		q->avail->idx++;
		coherence();
		csr32w(c, QueueNotify, Qreq);

		deadline = m->ticks + HZ;	/* ~1s */
		for(;;){
			idx = q->used->idx;
			if(q->lastused != idx)
				break;
			if((long)(m->ticks - deadline) > 0){
				qunlock(&rnglock);
				return;
			}
			/* Must not sleep under ilock; qlock allows sched. */
			if(up != nil)
				sched();
		}
		USED(id);
		got = q->usedent[q->lastused & mask].len;
		q->lastused++;
		if(got > chunk)
			got = chunk;
		if(got > 0){
			memmove(a, q->buf, got);
			a += got;
			left -= got;
		}else
			break;
	}
	qunlock(&rnglock);
}

static Ctlr*
mmioprobe(void)
{
	Ctlr *c;
	Vqueue *q;
	uintptr base;
	u32int magic, vers, id, feat1, n;
	int slot;

	for(slot = 0; slot < VIRTIO_NDEV; slot++){
		base = VIRTIO0 + (uintptr)slot*VIRTIO_SIZE;
		magic = *(volatile u32int*)(base+Magic);
		if(magic != VirtMagic)
			continue;
		vers = *(volatile u32int*)(base+Version);
		id = *(volatile u32int*)(base+DeviceId);
		if(id != TypRng)
			continue;
		if(vers != 1 && vers != 2)
			continue;
		c = mallocz(sizeof(*c), 1);
		if(c == nil)
			return nil;
		c->vers = vers;
		c->regs = base;
		c->irq = Virtio0IRQ + slot;

		csr32w(c, Status, 0);
		csr32w(c, Status, Sacknowledge|Sdriver);
		if(vers >= 2){
			csr32w(c, DevFeaturesSel, 1);
			feat1 = csr32r(c, DevFeatures);
			csr32w(c, DrvFeaturesSel, 0);
			csr32w(c, DrvFeatures, 0);
			csr32w(c, DrvFeaturesSel, 1);
			csr32w(c, DrvFeatures, feat1 & 1);
			csr32w(c, Status, Sacknowledge|Sdriver|Sfeatureok);
			if(!(csr32r(c, Status) & Sfeatureok)){
				csr32w(c, Status, Sfailed);
				free(c);
				continue;
			}
		}else{
			csr32w(c, DrvFeaturesSel, 0);
			csr32w(c, DrvFeatures, 0);
		}

		csr32w(c, QueueSel, Qreq);
		n = csr32r(c, QueueNumMax);
		if(n == 0){
			csr32w(c, Status, Sfailed);
			free(c);
			continue;
		}
		if(n > Nbuf)
			n = Nbuf;
		while(n & (n-1))
			n--;
		q = mkvqueue(n);
		if(q == nil){
			csr32w(c, Status, Sfailed);
			free(c);
			continue;
		}
		c->q = q;
		if(vqsetup(c, q, Qreq) < 0){
			csr32w(c, Status, Sfailed);
			free(q);
			free(c);
			continue;
		}
		csr32w(c, Status, Sacknowledge|Sdriver|Sfeatureok|Sdriverok);
		print("virtiommio: rng");
		print(" @ "); print("%lux", (ulong)c->regs);
		print(" irq "); print("%d", c->irq);
		print(" v"); print("%d", c->vers);
		print("\n");
		return c;
	}
	return nil;
}

void
rngvirtiommiolink(void)
{
	Ctlr *c;

	c = mmioprobe();
	if(c == nil)
		return;
	rngctlr = c;
	hwrandbuf = rngfill;
	intrenable(c->irq, 0, rnginterrupt, c, "virtrng");
}
