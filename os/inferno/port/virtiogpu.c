#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/pci.h"
#include "../port/error.h"

/*
 * virtio-gpu, 2-D scanout only (device type 16, PCI id 0x1050).
 *
 * The plan doc's tier-one display: create one host resource the size
 * of the screen, attach a guest framebuffer as its backing store, set
 * it as scanout 0, and on each flush transfer the dirty rectangle and
 * present it.  gscreen draws into the framebuffer; virtiogpuflush()
 * pushes a rectangle.  This is one portable driver a board's screen.c
 * uses in place of ramfb or a fixed boot framebuffer.  virtio-gpu is
 * the display QEMU, KVM and clouds all present, and it modesets and
 * carries a hardware cursor, which a fixed framebuffer does not.
 *
 * The virtio 1.0 transport (register map, feature negotiation, the
 * split virtqueue) follows os/inferno/port/sdvirtio10.c; only the
 * control queue is used, one command at a time, synchronously.
 */

enum {
	/* transport, from sdvirtio10.c */
	Acknowledge	= 1,
	Driver		= 2,
	DriverOk	= 4,
	FeaturesOk	= 8,

	Vconf_devfeatsel	= 0,
	Vconf_devfeat		= 4,
	Vconf_drvfeatsel	= 8,
	Vconf_drvfeat		= 12,
	Vconf_msixcfg		= 16,
	Vconf_numqueues		= 18,
	Vconf_status		= 20,
	Vconf_cfggen		= 21,
	Vconf_queuesel		= 22,
	Vconf_queuesize		= 24,
	Vconf_queuemsixvec	= 26,
	Vconf_queueenable	= 28,
	Vconf_queuenotifyoff	= 30,
	Vconf_queuedesc		= 32,
	Vconf_queueavail	= 40,
	Vconf_queueused		= 48,
	Vconf_sz		= 56,

	/* virtio-gpu control commands */
	CMD_GET_DISPLAY_INFO	= 0x0100,
	CMD_RESOURCE_CREATE_2D	= 0x0101,
	CMD_RESOURCE_UNREF	= 0x0102,
	CMD_SET_SCANOUT		= 0x0103,
	CMD_RESOURCE_FLUSH	= 0x0104,
	CMD_TRANSFER_TO_HOST_2D	= 0x0105,
	CMD_RESOURCE_ATTACH_BACKING = 0x0106,
	RESP_OK_NODATA		= 0x1100,
	RESP_OK_DISPLAY_INFO	= 0x1101,

	FMT_B8G8R8X8		= 2,	/* matches XBGR32 little-endian bytes */

	MAXSCAN			= 16,
	Resid			= 1,	/* our single scanout resource id */
};

typedef struct Vio Vio;
typedef struct Vdesc Vdesc;
typedef struct Vring Vring;
typedef struct Vused Vused;
typedef struct Vqueue Vqueue;

struct Vio {
	uchar	*mem;		/* modern virtio maps memory BARs on every board */
};

static u32int vin32(Vio*, int);
static void vout8(Vio*, int, u8int);
static void vout16(Vio*, int, u16int);
static void vout32(Vio*, int, u32int);
static void vout64(Vio*, int, u64int);
static u8int vin8(Vio*, int);
static u16int vin16(Vio*, int);

struct Vdesc { u64int addr; u32int len; u16int flags; u16int next; };
struct Vring { u16int flags; u16int idx; u16int ring[]; };
struct Vused { u32int id; u32int len; };

struct Vqueue {
	Lock;
	int	size;
	Vdesc	*desc;
	Vring	*avail;
	u16int	*availent;
	Vring	*used;
	Vused	*usedent;
	u16int	lastused;
	Vio	notify;
	int	qidx;
};

/* control command header, 24 bytes */
typedef struct Ctrlhdr Ctrlhdr;
struct Ctrlhdr {
	u32int	type;
	u32int	flags;
	u64int	fence_id;
	u32int	ctx_id;
	u32int	pad;
};

typedef struct Rect Rect;
struct Rect { u32int x, y, w, h; };

static struct {
	int	present;
	Pcidev	*pci;
	Vio	cfg;
	Vio	notify;
	u32int	notifyoffmult;
	Vqueue	ctrlq;
	int	w, h;
	uchar	*fb;		/* the guest framebuffer, DMA backing */
	uchar	*cmd;		/* one command buffer */
	uchar	*resp;		/* one response buffer */
} gpu;

static u8int
vin8(Vio *r, int off)
{
	return r->mem[off];
}
static u16int
vin16(Vio *r, int off)
{
	return *(u16int*)(r->mem + off);
}
static u32int
vin32(Vio *r, int off)
{
	return *(u32int*)(r->mem + off);
}
static void
vout8(Vio *r, int off, u8int v)
{
	r->mem[off] = v;
}
static void
vout16(Vio *r, int off, u16int v)
{
	*(u16int*)(r->mem + off) = v;
}
static void
vout32(Vio *r, int off, u32int v)
{
	*(u32int*)(r->mem + off) = v;
}
static void
vout64(Vio *r, int off, u64int v)
{
	vout32(r, off, (u32int)v);
	vout32(r, off+4, (u32int)(v>>32));
}

/* find a virtio PCI capability of the given cfg type */
static int
virtiocap(Pcidev *p, int typ)
{
	int cap, off;

	for(off = pcicfgr8(p, 0x34); off != 0; off = pcicfgr8(p, off+1)){
		if(pcicfgr8(p, off) != 9)
			continue;
		if(pcicfgr8(p, off+3) == typ)
			return off;
	}
	return -1;
}

static int
virtiomapregs(Pcidev *p, int cap, int size, Vio *v)
{
	int bar;
	uvlong a;
	u32int off, length;

	if(cap < 0)
		return 0;
	bar = pcicfgr8(p, cap+4) % nelem(p->mem);
	off = pcicfgr32(p, cap+8);
	length = pcicfgr32(p, cap+12);
	if(size != 0 && length < size)
		length = size;
	a = p->mem[bar].bar;
	if(a & 1)			/* an I/O BAR: modern virtio-gpu uses memory */
		return 0;
	v->mem = (uchar*)vmap((a & ~0xFULL) + off, length);
	if(v->mem == nil)
		return 0;
	return 1;
}

static void
freeq(Vqueue *q)
{
	q->size = 0;
}

static int
setupq(Vqueue *q, int n)
{
	uchar *p;
	int i;

	/* desc[n] + avail(3+n u16) + pad + used(3+2n u32); one page-aligned block */
	q->size = n;
	q->lastused = 0;
	p = xspanalloc(n*16 + (6+2*n)*2 + (6+8*n) + 0x1000, 0x1000, 0);
	if(p == nil)
		return -1;
	q->desc = (Vdesc*)p;
	p += n*16;
	q->avail = (Vring*)p;
	q->availent = (u16int*)(p + 4);
	p += (4 + 2*n + 2);
	p = (uchar*)(((uintptr)p + 3) & ~3ULL);
	q->used = (Vring*)p;
	q->usedent = (Vused*)(p + 4);
	for(i = 0; i < n; i++)
		q->desc[i].next = i+1;
	return 0;
}

/* one synchronous control command: out cmdlen bytes, in resplen bytes */
static int
docmd(int cmdlen, int resplen)
{
	Vqueue *q;
	int h;
	u16int a;

	q = &gpu.ctrlq;
	/* two-descriptor chain: cmd (device-read), resp (device-write) */
	h = 0;
	q->desc[0].addr = PADDR(gpu.cmd);
	q->desc[0].len = cmdlen;
	q->desc[0].flags = 1;		/* NEXT only; the command is device-read */
	q->desc[0].next = 1;
	q->desc[1].addr = PADDR(gpu.resp);
	q->desc[1].len = resplen;
	q->desc[1].flags = 2;		/* WRITE */
	dmaflush(1, gpu.cmd, cmdlen);
	coherence();
	a = q->avail->idx;
	q->availent[a % q->size] = h;
	coherence();
	q->avail->idx = a + 1;
	coherence();
	/* notify the control queue (index 0) */
	*(u16int*)gpu.notify.mem = 0;
	/* wait for completion */
	{
		int spin;
		for(spin = 0; spin < 2000; spin++){
			coherence();
			if(q->used->idx != q->lastused)
				break;
			delay(1);
		}
		if(spin >= 2000)
			print("virtiogpu: command timeout\n");
	}
	q->lastused = q->used->idx;
	dmaflush(0, gpu.resp, resplen);
	return ((Ctrlhdr*)gpu.resp)->type;
}

static Ctrlhdr*
cmdhdr(int type)
{
	Ctrlhdr *h;

	memset(gpu.cmd, 0, 0x400);
	memset(gpu.resp, 0, 0x400);
	h = (Ctrlhdr*)gpu.cmd;
	h->type = type;
	return h;
}

/*
 * bring the device up: reset, negotiate, one control queue, then
 * GET_DISPLAY_INFO for the geometry.  Returns 1 if a device is present
 * and answered.
 */
int
virtiogpuinit(void)
{
	Pcidev *p;
	Vio cfg;
	int cap, n;
	u32int *info;

	for(p = nil; p = pcimatch(p, 0x1AF4, 0x1050);){
		if(p->rid == 0)			/* transitional; want modern */
			continue;
		if((cap = virtiocap(p, 1)) < 0)
			continue;
		if(virtiomapregs(p, cap, Vconf_sz, &cfg) == 0)
			continue;
		gpu.pci = p;
		gpu.cfg = cfg;
		pcienable(p);
		cap = virtiocap(p, 2);
		if(virtiomapregs(p, cap, 0, &gpu.notify) == 0)
			continue;
		gpu.notifyoffmult = pcicfgr32(p, cap+16);

		/* reset and handshake */
		vout8(&cfg, Vconf_status, 0);
		while(vin8(&cfg, Vconf_status) != 0)
			delay(1);
		vout8(&cfg, Vconf_status, Acknowledge|Driver);
		/* accept only VIRTIO_F_VERSION_1 (bit 32) */
		vout32(&cfg, Vconf_drvfeatsel, 1);
		vout32(&cfg, Vconf_drvfeat, 1);
		vout32(&cfg, Vconf_drvfeatsel, 0);
		vout32(&cfg, Vconf_drvfeat, 0);
		vout8(&cfg, Vconf_status, vin8(&cfg, Vconf_status) | FeaturesOk);

		/* control queue is index 0 */
		vout16(&cfg, Vconf_queuesel, 0);
		n = vin16(&cfg, Vconf_queuesize);
		if(n == 0 || (n & (n-1)) != 0)
			continue;
		if(n > 64)
			n = 64;
		if(setupq(&gpu.ctrlq, n) < 0)
			continue;
		gpu.notify.mem += gpu.notifyoffmult * vin16(&cfg, Vconf_queuenotifyoff);
		coherence();
		vout16(&cfg, Vconf_queuesel, 0);
		vout16(&cfg, Vconf_queuesize, n);
		vout64(&cfg, Vconf_queuedesc, PADDR(gpu.ctrlq.desc));
		vout64(&cfg, Vconf_queueavail, PADDR(gpu.ctrlq.avail));
		vout64(&cfg, Vconf_queueused, PADDR(gpu.ctrlq.used));
		vout16(&cfg, Vconf_queueenable, 1);
		vout8(&cfg, Vconf_status, vin8(&cfg, Vconf_status) | DriverOk);

		gpu.cmd = xspanalloc(0x400, 8, 0);
		gpu.resp = xspanalloc(0x400, 8, 0);
		if(gpu.cmd == nil || gpu.resp == nil)
			continue;

		cmdhdr(CMD_GET_DISPLAY_INFO);
		if(docmd(sizeof(Ctrlhdr), 0x400) != RESP_OK_DISPLAY_INFO){
			print("virtiogpu: no display info\n");
			continue;
		}
		/* response: hdr then 16 pmodes of (rect{4 u32}, enabled, flags) */
		info = (u32int*)(gpu.resp + sizeof(Ctrlhdr));
		gpu.w = info[2];	/* pmodes[0].r.width */
		gpu.h = info[3];	/* pmodes[0].r.height */
		if(gpu.w == 0 || gpu.h == 0){
			gpu.w = 1024;
			gpu.h = 768;
		}
		gpu.present = 1;
		print("virtiogpu: %dx%d\n", gpu.w, gpu.h);
		return 1;
	}
	return 0;
}

/*
 * create the scanout resource, attach fb as its backing, set scanout.
 * fb must be w*h*4 bytes, physically contiguous.
 */
int
virtiogpuscanout(int w, int h, uchar *fb)
{
	u32int *c;

	if(!gpu.present)
		return -1;
	gpu.w = w;
	gpu.h = h;
	gpu.fb = fb;

	/* RESOURCE_CREATE_2D */
	c = (u32int*)cmdhdr(CMD_RESOURCE_CREATE_2D);
	c[6] = Resid;
	c[7] = FMT_B8G8R8X8;
	c[8] = w;
	c[9] = h;
	if(docmd(6*4 + 4*4, 0x400) != RESP_OK_NODATA)
		return -1;

	/* RESOURCE_ATTACH_BACKING with one entry */
	c = (u32int*)cmdhdr(CMD_RESOURCE_ATTACH_BACKING);
	c[6] = Resid;
	c[7] = 1;			/* nr_entries */
	*(u64int*)&c[8] = PCIWADDR(fb);
	c[10] = w*h*4;			/* length */
	c[11] = 0;
	if(docmd(6*4 + 2*4 + 16, 0x400) != RESP_OK_NODATA)
		return -1;

	/* SET_SCANOUT: rect{0,0,w,h}, scanout 0, resource */
	c = (u32int*)cmdhdr(CMD_SET_SCANOUT);
	c[6] = 0; c[7] = 0; c[8] = w; c[9] = h;
	c[10] = 0;			/* scanout id */
	c[11] = Resid;
	if(docmd(6*4 + 6*4, 0x400) != RESP_OK_NODATA)
		return -1;
	return 0;
}

/* push a rectangle: transfer to host then flush to the display */
void
virtiogpuflush(int x, int y, int w, int h)
{
	u32int *c;

	if(!gpu.present || gpu.fb == nil)
		return;
	if(x < 0) x = 0;
	if(y < 0) y = 0;
	if(x + w > gpu.w) w = gpu.w - x;
	if(y + h > gpu.h) h = gpu.h - y;
	if(w <= 0 || h <= 0)
		return;
	dmaflush(1, gpu.fb + (y*gpu.w + x)*4, (h*gpu.w)*4);

	c = (u32int*)cmdhdr(CMD_TRANSFER_TO_HOST_2D);
	c[6] = x; c[7] = y; c[8] = w; c[9] = h;
	*(u64int*)&c[10] = (u64int)(y*gpu.w + x)*4;	/* offset */
	c[12] = Resid;
	c[13] = 0;
	if(docmd(6*4 + 4*4 + 8 + 4*2, 0x400) != RESP_OK_NODATA)
		return;

	c = (u32int*)cmdhdr(CMD_RESOURCE_FLUSH);
	c[6] = x; c[7] = y; c[8] = w; c[9] = h;
	c[10] = Resid;
	c[11] = 0;
	docmd(6*4 + 6*4, 0x400);
}

int
virtiogpupresent(void)
{
	return gpu.present;
}

int
virtiogpuwidth(void)
{
	return gpu.w;
}

int
virtiogpuheight(void)
{
	return gpu.h;
}
