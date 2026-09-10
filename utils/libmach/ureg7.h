/*
 * AArch64 Ureg, as the kernels in this tree lay it out.
 *
 * Copied from os/inferno/virtarm64's Inferno/aarch64/include/ureg.h
 * rather than included from it, the way utils/libmach/ureg6.h and
 * uregj.h are copies for amd64 and riscv64: libmach is a host library
 * and must not reach into a target's include tree.  Fields are
 * u64int, not uintptr, because this describes the target's record and
 * not the host's word -- see AGENTS.md on `long' is 32 bits.
 *
 * 31 real GPRs (x0..x30, x30 the link register) plus SP kept separate:
 * AArch64 does not number SP as a 32nd GPR.  pc, status and tval are
 * ELR_EL1, SPSR_EL1 and FAR_EL1; cause is ESR_EL1; type is the small
 * vector-class tag (TSync/TIrq/TFiq/TSerr) each vector's entry stub
 * sets.
 */
struct Ureg
{
	u64int	r0;
	u64int	r1;
	u64int	r2;
	u64int	r3;
	u64int	r4;
	u64int	r5;
	u64int	r6;
	u64int	r7;
	u64int	r8;
	u64int	r9;
	u64int	r10;
	u64int	r11;
	u64int	r12;
	u64int	r13;
	u64int	r14;
	u64int	r15;
	u64int	r16;
	u64int	r17;
	u64int	r18;
	u64int	r19;
	u64int	r20;
	u64int	r21;
	u64int	r22;
	u64int	r23;
	u64int	r24;
	u64int	r25;
	u64int	r26;
	u64int	r27;
	u64int	r28;
	u64int	r29;		/* frame pointer */
	u64int	r30;		/* link register */
	u64int	sp;
	u64int	pc;		/* ELR_EL1 */
	u64int	status;		/* SPSR_EL1 */
	u64int	type;		/* vector class: TSync/TIrq/TFiq/TSerr */
	u64int	cause;		/* ESR_EL1 */
	u64int	tval;		/* FAR_EL1 */
};
