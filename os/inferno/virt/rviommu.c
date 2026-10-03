/*
 * The RISC-V IOMMU (the RISC-V IOMMU Architecture Specification 1.0)
 * as a backend of the portable IOMMU layer (port/iommu.h, #Q):
 * doc/genesize-plan.ms, phase 15.  QEMU's riscv-iommu-pci is the one
 * on the bench: a PCI function whose BAR0 holds the registers, and
 * which translates the DMA of the functions on its bus.
 *
 * The device directory is two levels deep, indexed by requester ID;
 * every function on the bus has a device context, and one in the host
 * domain is valid with both stages bare -- its DMA addresses are
 * physical addresses, as before translation was on.  A domain is a
 * second-stage (G-stage) table in Sv39x4, the same format as a
 * guest's (vmrv.c), so a domain can be a guest's physical memory as
 * it is: the GSCID tags its translations.  Commands -- IODIR to drop a
 * cached device context, IOTINVAL.GVMA a domain's translations, and
 * IOFENCE.C to wait for both -- go through the command queue, and
 * faults come back through the fault queue; both are polled, the
 * IOMMU's interrupts unused.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"../port/pci.h"
#include	"../port/iommu.h"

enum {
	/* registers */
	Rcap		= 0x00,
	Rfctl		= 0x08,
	Rddtp		= 0x10,
	Rcqb		= 0x18,
	Rcqh		= 0x20,
	Rcqt		= 0x24,
	Rfqb		= 0x28,
	Rfqh		= 0x30,
	Rfqt		= 0x34,
	Rcqcsr		= 0x48,
	Rfqcsr		= 0x4C,

	/* capabilities */
	CapSv39x4	= 1<<17,
	CapMsiflat	= 1<<22,

	/* ddtp modes */
	DdtOff		= 0,
	DdtBare		= 1,
	Ddt2lvl		= 3,
	Ddtbusy		= 1<<4,

	/* queue csr */
	Qen		= 1<<0,
	Qmf		= 1<<8,
	Qof		= 1<<9,
	Qcmdill		= 1<<10,
	Qon		= 1<<16,
	Qbusy		= 1<<17,

	Ncq		= 256,		/* 16-byte commands: one page */
	Nfq		= 128,		/* 32-byte records: one page */

	/* device context */
	TcV		= 1<<0,
	Gatpsv39x4	= 8,

	/* commands */
	CmdIotinval	= 1,
	CmdIofence	= 2,
	CmdIodir	= 3,
	FuncGvma	= 1,
	FuncInvalddt	= 0,
	CmdGv		= 1ULL<<33,	/* IOTINVAL: GSCID valid */
	CmdDv		= 1ULL<<33,	/* IODIR: DID valid */

	/* G-stage PTEs */
	Pv		= 1<<0,
	Pr		= 1<<1,
	Pw		= 1<<2,
	Pu		= 1<<4,
	Pa		= 1<<6,
	Pd		= 1<<7,

	Rootsize	= 16*1024,	/* Sv39x4's root: 2048 entries */
	Hostgscid	= 0,
};

typedef struct Rvdom Rvdom;
struct Rvdom
{
	uvlong	*root;
	int	gscid;
};

static Pcidev	*iommu;
static uchar	*regs;
static uvlong	cap;
static int	dcsize;		/* 64 with the MSI flat table (extended format), else 32 */
static int	dcshift;	/* requester ID bits a leaf page indexes */
static uvlong	*ddt;		/* the directory's root page */
static uchar	*cq;		/* command queue */
static uchar	*fq;		/* fault queue */
static Lock	cqlk;

#define	R32(r)		(*(u32int*)(regs + (r)))
#define	W32(r, v)	(*(u32int*)(regs + (r)) = (v))
#define	R64(r)		(*(uvlong*)(regs + (r)))
#define	W64(r, v)	(*(uvlong*)(regs + (r)) = (v))

static void*
page(void)
{
	void *p;

	p = mallocalign(BY2PG, BY2PG, 0, 0);
	if(p == nil)
		error(Enomem);
	memset(p, 0, BY2PG);
	return p;
}

static int
waitfor(int r, u32int bit, int want)
{
	int i;

	for(i = 0; i < 100000; i++){
		if(((R32(r) & bit) != 0) == want)
			return 0;
		microdelay(1);
	}
	return -1;
}

/* one command, then a fence, and wait for the IOMMU to have done both */
static void
command(uvlong d0, uvlong d1)
{
	u32int t;
	uvlong *c;
	int i;

	ilock(&cqlk);
	t = R32(Rcqt);
	c = (uvlong*)(cq + 16*t);
	c[0] = d0;
	c[1] = d1;
	t = (t+1) % Ncq;
	c = (uvlong*)(cq + 16*t);
	c[0] = CmdIofence | 0<<7;	/* IOFENCE.C: earlier commands complete */
	c[1] = 0;
	t = (t+1) % Ncq;
	coherence();
	W32(Rcqt, t);
	for(i = 0; i < 1000000 && R32(Rcqh) != t; i++)
		;
	iunlock(&cqlk);
	if(R32(Rcqcsr) & (Qmf|Qcmdill))
		print("rviommu: command queue error, cqcsr %#ux\n", R32(Rcqcsr));
}

/* the device context for requester rid, its leaf page made if need be */
static uvlong*
dcof(int rid)
{
	uvlong *leaf;
	int i;

	i = rid >> dcshift;
	if(i >= 512)
		error("requester ID beyond a two-level directory");
	if((ddt[i] & 1) == 0)
		ddt[i] = (uvlong)PADDR(page())>>PGSHIFT<<10 | 1;
	leaf = KADDR((ddt[i]>>10)<<PGSHIFT);
	return (uvlong*)((uchar*)leaf + dcsize*(rid & ((1<<dcshift)-1)));
}

static int
rid(Pcidev *p)
{
	return BUSBNO(p->tbdf)<<8 | BUSDNO(p->tbdf)<<3 | BUSFNO(p->tbdf);
}

/* a device context: in the host domain (d nil) both stages bare */
static void
setdc(Pcidev *p, Rvdom *d)
{
	uvlong *dc;
	int r;

	r = rid(p);
	dc = dcof(r);
	memset(dc, 0, dcsize);
	if(d != nil)
		dc[1] = (uvlong)Gatpsv39x4<<60 | (uvlong)d->gscid<<44 | (uvlong)PADDR(d->root)>>PGSHIFT;
	coherence();
	dc[0] = TcV;
	coherence();
	command(CmdIodir | FuncInvalddt<<7 | CmdDv | (uvlong)r<<40, 0);
}

static int
rvprobe(char *why, int nwhy)
{
	extern void pciinit(void);

	pciinit();	/* this runs from links(), before pciarchinit() */
	iommu = pcimatch(nil, 0x1B36, 0x0014);
	if(iommu == nil){
		snprint(why, nwhy, "no RISC-V IOMMU on the PCI bus");
		return -1;
	}
	regs = vmap(iommu->mem[0].bar & ~0xFULL, iommu->mem[0].size);
	pcicfgw16(iommu, PciPCR, pcicfgr16(iommu, PciPCR) | 2);	/* memory space */
	cap = R64(Rcap);
	if((cap & CapSv39x4) == 0){
		snprint(why, nwhy, "no Sv39x4 second stage (capabilities %#llux)", cap);
		return -1;
	}
	if(cap & CapMsiflat){
		dcsize = 64;
		dcshift = 6;
	}else{
		dcsize = 32;
		dcshift = 7;
	}
	/* until translation is turned on, every function's DMA passes */
	W64(Rddtp, DdtBare);
	return 0;
}

static int
rvcovers(Pcidev *p)
{
	return iommu != nil && p != iommu && BUSBNO(p->tbdf) == BUSBNO(iommu->tbdf);
}

static int
rvenable(void)
{
	Pcidev *p;

	cq = page();
	fq = page();
	ddt = page();
	W64(Rcqb, (uvlong)PADDR(cq)>>PGSHIFT<<10 | (8-1));	/* 2^8 entries */
	W32(Rcqt, 0);
	W32(Rcqcsr, Qen);
	W64(Rfqb, (uvlong)PADDR(fq)>>PGSHIFT<<10 | (7-1));	/* 2^7 entries */
	W32(Rfqh, 0);
	W32(Rfqcsr, Qen);
	if(waitfor(Rcqcsr, Qon, 1) < 0 || waitfor(Rfqcsr, Qon, 1) < 0){
		print("rviommu: the queues did not come on (cqcsr %#ux fqcsr %#ux)\n", R32(Rcqcsr), R32(Rfqcsr));
		return -1;
	}
	/* every function it covers in the host domain, then the directory on */
	for(p = nil; (p = pcimatch(p, 0, 0)) != nil; )
		if(rvcovers(p))
			setdc(p, nil);
	coherence();
	W64(Rddtp, (uvlong)PADDR(ddt)>>PGSHIFT<<10 | Ddt2lvl);
	if(waitfor(Rddtp, Ddtbusy, 0) < 0 || (R64(Rddtp) & 0xF) != Ddt2lvl){
		print("rviommu: the directory did not take (ddtp %#llux)\n", R64(Rddtp));
		return -1;
	}
	print("rviommu: %T translating, %d-byte device contexts\n", iommu->tbdf, dcsize);
	return 0;
}

static char*
rvinfo(char *p, char *e)
{
	if(iommu == nil)
		return p;
	return seprint(p, e, "riscv-iommu %T capabilities %#llux ddtp %#llux cqcsr %#ux fqcsr %#ux\n",
		iommu->tbdf, cap, R64(Rddtp), R32(Rcqcsr), R32(Rfqcsr));
}

static void
rvdomnew(Iodom *d)
{
	Rvdom *r;

	r = malloc(sizeof *r);
	if(r == nil)
		error(Enomem);
	r->root = mallocalign(Rootsize, Rootsize, 0, 0);
	if(r->root == nil){
		free(r);
		error(Enomem);
	}
	memset(r->root, 0, Rootsize);
	r->gscid = d->id + 1;
	d->arch = r;
}

static void
freetab(uvlong *t, int level)
{
	int i;

	if(level > 0)
		for(i = 0; i < 512; i++)
			if((t[i] & (Pv|Pr|Pw)) == Pv)
				freetab(KADDR((t[i]>>10)<<PGSHIFT), level-1);
	free(t);
}

static void
rvdomfree(Iodom *d)
{
	Rvdom *r;
	int i;

	r = d->arch;
	if(r == nil)
		return;
	command(CmdIotinval | FuncGvma<<7 | CmdGv | (uvlong)r->gscid<<44, 0);
	for(i = 0; i < Rootsize/8; i++)
		if((r->root[i] & (Pv|Pr|Pw)) == Pv)
			freetab(KADDR((r->root[i]>>10)<<PGSHIFT), 1);
	free(r->root);
	free(r);
	d->arch = nil;
}

static void
rvattach(Iodom *d, Pcidev *p)
{
	if(!rvcovers(p))
		error("no IOMMU covers that function");
	setdc(p, d != nil ? d->arch : nil);
}

/* the 4K PTE for iova, tables made on the way */
static uvlong*
gswalk(Rvdom *r, uvlong iova)
{
	uvlong *t, *pte;
	int l;

	t = r->root;
	pte = &t[(iova>>30) & 0x7FF];
	for(l = 2; l > 0; l--){
		if((*pte & Pv) == 0){
			t = page();
			*pte = (uvlong)PADDR(t)>>PGSHIFT<<10 | Pv;
		}else
			t = KADDR((*pte>>10)<<PGSHIFT);
		pte = &t[(iova>>(12+9*(l-1))) & 0x1FF];
	}
	return pte;
}

static void
rvmap(Iodom *d, uvlong iova, uvlong pa, uvlong len, int prot)
{
	Rvdom *r;
	uvlong e, bits;

	r = d->arch;
	if((iova | pa | len) & (BY2PG-1))
		error(Ebadarg);
	if(iova + len > 1ULL<<41)
		error("beyond Sv39x4's 41 bits");
	bits = Pv|Pu|Pa|Pd;
	if(prot & IoR)
		bits |= Pr;
	if(prot & IoW)
		bits |= Pw|Pr;
	for(e = iova + len; iova < e; iova += BY2PG, pa += BY2PG)
		*gswalk(r, iova) = pa>>PGSHIFT<<10 | bits;
	coherence();
	command(CmdIotinval | FuncGvma<<7 | CmdGv | (uvlong)r->gscid<<44, 0);
}

static void
rvunmap(Iodom *d, uvlong iova, uvlong len)
{
	Rvdom *r;
	uvlong e;

	r = d->arch;
	if((iova | len) & (BY2PG-1))
		error(Ebadarg);
	for(e = iova + len; iova < e; iova += BY2PG)
		*gswalk(r, iova) = 0;
	coherence();
	command(CmdIotinval | FuncGvma<<7 | CmdGv | (uvlong)r->gscid<<44, 0);
}

/* the fault queue's records, head to tail */
static int
rvfaults(Iofault *f, int max)
{
	u32int h, t;
	uvlong *rec, hdr;
	int n, cause;

	if(fq == nil)
		return 0;
	n = 0;
	h = R32(Rfqh);
	t = R32(Rfqt);
	while(h != t && n < max){
		rec = (uvlong*)(fq + 32*h);
		hdr = rec[0];
		cause = hdr & 0xFFF;
		f[n].sid = hdr >> 40;
		f[n].reason = cause;
		f[n].write = cause == 7 || cause == 15 || cause == 23;
		f[n].addr = rec[2];
		n++;
		h = (h+1) % Nfq;
	}
	W32(Rfqh, h);
	if(R32(Rfqcsr) & (Qmf|Qof))
		W32(Rfqcsr, Qen | Qmf | Qof);	/* clear them (write 1) */
	return n;
}

static char*
rvreason(int r)
{
	switch(r){
	case 1: return "instruction access fault";
	case 5: return "read access fault";
	case 7: return "write access fault";
	case 12: case 13: case 15: return "first-stage page fault";
	case 20: case 21: case 23: return "second-stage (guest) page fault";
	case 256: return "all inbound transactions disallowed";
	case 257: return "DDT entry load access fault";
	case 258: return "DDT entry not valid";
	case 259: return "DDT entry misconfigured";
	case 260: return "transaction type disallowed";
	case 274: return "page table corrupted";
	}
	return "other";
}

static Iommuops rvops = {
	"riscv-iommu",
	rvprobe,
	rvenable,
	rvcovers,
	rvinfo,
	rvdomnew,
	rvdomfree,
	rvattach,
	rvmap,
	rvunmap,
	rvfaults,
	rvreason,
};

void
rviommulink(void)
{
	iommuregister(&rvops);
}
