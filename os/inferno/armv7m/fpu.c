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
