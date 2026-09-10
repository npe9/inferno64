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
 * Each started processor gets the address of its own slot as CPU_ON's
 * context id, which arrives in x0.  That is the whole of the
 * arrangement: no stack, no static base, no lock and no shared cursor,
 * so _secondary can be four instructions and cannot race.  The MMU is
 * off on both sides, so every access is to memory rather than to a
 * cache, and the addresses are physical as they stand.
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

static uvlong secmpidr[Nacpicpu];
static char started[Nacpicpu];

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
	uvlong own, entry, r;
	int i, ms, nstart, nanswer, nmatch, nfail, nodd;

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
	print("cpu: this one is mpidr %#llux; entry %#llux, cpu_on through %s\n",
		own, entry, pscismcconduit ? "smc" : "hvc");

	nstart = nfail = 0;
	for(i = 0; i < acpincpudesc; i++){
		started[i] = 0;
		if(acpicpu[i].mpidr == own)
			continue;
		if((acpicpu[i].flags & 1) == 0)
			continue;
		secmpidr[i] = ~(uvlong)0;
		r = psci(PsciCpuOn, acpicpu[i].mpidr, entry, (uvlong)&secmpidr[i]);
		if(r == 0){
			started[i] = 1;
			nstart++;
		}else if(nfail++ < 4)		/* a big machine must not print a page */
			print("cpu: mpidr %#llux cpu_on: %s (%lld)\n",
				acpicpu[i].mpidr, pscierr((vlong)r), (vlong)r);
	}

	/*
	 * Bounded, and the bound is reported: a count short of the number
	 * started is a result, not a hang.
	 */
	nanswer = 0;
	for(ms = 0; ms < Waitms; ms++){
		nanswer = 0;
		for(i = 0; i < acpincpudesc; i++)
			if(started[i] && secmpidr[i] != ~(uvlong)0)
				nanswer++;
		if(nanswer >= nstart)
			break;
		delay(1);
	}

	nmatch = nodd = 0;
	for(i = 0; i < acpincpudesc; i++){
		if(!started[i] || secmpidr[i] == ~(uvlong)0)
			continue;
		if((secmpidr[i] & mpidrmask) == acpicpu[i].mpidr)
			nmatch++;
		else if(nodd++ < 4)
			print("cpu: asked for mpidr %#llux, got %#llux\n",
				acpicpu[i].mpidr, secmpidr[i]);
	}

	print("cpu: %d started, %d answered in %dms, %d mpidrs match; parked, conf.nmach %lud\n",
		nstart, nanswer, ms, nmatch, conf.nmach);
}
