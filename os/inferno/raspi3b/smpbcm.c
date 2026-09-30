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
 * WHAT IT PROVES AND WHAT IT DOES NOT.  A released core runs kernel C on
 * its own stack, turns on the MMU with core 0's page tables, takes its
 * own Mach, installs the vector table on itself, arms its own generic
 * timer and its own route through the BCM2836 local controller, enables
 * interrupts and idles -- and its m->ticks then rises, which is what says
 * it is taking its own interrupts through its own vectors into its own
 * Mach.  All of that is per-processor state that no amount of work on
 * core 0 can set up on its behalf, which is why it is done over there.
 *
 * It is still not in the scheduler.  conf.nmach stays 1 and
 * active.machs[n] stays 0 for a secondary, which is what keeps every
 * portable loop over MAXMACH -- devcons's Qsysstat sizes its buffer from
 * conf.nmach while looping to MAXMACH -- seeing one processor.  Its timer
 * interrupt goes to clocksecondary(), not clockintr(), because
 * accounttime(), checkalarms(), timercheck() and hzsched() all reach
 * shared scheduler state that this kernel's portable half has never been
 * asked to protect against a second processor.  Making them safe, and
 * then letting a secondary run schedinit(), is the next step and a much
 * larger one.
 *
 * It calls no print and takes no lock.  print takes a lock, and a
 * secondary holding a console lock when core 0 wants it is exactly the
 * kind of thing that would look like the board hanging at boot.
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
 * the secondary's value.  The distinction only holds on a core's FIRST
 * release, mind: one called back through the park loop already has its
 * MMU on, so both halves are cached and the two say the same thing.
 *
 * A WARM JTAG RESTART RELEASES NOTHING UNLESS THE PARKED CORES ARE
 * RESTING ON THIS EXACT LOOP -- and on this rig it releases nothing
 * anyway, because jtagrestart resumes core 0 alone and leaves the other
 * three halted by the debugger, so the release finds nobody awake to read
 * the slot and reports CPUn SILENT (measured).  That is also what makes
 * the warm path safe in practice: a halted core cannot run the previous
 * kernel's code out of memory this image has overwritten.  The
 * fingerprint below is what makes it safe to attempt at all.  tools/jtag/boot.sh re-enters KTZERO
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
	Ncpu	= MAXMACH,		/* BCM2837: four Cortex-A53 */
	Lines	= 64,			/* A53 cache line */
	Startms	= 200,			/* how long to wait for a core */
	Tickms	= 200,			/* and how long to count its ticks */

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

	Sctlrmmu = 1<<0,		/* SCTLR_EL1.M: MMU and caches on */
};

typedef struct Cpurep Cpurep;
struct Cpurep {
	uvlong	mpidr;			/* written with the MMU off */
	uvlong	el;
	uvlong	sp;
	uchar	pad[Lines-3*8];
	int	alive;			/* written with the MMU on */
	ulong	ticks;			/* core 0's only: m->ticks, before */
	uchar	pad2[Lines-4-sizeof(ulong)];
};

static uchar	repmem[sizeof(Cpurep)*Ncpu + Lines];
static Cpurep	*cpurep;

/*
 * One Mach per secondary, each on its own cache line so that two
 * processors updating their own m->ticks do not fight over one.  mach0
 * belongs to core 0 and is in l.s.
 */
typedef struct Cpumach Cpumach;
struct Cpumach {
	Mach	m;
	uchar	pad[Lines - sizeof(Mach)%Lines];
};
static uchar	machmem[sizeof(Cpumach)*Ncpu + Lines];
static Cpumach	*cpumach;

static void	recall(int);

/*
 * How far to take the other three processors.  0 leaves them parked as
 * they were before any of this existed; 1 releases each one, lets it
 * report itself and go back to resting with interrupts still masked; 2
 * gives it its own Mach, vector table and timer and lets it idle with
 * interrupts on.
 *
 * It is here because two changes arrived together -- m and up became
 * registers, and the secondaries started taking interrupts -- and a
 * freeze appeared with them, a few hundred milliseconds into the first
 * Dis program, at a wild pc reached from xec()'s call through its opcode
 * table.  Separating two changes needs a kernel that differs in one, and
 * this is the one byte that makes the difference: 1 is what the kernel
 * did before the timers, with everything else in place.  Set in the
 * config's code section, like cflag.
 */
extern int	smpstart;

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
 * Nothing here may touch m or up before the lines below set them -- boot2
 * zeroed both, so a premature use faults at a null pointer rather than
 * writing quietly through whatever the firmware's spin loop left -- and
 * nothing here may take a lock or call print at any point, because print
 * takes one and a secondary holding the console lock when core 0 wants it
 * is indistinguishable from the board hanging at boot.
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
	 * SCTLR.C, exactly as mmuinit() does on core 0.  The page tables are
	 * core 0's: the map is a flat identity one, marked inner shareable,
	 * and TTBR0/TCR/MAIR are per-core registers, so each core installs
	 * the same table for itself.
	 *
	 * ONLY ON A FIRST RELEASE.  A core released out of armstub8's loop
	 * has its MMU off and its caches in reset state; a core this kernel
	 * started once already and then called back through the park loop has
	 * both on, and must not run either line.  cacheinit() is a DC ISW
	 * loop -- invalidate by set/way, WITHOUT cleaning -- so on a core
	 * whose caches are live it throws dirty lines away, and the first one
	 * it throws away is this core's own clearing of its spin-table slot,
	 * which _secondary wrote a few instructions ago and which is still in
	 * L1.  The slot then reads back as the release address, the park loop
	 * finds it non-zero and branches straight back here, and the core
	 * does that for ever -- re-zeroing its own tick count every time
	 * round, so the symptom is a tick line near nought and not anything
	 * that looks like a core spinning.  QEMU cannot show it: it has no
	 * caches.
	 */
	if((getsctlr() & Sctlrmmu) == 0){
		cacheinit();
		if(mmul1 != nil)
			mmuenable(mmul1);
	}
	fpinit();

	/*
	 * Its own Mach, from here on.  m is a register (dat.h), so this
	 * assignment is this processor's and nobody else's; machp[n] is how
	 * core 0 finds it afterwards.
	 */
	if(smpstart < 2){
		/*
		 * Level 1: report and go back to resting, with no Mach, no
		 * vectors, no timer and interrupts still masked -- which is
		 * exactly what this file did before any of that existed.
		 */
		r->alive = 1;
		coherence();
		cpupark();
	}

	m = &cpumach[n].m;
	memset(m, 0, sizeof(Mach));
	m->machno = n;
	machp[n] = m;
	coherence();

	/*
	 * And its own vectors, timer and route.  active.machs[n] is
	 * deliberately not set: that array means "running a scheduler".
	 */
	vectorinstall();
	clockinitsecondary();

	/*
	 * alive last, because it is the word core 0 tests.  No barrier is
	 * needed in front of it: the other three words were written with the
	 * MMU off, straight to DRAM, and mmuenable() ends in DSB and ISB, so
	 * they are visible before this store can be.
	 */
	r->alive = 1;
	coherence();

	/*
	 * Interrupts on, and rest -- in the same park loop, which is an idle
	 * loop as soon as interrupts are enabled: WFE wakes on an unmasked
	 * IRQ as well as on an event, so the timer interrupt is taken at the
	 * WFE, returns to the instruction after it, finds the slot still zero
	 * and waits again.  So a processor that is idling is also a processor
	 * core 0 can still call back by writing its slot, and it is idling at
	 * the one fixed address in this kernel.
	 */
	spllo();
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

	if(smpstart <= 0){
		print("CPU-SMP-OFF smpstart 0: cores 1-3 left parked\n");
		return;
	}
	cpurep = (Cpurep*)(((uintptr)repmem + Lines-1) & ~(uintptr)(Lines-1));
	memset(cpurep, 0, sizeof(Cpurep)*Ncpu);
	cpumach = (Cpumach*)(((uintptr)machmem + Lines-1) & ~(uintptr)(Lines-1));
	memset(cpumach, 0, sizeof(Cpumach)*Ncpu);
	/*
	 * A secondary reads the pointer and writes the report with the MMU
	 * off, straight to DRAM, so core 0's cached copies of both have to
	 * be in DRAM before the core is let go.
	 */
	cacheflush(&cpurep, sizeof cpurep);
	cacheflush(cpurep, sizeof(Cpurep)*Ncpu);
	cacheflush(&cpumach, sizeof cpumach);

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

	/*
	 * And then the thing the per-processor Mach, vector table and timer
	 * were for: each processor's own tick count over one interval of this
	 * one's.  A processor idling at WFE with its route armed should see
	 * HZ ticks a second and no more, so Tickms of wall time is about
	 * HZ*Tickms/1000 of them; zero means it is not taking its own
	 * interrupts, and wildly more would mean it is taking somebody
	 * else's.
	 */
	for(n = 1; n < Ncpu; n++)
		if(cpurep[n].alive && machp[n] != nil)
			cpurep[n].ticks = machp[n]->ticks;
	delay(Tickms);
	for(n = 1; n < Ncpu; n++){
		if(!cpurep[n].alive || machp[n] == nil)
			continue;
		print("CPU%d ticks %lud in %d ms (mach %#p machno %d)\n",
			n, machp[n]->ticks - cpurep[n].ticks, Tickms,
			machp[n], machp[n]->machno);
	}
	recall(1);
}

/*
 * Call one processor back through the park loop and start it again.
 *
 * This exists to run a path that nothing else reaches.  A processor
 * released out of armstub8's loop has its MMU off; one called back out of
 * the park loop has it on, and cpustart() must then skip cacheinit() --
 * see the argument there.  That branch has no other caller: the kernel
 * never otherwise recalls a processor, and a JTAG restart cannot be used
 * to test it because jtagrestart resumes core 0 alone and leaves the
 * others halted by the debugger.  So the release path with the caches
 * already live would ship unexecuted, on the strength of reading the
 * code, if this did not run it once at every boot.
 *
 * It is also the test of a claim the design makes: that a processor which
 * is idling is still one core 0 can reach, because idling and resting are
 * the same loop.
 *
 * No cache maintenance on the report here, deliberately.  A recalled
 * processor has its MMU on throughout, so every word it writes is Normal
 * cacheable and inner shareable and coherency does the work; cleaning or
 * invalidating core 0's own copy of `alive' would only throw away the
 * zero written just below.
 */
static void
recall(int n)
{
	uintptr *tab;
	Cpurep *r;
	ulong t;
	int i;

	if(n <= 0 || n >= Ncpu)
		return;
	r = &cpurep[n];
	if(!r->alive || machp[n] == nil)
		return;
	r->alive = 0;
	coherence();

	tab = (uintptr*)Spintab;
	cacheinval(&tab[n], sizeof tab[n]);
	tab[n] = (uintptr)_secondary;
	cacheflush(&tab[n], sizeof tab[n]);
	for(i = 0; i < Startms; i++){
		sev();
		delay(1);
		if(r->alive)
			break;
	}
	if(!r->alive){
		print("CPU%d RECALL FAILED after %d ms\n", n, Startms);
		return;
	}
	t = machp[n]->ticks;
	delay(Tickms);
	print("CPU%d recalled in %d ms, ticks %lud in %d ms after it\n",
		n, i, machp[n]->ticks - t, Tickms);
}
