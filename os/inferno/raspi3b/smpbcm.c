#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"

/*
 * Starting the BCM2837's other three cores.
 *
 * This kernel has run on one core since the board came up, and the
 * other three have been parked at WFE by l.s since the first boot --
 * the fix for a garbled console, when all four were running the same
 * boot and writing the same UART.  What follows is the first step back:
 * release a core, give it its own stack, and have it say so.
 *
 * WHAT IT PROVES AND WHAT IT DOES NOT.  A released core here runs
 * kernel C on its own stack, turns on the MMU with core 0's page
 * tables, and writes two words.  It does not have a Mach, does not take
 * interrupts, does not touch a lock, does not call print, and is not
 * known to the scheduler: MAXMACH is still 1 and `m' is still a single
 * global.  Everything a running processor needs (a per-core Mach, real
 * atomics in place of archbcm.c's spl-masked ainc/adec, per-core timer
 * interrupts, a scheduler that can be entered from more than one core)
 * is still absent.  This is a bring-up probe, not a second processor.
 *
 * THE REPORT IS DELIBERATELY IN TWO HALVES, IN TWO CACHE LINES.  mpidr,
 * el and sp are written before the MMU goes on, so they reach DRAM
 * directly and core 0 can read them back by invalidating its own copy
 * -- no inter-core cache coherency required.  alive is written after,
 * from Normal inner-shareable memory, so it arrives only if the two
 * cores' caches really are coherent (which on real hardware means
 * armstub8 set CPUECTLR_EL1.SMPEN for every core before it dropped to
 * EL2; this kernel does not write CPUECTLR itself, because access to it
 * from EL1 is trappable and a trap here would be a silent hang).  So
 * the two halves fail separately and say different things: nothing at
 * all means the core never ran, and the first half without the second
 * means it ran but its memory is not coherent with core 0's.
 *
 * They must be in separate cache lines for that to be true.  Core 0
 * cleans-and-invalidates to read the first half; if the second shared a
 * line with it, that clean could write core 0's stale zero back over
 * the secondary's value.
 *
 * A WARM JTAG RESTART RELEASES NOTHING UNLESS THE PARKED CORES ARE
 * RESTING ON THIS EXACT LOOP.  tools/jtag/boot.sh re-enters KTZERO
 * without resetting the cores, so a core parked by the previous kernel
 * is spinning on an instruction of an image that is no longer loaded --
 * a pre-SMP kernel parked its cores in a WFE loop somewhere in the
 * middle of _main, and a SEV would send three cores into whatever this
 * build put at that address, with no vectors and a live scheduler
 * underneath.  So a kernel that releases cores leaves a fingerprint of
 * its park loop in core 0's own (otherwise unused) spin-table slot, and
 * a kernel entered over JTAG releases nothing unless the fingerprint it
 * finds is the one it would have written.  A cold boot needs no such
 * check: the firmware's armstub8 zeroes the spin table and owns the
 * three cores itself.
 */

enum {
	Ncpu	= 4,			/* BCM2837: four Cortex-A53 */
	Lines	= 64,			/* A53 cache line */
	Startms	= 200,			/* how long to wait for a core */

	/*
	 * The first and last instructions of l.s's park loop, as this
	 * assembler encodes them: WFE, and "BR R2" seven words later.  They
	 * are here so the kernel can recognise its own park loop at the
	 * fixed address a previously-parked core is resting on; if the loop
	 * is ever rewritten these change with it, which is the point.
	 */
	Parkwfe	= 0xd503205f,
	Parkbr	= 0xd61f0040,
	Parkwords = 7,			/* WFE through BR inclusive */

	Parkmagic = 0x5041524b,		/* "PARK", the fingerprint's seed */
};

typedef struct Cpurep Cpurep;
struct Cpurep {
	uvlong	mpidr;			/* written with the MMU off */
	uvlong	el;
	uvlong	sp;
	uchar	pad[Lines-3*8];
	int	alive;			/* written with the MMU on */
	uchar	pad2[Lines-4];
};

static uchar	repmem[sizeof(Cpurep)*Ncpu + Lines];
static Cpurep	*cpurep;

extern void	_secondary(void);
extern void	sev(void);
extern void	cpupark(void);
extern void	getmpidr(uvlong*);
extern void	getcurrentel(uvlong*);
extern void	mmuenable(void*);
extern uvlong	*mmul1;			/* core 0's identity map, shared */

/*
 * A fingerprint of the park loop as this image has it: enough that a
 * kernel can tell whether the cores resting at Cpuparkwait are resting
 * on instructions it agrees with, and different if a single word of the
 * loop is ever changed.
 */
static uvlong
parkprint(u32int *p)
{
	uvlong s;
	int i;

	s = Parkmagic;
	for(i = 0; i < Parkwords; i++)
		s = s*1000003 + p[i];
	return s;
}

/*
 * A secondary's first kernel C, called from l.s's boot2 with the core
 * number and a stack of its own, at EL1, with the MMU off.
 *
 * Nothing here may touch m, up, a lock, or the console: there is one
 * Mach in this kernel and it belongs to core 0, and print() takes a
 * lock.  The whole report is two stores.
 */
void
cpustart(int n)
{
	Cpurep *r;
	uvlong v;

	if(n <= 0 || n >= Ncpu || cpurep == nil)
		cpupark();
	r = &cpurep[n];
	getmpidr(&v);
	r->mpidr = v;
	getcurrentel(&v);
	r->el = v;
	r->sp = (uintptr)&v;		/* did boot2's stack arithmetic work? */

	/*
	 * ARMv8 reset leaves cache contents UNKNOWN, so invalidate before
	 * SCTLR.C, exactly as mmuinit() does on core 0.  The page tables
	 * are core 0's: the map is a flat identity one, marked inner
	 * shareable, and TTBR0/TCR/MAIR are per-core registers, so each
	 * core installs the same table for itself.
	 */
	cacheinit();
	if(mmul1 != nil)
		mmuenable(mmul1);
	fpinit();

	/*
	 * alive last, because it is the word core 0 tests.  No barrier is
	 * needed in front of it: the other three words were written with the
	 * MMU off, straight to DRAM, and mmuenable() ends in DSB and ISB, so
	 * they are visible before this store can be.
	 */
	r->alive = 1;
	coherence();
	cpupark();
}

/*
 * Core 0: release each secondary in turn and print what it reported.
 * Called from main() once print() works.
 */
void
cpuboot(void)
{
	uintptr *tab;
	Cpurep *r;
	u32int *park;
	uvlong fp;
	int n, i;

	cpurep = (Cpurep*)(((uintptr)repmem + Lines-1) & ~(uintptr)(Lines-1));
	memset(cpurep, 0, sizeof(Cpurep)*Ncpu);
	/*
	 * A secondary reads the pointer and writes the report with the MMU
	 * off, straight to DRAM, so core 0's cached copies of both have to
	 * be in DRAM before the core is let go.
	 */
	cacheflush(&cpurep, sizeof cpurep);
	cacheflush(cpurep, sizeof(Cpurep)*Ncpu);

	/*
	 * A core parked by the previous kernel is resting on one instruction
	 * of this image, at Cpuparkwait, and the SEV below is what wakes it.
	 * So check that the instruction really is the park loop's WFE and
	 * that the loop still ends where it did: if the loop has moved or
	 * changed shape, a release would send three cores into whatever this
	 * build put there instead.  Reading the words is the only way to ask
	 * -- the loop is a label inside _main, not a symbol, because 7l does
	 * not keep TEXT symbols in file order.
	 */
	park = (u32int*)Cpuparkwait;
	if(park[0] != Parkwfe || park[Parkwords-1] != Parkbr){
		print("CPU-PARK-MOVED: %#p is %#.8ux %#.8ux, want %#.8ux %#.8ux;"
			" no secondaries released\n",
			(void*)Cpuparkwait, park[0], park[Parkwords-1],
			Parkwfe, Parkbr);
		return;
	}
	tab = (uintptr*)Spintab;
	fp = parkprint(park);
	cacheinval(tab, sizeof(uintptr));	/* slot 0: the fingerprint */
	if(bootx0 == Jtagmagic && tab[0] != fp){
		print("CPU-WARM-RESTART: slot0 %#llux, this kernel's park loop is"
			" %#llux; no secondaries released, cold boot to start them\n",
			(uvlong)tab[0], fp);
		return;
	}
	tab[0] = fp;
	cacheflush(tab, sizeof(uintptr));

	for(n = 1; n < Ncpu; n++){
		cacheinval(&tab[n], sizeof tab[n]);
		tab[n] = (uintptr)_secondary;
		cacheflush(&tab[n], sizeof tab[n]);
		r = &cpurep[n];
		for(i = 0; i < Startms; i++){
			sev();
			delay(1);
			cacheinval(&r->mpidr, 3*sizeof(uvlong));
			cacheinval(&r->alive, sizeof r->alive);
			if(r->alive)
				break;
		}
		if(r->alive)
			print("CPU%d alive: mpidr %#llux el%lld sp %#llux (%d ms)\n",
				n, r->mpidr, (r->el>>2)&3, r->sp, i);
		else if(r->mpidr != 0)
			print("CPU%d RAN BUT IS NOT COHERENT:"
				" mpidr %#llux el%lld sp %#llux, alive still 0\n",
				n, r->mpidr, (r->el>>2)&3, r->sp);
		else{
			cacheinval(&tab[n], sizeof tab[n]);
			print("CPU%d SILENT after %d ms (slot %#p holds %#p)\n",
				n, Startms, &tab[n], (void*)tab[n]);
		}
	}
}
