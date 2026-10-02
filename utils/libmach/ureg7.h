/*
 * AArch64 Ureg, as the kernel lays it out.
 *
 * A COPY of Inferno/aarch64/include/ureg.h, and a copy on purpose: every
 * other machine in this directory has one (ureg5.h, ureg6.h, uregj.h and
 * the rest), because libmach is built for the HOST and cannot include a
 * target's headers.  If the kernel's Ureg changes, this has to change
 * with it, and the register offsets a debugger prints are wrong until it
 * does.
 *
 * 31 real GPRs (x0..x30, x30 the link register) plus SP kept separate --
 * AArch64 does not number SP as a 32nd GPR.  pc/status/cause/tval are
 * ELR_EL1/SPSR_EL1/ESR_EL1/FAR_EL1, and type is the vector-class tag the
 * entry stubs set.
 */
struct Ureg
{
	uintptr	r0;
	uintptr	r1;
	uintptr	r2;
	uintptr	r3;
	uintptr	r4;
	uintptr	r5;
	uintptr	r6;
	uintptr	r7;
	uintptr	r8;
	uintptr	r9;
	uintptr	r10;
	uintptr	r11;
	uintptr	r12;
	uintptr	r13;
	uintptr	r14;
	uintptr	r15;
	uintptr	r16;
	uintptr	r17;
	uintptr	r18;
	uintptr	r19;
	uintptr	r20;
	uintptr	r21;
	uintptr	r22;
	uintptr	r23;
	uintptr	r24;
	uintptr	r25;
	uintptr	r26;
	uintptr	r27;
	uintptr	r28;
	uintptr	r29;		/* frame pointer */
	uintptr	r30;		/* link register */
	uintptr	sp;
	uintptr	pc;		/* ELR_EL1 */
	uintptr	status;		/* SPSR_EL1 */
	uintptr	type;		/* vector class: TSync/TIrq/TFiq/TSerr */
	uintptr	cause;		/* ESR_EL1 */
	uintptr	tval;		/* FAR_EL1 */
};
