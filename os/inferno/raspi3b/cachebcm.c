/*
 * Data-cache maintenance by virtual address, to the point of coherency.
 *
 * RAM is mapped Normal write-back cacheable (mmu.c), but the VideoCore
 * GPU and any bus-master DMA read it uncached through the 0xC0000000
 * alias, so a buffer the ARM has written may still be sitting in the
 * D-cache when the device reads it, and a buffer the device has written
 * may be shadowed by a stale D-line when the ARM reads it back.  Before
 * a device reads ARM-written memory it must be cleaned (DC CVAC); after
 * a device writes memory the ARM must invalidate its stale lines
 * (DC IVAC) before reading.  The single-line ops live in l.s; these
 * stride them across a byte range at the cache's minimum line size.
 *
 * QEMU models no data cache, so on the emulator these loops execute
 * against a coherent memory and change nothing observable; they earn
 * their keep only on real silicon.  Do NOT remove them for that reason
 * (see AGENTS.md): the mailbox and framebuffer paths depend on them
 * being correct on hardware.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

/*
 * Invalidate every data or unified cache before SCTLR.C is first enabled.
 * CLIDR describes up to seven levels; selecting a level in CSSELR makes
 * CCSIDR report its line, set and way geometry.  DC ISW's operand uses the
 * same line shift, level in bits 3:1, and a way field aligned at the top of
 * the 32-bit operand.  This is architectural ARMv8 code, not A53 geometry
 * hard-coded for QEMU.
 */
void
cacheinit(void)
{
	u32 clidr, ccsidr, sw;
	int level, loc, type, lineshift, ways, sets, waybits, wayshift;
	int way, set, n;

	coherence();
	clidr = getclidr();
	loc = (clidr >> 24) & 7;
	for(level = 0; level < loc; level++){
		type = (clidr >> (level*3)) & 7;
		if(type < 2 || type > 4)
			continue;	/* no data/unified cache at this level */
		setcsselr(level << 1);	/* data/unified cache */
		ccsidr = getccsidr();
		lineshift = (ccsidr & 7) + 4;
		ways = ((ccsidr >> 3) & 0x3ff) + 1;
		sets = ((ccsidr >> 13) & 0x7fff) + 1;
		waybits = 0;
		for(n = ways-1; n != 0; n >>= 1)
			waybits++;
		wayshift = 32 - waybits;
		for(way = ways-1; way >= 0; way--)
			for(set = sets-1; set >= 0; set--){
				sw = (level << 1) | (set << lineshift);
				if(waybits != 0)
					sw |= (u32)way << wayshift;
				dcisw(sw);
			}
	}
	setcsselr(0);
	coherence();
}

/*
 * Smallest data-cache line in bytes, from CTR_EL0.DminLine (bits 19:16,
 * log2 of the line size in 4-byte words).  DC operations by VA must
 * stride by the minimum line present so no line in the range is skipped.
 */
static usize
dlinesz(void)
{
	static usize ls;

	if(ls == 0)
		ls = 4UL << ((getctr() >> 16) & 0xf);
	return ls;
}

/*
 * Clean [va, va+len) to the point of coherency, then a DSB so the
 * cleaned lines are visible to the device before the caller pokes it.
 */
void
cacheflush(void *va, usize len)
{
	uintptr a, e, ls;

	ls = dlinesz();
	a = (uintptr)va & ~(ls - 1);
	e = (uintptr)va + len;
	for(; a < e; a += ls)
		dccvac(a);
	coherence();
}

/*
 * Clean AND invalidate [va, va+len) in a single pass (DC CIVAC): the
 * line is written back if dirty and then dropped.  One CIVAC pass is
 * not the same as a clean pass followed by a separate invalidate pass,
 * so this is its own loop -- the DWC2 control path allocates a read
 * buffer, poisons it, and CIVACs it before the transfer so the device
 * DMAs into memory with no ARM-dirty line left to write back over it.
 */
void
cacheflushinv(void *va, usize len)
{
	uintptr a, e, ls;

	ls = dlinesz();
	a = (uintptr)va & ~(ls - 1);
	e = (uintptr)va + len;
	for(; a < e; a += ls)
		dccivac(a);
	coherence();
}

/*
 * Invalidate [va, va+len): discard any stale D-lines so a following read
 * fetches what the device just wrote.  The range is rounded out to whole
 * lines; the caller must already have cleaned (or never written) the
 * partial end lines, or invalidating them would drop ARM writes.  A DSB
 * first orders it after the device's completion, one after so the
 * discard is done before the read.
 */
void
cacheinval(void *va, usize len)
{
	uintptr a, e, ls;

	ls = dlinesz();
	coherence();
	a = (uintptr)va & ~(ls - 1);
	e = (uintptr)va + len;
	for(; a < e; a += ls)
		dcivac(a);
	coherence();
}
