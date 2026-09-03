/*
 * A block device driven from user space: the driver as a task the talk
 * draws, on a virtio 1.0 block device the microkernel has exposed
 * (ospreyblkexpose in os/osprey/port/devosprey.c, the descriptor in
 * ospreyabi.h).  The kernel gave this container the device's register
 * BAR as the segment "virtioblk", the offsets of the four virtio-pci
 * regions in it, the physical address of the container's own slice, and
 * a semaphore its interrupt gives.  Everything else is here, compiled
 * against the user headers: the reset and feature dance, a queue of
 * eight in this container's own data area, a request as three
 * descriptors - header, data, status - the notify, and a select on the
 * semaphore for the completion, which is what a driver task waits on.
 *
 * What it does when the server personality comes up, if there is a
 * device: reads sector 0 and prints what the host put there, writes a
 * stamp to the last sector - out of the way of the log the file system
 * keeps from sector 1 - and reads it back.  The check on the host side
 * reads that sector of the image afterwards and finds the stamp: a write
 * from a program above the microkernel reached the disk.
 */
#include <u.h>
#include <libc.h>

enum {
	Ospreyblkmagic	= 0x4f53424c4bULL,
	Ospreyblkoff	= 3584,
	Ospreyblkring	= 4096,
	Blkarmoff	= 128,		/* our select arm, clear of the serve loop's at 0 */
	OSdown		= 4,

	Qsize		= 8,
	Sacknowledge	= 1,
	Sdriver		= 2,
	Sdriverok	= 4,
	Sfeaturesok	= 8,
	Vconf_devfeatsel = 0, Vconf_devfeat = 4, Vconf_drvfeatsel = 8, Vconf_drvfeat = 12,
	Vconf_status = 20, Vconf_queuesel = 22, Vconf_queuesize = 24, Vconf_queueenable = 28,
	Vconf_queuenotifyoff = 30, Vconf_queuedesc = 32, Vconf_queueavail = 40, Vconf_queueused = 48,
	Dnext = 1, Dwrite = 2,
	Tin = 0, Tout = 1,
	Sector = 512,
};

typedef struct Ospreyblk Ospreyblk;
struct Ospreyblk { uvlong magic, slicepa, barsize, cfg, notify, notifymult, isr, devcfg, sem; };
typedef struct Omap Omap;
struct Omap {
	uvlong	magic, id, size, msgsize;
	uvlong	requestqueue, replyqueue, outputqueue;
	uvlong	request, reply, output;
	uvlong	data, datalen, sem, nsem, selected;
};
typedef struct Arm Arm;
struct Arm { uvlong op, obj, buf; };
typedef struct Vdesc Vdesc;
struct Vdesc { u64int addr; u32int len; u16int flags; u16int next; };
typedef struct Vhdr Vhdr;
struct Vhdr { u32int typ; u32int prio; u64int lba; };

/* the queue, in this container's data area, at offsets the device is told as physical addresses */
enum {
	Odesc	= Ospreyblkring,		/* 8 * 16 */
	Oavail	= Ospreyblkring + 128,		/* flags, idx, ring[8], used_event */
	Oused	= Ospreyblkring + 256,		/* flags, idx, ring[8] of {id, len}, avail_event */
	Ohdr	= Ospreyblkring + 384,
	Ostatus	= Ospreyblkring + 400,
	Obuf	= Ospreyblkring + 512,		/* one sector */
};

static uchar *bar, *data;
static Ospreyblk *blk;
static uvlong datapa;
static u16int avail_idx, last_used;
static int selects;			/* completions taken through the interrupt semaphore */

static void
say(char *s)
{
	write(2, s, strlen(s));
}

static u8int  r8(uvlong o)  { return *(volatile u8int*)(bar+o); }
static u16int r16(uvlong o) { return *(volatile u16int*)(bar+o); }
static u32int r32(uvlong o) { return *(volatile u32int*)(bar+o); }
static u64int r64(uvlong o) { return *(volatile u64int*)(bar+o); }
static void w8(uvlong o, u8int v)   { *(volatile u8int*)(bar+o) = v; }
static void w16(uvlong o, u16int v) { *(volatile u16int*)(bar+o) = v; }
static void w32(uvlong o, u32int v) { *(volatile u32int*)(bar+o) = v; }
static void w64(uvlong o, u64int v) { *(volatile u64int*)(bar+o) = v; }

static int
blkinit(void)
{
	uvlong cfg, f1;
	int n;

	cfg = blk->cfg;
	w8(cfg + Vconf_status, 0);
	for(n = 0; n < 100 && r8(cfg + Vconf_status) != 0; n++)
		sleep(1);
	w8(cfg + Vconf_status, Sacknowledge | Sdriver);
	w32(cfg + Vconf_devfeatsel, 1);
	f1 = r32(cfg + Vconf_devfeat);
	if((f1 & 1) == 0){
		say("blk: the device does not offer VERSION_1\n");
		return -1;
	}
	w32(cfg + Vconf_drvfeatsel, 1);
	w32(cfg + Vconf_drvfeat, 1);		/* VERSION_1 and nothing else */
	w32(cfg + Vconf_drvfeatsel, 0);
	w32(cfg + Vconf_drvfeat, 0);
	w8(cfg + Vconf_status, r8(cfg + Vconf_status) | Sfeaturesok);
	if((r8(cfg + Vconf_status) & Sfeaturesok) == 0){
		say("blk: the device refused the features\n");
		return -1;
	}
	w16(cfg + Vconf_queuesel, 0);
	n = r16(cfg + Vconf_queuesize);
	if(n == 0)
		return -1;
	if(n > Qsize)
		w16(cfg + Vconf_queuesize, Qsize);
	memset(data + Odesc, 0, Obuf - Odesc);
	w64(cfg + Vconf_queuedesc, datapa + Odesc);
	w64(cfg + Vconf_queueavail, datapa + Oavail);
	w64(cfg + Vconf_queueused, datapa + Oused);
	w16(cfg + Vconf_queueenable, 1);
	w8(cfg + Vconf_status, r8(cfg + Vconf_status) | Sdriverok);
	avail_idx = 0;
	last_used = 0;
	return 0;
}

/*
 * One request: the header, the sector, the status, chained; on the
 * avail ring; the device notified; then wait on the semaphore the
 * interrupt gives, and read the used ring.
 */
static int
blkio(int typ, uvlong lba)
{
	Vdesc *d;
	Vhdr *h;
	u16int *avail, *used;
	Arm *arm;
	int n, tries;

	d = (Vdesc*)(data + Odesc);
	h = (Vhdr*)(data + Ohdr);
	avail = (u16int*)(data + Oavail);
	used = (u16int*)(data + Oused);
	h->typ = typ;
	h->prio = 0;
	h->lba = lba;
	*(data + Ostatus) = 0xff;
	d[0].addr = datapa + Ohdr;    d[0].len = sizeof(Vhdr); d[0].flags = Dnext; d[0].next = 1;
	d[1].addr = datapa + Obuf;    d[1].len = Sector; d[1].flags = Dnext | (typ == Tin ? Dwrite : 0); d[1].next = 2;
	d[2].addr = datapa + Ostatus; d[2].len = 1; d[2].flags = Dwrite; d[2].next = 0;
	avail[2 + (avail_idx % Qsize)] = 0;		/* ring[i] = head descriptor 0 */
	avail[0] = 0;					/* flags: interrupt wanted */
	avail_idx++;
	avail[1] = avail_idx;
	w16(blk->notify + blk->notifymult * r16(blk->cfg + Vconf_queuenotifyoff), 0);
	/* the interrupt gives the semaphore; select on it, the driver task's wait */
	arm = (Arm*)(data + Blkarmoff);
	arm->op = OSdown;
	arm->obj = blk->sem;
	arm->buf = 0;
	for(tries = 0; tries < 200 && used[1] == last_used; tries++){
		n = dup(1, Blkarmoff);		/* select: blocks until the interrupt gives the semaphore */
		if(n == 0)
			selects++;
	}
	if(used[1] == last_used){
		say("blk: no completion\n");
		return -1;
	}
	last_used = used[1];
	return *(data + Ostatus);
}

/*
 * Called by the server personality as it comes up, with its slice mapped:
 * if the kernel exposed a device, drive it.  Reads sector 0, writes a
 * stamp to sector 1, reads it back.
 */
void
p9blk(uchar *base)
{
	Omap *map;
	char line[160], *s, *e;
	uvlong cap;
	int r, i;

	map = (Omap*)base;
	data = base + map->data;
	blk = (Ospreyblk*)(data + Ospreyblkoff);
	if(blk->magic != Ospreyblkmagic)
		return;			/* no device was exposed */
	bar = (uchar*)segattach(0, "virtioblk", 0, blk->barsize);	/* a length of 0 would mean a slice's worth */
	if(bar == (uchar*)-1){
		say("blk: could not map the device's registers\n");
		return;
	}
	datapa = blk->slicepa + map->data;
	if(blkinit() < 0)
		return;
	cap = r64(blk->devcfg);
	s = line;
	e = line + sizeof line;
	s = seprint(s, e, "blk: virtio block device driven from user space: %llud sectors, queue at pa %#llux\n", cap, datapa + Odesc);
	say(line);

	r = blkio(Tin, 0);
	for(i = 0; i < Sector && data[Obuf + i] >= ' ' && data[Obuf + i] < 127 && i < 60; i++)
		;
	seprint(line, e, "blk: read sector 0: status %d, text \"%.*s\"\n", r, i, (char*)(data + Obuf));
	say(line);

	memset(data + Obuf, 0, Sector);
	seprint((char*)(data + Obuf), (char*)(data + Obuf + Sector), "osprey wrote the last sector from user space");
	r = blkio(Tout, cap - 1);
	seprint(line, e, "blk: write sector %llud: status %d\n", cap - 1, r);
	say(line);

	memset(data + Obuf, 0, Sector);
	r = blkio(Tin, cap - 1);
	seprint(line, e, "blk: read sector %llud back: status %d, text \"%s\"\n", cap - 1, r, (char*)(data + Obuf));
	say(line);
	seprint(line, e, "blk: 3 requests, %d completions taken by select on the interrupt semaphore\n", selects);
	say(line);
}

/*
 * The face the file system sees, compiled against the kernel headers on
 * its side and the user headers on this: one sector in or out, and the
 * device's size.  A request is three descriptors and a select, as above.
 */
int
blkready(void)
{
	return bar != nil;
}

uvlong
blkcapacity(void)
{
	return bar == nil ? 0 : r64(blk->devcfg);
}

int
blkxfer(int wr, uvlong lba, void *buf)
{
	if(bar == nil)
		return -1;
	if(wr)
		memmove(data + Obuf, buf, Sector);
	if(blkio(wr ? Tout : Tin, lba) != 0)
		return -1;
	if(!wr)
		memmove(buf, data + Obuf, Sector);
	return 0;
}
