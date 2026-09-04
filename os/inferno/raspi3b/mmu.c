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
	 * Off by default: the board is stable MMU-off, and turning the MMU
	 * on does not fix the tick-time SD corruption - it changes its
	 * shape.  It is kept because it is the diagnostic that pinned the
	 * mechanism: with the MMU on, the corruption's residual failures
	 * fault as a level-1 translation abort at a RAM address, i.e. the
	 * store's base register was corrupted and the store landed on the
	 * page table (a wild store), where MMU-off had only shown a lost
	 * SDDATA write.  Set Mmuon to 1 (and enable the timer routing) to
	 * resume that hunt.  See doc/raspi3b-preempt-plan.ms.
	 */
	Mmuon	= 0,

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
	Pdevice	= Pvalid|Pblock|Paf|Prw|Pdev,		/* 0x401 */
};

/* two page-table pages plus slack to 4KB-align by hand (no __attribute__) */
static uchar ptpages[3*4096];

extern void mmuenable(void*);

void
mmuinit(void)
{
	uvlong *l1, *l2;
	uintptr pa;
	int i;

	if(!Mmuon)
		return;			/* MMU off: identity/physical, board default */
	l1 = (uvlong*)(((uintptr)ptpages + 4095) & ~(uintptr)4095);
	l2 = l1 + 512;

	for(i = 0; i < 512; i++){
		pa = (uintptr)i << L2SHIFT;
		if(pa >= BCMPERIPH && pa < 0x40000000)
			l2[i] = pa | Pdevice;		/* peripherals */
		else
			l2[i] = pa | Pnormal;		/* RAM / unused */
	}

	l1[0] = (uintptr)l2 | Ptable;			/* 0-1GB via the L2 */
	l1[1] = (uvlong)0x40000000 | Pvalid | Pblock | Paf | Prw | Pdev;
							/* 1-2GB 1GB block: BCM2836 */

	mmuenable(l1);
}
