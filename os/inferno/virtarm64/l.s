#include "mem.h"

/*
 * System-register encodings 7a's lexer doesn't already know by name
 * (ELR_EL1/SPSR_EL1/DAIF/CurrentEL/etc are real keywords -- see
 * lex.c's LSPREG table; these are not).  SPR(x) is a.y's own escape
 * for an arbitrary SYSARG5-encoded special register, the same
 * mechanism utils/7c/7.out.h's own D_* constants are built from.
 */
#define	SYSARG5(op0,op1,Cn,Cm,op2)	((op0)<<19|(op1)<<16|(Cn)<<12|(Cm)<<8|(op2)<<5)
#define	D_VBAR_EL1	SYSARG5(3,0,12,0,0)
#define	D_ESR_EL1	SYSARG5(3,0,5,2,0)
#define	D_FAR_EL1	SYSARG5(3,0,6,0,0)
#define	D_CPACR_EL1	SYSARG5(3,0,1,0,2)
#define	D_CNTFRQ_EL0	SYSARG5(3,3,14,0,0)
#define	D_CNTPCT_EL0	SYSARG5(3,3,14,0,1)
#define	D_CNTP_CTL_EL0	SYSARG5(3,3,14,2,1)
#define	D_CNTP_CVAL_EL0	SYSARG5(3,3,14,2,2)

/*
 * QEMU -M virt, AArch64 (cortex-a72), single privilege level (EL1),
 * MMU off, identity/physical addressing -- the 64-bit ARM analogue
 * of what os/inferno/armv7 does for ARMv7-A and os/inferno/virt does
 * for riscv64.  Unlike utils/5a (armv7's assembler, which predates
 * ARMv6 and needs WORD literals for everything past LDR/STR/basic
 * ALU ops), utils/7a is a real, largely complete AArch64 assembler:
 * MRS/MSR/WFI/DSB/ISB/LDXR/STXR/CBZ/ERET are all native mnemonics
 * here, verified by direct compilation against this host's own 7a
 * before being relied on (see doc/inferno-ports.ms).  Register
 * conventions from utils/7c/7.out.h: REGRET=REGARG=0, REGSB=28
 * (R28, the SB-relative base register kencc code generation uses),
 * REGLINK=30 (R30/LR), REGSP=REGZERO=31 (RSP alias; plain "R31" is
 * never written).  There is no STP/LDP pair-store mnemonic in this
 * assembler port, so register saves below are individual MOVs, one
 * per register -- more instructions than a real AArch64 kernel would
 * hand-write, but each one independently straightforward to get
 * right and to read back out of a disassembly.
 */

/* Ureg offsets; keep in sync with Inferno/arm64/include/ureg.h */
#define	UR_R0	0
#define	UR_R1	8
#define	UR_R2	16
#define	UR_R3	24
#define	UR_R4	32
#define	UR_R5	40
#define	UR_R6	48
#define	UR_R7	56
#define	UR_R8	64
#define	UR_R9	72
#define	UR_R10	80
#define	UR_R11	88
#define	UR_R12	96
#define	UR_R13	104
#define	UR_R14	112
#define	UR_R15	120
#define	UR_R16	128
#define	UR_R17	136
#define	UR_R18	144
#define	UR_R19	152
#define	UR_R20	160
#define	UR_R21	168
#define	UR_R22	176
#define	UR_R23	184
#define	UR_R24	192
#define	UR_R25	200
#define	UR_R26	208
#define	UR_R27	216
#define	UR_R28	224
#define	UR_R29	232
#define	UR_R30	240
#define	UR_SP	248
#define	UR_PC	256
#define	UR_STATUS	264
#define	UR_TYPE	272
#define	UR_CAUSE	280
#define	UR_TVAL	288
#define	UR_SIZE	304		/* 296 rounded up to a 16-byte (SP-alignment) multiple */

/*
 * Entry for QEMU -M virt -kernel ivirtarm64.  QEMU's aarch64 ELF
 * loader jumps to the ELF entry point with the MMU off, caches off,
 * at whatever exception level -bios/-M virt's reset state leaves it
 * -- verified empirically against this host's QEMU to be EL1, not
 * EL2 (no -machine virtualization=on, no EL3/EL2 firmware requested),
 * the same way armv7's own _main comment verifies SVC32 for its board.
 */
/*
 * "MOV $bigconst, RSP" as a single pseudo-op silently mis-encodes:
 * 7l's large-constant expansion picks a real AArch64 LDR-literal
 * load, whose Rd field of 31 always means XZR (discarding the
 * value), never SP -- confirmed live, gdbstub showed "ldr xzr,
 * [pc,#...]" at _main's very first instruction, SP left at its
 * reset value of 0.  AArch64 has no single real instruction that
 * loads an arbitrary 64-bit immediate straight into SP either (real
 * hand-written AArch64 always does this in two steps: load a GPR,
 * then "mov sp,xn", itself just an alias for "add sp,xn,#0" -- an
 * ADD-immediate encoding, one of the few forms where 31 genuinely
 * does mean SP).  Route through R2 rather than trust the one-step
 * pseudo-op.
 */
TEXT	_main(SB), 1, $-4
	MOV	$stack+KSTACK(SB), R2
	MOV	R2, RSP

	/*
	 * VBAR_EL1 is left at its reset value (architecturally
	 * UNKNOWN) until trapinit() (called early from main()) builds
	 * the real table and installs it via vectorinit() -- same
	 * reason armv7/l.s's vectorinit() comment gives: the table is
	 * built as runtime data by trap.c's vectorbuild(), not linked
	 * branch code, so there is nothing for 7l to fold or place
	 * wrongly regardless of whether it has an armv7-5l-style
	 * branch-folding pass.
	 */
	MOV	$setSB(SB), R28
	MOV	R0, dtbptr(SB)		/* x0 holds the DTB physical address at boot */
	BL	main(SB)
dead:
	B	dead

GLOBL	dtbptr(SB), $8
GLOBL	stack(SB), $KSTACK
GLOBL	mach0(SB), $(4*1024)

TEXT	getcallerpc(SB), 1, $-4
	MOV	0(RSP), R0
	RET	R30

/*
 * _tas: real LDXR/STXR, not a spl-masked critical section -- a trap
 * handler can run at any point and take the same Lock.  Mirrors
 * armv7's own _tas (LDREX/STREX) and riscv64's virt (LR.W/SC.W).
 *
 * The W-suffixed (32-bit) forms, not plain LDXR/STXR: tas(x) is
 * "_tas((int*)(x))" (fns.h) and Lock.key is a ulong (4 bytes)
 * immediately followed by Lock.sr -- the plain 64-bit LDXR/STXR
 * this line first used silently touched 8 bytes at *l, corrupting
 * l->sr on every single lock/unlock.  Found live: the very first
 * print() call (before printinit(), inside dofmt.c's own _fmtlock())
 * landed in the vector table's Sync slot with VBAR still 0 -- i.e.
 * a fault that predated trapinit() entirely, well before any of
 * this board's own new C code had run.
 *
 * A second, independent bug lived here too: 7a's "STXR Ws,Xt,[Xn]"
 * grammar puts the STATUS register in the bare reg-number slot ($2)
 * and the VALUE being stored in "from" ($4) -- see a.y's LSTXR
 * production.  "STXRW R2,R1,(R3)" therefore encoded Ws=R2 (clobbering
 * the $1 we'd just built), Xt=R1 (the OLD value we'd just loaded from
 * *l), Xn=R3 -- i.e. it stored the lock's own prior contents back
 * over itself and threw the intended "1" away entirely.  tas() always
 * returned the correct "was it free" answer (R1, untouched by the
 * store), so every caller believed it had acquired the lock while
 * l->key never actually changed.  Found live: iunlock()'s own
 * self-check ("l->key == 0: not locked") fired on the FIRST ilock/
 * iunlock pair ever taken (kmesg.lk, from print()'s own kmesgputs()),
 * and the diagnostic print() it triggered recursed back through
 * kmesgputs()/ilock()/iunlock() to print the same complaint again,
 * looping until a garbage %p argument's utflen() call finally faulted.
 * Fixed by giving the status result its own scratch register (R4) and
 * storing the real new value (R2, "1") instead of the stale R1.
 */
/*
 * psci(fn, a1, a2, a3): a PSCI call through HVC, QEMU virt's conduit.
 * The four args are already in R0-R3 (x0-x3) where SMCCC wants them;
 * HVC #0 uses them and returns the result in x0.  HVC is not a 7a
 * mnemonic, so it is the raw encoding 0xd4000002.
 */
TEXT	psci(SB), 1, $-4
	WORD	$0xd4000002
	RET	R30

/*
 * GICv3 CPU-interface accessors.  On a GICv3 the per-CPU interface is
 * a set of ICC_*_EL1 system registers, not the MMIO GICC page a GICv2
 * has, so acknowledge/EOI/priority-mask/group-enable are MSR/MRS here.
 * 7a does not know the ICC_* mnemonics, so each is the raw MSR/MRS
 * word (op0=3,op1=0,CRn=12/4,CRm,op2, Rt=0 == R0), verified against
 * the host assembler; the single arg / return value lives in R0/x0
 * where 7c's calling convention already puts it.  SRE and group-enable
 * writes need an ISB (0xd5033fdf) before the next fetch sees them.
 */
TEXT	seticcsre(SB), 1, $-4
	WORD	$0xd518cca0		/* MSR x0, ICC_SRE_EL1 */
	WORD	$0xd5033fdf		/* ISB */
	RET	R30

TEXT	geticcsre(SB), 1, $-4
	WORD	$0xd538cca0		/* MRS ICC_SRE_EL1, x0 */
	RET	R30

TEXT	seticcpmr(SB), 1, $-4
	WORD	$0xd5184600		/* MSR x0, ICC_PMR_EL1 */
	RET	R30

TEXT	seticcbpr1(SB), 1, $-4
	WORD	$0xd518cc60		/* MSR x0, ICC_BPR1_EL1 */
	RET	R30

TEXT	seticcgrpen1(SB), 1, $-4
	WORD	$0xd518cce0		/* MSR x0, ICC_IGRPEN1_EL1 */
	WORD	$0xd5033fdf		/* ISB */
	RET	R30

TEXT	seticcctlr(SB), 1, $-4
	WORD	$0xd518cc80		/* MSR x0, ICC_CTLR_EL1 */
	RET	R30

TEXT	geticciar(SB), 1, $-4
	WORD	$0xd538cc00		/* MRS ICC_IAR1_EL1, x0 */
	RET	R30

/*
 * ID_AA64PFR0_EL1.GIC (bits 27:24): 0 == no GICv3 system-register cpu
 * interface (a GICv2 board), non-zero == the ICC_* interface is
 * present.  A CPU ID register, so reading it never aborts - unlike the
 * GICv2 distributor's PIDR2, which QEMU's model does not implement and
 * faults on.  This is how gicinit tells v2 from v3 without touching an
 * address that might not answer.
 */
TEXT	getpfr0(SB), 1, $-4
	WORD	$0xd5380400		/* MRS ID_AA64PFR0_EL1, x0 */
	RET	R30

TEXT	seticceoir(SB), 1, $-4
	WORD	$0xd518cc20		/* MSR x0, ICC_EOIR1_EL1 */
	RET	R30

TEXT	_tas(SB), 1, $-4
	MOV	R0, R3
tas1:
	LDXRW	(R3), R1
	MOV	$1, R2
	STXRW	R4, R2, (R3)
	CBNZW	R4, tas1
	DSB	$15
	MOV	R1, R0
	RET	R30

TEXT	setlabel(SB), 1, $-4
	MOV	R0, R2
	/*
	 * Not "MOV RSP, 0(R2)": in an AArch64 store, register 31 is
	 * XZR, so that assembles to STR XZR,[X2] and every Label got
	 * sp == 0.  The first nexterror() then resumed its waserror()
	 * frame on a zero stack pointer, which is what stopped this
	 * board at its first module load (doc/inferno-ports.ms).
	 * Only ADD/SUB read SP in register 31, so go through R1.
	 */
	MOV	RSP, R1
	MOV	R1, 0(R2)
	MOV	R30, 8(R2)
	MOV	$0, R0
	RET	R30

TEXT	gotolabel(SB), 1, $-4
	MOV	0(R0), R1
	MOV	8(R0), R2
	MOV	R1, RSP
	MOV	$setSB(SB), R28
	MOV	$1, R0
	MOV	R2, R30
	RET	R30

/*
 * First process entry trampoline -- keeps SB set on the new stack,
 * same shape as armv7/riscv64's init0entry.
 */
TEXT	init0entry(SB), 1, $-4
	MOV	$setSB(SB), R28
	BL	init0(SB)
dead0:
	B	dead0

/*
 * Interrupt level.  DAIF.I is the whole of it -- MAXMACH is 1, so
 * masking IRQs is the only atomicity primitive this board needs.
 */
TEXT	splhi(SB), 1, $-4
	MRS	DAIF, R0
	AND	$0x80, R0, R1		/* previous I-bit, for the return value */
	MSR	$2, DAIFSet		/* imm bit1 = IRQ */
	MOV	$mach0(SB), R2
	MOV	R30, 0(R2)		/* m->splpc */
	MOV	R1, R0
	RET	R30

TEXT	spllo(SB), 1, $-4
	MRS	DAIF, R0
	AND	$0x80, R0, R1
	MSR	$2, DAIFClr
	MOV	R1, R0
	RET	R30

TEXT	splx(SB), 1, $-4
	MOV	$mach0(SB), R2
	MOV	R30, 0(R2)
	CMP	$0, R0
	BEQ	splxlo
	MSR	$2, DAIFSet
	RET	R30
splxlo:
	MSR	$2, DAIFClr
	RET	R30

/*
 * islo(): 1 if interrupts are enabled, 0 if masked.  No AArch64
 * equivalent of armv7's "MOVW.NE" condition-suffixed data op (real
 * AArch64 only conditions branches and CSEL-family selects, not a
 * general instruction suffix) -- a plain branch does the same job.
 */
TEXT	islo(SB), 1, $-4
	MRS	DAIF, R0
	AND	$0x80, R0, R0
	MOV	$1, R1
	CMP	$0, R0
	BEQ	islo1
	MOV	$0, R1
islo1:
	MOV	R1, R0
	RET	R30

TEXT	idle(SB), 1, $-4
	WFI
	RET	R30

/*
 * coherence(): a full DSB, not a hint -- see armv7/l.s's own comment
 * on why unlock() needs a real barrier here.
 */
TEXT	coherence(SB), 1, $-4
	DSB	$15
	RET	R30

/*
 * cycles(uvlong*): genuinely 64-bit here (real X registers), unlike
 * armv7's mrrc-into-two-32-bit-halves.  Still an out-param, matching
 * fns.h/io.h's shared declaration across every board -- nothing in
 * this tree has needed to risk a bare uvlong return yet.
 */
TEXT	cycles(SB), 1, $-4
	MRS	SPR(D_CNTPCT_EL0), R1
	MOV	R1, 0(R0)
	RET	R30

/*
 * hwtimerset(uvlong *whenp): CNTP_CVAL_EL0 = *whenp, matching the
 * absolute "when" semantics os/inferno/virt's clock.c already
 * assumes from riscv64's mtimecmp and armv7's CNTP_CVAL.
 */
TEXT	hwtimerset(SB), 1, $-4
	MOV	0(R0), R1
	MSR	R1, SPR(D_CNTP_CVAL_EL0)
	RET	R30

TEXT	cntfrq(SB), 1, $-4
	MRS	SPR(D_CNTFRQ_EL0), R1
	MOV	R1, 0(R0)
	RET	R30

TEXT	timerie(SB), 1, $-4
	MOV	$1, R0
	MSR	R0, SPR(D_CNTP_CTL_EL0)
	RET	R30

/*
 * fpinit(): FP/SIMD is off at reset (CPACR_EL1.FPEN traps both EL0
 * and EL1) -- any V/D/S-register instruction traps Undefined (Sync,
 * ESR_EL1.EC == 0x07).  Grant full access (FPEN = 0b11, bits 21:20),
 * ISB to make it visible to the next instruction fetched.  Unlike
 * armv7's 5c, there is no legacy FPA coprocessor for 7c to
 * accidentally target instead -- AArch64 has exactly one FP register
 * file, so there is no equivalent of armv7's "-f" 5l flag to get
 * wrong.
 */
TEXT	fpinit(SB), 1, $-4
	MRS	SPR(D_CPACR_EL1), R0
	MOV	$(3<<20), R1
	ORR	R1, R0
	MSR	R0, SPR(D_CPACR_EL1)
	ISB	$15
	RET	R30

/*
 * vectorinit(void *table): VBAR_EL1 = table (arg in R0, REGARG).
 * Just the system-register write + ISB; trap.c's vectorbuild() is
 * the only caller and builds the table itself.
 */
TEXT	vectorinit(SB), 1, $-4
	MSR	R0, SPR(D_VBAR_EL1)
	ISB	$15
	RET	R30

/*
 * vectrap: the shared tail every one of the four active vector-table
 * entries (Sync/IRQ/FIQ/SError, all taken at current EL using SP_ELx
 * -- the only group this single-EL kernel ever reaches, see trap.c's
 * vectorbuild()) branches into once its own tiny in-table stub has
 * reserved the frame, stashed the one register (R9) it needed as a
 * type-tag carrier, and written the tag into R9.  On entry here: SP
 * already points at a UR_SIZE-byte frame, R9 holds the type tag (not
 * yet written to UR_TYPE), and R9's true interrupted value already
 * sits safely at UR_R9(SP).  Every other register is saved HERE,
 * first thing: the four-instruction stub vectorbuild() generates
 * saves only R9, and until 3 September 2026 nothing saved the rest
 * while the exit path below restored all thirty-one from the frame,
 * so every interrupt returned to its interrupted code with whatever
 * happened to lie in the frame slots in R0-R8 and R10-R30.  That was
 * the "pool corruption" at the first module load: an IRQ inside
 * libinterp's brpatch() came back with a garbage R30 and RET went to
 * a heap address (doc/inferno-ports.ms).
 *
 * This mirrors riscv64/virt's trapvec far more closely than it
 * mirrors armv7's vectrap: AArch64's SP-relative STR/MOV needs no
 * scratch register held in advance (unlike ARM32, which had to bank
 * on R13 being a genuinely different physical register per mode to
 * get a free pointer at all) -- SUB SP,SP,#UR_SIZE by itself, before
 * touching any GPR, is enough to make the frame safe to write into.
 */
TEXT	vectrap(SB), 1, $-4
	MOV	R9, UR_TYPE(RSP)	/* the tag; R9 is now free to reuse */

	/* the interrupted registers, before anything can touch them */
	MOV	R0, UR_R0(RSP)
	MOV	R1, UR_R1(RSP)
	MOV	R2, UR_R2(RSP)
	MOV	R3, UR_R3(RSP)
	MOV	R4, UR_R4(RSP)
	MOV	R5, UR_R5(RSP)
	MOV	R6, UR_R6(RSP)
	MOV	R7, UR_R7(RSP)
	MOV	R8, UR_R8(RSP)
	MOV	R10, UR_R10(RSP)
	MOV	R11, UR_R11(RSP)
	MOV	R12, UR_R12(RSP)
	MOV	R13, UR_R13(RSP)
	MOV	R14, UR_R14(RSP)
	MOV	R15, UR_R15(RSP)
	MOV	R16, UR_R16(RSP)
	MOV	R17, UR_R17(RSP)
	MOV	R18, UR_R18(RSP)
	MOV	R19, UR_R19(RSP)
	MOV	R20, UR_R20(RSP)
	MOV	R21, UR_R21(RSP)
	MOV	R22, UR_R22(RSP)
	MOV	R23, UR_R23(RSP)
	MOV	R24, UR_R24(RSP)
	MOV	R25, UR_R25(RSP)
	MOV	R26, UR_R26(RSP)
	MOV	R27, UR_R27(RSP)
	MOV	R28, UR_R28(RSP)
	MOV	R29, UR_R29(RSP)
	MOV	R30, UR_R30(RSP)


	MOV	RSP, R9
	ADD	$UR_SIZE, R9		/* interrupted sp == current sp + frame */
	MOV	R9, UR_SP(RSP)

	MRS	ELR_EL1, R9
	MOV	R9, UR_PC(RSP)
	MRS	SPSR_EL1, R9
	MOV	R9, UR_STATUS(RSP)
	MRS	SPR(D_ESR_EL1), R9
	MOV	R9, UR_CAUSE(RSP)
	MRS	SPR(D_FAR_EL1), R9
	MOV	R9, UR_TVAL(RSP)

	MOV	RSP, R0			/* &Ureg, arg to trap() */
	BL	trap(SB)

	MOV	UR_PC(RSP), R9
	MSR	R9, ELR_EL1
	MOV	UR_STATUS(RSP), R9
	MSR	R9, SPSR_EL1

	MOV	UR_R0(RSP), R0
	MOV	UR_R1(RSP), R1
	MOV	UR_R2(RSP), R2
	MOV	UR_R3(RSP), R3
	MOV	UR_R4(RSP), R4
	MOV	UR_R5(RSP), R5
	MOV	UR_R6(RSP), R6
	MOV	UR_R7(RSP), R7
	MOV	UR_R8(RSP), R8
	MOV	UR_R10(RSP), R10
	MOV	UR_R11(RSP), R11
	MOV	UR_R12(RSP), R12
	MOV	UR_R13(RSP), R13
	MOV	UR_R14(RSP), R14
	MOV	UR_R15(RSP), R15
	MOV	UR_R16(RSP), R16
	MOV	UR_R17(RSP), R17
	MOV	UR_R18(RSP), R18
	MOV	UR_R19(RSP), R19
	MOV	UR_R20(RSP), R20
	MOV	UR_R21(RSP), R21
	MOV	UR_R22(RSP), R22
	MOV	UR_R23(RSP), R23
	MOV	UR_R24(RSP), R24
	MOV	UR_R25(RSP), R25
	MOV	UR_R26(RSP), R26
	MOV	UR_R27(RSP), R27
	MOV	UR_R28(RSP), R28
	MOV	UR_R29(RSP), R29
	MOV	UR_R30(RSP), R30
	MOV	UR_R9(RSP), R9

	/*
	 * SP self-restores: the frame lives on the interrupted kernel
	 * stack itself (not a static shared buffer the way armv7 and
	 * riscv64 both use), so undoing the entry-stub's SUB by the
	 * same UR_SIZE puts SP back exactly where the exception found
	 * it -- no separate UR_SP-driven restore needed, unlike a
	 * static-buffer design.
	 */
	ADD	$UR_SIZE, RSP
	ERET
