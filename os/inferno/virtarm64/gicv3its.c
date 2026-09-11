#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/pci.h"

/*
 * The GICv3 Interrupt Translation Service, which is how a GICv3 board
 * does MSI.
 *
 * This is the other half of item 1 in doc/inferno-driver-plan.ms.  A
 * GICv2 board gets MSI from a v2m frame (gicv2m.c): one register, a
 * fixed block of SPIs, nothing to program per device.  A GICv3 has no
 * frame -- QEMU's hw/arm/virt.c create_gic() instantiates a v2m for
 * gic-version=2 and an ITS for gic-version=3, never both -- and the
 * ITS is a different shape entirely: a command queue in memory, a
 * device table, a collection table, a per-device interrupt translation
 * table, and a class of interrupt (LPIs, INTID 8192 and up) that does
 * not exist on a v2 at all.
 *
 * The chain a device's write travels:
 *
 *	device writes its EventID to GITS_TRANSLATER
 *	  -> ITS looks up DeviceID (from the bus RID) in the device table
 *	  -> that gives an ITT; EventID indexes it
 *	  -> the ITT entry gives an LPI INTID and a collection (ICID)
 *	  -> the collection table maps ICID to a redistributor
 *	  -> the redistributor makes that LPI pending for its cpu
 *
 * So four things must be set up before a single MSI can land: the
 * redistributor has to have LPIs enabled with a configuration table
 * and a pending table; the ITS has to have its tables and its command
 * queue; the collection has to be mapped to this cpu (MAPC); and the
 * device has to have an ITT mapped (MAPD) with one entry per vector
 * (MAPTI).  None of that is optional and none of it is discoverable
 * from the device -- which is why this file is four hundred lines and
 * gicv2m.c is one hundred and fifty.
 *
 * Everything here is sized from what the hardware reports, not from
 * what QEMU happens to provide: GITS_TYPER gives the ITT entry size,
 * the DeviceID width and whether RDBASE is a processor number or a
 * redistributor address, and GITS_BASER gives each table's entry size.
 * A real ITS differs from QEMU's in all of those.
 */

/*
 * Every bit above 31 here is written as a full-width hex literal,
 * because the enum this file started with silently threw those bits
 * away.  An enum constant is an int in this compiler, so "1<<63" and
 * "1<<59" inside an enum are both zero, with no diagnostic.  The
 * symptom was a device that appeared to accept some of the bits: the
 * first GITS_BASER write went out as 0x0107000004d271400 -- type and
 * entry size right, bit 10 right, bits 59 and 63 gone -- the ITS
 * stored exactly what it was given, and the only complaint anywhere
 * was a table that would not turn valid.
 *
 * Two forms that do work, checked by reading what 7c -S emits for
 * them, are "1ULL<<63" and "(uvlong)1<<63", in an enum or out of it.
 * An earlier draft of this comment said neither did.  That was wrong,
 * and wrong for a reason worth writing down: the test that "proved"
 * it was run against a gicv3its.7 that mk had not rebuilt, because
 * the source's mtime had not moved.  Same failure as a boardsuite arm
 * booting yesterday's kernel -- the measurement was of the old code.
 * The hex literals stay because they are the form that cannot be
 * narrowed by anything, but the reason is taste, not necessity.
 *
 * The one real trap left, which this file does not hit but a 64-bit
 * register composed anywhere else in the tree will: an enum member of
 * "1<<31" is the int -2147483648, so casting it to a uvlong sign
 * extends it to 0xFFFFFFFF80000000 rather than giving 0x80000000.
 */
#define	BaserValid	0x8000000000000000ULL
#define	BaserIndirect	0x4000000000000000ULL
#define	BaserInner	0x0800000000000000ULL	/* InnerCache = cacheable */
#define	BaserShare	0x0000000000000400ULL	/* inner shareable */
#define	CbaserValid	0x8000000000000000ULL
#define	CmdValid	0x8000000000000000ULL
#define	Propcache	0x0000000000000480ULL	/* PROPBASER/PENDBASER bits 7,10 */
#define	Pagemask	0xFFFFFFFFFFFFF000ULL
#define	Bigpagemask	0xFFFFFFFFFFFF0000ULL
#define	Ittmask		0xFFFFFFFFFFFFFF00ULL

enum {
	/* GITS control page (arm_gicv3_its_common.h) */
	GitsCTLR	= 0x0000,
	GitsIIDR	= 0x0004,
	GitsTYPER	= 0x0008,
	GitsCBASER	= 0x0080,
	GitsCWRITER	= 0x0088,
	GitsCREADR	= 0x0090,
	GitsBASER	= 0x0100,	/* eight 64-bit registers */
	Nbaser		= 8,

	/* GITS translation page: one 64K page past the control page */
	GitsTRANSLATER	= 0x0040,

	GitsCTLR_En	= 1<<0,
	GitsCTLR_Quiescent = 1u<<31,

	/* GITS_TYPER */
	TyperPhysical	= 1<<0,
	TyperIttShift	= 4,		/* [7:4] entry size minus one */
	TyperIdShift	= 8,		/* [12:8] LPI ID bits minus one */
	TyperDevShift	= 13,		/* [17:13] DeviceID bits minus one */
	TyperPta	= 1<<19,	/* RDBASE is an address, not a number */

	/* GITS_BASER */
	BaserTypeShift	= 56,		/* [58:56] */
	BaserEntShift	= 48,		/* [52:48] entry size minus one */
	BaserPage4K	= 0,
	BaserTypeDevice	= 1,
	BaserTypeCollection = 4,

	/* commands */
	CmdMOVI		= 0x01,
	CmdINT		= 0x03,
	CmdCLEAR	= 0x04,
	CmdSYNC		= 0x05,
	CmdMAPD		= 0x08,
	CmdMAPC		= 0x09,
	CmdMAPTI	= 0x0A,
	CmdINV		= 0x0C,
	CmdDISCARD	= 0x0F,

	/* redistributor LPI registers, RD_base relative */
	GicrCTLR	= 0x0000,
	GicrTYPER	= 0x0008,
	GicrPROPBASER	= 0x0070,
	GicrPENDBASER	= 0x0078,
	GicrCTLR_EnableLPIs = 1<<0,
	GicrCTLR_RWP	= 1<<3,
	GicrTYPER_PLPIS	= 1<<0,

	/*
	 * What goes in GICR_PROPBASER.IDbits, which is already a
	 * minus-one field: the largest INTID the redistributor will
	 * accept is 2^(IDbits+1) - 1.  So 13 spans 8192..16383 and
	 * costs an 8K configuration table, since the table is indexed
	 * from 8192 and its size is 2^(IDbits+1) - 8192.  Asking for
	 * the 16 bits QEMU offers would cost 120K to address vectors
	 * this kernel will never allocate.
	 *
	 * Writing IDbits-1 here, on the theory that the field wanted
	 * the count rather than the count minus one, caps the largest
	 * INTID at 8191 -- one below the first LPI there is.  The ITS
	 * then translates every event correctly, the trace shows the
	 * device ringing the doorbell and the tables being walked, and
	 * the redistributor silently drops the result because the
	 * INTID is out of its range.  Nothing anywhere reports it.
	 */
	Idbits		= 13,
	Nlpi		= (1<<(Idbits+1)) - GicLpiBase,	/* 8192 */

	/* one 4K page each; a flat table, never indirect */
	Tablepages	= 1,
	Cmdpages	= 1,
	Ncmd		= (Cmdpages*4096) / 32,

	Nevent		= 32,		/* ITT entries per device */
	Ndev		= 32,		/* devices this driver will map */
};

static uchar	*its;			/* GITS control page */
static uvlong	itsphys;
static uvlong	itstranslate;		/* physical GITS_TRANSLATER */
static uchar	*cmdq;			/* command queue */
static uvlong	cmdqphys;
static int	cmdw;			/* our write index */
static uchar	*lpiconf;		/* LPI configuration table */
static int	ittsize;		/* bytes per ITT entry */
static int	devbits;
static int	pta;			/* GITS_TYPER.PTA */
static Lock	itslock;

/*
 * The next free LPI INTID.  Set to GicLpiBase at init, not here: LPI
 * INTIDs start at 8192 and zero is not one of them, so leaving this at
 * its static zero handed the first caller INTID 0 and the ITS refused
 * the MAPTI with "invalid interrupt ID 0x0" -- which is the whole
 * reason to boot QEMU with -d guest_errors while writing this, since
 * a silently unmapped event and a correctly mapped one that never
 * fires look identical from the guest.
 */
static int	nextlpi;
static ulong	mappeddev[Ndev];	/* DeviceIDs given an ITT */
static int	nmapped;
static int	nextevent[Ndev];

/* the PCI RID-to-DeviceID window from the host bridge's msi-map */
static ulong	msiridbase, msidevbase, msimaplen;
static int	havemsimap;
static int	acpimsimap;		/* the IORT's windows, not the tree's */

/*
 * One command is four 64-bit words.  The queue is a ring; the ITS
 * consumes up to GITS_CWRITER and reports progress in GITS_CREADR, so
 * a command is "done" when CREADR has passed it.  SYNC is the only
 * ordering guarantee the architecture gives between a mapping command
 * and the first interrupt that depends on it, so every sequence here
 * ends with one.
 */
static void
itscmd(uvlong w0, uvlong w1, uvlong w2, uvlong w3)
{
	uvlong *c;
	ulong next;

	c = (uvlong*)(cmdq + cmdw*32);
	c[0] = w0;
	c[1] = w1;
	c[2] = w2;
	c[3] = w3;
	coherence();

	next = (cmdw + 1) % Ncmd;
	cmdw = next;
	*(uvlong*)(its + GitsCWRITER) = (uvlong)next * 32;
	coherence();
}

static void
itswait(void)
{
	ulong target;
	int i;

	target = (ulong)cmdw * 32;
	for(i = 0; i < 1000000; i++){
		if((*(uvlong*)(its + GitsCREADR) & 0xFFFE0) == target)
			return;
	}
	print("gicv3its: command queue did not drain (CREADR %#llux want %#lux)\n",
		*(uvlong*)(its + GitsCREADR), target);
}

/*
 * RDBASE for MAPC and SYNC.  With GITS_TYPER.PTA clear it is a
 * processor number, and with it set the physical address of the
 * redistributor's RD_base.  QEMU is the former and real parts are
 * often the latter, so read the bit rather than assume: this kernel is
 * uniprocessor, so the answer is cpu 0 either way, but the two are not
 * the same number and a board that wanted the address would deliver
 * nothing at all.
 */
static uvlong
rdbase(void)
{
	if(pta)
		return PADDR(GICR) >> 16 << 16;
	return 0;			/* processor number of cpu 0 */
}

static void
mapcollection(void)
{
	uvlong w2;

	/* MAPC: collection 0 -> this cpu's redistributor, valid */
	w2 = rdbase() << 16;
	w2 |= 0;			/* ICID 0 */
	w2 |= CmdValid;
	itscmd(CmdMAPC, 0, w2, 0);
	itscmd(CmdSYNC, 0, rdbase() << 16, 0);
	itswait();
}

/*
 * Allocate and publish one of the ITS's own tables.  GITS_BASER is
 * write-any-read-back: the entry size and type are read-only fields
 * the hardware fills in, and the shareability and cacheability bits
 * may read back different from what was written -- the architecture
 * says to honour what comes back, because a part that cannot do
 * inner-shareable will quietly downgrade and then expect the software
 * to have noticed.  QEMU does not care; silicon does.
 */
static int
itstable(int type)
{
	uvlong *baser, v;
	uchar *mem;
	int i, entsize;

	for(i = 0; i < Nbaser; i++){
		baser = (uvlong*)(its + GitsBASER + 8*i);
		v = *baser;
		if(((v >> BaserTypeShift) & 7) != type)
			continue;
		entsize = ((v >> BaserEntShift) & 0x1f) + 1;
		mem = xspanalloc(Tablepages*4096, 4096, 0);
		if(mem == nil)
			return -1;
		memset(mem, 0, Tablepages*4096);
		coherence();
		/*
		 * Assembled one OR at a time into the uvlong, which is
		 * how it was debugged and reads better than the one
		 * expression it could be: each line is one field of one
		 * register, in the order the architecture lists them.
		 */
		v = PADDR(mem) & Pagemask;
		v |= (uvlong)type << BaserTypeShift;
		v |= (uvlong)(entsize-1) << BaserEntShift;
		v |= (uvlong)(Tablepages - 1);
		v |= BaserPage4K;
		v |= BaserShare;
		v |= BaserInner;
		v |= BaserValid;
		*baser = v;
		coherence();
		v = *baser;			/* what the part accepted */
		if((v & BaserValid) == 0){
			print("gicv3its: BASER%d type %d refused\n", i, type);
			return -1;
		}
		if(v & BaserIndirect){
			print("gicv3its: BASER%d came back indirect; unsupported\n", i);
			return -1;
		}
		return 0;
	}
	return type == BaserTypeDevice ? -1 : 0;	/* collection may be implicit */
}

/*
 * Give this cpu's redistributor an LPI configuration table and a
 * pending table and turn LPIs on.  Both are ordinary memory the
 * redistributor reads; the configuration table is one byte per LPI
 * (priority in [7:2], enable in bit 0) and the pending table one bit.
 *
 * The pending table must be 64K aligned and is allocated at 64K
 * whatever Idbits says, because that is the architectural minimum and
 * the saving from a smaller one is not worth the arithmetic.
 */
static int
lpienable(void)
{
	uchar *rd, *pend;
	u32int typer;

	rd = (uchar*)GICR;
	typer = *(u32int*)(rd + GicrTYPER);
	if((typer & GicrTYPER_PLPIS) == 0){
		print("gicv3its: redistributor reports no physical LPIs\n");
		return -1;
	}
	if(*(u32int*)(rd + GicrCTLR) & GicrCTLR_EnableLPIs){
		print("gicv3its: LPIs already enabled; not reprogramming\n");
		return -1;
	}

	lpiconf = xspanalloc(Nlpi, 4096, 0);
	pend = xspanalloc(64*1024, 64*1024, 0);
	if(lpiconf == nil || pend == nil)
		return -1;
	memset(lpiconf, 0, Nlpi);
	memset(pend, 0, 64*1024);
	coherence();

	*(uvlong*)(rd + GicrPROPBASER) = (PADDR(lpiconf) & Pagemask)
		| Idbits | Propcache;		/* inner cacheable, shareable */
	*(uvlong*)(rd + GicrPENDBASER) = (PADDR(pend) & Bigpagemask)
		| Propcache;
	coherence();
	*(u32int*)(rd + GicrCTLR) |= GicrCTLR_EnableLPIs;
	coherence();
	while(*(u32int*)(rd + GicrCTLR) & GicrCTLR_RWP)
		;
	return 0;
}

/*
 * The DeviceID a PCI function presents to the ITS.  It is the bus RID
 * -- bus, device, function -- put through the host bridge's msi-map,
 * which on QEMU's virt is the identity over the whole bus range but on
 * real hardware need not be, and on a machine with several segments is
 * not even unique without it.  Read rather than assumed for that
 * reason; without a msi-map the identity is the only thing left to
 * guess.
 */
static ulong
ridtodevid(Pcidev *p)
{
	ulong rid;

	rid = (BUSBNO(p->tbdf) << 8) | (BUSDNO(p->tbdf) << 3) | BUSFNO(p->tbdf);
	if(acpimsimap){
		extern int acpiridtodevid(ulong, ulong*);
		ulong devid;

		/*
		 * Several windows, not one: a root complex in front of an
		 * SMMU has a mapping per SMMU as well as whatever it sends
		 * straight to the ITS, and the composed answers do not
		 * form a single range.  Not covered is refused, for the
		 * reason in the comment above.
		 */
		if(acpiridtodevid(rid, &devid))
			return devid;
		return ~0UL;
	}
	if(havemsimap){
		if(rid < msiridbase || rid >= msiridbase + msimaplen)
			return ~0UL;
		return msidevbase + (rid - msiridbase);
	}
	return rid;
}

static int
mapdevice(ulong devid)
{
	uchar *itt;
	uvlong w2;
	int i;

	for(i = 0; i < nmapped; i++)
		if(mappeddev[i] == devid)
			return i;
	if(nmapped >= Ndev || devid >= (1UL<<devbits))
		return -1;

	/*
	 * The ITT is indexed by EventID and its entry size is the one
	 * GITS_TYPER reported, not a constant: QEMU says twelve bytes,
	 * parts exist that say eight or sixteen.  256-byte aligned
	 * because MAPD's address field starts at bit 8.
	 */
	itt = xspanalloc(Nevent*ittsize, 256, 0);
	if(itt == nil)
		return -1;
	memset(itt, 0, Nevent*ittsize);
	coherence();

	/* MAPD: size is log2(number of EventIDs) minus one */
	w2 = PADDR(itt) & Ittmask;
	w2 |= CmdValid;
	itscmd(CmdMAPD | ((uvlong)devid << 32), 4, w2, 0);	/* 2^(4+1) events */
	itscmd(CmdSYNC, 0, rdbase() << 16, 0);
	itswait();

	i = nmapped++;
	mappeddev[i] = devid;
	nextevent[i] = 0;
	return i;
}

/*
 * The pcimsirouter for this board.  Hands back the address and data a
 * device must write, and the INTID that write will arrive as.
 */
static int
itsrouter(Pcidev *p, uvlong *addr, ulong *data)
{
	ulong devid;
	int slot, event, lpi;

	if(p == nil)
		return -1;
	devid = ridtodevid(p);
	if(devid == ~0UL)
		return -1;

	ilock(&itslock);
	/*
	 * Two limits, and trap.c's is the tighter one.  lpiconf has a
	 * byte for every INTID the redistributor will accept, but the
	 * dispatch table in trap.c holds GicLpiMax of them and
	 * intrenable() panics on one it cannot reach.  Refusing here
	 * turns that panic into a negative return, which is what
	 * pcimsixintr() reads as "no vector" before falling back to
	 * INTx.  Two devices do not come near either limit; a board with
	 * a multiqueue NIC on it would.
	 */
	if(nextlpi >= GicLpiBase + Nlpi || nextlpi - GicLpiBase >= GicLpiMax){
		iunlock(&itslock);
		return -1;
	}
	slot = mapdevice(devid);
	if(slot < 0 || nextevent[slot] >= Nevent){
		iunlock(&itslock);
		return -1;
	}
	event = nextevent[slot]++;
	lpi = nextlpi++;

	/* enable it in the configuration table before it can be raised */
	lpiconf[lpi - GicLpiBase] = (0xa0 & 0xfc) | 1;
	coherence();

	/* MAPTI: (devid, event) -> LPI, collection 0 */
	itscmd(CmdMAPTI | ((uvlong)devid << 32),
		(uvlong)event | ((uvlong)lpi << 32), 0, 0);
	/* INV: the redistributor may have cached the old config byte */
	itscmd(CmdINV | ((uvlong)devid << 32), (uvlong)event, 0, 0);
	itscmd(CmdSYNC, 0, rdbase() << 16, 0);
	itswait();
	iunlock(&itslock);

	*addr = itstranslate;
	*data = event;
	return lpi;
}

/*
 * The host bridge's msi-map, read from the device tree.  Four cells:
 * RID base, the MSI controller's phandle, DeviceID base, length.  Only
 * a single-entry map is handled, which is what every machine this
 * kernel boots emits; a bridge with several windows would need the
 * phandle compared against the ITS node's, and this says so rather
 * than pretending the first entry is always right.
 */
static void
readmsimap(void)
{
	extern int fdtu32array(char*, char*, u32int*, int);
	u32int cells[8];
	int n;

	n = fdtu32array("pci-host-ecam-generic", "msi-map", cells, nelem(cells));
	if(n < 4){
		/*
		 * The IORT says what the msi-map property says and more of
		 * it: a list of windows rather than one, because a root
		 * complex with an SMMU in front of it needs its mappings
		 * composed with the SMMU's and the result is not a single
		 * range.  acpiarm.c does the composing; this only asks
		 * whether there is anything to ask.  A machine with tables
		 * and no tree is the whole reason either is read.
		 */
		extern int acpinwindow(void);

		if(acpinwindow() > 0)
			acpimsimap = 1;
		return;
	}
	if(n > 4)
		print("gicv3its: msi-map has %d cells; using the first window\n", n);
	msiridbase = cells[0];
	msidevbase = cells[2];
	msimaplen = cells[3];
	havemsimap = 1;
}

void
gicv3itsinit(void)
{
	extern int fdtreg(char*, uvlong*, uvlong*);
	extern uvlong acpiits(void);
	uvlong base, size, typer, v;

	/*
	 * The device tree first, then the MADT.  Both describe the same
	 * part and a machine has one or the other: QEMU booted with
	 * -kernel has only a tree, a SystemReady machine has only tables,
	 * and a QEMU booted through UEFI happens to have both.  The order
	 * between them is arbitrary because of that; the tree comes first
	 * only because it is what every board here was using already.
	 *
	 * The MADT carries no size, because an ITS is architecturally
	 * two 64K pages and there is nothing to say.  fdtreg() gives a
	 * size that is already clamped up to the same thing below.
	 */
	base = 0;
	size = 0;
	if(!fdtreg("arm,gic-v3-its", &base, &size) || base == 0){
		base = acpiits();
		size = 0;
	}
	if(base == 0)
		return;
	if(size < 0x20000)
		size = 0x20000;
	if((its = vmap(base, size)) == nil)
		return;
	itsphys = base;

	typer = *(uvlong*)(its + GitsTYPER);
	if((typer & TyperPhysical) == 0){
		print("gicv3its: no physical LPI support\n");
		its = nil;
		return;
	}
	ittsize = ((typer >> TyperIttShift) & 0xf) + 1;
	devbits = ((typer >> TyperDevShift) & 0x1f) + 1;
	pta = (typer & TyperPta) != 0;

	/*
	 * The translation register lives in the second 64K page of the
	 * ITS, not the control page -- hw/arm/virt.c computes the same
	 * address for its IOMMU reserved-region property.
	 */
	itstranslate = base + 0x10000 + GitsTRANSLATER;

	if(lpienable() < 0){
		its = nil;
		return;
	}

	/* quiesce before touching the tables, as the architecture asks */
	*(u32int*)(its + GitsCTLR) &= ~GitsCTLR_En;
	coherence();

	if(itstable(BaserTypeDevice) < 0 || itstable(BaserTypeCollection) < 0){
		its = nil;
		return;
	}

	cmdq = xspanalloc(Cmdpages*4096, 4096, 0);
	if(cmdq == nil){
		its = nil;
		return;
	}
	memset(cmdq, 0, Cmdpages*4096);
	coherence();
	cmdqphys = PADDR(cmdq);
	v = cmdqphys & Pagemask;
	v |= (uvlong)(Cmdpages - 1);
	v |= BaserShare;
	v |= BaserInner;
	v |= CbaserValid;
	*(uvlong*)(its + GitsCBASER) = v;
	*(uvlong*)(its + GitsCWRITER) = 0;
	cmdw = 0;
	coherence();

	*(u32int*)(its + GitsCTLR) |= GitsCTLR_En;
	coherence();

	nextlpi = GicLpiBase;
	mapcollection();
	readmsimap();

	print("its: gicv3 @ %#llux translate %#llux, %d devid bits, itt %d bytes,"
		" rdbase %s, lpi %d..%d, ITS-OK\n",
		base, itstranslate, devbits, ittsize,
		pta ? "address" : "procnum", GicLpiBase,
		GicLpiBase + (Nlpi < GicLpiMax ? Nlpi : GicLpiMax) - 1);

	pcimsirouter = itsrouter;
}

/* what the board reports about itself; see fdtreport() in main.c */
int
gicv3itspresent(void)
{
	return its != nil;
}
