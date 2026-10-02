/*
 * Virtio devices provided by the hypervisor itself (doc/genesize-
 * plan.ms, phase 9): a function on the guest's PCI bus (vmpci.c) with
 * the virtio 1.0 PCI transport -- no legacy interface -- and a backend
 * here in the kernel, so a guest's disk is served without a trip to
 * Limbo for each request.
 *
 * The transport is one 64-bit memory BAR (BAR4) that is never mapped:
 * every access traps, through the nested page tables, to vvmmio.  It
 * holds
 *
 *	0x0000	common configuration (features, status, queues)
 *	0x1000	ISR status
 *	0x2000	device configuration
 *	0x3000	queue notification, queue i at 0x3000 + 4*i
 *	0x4000	MSI-X table, 0x5000 its pending bits
 *
 * named by the vendor capabilities in configuration space.  Queues are
 * split rings (no packed rings, indirect descriptors or event index)
 * in guest memory; every address and length the guest gives is checked
 * against that memory before it is used.  Interrupts are MSI-X,
 * delivered into the guest's local APIC (vmplatmsi); a driver that
 * does not enable MSI-X gets none -- INTx is not modelled.
 *
 * blk: a block device over any file in the namespace of whoever wrote
 * the ctl message -- a disk image, an sd partition, a file on another
 * machine.  A notification is served at once, on the vCPU's own kproc,
 * by reads and writes on that file: simple, and nothing runs on its
 * own to outlive the machine.  Requests: in, out, flush, get id.
 *
 * net: an ethernet interface on a connection of an ether(3) device
 * ("/net/ether1", say), opened as a bridge port: every type,
 * promiscuous, and in bridge mode, so the guest's frames keep its own
 * source address and devether delivers to this connection the frames
 * for that address (which it learns from what the guest sends), and
 * broadcasts and multicasts -- but not the guest's own back to it.
 * The guest's MAC is made from the machine and device numbers.  A
 * frame the guest queues is written at once, on the vCPU's kproc; a
 * kproc of the device's own reads the connection and fills the
 * guest's receive buffers, and is stopped (vvstop) before the guest's
 * memory goes.  A frame with no buffer waiting is dropped, as a NIC
 * with a full ring drops.  No offloads: no checksum, TSO or mergeable
 * buffers are offered, so every header is the bare 12 bytes.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"../port/vm.h"
#include	"vmpci.h"
#include	"vmvirtio.h"

typedef struct Vv Vv;
typedef struct Vq Vq;
typedef struct Seg Seg;

enum {
	Qmax	= 256,		/* largest queue offered */
	Nq	= 2,
	Nvec	= 4,		/* MSI-X entries */
	Novec	= 0xFFFF,	/* VIRTIO_MSI_NO_VECTOR */

	Tnet	= 1,
	Tblk	= 2,

	/* device status */
	Sack	= 1,
	Sdriver	= 2,
	Sdriverok	= 4,
	Sfeatok	= 8,
	Sneedreset	= 0x40,
	Sfailed	= 0x80,

	/* descriptor flags */
	Dnext	= 1,
	Dwrite	= 2,
	Dindirect	= 4,

	Fversion1	= 32,	/* VIRTIO_F_VERSION_1 */
	Fblkro	= 5,		/* VIRTIO_BLK_F_RO */
	Fblkflush	= 9,	/* VIRTIO_BLK_F_FLUSH */
	Fnetmac	= 5,		/* VIRTIO_NET_F_MAC */

	Nethdr	= 12,		/* virtio_net_hdr_v1: the version 1 header */
	Maxframe	= 1514,
	Minframe	= 60,

	/* blk request types and status */
	Bin	= 0,
	Bout	= 1,
	Bflush	= 4,
	Bgetid	= 8,
	Bok	= 0,
	Bioerr	= 1,
	Bunsupp	= 2,
};

struct Seg
{
	uvlong	addr;
	u32int	len;
	int	write;
};

struct Vq
{
	u16int	size;
	u16int	enable;
	u16int	vec;
	uvlong	desc, avail, used;
	u16int	lastavail;	/* the next avail entry to take */
	u16int	usedidx;
	uvlong	nreq;
};

struct Vv
{
	Vm	*vm;
	int	type;
	int	dev;		/* device number on the guest's bus 0 */
	char	name[KNAMELEN];

	/* configuration space */
	uvlong	bar;
	u32int	barlo, barhi;	/* what the guest last wrote, for sizing */
	int	sizing;
	u16int	cmd;
	u8int	intline;
	u16int	msixctl;	/* enable 15, function mask 14 */
	struct {
		u32int	addrlo, addrhi, data, ctl;
		int	pending;
	} msix[Nvec];

	/* common configuration */
	u32int	dfsel, gfsel;	/* feature selects: device's, driver's */
	uvlong	dfeat;		/* offered */
	uvlong	gfeat;		/* accepted by the driver */
	u8int	status;
	u16int	cfgvec;
	u16int	qsel;
	int	nq;
	Vq	q[Nq];
	u8int	isr;

	QLock	lk;		/* queues: the vCPU's kproc and the receiver */

	/* blk */
	Chan	*c;
	char	*path;
	uvlong	sectors;
	int	ro;
	Seg	seg[Qmax];

	/* net */
	Chan	*ctl;		/* the connection's: held so it stays ours */
	uchar	mac[6];
	Proc	*rxp;		/* the receiving kproc */
	int	stopping;
	int	rxdone;
	Rendez	rxr;
	uchar	txbuf[Nethdr + Maxframe];
	uvlong	nrx, ntx, nrxdrop, ntxbad;

	uvlong	nmsi, nnovec, nbad;
	char	lasterr[ERRMAX];
};

static uint
g16(uchar *p)
{
	return p[0] | p[1]<<8;
}

static u32int
g32(uchar *p)
{
	return p[0] | p[1]<<8 | p[2]<<16 | (u32int)p[3]<<24;
}

static uvlong
g64(uchar *p)
{
	return g32(p) | (uvlong)g32(p+4)<<32;
}

static void
p16(uchar *p, uint v)
{
	p[0] = v;
	p[1] = v>>8;
}

static void
p32(uchar *p, u32int v)
{
	p[0] = v;
	p[1] = v>>8;
	p[2] = v>>16;
	p[3] = v>>24;
}

static void
p64(uchar *p, uvlong v)
{
	p32(p, v);
	p32(p+4, v>>32);
}

/* guest-physical [a, a+n) as a host pointer, or nil if not all guest memory */
static uchar*
gmem(Vv *v, uvlong a, uvlong n)
{
	Vm *vm;

	vm = v->vm;
	if(vm->mem == nil || a > vm->memsize || n > vm->memsize - a)
		return nil;
	return vm->mem + a;
}

static void
vecintr(Vv *v, int vec)
{
	if(!(v->msixctl & 1<<15))
		return;		/* INTx is not modelled */
	if(vec == Novec || vec >= Nvec){
		v->nnovec++;
		return;
	}
	if((v->msixctl & 1<<14) || (v->msix[vec].ctl & 1)){
		v->msix[vec].pending = 1;
		return;
	}
	v->msix[vec].pending = 0;
	v->nmsi++;
	vmplatmsi(v->vm, v->msix[vec].addrlo, v->msix[vec].data);
}

/* entries unmasked with an interrupt pending get it now */
static void
msixpending(Vv *v)
{
	int i;

	for(i = 0; i < Nvec; i++)
		if(v->msix[i].pending)
			vecintr(v, i);
}

static void
needreset(Vv *v, char *why)
{
	v->nbad++;
	kstrcpy(v->lasterr, why, sizeof v->lasterr);
	v->status |= Sneedreset;
	if(v->status & Sdriverok){
		v->isr |= 2;
		vecintr(v, v->cfgvec);
	}
}

static void
reset(Vv *v)
{
	int i;

	v->dfsel = v->gfsel = 0;
	v->gfeat = 0;
	v->status = 0;
	v->cfgvec = Novec;
	v->qsel = 0;
	v->isr = 0;
	for(i = 0; i < v->nq; i++){
		memset(&v->q[i], 0, sizeof v->q[i]);
		v->q[i].size = Qmax;
		v->q[i].vec = Novec;
	}
}

/*
 * The descriptor chain from head into v->seg; the number of
 * descriptors, or -1 for a chain that is malformed (out of the table,
 * indirect, or longer than the queue, which a loop would be).
 */
static int
chain(Vv *v, Vq *q, uchar *desc, uint head)
{
	uchar *d;
	uint i, f;
	int n;

	i = head;
	for(n = 0;; n++){
		if(i >= q->size || n >= q->size)
			return -1;
		d = desc + 16*i;
		f = g16(d+12);
		if(f & Dindirect)
			return -1;
		v->seg[n].addr = g64(d);
		v->seg[n].len = g32(d+8);
		v->seg[n].write = (f & Dwrite) != 0;
		if(gmem(v, v->seg[n].addr, v->seg[n].len) == nil)
			return -1;
		if(!(f & Dnext))
			return n+1;
		i = g16(d+14);
	}
}

/* move n bytes between the file at off and guest memory at a */
static void
fileio(Vv *v, int write, uvlong off, uvlong a, u32int n)
{
	uchar *p;
	s32 r, m;

	p = gmem(v, a, n);
	while(n > 0){
		m = n > 128*1024 ? 128*1024 : n;
		if(write)
			r = devtab[v->c->type]->write(v->c, p, m, off);
		else
			r = devtab[v->c->type]->read(v->c, p, m, off);
		if(r < 0 || r > m)
			error(Eio);
		if(r == 0){
			if(write)
				error(Eio);
			memset(p, 0, n);	/* past the end of the file: zeros */
			return;
		}
		p += r;
		off += r;
		n -= r;
	}
}

/* serve one request; the bytes written into the guest's buffers */
static u32int
blkreq(Vv *v, Vq *q, uchar *desc, uint head)
{
	Seg *s, *st;
	uchar *h, *sp;
	int n, i, type, status;
	uvlong off, len;
	u32int wrote;
	char id[20];

	n = chain(v, q, desc, head);
	if(n < 2){
		v->nbad++;
		kstrcpy(v->lasterr, "malformed request chain", sizeof v->lasterr);
		return 0;
	}
	s = v->seg;
	st = &s[n-1];
	if(!st->write || st->len < 1 || s[0].write || s[0].len < 16){
		v->nbad++;
		kstrcpy(v->lasterr, "request without header or status", sizeof v->lasterr);
		return 0;
	}
	h = gmem(v, s[0].addr, 16);
	sp = gmem(v, st->addr, 1);
	type = g32(h);
	off = g64(h+8) * 512;
	wrote = 0;
	len = 0;
	for(i = 1; i < n-1; i++)
		len += s[i].len;
	q->nreq++;

	status = Bok;
	switch(type){
	case Bin:
	case Bout:
		for(i = 1; i < n-1; i++)
			if(s[i].write != (type == Bin))
				status = Bioerr;
		if(type == Bout && v->ro)
			status = Bioerr;
		if(off/512 > v->sectors || len > v->sectors*512 - off)
			status = Bioerr;
		if(status != Bok)
			break;
		if(waserror()){
			kstrcpy(v->lasterr, up->env->errstr, sizeof v->lasterr);
			status = Bioerr;
			break;
		}
		for(i = 1; i < n-1; i++){
			fileio(v, type == Bout, off, s[i].addr, s[i].len);
			off += s[i].len;
			if(type == Bin)
				wrote += s[i].len;
		}
		poperror();
		break;
	case Bflush:
		break;		/* writes are not buffered here */
	case Bgetid:
		if(n < 3 || !s[1].write){
			status = Bioerr;
			break;
		}
		memset(id, 0, sizeof id);
		strncpy(id, v->name, sizeof id);
		i = s[1].len < sizeof id ? s[1].len : sizeof id;
		memmove(gmem(v, s[1].addr, i), id, i);
		wrote = i;
		break;
	default:
		status = Bunsupp;
	}
	*sp = status;
	return wrote + 1;
}

/* transmit one frame: the readable buffers, less the header */
static void
nettx(Vv *v, Vq *q, uchar *desc, uint head)
{
	Seg *s;
	int n, i;
	u32int len, m;

	n = chain(v, q, desc, head);
	if(n < 1){
		v->ntxbad++;
		return;
	}
	s = v->seg;
	len = 0;
	for(i = 0; i < n; i++){
		if(s[i].write || s[i].len > sizeof v->txbuf - len){
			v->ntxbad++;
			return;
		}
		memmove(v->txbuf + len, gmem(v, s[i].addr, s[i].len), s[i].len);
		len += s[i].len;
	}
	q->nreq++;
	if(len < Nethdr + 14){
		v->ntxbad++;
		return;
	}
	m = len - Nethdr;
	if(m < Minframe){
		memset(v->txbuf + len, 0, Minframe - m);
		m = Minframe;
	}
	if(waserror()){
		kstrcpy(v->lasterr, up->env->errstr, sizeof v->lasterr);
		v->ntxbad++;
		return;
	}
	devtab[v->c->type]->write(v->c, v->txbuf + Nethdr, m, 0);
	poperror();
	v->ntx++;
}

/*
 * Give a received frame to the guest, in the next buffer on the
 * receive queue: the 12-byte header (no offloads, one buffer), then the
 * frame.  Returns 0 if there is no buffer, or no queue yet.
 */
static int
netrx(Vv *v, uchar *f, int len)
{
	Vq *q;
	Seg *s;
	uchar *desc, *avail, *used, *u, *p;
	uchar hdr[Nethdr];
	uint ai, head;
	int n, i, off, m, tot;

	q = &v->q[0];
	if(!q->enable || !(v->status & Sdriverok) || (v->status & Sneedreset))
		return 0;
	desc = gmem(v, q->desc, 16*q->size);
	avail = gmem(v, q->avail, 6 + 2*q->size);
	used = gmem(v, q->used, 6 + 8*q->size);
	if(desc == nil || avail == nil || used == nil)
		return 0;
	coherence();
	ai = g16(avail+2);
	if(ai == q->lastavail)
		return 0;
	head = g16(avail + 4 + 2*(q->lastavail % q->size));
	coherence();
	q->lastavail++;
	memset(hdr, 0, sizeof hdr);
	p16(hdr+10, 1);		/* num_buffers */
	n = chain(v, q, desc, head);
	tot = 0;
	if(n > 0){
		s = v->seg;
		off = 0;	/* into header ++ frame */
		for(i = 0; i < n && off < Nethdr + len; i++){
			if(!s[i].write)
				break;
			p = gmem(v, s[i].addr, s[i].len);
			for(m = 0; m < s[i].len && off < Nethdr + len; m++, off++)
				p[m] = off < Nethdr ? hdr[off] : f[off - Nethdr];
		}
		if(off == Nethdr + len)
			tot = off;
		else
			v->nrxdrop++;	/* buffers too small: give it back empty */
	}else
		v->nbad++;
	u = used + 4 + 8*(q->usedidx % q->size);
	p32(u, head);
	p32(u+4, tot);
	coherence();
	q->usedidx++;
	p16(used+2, q->usedidx);
	coherence();
	q->nreq++;
	if(!(g16(avail) & 1)){
		v->isr |= 1;
		vecintr(v, q->vec);
	}
	return 1;
}

static int
rxstopped(void *a)
{
	return ((Vv*)a)->rxdone;
}

/* the receiving kproc: frames from the connection into the guest */
static void
netreader(void *a)
{
	Vv *v;
	uchar *f;
	s32 n;

	v = a;
	v->rxp = up;
	f = malloc(Maxframe + 64);
	while(!v->stopping && f != nil){
		if(waserror()){
			if(v->stopping)
				break;
			kstrcpy(v->lasterr, up->env->errstr, sizeof v->lasterr);
			tsleep(&up->sleep, return0, nil, 100);
			continue;
		}
		n = devtab[v->c->type]->read(v->c, f, Maxframe + 64, 0);
		poperror();
		if(n < 14 || n > Maxframe + 64)
			continue;
		/* the guest's own frames, should one come back, are not for it */
		if(memcmp(f+6, v->mac, 6) == 0)
			continue;
		qlock(&v->lk);
		if(netrx(v, f, n))
			v->nrx++;
		else
			v->nrxdrop++;
		qunlock(&v->lk);
	}
	free(f);
	v->rxdone = 1;
	wakeup(&v->rxr);
	pexit("", 0);
}

/* take every request the driver has made available on queue qi */
static void
serve(Vv *v, int qi)
{
	Vq *q;
	uchar *desc, *avail, *used, *u;
	uint ai, head, k;
	u32int n;
	int any;

	if(qi >= v->nq)
		return;
	/*
	 * A net receive queue's notification only says buffers were
	 * added: they wait there for frames (netrx).  Serving them here
	 * returned each at once, empty, and the driver gave it straight
	 * back -- a loop of zero-length packets that left none for the
	 * frames.
	 */
	if(v->type == Tnet && qi == 0)
		return;
	q = &v->q[qi];
	if(!q->enable || !(v->status & Sdriverok) || (v->status & Sneedreset))
		return;
	desc = gmem(v, q->desc, 16*q->size);
	avail = gmem(v, q->avail, 6 + 2*q->size);
	used = gmem(v, q->used, 6 + 8*q->size);
	if(desc == nil || avail == nil || used == nil){
		needreset(v, "queue outside guest memory");
		return;
	}
	any = 0;
	for(;;){
		coherence();
		ai = g16(avail+2);
		if(ai == q->lastavail)
			break;
		if((u16int)(ai - q->lastavail) > q->size){
			needreset(v, "avail index ran ahead of the queue");
			return;
		}
		head = g16(avail + 4 + 2*(q->lastavail % q->size));
		coherence();
		q->lastavail++;
		n = 0;
		if(v->type == Tblk)
			n = blkreq(v, q, desc, head);
		else if(qi == 1)
			nettx(v, q, desc, head);
		k = q->usedidx % q->size;
		u = used + 4 + 8*k;
		p32(u, head);
		p32(u+4, n);
		coherence();
		q->usedidx++;
		p16(used+2, q->usedidx);
		any = 1;
	}
	coherence();
	if(any && !(g16(avail) & 1)){		/* VIRTQ_AVAIL_F_NO_INTERRUPT */
		v->isr |= 1;
		vecintr(v, q->vec);
	}
}

static int
pow2(uint n)
{
	return n != 0 && (n & (n-1)) == 0;
}

static void
qenable(Vv *v, Vq *q)
{
	if(!pow2(q->size) || q->size > Qmax
	|| gmem(v, q->desc, 16*q->size) == nil
	|| gmem(v, q->avail, 6 + 2*q->size) == nil
	|| gmem(v, q->used, 6 + 8*q->size) == nil){
		needreset(v, "bad queue enabled");
		return;
	}
	q->lastavail = 0;
	q->usedidx = 0;
	q->enable = 1;
}

static void
setstatus(Vv *v, u8int s)
{
	if(s == 0){
		reset(v);
		return;
	}
	if((s & Sfeatok) && !(v->status & Sfeatok)){
		/* the driver may accept only what was offered, and must speak 1.0 */
		if((v->gfeat & ~v->dfeat) != 0 || !(v->gfeat & 1ULL<<Fversion1))
			s &= ~Sfeatok;
	}
	v->status = s | (v->status & Sneedreset);
}

/* the common configuration structure as the guest would read it */
static void
commonimage(Vv *v, uchar *b)
{
	Vq *q;

	memset(b, 0, 0x38);
	p32(b+0x00, v->dfsel);
	p32(b+0x04, v->dfsel < 2 ? v->dfeat >> 32*v->dfsel : 0);
	p32(b+0x08, v->gfsel);
	p32(b+0x0C, v->gfsel < 2 ? v->gfeat >> 32*v->gfsel : 0);
	p16(b+0x10, v->cfgvec);
	p16(b+0x12, v->nq);
	b[0x14] = v->status;
	b[0x15] = 0;		/* config generation: the config never changes */
	p16(b+0x16, v->qsel);
	if(v->qsel < v->nq){
		q = &v->q[v->qsel];
		p16(b+0x18, q->size);
		p16(b+0x1A, q->vec);
		p16(b+0x1C, q->enable);
		p16(b+0x1E, v->qsel);	/* notify offset: queue i at 4*i */
		p64(b+0x20, q->desc);
		p64(b+0x28, q->avail);
		p64(b+0x30, q->used);
	}else
		p16(b+0x18, 0);		/* no such queue */
}

static void
commonwrite(Vv *v, int off, int size, uvlong val)
{
	Vq *q;
	uvlong m;

	q = v->qsel < v->nq ? &v->q[v->qsel] : nil;
	switch(off){
	case 0x00: v->dfsel = val; return;
	case 0x08: v->gfsel = val; return;
	case 0x0C:
		if(v->gfsel < 2 && !(v->status & Sfeatok)){
			m = 0xFFFFFFFFULL << 32*v->gfsel;
			v->gfeat = (v->gfeat & ~m) | ((uvlong)(u32int)val << 32*v->gfsel);
		}
		return;
	case 0x10: v->cfgvec = val; return;
	case 0x14: setstatus(v, val); return;
	case 0x16: v->qsel = val; return;
	}
	if(q == nil || q->enable && off != 0x1C)
		return;		/* a live queue's layout does not change */
	switch(off){
	case 0x18: q->size = val; return;
	case 0x1A: q->vec = val; return;
	case 0x1C:
		if((val & 1) && !q->enable)
			qenable(v, q);
		return;
	case 0x20: q->desc = size == 8 ? val : (q->desc & ~0xFFFFFFFFULL) | (u32int)val; return;
	case 0x24: q->desc = (q->desc & 0xFFFFFFFFULL) | val << 32; return;
	case 0x28: q->avail = size == 8 ? val : (q->avail & ~0xFFFFFFFFULL) | (u32int)val; return;
	case 0x2C: q->avail = (q->avail & 0xFFFFFFFFULL) | val << 32; return;
	case 0x30: q->used = size == 8 ? val : (q->used & ~0xFFFFFFFFULL) | (u32int)val; return;
	case 0x34: q->used = (q->used & 0xFFFFFFFFULL) | val << 32; return;
	}
}

static void
devimage(Vv *v, uchar *b)
{
	memset(b, 0, 0x100);
	if(v->type == Tblk)
		p64(b, v->sectors);	/* capacity, 512-byte sectors */
	else
		memmove(b, v->mac, 6);
}

static uvlong
extract(uchar *b, int off, int size)
{
	switch(size){
	case 1: return b[off];
	case 2: return g16(b+off);
	case 4: return g32(b+off);
	case 8: return g64(b+off);
	}
	return 0;
}

static int mmio(Vv*, uvlong, int, int, uvlong*);

int
vvmmio(void *a, uvlong gpa, int size, int write, uvlong *val)
{
	Vv *v = a;
	int r;

	if(v->bar == 0 || gpa < v->bar || gpa >= v->bar + Vvbarsize)
		return 0;
	qlock(&v->lk);
	if(waserror()){
		qunlock(&v->lk);
		nexterror();
	}
	r = mmio(v, gpa - v->bar, size, write, val);
	poperror();
	qunlock(&v->lk);
	return r;
}

static int
mmio(Vv *v, uvlong off, int size, int write, uvlong *val)
{
	uchar img[0x100];
	int i, f;

	if(size != 1 && size != 2 && size != 4 && size != 8)
		return 0;
	if(!write)
		*val = 0;
	if(off < 0x38){
		if(off + size > 0x38)
			return 1;
		if(write)
			commonwrite(v, off, size, *val);
		else{
			commonimage(v, img);
			*val = extract(img, off, size);
		}
		return 1;
	}
	if(off >= 0x1000 && off < 0x1004){
		if(!write && off == 0x1000){
			*val = v->isr;
			v->isr = 0;	/* reading clears it */
		}
		return 1;
	}
	if(off >= 0x2000 && off < 0x2100){
		if(!write && off - 0x2000 + size <= 0x100){
			devimage(v, img);
			*val = extract(img, off - 0x2000, size);
		}
		return 1;
	}
	if(off >= 0x3000 && off < 0x3000 + 4*Nq){
		if(write)
			serve(v, (off - 0x3000) / 4);
		return 1;
	}
	if(off >= 0x4000 && off < 0x4000 + 16*Nvec){
		i = (off - 0x4000) / 16;
		f = (off - 0x4000) % 16;
		if(!write){
			switch(f){
			case 0: *val = v->msix[i].addrlo | (size == 8 ? (uvlong)v->msix[i].addrhi << 32 : 0); break;
			case 4: *val = v->msix[i].addrhi; break;
			case 8: *val = v->msix[i].data | (size == 8 ? (uvlong)v->msix[i].ctl << 32 : 0); break;
			case 12: *val = v->msix[i].ctl; break;
			}
			return 1;
		}
		switch(f){
		case 0:
			v->msix[i].addrlo = *val;
			if(size == 8)
				v->msix[i].addrhi = *val >> 32;
			break;
		case 4: v->msix[i].addrhi = *val; break;
		case 8:
			v->msix[i].data = *val;
			if(size == 8)
				v->msix[i].ctl = (*val >> 32) & 1;
			break;
		case 12: v->msix[i].ctl = *val & 1; break;
		}
		msixpending(v);
		return 1;
	}
	if(off >= 0x5000 && off < 0x5008){
		if(!write)
			for(i = 0; i < Nvec; i++)
				if(v->msix[i].pending)
					*val |= 1ULL << i;
		return 1;
	}
	return 1;	/* the rest of the BAR reads as zero and ignores writes */
}

/*
 * Configuration space: built here, nothing behind it.  Capabilities at
 * 0x40 (common), 0x50 (ISR), 0x60 (device), 0x70 (notify), 0x84 (MSI-X).
 */
static void
vcap(uchar *c, int next, int len, int type, u32int off, u32int size)
{
	c[0] = 0x09;		/* vendor specific */
	c[1] = next;
	c[2] = len;
	c[3] = type;
	c[4] = 4;		/* BAR4 */
	p32(c+8, off);
	p32(c+12, size);
}

u32int
vvcfgread(void *a, int reg)
{
	Vv *v = a;
	uchar c[256];

	memset(c, 0, sizeof c);
	p16(c+0x00, 0x1AF4);
	p16(c+0x02, 0x1040 + v->type);
	p16(c+0x04, v->cmd);
	p16(c+0x06, 0x10);		/* capabilities list */
	c[0x08] = 1;			/* revision: a modern-only device */
	if(v->type == Tblk){
		c[0x0A] = 0x80;		/* mass storage: other */
		c[0x0B] = 0x01;
	}else{
		c[0x0A] = 0x00;		/* network: ethernet */
		c[0x0B] = 0x02;
	}
	if(v->sizing){
		p32(c+0x20, v->barlo == 0xFFFFFFFF ? ~(u32int)(Vvbarsize-1) | 0x4 : (u32int)v->bar | 0x4);
		p32(c+0x24, v->barhi == 0xFFFFFFFF ? 0xFFFFFFFF : v->bar >> 32);
	}else{
		p32(c+0x20, (u32int)v->bar | 0x4);	/* 64-bit, not prefetchable */
		p32(c+0x24, v->bar >> 32);
	}
	p16(c+0x2C, 0x1AF4);
	p16(c+0x2E, 0x40 + v->type);
	c[0x34] = 0x40;
	c[0x3C] = v->intline;
	c[0x3D] = 1;			/* INTA#, though nothing raises it */
	vcap(c+0x40, 0x50, 16, 1, 0x0000, 0x38);
	vcap(c+0x50, 0x60, 16, 3, 0x1000, 4);
	vcap(c+0x60, 0x70, 16, 4, 0x2000, 0x100);
	vcap(c+0x70, 0x84, 20, 2, 0x3000, 4*Nq);
	p32(c+0x80, 4);			/* notify_off_multiplier */
	c[0x84] = 0x11;			/* MSI-X */
	c[0x85] = 0;
	p16(c+0x86, v->msixctl | (Nvec-1));
	p32(c+0x88, 0x4000 | 4);
	p32(c+0x8C, 0x5000 | 4);
	return g32(c + (reg & 0xFC));
}

void
vvcfgwrite(void *a, int reg, u32int val, u32int mask)
{
	Vv *v = a;
	u32int w;
	uvlong nb;

	switch(reg){
	case 0x04:
		if(mask & 0xFFFF)
			v->cmd = val & 0x0006;	/* memory space, bus master */
		return;
	case 0x20:
	case 0x24:
		w = (reg == 0x20 ? v->barlo : v->barhi) & ~mask | val & mask;
		if(reg == 0x20)
			v->barlo = w;
		else
			v->barhi = w;
		if(w == 0xFFFFFFFF){
			v->sizing = 1;
			return;
		}
		v->sizing = 0;
		if(reg == 0x20)
			nb = (v->bar & ~0xFFFFFFFFULL) | (w & ~(u32int)(Vvbarsize-1));
		else
			nb = (v->bar & 0xFFFFFFFFULL) | (uvlong)w << 32;
		v->bar = nb;		/* never mapped: nothing to move */
		return;
	case 0x3C:
		if(mask & 0xFF)
			v->intline = val;
		return;
	case 0x84:
		if(mask & 0xFFFF0000){
			v->msixctl = (val >> 16) & 0xC000;
			msixpending(v);
		}
		return;
	}
}

static uvlong
filelength(Chan *c)
{
	uchar buf[STATFIXLEN + 4*KNAMELEN];
	s32 n;
	Dir d;

	n = devtab[c->type]->stat(c, buf, sizeof buf);
	if(n < 0 || convM2D(buf, n, &d, nil) == 0)
		error("can't stat the backing file");
	return d.length;
}

static void
blkopen(Vv *v, char *path)
{
	v->type = Tblk;
	v->nq = 1;
	if(!waserror()){
		v->c = namec(path, Aopen, ORDWR, 0);
		poperror();
	}else{
		v->c = namec(path, Aopen, OREAD, 0);
		v->ro = 1;
	}
	v->sectors = filelength(v->c) / 512;
	v->dfeat = 1ULL<<Fversion1 | 1ULL<<Fblkflush;
	if(v->ro)
		v->dfeat |= 1ULL<<Fblkro;
}

/* a bridge port on the ether(3) device at dir: "connect -1", promiscuous, bridge */
static void
netopen(Vv *v, char *dir)
{
	char buf[128], *msg[] = { "connect -1", "promiscuous", "bridge" };
	s32 n;
	int i;

	v->type = Tnet;
	v->nq = 2;
	snprint(buf, sizeof buf, "%s/clone", dir);
	v->ctl = namec(buf, Aopen, ORDWR, 0);
	n = devtab[v->ctl->type]->read(v->ctl, buf, sizeof buf - 1, 0);
	if(n <= 0)
		error("virtio net: reading the connection number");
	buf[n] = 0;
	snprint(buf, sizeof buf, "%s/%d/data", dir, atoi(buf));
	for(i = 0; i < nelem(msg); i++)
		devtab[v->ctl->type]->write(v->ctl, msg[i], strlen(msg[i]), 0);
	v->c = namec(buf, Aopen, ORDWR, 0);
	/* locally administered, unicast: 52:49:<vm>:<dev>:00:01 ("RI") */
	v->mac[0] = 0x52;
	v->mac[1] = 0x49;
	v->mac[2] = v->vm->id;
	v->mac[3] = v->dev;
	v->mac[4] = 0;
	v->mac[5] = 1;
	v->dfeat = 1ULL<<Fversion1 | 1ULL<<Fnetmac;
}

void*
vvnew(Vm *vm, char *kind, char *path, int dev, uvlong bar)
{
	Vv *v;

	if(strcmp(kind, "blk") != 0 && strcmp(kind, "net") != 0)
		error("virtio: kinds are blk and net");
	v = mallocz(sizeof *v, 1);
	if(v == nil)
		error(Enomem);
	if(waserror()){
		if(v->c != nil)
			cclose(v->c);
		if(v->ctl != nil)
			cclose(v->ctl);
		free(v->path);
		free(v);
		nexterror();
	}
	v->vm = vm;
	v->dev = dev;
	v->bar = bar;
	v->path = strdup(path);
	if(strcmp(kind, "blk") == 0)
		blkopen(v, path);
	else
		netopen(v, path);
	snprint(v->name, sizeof v->name, "vm%d.v%s%d", vm->id, kind, dev);
	reset(v);
	poperror();
	if(v->type == Tnet){
		kproc(v->name, netreader, v, 0);
		/* the kproc records itself; wait until it has */
		while(v->rxp == nil && !v->rxdone)
			tsleep(&up->sleep, return0, nil, 10);
	}
	return v;
}

/*
 * Stop the receiver, which writes into the guest's memory, before that
 * memory goes.  blk does its work on the vCPU's kproc: nothing to stop.
 */
void
vvstop(void *a)
{
	Vv *v = a;

	if(v->type != Tnet || v->rxp == nil || v->rxdone)
		return;
	v->stopping = 1;
	while(!v->rxdone){
		postnote(v->rxp, 1, "virtio stop", NUser);
		tsleep(&v->rxr, rxstopped, v, 100);
	}
}

void
vvfree(void *a)
{
	Vv *v = a;

	if(v == nil)
		return;
	vvstop(v);
	if(v->c != nil)
		cclose(v->c);
	if(v->ctl != nil)
		cclose(v->ctl);
	free(v->path);
	free(v);
}

int
vvdev(void *a)
{
	return ((Vv*)a)->dev;
}

uvlong
vvbar(void *a)
{
	return ((Vv*)a)->bar;
}

char*
vvstatus(void *a, char *p, char *e)
{
	Vv *v = a;
	int i;

	p = seprint(p, e, "pci 00:%.2d.0 virtio %s %s", v->dev, v->type == Tblk ? "blk" : "net", v->path);
	if(v->type == Tblk)
		p = seprint(p, e, "%s %llud sectors", v->ro ? " ro" : "", v->sectors);
	p = seprint(p, e, " bar4 %#llux status %#ux features %#llux msix %s",
		v->bar, v->status, v->gfeat, (v->msixctl & 1<<15) ? "on" : "off");
	for(i = 0; i < v->nq; i++)
		p = seprint(p, e, " q%d %s size %d vec %d req %llud", i,
			v->q[i].enable ? "on" : "off", v->q[i].size, v->q[i].vec, v->q[i].nreq);
	if(v->type == Tnet)
		p = seprint(p, e, " mac %E rx %llud rxdrop %llud tx %llud txbad %llud",
			v->mac, v->nrx, v->nrxdrop, v->ntx, v->ntxbad);
	p = seprint(p, e, " msi %llud novec %llud bad %llud", v->nmsi, v->nnovec, v->nbad);
	if(v->lasterr[0])
		p = seprint(p, e, " last %q", v->lasterr);
	return seprint(p, e, "\n");
}
