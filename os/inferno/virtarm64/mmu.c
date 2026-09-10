#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * An identity MMU for QEMU's arm64 virt, and for the class of machine
 * it stands in for.
 *
 * The board ran with the MMU off, which is not merely slow: with
 * SCTLR_EL1.M clear every data access is Device-nGnRnE, and LDXR/STXR
 * on Device memory is CONSTRAINED UNPREDICTABLE -- the architecture
 * makes no promise the exclusive monitor works at all.  That is the
 * whole reason this exists: os/inferno/virtarm64/l.s's cmpswap, ainc,
 * adec and _tas are exclusive-monitor loops, and nothing above them is
 * sound on a real core until RAM is Normal write-back inner-shareable.
 * A second processor cannot be let near a run queue before then.
 *
 * Four levels and a 48-bit virtual address, where
 * os/inferno/raspi3b/mmu.c has three and 39 bits.  The reason is where
 * a server puts things: this machine's PCIe ECAM sits at 0x4010000000,
 * 256 GiB up, and QEMU's virt has a second, high PCIe MMIO window at
 * 0x8000000000, which 39 bits cannot reach at all.  No BAR lands in
 * that window today -- pciecam.c's own report says every one of them
 * is between 0x10000000 and 0x3fffffff -- but a machine with more
 * devices than QEMU's will use it, and a table level is cheaper than
 * finding out on rented hardware.
 *
 * The map is built from what the machine says about itself rather than
 * from constants: conf.mem[], which archvirtarm64.c fills from the
 * firmware's memory map, decides which 1 GiB blocks are RAM.
 * Everything else below the top of RAM, and the two PCIe windows above
 * it, is Device.
 */

enum {
	Mmuon	= 1,

	L1SHIFT	= 30,			/* 1GB block */
	L2SHIFT	= 21,			/* 2MB block */

	Pvalid	= 1<<0,
	Pblock	= 0<<1,			/* at L1/L2: block descriptor */
	Ptable	= 3,			/* table descriptor (0b11) */
	Paf	= 1<<10,		/* access flag */
	Pshin	= 3<<8,			/* inner shareable */
	Prw	= 0<<6,			/* EL1 read/write */
	Pdev	= 0<<2,			/* MAIR index 0: Device-nGnRnE */
	Pmem	= 1<<2,			/* MAIR index 1: Normal WB cacheable */
	Pro	= 1<<7,			/* AP[2]: read-only at EL1 */
	Pxn	= (uvlong)1<<54,	/* execute never */

	Pnormal	= Pvalid|Pblock|Paf|Pshin|Prw|Pmem,
	Pdevice	= Pvalid|Pblock|Paf|Prw|Pdev|Pxn,

	/*
	 * One 2 MiB block of tables, 2 MiB aligned, which is 512 of
	 * them.  Six are used on this machine and a few more on one with
	 * memory or devices spread further, so the size is not chosen
	 * for capacity: it is chosen so the tables occupy a whole block
	 * of their own and nothing else shares it.  That is what lets
	 * the block be mapped read-only.  The first attempt sized this
	 * array to what it needed and mapped the containing block
	 * read-only anyway, which made the kernel's own data read-only
	 * along with it and killed the machine at the SCTLR write.
	 */
	Tblblock = 2*1024*1024,
	Ntable	= Tblblock/(512*8),
	Nent	= 512,

	/*
	 * The two windows above RAM this machine puts PCIe in.  Named
	 * here rather than mapped blindly to the top of the address
	 * space: a Device mapping is not free -- it forbids speculation
	 * and unaligned access -- and mapping 256 TiB of nothing as
	 * Device to avoid naming two ranges is not a saving.
	 */
	Ecambase	= 0x4010000000ULL,
	Ecamsize	= 0x10000000ULL,
	Pciehigh	= 0x8000000000ULL,
	Pciehighsize	= 0x8000000000ULL,
};

/*
 * Twice the block, so the base can be rounded up to a 2 MiB boundary
 * at run time: kencc has no alignment attribute.  The same arrangement
 * os/inferno/raspi3b/mmu.c uses.
 */
static uchar tablemem[2*Tblblock];
static uvlong *tables;
static int ntable;
static uvlong *l0;

extern void mmuenable(void*);

static uvlong*
newtable(void)
{
	uvlong *t;

	if(ntable >= Ntable)
		panic("mmuinit: out of page tables (Ntable %d)", Ntable);
	t = tables + ntable*Nent;
	memset(t, 0, Nent*sizeof(uvlong));
	ntable++;
	return t;
}

/*
 * The table one level down from ent, made if it is not there yet.
 *
 * A slot that already holds a block descriptor is split rather than
 * refused: the same physical range, described by 512 blocks one level
 * down with the attributes it already had, so the split changes
 * nothing until the caller writes into it.  This is not a nicety.  A
 * map built from a firmware memory map arrives in whatever order the
 * firmware listed it, and whether a 1 GiB block is created before or
 * after something needs 2 MiB granularity inside it is not the
 * caller's to control: on the -kernel path this board's RAM ends at
 * 0x50000000 and every mapping is 2 MiB, and under UEFI with -m 1024
 * it ends at 0x80000000, one whole 1 GiB block -- so the read-only
 * mapping of the page tables, which lands inside it, panicked on the
 * second machine and not the first.
 *
 * shift is the size of the blocks the new table will hold.
 */
static uvlong*
subtable(uvlong *ent, int shift)
{
	uvlong *t, pa, attr;
	int i;

	if(*ent != 0 && (*ent & 3) == Ptable)
		return (uvlong*)(uintptr)(*ent & 0x0000FFFFFFFFF000ULL);
	t = newtable();
	if(*ent != 0){
		pa = *ent & 0x0000FFFFFFFFF000ULL;
		attr = *ent & ~0x0000FFFFFFFFF000ULL;
		for(i = 0; i < Nent; i++)
			t[i] = (pa + ((uvlong)i<<shift)) | attr;
	}
	*ent = (uintptr)t | Ptable;
	return t;
}

/*
 * Map [base, top) with attr.  Identity, so the virtual address is the
 * physical one.  2 MiB blocks below the first GiB, where this machine
 * mixes device registers and RAM at that granularity, and 1 GiB blocks
 * above it.
 */
static void
maprange(uvlong base, uvlong top, uvlong attr)
{
	uvlong pa, *l1, *l2;
	int i;

	/*
	 * Down to the 2 MiB block below and up to the one above.  This
	 * line read "base &= ~((uvlong)1<<L2SHIFT)-1", which is not that
	 * mask: unary ~ binds tighter than -, so it cleared bit 21 and
	 * bit 0 of the address and left everything else, and a base of
	 * 0x40200000 came out as 0x40000000.  For the ranges whose base
	 * was already aligned it did no harm and for the RAM runs it only
	 * mapped a little extra; the one call it broke was the read-only
	 * mapping of the page tables, which landed on the block holding
	 * the kernel's own text and stack and killed the machine at the
	 * SCTLR write.
	 */
	base &= ~(((uvlong)1<<L2SHIFT)-1);
	top = (top + (((uvlong)1<<L2SHIFT)-1)) & ~(((uvlong)1<<L2SHIFT)-1);
	for(pa = base; pa < top; ){
		l1 = subtable(&l0[(pa >> 39) & (Nent-1)], L1SHIFT);
		i = (pa >> L1SHIFT) & (Nent-1);
		if(pa < (1ULL<<L1SHIFT)
		|| (pa & (((uvlong)1<<L1SHIFT)-1)) != 0
		|| top - pa < (1ULL<<L1SHIFT)){
			l2 = subtable(&l1[i], L2SHIFT);
			l2[(pa >> L2SHIFT) & (Nent-1)] = pa | attr;
			pa += (uvlong)1<<L2SHIFT;
		}else{
			l1[i] = pa | attr;
			pa += (uvlong)1<<L1SHIFT;
		}
	}
}

void
mmuinit(void)
{
	uvlong ptlo, pthi;
	int i;

	if(!Mmuon)
		return;

	tables = (uvlong*)(((uintptr)tablemem + (Tblblock-1)) & ~((uintptr)Tblblock-1));
	l0 = newtable();

	/*
	 * Everything below where RAM starts is device registers on this
	 * machine -- the GIC at 0x08000000, the PL011 and PL031, the
	 * virtio-mmio slots, and the low PCIe MMIO window that every BAR
	 * on this board is allocated out of.
	 */
	maprange(0, PHYSDRAM, Pdevice);

	/* RAM, as the firmware described it */
	for(i = 0; i < nelem(conf.mem); i++)
		if(conf.mem[i].npage != 0)
			maprange(conf.mem[i].base,
				conf.mem[i].base + (uvlong)conf.mem[i].npage*BY2PG,
				Pnormal);

	/*
	 * The gaps between those runs are the firmware's own reserved
	 * regions -- ACPI tables among them, which acpiinit() reads --
	 * so they are mapped too, as Normal: they are memory, this
	 * kernel only reads them, and leaving them unmapped would fault
	 * on the next table walk rather than protect anything.
	 */
	maprange(PHYSDRAM, conf.topofmem, Pnormal);

	maprange(Ecambase, Ecambase + Ecamsize, Pdevice);
	maprange(Pciehigh, Pciehigh + Pciehighsize, Pdevice);

	/*
	 * The page tables themselves read-only, so a wild store into
	 * them faults at the store with the state intact rather than
	 * corrupting the map and failing somewhere else later.  Same
	 * tripwire os/inferno/raspi3b/mmu.c keeps, and it is what
	 * localised that board's tick-time corruption.  Done last,
	 * over-writing the Normal mapping the RAM loop just made.
	 */
	ptlo = (uintptr)tables;
	pthi = ptlo + Tblblock;
	maprange(ptlo, pthi, Pnormal|Pro);

	print("mmu: %d tables, ram to %#llux, ecam %#llux, pcie-high %#llux\n",
		ntable, (uvlong)conf.topofmem, (uvlong)Ecambase, (uvlong)Pciehigh);

	mmuenable(l0);
}
