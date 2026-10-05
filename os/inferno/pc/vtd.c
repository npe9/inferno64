/*
 * Intel VT-d DMA remapping, the first backend of the portable IOMMU
 * layer (../port/iommu.h, ../port/deviommu.c; doc/genesize-plan.ms,
 * phase 2).  Legacy (not scalable) mode, second-level translation,
 * queued invalidation where the unit has it (ECAP.QI) and the registers
 * where it does not.  Interrupt remapping, where DMAR and every unit
 * have it, is on from boot (irinit, from archacpi.c, before any
 * interrupt is routed): one table of IRTEs every unit shares, and
 * mp.c routes the I/O APICs' entries and every MSI through it
 * (irroute); compatibility-format interrupts are not let through.
 *
 * The units are the DRHDs archacpi.c read from DMAR (dmar.h).  Each
 * gets a root table, and context tables for the buses it covers are
 * made as functions are given contexts.  At "enable" every function a
 * unit covers is put in the host domain: a pass-through context when
 * the unit has pass-through (ECAP.PT), otherwise second-level tables
 * mapping host memory one to one.  A domain is its own second-level
 * tables; attaching a function points its context entry at them.
 *
 * Where the unit's page walks are not coherent with the processor's
 * caches (ECAP.C clear), the tables are written back with WBINVD after
 * each change.  Every change is followed by a global context-cache
 * and IOTLB invalidation: correct, if heavier than domain- or
 * page-selective invalidation would be.
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
#include	"dmar.h"

typedef struct Vtunit Vtunit;

enum {
	VER	= 0x00,
	CAP	= 0x08,
	ECAP	= 0x10,
	GCMD	= 0x18,
	GSTS	= 0x1C,
	RTADDR	= 0x20,
	CCMD	= 0x28,
	FSTS	= 0x34,
	FECTL	= 0x38,
	IQH	= 0x80,
	IQT	= 0x88,
	IQA	= 0x90,
	IRTA	= 0xB8,

	/* GCMD and GSTS, beside those below */
	SIRTP	= 1<<24,	/* set the interrupt remapping table pointer */

	QdIec	= 0x4,		/* interrupt entry cache invalidate; bit 4: one index */
	QdIecIndex	= 1<<4,

	Nirte	= 256,		/* IRTA.S 7: 2^(7+1) entries */
	IrteP	= 1ULL<<0,
	IrteTM	= 1ULL<<4,	/* level-triggered */
	IrteSVT	= 1ULL<<18,	/* in the high quadword: the requester ID is checked */

	/* FSTS */
	IQE	= 1<<4,		/* invalidation queue error */

	/* queued invalidation descriptors, by type in bits 3:0 */
	QdCtx	= 0x1,		/* context-cache invalidate */
	QdIotlb	= 0x2,		/* IOTLB invalidate */
	QdWait	= 0x5,		/* invalidation wait */
	QdGlobal	= 1<<4,	/* granularity in bits 5:4: global (both) */
	QdWaitSW	= 1<<5,	/* the wait writes its status word */
	QdWaitFN	= 1<<6,	/* and fences: later descriptors wait for it */
	Nqd	= 256,		/* 16 bytes each: one page, IQA.QS 0 */

	/* GCMD and GSTS */
	TE	= 1<<31,
	SRTP	= 1<<30,
	WBF	= 1<<27,
	QIE	= 1<<26,
	IRE	= 1<<25,
	CFI	= 1<<23,
	Persist	= TE|QIE|IRE|CFI,	/* GSTS bits a GCMD write must carry */

	/* context entry translation type */
	TTuntranslated	= 0<<2,
	TTpass		= 2<<2,

	SlR	= 1<<0,
	SlW	= 1<<1,
	SlSP	= 1<<7,

	Hostdid	= 1,		/* domain id of the host domain; 0 is reserved under caching mode */
};

struct Vtunit
{
	Dmarunit *d;
	uchar	*regs;
	uvlong	cap, ecap;
	int	coherent;
	int	pt;		/* pass-through contexts */
	int	nfr, fro, iro;
	uvlong	*root;		/* 256 root entries, 128 bits each */
	uvlong	*ctx[256];	/* a context table per bus, made when needed */
	int	qi;		/* queued invalidation on */
	uvlong	*iq;		/* the invalidation queue, Nqd descriptors */
	int	iqtail;		/* the next descriptor's index */
	u32int	*iqstat;	/* where its waits write */
	u32int	iqseq;
};

static Vtunit units[Ndmarunit];
static int nunits;
static int levels;		/* second-level paging levels every unit supports */
static int aw;			/* the context entries' AW for that */
static uvlong *hostid;		/* identity tables for a unit without pass-through */

static u32int
rd32(Vtunit *u, int r)
{
	return *(volatile u32int*)(u->regs + r);
}

static void
wr32(Vtunit *u, int r, u32int v)
{
	*(volatile u32int*)(u->regs + r) = v;
}

static uvlong
rd64(Vtunit *u, int r)
{
	return *(volatile uvlong*)(u->regs + r);
}

static void
wr64(Vtunit *u, int r, uvlong v)
{
	*(volatile uvlong*)(u->regs + r) = v;
}

static void
flushtables(void)
{
	int i;

	coherence();
	for(i = 0; i < nunits; i++)
		if(!units[i].coherent){
			wbinvd();
			return;
		}
}

static int
waitbit(Vtunit *u, int reg, uvlong bit, int want, int wide)
{
	int i;
	uvlong v;

	for(i = 0; i < 1000000; i++){
		v = wide ? rd64(u, reg) : rd32(u, reg);
		if(((v & bit) != 0) == want)
			return 0;
	}
	print("vtd: unit at %#llux: register %#x bit %#llux never became %d\n",
		u->d->base, reg, bit, want);
	return -1;
}

static void
gcmd(Vtunit *u, u32int bit, u32int stsbit, int on)
{
	u32int s;

	s = rd32(u, GSTS) & Persist;
	if(on)
		s |= bit;
	else
		s &= ~bit;
	wr32(u, GCMD, s);
	waitbit(u, GSTS, stsbit, on, 0);
}

static void*	page(void);
int	irinit(void);

/* a descriptor on the invalidation queue */
static void
qdesc(Vtunit *u, uvlong lo, uvlong hi)
{
	uvlong *d;

	d = u->iq + 2*u->iqtail;
	d[0] = lo;
	d[1] = hi;
	u->iqtail = (u->iqtail + 1) % Nqd;
}

/* hand the descriptors so far to the unit, with a wait, and wait for it */
static void
qsync(Vtunit *u)
{
	u32int seq;
	int i;

	seq = ++u->iqseq;
	qdesc(u, (uvlong)seq<<32 | QdWaitFN | QdWaitSW | QdWait, PADDR(u->iqstat));
	coherence();
	if(!u->coherent)
		wbinvd();
	wr64(u, IQT, (uvlong)u->iqtail<<4);
	for(i = 0; i < 10000000; i++){
		if(*(volatile u32int*)u->iqstat == seq)
			return;
		if(rd32(u, FSTS) & IQE){
			print("vtd: unit at %#llux: invalidation queue error at %#llux\n",
				u->d->base, rd64(u, IQH));
			wr32(u, FSTS, IQE);
			return;
		}
	}
	print("vtd: unit at %#llux: invalidation wait %ud never written\n", u->d->base, seq);
}

/* the queue, and queued invalidation on */
static void
qion(Vtunit *u)
{
	u->iq = page();
	u->iqstat = page();
	u->iqtail = 0;
	wr64(u, IQT, 0);
	wr64(u, IQA, PADDR(u->iq));	/* QS 0: one page; 128-bit descriptors */
	gcmd(u, QIE, QIE, 1);
	u->qi = (rd32(u, GSTS) & QIE) != 0;
}

/* global context-cache and IOTLB invalidation */
static void
invalidate(Vtunit *u)
{
	int iotlb;

	if(u->qi){
		qdesc(u, QdGlobal | QdCtx, 0);
		/* drain reads and writes (IOTLB invalidate DR, DW) where the unit can */
		qdesc(u, QdGlobal | QdIotlb | ((u->cap>>55 & 1) ? 1<<7 : 0) | ((u->cap>>54 & 1) ? 1<<6 : 0), 0);
		qsync(u);
		return;
	}
	if(u->cap & 1<<4){		/* RWBF: flush the write buffer first */
		wr32(u, GCMD, (rd32(u, GSTS) & Persist) | WBF);
		waitbit(u, GSTS, WBF, 0, 0);
	}
	wr64(u, CCMD, 1ULL<<63 | 1ULL<<61);
	waitbit(u, CCMD, 1ULL<<63, 0, 1);
	iotlb = u->iro + 8;
	wr64(u, iotlb, 1ULL<<63 | 1ULL<<60 | 1ULL<<49 | 1ULL<<48);
	waitbit(u, iotlb, 1ULL<<63, 0, 1);
}

static void
invalidateall(void)
{
	int i;

	flushtables();
	for(i = 0; i < nunits; i++)
		if(rd32(&units[i], GSTS) & TE)
			invalidate(&units[i]);
}

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

/* the leaf entry for iova in tables rooted at tab, made as needed */
static uvlong*
slwalk(uvlong *tab, uvlong iova)
{
	int l;

	for(l = levels-1; l >= 1; l--){
		tab += (iova >> (12 + 9*l)) & 0x1FF;
		if((*tab & (SlR|SlW)) == 0)
			*tab = PADDR(page()) | SlR | SlW;
		tab = (uvlong*)(uintptr)(*tab & 0x000FFFFFFFFFF000ULL);
	}
	return tab + ((iova >> 12) & 0x1FF);
}

static void
slfree(uvlong *tab, int l)
{
	int i;

	if(l > 0)
		for(i = 0; i < 512; i++)
			if((tab[i] & (SlR|SlW)) != 0 && (tab[i] & SlSP) == 0)
				slfree((uvlong*)(uintptr)(tab[i] & 0x000FFFFFFFFFF000ULL), l-1);
	free(tab);
}

/*
 * The function's unit: a device scope naming the function, or a
 * bridge above it, on its own bus; else a unit that includes all.
 * Scopes here have one path element, as every DMAR this kernel has
 * met does; a deeper path is a function behind a bridge that is not
 * on bus 0's segment root and is not matched.
 */
static Vtunit*
unitof(Pcidev *p)
{
	Pcidev *q;
	Dmarscope *s;
	Vtunit *u;
	int i, j;

	for(i = 0; i < nunits; i++){
		u = &units[i];
		for(j = 0; j < u->d->nscope; j++){
			s = &u->d->scope[j];
			if(s->npath != 1)
				continue;
			for(q = p; q != nil; q = q->parent){
				if(BUSBNO(q->tbdf) != s->bus
				|| BUSDNO(q->tbdf) != s->path[0][0] || BUSFNO(q->tbdf) != s->path[0][1])
					continue;
				if(q == p && s->type == DmarScopeEndpoint
				|| s->type == DmarScopeBridge)
					return u;
			}
		}
	}
	for(i = 0; i < nunits; i++)
		if(units[i].d->flags & DmarIncludeAll)
			return &units[i];
	return nil;
}

static uvlong*
ctxentry(Vtunit *u, Pcidev *p)
{
	int bus, devfn;

	bus = BUSBNO(p->tbdf);
	devfn = BUSDNO(p->tbdf)<<3 | BUSFNO(p->tbdf);
	if(u->ctx[bus] == nil){
		u->ctx[bus] = page();
		u->root[2*bus] = PADDR(u->ctx[bus]) | 1;
		u->root[2*bus+1] = 0;
	}
	return &u->ctx[bus][2*devfn];
}

static void
setctx(Vtunit *u, Pcidev *p, uvlong *tables, int did)
{
	uvlong *c;

	c = ctxentry(u, p);
	c[0] = 0;		/* not present while it changes */
	coherence();
	if(tables == nil && u->pt){
		c[1] = aw | did << 8;
		c[0] = TTpass | 1;
	}else{
		if(tables == nil)
			tables = hostid;
		c[1] = aw | did << 8;
		c[0] = PADDR(tables) | TTuntranslated | 1;
	}
}

static int
vtdcovers(Pcidev *p)
{
	return unitof(p) != nil;
}

/* the units DMAR describes, mapped once (irinit at boot, vtdprobe later) */
static int
mapunits(char *why, int nwhy)
{
	static int done, ok;
	Vtunit *u;
	int i, sagaw, l;

	if(done)
		goto out;
	done = 1;
	if(dmar == nil || dmar->nunit == 0){
		snprint(why, nwhy, "no DMAR table");
		return -1;
	}
	l = 4;
	for(i = 0; i < dmar->nunit && nunits < nelem(units); i++){
		u = &units[nunits];
		u->d = &dmar->unit[i];
		if(u->d->segment != 0)
			continue;
		u->regs = vmap(u->d->base, u->d->size);
		if(u->regs == nil){
			print("vtd: cannot map unit at %#llux\n", u->d->base);
			continue;
		}
		u->cap = rd64(u, CAP);
		u->ecap = rd64(u, ECAP);
		u->coherent = u->ecap & 1;
		u->pt = (u->ecap >> 6) & 1;
		u->nfr = ((u->cap >> 40) & 0xFF) + 1;
		u->fro = ((u->cap >> 24) & 0x3FF) * 16;
		u->iro = ((u->ecap >> 8) & 0x3FF) * 16;
		sagaw = (u->cap >> 8) & 0x1F;
		if(sagaw & 1<<2)
			;			/* 48 bits, four levels */
		else if(sagaw & 1<<1)
			l = 3;			/* 39 bits, three levels */
		else{
			print("vtd: unit at %#llux supports neither 3- nor 4-level tables (SAGAW %#x)\n",
				u->d->base, sagaw);
			continue;
		}
		nunits++;
	}
	levels = l;
	aw = l == 4 ? 2 : 1;
	ok = nunits > 0;
out:
	if(!ok){
		snprint(why, nwhy, dmar == nil || dmar->nunit == 0 ? "no DMAR table" : "no usable remapping unit");
		return -1;
	}
	return 0;
}

static int
vtdprobe(char *why, int nwhy)
{
	return mapunits(why, nwhy);
}

static char*
vtdinfo(char *p, char *e)
{
	Vtunit *u;
	int i;

	p = seprint(p, e, "levels %d haw %d intremap %d\n", levels, dmar->haw,
		(dmar->flags & DmarIntrRemap) != 0);
	for(i = 0; i < nunits; i++){
		u = &units[i];
		p = seprint(p, e, "unit %d regs %#llux ver %#ux cap %#llux ecap %#llux gsts %#ux pt %d coherent %d nfr %d%s\n",
			i, u->d->base, rd32(u, VER), u->cap, u->ecap, rd32(u, GSTS),
			u->pt, u->coherent, u->nfr, (u->cap & 1<<7) ? " caching-mode" : "");
	}
	return p;
}

/* identity tables for the host domain, for a unit without pass-through */
static void
mkhostid(void)
{
	uvlong top, a;
	int i;

	if(hostid != nil)
		return;
	top = 0;
	for(i = 0; i < nelem(conf.mem); i++)
		if(conf.mem[i].npage != 0 && conf.mem[i].base + conf.mem[i].npage*BY2PG > top)
			top = conf.mem[i].base + conf.mem[i].npage*BY2PG;
	hostid = page();
	for(a = 0; a < top; a += BY2PG)
		*slwalk(hostid, a) = a | SlR | SlW;
}

static int
vtdenable(void)
{
	Vtunit *u;
	Pcidev *p;
	int i;

	for(i = 0; i < nunits; i++){
		u = &units[i];
		if(!u->pt)
			mkhostid();
		u->root = page();
	}
	for(p = pcimatch(nil, 0, 0); p != nil; p = pcimatch(p, 0, 0))
		if((u = unitof(p)) != nil)
			setctx(u, p, nil, Hostdid);
	flushtables();
	for(i = 0; i < nunits; i++){
		u = &units[i];
		if(!u->qi && (rd32(u, GSTS) & QIE)){
			print("vtd: unit at %#llux has queued invalidation on; not taken over\n", u->d->base);
			return -1;
		}
		if(!u->qi && (u->ecap & 1<<1))	/* QI; irinit may have it on already */
			qion(u);
		wr64(u, RTADDR, PADDR(u->root));
		gcmd(u, SRTP, SRTP, 1);
		invalidate(u);
		gcmd(u, TE, TE, 1);
		if((rd32(u, GSTS) & TE) == 0)
			return -1;
		print("vtd: unit %d at %#llux translating (host domain %s, %s invalidation)\n", i, u->d->base,
			u->pt ? "pass-through" : "identity-mapped", u->qi ? "queued" : "register");
	}
	return 0;
}

static void
vtddomnew(Iodom *d)
{
	d->arch = page();
}

static void
vtddomfree(Iodom *d)
{
	if(d->arch != nil)
		slfree(d->arch, levels-1);
	d->arch = nil;
	invalidateall();
}

static void
vtdattach(Iodom *d, Pcidev *p)
{
	Vtunit *u;

	u = unitof(p);
	if(u == nil)
		error("no IOMMU covers that function");
	if(d == nil)
		setctx(u, p, nil, Hostdid);
	else
		setctx(u, p, d->arch, Hostdid + 1 + d->id);
	invalidateall();
}

static void
vtdmap(Iodom *d, uvlong iova, uvlong pa, uvlong len, int prot)
{
	uvlong e, bits;

	if((iova | pa | len) & (BY2PG-1))
		error(Ebadarg);
	if(iova + len > 1ULL << (levels == 4 ? 48 : 39))
		error("beyond the address width");
	bits = 0;
	if(prot & IoR)
		bits |= SlR;
	if(prot & IoW)
		bits |= SlW;
	for(e = iova + len; iova < e; iova += BY2PG, pa += BY2PG)
		*slwalk(d->arch, iova) = pa | bits;
	invalidateall();
}

static void
vtdunmap(Iodom *d, uvlong iova, uvlong len)
{
	uvlong e;

	if((iova | len) & (BY2PG-1))
		error(Ebadarg);
	for(e = iova + len; iova < e; iova += BY2PG)
		*slwalk(d->arch, iova) = 0;
	invalidateall();
}

static int
vtdfaults(Iofault *f, int max)
{
	Vtunit *u;
	uvlong hi, lo;
	int i, j, n;

	n = 0;
	for(i = 0; i < nunits; i++){
		u = &units[i];
		for(j = 0; j < u->nfr && n < max; j++){
			hi = rd64(u, u->fro + 16*j + 8);
			if((hi & 1ULL<<63) == 0)
				continue;
			lo = rd64(u, u->fro + 16*j);
			f[n].sid = hi & 0xFFFF;
			f[n].reason = (hi >> 32) & 0xFF;
			f[n].write = (hi & 1ULL<<62) == 0;	/* T: 0 write, 1 read */
			f[n].addr = lo & ~0xFFFULL;
			n++;
			wr32(u, u->fro + 16*j + 12, 1<<31);	/* clear F */
		}
		wr32(u, FSTS, rd32(u, FSTS) & 1);	/* clear an overflow */
	}
	return n;
}

static char*
vtdreason(int r)
{
	switch(r){
	case 0x1: return "root entry not present";
	case 0x2: return "context entry not present";
	case 0x3: return "context entry invalid";
	case 0x4: return "address beyond the address width";
	case 0x5: return "write to a page without write permission";
	case 0x6: return "read of a page without read permission";
	case 0x7: return "page table walk failed";
	case 0x8: return "root table read failed";
	case 0x9: return "context table read failed";
	case 0xA: return "root entry reserved bits";
	case 0xB: return "context entry reserved bits";
	case 0xC: return "page table entry reserved bits";
	case 0xD: return "translation type not allowed";
	}
	return "other";
}

static Iommuops vtdops = {
	"vtd",
	vtdprobe,
	vtdenable,
	vtdcovers,
	vtdinfo,
	vtddomnew,
	vtddomfree,
	vtdattach,
	vtdmap,
	vtdunmap,
	vtdfaults,
	vtdreason,
};

void
vtdlink(void)
{
	irinit();
	iommuregister(&vtdops);
}

/*
 * Interrupt remapping.  Every interrupt a device or an I/O APIC sends
 * is a write to 0xFEExxxxx that the unit covering it remaps through an
 * IRTE: vector, destination, trigger, and for an MSI the requester ID
 * it must come from.  An assigned function can then raise only the
 * interrupts its entries allow.  On from boot, before any interrupt is
 * routed, so nothing is ever in the compatibility format, which is not
 * let through (GCMD.CFI clear).
 */
extern int	irremap;	/* mp.c: on, it routes through irroutef */
extern int	(*irroutef)(uvlong, int, int, int, int);
extern int	(*irioapicsidf)(int);
extern void	intrreroute(void);	/* irq.c */
int	irroute(uvlong, int, int, int, int);
static uvlong	*irt;		/* Nirte entries, two quadwords each */
static uvlong	irkey[Nirte];	/* what each entry is for, 0 free */
static Lock	irtlock;

/*
 * An I/O APIC's requester ID, from its DMAR device scope: its start bus
 * and, for a scope with one (device, function), that.  A longer path
 * runs through bridges whose bus numbers would have to be read; such an
 * I/O APIC is not checked (-1).
 */
static int
ioapicsid(int apicno)
{
	Dmarscope *sc;
	int i, j;

	for(i = 0; i < dmar->nunit; i++)
		for(j = 0; j < dmar->unit[i].nscope; j++){
			sc = &dmar->unit[i].scope[j];
			if(sc->type == DmarScopeIoapic && sc->enumid == apicno && sc->npath == 1)
				return sc->bus<<8 | sc->path[0][0]<<3 | sc->path[0][1];
		}
	return -1;
}

int
irinit(void)
{
	char why[ERRMAX];
	Vtunit *u;
	int i;

	if(dmar == nil || (dmar->flags & DmarIntrRemap) == 0)
		return -1;
	if(mapunits(why, sizeof why) < 0)
		return -1;
	for(i = 0; i < nunits; i++)
		if((units[i].ecap & (1<<3|1<<1)) != (1<<3|1<<1)){	/* IR and QI */
			print("vtd: unit at %#llux cannot remap interrupts (ECAP %#llux)\n",
				units[i].d->base, units[i].ecap);
			return -1;
		}
	irt = page();		/* Nirte*16 bytes: one page */
	for(i = 0; i < nunits; i++){
		u = &units[i];
		if(rd32(u, GSTS) & (QIE|IRE)){
			print("vtd: unit at %#llux has queued invalidation or remapping on; not taken over\n", u->d->base);
			return -1;
		}
		qion(u);
		wr64(u, IRTA, PADDR(irt) | 7);	/* S 7: 256 entries; EIME clear, xAPIC */
		gcmd(u, SIRTP, SIRTP, 1);
		qdesc(u, QdIec, 0);		/* global */
		qsync(u);
		gcmd(u, IRE, IRE, 1);
		if((rd32(u, GSTS) & IRE) == 0){
			print("vtd: unit at %#llux: remapping did not come on\n", u->d->base);
			return -1;
		}
	}
	irroutef = irroute;
	irioapicsidf = ioapicsid;
	irremap = 1;
	intrreroute();
	print("vtd: interrupt remapping on, %d units, %d entries\n", nunits, Nirte);
	return 0;
}

/*
 * The IRTE for key (a source: an I/O APIC input or a function's MSI
 * vector), made or reused, routing vector vno to the processor whose
 * APIC ID is apicid; sid is the requester ID an MSI must carry, -1 for
 * none checked.  Returns its index, -1 if the table is full.
 */
int
irroute(uvlong key, int vno, int apicid, int level, int sid)
{
	uvlong *e;
	int i, free, j;

	ilock(&irtlock);
	free = -1;
	for(i = 0; i < Nirte; i++){
		if(irkey[i] == key)
			break;
		if(irkey[i] == 0 && free < 0)
			free = i;
	}
	if(i == Nirte){
		if(free < 0){
			iunlock(&irtlock);
			print("vtd: interrupt remapping table full\n");
			return -1;
		}
		i = free;
		irkey[i] = key;
	}
	e = irt + 2*i;
	e[0] = 0;
	coherence();
	e[1] = sid >= 0 ? IrteSVT | (uvlong)(sid & 0xFFFF) : 0;
	e[0] = IrteP | (level ? IrteTM : 0) | (uvlong)(vno & 0xFF)<<16 | (uvlong)(apicid & 0xFF)<<40;
	flushtables();
	for(j = 0; j < nunits; j++){
		qdesc(&units[j], QdIec | QdIecIndex | (uvlong)i<<32, 0);
		qsync(&units[j]);
	}
	iunlock(&irtlock);
	return i;
}
