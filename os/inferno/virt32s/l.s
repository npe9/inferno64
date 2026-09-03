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

/*
 * Supervisor-mode CSRs: this board is entered by OpenSBI in S-mode, so
 * every trap/status CSR is the S-mode one and the trap return is SRET.
 * The interrupt-enable bit positions differ from M-mode: sstatus.SIE is
 * bit 1, sie.STIE bit 5, sie.SEIE bit 9 (and SEIE 512 now fits the
 * signed 12-bit immediate an OR encodes, unlike M-mode's MEIE 2048).
 */
#define	SSTATUS	0x100
#define	SIE	0x104
#define	STVEC	0x105
#define	SEPC	0x141
#define	SCAUSE	0x142
#define	STVAL	0x143
#define	RDCYCLE	0xC00		/* cycle CSR (read-only) */
#define	TIMECSR	0xC01		/* time (low 32) */
#define	TIMEHCSR 0xC81		/* timeh (high 32) — rv32 only */
#define	SIEBIT	2		/* sstatus.SIE (bit 1) */
#define	STIE	32		/* sie.STIE — supervisor timer (bit 5) */
#define	SEIE	512		/* sie.SEIE — supervisor external/PLIC (bit 9) */
#define	FSBITS	(3<<13)		/* sstatus.FS = Dirty — enable FPU */
#define	SRET	WORD $(0x10200073)
#define	ECALL	WORD $(0x00000073)

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
 * Entry from OpenSBI (S-mode) for QEMU -M virt -kernel ivirt32s.
 * Stack is SB-relative so lui sign-extension around 0x80000000 is
 * avoided, same reasoning as virt/l.s even though riscv32 lui doesn't
 * have riscv64's specific 64-bit-sign-extend failure mode -- untested
 * either way, so match the safer existing convention.
 */
TEXT	_main(SB), 1, $-4
	MOVW	$setSB(SB), R26
	MOVW	R11, dtbptr(SB)		/* a1 = DTB pointer from OpenSBI, before R11 is reused */
	MOVW	$stack+(64*1024)(SB), SP
	/*
	 * mstatus.FS resets to 0 (Off): any F/D instruction traps as
	 * illegal, cause 2, until this is set -- not needed when this
	 * file was first written (za/zc had no float support then),
	 * forgotten when that support was added later.  Found live:
	 * epc pointed at an FLD, tval decoded byte-for-byte to
	 * "FLD f0,436(x28)" -- a real, legal instruction, illegal
	 * only because FS was off.  za has no CSR-with-register-
	 * operand form (see the CSRR/CSRW macros above), same
	 * WORD-immediate-shift workaround MEIE already needed since
	 * FSBITS is also past the +-2047 signed 12 bit immediate an
	 * OR can encode directly.
	 */
	CSRR(SSTATUS, 10)
	MOVW	$3, R11
	SLL	$13, R11
	OR	R11, R10
	CSRW(SSTATUS, 10)
	JAL	LINK, main(SB)
dead:
	JMP	dead

GLOBL	dtbptr(SB), $4
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
	CSRR(SSTATUS, 10)
	MOVW	R10, RARG		/* return previous */
	MOVW	$~SIEBIT, R11
	AND	R11, R10
	CSRW(SSTATUS, 10)
	MOVW	$mach0(SB), R12
	MOVW	LINK, 0(R12)		/* m->splpc */
	RET

TEXT	spllo(SB), 1, $-4
	CSRR(SSTATUS, 10)
	MOVW	R10, RARG
	OR	$SIEBIT, R10
	CSRW(SSTATUS, 10)
	RET

TEXT	splx(SB), 1, $-4
	MOVW	$mach0(SB), R12
	MOVW	LINK, 0(R12)
	CSRW(SSTATUS, 1)
	RET

TEXT	islo(SB), 1, $-4
	CSRR(SSTATUS, 1)
	AND	$SIEBIT, RARG
	RET

TEXT	idle(SB), 1, $-4
	WORD	$(0x10500073)		/* WFI */
	RET

TEXT	coherence(SB), 1, $-4
	FENCE
	RET

TEXT	rdcycle(SB), 1, $-4
	CSRR(RDCYCLE, 1)
	RET

/*
 * Install stvec (direct mode).  Call mtimerie after arming the SBI timer.
 */
TEXT	vectorinit(SB), 1, $-4
	MOVW	$trapvec(SB), R10
	CSRW(STVEC, 10)
	RET

TEXT	mtimerie(SB), 1, $-4
	CSRR(SIE, 10)
	OR	$STIE, R10
	CSRW(SIE, 10)
	RET

TEXT	mextie(SB), 1, $-4
	CSRR(SIE, 10)
	OR	$SEIE, R10		/* SEIE 512 fits the 12-bit immediate */
	CSRW(SIE, 10)
	RET

/*
 * rv32 has no 64-bit register, so the 64-bit monotonic counter is two
 * CSRs: time (low) and timeh (high).  These return one 32-bit half each
 * in RARG; clock.c does the standard read-hi/read-lo/read-hi-again
 * retry in C (where an ulong compare is reliable), avoiding a 64-bit
 * value in a single register or a two-register branch in za.
 */
TEXT	rdtimelo(SB), 1, $-4
	CSRR(TIMECSR, 1)
	RET

TEXT	rdtimehi(SB), 1, $-4
	CSRR(TIMEHCSR, 1)
	RET

/*
 * SBI legacy set_timer.  On rv32 the 64-bit deadline is passed as
 * a0=low, a1=high; clock.c splits its uvlong into the two ulong globals
 * sbitimerlo/sbitimerhi (the compiler handles that split), and this
 * loads them into a0/a1 - no uvlong ever has to sit in one register or
 * be passed to asm.  a7=0 is the legacy set_timer EID.
 */
TEXT	sbisettimer(SB), 1, $-4
	MOVW	sbitimerlo(SB), R10	/* a0 = deadline low 32 */
	MOVW	sbitimerhi(SB), R11	/* a1 = deadline high 32 */
	MOVW	$0, R17			/* a7 = SBI set_timer (legacy EID 0) */
	ECALL
	RET

/*
 * SBI SRST (system reset): a0=type (0 shutdown), a1=reason, a6=FID 0,
 * a7="SRST".  The type is a plain int so it rides in RARG fine.  Gives
 * exit() a clean poweroff instead of the WFI spin the M-mode board has.
 */
TEXT	sbisystemreset(SB), 1, $-4
	MOVW	RARG, R10		/* a0 = reset type */
	MOVW	$0, R11			/* a1 = reason 0 */
	MOVW	$0, R16			/* a6 = FID 0 (system_reset) */
	MOVW	$0x53525354, R17	/* a7 = "SRST" */
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

	CSRR(SEPC, 10)
	MOVW	R10, (TRAPPAD+UREG_PC)(SP)
	CSRR(SSTATUS, 10)
	MOVW	R10, (TRAPPAD+UREG_STATUS)(SP)
	CSRR(SIE, 10)
	MOVW	R10, (TRAPPAD+UREG_IE)(SP)
	CSRR(SCAUSE, 10)
	MOVW	R10, (TRAPPAD+UREG_CAUSE)(SP)
	CSRR(STVAL, 10)
	MOVW	R10, (TRAPPAD+UREG_TVAL)(SP)
	MOVW	R0, (TRAPPAD+UREG_CURMODE)(SP)

	MOVW	$setSB(SB), R26
	MOVW	SP, RARG
	ADD	$TRAPPAD, RARG			/* &Ureg */
	JAL	LINK, trap(SB)

	MOVW	(TRAPPAD+UREG_PC)(SP), R10
	CSRW(SEPC, 10)
	MOVW	(TRAPPAD+UREG_STATUS)(SP), R10
	CSRW(SSTATUS, 10)

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
	SRET
