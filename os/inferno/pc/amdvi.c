/*
 * AMD-Vi DMA remapping, a backend of the portable IOMMU layer
 * (../port/iommu.h, ../port/deviommu.c; doc/genesize-plan.ms, phase 2),
 * beside VT-d (vtd.c): what an AMD machine has where an Intel one has
 * VT-d.  The IOMMU is the one IVRS describes (archacpi.c, dmar.h).
 *
 * One device table, indexed by requester ID, 32 bytes an entry: every
 * function starts in the host domain, an entry that is valid with
 * translation off (TV clear) and read and write allowed, so its DMA
 * reaches host memory untranslated.  A domain is a four-level page
 * table (48-bit I/O virtual addresses, AMD's own format, not the
 * processor's) and a domain ID; attaching a function points its entry
 * at the table.  Changes go through the command buffer: invalidate the
 * device table entry or the domain's pages, then a completion wait
 * whose store is polled.  Faults come back through the event log,
 * polled too.  Interrupt remapping is not used.
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

enum {
	/* registers */
	Rdevtab		= 0x0000,	/* base | (size in 4K pages - 1) */
	Rcmdbase	= 0x0008,	/* base | log2(entries)<<56 */
	Revtbase	= 0x0010,
	Rctl		= 0x0018,
	Rextfeat	= 0x0030,
	Rcmdhead	= 0x2000,
	Rcmdtail	= 0x2008,
	Revthead	= 0x2010,
	Revttail	= 0x2018,
	Rstatus		= 0x2020,

	/* Rctl */
	CtlEn		= 1<<0,
	CtlEvtlog	= 1<<2,
	CtlCmdbuf	= 1<<12,

	/* Rstatus */
	StEvtOvf	= 1<<0,

	/* device table entry, first quadword */
	DteV		= 1ULL<<0,
	DteTV		= 1ULL<<1,
	DteMode4	= 4ULL<<9,	/* four levels */
	DteIR		= 1ULL<<61,
	DteIW		= 1ULL<<62,

	/* page table entry */
	PtePR		= 1ULL<<0,
	PteIR		= 1ULL<<61,
	PteIW		= 1ULL<<62,
	PteAddr		= 0x000FFFFFFFFFF000ULL,

	/* commands, by opcode in bits 63:60 of the first quadword */
	CmdWait		= 0x1,
	CmdInvDte	= 0x2,
	CmdInvPages	= 0x3,

	Ndevid		= 65536,
	Ndte		= 4,		/* quadwords an entry */
	Ncmd		= 256,		/* 16 bytes each, one page */
	Nevt		= 256,

	Evtpagefault	= 2,		/* event types, bits 63:60 of the first quadword */
};

typedef struct Amddom Amddom;
struct Amddom
{
	uvlong	*root;		/* level-4 table */
	int	domid;
};

static uchar	*regs;
static uvlong	*dtab;	/* Ndevid entries of Ndte quadwords */
static uvlong	*cmdbuf;
static uvlong	*evtlog;
static uvlong	*waitword;	/* where completion waits store */
static uvlong	waitseq;
static Lock	cmdlock;

static uvlong
rd64(int r)
{
	return *(volatile uvlong*)(regs + r);
}

static void
wr64(int r, uvlong v)
{
	*(volatile uvlong*)(regs + r) = v;
}

static void*
page(uintptr size)
{
	void *p;

	p = mallocalign(size, BY2PG, 0, 0);
	if(p == nil)
		error(Enomem);
	memset(p, 0, size);
	return p;
}

/* a command; the buffer is drained before every completion wait */
static void
command(uvlong w0, uvlong w1)
{
	uvlong tail, *c;

	tail = rd64(Rcmdtail) & 0x7FFF0;
	c = cmdbuf + tail/8;
	c[0] = w0;
	c[1] = w1;
	coherence();
	wr64(Rcmdtail, (tail + 16) % (Ncmd*16));
}

/* wait for every command so far to be done */
static void
cmdsync(void)
{
	uvlong seq;
	int i;

	seq = ++waitseq;
	command((uvlong)CmdWait<<60 | PADDR(waitword) | 1, seq);	/* store seq at waitword */
	for(i = 0; i < 10000000; i++){
		if(*(volatile uvlong*)waitword == seq)
			return;
	}
	print("amdvi: completion wait %llud never stored (head %#llux tail %#llux status %#llux)\n",
		seq, rd64(Rcmdhead), rd64(Rcmdtail), rd64(Rstatus));
}

static void
invdte(int devid)
{
	ilock(&cmdlock);
	command((uvlong)CmdInvDte<<60 | devid, 0);
	cmdsync();
	iunlock(&cmdlock);
}

/* every page of a domain: S set, the address all ones */
static void
invdom(int domid)
{
	ilock(&cmdlock);
	command((uvlong)CmdInvPages<<60 | (uvlong)domid<<32, 0x7FFFFFFFFFFFF000ULL | 1);
	cmdsync();
	iunlock(&cmdlock);
}

static int
devid(Pcidev *p)
{
	return BUSBNO(p->tbdf)<<8 | BUSDNO(p->tbdf)<<3 | BUSFNO(p->tbdf);
}

/* the host domain: valid, untranslated, read and write */
static void
sethost(int id)
{
	uvlong *e;

	e = dtab + Ndte*id;
	e[1] = 0;
	e[2] = 0;
	e[3] = 0;
	coherence();
	e[0] = DteV | DteIR | DteIW;
}

static int
amdcovers(Pcidev *p)
{
	return regs != nil && p->tbdf != MKBUS(BusPCI, ivrs->devid>>8, (ivrs->devid>>3)&0x1F, ivrs->devid&7);
}

static int
amdprobe(char *why, int nwhy)
{
	if(ivrs == nil){
		snprint(why, nwhy, "no IVRS table");
		return -1;
	}
	if(ivrs->segment != 0){
		snprint(why, nwhy, "IOMMU on segment %d", ivrs->segment);
		return -1;
	}
	regs = vmap(ivrs->base, 0x4000);
	if(regs == nil){
		snprint(why, nwhy, "cannot map registers at %#llux", ivrs->base);
		return -1;
	}
	return 0;
}

static char*
amdinfo(char *p, char *e)
{
	if(regs == nil)
		return p;
	return seprint(p, e, "amd-vi regs %#llux ctl %#llux status %#llux extfeat %#llux\n",
		ivrs->base, rd64(Rctl), rd64(Rstatus), rd64(Rextfeat));
}

static int
amdenable(void)
{
	int i;

	dtab = page(Ndevid*Ndte*8);	/* two megabytes */
	cmdbuf = page(Ncmd*16);
	evtlog = page(Nevt*16);
	waitword = page(BY2PG);
	for(i = 0; i < Ndevid; i++)
		sethost(i);
	coherence();

	wr64(Rctl, 0);
	wr64(Rdevtab, PADDR(dtab) | (Ndevid*Ndte*8/BY2PG - 1));
	wr64(Rcmdbase, PADDR(cmdbuf) | 8ULL<<56);	/* 2^8 entries */
	wr64(Revtbase, PADDR(evtlog) | 8ULL<<56);
	wr64(Rcmdhead, 0);
	wr64(Rcmdtail, 0);
	wr64(Revthead, 0);
	wr64(Revttail, 0);
	wr64(Rctl, CtlEn | CtlEvtlog | CtlCmdbuf);

	/* nothing cached from before: every entry, then a wait */
	ilock(&cmdlock);
	for(i = 0; i < 256*8; i++){	/* the entries a function on bus 0 to 7 can have */
		command((uvlong)CmdInvDte<<60 | i, 0);
		if(i % (Ncmd/2) == Ncmd/2-1)
			cmdsync();	/* never more than half the buffer outstanding */
	}
	cmdsync();
	iunlock(&cmdlock);
	print("amdvi: translating, device table %#p, %d entries\n", PADDR(dtab), Ndevid);
	return 0;
}

static void
amddomnew(Iodom *d)
{
	Amddom *a;

	a = malloc(sizeof *a);
	if(a == nil)
		error(Enomem);
	a->root = page(BY2PG);
	a->domid = d->id + 1;	/* 0 is not a domain */
	d->arch = a;
}

static void
freetab(uvlong *t, int level)
{
	int i;

	if(level > 1)
		for(i = 0; i < 512; i++)
			if(t[i] & PtePR)
				freetab(KADDR(t[i] & PteAddr), level-1);
	free(t);
}

static void
amddomfree(Iodom *d)
{
	Amddom *a;

	a = d->arch;
	if(a == nil)
		return;
	invdom(a->domid);
	freetab(a->root, 4);
	free(a);
	d->arch = nil;
}

static void
amdattach(Iodom *d, Pcidev *p)
{
	Amddom *a;
	uvlong *e;
	int id;

	if(!amdcovers(p))
		error("no IOMMU covers that function");
	id = devid(p);
	if(d == nil){
		sethost(id);
		invdte(id);
		return;
	}
	a = d->arch;
	e = dtab + Ndte*id;
	/*
	 * Blocked while it changes: translation valid with no tables and
	 * neither IR nor IW refuses everything, where V clear (or TV
	 * clear) would pass DMA through untranslated.
	 */
	e[0] = DteV | DteTV;
	coherence();
	invdte(id);
	e[1] = a->domid;
	e[2] = 0;
	e[3] = 0;
	coherence();
	e[0] = PADDR(a->root) | DteMode4 | DteV | DteTV | DteIR | DteIW;
	coherence();
	invdte(id);
	invdom(a->domid);
}

/* the leaf entry for iova, tables made on the way */
static uvlong*
iowalk(Amddom *a, uvlong iova)
{
	uvlong *t, *e;
	int l;

	t = a->root;
	for(l = 4; l > 1; l--){
		e = t + ((iova >> (12 + 9*(l-1))) & 0x1FF);
		if((*e & PtePR) == 0)
			*e = PADDR(page(BY2PG)) | (uvlong)(l-1)<<9 | PteIR | PteIW | PtePR;
		t = KADDR(*e & PteAddr);
	}
	return t + ((iova >> 12) & 0x1FF);
}

static void
amdmap(Iodom *d, uvlong iova, uvlong pa, uvlong len, int prot)
{
	Amddom *a;
	uvlong e, bits;

	a = d->arch;
	if((iova | pa | len) & (BY2PG-1))
		error(Ebadarg);
	if(iova + len > 1ULL<<48)
		error("beyond 48 bits");
	bits = PtePR;
	if(prot & IoR)
		bits |= PteIR;
	if(prot & IoW)
		bits |= PteIW;
	for(e = iova + len; iova < e; iova += BY2PG, pa += BY2PG)
		*iowalk(a, iova) = pa | bits;	/* next level 0: a leaf */
	coherence();
	invdom(a->domid);
}

static void
amdunmap(Iodom *d, uvlong iova, uvlong len)
{
	Amddom *a;
	uvlong e;

	a = d->arch;
	if((iova | len) & (BY2PG-1))
		error(Ebadarg);
	for(e = iova + len; iova < e; iova += BY2PG)
		*iowalk(a, iova) = 0;
	coherence();
	invdom(a->domid);
}

/* the event log's records, head to tail */
static int
amdfaults(Iofault *f, int max)
{
	uvlong h, t, *ev;
	int n, info;

	if(evtlog == nil)
		return 0;
	n = 0;
	h = rd64(Revthead) & 0x7FFF0;
	t = rd64(Revttail) & 0x7FFF0;
	while(h != t && n < max){
		ev = evtlog + h/8;
		info = ev[0] >> 48;
		f[n].sid = ev[0] & 0xFFFF;
		f[n].reason = info >> 12;		/* the event type */
		f[n].write = (info & 1<<5) != 0;	/* RW in the page fault's flags */
		f[n].addr = ev[1];
		n++;
		h = (h + 16) % (Nevt*16);
	}
	wr64(Revthead, h);
	if(rd64(Rstatus) & StEvtOvf)
		wr64(Rstatus, StEvtOvf);	/* write 1 to clear */
	return n;
}

static char*
amdreason(int r)
{
	switch(r){
	case 1: return "illegal device table entry";
	case 2: return "I/O page fault";
	case 3: return "device table hardware error";
	case 4: return "page table hardware error";
	case 5: return "illegal command";
	case 6: return "command hardware error";
	case 7: return "IOTLB invalidation timeout";
	case 8: return "invalid device request";
	}
	return "other";
}

static Iommuops amdops = {
	"amd-vi",
	amdprobe,
	amdenable,
	amdcovers,
	amdinfo,
	amddomnew,
	amddomfree,
	amdattach,
	amdmap,
	amdunmap,
	amdfaults,
	amdreason,
};

void
amdvilink(void)
{
	iommuregister(&amdops);
}
