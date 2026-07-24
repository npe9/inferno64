/*
 * Cadence GEM / SiFive FU540 ethernet (sifive,fu540-c000-gem).
 * QEMU -M sifive_u @ GEM0; descriptor layout matches os/boot/zynq/net.c.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "../port/netif.h"
#include "../port/etherif.h"

#ifndef GEM0
#define GEM0	0
#endif

enum {
	Nrdre	= 64,
	Ntdre	= 16,
	Rbsize	= ROUND(ETHERMAXTU+4, 64),
};

/* register offsets in u32 units */
enum {
	NetCtrl		= 0x00/4,
	NetCfg		= 0x04/4,
	NetStatus	= 0x08/4,
	DmaCfg		= 0x10/4,
	TxStatus	= 0x14/4,
	RxQbar		= 0x18/4,
	TxQbar		= 0x1c/4,
	RxStatus	= 0x20/4,
	IntrStatus	= 0x24/4,
	IntrEn		= 0x28/4,
	IntrDis		= 0x2c/4,
	IntrMask	= 0x30/4,
	PhyMaint	= 0x34/4,
	HashBot		= 0x80/4,
	HashTop		= 0x84/4,
	SpecAddr1Bot	= 0x88/4,
	SpecAddr1Top	= 0x8c/4,
};

enum {
	/* NetCtrl */
	RxEn		= 1<<2,
	TxEn		= 1<<3,
	MdEn		= 1<<4,
	StartTx		= 1<<9,
	/* NetCfg */
	Speed100	= 1<<0,
	FdEn		= 1<<1,
	Rx1536En	= 1<<8,
	GigeEn		= 1<<10,
	MdcDiv48	= 3<<18,	/* ok for QEMU */
	RxChksumEn	= 1<<24,
	/* NetStatus */
	PhyIdle		= 1<<2,
	/* DmaCfg */
	TxChksumEn	= 1<<11,
	/* TxStatus */
	TxCompl		= 1<<5,
	/* Intr */
	IrqRxDone	= 1<<1,
	IrqTxDone	= 1<<7,
	IrqRxUsed	= 1<<2,
	/* TX desc word1 */
	TxUsed		= 1<<31,
	TxWrap		= 1<<30,
	TxLast		= 1<<15,
	/* RX desc word0 */
	RxUsed		= 1<<0,
	RxWrap		= 1<<1,
};

typedef struct Ctlr Ctlr;
struct Ctlr {
	Lock;
	u32	*r;
	int	active;
	int	attached;

	u32	*tdr;
	u32	*rdr;
	Block	**rb;
	int	tdh, tdt;
	int	rdh;

	Rendez	rr;
	int	rxrdy;
};

static Ctlr gemctlr;

static u32*
reg(Ctlr *c)
{
	return c->r;
}

static int
rxready(void *a)
{
	return ((Ctlr*)a)->rxrdy != 0;
}

static void
interrupt(Ureg*, void *arg)
{
	Ether *edev;
	Ctlr *c;
	u32 st;

	edev = arg;
	c = edev->ctlr;
	st = reg(c)[IntrStatus];
	reg(c)[IntrStatus] = st;	/* W1C */
	if(st & (IrqRxDone|IrqRxUsed)){
		c->rxrdy = 1;
		wakeup(&c->rr);
	}
	USED(TxCompl);
}

static void
txdone(Ctlr *c)
{
	u32 *d;
	int i;

	for(i = 0; i < Ntdre; i++){
		d = c->tdr + 2*((c->tdh + i) % Ntdre);
		if((d[1] & TxUsed) == 0)
			break;
	}
	/* reclaim is implicit: we wait for Used before reuse in transmit */
	USED(i);
}

static void
transmit(Ether *edev)
{
	Ctlr *c;
	Block *b;
	u32 *d, pa;
	int len, n, i;

	c = edev->ctlr;
	ilock(c);
	while((b = qget(edev->oq)) != nil){
		len = BLEN(b);
		if(len <= 0 || len > ETHERMAXTU){
			freeb(b);
			continue;
		}
		d = c->tdr + 2*c->tdt;
		for(i = 0; i < 100000 && (d[1] & TxUsed) == 0; i++)
			;
		if((d[1] & TxUsed) == 0){
			freeb(b);
			edev->oerrs++;
			break;
		}
		pa = (u32)PADDR(b->rp);
		coherence();
		d[0] = pa;
		n = TxLast | (len & 0x3FFF);
		if(c->tdt == Ntdre-1)
			n |= TxWrap;
		coherence();
		d[1] = n;			/* clear Used → HW owns */
		c->tdt = (c->tdt + 1) % Ntdre;
		reg(c)[TxStatus] = 0xFF;
		reg(c)[NetCtrl] |= StartTx;
		for(i = 0; i < 100000 && (d[1] & TxUsed) == 0; i++)
			;
		freeb(b);
		if((d[1] & TxUsed) == 0)
			edev->oerrs++;
		else
			edev->outpackets++;
	}
	txdone(c);
	iunlock(c);
}

static void
rxproc(void *v)
{
	Ether *edev;
	Ctlr *c;
	Block *b, *nb;
	u32 *d, sta, pa;
	int len;

	edev = v;
	c = edev->ctlr;

	while(waserror())
		;

	for(;;){
		while(c->rxrdy == 0)
			sleep(&c->rr, rxready, c);
		c->rxrdy = 0;

		for(;;){
			d = c->rdr + 2*c->rdh;
			if((d[0] & RxUsed) == 0)
				break;
			sta = d[1];
			len = sta & 0x1FFF;
			b = c->rb[c->rdh];
			if(b != nil && len >= ETHERMINTU && len <= ETHERMAXTU){
				b->wp = b->rp + len;
				etheriq(edev, b);
				c->rb[c->rdh] = nil;
				b = nil;
				if((nb = iallocb(Rbsize)) != nil){
					c->rb[c->rdh] = nb;
					b = nb;
				}
			}
			if(b != nil){
				pa = (u32)PADDR(b->rp);
				if(c->rdh == Nrdre-1)
					pa |= RxWrap;
				coherence();
				d[1] = 0;
				d[0] = pa;	/* clear Used → HW owns */
			}else{
				/* leave Used so we retry alloc next pass */
				c->rxrdy = 1;
			}
			c->rdh = (c->rdh + 1) % Nrdre;
		}
		reg(c)[RxStatus] = 0xF;
	}
}

static void
attach(Ether *edev)
{
	Ctlr *c;
	char name[KNAMELEN];

	c = edev->ctlr;
	ilock(c);
	if(c->attached){
		iunlock(c);
		return;
	}
	c->attached = 1;
	reg(c)[IntrStatus] = 0xFFFFFFFF;
	reg(c)[IntrEn] = IrqRxDone|IrqRxUsed|IrqTxDone;
	reg(c)[NetCtrl] |= RxEn|TxEn|MdEn;
	iunlock(c);

	snprint(name, sizeof name, "#l%drx", edev->ctlrno);
	kproc(name, rxproc, edev, 0);
}

static void
shutdown(Ether *edev)
{
	Ctlr *c;

	c = edev->ctlr;
	ilock(c);
	reg(c)[NetCtrl] = 0;
	reg(c)[IntrDis] = 0xFFFFFFFF;
	c->attached = 0;
	iunlock(c);
}

static long
ifstat(Ether *edev, void *a, long n, ulong offset)
{
	char buf[128];
	Ctlr *c;

	c = edev->ctlr;
	snprint(buf, sizeof buf, "gem port %#p irq %d tdt %d rdh %d\n",
		c->r, (int)edev->irq, c->tdt, c->rdh);
	return readstr(offset, a, n, buf);
}

static int
geminit(Ctlr *c, uchar ea[Eaddrlen])
{
	u32 *r, *d, pa;
	Block *b;
	int i;

	r = c->r;
	r[NetCtrl] = 0;
	r[RxStatus] = 0xF;
	r[TxStatus] = 0xFF;
	r[IntrDis] = 0xFFFFFFFF;
	r[RxQbar] = 0;
	r[TxQbar] = 0;

	r[NetCfg] = MdcDiv48|FdEn|Speed100|Rx1536En|GigeEn|RxChksumEn;
	r[SpecAddr1Bot] = ea[0] | ea[1]<<8 | ea[2]<<16 | ea[3]<<24;
	r[SpecAddr1Top] = ea[4] | ea[5]<<8;
	r[DmaCfg] = TxChksumEn | (0x18<<16) | (1<<10) | (3<<8) | 0x10;
	r[HashBot] = 0;
	r[HashTop] = 0;

	if(c->tdr == nil){
		c->tdr = mallocalign(Ntdre*2*sizeof(u32), 16, 0, 0);
		c->rdr = mallocalign(Nrdre*2*sizeof(u32), 16, 0, 0);
		c->rb = mallocz(Nrdre*sizeof(Block*), 1);
		if(c->tdr == nil || c->rdr == nil || c->rb == nil)
			return -1;
	}

	for(i = 0; i < Ntdre; i++){
		d = c->tdr + 2*i;
		d[0] = 0;
		d[1] = TxUsed;
		if(i == Ntdre-1)
			d[1] |= TxWrap;
	}
	c->tdh = c->tdt = 0;
	r[TxQbar] = (u32)PADDR(c->tdr);

	for(i = 0; i < Nrdre; i++){
		b = iallocb(Rbsize);
		c->rb[i] = b;
		d = c->rdr + 2*i;
		if(b == nil){
			d[0] = RxUsed;
			d[1] = 0;
			continue;
		}
		pa = (u32)PADDR(b->rp);
		if(i == Nrdre-1)
			pa |= RxWrap;
		d[1] = 0;
		d[0] = pa;	/* HW owns */
	}
	c->rdh = 0;
	r[RxQbar] = (u32)PADDR(c->rdr);

	r[NetCtrl] = MdEn;
	coherence();
	return 0;
}

static int
reset(Ether *edev)
{
	static uchar defea[Eaddrlen] = {0x52, 0x54, 0x00, 0x12, 0x34, 0x56};
	static uchar zeros[Eaddrlen];
	Ctlr *c;

	if(GEM0 == 0)
		return -1;

	c = &gemctlr;
	if(c->active)
		return -1;

	c->r = (u32*)GEM0;
	if(memcmp(edev->ea, zeros, Eaddrlen) == 0)
		memmove(edev->ea, defea, Eaddrlen);

	if(geminit(c, edev->ea) < 0)
		return -1;

	c->active = 1;
	edev->ctlr = c;
	edev->port = (ulong)GEM0;
	edev->irq = Gem0IRQ;
	edev->tbdf = BUSUNKNOWN;
	edev->mbps = 1000;
	edev->link = 1;
	edev->arg = edev;
	edev->attach = attach;
	edev->transmit = transmit;
	edev->shutdown = shutdown;
	edev->ifstat = ifstat;

	intrenable(edev->irq, edev->tbdf, interrupt, edev, edev->name);
	print("ethersifivegem: %#p irq %d ea %E\n", GEM0, Gem0IRQ, edev->ea);
	return 0;
}

void
ethersifivegemlink(void)
{
	addethercard("gem", reset);
}
