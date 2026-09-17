/*
 * ARMv7-M (Cortex-M3, M4, M7): the System Control Space, and the Thumb-2
 * encodings this tree's assembler has no mnemonic for.
 *
 * Everything here is a #define, so os/inferno/armv7m/l.s and the C files
 * beside it both include it.
 *
 * An ARMv7-M core has no ARM state, so every instruction in a kernel for
 * one is a Thumb instruction.  utils/5a assembles the ARM assembler
 * syntax and utils/tl encodes it with the Thumb encodings; where the
 * instruction needed has no ARM mnemonic at all -- the M-profile system
 * registers, the barriers, the exclusive monitor -- it is written here as
 * a raw halfword (HWORD) or a raw pair of them (T2).
 */

/*
 * A WORD is four bytes, so it is two Thumb halfwords with the first one
 * in the low half.  A single halfword is HWORD, which utils/tl added for
 * exactly this; see utils/5c/5.out.h.
 */
#define	T2(hw1, hw2)	WORD	$((((hw2)&0xffff)<<16)|((hw1)&0xffff))

/* SYSm operands of MRS and MSR */
#define	SYSM_APSR	0
#define	SYSM_XPSR	3
#define	SYSM_IPSR	5
#define	SYSM_MSP	8
#define	SYSM_PSP	9
#define	SYSM_PRIMASK	16
#define	SYSM_BASEPRI	17
#define	SYSM_FAULTMASK	19
#define	SYSM_CONTROL	20

#define	MRS(sysm, rd)	T2(0xf3ef, 0x8000|((rd)<<8)|(sysm))
#define	MSR(sysm, rn)	T2(0xf380|(rn), 0x8800|(sysm))

#define	CPSID		HWORD	$0xb672		/* PRIMASK = 1: mask interrupts */
#define	CPSIE		HWORD	$0xb662		/* PRIMASK = 0: unmask them */

#define	DSBSY		T2(0xf3bf, 0x8f4f)
#define	DMBSY		T2(0xf3bf, 0x8f5f)
#define	ISBSY		T2(0xf3bf, 0x8f6f)
#define	CLREX		T2(0xf3bf, 0x8f2f)

#define	LDREXW(rt, rn)		T2(0xe850|(rn), ((rt)<<12)|0x0f00)
#define	STREXW(rd, rt, rn)	T2(0xe840|(rn), ((rt)<<12)|((rd)<<8))

/*
 * VFP load and store multiple, the whole single-precision register file
 * at once.  utils/5a has mnemonics for the double-precision arithmetic
 * (MOVD, ADDD, ...) and none for these, so they are written out here.
 *
 * Bits of the first halfword, from the ARMv7-M architecture reference:
 * 1110110 then P, U, D, W, L and Rn.  Increment-after with no writeback
 * is P=0 U=1 W=0, so 0xec80 for a store and 0xec90 for a load, plus Rn.
 * The second halfword is Vd=0, coproc=1010 (cp10, single precision), and
 * an imm8 that counts registers: 32 of them, 0x20.
 *
 * Single precision on purpose.  A Cortex-M4's FPv4-SP has the 32 S
 * registers but no double-precision arithmetic, so this moves the whole
 * file -- D0-D15 included, since they alias S0-S31 -- on a core that
 * cannot add two doubles.  That is what makes it usable from the fault
 * handler that emulates the arithmetic.
 */
#define	VSTMIA32(rn)	T2(0xec80|(rn), 0x0a20)	/* VSTMIA rn, {S0-S31} */
#define	VLDMIA32(rn)	T2(0xec90|(rn), 0x0a20)	/* VLDMIA rn, {S0-S31} */

/*
 * FPSCR, to and from a core register.  Both are cp10, so both work on a
 * Cortex-M4: it is only the double-precision arithmetic FPv4-SP lacks.
 * The emulation needs these to publish a comparison's result, which is
 * where VCMP leaves it and what a following VMRS reads.
 */
#define	VMRSFPSCR(rt)	T2(0xeef1, ((rt)<<12)|0x0a10)	/* rt = FPSCR */
#define	VMSRFPSCR(rt)	T2(0xeee1, ((rt)<<12)|0x0a10)	/* FPSCR = rt */

#define	WFI		HWORD	$0xbf30
#define	NOOP		HWORD	$0xbf00
#define	BXR(rm)		HWORD	$(0x4700|((rm)<<3))

/*
 * System Control Space.  One page at a fixed address on every ARMv7-M
 * core, so it belongs here and not in a board's io.h.
 */
#define	SCS		0xe000e000

#define	SYST_CSR	(SCS+0x010)
#define	SYST_RVR	(SCS+0x014)
#define	SYST_CVR	(SCS+0x018)
#define	SYST_CALIB	(SCS+0x01c)
#define	  SystEnable	(1<<0)
#define	  SystTickint	(1<<1)
#define	  SystClksrc	(1<<2)		/* processor clock, not the reference */
#define	  SystCountflag	(1<<16)

#define	NVIC_ISER	(SCS+0x100)	/* 16 words: set enable */
#define	NVIC_ICER	(SCS+0x180)	/* clear enable */
#define	NVIC_ISPR	(SCS+0x200)	/* set pending */
#define	NVIC_ICPR	(SCS+0x280)	/* clear pending */
#define	NVIC_IABR	(SCS+0x300)	/* active */
#define	NVIC_IPR	(SCS+0x400)	/* one byte of priority per interrupt */

#define	SCB_CPUID	(SCS+0xd00)
#define	SCB_ICSR	(SCS+0xd04)
#define	SCB_VTOR	(SCS+0xd08)
#define	SCB_AIRCR	(SCS+0xd0c)
#define	  AircrKey	(0x05fa<<16)
#define	  AircrSysreset	(1<<2)
#define	SCB_SCR		(SCS+0xd10)
#define	SCB_CCR		(SCS+0xd14)
#define	SCB_SHPR1	(SCS+0xd18)
#define	SCB_SHPR2	(SCS+0xd1c)
#define	SCB_SHPR3	(SCS+0xd20)
#define	SCB_SHCSR	(SCS+0xd24)
#define	  ShcsrMemfault	(1<<16)
#define	  ShcsrBusfault	(1<<17)
#define	  ShcsrUsgfault	(1<<18)
#define	SCB_CFSR	(SCS+0xd28)
/*
 * CFSR is three fault status bytes in one word; the UsageFault byte is
 * the top halfword, and its bit 0 -- so bit 16 here -- says the fault
 * was an undefined instruction.  Written back to clear.
 */
#define	CfsrUndefinstr	(1<<16)
#define	SCB_HFSR	(SCS+0xd2c)
#define	SCB_MMFAR	(SCS+0xd34)
#define	SCB_BFAR	(SCS+0xd38)
#define	SCB_CPACR	(SCS+0xd88)
#define	  CpacrCp10	(3<<20)		/* full access */
#define	  CpacrCp11	(3<<22)

/* cache maintenance; Cortex-M7 only, absent on M3 and M4 */
#define	SCB_CLIDR	(SCS+0xd78)
#define	SCB_CTR		(SCS+0xd7c)
#define	SCB_CCSIDR	(SCS+0xd80)
#define	SCB_CSSELR	(SCS+0xd84)
#define	SCB_ICIALLU	(SCS+0xf50)
#define	SCB_ICIMVAU	(SCS+0xf58)
#define	SCB_DCIMVAC	(SCS+0xf5c)
#define	SCB_DCISW	(SCS+0xf60)
#define	SCB_DCCMVAU	(SCS+0xf64)
#define	SCB_DCCMVAC	(SCS+0xf68)
#define	SCB_DCCSW	(SCS+0xf6c)
#define	SCB_DCCIMVAC	(SCS+0xf70)
#define	SCB_DCCISW	(SCS+0xf74)
#define	  CcrIc		(1<<17)
#define	  CcrDc		(1<<16)

#define	FPU_FPCCR	(SCS+0xf34)
#define	  FpccrAspen	(1<<31)		/* set CONTROL.FPCA automatically */
#define	  FpccrLspen	(1<<30)		/* lazy floating point stacking */
#define	FPU_FPCAR	(SCS+0xf38)
#define	FPU_FPDSCR	(SCS+0xf3c)

/*
 * Exception numbers, which are what IPSR holds and what indexes the
 * vector table.  An interrupt from the NVIC is Excirq+n.
 */
#define	Excreset	1
#define	Excnmi		2
#define	Exchard		3
#define	Excmem		4
#define	Excbus		5
#define	Excusage	6
#define	Excsvc		11
#define	Excdebug	12
#define	Excpendsv	14
#define	Excsystick	15
#define	Excirq		16
