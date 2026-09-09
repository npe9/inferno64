#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * Minimal identity MMU for QEMU raspi4b.  Same shape as the raspi3b
 * table -- 4KB granule, 39-bit VA, one L1 whose first entry points at a
 * 512-entry L2 of 2MB blocks -- with the gigabytes rearranged, because
 * on a BCM2711 the peripherals are not where a BCM2837 puts them.
 *
 * The Pi 3B has its peripheral window inside the first gigabyte, at
 * 0x3f000000, so the L2 could carry it and the L1 needed only two
 * entries: 0-1GB through the L2, and 1-2GB as one device block for the
 * BCM2836 per-core registers.  On a Pi 4 the peripherals are at
 * 0xfe000000 and the ARM control block, which holds the GIC, at
 * 0xff800000 -- both in the fourth gigabyte, and neither reachable
 * from a table that stops at 2GB.  That is not a subtle failure: the
 * MMU comes on and the next peripheral touch is a fault, which is
 * exactly where this port first stopped.
 *
 * So: 0-1GB through the L2 as RAM, 1-2GB as RAM too (this board has
 * 2GB and the Pi 4 has no per-core block there), and 3-4GB as one
 * device block covering the peripherals and the ARM control block
 * together.  The third gigabyte is left unmapped; nothing is there.
 */

enum {
	/*
	 * On.  RAM is Normal write-back inner-shareable, which is what makes
	 * the kernel's LDXR/STXR spinlocks sound (exclusives are unpredictable
	 * on Device memory), and the page tables themselves are mapped
	 * read-only so a wild store to them faults at the store with state
	 * intact.  That read-only tripwire is what localised the tick-time
	 * corruption to an unbounded copy walking upward into the page tables;
	 * the root cause (vectrap's trap() arg-home overwriting the saved R1,
	 * see l.s) is fixed, so the tripwire now stands as cheap defence in
	 * depth rather than a live probe.
	 */
	Mmuon	= 1,

	L2SHIFT	= 21,			/* 2MB block */
	Pvalid	= 1<<0,
	Pblock	= 0<<1,			/* at L1/L2: block descriptor */
	Ptable	= 3,			/* table descriptor (0b11) */
	Paf	= 1<<10,		/* access flag */
	Pshin	= 3<<8,			/* inner shareable */
	Prw	= 0<<6,			/* EL1 read/write */
	Pdev	= 0<<2,			/* MAIR index 0: Device-nGnRnE */
	Pmem	= 1<<2,			/* MAIR index 1: Normal WB cacheable */

	Pnormal	= Pvalid|Pblock|Paf|Pshin|Prw|Pmem,	/* 0x705 */
	Pro	= 1<<7,			/* AP[2]: read-only at EL1 */
	Pdevice	= Pvalid|Pblock|Paf|Prw|Pdev,		/* 0x401 */
};

/* 2MB of page-table memory so the block holding it can be marked RO */
static uchar ptpages[2*0x200000];

extern void mmuenable(void*);

void
mmuinit(void)
{
	uvlong *l1, *l2;
	uintptr pa, ptblk;
	int i;

	if(!Mmuon)
		return;			/* MMU off: identity/physical, board default */
	l1 = (uvlong*)(((uintptr)ptpages + 0x1fffff) & ~(uintptr)0x1fffff);
	l2 = l1 + 512;				/* next 4KB page, same 2MB block */
	ptblk = ((uintptr)l1) >> L2SHIFT;	/* the 2MB block the tables live in */

	for(i = 0; i < 512; i++){
		pa = (uintptr)i << L2SHIFT;
		/*
		 * No peripheral case here, unlike raspi3b: on this board
		 * the whole first gigabyte is RAM.
		 */
		if(i == ptblk)
			l2[i] = pa | Pnormal | Pro;	/* the page tables: RO, so a
							 * wild store to them faults AT
							 * the store, state intact */
		else
			l2[i] = pa | Pnormal;		/* RAM / unused */
	}

	l1[0] = (uintptr)l2 | Ptable;			/* 0-1GB via the L2 */
	l1[1] = (uvlong)0x40000000 | Pnormal;		/* 1-2GB: more RAM */
	l1[3] = (uvlong)0xc0000000 | Pdevice;		/* 3-4GB: peripherals
							 * at 0xfe000000 and the
							 * ARM control block,
							 * with the GIC, at
							 * 0xff800000 */

	mmuenable(l1);
}
