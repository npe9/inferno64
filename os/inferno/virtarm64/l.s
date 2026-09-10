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
#define	D_ICC_SRE_EL1	SYSARG5(3,0,12,12,5)
#define	D_ICC_PMR_EL1	SYSARG5(3,0,4,6,0)
#define	D_ICC_BPR1_EL1	SYSARG5(3,0,12,12,3)
#define	D_ICC_IGRPEN1_EL1	SYSARG5(3,0,12,12,7)
#define	D_ICC_CTLR_EL1	SYSARG5(3,0,12,12,4)
#define	D_ICC_IAR1_EL1	SYSARG5(3,0,12,12,0)
#define	D_ICC_EOIR1_EL1	SYSARG5(3,0,12,12,1)
#define	D_ID_AA64PFR0_EL1	SYSARG5(3,0,0,4,0)
#define	D_ID_AA64MMFR0_EL1	SYSARG5(3,0,0,7,0)
#define	D_CNTP_CVAL_EL0	SYSARG5(3,3,14,2,2)
#define	D_MPIDR_EL1	SYSARG5(3,0,0,0,5)
#define	D_MAIR_EL1	SYSARG5(3,0,10,2,0)
#define	D_TCR_EL1	SYSARG5(3,0,2,0,2)
#define	D_TTBR0_EL1	SYSARG5(3,0,2,0,0)
#define	D_SCTLR_EL1	SYSARG5(3,0,1,0,0)
#define	D_CLIDR_EL1	SYSARG5(3,1,0,0,1)
#define	D_CCSIDR_EL1	SYSARG5(3,1,0,0,0)
#define	D_CSSELR_EL1	SYSARG5(3,2,0,0,0)
#define	D_CTR_EL0	SYSARG5(3,3,0,0,1)

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
	/*
	 * m and up are extern registers (see dat.h): R27 and R26.  The
	 * first C code to run reads m->, so R27 must point at a Mach
	 * before main() is called rather than inside it, and up must be
	 * nil rather than whatever the firmware left.
	 */
	MOV	$mach0(SB), R27
	MOV	$0, R26
	MOV	R0, dtbptr(SB)		/* x0 holds the DTB physical address at boot */
	/*
	 * x1 is reserved zero by the AArch64 Linux boot protocol, which
	 * QEMU's -kernel path honours, so a loader can use it without
	 * disturbing that path.  os/inferno/boot/efi/aa64.s's jump()
	 * puts the configuration block there; bootargs.c copies it.
	 */
	MOV	R1, confptr(SB)
	BL	main(SB)
dead:
	B	dead

GLOBL	dtbptr(SB), $8
GLOBL	confptr(SB), $8
GLOBL	stack(SB), $KSTACK
GLOBL	mach0(SB), $(4*1024)

/*
 * The static base this kernel was linked with, so startcpu.c can hand
 * it to a processor that has to load R28 before it can run any C.
 * $setSB(SB) is the linker's own symbol for it and there is no way to
 * name it from C.
 */
TEXT	getsb(SB), 1, $-4
	MOV	$setSB(SB), R0
	RET	R30

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
 * A PSCI call.  SMCCC wants the function number in x0 and the three
 * arguments in x1-x3, and returns in x0.
 *
 * Only x0 arrives that way on its own.  7c passes the first argument
 * in a register (REGARG is 0, see utils/7c/txt.c's curarg==0 case) and
 * every argument after it on the stack, so x1-x3 hold whatever the
 * caller last had in them unless they are loaded here.  This was
 * written the other way first, on the assumption that a four-argument
 * call arrives in x0-x3, and nothing caught it because the only PSCI
 * calls this kernel made were SYSTEM_OFF and SYSTEM_RESET, which take
 * no arguments at all -- both of which are now known to complete, see
 * archvirtarm64.c.  CPU_ON, which takes three, answered
 * INVALID_PARAMETERS every time.  The frame offsets below are the same
 * ones os/inferno/boot/efi/aa64.s's eficall uses: the slot at 0(FP) is
 * reserved for the register-passed first argument and never written,
 * so the second argument is at 8(FP).
 *
 * Which instruction reaches PSCI is firmware's to say: a guest running
 * at EL1 under a hypervisor reaches it with HVC, a machine whose
 * firmware sits at EL3 reaches it with SMC.  The FADT's ARM Boot
 * Architecture Flags carry the answer and archvirtarm64.c's psci()
 * picks between these two on it.
 */
TEXT	pscihvc(SB), 1, $-4
	MOV	a1+8(FP), R1
	MOV	a2+16(FP), R2
	MOV	a3+24(FP), R3
	HVC	$0
	RET	R30

TEXT	pscismc(SB), 1, $-4
	MOV	a1+8(FP), R1
	MOV	a2+16(FP), R2
	MOV	a3+24(FP), R3
	SMC	$0
	RET	R30

/*
 * getmpidr(): this processor's own affinity, the one value MPIDR_EL1
 * can give and the MADT cannot -- MPIDR_EL1 reads only the processor
 * executing it, which is how startcpu.c tells its own entry in the
 * MADT's list from the others.
 */
TEXT	getmpidr(SB), 1, $-4
	MRS	SPR(D_MPIDR_EL1), R0
	RET	R30

/*
 * Where PSCI CPU_ON lands a processor this kernel has just started.
 * It runs with the MMU and caches off, at EL1, on no stack and with
 * no SB set, so it must not touch a global by name and must not call
 * anything: x0 holds whatever was handed to CPU_ON as its context id,
 * and startcpu.c hands it the address of that processor's own slot.
 * Writing its MPIDR there is the whole of what it does -- the value
 * comes from the processor's own register, not from the caller, so a
 * slot that fills in is a processor that really is the one the MADT
 * named.  Then it parks: WFE in a loop, waking on any event and going
 * straight back, touching nothing further.
 */
/*
 * _secondary(record): where a processor started by PSCI's CPU_ON
 * arrives.  R0 holds the context id CPU_ON was given, which is the
 * address of that processor's own Secboot record; the MMU is off, so
 * the address is physical as it stands and every access is to memory
 * rather than to a cache.  startcpu.c cleaned the record, the Mach and
 * the stack to the point of coherency before making the call, which is
 * what the AArch64 boot protocol requires of whoever starts a
 * processor ("the address range corresponding to the loaded kernel
 * image must be cleaned to the PoC", and those requirements "apply to
 * all CPUs").
 *
 * Nothing is written from here.  Every write this processor makes
 * happens in secondary() below, with the MMU on and the memory Normal
 * inner-shareable, so the primary reading it back is reading coherent
 * memory rather than polling a location two agents touch with
 * different cacheability -- which is the arrangement that works under
 * an emulator with no cache and fails on a core with one.
 *
 * Secboot offsets; keep in sync with startcpu.c.
 */
#define	SB_MPIDR	0
#define	SB_STACK	8
#define	SB_SB		16
#define	SB_MACH		24
#define	SB_L0		32
#define	SB_TCR		40

TEXT	_secondary(SB), 1, $-4
	MOV	R0, R19			/* the record; R19 survives mmuon */
	MOV	SB_STACK(R19), R1
	MOV	R1, RSP
	MOV	SB_SB(R19), R28		/* SB, before any C */
	MOV	SB_MACH(R19), R27	/* m */
	MOV	$0, R26			/* up */
	MOV	SB_L0(R19), R0
	MOV	SB_TCR(R19), R1
	BL	mmuon(SB)
	MOV	R19, R0
	BL	secondary(SB)
_secondarypark:
	WFE
	B	_secondarypark

/*
 * GICv3 CPU-interface accessors.  On a GICv3 the per-CPU interface is
 * a set of ICC_*_EL1 system registers, not the MMIO GICC page a GICv2
 * has, so acknowledge/EOI/priority-mask/group-enable are MSR/MRS here.
 * The ICC_* registers reach the assembler through SPR(); the single arg
 * / return value lives in R0/x0 where 7c's calling convention already
 * puts it.  SRE and group-enable writes need an ISB before the next
 * fetch sees them.
 */
TEXT	seticcsre(SB), 1, $-4
	MSR	R0, SPR(D_ICC_SRE_EL1)
	ISB	$15
	RET	R30

TEXT	geticcsre(SB), 1, $-4
	MRS	SPR(D_ICC_SRE_EL1), R0
	RET	R30

TEXT	seticcpmr(SB), 1, $-4
	MSR	R0, SPR(D_ICC_PMR_EL1)
	RET	R30

TEXT	seticcbpr1(SB), 1, $-4
	MSR	R0, SPR(D_ICC_BPR1_EL1)
	RET	R30

TEXT	seticcgrpen1(SB), 1, $-4
	MSR	R0, SPR(D_ICC_IGRPEN1_EL1)
	ISB	$15
	RET	R30

TEXT	seticcctlr(SB), 1, $-4
	MSR	R0, SPR(D_ICC_CTLR_EL1)
	RET	R30

TEXT	geticciar(SB), 1, $-4
	MRS	SPR(D_ICC_IAR1_EL1), R0
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
	MRS	SPR(D_ID_AA64PFR0_EL1), R0
	RET	R30

/*
 * ID_AA64MMFR0_EL1.PARange (bits 3:0): the physical address size this
 * core implements, in the same encoding TCR_EL1.IPS uses -- 0 is 32
 * bits, 1 is 36, 2 is 40, 3 is 42, 4 is 44, 5 is 48.  mmuinit() reads
 * it because writing an IPS larger than PARange is CONSTRAINED
 * UNPREDICTABLE, and the value that was there was a constant 4 chosen
 * for no reason beyond covering the map: correct on a core with 44-bit
 * addressing and unspecified on one with less.
 */
TEXT	getmmfr0(SB), 1, $-4
	MRS	SPR(D_ID_AA64MMFR0_EL1), R0
	RET	R30

TEXT	seticceoir(SB), 1, $-4
	MSR	R0, SPR(D_ICC_EOIR1_EL1)
	RET	R30

/*
 * _tas, cmpswap, ainc and adec: the four primitives everything above
 * them assumes are atomic.  They were spl-masked C in
 * archvirtarm64.c, which is correct on one processor and silently
 * wrong on two -- masking interrupts on this processor says nothing
 * about what another one is doing to the same word -- so they are
 * exclusive-monitor loops here before a second processor is allowed
 * to run any portable code.
 *
 * The acquire and release halves are not decoration.  LDAXRW gives
 * the acquire side, so nothing the caller does after taking a lock
 * can be observed before the lock is taken, and STLXRW gives the
 * release side on the way out.  os/inferno's own history has the
 * counter-example: emu's unlock() had no release barrier and the
 * scheduler deadlocked once in every couple of runs, with a signature
 * ("a list changed between two locked operations") that reads as a
 * lock bug and is a memory-ordering one.
 *
 * All four take a word (32-bit) rather than a doubleword: Lock.key,
 * Ref.ref and Heap.ref are all int.
 *
 * Where the emulator is more forgiving than hardware, and it is here:
 * this board runs with SCTLR_EL1.M clear (see mmu.c), so every data
 * access is Device-nGnRnE, and LDXR/STXR on Device memory is
 * CONSTRAINED UNPREDICTABLE -- the architecture does not promise the
 * exclusive monitor works at all.  QEMU's TCG implements a global
 * monitor regardless of memory type, so these loops behave correctly
 * under it and would not necessarily behave correctly on a core.  The
 * guarantee arrives when the MMU does, with RAM mapped Normal
 * write-back inner-shareable the way os/inferno/raspi3b/mmu.c maps it;
 * until then this code is right and its verification is emulator-only.
 */
TEXT	_tas(SB), 1, $-4
	MOV	R0, R3
	MOV	$1, R2
tas1:
	LDAXRW	(R3), R1
	STLXRW	R4, R2, (R3)
	CBNZW	R4, tas1
	MOV	R1, R0
	RET	R30

/*
 * cmpswap(int *addr, int old, int new): store new only if *addr is
 * still old, and say whether it was.  A failed compare clears the
 * monitor with CLREX rather than leaving it set for whatever runs
 * next -- an abandoned exclusive monitor is not a correctness bug on
 * its own, but leaving one behind on every failed compare is the kind
 * of thing that makes an unrelated STLXR fail spuriously and forever.
 */
TEXT	cmpswap(SB), 1, $-4
	MOV	R0, R3
	MOVW	arg1+8(FP), R1
	MOVW	arg2+16(FP), R2
cas1:
	LDAXRW	(R3), R4
	CMPW	R4, R1
	BNE	cas2
	STLXRW	R5, R2, (R3)
	CBNZW	R5, cas1
	MOVW	$1, R0
	RET	R30
cas2:
	CLREX	$0
	MOVW	$0, R0
	RET	R30

/*
 * ainc/adec: libinterp's Dis reference-counting primitives (AINC/ADEC
 * in include/interp.h), which return the new value.  Nothing in
 * os/inferno provides these for the aarch64 objtype but this file.
 */
TEXT	ainc(SB), 1, $-4
	MOV	R0, R3
ainc1:
	LDAXRW	(R3), R1
	ADDW	$1, R1
	STLXRW	R2, R1, (R3)
	CBNZW	R2, ainc1
	MOVW	R1, R0
	RET	R30

TEXT	adec(SB), 1, $-4
	MOV	R0, R3
adec1:
	LDAXRW	(R3), R1
	SUBW	$1, R1
	STLXRW	R2, R1, (R3)
	CBNZW	R2, adec1
	MOVW	R1, R0
	RET	R30

/*
 * dcinvalidate(): invalidate every level of data/unified cache by
 * set/way, which is what the architecture requires before turning the
 * D-cache on: at reset the cache contents are UNKNOWN, and enabling C
 * with stale lines present lets the core hit them instead of the
 * memory the kernel has been writing with caches off.
 *
 * CLIDR_EL1 names the levels; for each one that has data or unified
 * cache, CSSELR_EL1 selects it and CCSIDR_EL1 gives the geometry --
 * LineSize (log2 words minus 2) in bits 2:0, Associativity-1 in 12:3,
 * NumSets-1 in 27:13.  DC ISW takes SetWay = way<<(32-log2(assoc)) |
 * set<<linesize+4 | level<<1.
 *
 * Where the emulator is more forgiving than hardware: QEMU models no
 * cache, so DC ISW is a no-op there and this loop's effect cannot be
 * observed under it.  What running it here does establish is that the
 * loop terminates, that the geometry registers read back something
 * self-consistent, and that the shift arithmetic does not run away --
 * cacheinfo() prints what the walk found, so a machine's own numbers
 * are in its boot log rather than assumed.  os/inferno/raspi3b/l.s
 * leaves this out and says not to enable the D-cache on real hardware
 * without it; this is that walk.
 */
TEXT	dcinvalidate(SB), 1, $-4
	DSB	$15
	MRS	SPR(D_CLIDR_EL1), R0
	AND	$0x7000000, R0, R3	/* LoC << 24 */
	LSR	$23, R3, R3		/* LoC * 2 */
	CBZ	R3, dcidone
	MOV	$0, R10			/* R10 = level * 2 */
dcilevel:
	ADD	R10, R10, R2
	LSR	R2, R0, R12
	AND	$7, R12, R12		/* cache type at this level */
	CMP	$2, R12
	BLT	dcinext			/* no data or unified cache here */

	MSR	R10, SPR(D_CSSELR_EL1)	/* select level, data cache */
	ISB	$15
	MRS	SPR(D_CCSIDR_EL1), R1

	AND	$7, R1, R2
	ADD	$4, R2, R2		/* R2 = log2(line bytes) */
	LSR	$3, R1, R4
	AND	$0x3FF, R4, R4		/* R4 = assoc - 1 */
	LSR	$13, R1, R5
	AND	$0x7FFF, R5, R5		/* R5 = sets - 1 */

	/* R6 = 32 - log2(assoc rounded up), the way shift */
	CLZW	R4, R6

dciset:
	MOV	R4, R7			/* way counter */
dciway:
	LSL	R6, R7, R8
	LSL	R2, R5, R9
	ORR	R9, R8, R8
	ORR	R10, R8, R8
	SYS	R8, $SYSARG5(0,0,7,6,2)	/* DC ISW, R8 */
	SUB	$1, R7, R7
	CMP	$0, R7
	BGE	dciway
	SUB	$1, R5, R5
	CMP	$0, R5
	BGE	dciset

dcinext:
	ADD	$2, R10, R10
	CMP	R3, R10
	BLT	dcilevel
dcidone:
	MOV	$0, R0
	MSR	R0, SPR(D_CSSELR_EL1)
	DSB	$15
	ISB	$15
	RET	R30

/*
 * mmuenable(l0, tcr): 48-bit virtual addresses, four levels, 4 KiB
 * granule, TTBR0 only.  T0SZ = 16 gives the full 48 bits, which is
 * what reaches this machine's high PCIe window at 0x8000000000;
 * raspi3b's T0SZ = 25 would stop at 512 GiB.  EPD1 disables the TTBR1
 * half, which this kernel does not use -- there is one address space
 * and Dis is the isolation boundary.
 *
 * The TCR_EL1 value itself is built by mmuinit(), because its IPS
 * field is not a constant: see Tcrbase there.
 */
TEXT	mmuenable(SB), 1, $-4
	/*
	 * R0 is the table pointer and R30 the return address, and
	 * dcinvalidate() destroys both -- it reads CLIDR_EL1 into R0 and
	 * is reached by BL.  Losing R0 here is not a fault at the call:
	 * it is a TTBR0_EL1 loaded with whatever CLIDR left behind, and
	 * the machine dies silently at the SCTLR write two instructions
	 * later, with a correct set of page tables sitting in memory
	 * that nothing is pointing at.
	 */
	MOV	R0, R19
	MOV	R30, R20
	MOV	tcr+8(FP), R21		/* before the call, for the same reason */
	BL	dcinvalidate(SB)
	MOV	R19, R0
	MOV	R21, R1
	BL	mmuon(SB)
	MOV	R20, R30
	RET	R30

/*
 * mmuon(l0, tcr): the switch itself, with no cache maintenance in it,
 * so that a secondary can use it too.  A processor started by CPU_ON
 * comes out of a power-on reset with its caches invalid -- which is
 * why it does not repeat mmuenable()'s set/way walk, and why it must
 * not: that walk on a core whose outer level is shared with a running
 * processor would discard the other one's dirty lines.  Nothing here
 * touches memory, so it is callable before there is a usable stack,
 * and it uses only R0, R1, R2, R3 and R30.
 */
TEXT	mmuon(SB), 1, $-4
	MOV	$0xff00, R2		/* MAIR: attr1=Normal(ff), attr0=Device(00) */
	MSR	R2, SPR(D_MAIR_EL1)
	MSR	R1, SPR(D_TCR_EL1)
	MSR	R0, SPR(D_TTBR0_EL1)
	ISB	$15
	SYS	$SYSARG5(0,0,8,7,0)	/* TLBI VMALLE1 */
	DSB	$15
	ISB	$15
	SYS	$SYSARG5(0,0,7,5,0)	/* IC IALLU: invalidate I-cache */
	DSB	$15
	ISB	$15
	MRS	SPR(D_SCTLR_EL1), R2
	MOV	$0x1005, R3		/* M(0) | C(2) | I(12) */
	ORR	R3, R2, R2
	MSR	R2, SPR(D_SCTLR_EL1)
	ISB	$15
	RET	R30

/*
 * dccleanrange(p, n): clean [p, p+n) to the point of coherency, by
 * virtual address, so that a processor reading it with its MMU off
 * sees what this one wrote through its cache.  That is the whole of
 * what starting a processor requires of the one that starts it.
 *
 * By VA and not by set/way: a set/way walk cleans whatever happens to
 * be in the cache, which is not the same set of addresses and is not
 * safe on a shared level.  The line size is CTR_EL0.DminLine, in words,
 * and is read rather than assumed -- it is 64 bytes on the cores this
 * has run on and 128 on some.
 *
 * Under TCG this is exercised and not tested: an emulator with no
 * cache cannot tell a kernel that omits it from one that does not.
 */
TEXT	dccleanrange(SB), 1, $-4
	MOVW	n+8(FP), R1
	ADD	R0, R1, R1		/* end */
	MRS	SPR(D_CTR_EL0), R2
	LSR	$16, R2, R2
	AND	$0xf, R2, R2		/* DminLine: log2 of the line in words */
	MOV	$4, R3
	LSL	R2, R3, R3		/* line size in bytes */
	SUB	$1, R3, R4
	BIC	R4, R0, R0		/* down to the line the range starts in */
dcclean1:
	SYS	R0, $SYSARG5(0,3,7,10,1)	/* DC CVAC, R0 */
	ADD	R3, R0, R0
	CMP	R1, R0
	BLO	dcclean1
	DSB	$15
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
/*
 * m->splpc through R27, which is m, and not through $mach0(SB), which
 * is processor 0's Mach.  With one Mach the two were the same address
 * and the difference did not exist; with a Mach per processor, a
 * secondary taking a trap would have recorded its splpc in processor
 * 0's Mach -- writing the first word of a structure another processor
 * is using.  splpc is the first field for exactly this reason, and
 * dat.h says so.
 */
TEXT	splhi(SB), 1, $-4
	MRS	DAIF, R0
	AND	$0x80, R0, R1		/* previous I-bit, for the return value */
	MSR	$2, DAIFSet		/* imm bit1 = IRQ */
	MOV	R30, 0(R27)		/* m->splpc */
	MOV	R1, R0
	RET	R30

TEXT	spllo(SB), 1, $-4
	MRS	DAIF, R0
	AND	$0x80, R0, R1
	MSR	$2, DAIFClr
	MOV	R1, R0
	RET	R30

TEXT	splx(SB), 1, $-4
	MOV	R30, 0(R27)		/* m->splpc; see splhi above */
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

	/*
	 * Reserve the C-call argument-home area BELOW the Ureg before
	 * calling trap().  Plan 9's arm64 convention gives the callee a
	 * stack home for arg0 at caller-SP+8; with SP sitting on the Ureg
	 * base that slot IS UR_R1, so trap()'s prologue spilling its Ureg*
	 * argument overwrote the saved R1 on every single interrupt --
	 * harmless wherever R1 was dead, but it clobbers a live R1 (e.g. a
	 * loop counter in interrupted code).  Drop SP by 16 so the arg home
	 * lands in scratch, pass &Ureg = SP+16, pop it before the restore.
	 */
	SUB	$16, RSP
	ADD	$16, RSP, R0		/* R0 = &Ureg (the frame base) */
	BL	trap(SB)
	ADD	$16, RSP

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
	/*
	 * R26 (up) and R27 (m) are NOT restored from the frame.
	 *
	 * They belong to the processor and to the scheduler, not to the
	 * interrupted code.  What was here restored both, which is
	 * harmless on one processor -- the frame was built by this
	 * processor, so the m it holds is this processor's -- and is the
	 * whole of the SMP fault as soon as there is a second.  A
	 * process interrupted on cpu0 carries a frame on its kernel
	 * stack naming cpu0's Mach; when the scheduler resumes that
	 * process on cpu1 and it returns through here, cpu1's m becomes
	 * cpu0's Mach, and cpu1's own entirely correct ilock()/iunlock()
	 * then count cpu0's m->ilockdepth.  up comes back wrong by the
	 * same instruction.
	 *
	 * That is not a guess about this board: it is what the identical
	 * "POPQ R14; POPQ R15" did in os/inferno/pc64/l.s, measured
	 * there -- 4 of 4 two-processor runs faulting before, 20 of 20
	 * clean after -- and os/9front/pc64/l.s guards it with a test on
	 * the saved CS for exactly this reason.  This board needs no
	 * such test: os/inferno/virtarm64/trap.c records that the kernel
	 * "never itself enters EL0", so every exception here is EL1 to
	 * EL1 and the reload was always the nested case.  If EL0 is ever
	 * introduced, the reload comes back guarded on the saved SPSR's
	 * mode field at UR_STATUS, the way pc64 guards on CS.
	 *
	 * The entry stub still saves both, so a register dump is
	 * unchanged.
	 */
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
