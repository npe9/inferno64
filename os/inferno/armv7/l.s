#include "mem.h"

/*
 * QEMU -M virt, ARMv7-A (cortex-a15), single privilege level (SVC),
 * MMU off, identity/physical addressing -- the ARM analogue of what
 * os/inferno/virt does for riscv64 in bare M-mode.  Every raw
 * instruction encoded here with WORD was validated against
 * arm-none-eabi-as (real GNU binutils) ground truth before being
 * copied in, then re-validated end to end booting real 5a/5l-built
 * images under this host's own qemu-system-arm.  See doc/inferno-ports.ms.
 *
 * utils/5a has no native mnemonics for anything past ARMv5 -- no CPS,
 * no MRS/MSR of CPSR/SPSR, no WFI, no LDREX/STREX, no SRS, no MCR/MRC,
 * no LDM^.  Every one of those is a WORD literal here, exactly as
 * os/inferno/virt/l.s WORDs FENCE/LRW/SCW/MRET for instructions its
 * own (riscv64) assembler predates.
 */

/* Ureg offsets; keep in sync with Inferno/arm/include/ureg.h */
#define	UR_R0	0
#define	UR_R1	4
#define	UR_R2	8
#define	UR_R3	12
#define	UR_R4	16
#define	UR_R5	20
#define	UR_R6	24
#define	UR_R7	28
#define	UR_R8	32
#define	UR_R9	36
#define	UR_R10	40
#define	UR_R11	44
#define	UR_R12	48
#define	UR_SP	52
#define	UR_R14	56
#define	UR_LINK	60
#define	UR_TYPE	64
#define	UR_PSR	68
#define	UR_PC	72
#define	UR_SIZE	80		/* 76 rounded up to 8 */

/* Trap types, passed in Ureg.type */
#define	TReset	0
#define	TUndef	1
#define	TSvc	2
#define	TPabt	3
#define	TDabt	4
#define	TIrq	5
#define	TFiq	6

/*
 * Entry for QEMU -M virt -kernel iarmv7.  Comes in SVC32, IRQ/FIQ
 * masked, MMU/caches off (the same state a raw ARM Linux zImage
 * would see) -- verified empirically against this host's QEMU by
 * printing the CPSR mode nibble before anything else runs.
 */
TEXT	_main(SB), 1, $-4
	MOVW	$stack+KSTACK(SB), R13

	/*
	 * VBAR is left at whatever QEMU's -kernel loader reset it to
	 * until trapinit() (called early from main()) builds the real
	 * table and installs it -- see vectorinit()/vectorbuild() below
	 * for why the table can't just be link-time branch code.
	 */
	MOVW	$setR12(SB), R12
	BL	main(SB)
dead:
	B	dead

GLOBL	stack(SB), $KSTACK
GLOBL	mach0(SB), $(4*1024)

TEXT	getcallerpc(SB), 1, $-4
	MOVW	0(R13), R0
	RET

/*
 * _tas: real LDREX/STREX, not a spl-masked critical section -- a
 * trap handler can run at any point and take the same Lock.
 */
TEXT	_tas(SB), 1, $-4
	MOVW	R0, R3
tas1:
	WORD	$0xe1931f9f		/* ldrex r1, [r3] */
	MOVW	$1, R2
	WORD	$0xe1830f92		/* strex r0, r2, [r3] */
	CMP	$0, R0
	BNE	tas1
	WORD	$0xf57ff05f		/* dmb sy */
	MOVW	R1, R0
	RET

TEXT	setlabel(SB), 1, $-4
	MOVW	R0, R2
	MOVW	R13, 0(R2)		/* sp */
	MOVW	R14, 4(R2)		/* pc */
	MOVW	$0, R0
	RET

TEXT	gotolabel(SB), 1, $-4
	MOVW	0(R0), R1
	MOVW	4(R0), R2
	MOVW	R1, R13
	MOVW	$setR12(SB), R12
	MOVW	$1, R0
	MOVW	R2, R14		/* RET returns via R14, same idiom as armv7m's gotolabel */
	RET

/*
 * First process entry trampoline -- keeps SB set on the new stack,
 * same shape as riscv64/armv7m's init0entry.
 */
TEXT	init0entry(SB), 1, $-4
	MOVW	$setR12(SB), R12
	BL	init0(SB)
dead0:
	B	dead0

/*
 * Interrupt level.  CPSR.I is the whole of it -- MAXMACH is 1, so
 * masking IRQs is the only atomicity primitive this board needs.
 */
TEXT	splhi(SB), 1, $-4
	WORD	$0xe10f0000		/* mrs r0, cpsr */
	AND	$0x80, R0, R1		/* previous I-bit, for the return value */
	WORD	$0xf10c0080		/* cpsid i */
	MOVW	$mach0(SB), R2
	MOVW	R14, 0(R2)		/* m->splpc */
	MOVW	R1, R0
	RET

TEXT	spllo(SB), 1, $-4
	WORD	$0xe10f0000		/* mrs r0, cpsr */
	AND	$0x80, R0, R1
	WORD	$0xf1080080		/* cpsie i */
	MOVW	R1, R0
	RET

TEXT	splx(SB), 1, $-4
	MOVW	$mach0(SB), R2
	MOVW	R14, 0(R2)
	CMP	$0, R0
	BEQ	splxlo
	WORD	$0xf10c0080		/* cpsid i */
	RET
splxlo:
	WORD	$0xf1080080		/* cpsie i */
	RET

TEXT	islo(SB), 1, $-4
	WORD	$0xe10f0000		/* mrs r0, cpsr */
	AND	$0x80, R0, R0
	CMP	$0, R0
	MOVW	$1, R0
	MOVW.NE	$0, R0
	RET

TEXT	idle(SB), 1, $-4
	WORD	$0xe320f003		/* wfi */
	RET

/*
 * coherence(): a full DSB, not a hint -- see armv7m/l.s's own comment
 * on why unlock() needs a real barrier here.
 */
TEXT	coherence(SB), 1, $-4
	WORD	$0xf57ff04f		/* dsb sy */
	RET

/*
 * cycles(uvlong*): out-param, never a 64-bit register return -- this
 * toolchain's calling convention for a bare 64-bit value crossing the
 * C/asm boundary was never worth risking; every 64-bit CP15 access
 * here goes through a pointer instead, the same caution riscv64's
 * cycles(uvlong*) already uses despite having native 64-bit regs.
 */
TEXT	cycles(SB), 1, $-4
	MOVW	R0, R3
	WORD	$0xec521f0e		/* mrrc p15,0,r1,r2,c14 : CNTPCT -> r1(lo),r2(hi) */
	MOVW	R1, 0(R3)
	MOVW	R2, 4(R3)
	RET

/*
 * hwtimerset(uvlong *whenp): CNTP_CVAL = *whenp, matching the absolute
 * "when" semantics os/inferno/virt's clock.c already assumes from
 * riscv64's mtimecmp.
 */
TEXT	hwtimerset(SB), 1, $-4
	MOVW	0(R0), R1
	MOVW	4(R0), R2
	WORD	$0xec421f2e		/* mcrr p15,2,r1,r2,c14 : CNTP_CVAL = r1(lo),r2(hi) */
	RET

TEXT	cntfrq(SB), 1, $-4
	MOVW	R0, R3
	WORD	$0xee1e1f10		/* mrc p15,0,r1,c14,c0,0 : CNTFRQ -> r1 */
	MOVW	R1, 0(R3)
	MOVW	$0, R1
	MOVW	R1, 4(R3)
	RET

TEXT	timerie(SB), 1, $-4
	MOVW	$1, R0
	WORD	$0xee0e0f32		/* mcr p15,0,r0,c14,c2,1 : CNTP_CTL enable, unmasked */
	RET

/*
 * fpinit(): VFP is off at reset (CPACR denies cp10/cp11, FPEXC.EN
 * clear) -- any VFP instruction traps Undefined.  Grant cp10/cp11
 * full access in CPACR, ISB, then set FPEXC.EN.  Every opcode here
 * verified against arm-none-eabi-as -mfpu=vfpv4 the same way as the
 * rest of this file.
 *
 * This alone did NOT fix the first real Dis interp() run's Undefined
 * trap -- that trap decoded as "cdp 1,0,cr8,cr0,cr9,{4}", coprocessor
 * *1*, not cp10/cp11: 5c's floating-point codegen targets the extinct
 * FPA coprocessor (cp1/cp2) by default, which cortex-a15 has never
 * implemented.  utils/5l's optab.c/span.c/asm.c carry a second,
 * VFP-encoded lowering for the same AADDF/AMOVF/ACMPF/AMOVFW
 * pseudo-ops, selected by 5l's own -f flag (span.c: "vfp =
 * debug['f']").  The real fix is linking with -f (see this board's
 * mkfile); fpinit() below is what makes those VFP instructions,
 * once 5l actually emits them, not trap.
 */
TEXT	fpinit(SB), 1, $-4
	WORD	$0xee110f50		/* mrc p15,0,r0,c1,c0,2 : read CPACR */
	MOVW	$0xf00000, R1		/* cp10/cp11 full access (bits 20-23) */
	ORR	R1, R0
	WORD	$0xee010f50		/* mcr p15,0,r0,c1,c0,2 : write CPACR */
	WORD	$0xf57ff06f		/* isb sy */
	MOVW	$0x40000000, R0		/* FPEXC.EN = bit 30 */
	WORD	$0xeee80a10		/* vmsr fpexc, r0 */
	RET

/*
 * vectorinit(void *table): VBAR = table (arg in R0, standard first-arg
 * register on this ABI).  Just the CP15 write; trap.c's vectorbuild()
 * builds the table itself and is the only caller.
 */
TEXT	vectorinit(SB), 1, $-4
	WORD	$0xee0c0f10		/* mcr p15,0,r0,c12,c0,0 : VBAR = r0 */
	RET

/*
 * There is deliberately no link-time branch table here (see the
 * removed "TEXT vectors(SB)" this comment replaces, and vectorbuild()
 * in trap.c): 5l's branch-folding pass does not leave a TEXT block of
 * pure unconditional branches alone, so a static table is not a
 * reliable target for VBAR.  Reset/Undef/SVC/PrefetchAbort/DataAbort/
 * FIQ all funnel into vectrap with a distinct type tag and, for the
 * two abort classes, the architecturally-correct LR adjustment (-4 vs
 * -8) so ur->pc names the actual faulting instruction, the same
 * convention os/inferno/virt's mepc gives for free on riscv64.  None
 * of the five are ever taken in ordinary operation -- this board has
 * no user mode to fault and issues no software interrupts -- so
 * trap()'s default case treats every one of them as fatal.
 */
/*
 * Every vector stashes the real R0-R4 to a fixed static buffer
 * FIRST, through the banked R13 of whichever mode it is (never used
 * as an actual stack on this board, so free to repoint at anything;
 * this board never initializes SP_und/SP_abt/SP_irq/SP_fiq and
 * doesn't need to) -- only after that are R0-R4 free to reuse for
 * the adjusted pc, SPSR, type tag and ureg0 base pointer vectrap
 * needs.  An earlier version reused R2 for the type tag before
 * stashing it, which silently discarded the interrupted code's real
 * r2 on every trap; caught by widening the register-preservation
 * self-test past r0/r1/r4-r12/r14 to all of r0-r12,r14.
 *
 * R4 specifically needs stashing here rather than being picked up
 * later by a plain register-block store, unlike R5-R11: vectrap's
 * very first act is "MOVW $ureg0(SB), R4", repurposing R4 as its own
 * base pointer before the interrupted context's true R4 is saved
 * anywhere.  A version that stored R4 straight into UR_R4 via
 * "stmia r4!,{r4-r11}" (later "stmia r3!,{r4-r11}" with r4 left as
 * a live register in the source list either way) always captured
 * &ureg0 itself, not the interrupted r4 -- confirmed with QEMU's
 * gdbstub: breaking at a vector's first instruction showed the true
 * r4, breaking after the save showed ureg0's own address (a fixed,
 * link-time constant, matching a data abort landmark that looked
 * uncannily like a plausible heap pointer purely by coincidence of
 * where the linker placed the buffer).  The fix is the same shape
 * R0-R3 already use: stash the true value before it can be
 * clobbered.
 */
TEXT	vecreset(SB), 1, $-4
	MOVW	$trapscratch(SB), R13
	MOVW	R0, 0(R13)
	MOVW	R1, 4(R13)
	MOVW	R2, 8(R13)
	MOVW	R3, 12(R13)
	MOVW	R4, 16(R13)
	MOVW	R14, R0
	MOVW	$TReset, R2
	B	vectrap(SB)

TEXT	vecundef(SB), 1, $-4
	SUB	$4, R14
	MOVW	$trapscratch(SB), R13
	MOVW	R0, 0(R13)
	MOVW	R1, 4(R13)
	MOVW	R2, 8(R13)
	MOVW	R3, 12(R13)
	MOVW	R4, 16(R13)
	WORD	$0xe14f1000		/* mrs r1, spsr */
	MOVW	R14, R0
	MOVW	$TUndef, R2
	B	vectrap(SB)

TEXT	vecswi(SB), 1, $-4
	SUB	$4, R14
	MOVW	$trapscratch(SB), R13
	MOVW	R0, 0(R13)
	MOVW	R1, 4(R13)
	MOVW	R2, 8(R13)
	MOVW	R3, 12(R13)
	MOVW	R4, 16(R13)
	WORD	$0xe14f1000
	MOVW	R14, R0
	MOVW	$TSvc, R2
	B	vectrap(SB)

TEXT	vecpabt(SB), 1, $-4
	SUB	$4, R14
	MOVW	$trapscratch(SB), R13
	MOVW	R0, 0(R13)
	MOVW	R1, 4(R13)
	MOVW	R2, 8(R13)
	MOVW	R3, 12(R13)
	MOVW	R4, 16(R13)
	WORD	$0xe14f1000
	MOVW	R14, R0
	MOVW	$TPabt, R2
	B	vectrap(SB)

TEXT	vecdabt(SB), 1, $-4
	SUB	$8, R14
	MOVW	$trapscratch(SB), R13
	MOVW	R0, 0(R13)
	MOVW	R1, 4(R13)
	MOVW	R2, 8(R13)
	MOVW	R3, 12(R13)
	MOVW	R4, 16(R13)
	WORD	$0xe14f1000
	MOVW	R14, R0
	MOVW	$TDabt, R2
	B	vectrap(SB)

TEXT	vecfiq(SB), 1, $-4
	SUB	$4, R14
	MOVW	$trapscratch(SB), R13
	MOVW	R0, 0(R13)
	MOVW	R1, 4(R13)
	MOVW	R2, 8(R13)
	MOVW	R3, 12(R13)
	MOVW	R4, 16(R13)
	WORD	$0xe14f1000
	MOVW	R14, R0
	MOVW	$TFiq, R2
	B	vectrap(SB)

TEXT	vecirq(SB), 1, $-4
	SUB	$4, R14
	MOVW	$trapscratch(SB), R13
	MOVW	R0, 0(R13)
	MOVW	R1, 4(R13)
	MOVW	R2, 8(R13)
	MOVW	R3, 12(R13)
	MOVW	R4, 16(R13)
	WORD	$0xe14f1000
	MOVW	R14, R0
	MOVW	$TIrq, R2
	B	vectrap(SB)

/*
 * vectrap: entered with R0-R3's true values already safe in
 * trapscratch, R0=adjusted pc, R1=SPSR (vecreset has no SPSR of its
 * own worth reading -- R1 there is stale, harmless since TReset is
 * never taken in practice), R2=type.  Switches to SVC and builds the
 * Ureg into a single static buffer rather than a stack-relative
 * frame.  An early version of this code, addressing the same stores
 * off R13 instead, hung QEMU; that was chased at length as a 5a/5l
 * codegen bug, but the real vector-table-addressing bug found later
 * (5l's branch-folding pass silently eating a TEXT block of pure
 * branches -- see vectorbuild() in trap.c) turned out to explain
 * symptoms that looked exactly like this one, and the R13 claim was
 * never independently reproduced after that fix.  Treat it as
 * unexplained and unverified, not as a confirmed toolchain bug.  A
 * static buffer is sound on its own merits regardless: traps never
 * nest on this board (a trap always runs to completion, C handler
 * included, before the mode switch back re-admits interrupts), so
 * nothing else can be using ureg0 while vectrap is.
 */
TEXT	vectrap(SB), 1, $-4
	WORD	$0xf1020013		/* cps #0x13 : svc */

	/*
	 * now in SVC mode: R13=interrupted sp, R5-R12/R14 pristine, R0=pc,
	 * R1=spsr, R2=type (all three survived the mode switch, none of
	 * them banked).  R4 is NOT pristine here -- it is repurposed as
	 * ureg0's own base pointer on the very next line, which is
	 * exactly why the vecXXX entry points above stash the true R4 to
	 * trapscratch before ever reaching vectrap.  A version that
	 * skipped that and later tried to recover R4 via a plain register
	 * block store ("stmia r4!,{r4-r11}", then "stmia r3!,{r4-r11}"
	 * with r4 still in the source list either way) always captured
	 * whatever R4 held AT THAT POINT -- ureg0's own address, a fixed
	 * link-time constant -- not the interrupted context's true r4.
	 * Confirmed with QEMU's gdbstub: breaking at a vecXXX entry's
	 * very first instruction showed the true r4 (a poison pattern in
	 * the one boot that caught this); breaking after the old save
	 * sequence showed &ureg0 instead, byte-identical to the literal
	 * pool constant this function's own first MOVW loads.  No
	 * encoding subtlety, no QEMU quirk -- R4 was simply gone by the
	 * time anything tried to save it.
	 */
	MOVW	$ureg0(SB), R4
	MOVW	R13, UR_SP(R4)
	MOVW	R14, UR_R14(R4)
	MOVW	R14, UR_LINK(R4)
	MOVW	R1, UR_PSR(R4)
	MOVW	R0, UR_PC(R4)
	MOVW	R2, UR_TYPE(R4)

	MOVW	$trapscratch(SB), R1
	MOVW	0(R1), R0
	MOVW	4(R1), R2
	MOVW	8(R1), R3
	MOVW	R0, UR_R0(R4)
	MOVW	R2, UR_R1(R4)
	MOVW	R3, UR_R2(R4)
	MOVW	12(R1), R0
	MOVW	R0, UR_R3(R4)
	MOVW	16(R1), R0		/* true r4, stashed by the entry point */
	MOVW	R0, UR_R4(R4)

	ADD	$UR_R5, R4, R3		/* &ureg0.r5 */
	WORD	$0xe8a30fe0		/* stmia r3!, {r5-r11} -- UR_R5..UR_R11 */
	WORD	$0xe8831000		/* stm r3, {r12} -- UR_R12 */

	MOVW	$ureg0(SB), R0		/* &Ureg */
	BL	trap(SB)

	/*
	 * Return: pack r0-r12,r14,pc into retbuf (Ureg's own layout
	 * cannot feed a single LDM^ directly -- sp/link/type/psr sit
	 * between r12 and r14), set SPSR, then one atomic
	 * "ldm {r0-r12,r14,pc}^" restores every GPR and CPSR together.
	 * No register serves double duty as both a live GPR and a
	 * transfer vehicle at any point, which a sequential restore
	 * cannot avoid without one of them losing its true value.
	 */
	MOVW	$ureg0(SB), R4
	MOVW	UR_PSR(R4), R0
	WORD	$0xe16ff000		/* msr spsr_cxsf, r0 */

	MOVW	$retbuf(SB), R1
	MOVW	UR_R0(R4), R0
	MOVW	R0, 0(R1)
	MOVW	UR_R1(R4), R0
	MOVW	R0, 4(R1)
	MOVW	UR_R2(R4), R0
	MOVW	R0, 8(R1)
	MOVW	UR_R3(R4), R0
	MOVW	R0, 12(R1)

	ADD	$UR_R4, R4, R3		/* &ureg0.r4 */
	WORD	$0xe8930ff0		/* ldm r3, {r4-r11} */
	WORD	$0xe8810ff0		/* stm r1, {r4-r11} -- retbuf+16..44 */

	MOVW	$ureg0(SB), R4
	MOVW	UR_R12(R4), R0
	MOVW	R0, 48(R1)
	MOVW	UR_R14(R4), R0
	MOVW	R0, 52(R1)
	MOVW	UR_PC(R4), R0
	MOVW	R0, 56(R1)
	MOVW	UR_SP(R4), R13		/* the interrupted sp, restored last */

	MOVW	$retbuf(SB), R1
	WORD	$0xe8d1dfff		/* ldm r1, {r0-r12,r14,pc}^ */

GLOBL	trapscratch(SB), $20		/* true r0,r1,r2,r3,r4 -- see vectrap */
GLOBL	ureg0(SB), $UR_SIZE
GLOBL	retbuf(SB), $64
GLOBL	fnnote(SB), $4
