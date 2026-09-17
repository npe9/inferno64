/*
 * Google Virtual NIC (gVNIC, PCI 1ae0:0042), GQI queue format with
 * queue page lists.
 *
 * Written from FreeBSD's sys/dev/gve (BSD licence), which is the
 * reference for every layout and sequence below.  A Compute Engine
 * arm64 (t2a) instance offers this device and nothing else to put a
 * packet on the wire -- asking for virtio-net there is refused -- so
 * without it the arm64 cloud kernel has no network.
 *
 * The device is driven entirely through memory it can read and write:
 *  - BAR0 holds big-endian registers, among them the page frame number
 *    of a one-page admin queue of 64-byte commands.
 *  - BAR2 holds doorbells, also big-endian in this format.
 *  - A queue page list is a set of pages registered with the device.
 *    With QPL the device copies packets out of and into those pages
 *    itself, so descriptors carry offsets into them, not addresses.
 *
 * No interrupts.  gVNIC signals only through MSI-X, and on the t2a the
 * MSI-X path needs a GICv3 ITS this kernel does not drive.  Nothing is
 * lost by it: a completion is a DMA write the driver can read at any
 * time -- a receive descriptor's sequence number, a transmit event
 * counter -- and the interrupt doorbells only mask and acknowledge.
 * So each queue has a kproc that polls, busily while there is work and
 * once a tick while there is none.  That costs latency, up to a tick
 * on an idle link, and it is the first thing to replace once MSI-X is
 * available.
 *
 * One transmit and one receive queue.  No checksum offload, TSO or
 * receive coalescing: this kernel's IP stack computes and checks its
 * own checksums.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/pci.h"
#include "../port/error.h"
#include "../port/netif.h"
#include "../port/etherif.h"

static long ifstatinf(Ether*, void*, long, ulong);

typedef struct Ctlr Ctlr;

enum {
	Pgsz		= 4096,

	/* BAR0 registers, all big-endian */
	Rstatus		= 0,
	Rdrvstatus	= 4,
	Rmaxtxq		= 8,
	Rmaxrxq		= 12,
	Raqpfn		= 16,
	Raqdoorbell	= 20,
	Raqevent	= 24,
	Rdrvversion	= 31,

	Sreset		= 1<<1,
	Slink		= 1<<2,

	/* admin queue */
	Aqdescribe	= 0x1,
	Aqconfigure	= 0x2,
	Aqregpages	= 0x3,
	Aqcreatetx	= 0x5,
	Aqcreaterx	= 0x6,
	Aqverify	= 0xF,

	Aqpassed	= 0x1,


	Cmdsz		= 64,
	Naqslot		= Pgsz/Cmdsz,

	/* device options */
	Optgqirda	= 0x2,
	Optgqiqpl	= 0x3,
	Optdqorda	= 0x4,
	Optdqoqpl	= 0x7,

	Fmtgqiqpl	= 0x2,

	/* interrupt doorbell bits */
	Irqmask		= 1<<30,

	/* transmit descriptor */
	Txdsz		= 16,
	Txdstd		= 0x0<<4,
	Txdseg		= 0x2<<4,
	Txminhdr	= 182,		/* the spec's minimum first segment */

	/* receive descriptor */
	Rxdsz		= 64,
	Rxpad		= 2,
	Rxbufsz		= 2048,
	Rxferr		= 1<<(3+8),
	Rxfcont		= 1<<(3+10),

	Qressz		= 64,
	Irqdbstride	= 64,

	Txqpldivisor	= 16,
};

struct Ctlr {
	Lock;
	Ctlr	*next;
	Pcidev	*pcidev;
	int	active;
	int	attached;
	uvlong	port;
	uchar	*reg;		/* BAR0 */
	uchar	*db;		/* BAR2 */
	u32int	dbsize;

	/* admin queue */

	uchar	*aq;
	u32int	aqprod;
	int	aqfail;

	/* what the device said about itself */
	uvlong	maxpages;
	int	ntxd;
	int	nrxd;
	int	mtu;
	int	nctr;
	int	rxppq;
	int	maxtxq;
	int	maxrxq;
	char	opts[64];

	u32int	*ctr;		/* event counters, big-endian */
	uchar	*irqdb;		/* interrupt doorbell indices */

	/* transmit queue 0 */
	uchar	*txd;
	uchar	*txres;
	uchar	*txfifo;	/* the queue page list, one contiguous run */
	int	ntxpages;
	uintptr	*txpgs;
	u32int	txdb;
	u32int	txctr;
	u32int	txreq;
	u32int	txdone;
	int	txhead;
	int	txavail;
	int	*txused;	/* fifo bytes held by the packet at each slot */
	Rendez	txr;

	/* receive queue 0 */
	uchar	*rxd;
	uchar	*rxres;
	uvlong	*rxdata;
	uchar	*rxpages;
	uintptr	*rxpgs;
	u32int	rxdb;
	u32int	rxcnt;
	u32int	rxfill;
	int	rxseq;
	Rendez	rxr;

	/* statistics */
	ulong	txpkts;
	ulong	txfull;
	ulong	rxpkts;
	ulong	rxerr;
	ulong	rxdrop;
	ulong	rxpolls;
};

#define	BDF(t)	BUSBNO(t), BUSDNO(t), BUSFNO(t)
#define	Aqunimpl	0xFFFFFFFEUL

static Ctlr *ctlrhead;

static u32int
get32(uchar *p)
{
	return p[0]<<24 | p[1]<<16 | p[2]<<8 | p[3];
}

static int
get16(uchar *p)
{
	return p[0]<<8 | p[1];
}

static uvlong
get64(uchar *p)
{
	return (uvlong)get32(p)<<32 | get32(p+4);
}

static void
put32(uchar *p, u32int v)
{
	p[0] = v>>24;
	p[1] = v>>16;
	p[2] = v>>8;
	p[3] = v;
}

static void
put16(uchar *p, int v)
{
	p[0] = v>>8;
	p[1] = v;
}

static void
put64(uchar *p, uvlong v)
{
	put32(p, v>>32);
	put32(p+4, v);
}

/*
 * Registers are four big-endian bytes in a little-endian machine's
 * address space; read and write them as one word, swapped.
 */
static u32int
swap32(u32int v)
{
	return v>>24 | (v>>8 & 0xFF00) | (v<<8 & 0xFF0000) | v<<24;
}

static u32int
rreg(Ctlr *c, int r)
{
	return swap32(*(u32int*)(c->reg+r));
}

static void
wreg(Ctlr *c, int r, u32int v)
{
	*(u32int*)(c->reg+r) = swap32(v);
}

static void
wdb(Ctlr *c, u32int off, u32int v)
{
	if(off > c->dbsize - 4){
		iprint("gve: doorbell offset %#ux past a %#ux bar\n", off, c->dbsize);
		return;
	}
	*(u32int*)(c->db+off) = swap32(v);
}

static void*
dmalloc(usize n)
{
	uchar *p;

	n = ROUNDUP(n, Pgsz);
	p = mallocalign(n, Pgsz, 0, 0);
	if(p != nil)
		memset(p, 0, n);
	return p;
}

/*
 * Queue commands, then ring the doorbell once and wait for the device's
 * event counter to reach it.  FreeBSD gives a command ten tries twenty
 * milliseconds apart; creating queues on a real device can take longer
 * than that, so this waits up to five seconds.
 */
static uchar*
aqslot(Ctlr *c, int op)
{
	uchar *cmd;

	if(c->aqprod - rreg(c, Raqevent) >= Naqslot)
		return nil;
	cmd = c->aq + (c->aqprod % Naqslot)*Cmdsz;
	memset(cmd, 0, Cmdsz);
	put32(cmd, op);
	c->aqprod++;
	return cmd;
}

static int
aqkick(Ctlr *c, char *what)
{
	u32int tail, i, st, op;
	uchar *cmd;
	int n;

	tail = rreg(c, Raqevent);
	coherence();
	wreg(c, Raqdoorbell, c->aqprod);
	for(n = 0; rreg(c, Raqevent) != c->aqprod; n++){
		if(n >= 500){
			print("gve: %s: admin queue timed out, event %ud prod %ud status %#ux\n",
				what, rreg(c, Raqevent), c->aqprod, rreg(c, Rstatus));
			return -1;
		}
		delay(10);
	}
	for(i = tail; i != c->aqprod; i++){
		cmd = c->aq + (i % Naqslot)*Cmdsz;
		st = get32(cmd+4);
		op = get32(cmd);
		if(st != Aqpassed){
			c->aqfail++;
			print("gve: %s: command %ud failed, status %#ux\n", what, op, st);
			return st == Aqunimpl ? -2 : -1;
		}
	}
	return 0;
}

static int
aqexec(Ctlr *c, uchar *cmd, char *what)
{
	uchar *s;

	s = aqslot(c, get32(cmd));
	if(s == nil)
		return -1;
	memmove(s+4, cmd+4, Cmdsz-4);
	return aqkick(c, what);
}

static int
verifydriver(Ctlr *c)
{
	uchar cmd[Cmdsz], *info;
	int r;

	/*
	 * struct gve_driver_info: os type, three version bytes, three
	 * big-endian os version words, four capability words and two
	 * 128-byte strings.  Capability bit 0 is "GQI with queue page
	 * lists", the only format this driver speaks.  The os type is 0,
	 * because this is not one of the systems the device knows.
	 */
	info = dmalloc(Pgsz);
	if(info == nil)
		return -1;
	info[1] = 1;
	put64(info+16, 1<<0);
	strcpy((char*)info+48, "Inferno");
	memset(cmd, 0, sizeof cmd);
	put32(cmd, Aqverify);
	put64(cmd+8, 48+128+128);
	put64(cmd+16, PADDR(info));
	r = aqexec(c, cmd, "verify driver");
	free(info);
	if(r == -2)
		return 0;	/* a device that does not ask is fine */
	return r;
}

static int
describe(Ctlr *c, uchar *ea)
{
	uchar cmd[Cmdsz], *d, *o, *e;
	int i, nopt, id, len, gqiqpl;
	char *s, *se;

	d = dmalloc(Pgsz);
	if(d == nil)
		return -1;
	memset(cmd, 0, sizeof cmd);
	put32(cmd, Aqdescribe);
	put64(cmd+8, PADDR(d));
	put32(cmd+16, 1);
	put32(cmd+20, Pgsz);
	if(aqexec(c, cmd, "describe device") < 0){
		free(d);
		return -1;
	}
	memmove(ea, d+24, Eaddrlen);
	c->maxpages = get64(d);
	c->ntxd = get16(d+10);
	c->nrxd = get16(d+12);
	c->mtu = get16(d+16);
	c->nctr = get16(d+18);
	c->rxppq = get16(d+22);
	nopt = get16(d+30);
	len = get16(d+32);
	if(len > Pgsz)
		len = Pgsz;
	e = d + len;

	gqiqpl = 0;
	s = c->opts;
	se = s + sizeof c->opts;
	*s = 0;
	o = d + 40;
	for(i = 0; i < nopt; i++){
		if(o+8 > e || o+8+get16(o+2) > e){
			print("gve: device options run past the descriptor\n");
			break;
		}
		id = get16(o);
		switch(id){
		case Optgqirda:	s = seprint(s, se, " gqi-rda"); break;
		case Optgqiqpl:	s = seprint(s, se, " gqi-qpl"); gqiqpl = get32(o+4) == 0; break;
		case Optdqorda:	s = seprint(s, se, " dqo-rda"); break;
		case Optdqoqpl:	s = seprint(s, se, " dqo-qpl"); break;
		default:	s = seprint(s, se, " %#ux", id); break;
		}
		o += 8 + get16(o+2);
	}
	print("gve: ea %E mtu %d txd %d rxd %d counters %d rxpages %d maxpages %llud options%s\n",
		d+24, c->mtu, c->ntxd, c->nrxd, c->nctr, c->rxppq, c->maxpages, c->opts);
	free(d);
	if(!gqiqpl){
		print("gve: the device does not offer GQI with queue page lists\n");
		return -1;
	}
	if(c->ntxd == 0 || c->nrxd == 0 || (c->ntxd & (c->ntxd-1)) || (c->nrxd & (c->nrxd-1))){
		print("gve: ring sizes %d/%d are not powers of two\n", c->ntxd, c->nrxd);
		return -1;
	}
	return 0;
}

static int
regpages(Ctlr *c, int id, uintptr *pgs, int n)
{
	uchar cmd[Cmdsz];
	uchar *list;
	int i, r;

	list = dmalloc(n*8);
	if(list == nil)
		return -1;
	for(i = 0; i < n; i++)
		put64(list + i*8, PADDR(pgs[i]));
	memset(cmd, 0, sizeof cmd);
	put32(cmd, Aqregpages);
	put32(cmd+8, id);
	put32(cmd+12, n);
	put64(cmd+16, PADDR(list));
	put64(cmd+24, Pgsz);
	r = aqexec(c, cmd, "register pages");
	free(list);
	return r;
}

/*
 * Reset time: there is no process yet, so this busy-waits and cannot
 * raise an error.  It learns what the device is and its address.
 */
static int
identify(Ctlr *c, uchar *ea)
{
	int i;

	/*
	 * The firmware may have left the device running; releasing the
	 * admin queue makes the device drop everything registered with
	 * it.  On a fresh device the register already reads 0.
	 */
	if(rreg(c, Raqpfn) != 0)
		wreg(c, Raqpfn, 0);
	for(i = 0; rreg(c, Raqpfn) != 0; i++){
		if(i >= 500){
			print("gve: admin queue never released\n");
			return -1;
		}
		delay(10);
	}

	c->aq = dmalloc(Pgsz);
	if(c->aq == nil)
		return -1;
	c->aqprod = 0;
	wreg(c, Raqpfn, PADDR(c->aq)/Pgsz);

	/* the device reads this a byte at a time, newline-terminated */
	{
		char *v = "GVE-Inferno-1.0\n";
		for(i = 0; v[i]; i++)
			c->reg[Rdrvversion] = v[i];
	}

	if(verifydriver(c) < 0)
		return -1;
	if(describe(c, ea) < 0)
		return -1;
	c->maxtxq = rreg(c, Rmaxtxq);
	c->maxrxq = rreg(c, Rmaxrxq);
	print("gve: status %#ux maxq tx %d rx %d\n", rreg(c, Rstatus), c->maxtxq, c->maxrxq);
	if(c->maxtxq < 1 || c->maxrxq < 1)
		return -1;

	return 0;
}

/*
 * Attach time, in a process: build and register the rings and start
 * the queues.  Allocation failures raise errors.
 */
static void*
need(usize n)
{
	void *p;

	p = dmalloc(n);
	if(p == nil)
		error(Enomem);
	return p;
}

static void
start(Ctlr *c)
{
	uchar cmd[Cmdsz], *d;
	int i, ndb;

	/* device resources: counters and interrupt doorbell indices */
	ndb = c->maxtxq + c->maxrxq;
	c->ctr = need(c->nctr*4);
	c->irqdb = need(ndb*Irqdbstride);
	memset(cmd, 0, sizeof cmd);
	put32(cmd, Aqconfigure);
	put64(cmd+8, PADDR(c->ctr));
	put64(cmd+16, PADDR(c->irqdb));
	put32(cmd+24, c->nctr);
	put32(cmd+28, ndb);
	put32(cmd+32, Irqdbstride);
	put32(cmd+36, 0);
	cmd[40] = Fmtgqiqpl;
	if(aqexec(c, cmd, "configure resources") < 0)
		error("gve: configure resources failed");

	/*
	 * Transmit: a ring of descriptors and a fifo of ntxd/16 pages,
	 * one contiguous run so a packet can be copied in with one
	 * memmove.  Receive: a ring of descriptors, a ring of data
	 * slots, and a page per slot.  Page list ids: transmit queue i
	 * is i, receive queue i is maxtxq+i.
	 */
	c->txd = need(c->ntxd*Txdsz);
	c->txres = need(Qressz);
	c->ntxpages = c->ntxd/Txqpldivisor;
	c->txfifo = need(c->ntxpages*Pgsz);
	c->txpgs = malloc(c->ntxpages*sizeof(uintptr));
	c->txused = malloc(c->ntxd*sizeof(int));
	if(c->txpgs == nil || c->txused == nil)
		error(Enomem);
	for(i = 0; i < c->ntxpages; i++)
		c->txpgs[i] = (uintptr)c->txfifo + i*Pgsz;
	c->txavail = c->ntxpages*Pgsz;
	c->txhead = 0;

	c->rxd = need(c->nrxd*Rxdsz);
	c->rxres = need(Qressz);
	c->rxdata = need(c->nrxd*8);
	c->rxpages = need((uvlong)c->nrxd*Pgsz);
	c->rxpgs = malloc(c->nrxd*sizeof(uintptr));
	if(c->rxpgs == nil)
		error(Enomem);
	for(i = 0; i < c->nrxd; i++){
		c->rxpgs[i] = (uintptr)c->rxpages + i*Pgsz;
		put64((uchar*)&c->rxdata[i], (uvlong)i*Pgsz);
	}

	if(c->ntxpages + c->nrxd > c->maxpages){
		print("gve: %d pages wanted, the device takes %llud\n",
			c->ntxpages + c->nrxd, c->maxpages);
		error("gve: too many pages");
	}
	if(regpages(c, 0, c->txpgs, c->ntxpages) < 0
	|| regpages(c, c->maxtxq, c->rxpgs, c->nrxd) < 0)
		error("gve: register pages failed");

	/* create the queues */
	d = aqslot(c, Aqcreaterx);
	if(d == nil)
		error("gve: admin queue full");
	put32(d+8, 0);			/* queue id */
	put32(d+12, 0);			/* index */
	put32(d+20, 1);			/* notify block: after the one transmit queue */
	put64(d+24, PADDR(c->rxres));
	put64(d+32, PADDR(c->rxd));
	put64(d+40, PADDR(c->rxdata));
	put32(d+48, c->maxtxq);		/* page list id */
	put16(d+52, c->nrxd);
	put16(d+54, Rxbufsz);
	if(aqkick(c, "create rx queue") < 0)
		error("gve: create rx queue failed");

	d = aqslot(c, Aqcreatetx);
	if(d == nil)
		error("gve: admin queue full");
	put32(d+8, 0);
	put64(d+16, PADDR(c->txres));
	put64(d+24, PADDR(c->txd));
	put32(d+32, 0);			/* page list id */
	put32(d+36, 0);			/* notify block */
	put16(d+48, c->ntxd);
	if(aqkick(c, "create tx queue") < 0)
		error("gve: create tx queue failed");

	c->txdb = 4*get32(c->txres);
	c->txctr = get32(c->txres+4);
	c->rxdb = 4*get32(c->rxres);
	if(c->txctr >= c->nctr){
		print("gve: transmit counter index %ud past %d counters\n", c->txctr, c->nctr);
		error("gve: bad counter index");
	}

	/* keep both queues' interrupts masked: this driver polls */
	wdb(c, 4*get32(c->irqdb + 0*Irqdbstride), Irqmask);
	wdb(c, 4*get32(c->irqdb + 1*Irqdbstride), Irqmask);

	/* every receive slot is already posted */
	c->rxseq = 1;
	c->rxcnt = 0;
	c->rxfill = c->nrxd;
	coherence();
	wdb(c, c->rxdb, c->rxfill);

	print("gve: up: tx doorbell %#ux counter %ud, rx doorbell %#ux, status %#ux\n",
		c->txdb, c->txctr, c->rxdb, rreg(c, Rstatus));

}

static u32int
txcompleted(Ctlr *c)
{
	return swap32(c->ctr[c->txctr]);
}

static void
txreclaim(Ctlr *c)
{
	u32int done;

	done = txcompleted(c);
	while(c->txdone != done){
		c->txavail += c->txused[c->txdone & (c->ntxd-1)];
		c->txused[c->txdone & (c->ntxd-1)] = 0;
		c->txdone++;
	}
}

static int
txroom(void *v)
{
	Ctlr *c;

	c = v;
	return txcompleted(c) != c->txdone;
}

/*
 * A packet goes in as two descriptors: the first min(len, 182) bytes
 * under the packet descriptor, the rest under one segment descriptor.
 * The fifo keeps each packet contiguous -- if it will not fit before
 * the end, the tail is skipped as padding -- and is realigned to 64
 * bytes after it, which is what the device expects of the headers.
 */
static int
txput(Ctlr *c, Block *b)
{
	int len, hlen, need, pad, off, ndesc;
	u32int i;
	uchar *d;

	len = BLEN(b);
	hlen = len < Txminhdr ? len : Txminhdr;
	ndesc = len > hlen ? 2 : 1;
	pad = 0;
	if(c->txhead + len > c->ntxpages*Pgsz)
		pad = c->ntxpages*Pgsz - c->txhead;
	need = pad + ROUNDUP(len, 64);
	if(c->ntxd - (c->txreq - c->txdone) < ndesc + 1 || c->txavail < need)
		return -1;

	off = (c->txhead + pad) % (c->ntxpages*Pgsz);
	memmove(c->txfifo + off, b->rp, len);
	c->txhead = (off + ROUNDUP(len, 64)) % (c->ntxpages*Pgsz);
	c->txavail -= need;

	i = c->txreq;
	c->txused[i & (c->ntxd-1)] = need;
	d = c->txd + (i & (c->ntxd-1))*Txdsz;
	memset(d, 0, Txdsz);
	d[0] = Txdstd;
	d[3] = ndesc;
	put16(d+4, len);
	put16(d+6, hlen);
	put64(d+8, off);
	if(ndesc == 2){
		d = c->txd + ((i+1) & (c->ntxd-1))*Txdsz;
		memset(d, 0, Txdsz);
		d[0] = Txdseg;
		put16(d+6, len - hlen);
		put64(d+8, off + hlen);
		c->txused[(i+1) & (c->ntxd-1)] = 0;
	}
	c->txreq += ndesc;
	coherence();
	wdb(c, c->txdb, c->txreq);
	c->txpkts++;
	return 0;
}

static void
txproc(void *v)
{
	Ether *edev;
	Ctlr *c;
	Block *b;

	edev = v;
	c = edev->ctlr;
	while(waserror())
		;
	while((b = qbread(edev->oq, 1000000)) != nil){
		txreclaim(c);
		if(BLEN(b) > c->mtu + ETHERHDRSIZE){
			freeb(b);
			continue;
		}
		while(txput(c, b) < 0){
			c->txfull++;
			tsleep(&c->txr, txroom, c, 10);
			txreclaim(c);
		}
		freeb(b);
	}
	pexit("ether out queue closed", 1);
}

static int
rxready(void *v)
{
	Ctlr *c;
	uchar *d;

	c = v;
	d = c->rxd + (c->rxcnt & (c->nrxd-1))*Rxdsz;
	return (get16(d+62) & 7) == c->rxseq;
}

static void
rxproc(void *v)
{
	Ether *edev;
	Ctlr *c;
	Block *b;
	uchar *d, *p;
	int flags, len, slot, n;

	edev = v;
	c = edev->ctlr;
	while(waserror())
		;
	for(;;){
		c->rxpolls++;
		tsleep(&c->rxr, rxready, c, 10);
		n = 0;
		while(rxready(c)){
			slot = c->rxcnt & (c->nrxd-1);
			d = c->rxd + slot*Rxdsz;
			flags = get16(d+62);
			len = get16(d+60);
			p = (uchar*)c->rxpgs[slot];
			c->rxcnt++;
			c->rxseq = c->rxseq == 7 ? 1 : c->rxseq+1;
			n++;
			if(flags & Rxfcont){
				/*
				 * A frame split over slots only happens
				 * for jumbo frames, which this driver
				 * never enables; count and drop.
				 */
				c->rxdrop++;
				continue;
			}
			if((flags & Rxferr) || len < Rxpad+ETHERHDRSIZE || len > Rxbufsz){
				c->rxerr++;
				continue;
			}
			len -= Rxpad;
			b = iallocb(len);
			if(b == nil){
				c->rxdrop++;
				continue;
			}
			memmove(b->wp, p+Rxpad, len);
			b->wp += len;
			c->rxpkts++;
			etheriq(edev, b);
		}
		if(n > 0){
			c->rxfill += n;
			coherence();
			wdb(c, c->rxdb, c->rxfill);
		}
	}
}

static void
attach(Ether *edev)
{
	char name[KNAMELEN];
	Ctlr *c;

	c = edev->ctlr;
	ilock(c);
	if(c->attached){
		iunlock(c);
		return;
	}
	c->attached = 1;
	iunlock(c);

	if(waserror()){
		print("gve: attach: %s\n", up->env->errstr);
		nexterror();
	}
	start(c);
	poperror();

	snprint(name, sizeof name, "#l%drx", edev->ctlrno);
	kproc(name, rxproc, edev, 0);
	snprint(name, sizeof name, "#l%dtx", edev->ctlrno);
	kproc(name, txproc, edev, 0);
}

static char*
ifstat(void *a, char *s, char *e)
{
	Ether *edev;
	Ctlr *c;

	edev = a;
	c = edev->ctlr;
	s = seprint(s, e, "status %#ux mtu %d options%s\n", rreg(c, Rstatus), c->mtu, c->opts);
	s = seprint(s, e, "tx req %ud done %ud nic %ud pkts %lud full %lud fifo %d/%d\n",
		c->txreq, c->txdone, txcompleted(c), c->txpkts, c->txfull,
		c->txavail, c->ntxpages*Pgsz);
	s = seprint(s, e, "rx cnt %ud fill %ud seq %d pkts %lud err %lud drop %lud polls %lud\n",
		c->rxcnt, c->rxfill, c->rxseq, c->rxpkts, c->rxerr, c->rxdrop, c->rxpolls);
	s = seprint(s, e, "adminq prod %ud event %ud failed %d\n",
		c->aqprod, rreg(c, Raqevent), c->aqfail);
	return s;
}

static long
ifstatinf(Ether *edev, void *a, long n, ulong offset)
{
	return ether9ifstat(edev, a, n, offset, ifstat);
}

static void
shutdown(Ether *edev)
{
	Ctlr *c;

	c = edev->ctlr;
	wreg(c, Raqpfn, 0);
	pciclrbme(c->pcidev);
}

static void
promiscuous(void*, int)
{
}

static void
multicast(void*, uchar*, int)
{
}

static uvlong
barbase(Pcidev *p, int bar)
{
	if(p->mem[bar].bar & 1)
		return 0;
	return p->mem[bar].bar & ~0xFULL;
}

static Ctlr*
pciprobe(void)
{
	Ctlr *c, *h, *t;
	Pcidev *p;
	uvlong r, d;

	h = t = nil;
	for(p = nil; p = pcimatch(p, 0x1AE0, 0x0042);){
		r = barbase(p, 0);
		d = barbase(p, 2);
		print("gve: pci %d.%d.%d bar0 %#llux size %d bar2 %#llux size %d\n",
			BDF(p->tbdf), r, p->mem[0].size, d, p->mem[2].size);
		if(r == 0 || d == 0){
			print("gve: pci %d.%d.%d: register or doorbell bar missing\n", BDF(p->tbdf));
			continue;
		}
		c = mallocz(sizeof(Ctlr), 1);
		if(c == nil)
			break;
		c->pcidev = p;
		c->port = r;
		pcienable(p);
		c->reg = vmap(r, p->mem[0].size);
		c->db = vmap(d, p->mem[2].size);
		c->dbsize = p->mem[2].size;
		if(c->reg == nil || c->db == nil){
			print("gve: pci %d.%d.%d: cannot map bars\n", BDF(p->tbdf));
			free(c);
			continue;
		}
		pcisetbme(p);
		print("gve: pci %d.%d.%d status %#ux maxq tx %ud rx %ud aqpfn %#ux\n", BDF(p->tbdf),
			rreg(c, Rstatus), rreg(c, Rmaxtxq), rreg(c, Rmaxrxq), rreg(c, Raqpfn));
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
	Ctlr *c;
	uchar ea[Eaddrlen];

	if(ctlrhead == nil)
		ctlrhead = pciprobe();
	for(c = ctlrhead; c != nil; c = c->next){
		if(c->active)
			continue;
		if(edev->port == 0 || edev->port == c->port){
			c->active = 1;
			break;
		}
	}
	if(c == nil)
		return -1;

	if(identify(c, ea) < 0){
		print("gve: pci %d.%d.%d: not usable\n", BDF(c->pcidev->tbdf));
		return -1;
	}

	edev->ctlr = c;
	edev->port = c->port;
	edev->irq = -1;
	edev->tbdf = c->pcidev->tbdf;
	edev->mbps = 10000;
	edev->link = (rreg(c, Rstatus) & Slink) != 0;
	edev->maxmtu = c->mtu + ETHERHDRSIZE;
	memmove(edev->ea, ea, Eaddrlen);
	edev->arg = edev;
	edev->attach = attach;
	edev->shutdown = shutdown;
	edev->ifstat = ifstatinf;
	edev->multicast = multicast;
	edev->promiscuous = promiscuous;
	return 0;
}

void
ethergvelink(void)
{
	addethercard("gve", reset);
}
