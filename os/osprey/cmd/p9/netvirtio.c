/*
 * A network device driven from user space: the driver as a task, on a
 * virtio 1.0 network device the microkernel has exposed (ospreynetexpose
 * in os/osprey/port/devosprey.c, the descriptor in ospreyabi.h), the way
 * blkvirtio.c drives the block device.  The kernel gave this container
 * the device's register BAR as the segment "virtionet", the offsets of
 * the four virtio-pci regions in it, the physical address of the
 * container's own slice, and a semaphore its interrupt gives.  The two
 * queues - receive and transmit, eight entries each - and the frames
 * live in the slice's packet and transmit buffers, which the kernel
 * laid out for lending to an interface and which are contiguous with
 * the slice, so a physical address is the slice's plus an offset.  The
 * real Plan 9 stack reaches the device through ospreyvnetmedium.c, which
 * calls the plain-typed functions at the end.
 *
 * Only VERSION_1 and MAC are asked of the device: no offloads, no merged
 * receive buffers, so a received frame is one buffer with the 12-byte
 * virtio-net header in front of it.
 */
#include <u.h>
#include <libc.h>

enum {
	Ospreynetmagic	= 0x4f534e4554ULL,
	Ospreynetoff	= 3712,
	Qsize		= 16,		/* a power of two, as a split virtqueue must be */
	Sacknowledge	= 1,
	Sdriver		= 2,
	Sdriverok	= 4,
	Sfeaturesok	= 8,
	Vconf_devfeatsel = 0, Vconf_devfeat = 4, Vconf_drvfeatsel = 8, Vconf_drvfeat = 12,
	Vconf_status = 20, Vconf_queuesel = 22, Vconf_queuesize = 24, Vconf_queueenable = 28,
	Vconf_queuenotifyoff = 30, Vconf_queuedesc = 32, Vconf_queueavail = 40, Vconf_queueused = 48,
	Dnext = 1, Dwrite = 2,
	Vnethdr		= 12,		/* virtio_net_hdr under VERSION_1, num_buffers included */
	Maxframe	= 1514,
	Rxq		= 0,
	Txq		= 1,
	Odesc		= 0,		/* a queue's rings, inside one packet buffer: 16 descriptors, avail, used */
	Oavail		= 256,
	Oused		= 512,
	Nrxbuf		= Qsize,	/* receive buffers posted: the kernel lays out 32 packet buffers, 2 hold the rings */
	Rxfirst		= 2,		/* packet buffers 0 and 1 hold the two queues' rings */
};

typedef struct Ospreynet Ospreynet;
struct Ospreynet { uvlong magic, slicepa, barsize, cfg, notify, notifymult, isr, devcfg, sem; };
typedef struct Omap Omap;
struct Omap {
	uvlong	magic, id, size, msgsize;
	uvlong	requestqueue, replyqueue, outputqueue;
	uvlong	request, reply, output;
	uvlong	data, datalen, sem, nsem, selected;
	uvlong	pktbuf, npktbuf, pktbufsize;
	uvlong	page, npage, maxpage, pagesize;
	uvlong	txbuf, ntxbuf, txbufsize;
};
typedef struct Vdesc Vdesc;
struct Vdesc { u64int addr; u32int len; u16int flags; u16int next; };

static uchar *bar, *base;
static Omap *map;
static Ospreynet *net;
static uvlong slicepa;
static uchar mac[6];
static u16int rxavail, rxlastused, txavail, txlastused;
static u16int notifyoff[2];
static long rxframes, txframes, txdrops, txrefused;

static void
say(char *s)
{
	write(2, s, strlen(s));
}

static u8int  r8(uvlong o)  { return *(volatile u8int*)(bar+o); }
static u16int r16(uvlong o) { return *(volatile u16int*)(bar+o); }
static u32int r32(uvlong o) { return *(volatile u32int*)(bar+o); }
static void w8(uvlong o, u8int v)   { *(volatile u8int*)(bar+o) = v; }
static void w16(uvlong o, u16int v) { *(volatile u16int*)(bar+o) = v; }
static void w32(uvlong o, u32int v) { *(volatile u32int*)(bar+o) = v; }
static void w64(uvlong o, u64int v) { *(volatile u64int*)(bar+o) = v; }

static uchar*	pktbuf(int i)	{ return base + map->pktbuf + i*map->pktbufsize; }
static uvlong	pktbufpa(int i)	{ return slicepa + map->pktbuf + i*map->pktbufsize; }
static uchar*	txbuf(int i)	{ return base + map->txbuf + i*map->txbufsize; }
static uvlong	txbufpa(int i)	{ return slicepa + map->txbuf + i*map->txbufsize; }
static Vdesc*	qdesc(int q)	{ return (Vdesc*)(pktbuf(q) + Odesc); }
static u16int*	qavail(int q)	{ return (u16int*)(pktbuf(q) + Oavail); }
static u16int*	qused(int q)	{ return (u16int*)(pktbuf(q) + Oused); }

static void
qnotify(int q)
{
	w16(net->notify + net->notifymult * notifyoff[q], q);
}

static int
qsetup(int q)
{
	int n;

	w16(net->cfg + Vconf_queuesel, q);
	n = r16(net->cfg + Vconf_queuesize);
	if(n == 0)
		return -1;
	if(n > Qsize)
		w16(net->cfg + Vconf_queuesize, Qsize);
	memset(pktbuf(q), 0, 1024);
	w64(net->cfg + Vconf_queuedesc, pktbufpa(q) + Odesc);
	w64(net->cfg + Vconf_queueavail, pktbufpa(q) + Oavail);
	w64(net->cfg + Vconf_queueused, pktbufpa(q) + Oused);
	notifyoff[q] = r16(net->cfg + Vconf_queuenotifyoff);
	w16(net->cfg + Vconf_queueenable, 1);
	return 0;
}

/* a receive buffer offered to the device */
static void
rxpost(int id)
{
	Vdesc *d = qdesc(Rxq);
	u16int *avail = qavail(Rxq);

	d[id].addr = pktbufpa(Rxfirst + id);
	d[id].len = map->pktbufsize;
	d[id].flags = Dwrite;
	d[id].next = 0;
	avail[2 + (rxavail % Qsize)] = id;
	rxavail++;
	avail[0] = 0;
	avail[1] = rxavail;
}

static int
netinit(void)
{
	uvlong f0, f1;
	int n, i;

	w8(net->cfg + Vconf_status, 0);
	for(n = 0; n < 100 && r8(net->cfg + Vconf_status) != 0; n++)
		sleep(1);
	w8(net->cfg + Vconf_status, Sacknowledge | Sdriver);
	w32(net->cfg + Vconf_devfeatsel, 1);
	f1 = r32(net->cfg + Vconf_devfeat);
	w32(net->cfg + Vconf_devfeatsel, 0);
	f0 = r32(net->cfg + Vconf_devfeat);
	if((f1 & 1) == 0){
		say("vnet: the device does not offer VERSION_1\n");
		return -1;
	}
	w32(net->cfg + Vconf_drvfeatsel, 1);
	w32(net->cfg + Vconf_drvfeat, 1);		/* VERSION_1 */
	w32(net->cfg + Vconf_drvfeatsel, 0);
	w32(net->cfg + Vconf_drvfeat, f0 & (1<<5));	/* MAC, if it offers one, and nothing else */
	w8(net->cfg + Vconf_status, r8(net->cfg + Vconf_status) | Sfeaturesok);
	if((r8(net->cfg + Vconf_status) & Sfeaturesok) == 0){
		say("vnet: the device refused the features\n");
		return -1;
	}
	if(qsetup(Rxq) < 0 || qsetup(Txq) < 0)
		return -1;
	w8(net->cfg + Vconf_status, r8(net->cfg + Vconf_status) | Sdriverok);
	for(i = 0; i < 6; i++)
		mac[i] = r8(net->devcfg + i);
	rxavail = rxlastused = txavail = txlastused = 0;
	for(i = 0; i < Nrxbuf; i++)
		rxpost(i);
	qnotify(Rxq);
	return 0;
}

/*
 * Called by the server personality as it comes up, with its slice
 * mapped: if the kernel exposed a network device, bring it up.
 */
void
p9vnet(uchar *b)
{
	char line[160];

	base = b;
	map = (Omap*)base;
	net = (Ospreynet*)(base + map->data + Ospreynetoff);
	if(net->magic != Ospreynetmagic)
		return;			/* no device was exposed */
	if(map->npktbuf < Rxfirst + Nrxbuf || map->ntxbuf < Qsize){
		say("vnet: the slice has too few packet or transmit buffers for the queues\n");
		return;
	}
	bar = (uchar*)segattach(0, "virtionet", 0, net->barsize);
	if(bar == (uchar*)-1){
		say("vnet: could not map the device's registers\n");
		bar = nil;
		return;
	}
	slicepa = net->slicepa;
	if(netinit() < 0){
		bar = nil;
		return;
	}
	seprint(line, line + sizeof line, "vnet: virtio network device driven from user space, mac %02x:%02x:%02x:%02x:%02x:%02x, %d receive buffers posted, queues in the slice at pa %#llux\n",
		mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], Nrxbuf, pktbufpa(0));
	say(line);
}

/* the face the medium sees, plain types */
int
vnet_ready(void)
{
	return bar != nil;
}

void
vnet_mac(uchar *m)
{
	memmove(m, mac, 6);
}

int
vnet_sem(void)
{
	return bar != nil ? (int)net->sem : -1;
}

/* a frame out: into the next transmit buffer, behind a zero virtio-net header, and the device told */
int
vnet_send(uchar *frame, long n)
{
	Vdesc *d = qdesc(Txq);
	u16int *avail = qavail(Txq), *used = qused(Txq);
	int slot;
	uchar *b;

	int spin;

	if(bar == nil || n > Maxframe)
		return -1;
	/*
	 * Reclaim what the device has sent; if every buffer is still in
	 * flight say so and the medium keeps the frame in its own queue
	 * until the device's interrupt says a slot is free (ospreyvnetpump
	 * drains it).  This spun for a slot once, and dropped before that.
	 */
	USED(spin);
	while(txlastused != used[1])
		txlastused++;
	if((u16int)(txavail - txlastused) >= Qsize){
		txrefused++;
		return -1;		/* every buffer in flight: not sent, not dropped */
	}
	slot = txavail % Qsize;
	b = txbuf(slot);
	memset(b, 0, Vnethdr);
	memmove(b + Vnethdr, frame, n);
	d[slot].addr = txbufpa(slot);
	d[slot].len = Vnethdr + n;
	d[slot].flags = 0;
	d[slot].next = 0;
	avail[2 + (txavail % Qsize)] = slot;
	txavail++;
	avail[0] = 0;
	avail[1] = txavail;
	qnotify(Txq);
	txframes++;
	return 0;
}

/* a frame in, if the device has put one in a buffer: copied out, the buffer offered again */
long
vnet_recv(uchar *frame, long max)
{
	u16int *used = qused(Rxq);
	u32int *e;
	int id;
	long n;

	if(bar == nil || rxlastused == used[1])
		return 0;
	e = (u32int*)(used + 2) + 2 * (rxlastused % Qsize);	/* {id, len} */
	id = e[0];
	n = (long)e[1] - Vnethdr;
	rxlastused++;
	if(id >= 0 && id < Nrxbuf){
		if(n > max)
			n = max;
		if(n > 0)
			memmove(frame, pktbuf(Rxfirst + id) + Vnethdr, n);
		rxpost(id);
		qnotify(Rxq);
	} else
		n = 0;
	if(n > 0)
		rxframes++;
	return n > 0 ? n : 0;
}

void
vnet_stats(long *rx, long *tx, long *drops)
{
	*rx = rxframes;
	*tx = txframes;
	*drops = txdrops;
}

/* times a send found every buffer in flight and left the frame with the medium */
long
vnet_refused(void)
{
	return txrefused;
}

/* is there a transmit slot free now?  the medium asks before it tries a queued frame */
int
vnet_cansend(void)
{
	u16int *used;

	if(bar == nil)
		return 0;
	used = qused(Txq);
	while(txlastused != used[1])
		txlastused++;
	return (u16int)(txavail - txlastused) < Qsize;
}
