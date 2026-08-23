/*
 * Virtio-mmio block (QEMU -M virt).  TypBlk only; rings based on os/pc/sdvirtio.c.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"
#include "../port/sd.h"

typedef struct Vring Vring;
typedef struct Vdesc Vdesc;
typedef struct Vused Vused;
typedef struct Vqueue Vqueue;
typedef struct Vdev Vdev;

enum {
	TypBlk		= 2,

	Acknowledge	= 1,
	Driver		= 2,
	DriverOk	= 4,
	FeaturesOk	= 8,
	Failed		= 0x80,

	Next		= 1,
	Write		= 2,

	VringSize	= 4,

	/* virtio-mmio */
	Magic		= 0x00,
	Version		= 0x04,
	DeviceId	= 0x08,
	VendorId	= 0x0c,
	DevFeatures	= 0x10,
	DevFeaturesSel	= 0x14,
	DrvFeatures	= 0x20,
	DrvFeaturesSel	= 0x24,
	GuestPageSize	= 0x28,	/* legacy */
	QueueSel	= 0x30,
	QueueNumMax	= 0x34,
	QueueNum	= 0x38,
	QueueAlign	= 0x3c,	/* legacy */
	QueuePfn	= 0x40,	/* legacy */
	QueueReady	= 0x44,	/* modern */
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
};

struct Vring
{
	u16	flags;
	u16	idx;
};

struct Vdesc
{
	u64	addr;
	u32	len;
	u16	flags;
	u16	next;
};

struct Vused
{
	u32	id;
	u32	len;
};

struct Vqueue
{
	Lock	lck;		/* named — KenC anonymous Lock was unreliable here */
	Vdev	*dev;
	int	idx;
	int	size;
	int	free;
	int	nfree;

	Vdesc	*desc;
	Vring	*avail;
	u16	*availent;
	u16	*availevent;
	Vring	*used;
	Vused	*usedent;
	u16	*usedevent;
	u16	lastused;

	void	*rock[];
};

struct Vdev
{
	int	typ;
	int	vers;
	int	irq;
	uintptr	regs;
	u32	feat;
	int	nqueue;
	Vqueue	*queue[8];
	Vdev	*next;
};

struct Rock {
	int done;
	Rendez *sleep;
};

#define csr32r(d, o)	(*(volatile u32*)((d)->regs+(o)))
#define csr32w(d, o, v)	(*(volatile u32*)((d)->regs+(o)) = (u32)(v))

static void
csr64w(Vdev *d, int low, uvlong v)
{
	csr32w(d, low, (u32)v);
	csr32w(d, low+4, (u32)(v>>32));
}

static Vqueue*
mkvqueue(int size)
{
	Vqueue *q;
	uchar *p;
	int i;

	q = malloc(sizeof(*q) + sizeof(void*)*size);
	p = mallocalign(
		PGROUND(sizeof(Vdesc)*size +
			VringSize +
			sizeof(u16)*size +
			sizeof(u16)) +
		PGROUND(VringSize +
			sizeof(Vused)*size +
			sizeof(u16)),
		BY2PG, 0, 0);
	if(p == nil || q == nil){
		print("virtiommio: no memory for Vqueue\n");
		free(p);
		free(q);
		return nil;
	}

	q->desc = (void*)p;
	p += sizeof(Vdesc)*size;
	q->avail = (void*)p;
	p += VringSize;
	q->availent = (void*)p;
	p += sizeof(u16)*size;
	q->availevent = (void*)p;
	p += sizeof(u16);

	p = (uchar*)PGROUND((uintptr)p);
	q->used = (void*)p;
	p += VringSize;
	q->usedent = (void*)p;
	p += sizeof(Vused)*size;
	q->usedevent = (void*)p;

	q->free = -1;
	q->nfree = q->size = size;
	for(i = 0; i < size; i++){
		q->desc[i].next = q->free;
		q->free = i;
	}
	return q;
}

static int
vqsetup(Vdev *vd, Vqueue *q)
{
	uvlong pa;

	csr32w(vd, QueueSel, q->idx);
	if(vd->vers >= 2){
		csr32w(vd, QueueNum, q->size);
		csr64w(vd, QueueDescLow, PADDR(q->desc));
		csr64w(vd, QueueAvailLow, PADDR(q->avail));
		csr64w(vd, QueueUsedLow, PADDR(q->used));
		coherence();
		csr32w(vd, QueueReady, 1);
		if(csr32r(vd, QueueReady) != 1){
			print("virtiommio: queue %d not ready\n", q->idx);
			return -1;
		}
	}else{
		/*
		 * Legacy MMIO: one contiguous queue at QueuePFN (page units).
		 * GuestPageSize once; do not write QueueAlign (QEMU defaults).
		 */
		csr32w(vd, GuestPageSize, BY2PG);
		csr32w(vd, QueueNum, q->size);
		csr32w(vd, QueueAlign, BY2PG);
		pa = PADDR(q->desc);
		if(pa & (BY2PG-1)){
			print("virtiommio: desc not page aligned\n");
			return -1;
		}
		coherence();
		csr32w(vd, QueuePfn, (u32)(pa/BY2PG));
	}
	return 0;
}

static Vdev*
viopnpdevs(void)
{
	Vdev *vd, *h, *t;
	Vqueue *q;
	uintptr base;
	u32 magic, vers, id, feat0, feat1, n;
	int slot, i;

	h = t = nil;
	for(slot = 0; slot < VIRTIO_NDEV; slot++){
		base = VIRTIO0 + (uintptr)slot*VIRTIO_SIZE;
		magic = *(volatile u32*)(base+Magic);
		if(magic != VirtMagic)
			continue;
		vers = *(volatile u32*)(base+Version);
		id = *(volatile u32*)(base+DeviceId);
		if(id != TypBlk)
			continue;
		if(vers != 1 && vers != 2){
			print("virtiommio: slot %d bad version %ud\n", slot, vers);
			continue;
		}
		if((vd = malloc(sizeof(*vd))) == nil){
			print("virtiommio: no memory for Vdev\n");
			break;
		}
		vd->typ = TypBlk;
		vd->vers = vers;
		vd->regs = base;
		vd->irq = Virtio0IRQ + slot;

		csr32w(vd, Status, 0);
		csr32w(vd, Status, Acknowledge|Driver);

		if(vers >= 2){
			csr32w(vd, DevFeaturesSel, 0);
			feat0 = csr32r(vd, DevFeatures);
			csr32w(vd, DevFeaturesSel, 1);
			feat1 = csr32r(vd, DevFeatures);
			USED(feat0);
			csr32w(vd, DrvFeaturesSel, 0);
			csr32w(vd, DrvFeatures, 0);
			csr32w(vd, DrvFeaturesSel, 1);
			csr32w(vd, DrvFeatures, feat1 & 1);	/* VERSION_1 */
			csr32w(vd, Status, Acknowledge|Driver|FeaturesOk);
			if(!(csr32r(vd, Status) & FeaturesOk)){
				print("virtiommio: FEATURES_OK rejected\n");
				csr32w(vd, Status, Failed);
				free(vd);
				continue;
			}
		}else{
			/* legacy: accept no optional features */
			csr32w(vd, DrvFeaturesSel, 0);
			csr32w(vd, DrvFeatures, 0);
		}

		for(i = 0; i < nelem(vd->queue); i++){
			csr32w(vd, QueueSel, i);
			n = csr32r(vd, QueueNumMax);
			if(n == 0 || (n & (n-1)) != 0)
				break;
			if(n > 256)
				n = 256;
			if((q = mkvqueue(n)) == nil)
				break;
			q->dev = vd;
			q->idx = i;
			q->size = n;
			q->nfree = n;
			if(vqsetup(vd, q) < 0){
				free(q);
				break;
			}
			vd->queue[i] = q;
		}
		vd->nqueue = i;
		if(vd->nqueue == 0){
			csr32w(vd, Status, Failed);
			free(vd);
			continue;
		}

		print("virtiommio: blk @ %#p irq %d v%ud queues %d\n",
			vd->regs, vd->irq, vd->vers, vd->nqueue);

		if(h == nil)
			h = vd;
		else
			t->next = vd;
		t = vd;
	}
	return h;
}

static void
vqinterrupt(Vqueue *q)
{
	int id, free, m;
	struct Rock *r;
	Rendez *z;

	m = q->size - 1;
	ilock(&q->lck);
	while((q->lastused ^ q->used->idx) & m){
		id = q->usedent[q->lastused++ & m].id;
		if((r = q->rock[id]) != nil){
			q->rock[id] = nil;
			z = r->sleep;
			r->done = 1;
			if(z != nil)
				wakeup(z);
		}
		do {
			free = id;
			id = q->desc[free].next;
			q->desc[free].next = q->free;
			q->free = free;
			q->nfree++;
		} while(q->desc[free].flags & Next);
	}
	iunlock(&q->lck);
}

static void
viointerrupt(Ureg*, void *arg)
{
	Vdev *vd;

	vd = arg;
	if(csr32r(vd, InterruptStatus) & 1){
		csr32w(vd, InterruptAck, 1);
		vqinterrupt(vd->queue[0]);
	}
}

static int
viodone(void *arg)
{
	return ((struct Rock*)arg)->done;
}

static void
vqio(Vqueue *q, int head)
{
	struct Rock rock;

	rock.done = 0;
	rock.sleep = &up->sleep;
	q->rock[head] = &rock;
	q->availent[q->avail->idx & (q->size-1)] = head;
	coherence();
	q->avail->idx++;
	coherence();
	iunlock(&q->lck);
	if((q->used->flags & 1) == 0)
		csr32w(q->dev, QueueNotify, q->idx);
	while(!rock.done){
		while(waserror())
			;
		tsleep(rock.sleep, viodone, &rock, 1000);
		poperror();
		if(!rock.done)
			vqinterrupt(q);
	}
}

/*
 * DMA buffers must not live on the kstack — keep a small per-CPU scratch.
 * (Uniprocessor virt: one in-flight request is enough for smoke.)
 */
static struct {
	u32	typ;
	u32	prio;
	u64	lba;
} vioreq;
static u8	viostatus;

static int
vioblkreq(Vdev *vd, int typ, void *a, long count, long secsize, uvlong lba)
{
	int need, free, head;
	Vqueue *q;
	Vdesc *d;

	need = 2;
	if(a != nil)
		need = 3;

	viostatus = 0xff;
	vioreq.typ = typ;
	vioreq.prio = 0;
	vioreq.lba = lba;

	q = vd->queue[0];
	ilock(&q->lck);
	while(q->nfree < need){
		iunlock(&q->lck);
		if(!waserror())
			tsleep(&up->sleep, return0, 0, 500);
		poperror();
		ilock(&q->lck);
	}

	head = free = q->free;

	d = &q->desc[free]; free = d->next;
	d->addr = PADDR(&vioreq);
	d->len = sizeof(vioreq);
	d->flags = Next;

	if(a != nil){
		d = &q->desc[free]; free = d->next;
		d->addr = PADDR(a);
		d->len = secsize*count;
		d->flags = typ ? Next : (Write|Next);
	}

	d = &q->desc[free]; free = d->next;
	d->addr = PADDR(&viostatus);
	d->len = sizeof(viostatus);
	d->flags = Write;

	q->free = free;
	q->nfree -= need;
	vqio(q, head);
	return viostatus;
}

static long
viobio(SDunit *u, int, int write, void *a, long count, uvlong lba)
{
	long ss, cc, max, ret;
	Vdev *vd;

	vd = u->dev->ctlr;
	max = 32;
	ss = u->secsize;
	ret = 0;
	while(count > 0){
		if((cc = count) > max)
			cc = max;
		if(vioblkreq(vd, write != 0, (uchar*)a + ret, cc, ss, lba) != 0)
			error(Eio);
		ret += cc*ss;
		count -= cc;
		lba += cc;
	}
	return ret;
}

static int
viorio(SDreq *r)
{
	int i, count, rw;
	uvlong lba;
	SDunit *u;
	Vdev *vd;

	u = r->unit;
	vd = u->dev->ctlr;
	if(r->cmd[0] == 0x35 || r->cmd[0] == 0x91){
		if(vioblkreq(vd, 4, nil, 0, 0, 0) != 0)
			return sdsetsense(r, SDcheck, 3, 0xc, 2);
		return sdsetsense(r, SDok, 0, 0, 0);
	}
	if((i = sdfakescsi(r)) != SDnostatus)
		return r->status = i;
	if((i = sdfakescsirw(r, &lba, &count, &rw)) != SDnostatus)
		return i;
	r->rlen = viobio(u, r->lun, rw == SDwrite, r->data, count, lba);
	return r->status = SDok;
}

static int
vioonline(SDunit *u)
{
	uvlong cap;
	Vdev *vd;

	vd = u->dev->ctlr;
	cap = csr32r(vd, Config);
	cap |= (uvlong)csr32r(vd, Config+4) << 32;
	if(u->sectors != cap){
		u->sectors = cap;
		u->secsize = 512;
		return 2;
	}
	return 1;
}

static int
vioverify(SDunit*)
{
	return 1;
}

SDifc sdvirtiommioifc;

static int
vioenable(SDev *sd)
{
	char name[32];
	Vdev *vd;

	vd = sd->ctlr;
	snprint(name, sizeof(name), "%s (%s)", sd->name, sd->ifc->name);
	intrenable(vd->irq, 0, viointerrupt, vd, name);
	csr32w(vd, Status, csr32r(vd, Status) | DriverOk);
	return 1;
}

static int
viodisable(SDev *sd)
{
	char name[32];
	Vdev *vd;

	vd = sd->ctlr;
	snprint(name, sizeof(name), "%s (%s)", sd->name, sd->ifc->name);
	intrdisable(vd->irq, 0, viointerrupt, vd, name);
	return 1;
}

static SDev*
viopnp(void)
{
	SDev *s, *h, *t;
	Vdev *vd;
	int id;

	h = t = nil;
	id = 'F';
	for(vd = viopnpdevs(); vd != nil; vd = vd->next){
		if(vd->nqueue == 0)
			continue;
		if((s = malloc(sizeof(*s))) == nil)
			break;
		s->ctlr = vd;
		s->idno = id++;
		s->ifc = &sdvirtiommioifc;
		s->nunit = 1;
		if(h)
			t->next = s;
		else
			h = s;
		t = s;
	}
	return h;
}

SDifc sdvirtiommioifc = {
	"virtiommio",
	viopnp,
	nil,
	vioenable,
	viodisable,
	vioverify,
	vioonline,
	viorio,
	nil,
	nil,
	viobio,
	nil,
	nil,
	nil,
	nil,
};
