/*
 * intel 10GB ethernet pci-express driver
 * copyright © 2007, coraid, inc.
 *
 * The 82598 and the 82599 (X520).  On the 82599, with *ixgbevfs=n in
 * plan9.ini, the driver is an SR-IOV PF as well: see i82599sriov.
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

/*
 * // comments note conflicts with 82563-style drivers,
 * and the registers are all different.
 */

enum {
	/* general */
	Ctrl		= 0x00000/4,	/* Device Control */
	Status		= 0x00008/4,	/* Device Status */
	Ctrlext		= 0x00018/4,	/* Extended Device Control */
	Esdp		= 0x00020/4,	/* extended sdp control */
	Esodp		= 0x00028/4,	/* extended od sdp control */
	Ledctl		= 0x00200/4,	/* led control */
	Tcptimer	= 0x0004c/4,	/* tcp timer */
	Ecc		= 0x110b0/4,	/* errata ecc control magic */

	/* nvm */
	Eec		= 0x10010/4,	/* eeprom/flash control */
	Eerd		= 0x10014/4,	/* eeprom read */
	Fla		= 0x1001c/4,	/* flash access */
	Flop		= 0x1013c/4,	/* flash opcode */
	Grc		= 0x10200/4,	/* general rx control */

	/* interrupt */
	Icr		= 0x00800/4,	/* interrupt cause read */
	Ics		= 0x00808/4,	/* " set */
	Ims		= 0x00880/4,	/* " mask read/set */
	Imc		= 0x00888/4,	/* " mask clear */
	Iac		= 0x00810/4,	/* " ayto clear */
	Iam		= 0x00890/4,	/* " auto mask enable */
	Itr		= 0x00820/4,	/* " throttling rate (0-19) */
	Ivar		= 0x00900/4,	/* " vector allocation regs. */
	/* msi interrupt */
	Msixt		= 0x0000/4,	/* msix table (bar3) */
	Msipba		= 0x2000/4,	/* msix pending bit array (bar3) */
	Pbacl		= 0x11068/4,	/* pba clear */
	Gpie		= 0x00898/4,	/* general purpose int enable */

	/* flow control */
	Pfctop		= 0x03008/4,	/* priority flow ctl type opcode */
	Fcttv		= 0x03200/4,	/* " transmit timer value (0-3) */
	Fcrtl		= 0x03220/4,	/* " rx threshold low (0-7) +8n */
	Fcrth		= 0x03260/4,	/* " rx threshold high (0-7) +8n */
	Rcrtv		= 0x032a0/4,	/* " refresh value threshold */
	Tfcs		= 0x0ce00/4,	/* " tx status */

	/* rx dma */
	Rbal		= 0x01000/4,	/* rx desc base low (0-63) +0x40n */
	Rbah		= 0x01004/4,	/* " high */
	Rdlen		= 0x01008/4,	/* " length */
	Rdh		= 0x01010/4,	/* " head */
	Rdt		= 0x01018/4,	/* " tail */
	Rxdctl		= 0x01028/4,	/* " control */

	Srrctl		= 0x02100/4,	/* split and replication rx ctl. */
	Dcarxctl	= 0x02200/4,	/* rx dca control */
	Rdrxctl		= 0x02f00/4,	/* rx dma control */
	Rxpbsize	= 0x03c00/4,	/* rx packet buffer size */
	Rxctl		= 0x03000/4,	/* rx control */
	Dropen		= 0x03d04/4,	/* drop enable control */

	/* rx */
	Rxcsum		= 0x05000/4,	/* rx checksum control */
	Rfctl		= 0x04008/4,	/* rx filter control */
	Mta		= 0x05200/4,	/* multicast table array (0-127) */
	Ral		= 0x05400/4,	/* rx address low */
	Rah		= 0x05404/4,
	Psrtype		= 0x05480/4,	/* packet split rx type. */
	Vfta		= 0x0a000/4,	/* vlan filter table array. */
	Fctrl		= 0x05080/4,	/* filter control */
	Vlnctrl		= 0x05088/4,	/* vlan control */
	Msctctrl	= 0x05090/4,	/* multicast control */
	Mrqc		= 0x05818/4,	/* multiple rx queues cmd */
	Vmdctl		= 0x0581c/4,	/* vmdq control */
	Imir		= 0x05a80/4,	/* immediate irq rx (0-7) */
	Imirext		= 0x05aa0/4,	/* immediate irq rx ext */
	Imirvp		= 0x05ac0/4,	/* immediate irq vlan priority */
	Reta		= 0x05c00/4,	/* redirection table */
	Rssrk		= 0x05c80/4,	/* rss random key */

	/* tx */
	Tdbal		= 0x06000/4,	/* tx desc base low +0x40n */
	Tdbah		= 0x06004/4,	/* " high */
	Tdlen		= 0x06008/4,	/* " len */
	Tdh		= 0x06010/4,	/* " head */
	Tdt		= 0x06018/4,	/* " tail */
	Txdctl		= 0x06028/4,	/* " control */
	Tdwbal		= 0x06038/4,	/* " write-back address low */
	Tdwbah		= 0x0603c/4,
	Dmatxctl	= 0x04a80/4,
	
	Dtxctl		= 0x07e00/4,	/* tx dma control */
	Tdcatxctrl	= 0x07200/4,	/* tx dca register (0-15) */
	Tipg		= 0x0cb00/4,	/* tx inter-packet gap */
	Txpbsize	= 0x0cc00/4,	/* tx packet-buffer size (0-15) */

	/* mac */
	Hlreg0		= 0x04240/4,	/* highlander control reg 0 */
	Hlreg1		= 0x04244/4,	/* highlander control reg 1 (ro) */
	Msca		= 0x0425c/4,	/* mdi signal cmd & addr */
	Msrwd		= 0x04260/4,	/* mdi single rw data */
	Mhadd		= 0x04268/4,	/* mac addr high & max frame */
	Pcss1		= 0x04288/4,	/* xgxs status 1 */
	Pcss2		= 0x0428c/4,
	Xpcss		= 0x04290/4,	/* 10gb-x pcs status */
	Serdesc		= 0x04298/4,	/* serdes control */
	Macs		= 0x0429c/4,	/* fifo control & report */
	Autoc		= 0x042a0/4,	/* autodetect control & status */
	Links		= 0x042a4/4,	/* link status */
	Autoc2		= 0x042a8/4,

	/* 82599 */
	Eimsex		= 0x00aa0/4,	/* vectors 0-31, 32-63 */
	Eimcex		= 0x00ab0/4,
	Eiamex		= 0x00ad0/4,
	Ivarmisc	= 0x00a00/4,	/* the other causes' vector */
	Gcrext		= 0x11050/4,
	Mtqc		= 0x08120/4,
	Rttdcs		= 0x04900/4,
	Vtctl		= 0x051b0/4,
	Vfre		= 0x051e0/4,	/* pools 0-31, 32-63 */
	Vfte		= 0x08110/4,
	Vmolr		= 0x0f000/4,	/* per pool */
	Pfdtxgswc	= 0x08220/4,
	Pfvfspoof	= 0x08200/4,
	Ral599		= 0x0a200/4,	/* receive addresses 0-127, 8 bytes each */
	Mpsar		= 0x0a600/4,	/* their pools: lo, hi */
	Pfmailbox	= 0x04b00/4,	/* the PF's side of VF n's mailbox, +n */
	Pfmbmem		= 0x13000/4,	/* VF n's buffer, +16n */
	Pfmbicr		= 0x00710/4,	/* VF requests (bit n) and acks (16+n), VFs 0-15, w1c */
	Vflre		= 0x00600/4,	/* VF level resets, VFs 0-31 */
	Vflrec		= 0x00700/4,	/* their clear */
};

enum {
	/* Ctrl */
	Rst		= 1<<26,	/* full nic reset */

	/* Txdctl */
	Ten		= 1<<25,

	/* Fctrl */
	Bam		= 1<<10,	/* broadcast accept mode */
	Upe 		= 1<<9,		/* unicast promiscuous */
	Mpe 		= 1<<8,		/* multicast promiscuous */

	/* Rxdctl */
	Pthresh		= 0,		/* prefresh threshold shift in bits */
	Hthresh		= 8,		/* host buffer minimum threshold " */
	Wthresh		= 16,		/* writeback threshold */
	Renable		= 1<<25,

	/* Dmatxctl */
	Txen		= 1<<0,

	/* Rxctl */
	Rxen		= 1<<0,
	Dmbyps		= 1<<1,

	/* Rdrxctl */
	Rdmt½		= 0,
	Rdmt¼		= 1,
	Rdmt⅛		= 2,

	/* Rxcsum */
	Ippcse		= 1<<12,	/* ip payload checksum enable */

	/* Eerd */
	EEstart		= 1<<0,		/* Start Read */
	EEdone		= 1<<1,		/* Read done */

	/* interrupts */
	Irx0		= 1<<0,		/* driver defined */
	Itx0		= 1<<1,		/* driver defined */
	Lsc		= 1<<20,	/* link status change */

	/* Links */
	Lnkup	= 1<<30,
	Lnkspd	= 1<<29,
	Lnkspd599	= 3<<28,	/* 82599: 1 100, 2 1000, 3 10000 */

	/* Hlreg0 */
	Jumboen	= 1<<2,

	/* 82599 */
	Crcstrip	= 1<<1,		/* Rdrxctl: as Hlreg0's RXCRCSTRP */
	Mailbox		= 1<<19,	/* interrupt: a VF's mailbox or reset */
	Msixmode	= 1<<4,		/* Gpie */
	Eiame		= 1<<30,
	Pbasupport	= 1<<31,
	Gpievt64	= 3<<14,
	Gcrmsixen	= 1<<31,	/* Gcrext */
	Gcrvt64		= 3,
	Vmdqen		= 8,		/* Mrqc: 64 pools */
	Mtqcvt64	= 1<<1 | 2<<2,	/* Mtqc: VT, 64 pools */
	Arbdis		= 1<<6,		/* Rttdcs */
	Vten		= 1<<0,		/* Vtctl */
	Replen		= 1<<30,
	Vtlben		= 1<<0,		/* Pfdtxgswc */
	Aupe		= 1<<24,	/* Vmolr */
	Rompe		= 1<<25,
	Vbam		= 1<<27,
	Pfrstd		= 1<<14,	/* Ctrlext: the PF is up, the VFs may run */
	Ivarvalid	= 0x80,

	/* the PF's side of a VF mailbox */
	Mbsts		= 0x01,
	Mback		= 0x02,
	Mbvfu		= 0x04,
	Mbpfu		= 0x08,
};

/* the mailbox protocol of Linux's ixgbevf (its mbx.h) */
enum {
	Vfmsgreset	= 0x01,
	Vfmsgsetmac	= 0x02,
	Vfmsgsetmc	= 0x03,
	Vfmsgsetvlan	= 0x04,
	Vfmsgsetlpe	= 0x05,
	Vfmsgapi	= 0x08,
	Vfmsggetq	= 0x09,
	Vtsuccess	= 1<<31,
	Vtfailure	= 1<<30,
	Vtcts		= 1<<29,
	Api10		= 0,
	Api11		= 2,

	Maxvf		= 15,		/* VFs 0-15 have one Pfmbicr; the PF takes pool n */
	Qpp		= 2,		/* queues per pool, with 64 pools */
};

typedef struct {
	uint	reg;
	char	*name;
} Stat;

Stat stattab[] = {
	0x4000,	"crc error",
	0x4004,	"illegal byte",
	0x4008,	"short packet",
	0x3fa0,	"missed pkt0",
	0x4034,	"mac local flt",
	0x4038,	"mac rmt flt",
	0x4040,	"rx length err",
	0x3f60,	"xon tx",
	0xcf60,	"xon rx",
	0x3f68,	"xoff tx",
	0xcf68,	"xoff rx",
	0x405c,	"rx 040",
	0x4060,	"rx 07f",
	0x4064,	"rx 100",
	0x4068,	"rx 200",
	0x406c,	"rx 3ff",
	0x4070,	"rx big",
	0x4074,	"rx ok",
	0x4078,	"rx bcast",
	0x3fc0,	"rx no buf0",
	0x40a4,	"rx runt",
	0x40a8,	"rx frag",
	0x40ac,	"rx ovrsz",
	0x40b0,	"rx jab",
	0x40d0,	"rx pkt",

	0x40d4,	"tx pkt",
	0x40d8,	"tx 040",
	0x40dc,	"tx 07f",
	0x40e0,	"tx 100",
	0x40e4,	"tx 200",
	0x40e8,	"tx 3ff",
	0x40ec,	"tx big",
	0x40f4,	"tx bcast",
	0x4120,	"xsum err",
};

/* errors */
enum {
	Ipe	= 1<<6,	/* ip checksum error (82599) */
	L4e	= 1<<5,	/* tcp/udp checksum error (82599) */
};

/* status */
enum {
	Pif	= 1<<7,	/* past exact filter (sic) */
	Ipcs	= 1<<6,	/* ip checksum calcuated */
	L4cs	= 1<<5,	/* layer 2 */
	Tcpcs	= 1<<4,	/* tcp checksum calcuated */
	Vp	= 1<<3,	/* 802.1q packet matched vet */
	Ixsm	= 1<<2,	/* ignore checksum */
	Reop	= 1<<1,	/* end of packet */
	Rdd	= 1<<0,	/* descriptor done */
};

typedef struct {
	u32int	addr[2];
	ushort	length;
	ushort	cksum;
	uchar	status;
	uchar	errors;
	ushort	vlan;
} Rd;

enum {
	/* Td cmd */
	Rs	= 1<<3,
	Ic	= 1<<2,
	Ifcs	= 1<<1,
	Teop	= 1<<0,

	/* Td status */
	Tdd	= 1<<0,
};

typedef struct {
	u32int	addr[2];
	ushort	length;
	uchar	cso;
	uchar	cmd;
	uchar	status;
	uchar	css;
	ushort	vlan;
} Td;

enum {
	Factive		= 1<<0,
	Fstarted	= 1<<1,
};

enum {
	i82598,
	i82599,
};

typedef struct {
	Pcidev	*p;
	Ether	*edev;
	int	type;
	uvlong	io;
	u32int	*reg;
	u32int	*regmsi;
	uchar	flag;
	int	nrd;
	int	ntd;
	int	rbsz;
	Lock	slock;
	Lock	alock;
	QLock	tlock;
	Rendez	lrendez;
	Rendez	trendez;
	Rendez	rrendez;
	uint	im;
	uint	lim;
	uint	rim;
	uint	tim;
	Lock	imlock;
	char	*alloc;

	Rd	*rdba;
	Block	**rb;
	uint	rdt;
	uint	rdfree;

	Td	*tdba;
	uint	tdh;
	uint	tdt;
	Block	**tb;

	uchar	ra[Eaddrlen];
	u32int	mta[128];
	ulong	stats[nelem(stattab)];
	uint	speeds[3];

	/* SR-IOV PF (82599, *ixgbevfs=n): the PF in pool n, on queue q */
	int	nvf;
	int	q;
	uchar	vfmac[Maxvf][Eaddrlen];
	int	vfapi[Maxvf];
	uint	nmbox;
	uint	nvfreset;
	uint	nvflr;
	uint	nmsix;
} Ctlr;

/* queue q's registers: the 0x40-byte blocks, 0x10 words apart */
#define Q(c, r)	((r) + 0x10*(c)->q)

static int
srrctl(Ctlr *c)
{
	if(c->type == i82599)
		return (0x01014 + 0x40*c->q)/4;
	return Srrctl + c->q;
}

/* tweakable paramaters */
enum {
	Mtu	= 12*1024,
	Nrd	= 256,
	Ntd	= 256,
	Nrb	= 256,
};

static	Ctlr	*ctlrtab[4];
static	int	nctlr;

static void
readstats(Ctlr *c)
{
	int i;

	lock(&c->slock);
	for(i = 0; i < nelem(c->stats); i++)
		c->stats[i] += c->reg[stattab[i].reg >> 2];
	unlock(&c->slock);
}

static int speedtab[] = {
	0,
	1000,
	10000,
};

static char*
ifstat(void *a, char *p, char *q)
{
	uint i, *t;
	Ether *e;
	Ctlr *c;

	if(p >= q)
		return p;

	e = a;
	c = e->ctlr;
	readstats(c);
	for(i = 0; i < nelem(stattab); i++)
		if(c->stats[i] > 0)
			p = seprint(p, q, "%.10s  %uld\n", stattab[i].name, c->stats[i]);
	t = c->speeds;
	p = seprint(p, q, "speeds: 0:%d 1000:%d 10000:%d\n", t[0], t[1], t[2]);
	p = seprint(p, q, "rdfree %d rdh %d rdt %d\n", c->rdfree, c->reg[Q(c, Rdt)],
		c->reg[Q(c, Rdh)]);
	if(c->nvf > 0){
		p = seprint(p, q, "sriov: vfs %d pf pool %d queue %d mbox %ud vfresets %ud vflr %ud msix %ud vfre %.8ux vfte %.8ux\n",
			c->nvf, c->nvf, c->q, c->nmbox, c->nvfreset, c->nvflr, c->nmsix,
			c->reg[Vfre], c->reg[Vfte]);
		for(i = 0; i < c->nvf; i++)
			p = seprint(p, q, "vf%d: %E api %d vmolr %.8ux\n", i, c->vfmac[i],
				c->vfapi[i], c->reg[Vmolr + i]);
	}

	return p;
}

static void
im(Ctlr *c, int i)
{
	ilock(&c->imlock);
	c->im |= i;
	c->reg[Ims] = c->im;
	iunlock(&c->imlock);
}

static int
lim(void *v)
{
	return ((Ctlr*)v)->lim != 0;
}

static void
lproc(void *v)
{
	int r, i;
	Ctlr *c;
	Ether *e;

	e = v;
	c = e->ctlr;
	while(waserror())
		;
	for (;;) {
		r = c->reg[Links];
		if(r & Lnkup && c->type == i82599){
			i = ((r & Lnkspd599) >> 28) - 1;	/* 100 counts as none */
			if(i < 0)
				i = 0;
			ethersetspeed(e, speedtab[i]);
			ethersetlink(e, 1);
		} else if(r & Lnkup){
			i = 1 + ((r & Lnkspd) != 0);
			ethersetspeed(e, speedtab[i]);
			ethersetlink(e, 1);
		} else {
			ethersetlink(e, 0);
			i = 0;
		}
		c->speeds[i]++;
		c->lim = 0;
		im(c, Lsc);
		sleep(&c->lrendez, lim, c);
		c->lim = 0;
	}
}

static long
ctl(Ether *, void *, long)
{
	error(Ebadarg);
	return 0;	/* this 6c wants a return after error() */
}

#define Next(x, m)	(((x)+1) & (m))

static int
cleanup(Ctlr *c, int tdh)
{
	Block *b;
	uint m, n;

	m = c->ntd - 1;
	while(c->tdba[n = Next(tdh, m)].status & Tdd){
		tdh = n;
		b = c->tb[tdh];
		c->tb[tdh] = 0;
		freeb(b);
		c->tdba[tdh].status = 0;
	}
	return tdh;
}

void
transmit(Ether *e)
{
	uint i, m, tdt, tdh;
	Ctlr *c;
	Block *b;
	Td *t;

	c = e->ctlr;
	if(!canqlock(&c->tlock)){
		im(c, Itx0);
		return;
	}
	tdh = c->tdh = cleanup(c, c->tdh);
	tdt = c->tdt;
	m = c->ntd - 1;
	for(i = 0; i < 8; i++){
		if(Next(tdt, m) == tdh){
			im(c, Itx0);
			break;
		}
		if(!(b = qget(e->oq)))
			break;
		t = c->tdba + tdt;
		t->addr[0] = PCIWADDR(b->rp);
		t->length = BLEN(b);
		t->cmd = Rs | Ifcs | Teop;
		c->tb[tdt] = b;
		tdt = Next(tdt, m);
	}
	if(i){
		c->tdt = tdt;
		c->reg[Q(c, Tdt)] = tdt;
	}
	qunlock(&c->tlock);
}

static int
tim(void *c)
{
	return ((Ctlr*)c)->tim != 0;
}

static void
tproc(void *v)
{
	Ctlr *c;
	Ether *e;

	e = v;
	c = e->ctlr;
	while(waserror())
		;
	for (;;) {
		sleep(&c->trendez, tim, c);	/* transmit kicks us */
		c->tim = 0;
		transmit(e);
	}
}

static void
rxinit(Ctlr *c)
{
	int i;
	Block *b;

	c->reg[Rxctl] &= ~Rxen;
	for(i = 0; i < c->nrd; i++){
		b = c->rb[i];
		c->rb[i] = 0;
		if(b)
			freeb(b);
	}
	c->rdfree = 0;

	c->reg[Fctrl] |= Bam;
	c->reg[Rxcsum] |= Ipcs;
	c->reg[srrctl(c)] = c->rbsz / 1024;
	c->reg[Mhadd] = c->rbsz << 16;
	c->reg[Hlreg0] |= Jumboen;

	c->reg[Q(c, Rbal)] = PCIWADDR(c->rdba);
	c->reg[Q(c, Rbah)] = PCIWADDR(c->rdba) >> 32;
	c->reg[Q(c, Rdlen)] = c->nrd*sizeof(Rd);
	c->reg[Q(c, Rdh)] = 0;
	c->reg[Q(c, Rdt)] = c->rdt = 0;

	if(c->type == i82599){
		/* the CRC stripped, as Hlreg0 says; the queue on before its tail moves */
		c->reg[Rdrxctl] |= Crcstrip;
		c->reg[Q(c, Rxdctl)] = 8<<Wthresh | 8<<Pthresh | 4<<Hthresh | Renable;
		for(i = 0; i < 1000 && (c->reg[Q(c, Rxdctl)] & Renable) == 0; i++)
			microdelay(10);
		c->reg[Rxctl] |= Rxen;
		return;
	}
	c->reg[Rdrxctl] = Rdmt¼;
	c->reg[Rxdctl] = 8<<Wthresh | 8<<Pthresh | 4<<Hthresh | Renable;
	c->reg[Rxctl] |= Rxen | Dmbyps;
}

static void
replenish(Ctlr *c, uint rdh)
{
	int rdt, m, i;
	Block *b;
	Rd *r;

	m = c->nrd - 1;
	i = 0;
	for(rdt = c->rdt; Next(rdt, m) != rdh; rdt = Next(rdt, m)){
		b = allocb(c->rbsz+BY2PG);
		b->rp = (uchar*)PGROUND((uintptr)b->base);
		b->wp = b->rp;
		c->rb[rdt] = b;
		r = c->rdba + rdt;
		r->addr[0] = PCIWADDR(b->rp);
		r->status = 0;
		c->rdfree++;
		i++;
	}
	if(i)
		c->reg[Q(c, Rdt)] = c->rdt = rdt;
}

static int
rim(void *v)
{
	return ((Ctlr*)v)->rim != 0;
}

static uchar zeroea[Eaddrlen];

void
rproc(void *v)
{
	uint m, rdh;
	Block *b;
	Ctlr *c;
	Ether *e;
	Rd *r;

	e = v;
	c = e->ctlr;
	m = c->nrd - 1;
	rdh = 0;
	while(waserror())
		;
loop:
	replenish(c, rdh);
	im(c, Irx0);
	sleep(&c->rrendez, rim, c);
loop1:
	c->rim = 0;
	if(c->nrd - c->rdfree >= 16)
		replenish(c, rdh);
	r = c->rdba + rdh;
	if(!(r->status & Rdd))
		goto loop;		/* UGH */
	b = c->rb[rdh];
	c->rb[rdh] = 0;
	b->wp += r->length;
	if(c->type == i82599){
		/* checked, and without error */
		if((r->status & Ipcs) && !(r->errors & Ipe))
			b->flag |= Bipck;
		if((r->status & L4cs) && !(r->errors & L4e))
			b->flag |= Btcpck | Budpck;
	} else if(!(r->status & Ixsm)){
		if(r->status & Ipcs)
			b->flag |= Bipck;
		if(r->status & Tcpcs)
			b->flag |= Btcpck | Budpck;
		b->checksum = r->cksum;
	}
//	r->status = 0;
	etheriq(e, b);
	c->rdfree--;
	rdh = Next(rdh, m);
	goto loop1;			/* UGH */
}

static void
promiscuous(void *a, int on)
{
	Ctlr *c;
	Ether *e;

	e = a;
	c = e->ctlr;
	if(on)
		c->reg[Fctrl] |= Upe | Mpe;
	else
		c->reg[Fctrl] &= ~(Upe | Mpe);
}

static void
multicast(void *a, uchar *ea, int on)
{
	int b, i;
	Ctlr *c;
	Ether *e;

	e = a;
	c = e->ctlr;

	/*
	 * multiple ether addresses can hash to the same filter bit,
	 * so it's never safe to clear a filter bit.
	 * if we want to clear filter bits, we need to keep track of
	 * all the multicast addresses in use, clear all the filter bits,
	 * then set the ones corresponding to in-use addresses.
	 */
	i = ea[5] >> 1;
	b = (ea[5]&1)<<4 | ea[4]>>4;
	b = 1 << b;
	if(on)
		c->mta[i] |= b;
//	else
//		c->mta[i] &= ~b;
	c->reg[Mta+i] = c->mta[i];
}

static int
detach(Ctlr *c)
{
	int i;

	c->reg[Imc] = ~0;
	c->reg[Ctrl] |= Rst;
	for(i = 0; i < 100; i++){
		delay(1);
		if((c->reg[Ctrl] & Rst) == 0)
			break;
	}
	if (i >= 100)
		return -1;
	/* errata */
	delay(50);
	if(c->type == i82598)
		c->reg[Ecc] &= ~(1<<21 | 1<<18 | 1<<9 | 1<<6);

	/* not cleared by reset; kill it manually. */
	for(i = 1; i < 16; i++)
		c->reg[Rah] &= ~(1 << 31);
	for(i = 0; i < 128; i++)
		c->reg[Mta + i] = 0;
	for(i = 1; i < 640; i++)
		c->reg[Vfta + i] = 0;
	return 0;
}

static void
shutdown(Ether *e)
{
	detach(e->ctlr);
}

/* ≤ 20ms */
static ushort
eeread(Ctlr *c, int i)
{
	c->reg[Eerd] = EEstart | i<<2;
	while((c->reg[Eerd] & EEdone) == 0)
		;
	return c->reg[Eerd] >> 16;
}

static int
eeload(Ctlr *c)
{
	ushort u, v, p, l, i, j;

	if((eeread(c, 0) & 0xc0) != 0x40)
		return -1;
	u = 0;
	for(i = 0; i < 0x40; i++)
		u +=  eeread(c, i);
	for(i = 3; i < 0xf; i++){
		p = eeread(c, i);
		l = eeread(c, p++);
		if((int)p + l + 1 > 0xffff)
			continue;
		for(j = p; j < p + l; j++)
			u += eeread(c, j);
	}
	if(u != 0xbaba)
		return -1;
	if(c->reg[Status] & (1<<3))
		u = eeread(c, 10);
	else
		u = eeread(c, 9);
	u++;
	for(i = 0; i < Eaddrlen;){
		v = eeread(c, u + i/2);
		c->ra[i++] = v;
		c->ra[i++] = v>>8;
	}
	c->ra[5] += (c->reg[Status] & 0xc) >> 2;
	return 0;
}

static int
reset(Ctlr *c)
{
	int i;

	if(detach(c)){
		print("82598: reset timeout\n");
		return -1;
	}
	if(eeload(c)){
		print("82598: eeprom failure\n");
		memset(c->ra, 0, Eaddrlen);
	}

	readstats(c);
	for(i = 0; i<nelem(c->stats); i++)
		c->stats[i] = 0;

	c->reg[Ctrlext] |= 1 << 16;
	/* make some guesses for flow control */
	c->reg[Fcrtl] = 0x10000 | 1<<31;
	c->reg[Fcrth] = 0x40000 | 1<<31;
	c->reg[Rcrtv] = 0x6000;

	/*
	 * configure interrupt mapping: queue 0's receive to cause Irx0,
	 * its transmit to Itx0.  The 82598's entries are by cause, the
	 * receive queues' then the transmit queues' from 64; the 82599's
	 * are by queue pair, receive and transmit of each in turn.
	 */
	if(c->type == i82599)
		c->reg[Ivar+0] = (0 | Ivarvalid) | (1 | Ivarvalid)<<8;
	else{
		c->reg[Ivar+0] =     0 | 1<<7;
		c->reg[Ivar+64/4] =  1 | 1<<7;
	}
//	c->reg[Ivar+97/4] = (2 | 1<<7) << (8*(97%4));

	/* interrupt throttling goes here. */
	for(i = Itr; i < Itr + 20; i++)
		c->reg[i] = 128;		/* ¼µs intervals */
	c->reg[Itr + Itx0] = 256;
	return 0;
}

static void
txinit(Ctlr *c)
{
	Block *b;
	int i;

	c->reg[Q(c, Txdctl)] = 16<<Wthresh | 16<<Pthresh;
	for(i = 0; i < c->ntd; i++){
		b = c->tb[i];
		c->tb[i] = 0;
		if(b)
			freeb(b);
	}
	memset(c->tdba, 0, c->ntd * sizeof(Td));
	c->reg[Q(c, Tdbal)] = PCIWADDR(c->tdba);
	c->reg[Q(c, Tdbah)] = PCIWADDR(c->tdba) >> 32;
	c->reg[Q(c, Tdlen)] = c->ntd*sizeof(Td);
	c->reg[Q(c, Tdh)] = 0;
	c->reg[Q(c, Tdt)] = 0;
	c->tdh = c->ntd - 1;
	c->tdt = 0;
	if(c->type == i82599){
		/* the 82599 wants transmit on before the queue */
		c->reg[Dmatxctl] |= Txen;
		c->reg[Q(c, Txdctl)] |= Ten;
		return;
	}
	c->reg[Txdctl] |= Ten;

	c->reg[Dmatxctl] |= Txen;
}

/*
 * SR-IOV PF (82599).  With *ixgbevfs=n in plan9.ini the PF makes n VFs
 * when it is attached and runs the switch for them, as Linux's ixgbe
 * does: the 82599 is put in 64 pools of two queue pairs (GCR_EXT,
 * MRQC, MTQC), pools 0 to n-1 are the VFs', the PF takes pool n
 * (VT_CTL's default pool) and its first queue, 2n.  Received frames go
 * to pools by destination address -- the PF's in receive address 0,
 * VF v's in 1+v, each with its pool in MPSAR -- broadcasts to every
 * pool, and the transmit switch loops frames between pools as well as
 * to the wire.  The VFs' interrupts work only in MSI-X mode (GPIE), so
 * the PF runs on one MSI-X vector too, for its queue and its other
 * causes alike, and serves the VF mailbox from it: a VF's ixgbevf asks
 * to be reset and is given its address, negotiates the mailbox API
 * (1.0 or 1.1 here), asks for its queues, sets its multicast filter
 * and frame size.  A VF's function-level reset (VFLRE) leaves its
 * queues and VFRE/VFTE bits cleared by the device; it is set up again
 * by its next reset message.  VLAN filtering, anti-spoofing, RSS and
 * rate limits are not done.
 */
static void
vfaddr(Ctlr *c, int v, uchar *ea)
{
	int i;

	i = 1 + v;
	c->reg[Ral599 + 2*i] = ea[3]<<24 | ea[2]<<16 | ea[1]<<8 | ea[0];
	c->reg[Ral599 + 2*i + 1] = 1<<31 | ea[5]<<8 | ea[4];
	c->reg[Mpsar + 2*i] = 1<<v;
	c->reg[Mpsar + 2*i + 1] = 0;
}

static void
vfmsg(Ctlr *c, int v)
{
	u32int m[16], r[5];
	int i, mb, nr, n;
	uint h;

	mb = Pfmailbox + v;
	c->reg[mb] = Mbpfu;
	if((c->reg[mb] & Mbpfu) == 0)
		return;			/* the VF holds it; it will ask again */
	for(i = 0; i < 16; i++)
		m[i] = c->reg[Pfmbmem + 16*v + i];
	c->reg[mb] = Mback | Mbpfu;
	c->nmbox++;

	nr = 1;
	r[0] = (m[0] & ~(Vtsuccess|Vtfailure|Vtcts)) | Vtsuccess | Vtcts;	/* the request, answered */
	switch(m[0] & 0xFFFF){
	case Vfmsgreset:
		c->nvfreset++;
		c->vfapi[v] = Api10;
		vfaddr(c, v, c->vfmac[v]);
		c->reg[Vmolr + v] = Aupe | Vbam | Rompe;
		c->reg[Vfre] |= 1<<v;
		c->reg[Vfte] |= 1<<v;
		r[0] = Vfmsgreset | Vtsuccess;		/* exactly: no CTS */
		r[1] = c->vfmac[v][3]<<24 | c->vfmac[v][2]<<16 | c->vfmac[v][1]<<8 | c->vfmac[v][0];
		r[2] = c->vfmac[v][5]<<8 | c->vfmac[v][4];
		r[3] = c->reg[Msctctrl] & 3;		/* the multicast filter type */
		nr = 4;
		break;
	case Vfmsgsetmac:
		for(i = 0; i < 4; i++)
			c->vfmac[v][i] = m[1] >> 8*i;
		c->vfmac[v][4] = m[2];
		c->vfmac[v][5] = m[2] >> 8;
		vfaddr(c, v, c->vfmac[v]);
		break;
	case Vfmsgsetmc:
		n = (m[0] >> 16) & 0xFF;
		if(n > 30)
			n = 30;
		for(i = 0; i < n; i++){
			h = (m[1 + i/2] >> 16*(i&1)) & 0xFFF;
			c->mta[h>>5] |= 1<<(h&31);
			c->reg[Mta + (h>>5)] = c->mta[h>>5];
		}
		c->reg[Vmolr + v] |= Rompe;
		break;
	case Vfmsgsetvlan:
		break;			/* no VLAN filtering: everything is accepted */
	case Vfmsgsetlpe:
		if(m[1] > (c->reg[Mhadd] >> 16) && m[1] <= Mtu)
			c->reg[Mhadd] = m[1] << 16;
		break;
	case Vfmsgapi:
		if(m[1] == Api10 || m[1] == Api11)
			c->vfapi[v] = m[1];
		else
			r[0] = (m[0] & ~(Vtsuccess|Vtfailure|Vtcts)) | Vtfailure | Vtcts;
		break;
	case Vfmsggetq:
		if(c->vfapi[v] != Api11){
			r[0] = (m[0] & ~(Vtsuccess|Vtfailure|Vtcts)) | Vtfailure | Vtcts;
			break;
		}
		r[1] = Qpp;		/* transmit queues */
		r[2] = Qpp;		/* receive queues */
		r[3] = 0;		/* no VLAN of the PF's to strip */
		r[4] = 0;		/* the default queue */
		nr = 5;
		break;
	default:
		r[0] = (m[0] & ~(Vtsuccess|Vtfailure|Vtcts)) | Vtfailure | Vtcts;
		break;
	}
	c->reg[mb] = Mbpfu;
	for(i = 0; i < nr; i++)
		c->reg[Pfmbmem + 16*v + i] = r[i];
	c->reg[mb] = Mbsts;		/* tell the VF; lets the buffer go */
}

static void
vfmbox(Ctlr *c)
{
	u32int icr, lr;
	int v;

	for(;;){
		lr = c->reg[Vflre];
		if(lr != 0){
			c->reg[Vflrec] = lr;
			c->nvflr++;
		}
		icr = c->reg[Pfmbicr];
		if(icr == 0)
			break;
		c->reg[Pfmbicr] = icr;
		for(v = 0; v < c->nvf; v++)
			if(icr & 1<<v)
				vfmsg(c, v);
	}
}

/* the one MSI-X vector: the PF's queue and its other causes */
static void
i82599interrupt(Ureg*, void *v)
{
	Ctlr *c;
	Ether *e;
	u32int icr;

	e = v;
	c = e->ctlr;
	c->nmsix++;
	icr = c->reg[Ics] & ~0xFFFF;	/* the other causes; the queue's clears itself (EIAC) */
	c->reg[Icr] = icr;
	vfmbox(c);
	ilock(&c->imlock);
	if(icr & Lsc){
		c->lim = Lsc;
		wakeup(&c->lrendez);
	}
	c->rim = Irx0;
	c->tim = Itx0;
	iunlock(&c->imlock);
	wakeup(&c->rrendez);
	wakeup(&c->trendez);
	c->reg[Ims] = 1;		/* auto-masked on the interrupt */
}

static void
i82599sriov(Ether *e, int n)
{
	Ctlr *c;
	char *err;
	int v, q;

	c = e->ctlr;
	if(n > Maxvf)
		n = Maxvf;
	if(pcimsixintrenable == nil){
		print("#l%d: i82599: no MSI-X here; no VFs\n", e->ctlrno);
		return;
	}
	if((err = pcisriovenable(c->p, n)) != nil){
		print("#l%d: i82599: VFs: %s\n", e->ctlrno, err);
		return;
	}
	c->nvf = n;
	c->q = q = Qpp*n;
	for(v = 0; v < n; v++){
		memmove(c->vfmac[v], "\x52\x54\x00\x82\x00\x00", Eaddrlen);
		c->vfmac[v][4] = e->ctlrno;
		c->vfmac[v][5] = 0x10 + v;
	}

	/* interrupts: MSI-X mode (the VFs' need it), vector 0 for the PF */
	c->reg[Imc] = ~0;
	c->reg[Eimcex] = ~0;
	c->reg[Eimcex+1] = ~0;
	c->reg[Gpie] = Pbasupport | Eiame | Gpievt64 | Msixmode;
	c->reg[Ivar] = 0;			/* queue 0's mapping, for the PF's own */
	c->reg[Ivar + q/2] = (0 | Ivarvalid) | (0 | Ivarvalid)<<8;
	c->reg[Ivarmisc] = (0 | Ivarvalid)<<8;	/* the other causes */
	c->reg[Iac] = 1;
	c->reg[Eiamex] = 1;
	pcimsixintrenable(c->p, 0, i82599interrupt, e, e->name);

	/* the switch: 64 pools, default pool n, loopback between them */
	c->reg[Gcrext] = Gcrmsixen | Gcrvt64;
	c->reg[Mrqc] = Vmdqen;
	c->reg[Rttdcs] |= Arbdis;
	c->reg[Mtqc] = Mtqcvt64;
	c->reg[Rttdcs] &= ~Arbdis;
	c->reg[Vtctl] = Vten | Replen | n<<7;
	c->reg[Pfdtxgswc] = Vtlben;
	c->reg[Mpsar] = 1<<n;			/* the PF's address: its pool */
	c->reg[Mpsar + 1] = 0;
	for(v = 0; v <= n; v++)
		c->reg[Vmolr + v] = Aupe | Vbam | Rompe;
	for(v = 0; v < 8; v++)
		c->reg[Pfvfspoof + v] = 0;
	c->reg[Vfre] = 1<<n;
	c->reg[Vfre + 1] = 0;
	c->reg[Vfte] = 1<<n;
	c->reg[Vfte + 1] = 0;
	c->reg[Vflrec] = ~0;
	c->reg[Pfmbicr] = ~0;
	print("#l%d: i82599: %d VFs, the PF in pool %d queue %d\n", e->ctlrno, n, n, q);
}

/* after the PF's queues are up: the VFs may reset and run */
static void
i82599pfready(Ctlr *c)
{
	if(c->nvf == 0)
		return;
	im(c, Mailbox | Lsc);
	c->reg[Ctrlext] |= Pfrstd;
}

static void
attach(Ether *e)
{
	Ctlr *c;
	int t;
	char buf[KNAMELEN], *s;

	c = e->ctlr;
	c->edev = e;			/* point back to Ether* */
	lock(&c->alock);
	if(c->alloc){
		unlock(&c->alock);
		return;
	}

	c->nrd = Nrd;
	c->ntd = Ntd;
	t  = c->nrd * sizeof *c->rdba + 255;
	t += c->ntd * sizeof *c->tdba + 255;
	t += (c->ntd + c->nrd) * sizeof(Block*);
	c->alloc = malloc(t);
	unlock(&c->alock);
	if(c->alloc == nil)
		error(Enomem);

	c->rdba = (Rd*)ROUNDUP((uintptr)c->alloc, 256);
	c->tdba = (Td*)ROUNDUP((uintptr)(c->rdba + c->nrd), 256);
	c->rb = (Block**)(c->tdba + c->ntd);
	c->tb = (Block**)(c->rb + c->nrd);

	if(c->type == i82599 && (s = getconf("*ixgbevfs")) != nil && atoi(s) > 0)
		i82599sriov(e, atoi(s));
	rxinit(c);
	txinit(c);
	i82599pfready(c);

	snprint(buf, sizeof buf, "#l%dl", e->ctlrno);
	kproc(buf, lproc, e, 0);
	snprint(buf, sizeof buf, "#l%dr", e->ctlrno);
	kproc(buf, rproc, e, 0);
	snprint(buf, sizeof buf, "#l%dt", e->ctlrno);
	kproc(buf, tproc, e, 0);
}

static void
interrupt(Ureg*, void *v)
{
	int icr, im;
	Ctlr *c;
	Ether *e;

	e = v;
	c = e->ctlr;
	ilock(&c->imlock);
	c->reg[Imc] = ~0;
	im = c->im;
	while((icr = c->reg[Icr] & c->im) != 0){
		if(icr & Lsc){
			im &= ~Lsc;
			c->lim = icr & Lsc;
			wakeup(&c->lrendez);
		}
		if(icr & Irx0){
			im &= ~Irx0;
			c->rim = icr & Irx0;
			wakeup(&c->rrendez);
		}
		if(icr & Itx0){
			im &= ~Itx0;
			c->tim = icr & Itx0;
			wakeup(&c->trendez);
		}
	}
	c->reg[Ims] = c->im = im;
	iunlock(&c->imlock);
}

static void
scan(void)
{
	uvlong io, iomsi;
	void *mem, *memmsi;
	int pciregs, pcimsix, type;
	Ctlr *c;
	Pcidev *p;

	p = 0;
	while(p = pcimatch(p, 0x8086, 0)){
		pciregs = 0;
		type = i82598;
		switch(p->did){
		case 0x10c6:		/* 82598 af dual port */
		case 0x10c7:		/* 82598 af single port */
		case 0x10b6:		/* 82598 backplane */
		case 0x10dd:		/* 82598 at cx4 */
		case 0x10ec:		/* 82598 at cx4 dual port */
			pcimsix = 3;
			break;
		case 0x10fb:		/* 82599 */
		case 0x1557:
		case 0x1528:		/* T540-T1 */
			pcimsix = 4;
			type = i82599;
			break;
		default:
			continue;
		}
		if((p->mem[pciregs].bar & 1) != 0
		|| (p->mem[pcimsix].bar & 1) != 0)
			continue;
		if(nctlr == nelem(ctlrtab)){
			print("i82598: too many controllers\n");
			return;
		}
		c = malloc(sizeof *c);
		if(c == nil){
			print("i82598: can't allocate memory\n");
			continue;
		}
		io = p->mem[pciregs].bar & ~0xf;
		mem = vmap(io, p->mem[pciregs].size);
		if(mem == nil){
			print("i82598: can't map regs %llux\n", io);
			free(c);
			continue;
		}
		iomsi = p->mem[pcimsix].bar & ~0xf;
		memmsi = vmap(iomsi, p->mem[pcimsix].size);
		if(memmsi == nil){
			print("i82598: can't map msi-x regs %llux\n", iomsi);
			vunmap(mem, p->mem[pciregs].size);
			free(c);
			continue;
		}
		pcienable(p);
		c->p = p;
		c->type = type;
		c->io = io;
		c->reg = (u32int*)mem;
		c->regmsi = (u32int*)memmsi;
		c->rbsz = ROUND(Mtu, 1024);
		if(reset(c)){
			print("i82598: can't reset\n");
			free(c);
			vunmap(mem, p->mem[pciregs].size);
			vunmap(memmsi, p->mem[pcimsix].size);
			continue;
		}
		pcisetbme(p);
		ctlrtab[nctlr++] = c;
	}
}

static int
pnp(Ether *e)
{
	static uchar zeros[Eaddrlen];
	int i;
	Ctlr *c = nil;
	uchar *p;

	if(nctlr == 0)
		scan();
	for(i = 0; i < nctlr; i++){
		c = ctlrtab[i];
		if(c == nil || c->flag & Factive)
			continue;
		if(e->port == 0 || e->port == c->io)
			break;
	}
	if (i >= nctlr)
		return -1;

	if(memcmp(c->ra, zeros, Eaddrlen) != 0)
		memmove(e->ea, c->ra, Eaddrlen);

	p = e->ea;
	c->reg[Ral] = p[3]<<24 | p[2]<<16 | p[1]<<8 | p[0];
	c->reg[Rah] = p[5]<<8 | p[4] | 1<<31;

	c->flag |= Factive;
	e->ctlr = c;
	e->port = (uintptr)c->reg;
	e->irq = c->p->intl;
	e->tbdf = c->p->tbdf;
	e->mbps = 10000;
	e->maxmtu = Mtu;

	e->arg = e;
	e->attach = attach;
	e->ctl = ctl;
	e->ifstat = ifstatinf;
	e->multicast = multicast;
	e->promiscuous = promiscuous;
	e->shutdown = shutdown;
	e->transmit = transmit;

	intrenable(e->irq, interrupt, e, e->tbdf, e->name);

	return 0;
}

void
ether82598link(void)
{
	addethercard("i82598", pnp);
}

/*
 * 9front-shaped ifstat above, adapted to this kernel's Ether.ifstat
 * through ether9ifstat() in ../port/devether.c.
 */
static long
ifstatinf(Ether *edev, void *a, long n, ulong offset)
{
	return ether9ifstat(edev, a, n, offset, ifstat);
}
