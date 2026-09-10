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
 * from constants: every entry of the firmware's memory map, which
 * archvirtarm64.c keeps whole beside the usable subset it puts in
 * conf.mem[], is mapped according to its type.  Below where RAM starts
 * is Device, the two PCIe windows above it are Device, and what the
 * firmware did not describe is not mapped at all.
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

	/*
	 * TCR_EL1 without its IPS field: TG0 4 KiB, SH0 inner shareable,
	 * ORGN0 and IRGN0 write-back write-allocate, EPD1 (no TTBR1),
	 * T0SZ 16 for a 48-bit virtual address.  IPS is added by
	 * ipsfield() below and is the only part of this word that is not
	 * a property of how the kernel wants to run.
	 */
	Tcrbase		= 0x00803510,
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
static uvlong mapmax;			/* one past the highest address mapped */

extern void mmuenable(void*, uvlong);
extern uvlong getmmfr0(void);

/*
 * TCR_EL1.IPS, which says how wide a physical address the translation
 * regime may produce.  Two things bound it and it must satisfy both.
 *
 * Below, the map: an IPS narrower than the highest address mapped
 * makes every access to the top of it an address size fault, so the
 * high PCIe window at 0x8000000000 needs at least 40 bits.  Above,
 * the core: ID_AA64MMFR0_EL1.PARange is what it implements, and
 * writing an IPS larger than that is CONSTRAINED UNPREDICTABLE -- an
 * implementation may treat it as PARange or may fault, and neither is
 * something to find out on a machine that is not here.  This was a
 * hard-coded 4 (44 bits), which is neither of those numbers: it was
 * chosen because it covered the map, and it happens to be within
 * PARange on Cortex-A72 and on QEMU, which is the whole of the
 * evidence there was for it.
 *
 * The encoding is shared between the two registers, which is what
 * makes the comparison a comparison of field values.
 */
static int
ipsfield(void)
{
	static int pabits[8] = {32, 36, 40, 42, 44, 48, 52, 56};
	int need, have;

	have = (int)(getmmfr0() & 0xf);
	if(have > 7)
		have = 7;			/* reserved: assume the widest named */
	for(need = 0; need < 7; need++)
		if(mapmax <= (uvlong)1<<pabits[need])
			break;
	if(need > have){
		/*
		 * The map asks for more address than the core can make.
		 * Said out loud rather than clamped quietly: what follows
		 * is address size faults on whatever lives up there, and
		 * the print is the only thing that will connect the two.
		 */
		print("mmu: map needs %d physical address bits, cpu has %d\n",
			pabits[need], pabits[have]);
		need = have;
	}
	return need;
}

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
	if(top > mapmax)
		mapmax = top;
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
	uvlong ptlo, pthi, base, top, unmapped;
	int i, type, ips;

	if(!Mmuon)
		return;

	unmapped = 0;
	mapmax = 0;
	tables = (uvlong*)(((uintptr)tablemem + (Tblblock-1)) & ~((uintptr)Tblblock-1));
	l0 = newtable();

	/*
	 * Everything below where RAM starts is device registers on this
	 * machine -- the GIC at 0x08000000, the PL011 and PL031, the
	 * virtio-mmio slots, and the low PCIe MMIO window that every BAR
	 * on this board is allocated out of.
	 */
	maprange(0, PHYSDRAM, Pdevice);

	/*
	 * Memory, entry by entry as the firmware described it.
	 *
	 * Not conf.mem[]: that holds only the usable runs, and the ACPI
	 * tables acpiinit() reads are not in one of them.  And not a
	 * single span from PHYSDRAM to conf.topofmem, which is what this
	 * did and which happens to be right on this machine for the one
	 * reason that QEMU's virt has a single contiguous bank.  A
	 * machine whose RAM comes in two banks with an MMIO hole between
	 * them would have had the hole mapped Normal, and Normal memory
	 * permits speculative reads: a speculative read into a hole is an
	 * imprecise external abort, arriving with no address and nothing
	 * to blame.  That is a fault the emulator cannot produce and a
	 * real machine can, so it would have been found on the rented
	 * board and not here.
	 *
	 * Types 1 (usable), 3 (ACPI reclaim) and 4 (ACPI NVS) are memory
	 * and are mapped.  Type 2 is not: os/inferno/boot/efi/efi.c gives
	 * it to EfiMemoryMappedIO and EfiRuntimeServicesData alike, so a
	 * type-2 run is as likely to be a device aperture as it is to be
	 * firmware memory, and this kernel calls no runtime service.
	 * Anything left unmapped faults at the access rather than at some
	 * later consequence of it.
	 *
	 * maprange() rounds out to 2 MiB, so a firmware that put memory
	 * and registers within one 2 MiB block of each other would still
	 * spill.  Nothing does -- a DRAM bank's edges are megabyte-
	 * aligned on every machine this targets -- but a map that fine
	 * would want page-granular tables here, not a wider rounding.
	 */
	for(i = 0; archfwrun(i, &base, &top, &type); i++)
		if(type == 1 || type == 3 || type == 4)
			maprange(base, top, Pnormal);
		else
			unmapped += top - base;

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

	ips = ipsfield();
	print("mmu: %d tables, ram to %#llux, %llud KB firmware-reserved unmapped, ecam %#llux, top %#llux, ips %d\n",
		ntable, (uvlong)conf.topofmem, unmapped/1024,
		(uvlong)Ecambase, mapmax, ips);

	mmuenable(l0, Tcrbase | ((uvlong)ips<<32));
}
