#include "mem.h"

/*
 * za's own register convention (utils/zc/z.out.h) is NOT jc's: REGARG/
 * REGRET=R1, REGSB=R26, REGSP=R27, REGTMP=R28, REGLINK=R31 -- entirely
 * different numbers from jc's R8/R3/R2/R4/R1.  Do not copy virt/l.s's
 * #defines across architectures; they were jc's role assignment, not a
 * RISC-V-wide one.  za also has no F-register file at all (checked
 * utils/zc/z.out.h -- no F0..F31, no ADDD/SUBD in utils/za/lex.c): this
 * port is integer-only, so the FPU-constant-priming block virt/l.s
 * carries for jc's F28-F31 double convention has no za equivalent and
 * is dropped here, not translated.
 */
#define LINK	R31
#define SP	R27
#define RARG	R1

/*
 * za's lexer has no built-in XLEN predefine the way ja's does (ja
 * special-cases thechar 'j' vs everything else); za is thechar 'z'
 * regardless of word width, so define it locally instead.
 */
#define XLEN	4

#define MASK(w)	((1<<(w))-1)
#define FENCE	WORD $(0xf | MASK(8)<<20)
#define AQ	(1<<26)
#define RL	(1<<25)
#define LRW(rs1, rd) \
	WORD $((2<<27)|(0<<20)|((rs1)<<15)|(2<<12)|((rd)<<7)|057|AQ)
#define SCW(rs2, rs1, rd) \
	WORD $((3<<27)|((rs2)<<20)|((rs1)<<15)|(2<<12)|((rd)<<7)|057|AQ|RL)

/*
 * za has no CSRRW/CSRRS/CSRRC operand form at all -- utils/za/a.y's only
 * production for LSYS (its class for these mnemonics) takes one bare
 * immediate, and utils/zl/optab.c has zero encoder entries for any of
 * them.  Hand-encode the two shapes this file needs, standard RISC-V
 * Zicsr I-type: csr[31:20] rs1[19:15] funct3[14:12] rd[11:7] 0x73.
 * funct3 1 = CSRRW, 2 = CSRRS.  Same pattern virt/l.s already uses for
 * WFI/MRET below, extended to the read/write forms this board needs.
 * Register arguments are bare numbers, matching LRW/SCW above.
 */
#define	CSRR(csr, rd)	WORD $(((csr)<<20)|(2<<12)|((rd)<<7)|0x73)
#define	CSRW(csr, rs1)	WORD $(((csr)<<20)|((rs1)<<15)|(1<<12)|0x73)

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
#define	MRET	WORD $(0x30200073)

/*
 * Ureg offsets (uintptr = 4 on riscv32); keep in sync with
 * Inferno/riscv32/include/ureg.h.  Field layout is positional (pc,
 * r1..r31, status, ie, cause, tval, curmode = 37 uintptr slots), not a
 * role table -- for za, r3's slot holds za's actual R3 (an ordinary
 * temp), not SB the way it holds jc's SB on riscv64, since za's SB is
 * R26.  Nothing in port/ C code reads ureg->r3 expecting SB (checked),
 * so this is cosmetic, but it means the riscv64 dat.h comment calling
 * that field sb does not apply to this board.
 */
#define	UREG_PC		0
#define	UREG_R1		4
#define	UREG_SP		8
#define	UREG_R3		12
#define	UREG_STATUS	128
#define	UREG_IE		132
#define	UREG_CAUSE	136
#define	UREG_TVAL	140
#define	UREG_CURMODE	144
#define	UREG_SIZE	160		/* 37*4 = 148, rounded to 16 */
/*
 * virt/l.s (jc/ja) uses TRAPPAD=2048 and gets away with load/store
 * offsets well past 2047 because ja auto-splits an out-of-range
 * immediate through a scratch register.  za does not (checked
 * empirically: zl rejects "MOVW Rn,2052(R27)" as an illegal
 * combination) -- RISC-V's S/I-type immediate is a hard 12 bits
 * signed on both RV32 and RV64, so this was never architectural, only
 * a feature ja has and za doesn't.  Keep every TRAPPAD+n*XLEN offset
 * inside +-2047 instead of relying on relaxation za can't do; 256
 * leaves the same "scratch space below Ureg for stray frame stores"
 * headroom the comment above TRAPPAD in virt/l.s describes, just
 * smaller, since it must fit the same single-instruction budget.
 */
#define	TRAPPAD		256
#define	TRAPFRAME	(TRAPPAD+UREG_SIZE)

/*
 * Entry for QEMU -M virt -bios none -kernel ivirt32.
 * Stack is SB-relative so lui sign-extension around 0x80000000 is
 * avoided, same reasoning as virt/l.s even though riscv32 lui doesn't
 * have riscv64's specific 64-bit-sign-extend failure mode -- untested
 * either way, so match the safer existing convention.
 */
TEXT	_main(SB), 1, $-4
	MOVW	$setSB(SB), R26
	MOVW	$stack+(64*1024)(SB), SP
	JAL	LINK, main(SB)
dead:
	JMP	dead

GLOBL	stack(SB), $(64*1024)
GLOBL	mach0(SB), $(4*1024)

TEXT	getcallerpc(SB), 1, $-4
	MOVW	0(FP), RARG
	RET

/*
 * virt/l.s's own _tas works unmodified for jc because jc's RARG is R8
 * -- the same register LRW(12,8) already leaves the pre-swap old
 * value in, so the return value lands in RARG as a side effect of
 * the register numbers chosen, not by design.  za's RARG is R1, so
 * copying the LRW/SCW calls verbatim silently returned R1's own
 * untouched value (the lock pointer itself, from the MOVW RARG,R12
 * two lines up) instead of the old lock word -- always nonzero, so
 * ilock() read every _tas() as "already held" even on a free lock
 * and spun forever on the very first (uncontended) call.  Found live
 * via QEMU/lldb: xinit()'s first ilock(&xlists) never returned.
 * Explicit copy into RARG at the end, rather than relying on the
 * macro's own destination register to coincide with it.
 */
TEXT	_tas(SB), 1, $-4
	MOVW	RARG, R12
	MOVW	$1, R10
	FENCE
tas1:
	LRW(12, 8)
	SCW(10, 12, 14)
	BNE	R14, tas1
	MOVW	R8, RARG
	RET

TEXT	setlabel(SB), 1, $-4
	MOVW	SP, 0(RARG)		/* sp */
	MOVW	LINK, 4(RARG)		/* pc */
	MOVW	R0, RARG
	RET

TEXT	gotolabel(SB), 1, $-4
	MOVW	0(RARG), SP
	MOVW	4(RARG), LINK
	MOVW	$setSB(SB), R26		/* C uses SB; restore after switch */
	MOVW	$1, RARG
	RET

/*
 * First process entry trampoline — keeps SB set on the new stack.
 */
TEXT	init0entry(SB), 1, $-4
	MOVW	$setSB(SB), R26
	JAL	LINK, init0(SB)
dead0:
	JMP	dead0

TEXT	splhi(SB), 1, $-4
	CSRR(MSTATUS, 10)
	MOVW	R10, RARG		/* return previous */
	MOVW	$~MIEBIT, R11
	AND	R11, R10
	CSRW(MSTATUS, 10)
	MOVW	$mach0(SB), R12
	MOVW	LINK, 0(R12)		/* m->splpc */
	RET

TEXT	spllo(SB), 1, $-4
	CSRR(MSTATUS, 10)
	MOVW	R10, RARG
	OR	$MIEBIT, R10
	CSRW(MSTATUS, 10)
	RET

TEXT	splx(SB), 1, $-4
	MOVW	$mach0(SB), R12
	MOVW	LINK, 0(R12)
	CSRW(MSTATUS, 1)
	RET

TEXT	islo(SB), 1, $-4
	CSRR(MSTATUS, 1)
	AND	$MIEBIT, RARG
	RET

TEXT	idle(SB), 1, $-4
	WORD	$(0x10500073)		/* WFI */
	RET

TEXT	coherence(SB), 1, $-4
	FENCE
	RET

TEXT	rdcycle(SB), 1, $-4
	CSRR(MCYCLE, 1)
	RET

/*
 * Install mtvec (direct mode).  Call mtimerie after programming mtimecmp.
 */
TEXT	vectorinit(SB), 1, $-4
	MOVW	$trapvec(SB), R10
	CSRW(MTVEC, 10)
	RET

TEXT	mtimerie(SB), 1, $-4
	CSRR(MIE, 10)
	OR	$MTIE, R10
	CSRW(MIE, 10)
	RET

TEXT	mextie(SB), 1, $-4
	CSRR(MIE, 10)
	/*
	 * MEIE is 2048 (bit 11) -- one past the +-2047 signed 12 bit
	 * immediate OR/ANDI/ADDI encode, so "OR $MEIE, R10" is not
	 * encodable as a single instruction (za rejected it: "illegal
	 * combination OR"). Build it in a register instead.
	 */
	MOVW	$1, R11
	SLL	$11, R11
	OR	R11, R10
	CSRW(MIE, 10)
	RET

/*
 * M-mode trap entry (direct mtvec).  Layout on interrupted stack:
 *	[SP, SP+TRAPPAD)	scratch for KenC frames
 *	[SP+TRAPPAD, +UREG)	Ureg
 *	SP+TRAPFRAME		interrupted SP
 */
TEXT	trapvec(SB), 1, $-4
	SUB	$TRAPFRAME, SP
	MOVW	R1, (TRAPPAD+UREG_R1)(SP)
	MOVW	R3, (TRAPPAD+UREG_R3)(SP)
	MOVW	R4, (TRAPPAD+4*XLEN)(SP)
	MOVW	R5, (TRAPPAD+5*XLEN)(SP)
	MOVW	R6, (TRAPPAD+6*XLEN)(SP)
	MOVW	R7, (TRAPPAD+7*XLEN)(SP)
	MOVW	R8, (TRAPPAD+8*XLEN)(SP)
	MOVW	R9, (TRAPPAD+9*XLEN)(SP)
	MOVW	R10, (TRAPPAD+10*XLEN)(SP)
	MOVW	R11, (TRAPPAD+11*XLEN)(SP)
	MOVW	R12, (TRAPPAD+12*XLEN)(SP)
	MOVW	R13, (TRAPPAD+13*XLEN)(SP)
	MOVW	R14, (TRAPPAD+14*XLEN)(SP)
	MOVW	R15, (TRAPPAD+15*XLEN)(SP)
	MOVW	R16, (TRAPPAD+16*XLEN)(SP)
	MOVW	R17, (TRAPPAD+17*XLEN)(SP)
	MOVW	R18, (TRAPPAD+18*XLEN)(SP)
	MOVW	R19, (TRAPPAD+19*XLEN)(SP)
	MOVW	R20, (TRAPPAD+20*XLEN)(SP)
	MOVW	R21, (TRAPPAD+21*XLEN)(SP)
	MOVW	R22, (TRAPPAD+22*XLEN)(SP)
	MOVW	R23, (TRAPPAD+23*XLEN)(SP)
	MOVW	R24, (TRAPPAD+24*XLEN)(SP)
	MOVW	R25, (TRAPPAD+25*XLEN)(SP)
	MOVW	R26, (TRAPPAD+26*XLEN)(SP)
	MOVW	R28, (TRAPPAD+28*XLEN)(SP)
	MOVW	R29, (TRAPPAD+29*XLEN)(SP)
	MOVW	R30, (TRAPPAD+30*XLEN)(SP)
	MOVW	R31, (TRAPPAD+31*XLEN)(SP)

	MOVW	SP, R10
	ADD	$TRAPFRAME, R10
	MOVW	R10, (TRAPPAD+UREG_SP)(SP)	/* interrupted SP */

	CSRR(MEPC, 10)
	MOVW	R10, (TRAPPAD+UREG_PC)(SP)
	CSRR(MSTATUS, 10)
	MOVW	R10, (TRAPPAD+UREG_STATUS)(SP)
	CSRR(MIE, 10)
	MOVW	R10, (TRAPPAD+UREG_IE)(SP)
	CSRR(MCAUSE, 10)
	MOVW	R10, (TRAPPAD+UREG_CAUSE)(SP)
	CSRR(MTVAL, 10)
	MOVW	R10, (TRAPPAD+UREG_TVAL)(SP)
	MOVW	R0, (TRAPPAD+UREG_CURMODE)(SP)

	MOVW	$setSB(SB), R26
	MOVW	SP, RARG
	ADD	$TRAPPAD, RARG			/* &Ureg */
	JAL	LINK, trap(SB)

	MOVW	(TRAPPAD+UREG_PC)(SP), R10
	CSRW(MEPC, 10)
	MOVW	(TRAPPAD+UREG_STATUS)(SP), R10
	CSRW(MSTATUS, 10)

	MOVW	(TRAPPAD+UREG_R1)(SP), R1
	MOVW	(TRAPPAD+UREG_R3)(SP), R3
	MOVW	(TRAPPAD+4*XLEN)(SP), R4
	MOVW	(TRAPPAD+5*XLEN)(SP), R5
	MOVW	(TRAPPAD+6*XLEN)(SP), R6
	MOVW	(TRAPPAD+7*XLEN)(SP), R7
	MOVW	(TRAPPAD+8*XLEN)(SP), R8
	MOVW	(TRAPPAD+9*XLEN)(SP), R9
	MOVW	(TRAPPAD+10*XLEN)(SP), R10
	MOVW	(TRAPPAD+11*XLEN)(SP), R11
	MOVW	(TRAPPAD+12*XLEN)(SP), R12
	MOVW	(TRAPPAD+13*XLEN)(SP), R13
	MOVW	(TRAPPAD+14*XLEN)(SP), R14
	MOVW	(TRAPPAD+15*XLEN)(SP), R15
	MOVW	(TRAPPAD+16*XLEN)(SP), R16
	MOVW	(TRAPPAD+17*XLEN)(SP), R17
	MOVW	(TRAPPAD+18*XLEN)(SP), R18
	MOVW	(TRAPPAD+19*XLEN)(SP), R19
	MOVW	(TRAPPAD+20*XLEN)(SP), R20
	MOVW	(TRAPPAD+21*XLEN)(SP), R21
	MOVW	(TRAPPAD+22*XLEN)(SP), R22
	MOVW	(TRAPPAD+23*XLEN)(SP), R23
	MOVW	(TRAPPAD+24*XLEN)(SP), R24
	MOVW	(TRAPPAD+25*XLEN)(SP), R25
	MOVW	(TRAPPAD+26*XLEN)(SP), R26
	MOVW	(TRAPPAD+28*XLEN)(SP), R28
	MOVW	(TRAPPAD+29*XLEN)(SP), R29
	MOVW	(TRAPPAD+30*XLEN)(SP), R30
	MOVW	(TRAPPAD+31*XLEN)(SP), R31
	MOVW	(TRAPPAD+UREG_SP)(SP), SP
	MRET
