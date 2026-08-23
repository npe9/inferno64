#include "mem.h"

#define LINK	R1
#define SP	R2
#define RARG	R8

#define MASK(w)	((1<<(w))-1)
#define FENCE	WORD $(0xf | MASK(8)<<20)
#define AQ	(1<<26)
#define RL	(1<<25)
#define LRW(rs1, rd) \
	WORD $((2<<27)|(0<<20)|((rs1)<<15)|(2<<12)|((rd)<<7)|057|AQ)
#define SCW(rs2, rs1, rd) \
	WORD $((3<<27)|((rs2)<<20)|((rs1)<<15)|(2<<12)|((rd)<<7)|057|AQ|RL)

#define	MSTATUS	0x300
#define	MIE	0x304
#define	MTVEC	0x305
#define	MEPC	0x341
#define	MCAUSE	0x342
#define	MTVAL	0x343
#define	MCYCLE	0xB00
#define	MIEBIT	8		/* mstatus.MIE */
#define	MTIE	128		/* mie.MTIE — machine timer */
#define	MEIE	2048		/* mie.MEIE — unused on spike */
#define	FSBITS	(3<<13)		/* mstatus.FS = Dirty — enable FPU */
#define	MRET	WORD $(0x30200073)

/* Ureg offsets (uintptr = 8); keep in sync with Inferno/riscv64/include/ureg.h */
#define	UREG_PC		0
#define	UREG_R1		8
#define	UREG_SP		16
#define	UREG_R3		24
#define	UREG_STATUS	256
#define	UREG_IE		264
#define	UREG_CAUSE	272
#define	UREG_TVAL	280
#define	UREG_CURMODE	288
#define	UREG_SIZE	304		/* 37*8 rounded to 16 */
/*
 * KenC saves REGARG at a positive SP offset that can reach above the
 * callee frame into whatever sits at the pre-call SP.  Keep a pad below
 * Ureg so those stores do not smash saved registers (especially ra).
 */
#define	TRAPPAD		2048
#define	TRAPFRAME	(TRAPPAD+UREG_SIZE)

/*
 * Entry for QEMU -M spike -bios none -kernel ispike.
 * Stack is SB-relative so RV64 lui sign-extension is avoided.
 */
TEXT	_main(SB), 1, $-8
	MOV	$setSB(SB), R3
	MOV	$stack+(64*1024)(SB), SP
	MOV	CSR(MSTATUS), R10
	OR	$FSBITS, R10
	MOV	R10, CSR(MSTATUS)
	/*
	 * KenC jc keeps small double constants in F28–F31
	 * (FREGZERO/HALF/ONE/TWO).  Must match utils/jc/i.out.h.
	 * MOVUD is FCVT (not bitcast) and truncates; store bits then MOVD.
	 */
	MOV	$0x3FE00000, R8
	SLL	$32, R8			/* 0x3FE0000000000000 = 0.5 */
	MOV	R8, fbits(SB)
	MOVD	fbits(SB), F29
	SUBD	F29, F29, F28		/* 0.0 */
	ADDD	F29, F29, F30		/* 1.0 */
	ADDD	F30, F30, F31		/* 2.0 */
	JAL	LINK, main(SB)
dead:
	JMP	dead

GLOBL	fbits(SB), $8
GLOBL	stack(SB), $(64*1024)
GLOBL	mach0(SB), $(4*1024)
/*
 * QEMU -M spike HTIF: 16-byte cell.  fromhost is tohost+8 (see htif.c).
 * Single GLOBL keeps the pair contiguous for QEMU's HTIF map.
 */
GLOBL	tohost(SB), $16

TEXT	getcallerpc(SB), 1, $-4
	MOV	0(FP), RARG
	RET

TEXT	_tas(SB), 1, $-4
	MOV	RARG, R12
	MOV	$1, R10
	FENCE
tas1:
	LRW(12, 8)
	SCW(10, 12, 14)
	BNE	R14, tas1
	RET

TEXT	setlabel(SB), 1, $-4
	MOV	SP, 0(RARG)		/* sp */
	MOV	LINK, XLEN(RARG)	/* pc */
	MOV	R0, RARG
	RET

TEXT	gotolabel(SB), 1, $-4
	MOV	0(RARG), SP
	MOV	XLEN(RARG), LINK
	MOV	$setSB(SB), R3		/* C uses SB; restore after switch */
	MOV	$1, RARG
	RET

/*
 * First process entry trampoline — keeps SB set on the new stack.
 */
TEXT	init0entry(SB), 1, $-4
	MOV	$setSB(SB), R3
	JAL	LINK, init0(SB)
dead0:
	JMP	dead0

TEXT	splhi(SB), 1, $-4
	MOV	CSR(MSTATUS), R10
	MOV	R10, RARG		/* return previous */
	MOV	$~MIEBIT, R11
	AND	R11, R10
	MOV	R10, CSR(MSTATUS)
	MOV	$mach0(SB), R12
	MOV	LINK, 0(R12)		/* m->splpc */
	RET

TEXT	spllo(SB), 1, $-4
	MOV	CSR(MSTATUS), R10
	MOV	R10, RARG
	OR	$MIEBIT, R10
	MOV	R10, CSR(MSTATUS)
	RET

TEXT	splx(SB), 1, $-4
	MOV	$mach0(SB), R12
	MOV	LINK, 0(R12)
	MOV	RARG, CSR(MSTATUS)
	RET

TEXT	islo(SB), 1, $-4
	MOV	CSR(MSTATUS), RARG
	AND	$MIEBIT, RARG
	RET

TEXT	idle(SB), 1, $-4
	WORD	$(0x10500073)		/* WFI */
	RET

TEXT	coherence(SB), 1, $-4
	FENCE
	RET

TEXT	rdcycle(SB), 1, $-4
	MOV	CSR(MCYCLE), RARG
	RET

/*
 * Install mtvec (direct mode).  Call mtimerie after programming mtimecmp.
 */
TEXT	vectorinit(SB), 1, $-4
	MOV	$trapvec(SB), R10
	MOV	R10, CSR(MTVEC)
	RET

TEXT	mtimerie(SB), 1, $-4
	MOV	CSR(MIE), R10
	OR	$MTIE, R10
	MOV	R10, CSR(MIE)
	RET

TEXT	mextie(SB), 1, $-4
	MOV	CSR(MIE), R10
	OR	$MEIE, R10
	MOV	R10, CSR(MIE)
	RET

/*
 * M-mode trap entry (direct mtvec).  Layout on interrupted stack:
 *	[SP, SP+TRAPPAD)	scratch for KenC frames
 *	[SP+TRAPPAD, +UREG)	Ureg
 *	SP+TRAPFRAME		interrupted SP
 */
TEXT	trapvec(SB), 1, $-4
	SUB	$TRAPFRAME, SP
	MOV	R1, (TRAPPAD+UREG_R1)(SP)
	MOV	R3, (TRAPPAD+UREG_R3)(SP)
	MOV	R4, (TRAPPAD+4*XLEN)(SP)
	MOV	R5, (TRAPPAD+5*XLEN)(SP)
	MOV	R6, (TRAPPAD+6*XLEN)(SP)
	MOV	R7, (TRAPPAD+7*XLEN)(SP)
	MOV	R8, (TRAPPAD+8*XLEN)(SP)
	MOV	R9, (TRAPPAD+9*XLEN)(SP)
	MOV	R10, (TRAPPAD+10*XLEN)(SP)
	MOV	R11, (TRAPPAD+11*XLEN)(SP)
	MOV	R12, (TRAPPAD+12*XLEN)(SP)
	MOV	R13, (TRAPPAD+13*XLEN)(SP)
	MOV	R14, (TRAPPAD+14*XLEN)(SP)
	MOV	R15, (TRAPPAD+15*XLEN)(SP)
	MOV	R16, (TRAPPAD+16*XLEN)(SP)
	MOV	R17, (TRAPPAD+17*XLEN)(SP)
	MOV	R18, (TRAPPAD+18*XLEN)(SP)
	MOV	R19, (TRAPPAD+19*XLEN)(SP)
	MOV	R20, (TRAPPAD+20*XLEN)(SP)
	MOV	R21, (TRAPPAD+21*XLEN)(SP)
	MOV	R22, (TRAPPAD+22*XLEN)(SP)
	MOV	R23, (TRAPPAD+23*XLEN)(SP)
	MOV	R24, (TRAPPAD+24*XLEN)(SP)
	MOV	R25, (TRAPPAD+25*XLEN)(SP)
	MOV	R26, (TRAPPAD+26*XLEN)(SP)
	MOV	R27, (TRAPPAD+27*XLEN)(SP)
	MOV	R28, (TRAPPAD+28*XLEN)(SP)
	MOV	R29, (TRAPPAD+29*XLEN)(SP)
	MOV	R30, (TRAPPAD+30*XLEN)(SP)
	MOV	R31, (TRAPPAD+31*XLEN)(SP)

	MOV	SP, R10
	ADD	$TRAPFRAME, R10
	MOV	R10, (TRAPPAD+UREG_SP)(SP)	/* interrupted SP */

	MOV	CSR(MEPC), R10
	MOV	R10, (TRAPPAD+UREG_PC)(SP)
	MOV	CSR(MSTATUS), R10
	MOV	R10, (TRAPPAD+UREG_STATUS)(SP)
	MOV	CSR(MIE), R10
	MOV	R10, (TRAPPAD+UREG_IE)(SP)
	MOV	CSR(MCAUSE), R10
	MOV	R10, (TRAPPAD+UREG_CAUSE)(SP)
	MOV	CSR(MTVAL), R10
	MOV	R10, (TRAPPAD+UREG_TVAL)(SP)
	MOV	R0, (TRAPPAD+UREG_CURMODE)(SP)

	MOV	$setSB(SB), R3
	MOV	SP, RARG
	ADD	$TRAPPAD, RARG			/* &Ureg */
	JAL	LINK, trap(SB)

	MOV	(TRAPPAD+UREG_PC)(SP), R10
	MOV	R10, CSR(MEPC)
	MOV	(TRAPPAD+UREG_STATUS)(SP), R10
	MOV	R10, CSR(MSTATUS)

	MOV	(TRAPPAD+UREG_R1)(SP), R1
	MOV	(TRAPPAD+UREG_R3)(SP), R3
	MOV	(TRAPPAD+4*XLEN)(SP), R4
	MOV	(TRAPPAD+5*XLEN)(SP), R5
	MOV	(TRAPPAD+6*XLEN)(SP), R6
	MOV	(TRAPPAD+7*XLEN)(SP), R7
	MOV	(TRAPPAD+8*XLEN)(SP), R8
	MOV	(TRAPPAD+9*XLEN)(SP), R9
	MOV	(TRAPPAD+10*XLEN)(SP), R10
	MOV	(TRAPPAD+11*XLEN)(SP), R11
	MOV	(TRAPPAD+12*XLEN)(SP), R12
	MOV	(TRAPPAD+13*XLEN)(SP), R13
	MOV	(TRAPPAD+14*XLEN)(SP), R14
	MOV	(TRAPPAD+15*XLEN)(SP), R15
	MOV	(TRAPPAD+16*XLEN)(SP), R16
	MOV	(TRAPPAD+17*XLEN)(SP), R17
	MOV	(TRAPPAD+18*XLEN)(SP), R18
	MOV	(TRAPPAD+19*XLEN)(SP), R19
	MOV	(TRAPPAD+20*XLEN)(SP), R20
	MOV	(TRAPPAD+21*XLEN)(SP), R21
	MOV	(TRAPPAD+22*XLEN)(SP), R22
	MOV	(TRAPPAD+23*XLEN)(SP), R23
	MOV	(TRAPPAD+24*XLEN)(SP), R24
	MOV	(TRAPPAD+25*XLEN)(SP), R25
	MOV	(TRAPPAD+26*XLEN)(SP), R26
	MOV	(TRAPPAD+27*XLEN)(SP), R27
	MOV	(TRAPPAD+28*XLEN)(SP), R28
	MOV	(TRAPPAD+29*XLEN)(SP), R29
	MOV	(TRAPPAD+30*XLEN)(SP), R30
	MOV	(TRAPPAD+31*XLEN)(SP), R31
	MOV	(TRAPPAD+UREG_SP)(SP), SP
	MRET
