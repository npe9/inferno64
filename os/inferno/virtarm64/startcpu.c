#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"

/*
 * Starting the processors the MADT describes.
 *
 * This is not SMP and does not pretend to be: MAXMACH is 1 on this
 * board, conf.nmach is 1, there is one Mach and one scheduler, and a
 * processor started here is parked in l.s's _secondary and never runs
 * anything else.  What it is, is the proof that the two pieces SMP
 * will need are right before anything is built on them -- that the
 * MPIDRs read out of the MADT are the ones the machine actually
 * answers to, and that PSCI's conduit and calling convention are what
 * this kernel thinks they are.
 *
 * The proof is that the value comes back from the other side.  The
 * MPIDR handed to CPU_ON is the firmware's; the MPIDR that appears in
 * the slot is read from MPIDR_EL1 by the processor that woke up.  If
 * the MADT were being misread -- an index used as an affinity, a field
 * taken from the wrong offset -- CPU_ON would fail, or a processor
 * would start and report an MPIDR that is not the one asked for.
 *
 * Each started processor gets the address of its own Secboot record as
 * CPU_ON's context id, which arrives in x0.  There is no lock and no
 * shared cursor: a processor touches its own record and nothing else,
 * so _secondary cannot race.
 *
 * What the record carries is the second half of this: a stack, a
 * static base, a Mach of its own and the page tables.  A processor
 * that sets those four and reports back the machno it read out of its
 * own m has proved the thing that has to be true before any of the
 * rest of SMP can be built -- that m is per-processor.  It cannot pass
 * that test if m is shared, because then every one of them would
 * report the same number.  It is still not SMP: conf.nmach is 1, there
 * is one scheduler, and a processor that has reported parks in WFE.
 */

enum {
	PsciCpuOn	= 0xC4000003,	/* CPU_ON, 64-bit calling convention */

	Waitms		= 200,		/* bounded: a processor that never
					 * answers must not stop the boot */
};

/*
 * Aff3..Aff0; MPIDR_EL1's other bits (U, MT, RES1) are not affinity and
 * the MADT's field carries the affinity alone.  A variable rather than
 * a member of the enum above because the enum's constants are ints and
 * this does not fit in one.
 */
static uvlong mpidrmask = 0xFF00FFFFFFULL;

/*
 * What a starting processor is handed.  The offsets are known to l.s
 * (SB_MPIDR..SB_TCR); keep the two in step.  The first two fields are
 * written by the processor that starts up, from secondary() below,
 * with the MMU already on -- so they are ordinary coherent memory as
 * far as the processor polling them is concerned, and not a location
 * two agents write with different cacheability, which is the
 * arrangement that works on an emulator with no cache and does not
 * work on a core with one.
 */
typedef struct Secboot Secboot;
struct Secboot {
	uvlong	mpidr;			/* 0: what MPIDR_EL1 says over there */
	uvlong	stacktop;		/* 8 */
	uvlong	sb;			/* 16 */
	uvlong	mach;			/* 24 */
	uvlong	l0;			/* 32 */
	uvlong	tcr;			/* 40 */
	uvlong	machno;			/* 48: m->machno, read over there */
};

static Secboot secboot[MAXMACH];
static char started[Nacpicpu];

extern void _secondary(void);
extern void dccleanrange(void*, int);
extern uvlong mmutables(uvlong*);
extern void* setSB(void);		/* the linker's static base symbol */

/*
 * Runs on the processor that just started, with the MMU on, its own
 * stack, its own static base and its own m.  It reads MPIDR_EL1 for
 * the round-trip check startcpus() has always made, and m->machno for
 * the new one, and parks.
 *
 * It does not set active.machs[machno].  That array is what the
 * portable code walks to MAXMACH to find processors that are running
 * a scheduler, and devcons.c's Qsysstat sizes its buffer from
 * conf.nmach while looping over it; setting it for a parked processor
 * would overflow that buffer.  It belongs to the increment that makes
 * these processors schedule, together with conf.nmach.
 */
void
secondary(Secboot *s)
{
	s->machno = m->machno;
	s->mpidr = getmpidr();
	coherence();
}

/*
 * PSCI's error returns, which say more than "it failed": DENIED and
 * INVALID_PARAMETERS mean the MPIDR was wrong, ALREADY_ON means the
 * firmware left the processor running, NOT_SUPPORTED means there is no
 * CPU_ON to call.
 */
static char*
pscierr(vlong r)
{
	switch(r){
	case 0:		return "success";
	case -1:	return "not supported";
	case -2:	return "invalid parameters";
	case -3:	return "denied";
	case -4:	return "already on";
	case -5:	return "on pending";
	case -6:	return "internal failure";
	case -7:	return "not present";
	case -9:	return "invalid address";
	}
	return "unknown";
}

void
startcpus(void)
{
	uvlong own, entry, r, l0, tcr;
	int i, ms, nstart, nanswer, nmatch, nfail, nodd, nmachno, nclip, machno;
	static schar slot[Nacpicpu];
	Secboot *sb;
	Mach *mp;
	void *stk;

	/*
	 * Nothing to do, and the two reasons are different: no list at
	 * all is the -kernel path, where there is no configuration and
	 * so no ACPI, and a list of one is a machine with one processor.
	 * Neither is a failure and neither prints.
	 */
	if(acpincpudesc == 0 || acpincpudesc == 1)
		return;
	if(acpiarmboot >= 0 && !acpipsci){
		print("cpu: the firmware says there is no psci; nothing started\n");
		return;
	}

	own = getmpidr() & mpidrmask;
	entry = (uvlong)_secondary;
	mmuparams(&l0, &tcr);
	print("cpu: this one is mpidr %#llux; entry %#llux, cpu_on through %s\n",
		own, entry, pscismcconduit ? "smc" : "hvc");

	nstart = nfail = nclip = 0;
	machno = 0;
	for(i = 0; i < acpincpudesc; i++){
		started[i] = 0;
		slot[i] = -1;
		if(acpicpu[i].mpidr == own)
			continue;
		if((acpicpu[i].flags & 1) == 0)
			continue;
		if(++machno >= MAXMACH){		/* 0 is this processor */
			nclip++;
			machno--;
			continue;
		}

		/*
		 * A Mach and a stack of its own, and the stack pointer is
		 * the top because it grows down.  xspanalloc rather than
		 * malloc: this is memory that is never freed and that a
		 * processor with its MMU off will read, so it wants to be
		 * page-aligned and out of the pool.
		 */
		mp = xspanalloc(sizeof(Mach), BY2PG, 0);
		memset(mp, 0, sizeof(Mach));
		mp->machno = machno;
		machp[machno] = mp;
		stk = xspanalloc(KSTACK, BY2PG, 0);

		sb = &secboot[machno];
		sb->mpidr = ~(uvlong)0;
		sb->machno = ~(uvlong)0;
		sb->stacktop = (uvlong)stk + KSTACK;
		sb->sb = getsb();
		sb->mach = (uvlong)mp;
		sb->l0 = l0;
		sb->tcr = tcr;

		/*
		 * Everything the starting processor reads with its MMU
		 * off, cleaned to the point of coherency: the record, its
		 * Mach and its stack.  This is the obligation the AArch64
		 * boot protocol puts on whoever starts a processor, and it
		 * is the one thing here an emulator cannot check.
		 */
		dccleanrange(sb, sizeof(*sb));
		dccleanrange(mp, sizeof(Mach));
		dccleanrange(stk, KSTACK);

		slot[i] = machno;
		r = psci(PsciCpuOn, acpicpu[i].mpidr, entry, (uvlong)sb);
		if(r == 0){
			started[i] = 1;
			nstart++;
		}else{
			machp[machno] = nil;
			machno--;
			if(nfail++ < 4)	/* a big machine must not print a page */
				print("cpu: mpidr %#llux cpu_on: %s (%lld)\n",
					acpicpu[i].mpidr, pscierr((vlong)r), (vlong)r);
		}
	}
	if(nclip)
		print("cpu: %d more processors than MAXMACH (%d); the rest are left alone\n",
			nclip, MAXMACH);

	/*
	 * Bounded, and the bound is reported: a count short of the number
	 * started is a result, not a hang.
	 */
	nanswer = 0;
	for(ms = 0; ms < Waitms; ms++){
		nanswer = 0;
		for(i = 0; i < acpincpudesc; i++)
			if(started[i] && secboot[slot[i]].mpidr != ~(uvlong)0)
				nanswer++;
		if(nanswer >= nstart)
			break;
		delay(1);
	}

	/*
	 * Three counts, and the third is the new one.  The MPIDR proves
	 * the MADT was read right and PSCI was called right.  The machno
	 * proves m is per-processor: each answer is the number this
	 * kernel put in that processor's own Mach, read back through
	 * that processor's own m, and if m were still one global they
	 * would all be the same number.
	 */
	nmatch = nodd = nmachno = 0;
	for(i = 0; i < acpincpudesc; i++){
		if(!started[i] || secboot[slot[i]].mpidr == ~(uvlong)0)
			continue;
		sb = &secboot[slot[i]];
		if((sb->mpidr & mpidrmask) == acpicpu[i].mpidr)
			nmatch++;
		else if(nodd++ < 4)
			print("cpu: asked for mpidr %#llux, got %#llux\n",
				acpicpu[i].mpidr, sb->mpidr);
		if(sb->machno == (uvlong)slot[i])
			nmachno++;
		else
			print("cpu: machno %d reported %lld\n", slot[i], (vlong)sb->machno);
	}

	print("cpu: %d started, %d answered in %dms, %d mpidrs match, %d own machnos; parked, conf.nmach %lud\n",
		nstart, nanswer, ms, nmatch, nmachno, conf.nmach);
	if(nmachno > 0){
		print("cpu: machnos");
		for(i = 0; i < acpincpudesc; i++)
			if(started[i] && secboot[slot[i]].machno != ~(uvlong)0)
				print(" %lld", (vlong)secboot[slot[i]].machno);
		print("\n");
	}
}
