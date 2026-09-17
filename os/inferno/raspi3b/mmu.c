#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * Minimal identity MMU for QEMU raspi3b.  The board ran with the MMU off
 * (all of RAM uncached, every access Device-nGnRnE), which is both slow
 * and the setting under which a timer IRQ taken inside the SDHOST FIFO
 * loop corrupts a transfer.  This maps a flat identity space: RAM (and
 * the unused window below the peripherals) as Normal write-back
 * cacheable, the BCM2835 peripheral window as Device, and the BCM2836
 * per-core block above 1GB as Device.  4KB granule, 39-bit VA, one L1
 * table whose first entry points at a 512-entry L2 of 2MB blocks.
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
		if(pa >= BCMPERIPH && pa < 0x40000000)
			l2[i] = pa | Pdevice;		/* peripherals */
		else if(pa == 0x20000000)
			l2[i] = pa | Pdevice;		/* crumb RAM (l.s crumbentry, trap.c):
							 * uncached, so a store lands in
							 * DRAM before a watchdog reset */
		else if(i == ptblk)
			l2[i] = pa | Pnormal | Pro;	/* the page tables: RO, so a
							 * wild store to them faults AT
							 * the store, state intact */
		else
			l2[i] = pa | Pnormal;		/* RAM / unused */
	}

	l1[0] = (uintptr)l2 | Ptable;			/* 0-1GB via the L2 */
	l1[1] = (uvlong)0x40000000 | Pvalid | Pblock | Paf | Prw | Pdev;
							/* 1-2GB 1GB block: BCM2836 */

	/* ARMv8 reset leaves cache contents UNKNOWN; do this before SCTLR.C. */
	cacheinit();
	mmuenable(l1);
}
