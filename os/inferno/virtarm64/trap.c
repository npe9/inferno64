#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"

static void	(*irqhandler[GicIRQMax])(Ureg*, void*);
static void	*irqarg[GicIRQMax];

/*
 * LPIs are numbered from 8192 up and are not SPIs: they do not live in
 * the distributor's registers, they are not enabled with gicenable(),
 * and they are far outside irqhandler[].  An ITS delivers them (see
 * itsvirtarm64.c); this is the other half, the dispatch.
 */
static void	(*lpihandler[Nlpivec])(Ureg*, void*);
static void	*lpiarg[Nlpivec];

extern char	etext[];

extern void	vectrap(void);
extern void	vectorinit(void*);

/*
 * The AArch64 exception-vector table: VBAR_EL1 must point at a
 * 2048-byte-aligned block of 16 128-byte slots, one per (exception
 * level x SP bank x class) combination -- see the ARM ARM's "Vector
 * table" chapter.  This single-EL kernel always runs at EL1h (SP_EL1
 * selected) and never itself enters EL0, so it only ever takes an
 * exception into the third group (offset 0x200, "current EL, SPx"):
 * Sync at +0x200, IRQ at +0x280, FIQ at +0x300, SError at +0x380.
 *
 * Like armv7/l.s's own vectorbuild(), this table is built as runtime
 * DATA into an oversized static buffer, not linked branch code.  The
 * table must be 2048-byte aligned (VBAR_EL1's low bits are RES0), and
 * this linker has no per-symbol alignment -- 7l rounds only whole text
 * and data segments, to 4096 (see utils/7l/asm.c) -- so no TEXT symbol
 * can be placed on a 2KB boundary.  The base is therefore computed at
 * runtime by rounding this buffer, and once the base is runtime-only
 * the slot-to-vectrap branches (PC-relative) cannot be pre-assembled.
 * That is the one case here that stays hand-encoded: the nameable
 * system instructions in l.s (ISB, CLREX, WFE, HVC, TLBI via SYS, and
 * every MSR/MRS through SPR()) are assembler mnemonics.  Each of the
 * four active slots is four real AArch64 instructions (not pure
 * branches, encoded here because they must live at a runtime-only-known
 * address no assembler invocation ever sees):
 *
 *	SUB  SP, SP, #UR_SIZE       -- reserve the Ureg frame; touches
 *	                               no GPR, so nothing needs saving
 *	                               before it (unlike ARM32, which
 *	                               had no free register at all
 *	                               without banking tricks)
 *	STR  R9, [SP, #UR_R9]       -- true R9 is safe on the frame now
 *	MOVZ R9, #<class>           -- reuse R9 to carry the trap class
 *	B    vectrap                -- shared tail does the other 30
 *	                               register saves, the CSR reads,
 *	                               and the call into trap()
 *
 * The twelve inactive slots (EL0/AArch32 groups this kernel never
 * takes) are filled with a single "B ." (self-branch, offset 0) --
 * inert unless something is badly wrong, in which case spinning
 * beats running whatever garbage bytes would otherwise be fetched.
 */
enum {
	VBAR_ALIGN	= 2048,
	SlotSize	= 128,
	NSlot		= 16,

	Off_R0		= 0,
	Off_R9		= 72,
	Off_Type	= 272,
	UrSize		= 304,
};

enum {
	SlotSync	= 4,	/* current EL, SPx: sync */
	SlotIrq		= 5,	/* .. irq */
	SlotFiq		= 6,	/* .. fiq */
	SlotSerr	= 7,	/* .. serror */
};

static u32	rawvectab[NSlot*SlotSize/4 + VBAR_ALIGN/4];

static u32
insn_sub_sp_sp(u32 imm12)
{
	return 0xD1000000 | (imm12<<10) | 0x3FF;	/* Rn=Rd=31(SP) */
}

static u32
insn_add_sp_sp(u32 imm12)
{
	return 0x91000000 | (imm12<<10) | 0x3FF;
}

static u32
insn_str_x_sp(int rt, u32 byteoff)
{
	return 0xF9000000 | ((byteoff/8)<<10) | (31<<5) | rt;	/* [SP, #off] */
}

static u32
insn_movz(int rd, u32 imm16)
{
	return 0xD2800000 | (imm16<<5) | rd;
}

static u32
insn_b(u32 *at, void *target)
{
	int imm26;

	imm26 = (int)(((uchar*)target - (uchar*)at) / 4);
	return 0x14000000 | (imm26 & 0x3FFFFFF);
}

static void
buildslot(u32 *slot, int class)
{
	slot[0] = insn_sub_sp_sp(UrSize);
	slot[1] = insn_str_x_sp(9, Off_R9);
	slot[2] = insn_movz(9, class);
	slot[3] = insn_b(&slot[3], (void*)vectrap);
}

/*
 * Not static: secmain() installs this table on each secondary, which
 * is what makes a processor able to take its own traps.  It was a
 * file-scope global on the multicore side and static on the cloud
 * side, because only one of the two started other processors.
 */
u32 *vectab;

/*
 * Install the table this kernel already built.  Every processor needs
 * its own VBAR_EL1 -- it is a per-processor system register -- but
 * they can all point at the same table, since the table is read-only
 * code and the frame it builds is on whichever stack was interrupted.
 */
void
vectorinstall(void)
{
	vectorinit(vectab);
}

static void
vectorbuild(void)
{
	u32 *v;
	int i;

	v = (u32*)(((uintptr)rawvectab + VBAR_ALIGN-1) & ~(uintptr)(VBAR_ALIGN-1));
	vectab = v;

	for(i = 0; i < NSlot; i++){
		u32 *slot = v + i*(SlotSize/4);
		if(i == SlotSync)
			buildslot(slot, 0);
		else if(i == SlotIrq)
			buildslot(slot, 1);
		else if(i == SlotFiq)
			buildslot(slot, 2);
		else if(i == SlotSerr)
			buildslot(slot, 3);
		else
			slot[0] = insn_b(&slot[0], slot);	/* "b ." */
	}
	vectorinit(v);
}

/*
 * The distributor at GICD is present on both a GICv2 and a GICv3; the
 * two differ in the per-cpu interface (MMIO GICC vs the ICC_* system
 * registers) and in where SGI/PPI enable state lives (GICD on v2, the
 * per-cpu redistributor SGI frame on v3).  gicv3 is set once at boot
 * from ID_AA64PFR0_EL1.GIC (the cpu's own "is the ICC_* system-register
 * interface present" bit - a CPU ID read, so it never aborts, unlike
 * the GICv2 distributor's PIDR2 which QEMU does not implement and
 * faults on), and the three GIC entry points below branch on it; every
 * other board runs -M virt's default GICv2 and never touches v3.
 */
static int gicv3;

enum {
	Ngicrframe	= 512,		/* see gicrfind() */
};

extern void	seticcsre(ulong);
extern void	seticcpmr(ulong);
extern void	seticcbpr1(ulong);
extern void	seticcgrpen1(ulong);
extern ulong	geticciar(void);
extern ulong	getpfr0(void);
extern void	seticceoir(ulong);

/*
 * The architected timer's interrupt.  io.h's GicPPITimer is the value
 * QEMU's device tree gives and the one this board booted on before
 * there was any ACPI; acpi.c replaces it from the GTDT when the
 * firmware says something different, which is why this is a variable
 * and not the constant it reads from.  Set in gicinit() rather than
 * here: 7c rejects an initialiser on a definition a header has already
 * declared extern.
 */
int timerirq;

/*
 * Make an SPI edge-triggered.  A GICv2m frame raises an MSI by pulsing
 * the SPI -- QEMU's arm_gicv2m.c calls qemu_irq_pulse(), raise and drop
 * in one step -- and a level-triggered input latches nothing from a
 * pulse: the pending bit is cleared as the line drops again.  Measured
 * rather than reasoned: writing an SPI number to the frame's SETSPI
 * register left GICD_ISPENDR unchanged at 0, and setting the SPI to
 * edge here is what makes the same write land.  GICD_ICFGR is two bits
 * per interrupt, sixteen interrupts to a register, and 0b10 is edge.
 */
void
gicedge(int irq)
{
	u32 *gicd, v;
	int i, sh;

	if(irq < GicSpiBase || irq >= GicIRQMax)
		return;
	gicd = (u32*)GICD;
	i = GicdICFGR + irq/16;
	sh = (irq%16)*2;
	v = gicd[i];
	v &= ~(3 << sh);
	v |= 2 << sh;
	gicd[i] = v;
}

/*
 * Not static any more: acpi.c calls it to enable the timer's line when
 * the GTDT names a different one from io.h's, and msivirtarm64.c calls
 * gicedge() above.
 */
void
gicenable(int irq)
{
	u32 *gicd, *sgi;

	if(irq <= 0 || irq >= GicIRQMax)
		return;
	gicd = (u32*)GICD;
	if(!gicv3){
		*((uchar*)GICD + 0x400 + irq) = 0xa0;	/* GICD_IPRIORITYR[irq] */
		/*
		 * Target cpu0, explicitly.  GICD_ITARGETSR resets to 0 -- no
		 * target at all -- and a uniprocessor GIC ignores it and
		 * delivers to cpu0 anyway, so leaving it unwritten worked for
		 * exactly as long as this board ran on one processor.  With a
		 * second one present every SPI went to nobody: the uart's
		 * interrupt never arrived, its output queue filled, and the
		 * process holding the interpreter blocked in qflow() with
		 * every other one queued behind it on vmacquire().  That is
		 * the whole of "-smp 2 stops partway through the boot".
		 * SGIs and PPIs are per-cpu and have no target register.
		 * The GICv3 path below already routes explicitly.
		 */
		if(irq >= GicSpiBase)
			*((uchar*)GICD + 0x800 + irq) = 1;	/* GICD_ITARGETSR */
		gicd[GicdISENABLER + irq/32] = 1 << (irq%32);
		return;
	}
	if(irq < GicSpiBase){
		/*
		 * SGI/PPI: this cpu's redistributor SGI frame, not GICD --
		 * and this cpu's, which is why it comes from m->gicr and
		 * not from the constant.  Enabling the timer PPI in
		 * processor 0's frame would leave every other processor's
		 * timer masked, which is the failure this looked like
		 * before giccpuinit() existed.
		 */
		sgi = (u32*)(m->gicr + GicrSGIoff);
		*((uchar*)sgi + 0x400 + irq) = 0xa0;	/* GICR_IPRIORITYR */
		sgi[GicrISENABLER0] = 1 << (irq%32);
		return;
	}
	/* SPI: priority, affinity-route to cpu 0 (affinity 0), enable */
	*((uchar*)GICD + 0x400 + irq) = 0xa0;
	*(uvlong*)((uchar*)GICD + GicdIROUTER + 8*irq) = 0;
	gicd[GicdISENABLER + irq/32] = 1 << (irq%32);
}

/*
 * This processor's redistributor.  A GICv3 gives every processor a
 * frame of its own, and which frame is which is not an index: the
 * order the frames appear in is the implementation's, so each one
 * carries its own affinity in GICR_TYPER and the processor looks for
 * the one that matches its MPIDR.  The MADT can name them -- the GICC
 * structure has a field for it -- but on this machine the firmware
 * leaves it zero (acpi.c prints "gicr 0x0"), so the region base from
 * mem.h and this walk are what there is.
 *
 * The frames are contiguous, two 64 KiB pages each (RD_base and
 * SGI_base), or four if the implementation has virtual LPIs, which
 * GICR_TYPER.VLPIS says.  The last frame sets GICR_TYPER.Last, which
 * is what ends the walk rather than a count from somewhere else.
 */
static uintptr
gicrfind(void)
{
	uvlong mpidr, want, typer;
	uintptr rd;
	int i;

	mpidr = getmpidr();
	/* GICR_TYPER's affinity is Aff3.Aff2.Aff1.Aff0 packed into 32 bits */
	want = (mpidr & 0xFFFFFF) | (((mpidr>>32) & 0xFF) << 24);
	rd = GICR;
	/*
	 * GICR_TYPER.Last is what ends this; the count is only a guard
	 * against a table that never sets it, and it is large enough not
	 * to be the thing that fails on a machine with many processors
	 * -- MAXMACH bounds how many this kernel runs, not how many
	 * frames it may have to walk past to find its own.
	 */
	for(i = 0; i < Ngicrframe; i++){
		typer = *(uvlong*)(rd + GicrTYPER);
		if(((typer>>32) & 0xFFFFFFFF) == want)
			return rd;
		if(typer & GicrTYPER_Last)
			break;
		rd += (typer & GicrTYPER_VLPIS) ? 4*64*1024 : 2*64*1024;
	}
	return 0;
}

/*
 * The half of GIC bring-up that belongs to one processor: the cpu
 * interface, its own redistributor, and the interrupts that are
 * private to it.  Everything the distributor owns is global and stays
 * in gicinit().
 *
 * Order matters: enable system-register access to the cpu interface
 * first, then wake this cpu's redistributor and wait for it, then
 * unmask priority and enable group-1 delivery.  Everything is placed
 * in group 1 so it arrives as an IRQ (group 0 would be an FIQ this
 * kernel never enables).
 */
void
giccpuinit(void)
{
	u32 *gicc, *rd, *sgi;

	if(!gicv3){
		gicc = (u32*)GICC;
		gicc[GiccPMR] = 0xff;
		gicc[GiccCTLR] = 1;
		m->gicr = 0;
		gicenable(timerirq);
		return;
	}

	seticcsre(1);				/* ICC_SRE_EL1.SRE = 1 */

	m->gicr = gicrfind();
	if(m->gicr == 0){
		/*
		 * iprint, not print: this can run on a processor that is
		 * not in the scheduler, and print() takes kmesg.lk.
		 */
		iprint("gic: cpu%d mpidr %#llux has no redistributor; falling back to %#p\n",
			m->machno, getmpidr(), (void*)GICR);
		m->gicr = GICR;
	}
	rd = (u32*)m->gicr;
	rd[GicrWAKER] &= ~2;			/* clear ProcessorSleep */
	while(rd[GicrWAKER] & 4)			/* wait ChildrenAsleep == 0 */
		;
	sgi = (u32*)(m->gicr + GicrSGIoff);
	sgi[GicrIGROUPR0] = ~0;			/* all SGI/PPI in group 1 */

	seticcpmr(0xff);			/* unmask all priorities */
	seticcbpr1(0);				/* no sub-priority preemption */
	seticcgrpen1(1);			/* enable group 1 at cpu interface */

	gicenable(timerirq);
}

void
gicinit(void)
{
	u32 *gicd;
	int i;

	timerirq = GicPPITimer;
	gicd = (u32*)GICD;
	gicv3 = ((getpfr0() >> 24) & 0xf) != 0;
	if(!gicv3){
		gicd[GicdCTLR] = 1;
		giccpuinit();
		return;
	}

	/*
	 * The distributor, once for the machine.  Affinity routing goes
	 * on before group 1 is enabled: with ARE set an SPI's target
	 * comes from GICD_IROUTER, which is ignored until it is.
	 */
	for(i = GicSpiBase/32; i < GicIRQMax/32 + 1; i++)
		gicd[GicdIGROUPR + i] = ~0;	/* all SPIs in group 1 */
	gicd[GicdCTLR] = GicdCTLR_ARE;
	gicd[GicdCTLR] = GicdCTLR_ARE | GicdCTLR_EN1;

	giccpuinit();
}

/*
 * The per-processor half of gicinit(), for a secondary.  On a GICv2 the
 * cpu interface at GICC and the SGI/PPI enable bits in GICD_ISENABLER0
 * are banked per processor: the same addresses, configuring whichever
 * processor writes them.  So a secondary re-runs exactly those and
 * leaves the distributor, which is global, alone.
 *
 * GICv3 is not done.  There the redistributor is per processor at
 * GICR + n*stride and this board's GICR is a single fixed address --
 * cpu0's frame -- so a secondary would need its own, which is a change
 * to how the base is computed rather than a line added here.
 */
int
gicsecondary(void)
{
	u32 *gicc;

	if(gicv3)
		return -1;
	gicc = (u32*)GICC;
	gicc[GiccPMR] = 0xff;
	gicc[GiccCTLR] = 1;
	gicenable(GicPPITimer);
	return 0;
}

void
trapinit(void)
{
	vectorbuild();
	gicinit();
}

void
trap(Ureg *ur)
{
	u32 *gicc;
	u32 iar;
	int irq;
	void (*f)(Ureg*, void*);

	switch(ur->type){
	case TIrq:
		/*
		 * Acknowledge (IAR), dispatch, then end-of-interrupt
		 * (EOIR).  On v3 both are ICC_* system-register accesses
		 * and the INTID is 24 bits wide; on v2 they are the MMIO
		 * GICC page and the INTID is 10 bits.  A spurious read
		 * returns INTID 1020..1023 either way - dispatch guards it
		 * via the irqhandler bound check, and 1023 gets no EOI.
		 */
		if(gicv3){
			iar = geticciar();
			irq = iar & 0xffffff;
		}else{
			gicc = (u32*)GICC;
			iar = gicc[GiccIAR];
			irq = iar & 0x3ff;
		}
		if(irq == timerirq){
			/*
			 * A processor that is not machno 0 is not in the
			 * scheduler yet, and clockintr() is: checkalarms()
			 * and timercheck() walk structures that belong to
			 * it.  So a secondary re-arms its own timer and
			 * counts, which is all this increment claims and
			 * all it is entitled to do.
			 */
			if(m->machno == 0)
				clockintr(ur);
			else
				clocksecondary();
		}else if(irq >= Lpiintid && irq - Lpiintid < Nlpivec){
			if((f = lpihandler[irq - Lpiintid]) != nil)
				f(ur, lpiarg[irq - Lpiintid]);
		}else if(irq < GicIRQMax && (f = irqhandler[irq]) != nil)
			f(ur, irqarg[irq]);
		if(gicv3)
			seticceoir(iar);
		else
			gicc[GiccEOIR] = iar;
		return;
	default:
		/*
		 * ur is a frame on the interrupted kernel stack itself
		 * (see l.s's vectrap comment), not a single shared
		 * static buffer the way armv7/riscv64 use -- a nested
		 * trap during print()/panic() below (iunlock() calling
		 * splx(), re-admitting IRQs) lands in its OWN fresh
		 * frame further down the same stack rather than
		 * silently overwriting this one, so the armv7 comment's
		 * splhi()-before-touching-ur precaution is not required
		 * for correctness here.  Kept anyway: a nested trap
		 * mid-panic is still not something to invite.
		 */
		splhi();
		/*
		 * iprint(), not print(): print() takes kmesg.lk, and a fault
		 * inside code holding it (poolfree() under the print lock, seen
		 * here) made this report deadlock instead of appearing.
		 */
		iprint("trap type %d esr %#p pc %#p\n",
			(int)ur->type, ur->cause, ur->pc);
		iprint(" r0 %#p r30 %#p\n", ur->r0, ur->r30);
		iprint(" sp %#p tval %#p", ur->sp, ur->tval);
		if(up != nil)
			iprint(" kstack %#p..%#p", up->kstack, (uchar*)up->kstack+KSTACK);
		iprint("\n");
		if(up != nil)
			iprint(" up %#p %s\n", up, up->text);
		dumpstack();
		panic("trap");
	}
}

void
intrenable(int v, void (*f)(Ureg*, void*), void *a, int tbdf, char *name)
{
	USED(tbdf, name);
	if(v >= Lpiintid && v - Lpiintid < Nlpivec){
		/*
		 * An LPI is already enabled by its configuration byte and
		 * the ITS mapping that produced it, so there is nothing to
		 * turn on here -- only the handler to record.
		 */
		lpihandler[v - Lpiintid] = f;
		lpiarg[v - Lpiintid] = a;
		return;
	}
	if(v <= 0 || v >= GicIRQMax)
		panic("intrenable: irq %d", v);
	irqhandler[v] = f;
	irqarg[v] = a;
	gicenable(v);
}

void
intrdisable(int v, void (*f)(Ureg*, void*), void *a, int tbdf, char *name)
{
	USED(tbdf, f, a, name);
	if(v >= Lpiintid && v - Lpiintid < Nlpivec){
		lpihandler[v - Lpiintid] = nil;
		lpiarg[v - Lpiintid] = nil;
		return;
	}
	if(v > 0 && v < GicIRQMax){
		irqhandler[v] = nil;
		irqarg[v] = nil;
	}
}

void
dumpstack(void)
{
	uintptr l, v, estack;
	int n;

	iprint("dumpstack\n");
	l = (uintptr)&l;
	if(up != nil
	&& l >= (uintptr)up->kstack
	&& l < (uintptr)up->kstack+KSTACK)
		estack = (uintptr)up->kstack+KSTACK;
	else
		estack = l + 64*sizeof(uintptr);
	n = 0;
	for(; l < estack; l += sizeof(uintptr)){
		v = *(uintptr*)l;
		if(v > (uintptr)KTZERO && v < (uintptr)etext){
			iprint("%.8lux\n", (ulong)v);
			if(++n >= 32)
				break;
		}
	}
}
