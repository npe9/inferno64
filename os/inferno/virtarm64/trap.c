#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"

static void	(*irqhandler[GicIRQMax])(Ureg*, void*);
static void	*irqarg[GicIRQMax];

extern char	etext[];

extern void	vectrap(void);
extern void	vectorinit(void*);

/*
 * The built table, for any processor that comes up later.  It is
 * assembled once and never written again, so a secondary installs the
 * same one rather than building its own.
 */
void	*vectab;

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

static void
vectorbuild(void)
{
	u32 *v;
	int i;

	v = (u32*)(((uintptr)rawvectab + VBAR_ALIGN-1) & ~(uintptr)(VBAR_ALIGN-1));

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
	vectab = v;
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

extern void	seticcsre(ulong);
extern void	seticcpmr(ulong);
extern void	seticcbpr1(ulong);
extern void	seticcgrpen1(ulong);
extern ulong	geticciar(void);
extern ulong	getpfr0(void);
extern void	seticceoir(ulong);

static void
gicenable(int irq)
{
	u32 *gicd, *sgi;

	if(irq <= 0 || irq >= GicIRQMax)
		return;
	gicd = (u32*)GICD;
	if(!gicv3){
		*((uchar*)GICD + 0x400 + irq) = 0xa0;	/* GICD_IPRIORITYR[irq] */
		gicd[GicdISENABLER + irq/32] = 1 << (irq%32);
		return;
	}
	if(irq < GicSpiBase){
		/* SGI/PPI: this cpu's redistributor SGI frame, not GICD */
		sgi = (u32*)(GICR + GicrSGIoff);
		*((uchar*)sgi + 0x400 + irq) = 0xa0;	/* GICR_IPRIORITYR */
		sgi[GicrISENABLER0] = 1 << (irq%32);
		return;
	}
	/* SPI: priority, affinity-route to cpu 0 (affinity 0), enable */
	*((uchar*)GICD + 0x400 + irq) = 0xa0;
	*(uvlong*)((uchar*)GICD + GicdIROUTER + 8*irq) = 0;
	gicd[GicdISENABLER + irq/32] = 1 << (irq%32);
}

void
gicinit(void)
{
	u32 *gicd, *gicc, *rd, *sgi;
	int i;

	gicd = (u32*)GICD;
	gicv3 = ((getpfr0() >> 24) & 0xf) != 0;
	if(!gicv3){
		gicc = (u32*)GICC;
		gicd[GicdCTLR] = 1;
		gicc[GiccPMR] = 0xff;
		gicc[GiccCTLR] = 1;
		gicenable(GicPPITimer);
		return;
	}

	/*
	 * GICv3 bring-up.  Order matters: enable system-register access
	 * to the cpu interface first, then wake this cpu's redistributor
	 * and wait for it, then turn on affinity routing at the
	 * distributor before enabling group 1 (with ARE set, an SPI's
	 * target comes from GICD_IROUTER, ignored until ARE is on), then
	 * unmask priority and enable group-1 delivery at the cpu
	 * interface.  Everything is placed in group 1 so it arrives as an
	 * IRQ (group 0 would be an FIQ this kernel never enables).
	 */
	seticcsre(1);				/* ICC_SRE_EL1.SRE = 1 */

	rd = (u32*)GICR;
	rd[GicrWAKER] &= ~2;			/* clear ProcessorSleep */
	while(rd[GicrWAKER] & 4)			/* wait ChildrenAsleep == 0 */
		;
	sgi = (u32*)(GICR + GicrSGIoff);
	sgi[GicrIGROUPR0] = ~0;			/* all SGI/PPI in group 1 */

	for(i = GicSpiBase/32; i < GicIRQMax/32 + 1; i++)
		gicd[GicdIGROUPR + i] = ~0;	/* all SPIs in group 1 */
	gicd[GicdCTLR] = GicdCTLR_ARE;
	gicd[GicdCTLR] = GicdCTLR_ARE | GicdCTLR_EN1;

	seticcpmr(0xff);			/* unmask all priorities */
	seticcbpr1(0);				/* no sub-priority preemption */
	seticcgrpen1(1);			/* enable group 1 at cpu interface */

	gicenable(GicPPITimer);
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
		if(irq == GicPPITimer)
			clockintr(ur);
		else if(irq < GicIRQMax && (f = irqhandler[irq]) != nil)
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
