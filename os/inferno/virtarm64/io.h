/*
 * Ureg.type values -- keep numerically in sync with l.s's own
 * vector-table entry stubs, one per AArch64 exception class taken
 * at current EL with SP_ELx (the only group this single-EL kernel
 * ever reaches; see l.s's vector table comment).
 */
enum {
	TSync	= 0,
	TIrq	= 1,
	TFiq	= 2,
	TSerr	= 3,
};

#define	BUSUNKNOWN	(-1)

/*
 * PL011 (arm,pl011 @ 0x09000000) -- 32-bit registers, word offsets.
 * Identical to armv7's board: same QEMU virt machine regardless of
 * -cpu cortex-a15 vs cortex-a72.
 */
enum {
	UartDR		= 0x00/4,
	UartFR		= 0x18/4,
	UartIBRD	= 0x24/4,
	UartFBRD	= 0x28/4,
	UartLCRH	= 0x2c/4,
	UartCR		= 0x30/4,
	UartIMSC	= 0x38/4,
	UartRIS		= 0x3c/4,
	UartMIS		= 0x40/4,
	UartICR		= 0x44/4,

	UartFRTXFF	= 1<<5,		/* transmit fifo full */
	UartFRRXFE	= 1<<4,		/* receive fifo empty */
	UartFRBUSY	= 1<<3,

	UartLCRHFEN	= 1<<4,		/* fifo enable */
	UartLCRHWLEN8	= 3<<5,		/* 8 bit word length */

	UartCRUARTEN	= 1<<0,
	UartCRTXE	= 1<<8,
	UartCRRXE	= 1<<9,

	UartIMSCRX	= 1<<4,
	UartIMSCTX	= 1<<5,

	UartICRALL	= 0x7ff,
};

/*
 * GICv2 (arm,cortex-a15-gic @ 0x08000000 dist, 0x08010000 cpu) --
 * word offsets from the start of each block.  Identical layout to
 * armv7's board.
 */
enum {
	GicdCTLR	= 0x000/4,
	GicdTYPER	= 0x004/4,
	GicdISENABLER	= 0x100/4,	/* +irq/32 */
	GicdICENABLER	= 0x180/4,
	GicdIPRIORITYR	= 0x400/4,	/* byte array really; see ipriority8 */
	GicdITARGETSR	= 0x800/4,	/* byte array really; see itargets8 */
	GicdICFGR	= 0xc00/4,

	GiccCTLR	= 0x000/4,
	GiccPMR		= 0x004/4,
	GiccIAR		= 0x00c/4,
	GiccEOIR	= 0x010/4,

	/* GICv2 distributor extras used only by the v3 path's SPI setup */
	GicdIGROUPR	= 0x080/4,	/* +irq/32; 1 == group 1 */
	GicdPIDR2	= 0xffe8/4,	/* [7:4] == architecture revision */

	/*
	 * GICv3 redistributor.  Each cpu owns a 128K pair: an RD_base
	 * frame (WAKER lives here) immediately followed by an SGI_base
	 * frame at +0x10000 that holds this cpu's SGI/PPI enable,
	 * priority and group registers - the v2 GicdISENABLER/IGROUPR
	 * for interrupts 0..31 move here on a v3.
	 */
	GicrTYPER	= 0x0008,	/* RD_base, 64-bit, byte offset */
	GicrTYPER_VLPIS	= 1<<1,
	GicrTYPER_Last	= 1<<4,
	GicrWAKER	= 0x0014/4,	/* RD_base: bit1 sleep, bit2 childrenasleep */
	GicrSGIoff	= 0x10000,	/* SGI_base = RD_base + this */
	GicrIGROUPR0	= 0x0080/4,	/* SGI_base-relative */
	GicrISENABLER0	= 0x0100/4,	/* SGI_base-relative */
	GicrIPRIORITYR	= 0x0400/4,	/* SGI_base-relative, byte array */

	GicdIROUTER	= 0x6000,	/* byte offset; +8*irq, 64-bit affinity */
	GicdCTLR_ARE	= 1<<4,		/* affinity routing enable */
	GicdCTLR_EN1	= 1<<1,		/* enable group 1 (with ARE set) */

	/*
	 * 32 virtio slots start at 48, and a GICv2m frame's SPIs sit above
	 * those -- QEMU's is 80..143, which is why this is not 96 any more.
	 */
	GicIRQMax	= 224,
	/*
	 * LPIs, which an ITS delivers.  They start at 8192 by
	 * architecture; how many this board hands out is its own choice
	 * and is the size of the dispatch table in trap.c.
	 */
	Lpiintid	= 8192,
	Nlpivec		= 64,
	GicSpiBase	= 32,
	GicPPITimer	= 27,		/* virtual timer (PPI 11); see cycles() in l.s */
};

/* virtio-mmio SPI n is GIC IRQ 32+16+n == 48+n (see mem.h VIRTIO0) */
#define	VirtioIRQ(n)	(48+(n))
enum {
	Virtio0IRQ	= 48,		/* ethervirtiommio.c: c->irq = Virtio0IRQ + slot */
};

/*
 * Generic timer (CNTP_*, EL1 physical timer) -- accessed only
 * through l.s helpers below; no C-visible register numbers needed.
 * Real 64-bit values stay pointer-out-param, matching riscv64/armv7
 * precedent, not because 7c can't return a uvlong (it can, LP64) but
 * because nothing in this tree has needed to risk finding out yet.
 */
void	cycles(uvlong*);
void	hwtimerset(uvlong*);
void	cntfrq(uvlong*);

/*
 * What acpi.c reads out of the MADT's GICC structures, one per
 * processor.  Kept as a board type rather than a private one in
 * acpi.c because the MPIDR is what anything that starts a second
 * processor has to hand PSCI.
 */
enum {
	Nacpicpu	= 64,	/* processors recorded; the rest are counted */
	Nacpitab	= 24,	/* tables remembered for printing afterwards */
	Nacpimsi	= 8,	/* GICv2m MSI frames */
	Nacpiits	= 8,	/* GICv3 ITS blocks */
};

typedef struct Acpimsi Acpimsi;
struct Acpimsi {		/* MADT GIC MSI frame, type 0x0D */
	u32int	id;
	uvlong	base;
	u32int	flags;		/* bit 0: the SPI count and base below are real */
	int	spicount;
	int	spibase;
};

typedef struct Acpiits Acpiits;
struct Acpiits {		/* MADT GIC ITS, type 0x0F */
	u32int	id;
	uvlong	base;
};

typedef struct Acpitab Acpitab;
struct Acpitab {
	char	sig[5];
	uvlong	addr;
	int	len;
	int	ok;		/* header length and checksum are good */
};

typedef struct Acpicpu Acpicpu;
struct Acpicpu {
	u32int	uid;		/* ACPI processor UID */
	u32int	flags;		/* 1 Enabled, 2 Online Capable (ACPI 6.3) */
	uvlong	mpidr;		/* PSCI CPU_ON's target */
	uvlong	gicr;		/* this processor's redistributor, GICv3 */
};

extern Acpicpu acpicpu[Nacpicpu];
extern int acpincpudesc, acpincpuall, acpincpu, acpicpushort;
extern int acpiarmboot, acpipsci, acpipscihvc;
extern uvlong acpiuart;
extern int acpiuartiface, acpiuartspace, acpiuartwidth, acpiuartaccess;
extern int acpiuartintr, acpiuartirq, acpiuartgsi, acpiuartbaud;
extern Acpitab acpitab[Nacpitab];
extern int acpintab, acpintaball, acpirev, acpixsdt, acpibad;
extern Acpimsi acpimsiframe[Nacpimsi];
extern Acpiits acpiits[Nacpiits];
extern int acpinmsiframe, acpinits;
extern uvlong acpiroot;
