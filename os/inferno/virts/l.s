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

/*
 * Supervisor-mode CSRs.  This board is entered by OpenSBI (QEMU's
 * default -bios) in S-mode, not by -bios none in M-mode like the virt
 * board, so every trap/status/timer CSR is the S-mode one and the
 * return from trap is SRET.  OpenSBI has already delegated the S-mode
 * interrupts and the usual exceptions to us via medeleg/mideleg.
 */
#define	SSTATUS	0x100
#define	SIE	0x104
#define	STVEC	0x105
#define	SEPC	0x141
#define	SCAUSE	0x142
#define	STVAL	0x143
#define	RDCYCLE	0xC00		/* cycle (read-only shadow of mcycle) */
#define	SIEBIT	2		/* sstatus.SIE (bit 1) */
#define	STIE	32		/* sie.STIE — supervisor timer (bit 5) */
#define	SEIE	512		/* sie.SEIE — supervisor external/PLIC (bit 9) */
#define	FSBITS	(3<<13)		/* sstatus.FS = Dirty — enable FPU */
#define	SRET	WORD $(0x10200073)
#define	ECALL	WORD $(0x00000073)

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
 * Entry from OpenSBI (S-mode) for QEMU -M virt -kernel ivirts.
 * OpenSBI passes a0=hartid, a1=DTB and has set up PMP/delegation.
 * Stack is SB-relative so RV64 lui sign-extension is avoided.
 */
TEXT	_main(SB), 1, $-8
	MOV	$setSB(SB), R3
	MOV	R11, dtbptr(SB)		/* a1 holds the DTB physical address at boot */
	MOV	$stack+(64*1024)(SB), SP
	MOV	CSR(SSTATUS), R10
	OR	$FSBITS, R10
	MOV	R10, CSR(SSTATUS)
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

GLOBL	dtbptr(SB), $8
GLOBL	fbits(SB), $8
GLOBL	stack(SB), $(64*1024)
GLOBL	mach0(SB), $(4*1024)

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
	MOV	CSR(SSTATUS), R10
	MOV	R10, RARG		/* return previous */
	MOV	$~SIEBIT, R11
	AND	R11, R10
	MOV	R10, CSR(SSTATUS)
	MOV	$mach0(SB), R12
	MOV	LINK, 0(R12)		/* m->splpc; 8 bytes, so dat.h makes it uintptr */
	RET

TEXT	spllo(SB), 1, $-4
	MOV	CSR(SSTATUS), R10
	MOV	R10, RARG
	OR	$SIEBIT, R10
	MOV	R10, CSR(SSTATUS)
	RET

TEXT	splx(SB), 1, $-4
	MOV	$mach0(SB), R12
	MOV	LINK, 0(R12)
	MOV	RARG, CSR(SSTATUS)
	RET

TEXT	islo(SB), 1, $-4
	MOV	CSR(SSTATUS), RARG
	AND	$SIEBIT, RARG
	RET

TEXT	idle(SB), 1, $-4
	WORD	$(0x10500073)		/* WFI */
	RET

TEXT	coherence(SB), 1, $-4
	FENCE
	RET

TEXT	rdcycle(SB), 1, $-4
	MOV	CSR(RDCYCLE), RARG
	RET

/*
 * Install stvec (direct mode).  Call mtimerie after arming the SBI timer.
 */
TEXT	vectorinit(SB), 1, $-4
	MOV	$trapvec(SB), R10
	MOV	R10, CSR(STVEC)
	RET

TEXT	mtimerie(SB), 1, $-4
	MOV	CSR(SIE), R10
	OR	$STIE, R10
	MOV	R10, CSR(SIE)
	RET

TEXT	mextie(SB), 1, $-4
	MOV	CSR(SIE), R10
	OR	$SEIE, R10
	MOV	R10, CSR(SIE)
	RET

/*
 * S-mode has no direct CLINT mtimecmp; the timer is armed through the
 * SBI legacy set_timer call (EID 0, value in a0), which also clears the
 * pending supervisor timer interrupt.  clock.c/stubs.c call this where
 * the virt board wrote ClintMtimecmp.  Plan 9 riscv passes the first
 * arg in RARG (R8); SBI wants it in a0 (R10).
 */
TEXT	sbisettimer(SB), 1, $-4
	MOV	RARG, R10		/* a0 = absolute time to fire */
	MOV	$0, R17			/* a7 = SBI set_timer (legacy EID 0) */
	ECALL
	RET

/*
 * The monotonic tick.  The virt board reads CLINT mtime MMIO, which
 * OpenSBI may PMP-protect from S-mode; the architected S-mode way is
 * the time CSR (0xC01), readable because OpenSBI sets mcounteren.TM.
 */
TEXT	rdtime(SB), 1, $-4
	MOV	CSR(0xC01), RARG
	RET

/*
 * SBI SRST (system reset), EID 0x53525354 FID 0.  a0 = reset type
 * (0 shutdown, 1 cold reboot), a1 = reason.  OpenSBI 2.0 backs this
 * with QEMU's syscon-poweroff/reboot, so exit() actually stops the
 * machine instead of spinning in WFI.  Does not return.
 */
TEXT	sbisystemreset(SB), 1, $-4
	MOV	RARG, R10		/* a0 = reset type */
	MOV	$0, R11			/* a1 = reason 0 */
	MOV	$0, R16			/* a6 = FID 0 (system_reset) */
	MOV	$0x53525354, R17	/* a7 = "SRST" */
	ECALL
	RET

/*
 * S-mode trap entry (direct stvec).  Layout on interrupted stack:
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

	MOV	CSR(SEPC), R10
	MOV	R10, (TRAPPAD+UREG_PC)(SP)
	MOV	CSR(SSTATUS), R10
	MOV	R10, (TRAPPAD+UREG_STATUS)(SP)
	MOV	CSR(SIE), R10
	MOV	R10, (TRAPPAD+UREG_IE)(SP)
	MOV	CSR(SCAUSE), R10
	MOV	R10, (TRAPPAD+UREG_CAUSE)(SP)
	MOV	CSR(STVAL), R10
	MOV	R10, (TRAPPAD+UREG_TVAL)(SP)
	MOV	R0, (TRAPPAD+UREG_CURMODE)(SP)

	MOV	$setSB(SB), R3
	MOV	SP, RARG
	ADD	$TRAPPAD, RARG			/* &Ureg */
	JAL	LINK, trap(SB)

	MOV	(TRAPPAD+UREG_PC)(SP), R10
	MOV	R10, CSR(SEPC)
	MOV	(TRAPPAD+UREG_STATUS)(SP), R10
	MOV	R10, CSR(SSTATUS)

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
	SRET
