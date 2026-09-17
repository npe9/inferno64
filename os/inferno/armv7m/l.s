#include "mem.h"
#include "armv7m.h"

/*
 * ARMv7-M entry, exception path and the machine primitives.
 *
 * The core comes out of reset in Thread mode using the main stack, and
 * this kernel never leaves that: Inferno's processes are kernel threads
 * that share one address space, so there is no user mode to enter and no
 * process stack to keep.  Everything runs privileged on MSP.
 *
 * The vector table has to be the first thing in the text segment, at the
 * address the board links its text to, because that is where the core
 * reads its initial stack pointer and reset address.  The mkfile puts
 * l.$O first in $OBJ for that reason.
 */

/* struct Ureg; keep in sync with Inferno/thumb/include/ureg.h */
#define	UREG_R0		0
#define	UREG_R4		16
#define	UREG_R8		32
#define	UREG_R12	48
#define	UREG_SP		52
#define	UREG_R14	56
#define	UREG_LINK	60
#define	UREG_TYPE	64
#define	UREG_PSR	68
#define	UREG_PC		72
#define	UREG_SIZE	80		/* 76 rounded up to 8 */

/*
 * The frame the core itself pushes: r0 r1 r2 r3 r12 lr pc xpsr.  It sits
 * immediately above the Ureg this code builds.
 */
#define	HW		UREG_SIZE
#define	HW_R0		(HW+0)
#define	HW_R1		(HW+4)
#define	HW_R2		(HW+8)
#define	HW_R3		(HW+12)
#define	HW_R12		(HW+16)
#define	HW_LR		(HW+20)
#define	HW_PC		(HW+24)
#define	HW_PSR		(HW+28)
#define	HWSIZE		32

#define	V1	WORD	$_trapentry(SB)
#define	V4	V1; V1; V1; V1
#define	V16	V4; V4; V4; V4
#define	V64	V16; V16; V16; V16

TEXT	_vectors(SB), 1, $-4
	WORD	$stack+KSTKSIZE(SB)	/* initial MSP */
	WORD	$_start(SB)		/* reset; the T bit is set for us */
	V4				/* 2 nmi, 3 hard, 4 mem, 5 bus */
	V4				/* 6 usage, 7-9 reserved */
	V4				/* 10 reserved, 11 svc, 12 debug, 13 reserved */
	V1				/* 14 pendsv */
	V1				/* 15 systick */
	IRQVECTORS			/* the board says how many it has */

TEXT	_start(SB), 1, $-4
	CPSID
	/* the vector table is at the start of our own text */
	MOVW	$_vectors(SB), R0
	MOVW	$SCB_VTOR, R1
	MOVW	R0, 0(R1)
	DSBSY
	ISBSY

	/*
	 * Let the floating point unit be used at all.  CPACR comes out of
	 * reset denying access to CP10 and CP11, so a VFP instruction
	 * faults; the C below is compiled with floating point in it and
	 * runs before anything could enable this from C.  What FPCCR has
	 * to say is settled later, in ../armv7m/fpu.c.
	 */
	MOVW	$SCB_CPACR, R1
	MOVW	0(R1), R0
	MOVW	$(CpacrCp10|CpacrCp11), R2
	ORR	R2, R0
	MOVW	R0, 0(R1)
	DSBSY
	ISBSY

	/* our own stack, in case the board was started with another one */
	MOVW	$stack+KSTKSIZE(SB), R0
	MSR(SYSM_MSP, 0)
	ISBSY

	/*
	 * The image is text then data, contiguous, so the data segment is
	 * in the file straight after the text.  On a board that runs its
	 * text from flash that is not where the data has to live, so copy
	 * it down before anything reads a variable.  bdata and edata are
	 * the linker's; etext is where the copy comes from.
	 */
	MOVW	$etext(SB), R0
	MOVW	$bdata(SB), R1
	MOVW	$edata(SB), R2
_datacopy:
	CMP	R2, R1
	BHS	_databss
	MOVW	0(R0), R3
	MOVW	R3, 0(R1)
	ADD	$4, R0
	ADD	$4, R1
	B	_datacopy

_databss:
	MOVW	$edata(SB), R0
	MOVW	$end(SB), R1
	MOVW	$0, R2
_bssclear:
	CMP	R1, R0
	BHS	_started
	MOVW	R2, 0(R0)
	ADD	$4, R0
	B	_bssclear

_started:
	BL	main(SB)
_dead:
	B	_dead
	/*
	 * Never reached.  utils/tl rewrites a DIV into a call to _div and
	 * the rest of ../../../libkern/div-thumb.s, but it does that
	 * after the libraries have been scanned, so nothing has asked for
	 * those members and they are not loaded.  Naming them here is how
	 * the ARM kernels this tree used to carry did it.
	 */
	BL	_div(SB)
	BL	_divu(SB)
	BL	_mod(SB)
	BL	_modu(SB)

GLOBL	stack(SB), $KSTKSIZE
GLOBL	mach0(SB), $MACHSIZE

/*
 * Exception entry.  The core has already pushed eight words and put an
 * EXC_RETURN value in R14; the rest of the state, and the numbering of
 * the exception, this code has to collect itself.
 */
TEXT	_trapentry(SB), 1, $-4
	SUB	$UREG_SIZE, R13

	MOVW	R4, (UREG_R4+0)(R13)
	MOVW	R5, (UREG_R4+4)(R13)
	MOVW	R6, (UREG_R4+8)(R13)
	MOVW	R7, (UREG_R4+12)(R13)
	MOVW	R8, R0			/* Thumb stores take a low register */
	MOVW	R0, (UREG_R8+0)(R13)
	MOVW	R9, R0
	MOVW	R0, (UREG_R8+4)(R13)
	MOVW	R10, R0
	MOVW	R0, (UREG_R8+8)(R13)
	MOVW	R11, R0
	MOVW	R0, (UREG_R8+12)(R13)
	MOVW	R14, R0			/* EXC_RETURN, needed to return */
	MOVW	R0, UREG_LINK(R13)

	MOVW	HW_R0(R13), R0
	MOVW	R0, (UREG_R0+0)(R13)
	MOVW	HW_R1(R13), R0
	MOVW	R0, (UREG_R0+4)(R13)
	MOVW	HW_R2(R13), R0
	MOVW	R0, (UREG_R0+8)(R13)
	MOVW	HW_R3(R13), R0
	MOVW	R0, (UREG_R0+12)(R13)
	MOVW	HW_R12(R13), R0
	MOVW	R0, UREG_R12(R13)
	MOVW	HW_LR(R13), R0
	MOVW	R0, UREG_R14(R13)
	MOVW	HW_PC(R13), R0
	MOVW	R0, UREG_PC(R13)
	MOVW	HW_PSR(R13), R0
	MOVW	R0, UREG_PSR(R13)

	/*
	 * The stack pointer the interrupted code had.  Bit 9 of the
	 * stacked xPSR says the core inserted a word to align the frame
	 * to eight bytes.
	 */
	MOVW	$(UREG_SIZE+HWSIZE)(R13), R1
	MOVW	$512, R2
	AND	R0, R2
	CMP	$0, R2
	BEQ	_noalign
	ADD	$4, R1
_noalign:
	MOVW	R1, UREG_SP(R13)

	MRS(SYSM_IPSR, 0)
	MOVW	R0, UREG_TYPE(R13)

	MOVW	$0(R13), R0		/* &Ureg */
	BL	trap(SB)

	MOVW	(UREG_R0+0)(R13), R0
	MOVW	R0, HW_R0(R13)
	MOVW	(UREG_R0+4)(R13), R0
	MOVW	R0, HW_R1(R13)
	MOVW	(UREG_R0+8)(R13), R0
	MOVW	R0, HW_R2(R13)
	MOVW	(UREG_R0+12)(R13), R0
	MOVW	R0, HW_R3(R13)
	MOVW	UREG_R12(R13), R0
	MOVW	R0, HW_R12(R13)
	MOVW	UREG_R14(R13), R0
	MOVW	R0, HW_LR(R13)
	MOVW	UREG_PC(R13), R0
	MOVW	R0, HW_PC(R13)
	MOVW	UREG_PSR(R13), R0
	MOVW	R0, HW_PSR(R13)

	MOVW	(UREG_R4+0)(R13), R4
	MOVW	(UREG_R4+4)(R13), R5
	MOVW	(UREG_R4+8)(R13), R6
	MOVW	(UREG_R4+12)(R13), R7
	MOVW	(UREG_R8+0)(R13), R0
	MOVW	R0, R8
	MOVW	(UREG_R8+4)(R13), R0
	MOVW	R0, R9
	MOVW	(UREG_R8+8)(R13), R0
	MOVW	R0, R10
	MOVW	(UREG_R8+12)(R13), R0
	MOVW	R0, R11

	MOVW	UREG_LINK(R13), R0
	MOVW	R0, R14
	ADD	$UREG_SIZE, R13
	BXR(14)				/* EXC_RETURN: the core pops the rest */

/*
 * Interrupt level.  PRIMASK is the whole of it: this kernel has one
 * priority, so masking is CPSID and the saved level is the old PRIMASK.
 */
TEXT	splhi(SB), 1, $-4
	MRS(SYSM_PRIMASK, 0)
	CPSID
	MOVW	$mach0(SB), R1
	MOVW	R14, R2
	MOVW	R2, 0(R1)		/* m->splpc */
	RET

TEXT	spllo(SB), 1, $-4
	MRS(SYSM_PRIMASK, 0)
	CPSIE
	RET

TEXT	splx(SB), 1, $-4
	MOVW	$mach0(SB), R1
	MOVW	R14, R2
	MOVW	R2, 0(R1)		/* m->splpc */
	MSR(SYSM_PRIMASK, 0)
	RET

TEXT	spldone(SB), 1, $-4
	RET

TEXT	islo(SB), 1, $-4
	MRS(SYSM_PRIMASK, 0)
	MOVW	$1, R1
	EOR	R1, R0			/* PRIMASK == 0 means interrupts are on */
	MOVW	$1, R1
	AND	R1, R0
	RET

TEXT	idle(SB), 1, $-4
	WFI
	RET

/*
 * A release barrier that is a barrier.  coherence() is what unlock()
 * relies on, and a store buffer with nothing ordering it is exactly the
 * bug that cost this tree a week on arm64, so this is a full DSB and not
 * a hint.
 */
/*
 * The floating point register file, out to memory and back.  128 bytes,
 * word aligned, S0 first.  The first argument is in R0 here (the same
 * convention _tas and setlabel below use).
 *
 * These touch no floating point arithmetic, only the transfers, so they
 * work on a Cortex-M4 whose FPv4-SP cannot do double precision.  That is
 * the point of them: os/inferno/armv7m/fpu.c turns FPCCR.ASPEN and
 * FPCCR.LSPEN off, so an exception does not stack the floating point
 * registers and they still hold the faulting instruction's operands when
 * a handler runs.
 */
TEXT	fpregsave(SB), 1, $-4
	VSTMIA32(0)
	RET

TEXT	fpregrestore(SB), 1, $-4
	VLDMIA32(0)
	RET

TEXT	coherence(SB), 1, $-4
	DSBSY
	RET

TEXT	_tas(SB), 1, $-4
	MOVW	R0, R3
_tas1:
	LDREXW(1, 3)
	MOVW	$1, R2
	STREXW(0, 2, 3)
	CMP	$0, R0
	BNE	_tas1
	DMBSY
	MOVW	R1, R0
	RET

TEXT	cmpswap(SB), 1, $-4
	MOVW	R0, R3			/* addr */
	MOVW	old+4(FP), R1
	MOVW	new+8(FP), R2
_cas1:
	LDREXW(0, 3)
	CMP	R1, R0
	BNE	_casfail
	STREXW(0, 2, 3)
	CMP	$0, R0
	BNE	_cas1
	DMBSY
	MOVW	$1, R0
	RET
_casfail:
	CLREX
	MOVW	$0, R0
	RET

TEXT	getcallerpc(SB), 1, $-4
	MOVW	0(R13), R0
	RET

TEXT	setlabel(SB), 1, $-4
	MOVW	R0, R2
	MOVW	$0(R13), R1
	MOVW	R1, 0(R2)		/* Label.sp */
	MOVW	R14, R1
	MOVW	R1, 4(R2)		/* Label.pc */
	MOVW	$0, R0
	RET

TEXT	gotolabel(SB), 1, $-4
	MOVW	0(R0), R1
	MOVW	4(R0), R2
	MOVW	R1, R13
	MOVW	R2, R14
	MOVW	$1, R0
	RET

/*
 * The first process starts here rather than at init0 so that there is a
 * frame under it on the new stack.
 */
TEXT	init0entry(SB), 1, $-4
	BL	init0(SB)
_dead0:
	B	_dead0

TEXT	archreboot(SB), 1, $-4
	CPSID
	DSBSY
	MOVW	$SCB_AIRCR, R1
	MOVW	$(AircrKey|AircrSysreset), R0
	MOVW	R0, 0(R1)
	DSBSY
_resetwait:
	B	_resetwait
