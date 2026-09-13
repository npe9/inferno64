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
/* raspi3b has no GIC and QEMU maps no per-core IRQ-source register
 * (0x40000000 is RAM), so the generic timer is recognised in trap() by
 * its own CNTP_CTL ISTATUS bit.  Peripheral IRQs (unused: console is
 * polled) would come from the BCM2835 controller at IRQBASE. */
extern ulong getcntpctl(void);

enum {
	CntpIStatus	= 1<<2,		/* CNTP_CTL_EL0.ISTATUS: timer fired */
	IrqEnable1	= 0x10,
	IrqPending1	= 0x04,
	IrqPending2	= 0x08,
};

static void
gicenable(int irq)
{
	u32 *ic;

	if(irq <= 0 || irq >= GicIRQMax)
		return;
	if(irq == GicPPITimer)		/* generic timer: enabled by clock.c */
		return;
	ic = (u32*)IRQBASE;
	ic[IrqEnable1/4 + irq/32] = 1 << (irq%32);
}

void
gicinit(void)
{
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
	u32 pend;
	int irq;
	void (*f)(Ureg*, void*);

	switch(ur->type){
	case TIrq:
		if(getcntpctl() & CntpIStatus){
			clockintr(ur);
			return;
		}
		pend = ((volatile u32*)IRQBASE)[IrqPending1/4];
		for(irq = 0; irq < 32; irq++){
			if((pend & (1<<irq)) == 0)
				continue;
			if((f = irqhandler[irq]) != nil)
				f(ur, irqarg[irq]);
		}
		pend = ((volatile u32*)IRQBASE)[IrqPending2/4];
		for(irq = 32; irq < 64; irq++){
			if((pend & (1<<(irq-32))) == 0)
				continue;
			if((f = irqhandler[irq]) != nil)
				f(ur, irqarg[irq]);
		}
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
