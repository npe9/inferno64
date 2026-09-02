/*
 * AArch64 Ureg: 31 real GPRs (x0..x30, x30 is LR) plus SP kept
 * separate -- AArch64 doesn't number SP as a 32nd GPR the way
 * x0-x30 are numbered; register 31 means XZR or SP depending on
 * context, never a real value slot.  type is a small vector-class
 * tag (TSync/TIrq/TFiq/TSerr, see io.h) set by each vector's own
 * entry stub, the same role armv7/l.s's R2 type-tag plays for a
 * board whose PSR carries no fault-reason field of its own; cause
 * is the real ESR_EL1 read at every vector regardless of class
 * (harmless for IRQ/FIQ, is the decode trap() actually wants for
 * TSync).  pc/status/tval are ELR_EL1/SPSR_EL1/FAR_EL1.
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
