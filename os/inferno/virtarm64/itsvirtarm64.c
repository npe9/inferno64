#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/pci.h"


/*
 * MSI-X through a GICv3 ITS.
 *
 * A PCI MSI on arm64 is a memory write, and something has to turn that
 * write into an interrupt.  os/inferno/virtarm64/msivirtarm64.c does it
 * with a GICv2m frame, whose SETSPI register takes an SPI number as its
 * data; a machine with a GICv3 ITS has no such frame and works the
 * other way round.  The write goes to one register, GITS_TRANSLATER,
 * and carries an event id as its data; the ITS looks up the writing
 * device and that event in tables this code builds, and delivers an
 * LPI -- an interrupt whose number is 8192 or above, outside the SPI
 * range entirely -- to a redistributor.
 *
 * So there are three things to set up before an MSI can arrive, and
 * they are independent of each other:
 *
 *	the redistributor's LPI tables: one byte of configuration per
 *	LPI (priority, enabled) and one bit of pending state, and
 *	GICR_CTLR.EnableLPIs;
 *
 *	the ITS's own tables: a device table, a collection table if the
 *	ITS keeps collections in memory rather than in hardware, and a
 *	command queue, which is how every other instruction below is
 *	issued;
 *
 *	per device, an interrupt translation table, and one mapping per
 *	vector: MAPD for the device, MAPC for the collection (once),
 *	MAPTI for device+event -> LPI, then INV and SYNC.
 *
 * This is a physical-LPI implementation only: no virtual LPIs, no
 * ITS list synchronisation, one collection on processor 0, and the
 * ITS's own affinity never changes.  That matches what this board does
 * with SPIs, which gicenable() routes to processor 0 and leaves there.
 *
 * Verified under QEMU (-M virt,gic-version=3, which has an ITS) and on
 * a Compute Engine t2a, whose MADT reports an ITS at 0x8080000 and no
 * v2m frame, which is why the arm64 cloud kernel had no MSI at all and
 * its network driver polled.
 */

enum {
	/* ITS registers, byte offsets from the ITS base */
	Ctlr		= 0x0000,	/* 32-bit: bit0 Enabled, bit31 Quiescent */
	Iidr		= 0x0004,
	Typer		= 0x0008,	/* 64-bit */
	Cbaser		= 0x0080,	/* 64-bit: command queue */
	Cwriter		= 0x0088,	/* 64-bit */
	Creadr		= 0x0090,	/* 64-bit */
	Baser0		= 0x0100,	/* 64-bit each, 8 of them */
	Translater	= 0x10040,	/* the doorbell an MSI writes */

	/* GITS_TYPER fields */
	TyperPhysical	= 1<<0,
	TyperPta	= 1<<19,	/* RDbase is an address, not a number */

	/* GITS_BASER fields */
	BaserValid	= (uvlong)1<<63,
	BaserIndirect	= (uvlong)1<<62,

	Tabdevice	= 1,		/* GITS_BASER Type field */
	Tabcollection	= 4,

	/* commands */
	Cmapd		= 0x08,
	Cmapc		= 0x09,
	Cmapti		= 0x0A,
	Cinv		= 0x0C,
	Csync		= 0x05,

	/* redistributor, RD_base byte offsets */
	Rctlr		= 0x0000,	/* bit0 EnableLPIs, bit3 RWP */
	Rtyper		= 0x0008,	/* 64-bit: [23:8] processor number */
	Rpropbaser	= 0x0070,	/* 64-bit */
	Rpendbaser	= 0x0078,	/* 64-bit */

	RctlrEnableLPIs	= 1<<0,

	/*
	 * Memory attributes.  They are NOT in the same bits in every
	 * register: GITS_BASER<n> and GITS_CBASER keep InnerCache at
	 * [61:59], and the redistributor's GICR_PROPBASER and
	 * GICR_PENDBASER keep it at [9:7].  Writing the BASER layout into
	 * PROPBASER leaves InnerCache 0, which is Device-nGnRnE: the
	 * redistributor then reads the LPI configuration with
	 * non-cacheable accesses while this kernel wrote it with
	 * cacheable ones, sees a table of zeroes, and every LPI is
	 * disabled.  That is what it looked like on a Compute Engine t2a
	 * -- every vector mapped, not one interrupt delivered -- while
	 * QEMU, which models no cache, was fine either way.
	 *
	 * 7 is RaWaWb, inner shareable.  The hardware may refuse and say
	 * so in the read-back, which is why itscoherent below exists.
	 */
	Baserinner	= (uvlong)7<<59,	/* GITS_BASER, GITS_CBASER */
	Basershare	= (uvlong)1<<10,
	Propinner	= (uvlong)7<<7,		/* GICR_PROPBASER, GICR_PENDBASER */
	Propshare	= (uvlong)1<<10,

	Lpibase		= 8192,		/* the first LPI INTID */
	Nlpi		= 64,		/* how many this board hands out */
	Nitt		= 32,		/* events per device */
	Ncmd		= 256,		/* command queue entries (32 bytes each) */
	Cmdsize		= 32,
};

typedef struct Itsdev Itsdev;
struct Itsdev {
	u32int	devid;
	uchar	*itt;
	int	mapped;
};

static uvlong itsbase;
static uvlong itstyper;
static uchar *cmdq;			/* Ncmd commands */
static u32int cmdwr;			/* our copy of GITS_CWRITER, in bytes */
static uchar *lpiconf;			/* one byte per LPI */
static uchar *lpipend;			/* one bit per LPI */
static uchar lpiused[Nlpi];
static Itsdev itsdev[16];
static int nitsdev;
static int collectionmapped;
static int itscoherent = 1;	/* the tables are read through a cache */
static uvlong rdbase;			/* what MAPC and SYNC name */

/*
 * When the hardware would not take a cacheable attribute, everything
 * this kernel writes for the ITS has to reach memory before the ITS
 * reads it.
 */
static void
itsclean(void *p, int n)
{
	if(!itscoherent)
		dccleanrange(p, n);
	coherence();
}

static u32int
itsr32(int off)
{
	return *(volatile u32int*)(uintptr)(itsbase + off);
}

static void
itsw32(int off, u32int v)
{
	*(volatile u32int*)(uintptr)(itsbase + off) = v;
}

static uvlong
itsr64(int off)
{
	return *(volatile uvlong*)(uintptr)(itsbase + off);
}

static void
itsw64(int off, uvlong v)
{
	*(volatile uvlong*)(uintptr)(itsbase + off) = v;
}

/*
 * One command into the queue, then wait for the ITS to consume it.
 * Waiting on every command rather than batching is the slow way and
 * the clear one: this runs a handful of times per device at boot, and
 * a command that fails is then the last one issued rather than one of
 * eight in flight.
 */
static int
itscmd(uvlong d0, uvlong d1, uvlong d2, uvlong d3)
{
	uvlong *c;
	u32int next;
	int i;

	c = (uvlong*)(cmdq + cmdwr);
	c[0] = d0;
	c[1] = d1;
	c[2] = d2;
	c[3] = d3;
	itsclean(c, Cmdsize);

	next = (cmdwr + Cmdsize) % (Ncmd*Cmdsize);
	itsw64(Cwriter, next);
	cmdwr = next;

	for(i = 0; i < 100000; i++){
		if((itsr64(Creadr) & ~(uvlong)0x1F) == next)
			return 0;
		microdelay(10);
	}
	print("its: command %llud not consumed: creadr %#llux cwriter %#ux\n",
		d0 & 0xFF, itsr64(Creadr), next);
	return -1;
}

static int
lpialloc(void)
{
	int i;

	for(i = 0; i < Nlpi; i++)
		if(lpiused[i] == 0){
			lpiused[i] = 1;
			return Lpibase + i;
		}
	return -1;
}

/*
 * A device's interrupt translation table, made once per device.  The
 * entry size is the ITS's, not ours: GITS_TYPER carries it.
 */
static Itsdev*
itsdevice(u32int devid)
{
	Itsdev *d;
	int i, ittsz, esize;
	uvlong size;

	for(i = 0; i < nitsdev; i++)
		if(itsdev[i].devid == devid)
			return &itsdev[i];
	if(nitsdev >= nelem(itsdev))
		return nil;

	esize = ((itstyper >> 4) & 0xF) + 1;
	ittsz = esize * Nitt;
	if(ittsz < 256)
		ittsz = 256;
	d = &itsdev[nitsdev];
	d->devid = devid;
	d->itt = mallocalign(ittsz, 256, 0, 0);
	if(d->itt == nil)
		return nil;
	memset(d->itt, 0, ittsz);
	itsclean(d->itt, ittsz);

	/* MAPD: device id, ITT size as log2(entries)-1, ITT address, valid */
	size = 4;			/* 32 events: log2(32) - 1 */
	if(itscmd(Cmapd | ((uvlong)devid << 32), size,
		(PADDR(d->itt) & ~(uvlong)0xFF) | BaserValid, 0) < 0)
		return nil;
	d->mapped = 1;
	nitsdev++;
	return d;
}

/*
 * The collection, once for the machine.  RDbase is the redistributor's
 * address when GITS_TYPER.PTA says so and its processor number when it
 * does not; getting that backwards maps the collection onto nothing
 * and no interrupt is ever delivered, with no other symptom.
 */
static int
itscollection(void)
{
	if(collectionmapped)
		return 0;
	if(itstyper & TyperPta)
		rdbase = m->gicr;
	else
		rdbase = (*(volatile uvlong*)(uintptr)(m->gicr + Rtyper) >> 8) & 0xFFFF;
	if(itscmd(Cmapc, 0, (rdbase << 16) | 0 | BaserValid, 0) < 0)
		return -1;
	collectionmapped = 1;
	return 0;
}

static void
itsintrenable(Pcidev *p, int vec, void (*f)(Ureg*, void*), void *a, char *name)
{
	u32int devid;
	int lpi, rid;

	if(itsbase == 0)
		return;
	/*
	 * The device id of a PCI function is its requester id, bus:dev.fn,
	 * unless the IORT remaps it -- which is a thing a machine really
	 * does, and which the firmware publishes, so ask rather than
	 * assume.  acpiitsdevid() returns 0 when there is nothing to say.
	 */
	rid = (BUSBNO(p->tbdf) << 8) | (BUSDNO(p->tbdf) << 3) | BUSFNO(p->tbdf);
	if(!acpiitsdevid(rid, &devid))
		devid = rid;

	if(itscollection() < 0){
		print("its: %s: cannot map the collection\n", name);
		return;
	}
	if(itsdevice(devid) == nil){
		print("its: %s: cannot map device %#ux\n", name, devid);
		return;
	}
	if(vec >= Nitt){
		print("its: %s: vector %d past this board's %d events\n",
			name, vec, Nitt);
		return;
	}
	if((lpi = lpialloc()) < 0){
		print("its: %s: no lpi left\n", name);
		return;
	}

	/* enabled, group 1, the same priority gicenable() gives an SPI */
	lpiconf[lpi - Lpibase] = 0xa0 | 2 | 1;
	itsclean(&lpiconf[lpi - Lpibase], 1);

	if(itscmd(Cmapti | ((uvlong)devid << 32),
		(uvlong)vec | ((uvlong)lpi << 32), 0, 0) < 0
	|| itscmd(Cinv | ((uvlong)devid << 32), vec, 0, 0) < 0
	|| itscmd(Csync, 0, rdbase << 16, 0) < 0){
		print("its: %s vec %d: mapping failed\n", name, vec);
		return;
	}

	if(pcimsixenable(p, vec, itsbase + Translater, vec) < 0){
		print("its: %s vec %d: pcimsixenable failed\n", name, vec);
		return;
	}
	intrenable(lpi, f, a, p->tbdf, name);
	print("msix: %s tbdf %#ux vec %d -> lpi %d (rid %#ux device %#ux): enabled\n",
		name, p->tbdf, vec, lpi, rid, devid);
}

/*
 * The redistributor's own LPI tables.  Both are this processor's, and
 * EnableLPIs is a one-way switch: the architecture allows an
 * implementation to refuse to clear it, so this is done once and never
 * undone.
 */
static int
lpiinit(void)
{
	volatile u32int *rc;
	uvlong prop, pend;
	int idbits;

	idbits = 14;			/* LPI ids 8192..16383 */
	lpiconf = mallocalign(1 << idbits, 4096, 0, 0);
	lpipend = mallocalign(64*1024, 64*1024, 0, 0);
	if(lpiconf == nil || lpipend == nil){
		print("its: no memory for the lpi tables\n");
		return -1;
	}
	memset(lpiconf, 0, 1 << idbits);
	memset(lpipend, 0, 64*1024);
	coherence();

	rc = (volatile u32int*)(uintptr)(m->gicr + Rctlr);
	if(*rc & RctlrEnableLPIs){
		print("its: lpis were already enabled by the firmware\n");
		return -1;
	}

	prop = (PADDR(lpiconf) & ~(uvlong)0xFFF) | Propinner | Propshare | (idbits - 1);
	pend = (PADDR(lpipend) & ~(uvlong)0xFFFF) | Propinner | Propshare;
	*(volatile uvlong*)(uintptr)(m->gicr + Rpropbaser) = prop;
	*(volatile uvlong*)(uintptr)(m->gicr + Rpendbaser) = pend;
	coherence();

	/*
	 * The read-back is the hardware's answer, not ours.  If it kept
	 * neither of the cacheable encodings, the redistributor is
	 * reading these tables around the cache and every table written
	 * from here on has to be cleaned to memory by hand.
	 */
	prop = *(volatile uvlong*)(uintptr)(m->gicr + Rpropbaser);
	if(((prop >> 7) & 7) <= 1){
		itscoherent = 0;
		print("its: the redistributor reads the lpi tables"
			" uncached; cleaning them by hand\n");
	}
	dccleanrange(lpiconf, 1 << idbits);
	dccleanrange(lpipend, 64*1024);
	coherence();
	*rc |= RctlrEnableLPIs;
	coherence();
	return 0;
}

/*
 * The ITS's own tables: a device table, and a collection table when
 * the ITS keeps collections in memory.
 *
 * The page size is the hardware's to choose, not ours.  GITS_BASER
 * takes a requested size in its Page_Size field and returns what it
 * will actually use, and a Compute Engine t2a returns 64 KiB for a
 * request of 4 KiB -- after which the Size field this kernel wrote
 * means sixteen 64 KiB pages rather than sixteen 4 KiB ones, and the
 * ITS reads a device table that is not the one that was allocated.
 * The symptom is nothing at all: commands are accepted, mappings are
 * made, and no interrupt is ever translated, because the device entry
 * the ITS looks up is not the entry that was written.  So this asks,
 * reads the answer back, and then allocates.
 */
static int
itstable(int n, int type, int idbits)
{
	uvlong b, pa;
	int esize, psize, pshift, npages, want;
	uchar *t;

	b = itsr64(Baser0 + 8*n);
	esize = ((b >> 48) & 0x1F) + 1;

	/* ask for 64 KiB pages and see what comes back */
	itsw64(Baser0 + 8*n, (b & ~(uvlong)0x300) | ((uvlong)2 << 8));
	b = itsr64(Baser0 + 8*n);
	psize = (b >> 8) & 3;
	switch(psize){
	case 0:	pshift = 12; break;
	case 1:	pshift = 14; break;
	default:	pshift = 16; break;
	}

	/*
	 * Enough entries for every id the ITS says it translates, capped:
	 * 16 device id bits at 8 bytes each is half a megabyte, which is
	 * worth having; more than a megabyte is not, and an id past the
	 * end of a short table simply never gets an interrupt, which the
	 * mapping code reports.
	 */
	want = esize << idbits;
	if(want > 1024*1024)
		want = 1024*1024;
	npages = (want + (1 << pshift) - 1) >> pshift;
	if(npages < 1)
		npages = 1;

	t = mallocalign(npages << pshift, 1 << pshift, 0, 0);
	if(t == nil){
		print("its: no memory for table type %d (%d pages of %d KiB)\n",
			type, npages, 1 << (pshift - 10));
		return -1;
	}
	memset(t, 0, npages << pshift);
	dccleanrange(t, npages << pshift);
	pa = PADDR(t);

	b = BaserValid | ((uvlong)type << 56) | ((uvlong)(esize - 1) << 48) |
		(pa & ~(uvlong)0xFFF) | Baserinner | Basershare |
		((uvlong)psize << 8) | (npages - 1);
	itsw64(Baser0 + 8*n, b);
	b = itsr64(Baser0 + 8*n);
	if((b & BaserValid) == 0){
		print("its: table type %d would not take: baser %#llux\n", type, b);
		return -1;
	}
	if(b & BaserIndirect){
		print("its: table type %d came back indirect;"
			" this board does not build two levels\n", type);
		return -1;
	}
	if((int)((b >> 8) & 3) != psize){
		print("its: table type %d: asked for %d KiB pages,"
			" got %lld\n", type, 1 << (pshift - 10), (b >> 8) & 3);
		return -1;
	}
	if(((b >> 59) & 7) <= 1)
		itscoherent = 0;
	print("its: table type %d: %d pages of %d KiB, entry %d bytes, for %d ids\n",
		type, npages, 1 << (pshift - 10), esize, (npages << pshift) / esize);
	return 0;
}

static int
itstables(void)
{
	uvlong b;
	int i, type, devbits, cidbits;

	devbits = ((itstyper >> 13) & 0x1F) + 1;
	cidbits = (itstyper & ((uvlong)1 << 36)) ? (int)(((itstyper >> 32) & 0xF) + 1) : 16;
	for(i = 0; i < 8; i++){
		b = itsr64(Baser0 + 8*i);
		type = (b >> 56) & 7;
		if(type != Tabdevice && type != Tabcollection)
			continue;
		if(itstable(i, type, type == Tabdevice ? devbits : cidbits) < 0)
			return -1;
	}
	return 0;
}

/*
 * Called from msiinit() when the MADT reports an ITS and no v2m frame.
 */
int
itsinit(void)
{
	uvlong c;

	if(acpinits == 0)
		return -1;
	itsbase = acpiits[0].base;
	itstyper = itsr64(Typer);
	if((itstyper & TyperPhysical) == 0){
		print("its: at %#llux does not do physical lpis\n", itsbase);
		itsbase = 0;
		return -1;
	}
	if(m->gicr == 0){
		print("its: no redistributor for this processor\n");
		itsbase = 0;
		return -1;
	}

	/* the ITS must be off while its tables are set */
	itsw32(Ctlr, 0);
	coherence();

	if(lpiinit() < 0 || itstables() < 0){
		itsbase = 0;
		return -1;
	}

	cmdq = mallocalign(Ncmd*Cmdsize, 64*1024, 0, 0);
	if(cmdq == nil){
		print("its: no memory for the command queue\n");
		itsbase = 0;
		return -1;
	}
	memset(cmdq, 0, Ncmd*Cmdsize);
	c = (PADDR(cmdq) & ~(uvlong)0xFFF) | Baserinner | Basershare |
		(Ncmd*Cmdsize/4096 - 1) | BaserValid;
	itsw64(Cbaser, c);
	c = itsr64(Cbaser);
	if(((c >> 59) & 7) <= 1)
		itscoherent = 0;
	dccleanrange(cmdq, Ncmd*Cmdsize);
	itsw64(Cwriter, 0);
	cmdwr = 0;
	coherence();

	itsw32(Ctlr, 1);
	coherence();
	if((itsr32(Ctlr) & 1) == 0){
		print("its: at %#llux would not enable\n", itsbase);
		itsbase = 0;
		return -1;
	}

	pcimsixintrenable = itsintrenable;
	print("its: at %#llux enabled, typer %#llux, lpi %d..%d, tables %s\n",
		itsbase, itstyper, Lpibase, Lpibase + Nlpi - 1,
		itscoherent ? "cached" : "uncached (cleaned by hand)");
	return 0;
}
