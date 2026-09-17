#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "armv7m.h"

/*
 * The ARMv7-M floating point extension.
 *
 * Two things have to be decided before the first exception is taken, and
 * they are decided here rather than left at their reset values.
 *
 * FPCCR.ASPEN and FPCCR.LSPEN are both turned off.  With either of them
 * on, taking an exception while CONTROL.FPCA is set makes the core push
 * a floating point state frame as well as the eight words the integer
 * frame holds -- 104 bytes rather than 32 -- and os/inferno/armv7m/l.s
 * builds its Ureg on the assumption that the frame is the small one.
 * Turning them off means the core never touches the floating point
 * registers on the way into an exception, which in turn means no
 * interrupt handler in this kernel may use floating point: an interrupt
 * that did would return to the interrupted process with D0-D15 changed.
 * Nothing in the trap path does.
 *
 * Processes do not save floating point state against each other either.
 * A Dis thread runs to a scheduling point rather than being preempted
 * mid-expression, and a context switch goes through setlabel and
 * gotolabel, which do not touch the floating point registers -- the same
 * arrangement the RISC-V boards use.
 */
/*
 * Prove the register file can be moved out and back before anything
 * depends on it.  This is the foundation the double-precision emulation
 * stands on, and both instructions are hand-encoded
 * (os/inferno/armv7m/armv7m.h), so it is checked rather than assumed.
 *
 * Deliberately no arithmetic: a pattern is written to memory, loaded
 * into S0-S31 with VLDMIA, stored back out with VSTMIA, and compared.
 * That runs on a Cortex-M4, which cannot add two doubles, as well as on
 * a Cortex-M7 which can -- so the same check reports from both benches.
 */
static void
fpregcheck(void)
{
	ulong out[32], in[32];
	int i, bad;

	for(i = 0; i < nelem(in); i++)
		in[i] = 0xf0000000 | (i<<16) | (i^0x5a5a);
	memset(out, 0, sizeof(out));

	fpregrestore(in);		/* VLDMIA: memory -> S0-S31 */
	fpregsave(out);			/* VSTMIA: S0-S31 -> memory */

	bad = -1;
	for(i = 0; i < nelem(in); i++)
		if(out[i] != in[i]){
			bad = i;
			break;
		}
	if(bad >= 0){
		print("FPREG-FAIL S%d wrote %.8lux read %.8lux\n",
			bad, in[bad], out[bad]);
		return;
	}
	print("FPREG-OK all 32 single-precision registers round-tripped\n");

	/*
	 * The round trip above is self-consistent: it would pass even if
	 * the transfers addressed the wrong registers, since the same pair
	 * writes and reads.  Check one low register independently, with a
	 * hardcoded VMOV that names S2 and nothing else.
	 */
	fpregrestore(in);
	if(s2get() != in[2]){
		print("FPREG-S2-FAIL VLDMIA left S2 ");
		print("%.8lux", s2get());
		print(" want %.8lux\n", in[2]);
	}
	else
		print("FPREG-S2-OK VLDMIA reaches S2\n");
}

void
fpinit(void)
{
	ulong *cpacr, *fpccr;

	cpacr = (ulong*)SCB_CPACR;
	*cpacr |= CpacrCp10|CpacrCp11;
	coherence();

	fpccr = (ulong*)FPU_FPCCR;
	*fpccr &= ~(FpccrAspen|FpccrLspen);
	coherence();

	fpregcheck();

}

void
FPsave(void *p)
{
	USED(p);
}

void
FPrestore(void *p)
{
	USED(p);
}

int
fpusave(void)
{
	return 0;
}

void
fpurestore(int x)
{
	USED(x);
}
