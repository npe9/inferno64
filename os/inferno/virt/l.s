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
#define	MEIE	2048		/* mie.MEIE — machine external (PLIC) */
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
 * Entry for QEMU -M virt -bios none -kernel ivirt.
 * Stack is SB-relative so RV64 lui sign-extension is avoided.
 */
TEXT	_main(SB), 1, $-8
	MOV	$setSB(SB), R3
	MOV	R11, dtbptr(SB)		/* a1 holds the DTB physical address at boot */
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

/*
 * The H extension's world switch (vmrv.c).  This kernel runs in
 * machine mode, so a guest is entered with MRET, mstatus.MPV set and
 * MPP supervisor -- VS-mode -- and every trap it does not delegate
 * comes back to machine mode, through mtvec, which points at rvexit
 * while the guest runs.  Rvcpu, in vmrv.c, holds the guest's state at
 * these offsets.  The C calling convention keeps nothing in registers
 * across a call but SP, the link and SB (setlabel saves no more), so
 * those are all of the host that is kept; the floating-point
 * registers are swapped whole, F28 to F31 being the compiler's
 * constants.
 */
#define	MSCRATCH	0x340
#define	FCSR		0x003
#define	RV_PC		256
#define	RV_HOSTSP	264
#define	RV_HOSTRA	272
#define	RV_MSTATUS	280
#define	RV_MCAUSE	288
#define	RV_MTVAL	296
#define	RV_MTVAL2	304
#define	RV_MTINST	312
#define	RV_F		320
#define	RV_FCSR		576
#define	RV_HOSTF	584
#define	RV_HOSTFCSR	840
#define	CSRRWSCRATCH8	WORD $0x34041473	/* csrrw x8, mscratch, x8 */

#define	SAVEF(o) \
	MOVD	F0, (o+0*8)(R8); MOVD	F1, (o+1*8)(R8); MOVD	F2, (o+2*8)(R8); MOVD	F3, (o+3*8)(R8);\
	MOVD	F4, (o+4*8)(R8); MOVD	F5, (o+5*8)(R8); MOVD	F6, (o+6*8)(R8); MOVD	F7, (o+7*8)(R8);\
	MOVD	F8, (o+8*8)(R8); MOVD	F9, (o+9*8)(R8); MOVD	F10, (o+10*8)(R8); MOVD	F11, (o+11*8)(R8);\
	MOVD	F12, (o+12*8)(R8); MOVD	F13, (o+13*8)(R8); MOVD	F14, (o+14*8)(R8); MOVD	F15, (o+15*8)(R8);\
	MOVD	F16, (o+16*8)(R8); MOVD	F17, (o+17*8)(R8); MOVD	F18, (o+18*8)(R8); MOVD	F19, (o+19*8)(R8);\
	MOVD	F20, (o+20*8)(R8); MOVD	F21, (o+21*8)(R8); MOVD	F22, (o+22*8)(R8); MOVD	F23, (o+23*8)(R8);\
	MOVD	F24, (o+24*8)(R8); MOVD	F25, (o+25*8)(R8); MOVD	F26, (o+26*8)(R8); MOVD	F27, (o+27*8)(R8);\
	MOVD	F28, (o+28*8)(R8); MOVD	F29, (o+29*8)(R8); MOVD	F30, (o+30*8)(R8); MOVD	F31, (o+31*8)(R8)

#define	LOADF(o) \
	MOVD	(o+0*8)(R8), F0; MOVD	(o+1*8)(R8), F1; MOVD	(o+2*8)(R8), F2; MOVD	(o+3*8)(R8), F3;\
	MOVD	(o+4*8)(R8), F4; MOVD	(o+5*8)(R8), F5; MOVD	(o+6*8)(R8), F6; MOVD	(o+7*8)(R8), F7;\
	MOVD	(o+8*8)(R8), F8; MOVD	(o+9*8)(R8), F9; MOVD	(o+10*8)(R8), F10; MOVD	(o+11*8)(R8), F11;\
	MOVD	(o+12*8)(R8), F12; MOVD	(o+13*8)(R8), F13; MOVD	(o+14*8)(R8), F14; MOVD	(o+15*8)(R8), F15;\
	MOVD	(o+16*8)(R8), F16; MOVD	(o+17*8)(R8), F17; MOVD	(o+18*8)(R8), F18; MOVD	(o+19*8)(R8), F19;\
	MOVD	(o+20*8)(R8), F20; MOVD	(o+21*8)(R8), F21; MOVD	(o+22*8)(R8), F22; MOVD	(o+23*8)(R8), F23;\
	MOVD	(o+24*8)(R8), F24; MOVD	(o+25*8)(R8), F25; MOVD	(o+26*8)(R8), F26; MOVD	(o+27*8)(R8), F27;\
	MOVD	(o+28*8)(R8), F28; MOVD	(o+29*8)(R8), F29; MOVD	(o+30*8)(R8), F30; MOVD	(o+31*8)(R8), F31

/*
 * rvrun(Rvcpu*): enter the guest, interrupts off, mepc, mstatus and
 * the VS CSRs already set by the caller; back when it traps.
 */
TEXT	rvrun(SB), 1, $-4
	MOV	SP, RV_HOSTSP(R8)
	MOV	LINK, RV_HOSTRA(R8)
	SAVEF(RV_HOSTF)
	MOV	CSR(FCSR), R10
	MOV	R10, RV_HOSTFCSR(R8)
	LOADF(RV_F)
	MOV	RV_FCSR(R8), R10
	MOV	R10, CSR(FCSR)
	MOV	RV_PC(R8), R10
	MOV	R10, CSR(MEPC)
	MOV	RV_MSTATUS(R8), R10
	MOV	R10, CSR(MSTATUS)
	MOV	R8, CSR(MSCRATCH)
	MOV	$rvexit(SB), R10
	MOV	R10, CSR(MTVEC)
	MOV	(1*8)(R8), R1
	MOV	(2*8)(R8), R2
	MOV	(3*8)(R8), R3
	MOV	(4*8)(R8), R4
	MOV	(5*8)(R8), R5
	MOV	(6*8)(R8), R6
	MOV	(7*8)(R8), R7
	MOV	(9*8)(R8), R9
	MOV	(10*8)(R8), R10
	MOV	(11*8)(R8), R11
	MOV	(12*8)(R8), R12
	MOV	(13*8)(R8), R13
	MOV	(14*8)(R8), R14
	MOV	(15*8)(R8), R15
	MOV	(16*8)(R8), R16
	MOV	(17*8)(R8), R17
	MOV	(18*8)(R8), R18
	MOV	(19*8)(R8), R19
	MOV	(20*8)(R8), R20
	MOV	(21*8)(R8), R21
	MOV	(22*8)(R8), R22
	MOV	(23*8)(R8), R23
	MOV	(24*8)(R8), R24
	MOV	(25*8)(R8), R25
	MOV	(26*8)(R8), R26
	MOV	(27*8)(R8), R27
	MOV	(28*8)(R8), R28
	MOV	(29*8)(R8), R29
	MOV	(30*8)(R8), R30
	MOV	(31*8)(R8), R31
	MOV	(8*8)(R8), R8
	MRET

/*
 * The guest trapped: mscratch holds its Rvcpu.  Save it, put the
 * host's trap vector back, and return from rvrun.
 */
TEXT	rvexit(SB), 1, $-4
	CSRRWSCRATCH8
	MOV	R1, (1*8)(R8)
	MOV	R2, (2*8)(R8)
	MOV	R3, (3*8)(R8)
	MOV	R4, (4*8)(R8)
	MOV	R5, (5*8)(R8)
	MOV	R6, (6*8)(R8)
	MOV	R7, (7*8)(R8)
	MOV	R9, (9*8)(R8)
	MOV	R10, (10*8)(R8)
	MOV	R11, (11*8)(R8)
	MOV	R12, (12*8)(R8)
	MOV	R13, (13*8)(R8)
	MOV	R14, (14*8)(R8)
	MOV	R15, (15*8)(R8)
	MOV	R16, (16*8)(R8)
	MOV	R17, (17*8)(R8)
	MOV	R18, (18*8)(R8)
	MOV	R19, (19*8)(R8)
	MOV	R20, (20*8)(R8)
	MOV	R21, (21*8)(R8)
	MOV	R22, (22*8)(R8)
	MOV	R23, (23*8)(R8)
	MOV	R24, (24*8)(R8)
	MOV	R25, (25*8)(R8)
	MOV	R26, (26*8)(R8)
	MOV	R27, (27*8)(R8)
	MOV	R28, (28*8)(R8)
	MOV	R29, (29*8)(R8)
	MOV	R30, (30*8)(R8)
	MOV	R31, (31*8)(R8)
	MOV	CSR(MSCRATCH), R10
	MOV	R10, (8*8)(R8)
	MOV	CSR(MEPC), R10
	MOV	R10, RV_PC(R8)
	MOV	CSR(MSTATUS), R10
	MOV	R10, RV_MSTATUS(R8)
	MOV	CSR(MCAUSE), R10
	MOV	R10, RV_MCAUSE(R8)
	MOV	CSR(MTVAL), R10
	MOV	R10, RV_MTVAL(R8)
	MOV	CSR(0x34B), R10		/* mtval2: the guest-physical address >> 2 */
	MOV	R10, RV_MTVAL2(R8)
	MOV	CSR(0x34A), R10		/* mtinst */
	MOV	R10, RV_MTINST(R8)
	SAVEF(RV_F)
	MOV	CSR(FCSR), R10
	MOV	R10, RV_FCSR(R8)
	LOADF(RV_HOSTF)
	MOV	RV_HOSTFCSR(R8), R10
	MOV	R10, CSR(FCSR)
	MOV	$setSB(SB), R3
	MOV	$trapvec(SB), R10
	MOV	R10, CSR(MTVEC)
	MOV	RV_HOSTSP(R8), SP
	MOV	RV_HOSTRA(R8), LINK
	RET

/* the CSRs vmrv.c reads and writes, one function each: the number is in the instruction */
TEXT	csrrdmisa(SB), 1, $-4
	MOV	CSR(0x301), RARG
	RET

TEXT	csrrdmstatus(SB), 1, $-4
	MOV	CSR(0x300), RARG
	RET

TEXT	csrrdhgatp(SB), 1, $-4
	MOV	CSR(0x680), RARG
	RET

TEXT	csrrdhstatus(SB), 1, $-4
	MOV	CSR(0x600), RARG
	RET

TEXT	csrrdhvip(SB), 1, $-4
	MOV	CSR(0x645), RARG
	RET

TEXT	csrrdvsstatus(SB), 1, $-4
	MOV	CSR(0x200), RARG
	RET

TEXT	csrrdvsie(SB), 1, $-4
	MOV	CSR(0x204), RARG
	RET

TEXT	csrrdvstvec(SB), 1, $-4
	MOV	CSR(0x205), RARG
	RET

TEXT	csrrdvsscratch(SB), 1, $-4
	MOV	CSR(0x240), RARG
	RET

TEXT	csrrdvsepc(SB), 1, $-4
	MOV	CSR(0x241), RARG
	RET

TEXT	csrrdvscause(SB), 1, $-4
	MOV	CSR(0x242), RARG
	RET

TEXT	csrrdvstval(SB), 1, $-4
	MOV	CSR(0x243), RARG
	RET

TEXT	csrrdvsatp(SB), 1, $-4
	MOV	CSR(0x280), RARG
	RET

TEXT	csrwrmedeleg(SB), 1, $-4
	MOV	RARG, CSR(0x302)
	RET

TEXT	csrwrmcounteren(SB), 1, $-4
	MOV	RARG, CSR(0x306)
	RET

TEXT	csrwrmstatus(SB), 1, $-4
	MOV	RARG, CSR(0x300)
	RET

TEXT	csrwrpmpcfg0(SB), 1, $-4
	MOV	RARG, CSR(0x3a0)
	RET

TEXT	csrwrpmpaddr0(SB), 1, $-4
	MOV	RARG, CSR(0x3b0)
	RET

TEXT	csrwrhstatus(SB), 1, $-4
	MOV	RARG, CSR(0x600)
	RET

TEXT	csrwrhedeleg(SB), 1, $-4
	MOV	RARG, CSR(0x602)
	RET

TEXT	csrwrhideleg(SB), 1, $-4
	MOV	RARG, CSR(0x603)
	RET

TEXT	csrwrhcounteren(SB), 1, $-4
	MOV	RARG, CSR(0x606)
	RET

TEXT	csrwrhtimedelta(SB), 1, $-4
	MOV	RARG, CSR(0x605)
	RET

TEXT	csrwrhvip(SB), 1, $-4
	MOV	RARG, CSR(0x645)
	RET

TEXT	csrwrhgatp(SB), 1, $-4
	MOV	RARG, CSR(0x680)
	RET

TEXT	csrwrvsstatus(SB), 1, $-4
	MOV	RARG, CSR(0x200)
	RET

TEXT	csrwrvsie(SB), 1, $-4
	MOV	RARG, CSR(0x204)
	RET

TEXT	csrwrvstvec(SB), 1, $-4
	MOV	RARG, CSR(0x205)
	RET

TEXT	csrwrvsscratch(SB), 1, $-4
	MOV	RARG, CSR(0x240)
	RET

TEXT	csrwrvsepc(SB), 1, $-4
	MOV	RARG, CSR(0x241)
	RET

TEXT	csrwrvscause(SB), 1, $-4
	MOV	RARG, CSR(0x242)
	RET

TEXT	csrwrvstval(SB), 1, $-4
	MOV	RARG, CSR(0x243)
	RET

TEXT	csrwrvsatp(SB), 1, $-4
	MOV	RARG, CSR(0x280)
	RET

TEXT	rvhfencegvma(SB), 1, $-4
	WORD	$0x62000073	/* hfence.gvma zero, zero */
	RET

TEXT	rvhfencevvma(SB), 1, $-4
	WORD	$0x22000073	/* hfence.vvma zero, zero */
	RET

TEXT	rvfencei(SB), 1, $-4
	WORD	$0x0000100F	/* fence.i */
	RET

/* the machine-level IMSIC (trap.c), through its indirect registers */
TEXT	csrwrmiselect(SB), 1, $-4
	MOV	RARG, CSR(0x350)
	RET

TEXT	csrrdmireg(SB), 1, $-4
	MOV	CSR(0x351), RARG
	RET

TEXT	csrwrmireg(SB), 1, $-4
	MOV	RARG, CSR(0x351)
	RET

TEXT	csrclaimmtopei(SB), 1, $-4
	WORD	$0x35C01473	/* csrrw x8, mtopei, x0: the top identity, claimed */
	RET

TEXT	csrrdvsiselect(SB), 1, $-4
	MOV	CSR(0x250), RARG
	RET

TEXT	csrwrvsiselect(SB), 1, $-4
	MOV	RARG, CSR(0x250)
	RET

TEXT	csrrdhgeip(SB), 1, $-4
	MOV	CSR(0xE12), RARG
	RET
