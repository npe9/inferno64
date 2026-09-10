/*
 * The AArch64 floating-point control and status registers, FPCR and
 * FPSR.  Assembly because the compiler has no word for a system
 * register; 7a takes FPCR and FPSR as native MRS/MSR operands
 * (utils/7a/lex.c names them, utils/7c/7.out.h encodes them).
 *
 * FPCR holds the rounding mode in bits 23:22 and, on a part that
 * implements trapped exceptions, five enable bits above it.  FPSR
 * holds the accrued exception flags in bits 4:0.  Those positions are
 * Inferno/aarch64/include/u.h's FPRNR/FPRPINF/FPRNINF/FPRZ and
 * FPAINEX..FPAINVAL, which were encoded from the architecture manual
 * and had, until this file, nothing to read or write them with.
 *
 * Only the rounding mode is written back, and the rest of each
 * register is left as it was.  The same header defines FPINEX,
 * FPUNFL, FPOVFL, FPZDIV and FPINVAL as zero on purpose: trapped
 * floating-point exceptions are optional in AArch64, a part that does
 * not implement them ignores the enable bits, and QEMU does not
 * implement them.  So this honours what the hardware will honour and
 * drops the rest, which is the choice getfcr-riscv64.s makes beside
 * it and for the same reason.  The precision bits FPPEXT, FPPSGL and
 * FPPDBL are zero for a third reason: AArch64 has no precision
 * control at all, each instruction naming its own width.
 *
 * Without this file no aarch64 board could carry the built-in $Math
 * module: libmath's FPinit() calls setfcr, and the link failed with
 * "FPinit: undefined: setfcr".  That is what MATH-FAIL was on
 * virtarm64, and why no aarch64 board's configuration had ever named
 * math in its mod section.
 */

#define RARG		R0
#define FPRMASK		(3<<22)		/* FPCR.RMode */
#define FPAMASK		0x1f		/* FPSR.IOC..IXC */

TEXT	getfcr(SB), 1, $-4		/* ulong getfcr(void) */
	MRS	FPCR, RARG
	AND	$FPRMASK, RARG, RARG
	RET	R30

/*
 * The mask goes through a register rather than an immediate.  BIC
 * takes a bitmask immediate, and 7l's opirr rejects these two with
 * "bad irr BIC"; AND with the same value assembles, so the pair are
 * written asymmetrically on purpose and not by oversight.
 */
TEXT	setfcr(SB), 1, $-4		/* void setfcr(ulong) */
	MRS	FPCR, R1
	MOV	$FPRMASK, R3
	BIC	R3, R1, R1
	AND	$FPRMASK, RARG, R2
	ORR	R2, R1
	MSR	R1, FPCR
	RET	R30

TEXT	getfsr(SB), 1, $-4		/* ulong getfsr(void) */
	MRS	FPSR, RARG
	AND	$FPAMASK, RARG, RARG
	RET	R30

TEXT	setfsr(SB), 1, $-4		/* void setfsr(ulong) */
	MRS	FPSR, R1
	MOV	$FPAMASK, R3
	BIC	R3, R1, R1
	AND	$FPAMASK, RARG, R2
	ORR	R2, R1
	MSR	R1, FPSR
	RET	R30
