#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"

static void	(*irqhandler[GicIRQMax])(Ureg*, void*);

/*
 * Whether a device interrupt may preempt the process it interrupted.
 * See the call site below: measured, it takes the wake-up latency from
 * 2.7-142ms to 203us and ETHERUSB-SETUP from 9620ms to 2300 with no
 * spin in the driver at all -- and it wedges the board.
 */
static int intrpreempt = 0;
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

extern void crumbentry(void);

static void
buildslot(u32 *slot, int class)
{
	slot[0] = 0xd518d089;			/* MSR TPIDR_EL1, X9 */
	slot[1] = insn_movz(9, class);
	slot[2] = insn_b(&slot[2], (void*)crumbentry);
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
	/*
	 * These instructions were just written through the data cache,
	 * with the MMU and caches already on.  The Cortex-A53's separate
	 * L1 instruction cache fetches from memory, which may still hold
	 * what was there before, so clean the written lines out to memory
	 * and drop any instruction-cache state before the vectors can be
	 * taken (as Linux's flush_icache_range does).  QEMU has no caches.
	 */
	cacheflush(v, NSlot*SlotSize);
	cacheiinv();
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
 * its own CNTP_CTL ISTATUS bit.  Peripheral IRQs come from the BCM2835
 * controller at IRQBASE, which splits its 64 GPU sources across two
 * pending registers -- see the loop in trap(). */
extern ulong getcntpctl(void);

enum {
	CntpIStatus	= 1<<2,		/* CNTP_CTL_EL0.ISTATUS: timer fired */
	IrqEnable1	= 0x10,
	IrqPending1	= 0x04,
	IrqPendingBasic	= 0x00,
	Ngpubank	= 2,		/* GPU IRQs 0..63, in two registers */

	/*
	 * The ARM basic bank, carried here as IRQs 64..71 so that one
	 * flat number space covers the whole controller.  Only bits
	 * 0..7 of IRQ_PENDING_BASIC are sources (bit 0 is the ARM
	 * timer); bits 8 and 9 merely say "something is pending in
	 * bank 1 / bank 2", and bits 10..20 are duplicate copies of
	 * eleven selected GPU IRQs -- 57, the PL011, among them.
	 * Dispatching on those would run a handler twice.  Basicmask
	 * is what keeps this to real sources.
	 */
	Basicbase	= 64,
	Nbasicirq	= 8,
	Basicmask	= 0xff,
};

static void
gicenable(int irq)
{
	u32 *ic;

	if(irq <= 0 || irq >= GicIRQMax)
		return;
	/*
	 * There was a special case here skipping GicPPITimer (30) as
	 * "the generic timer, enabled by clock.c".  That is virt-board
	 * legacy: clock.c drives the generic timer through timerie()
	 * and never calls intrenable() at all, while 30 is a perfectly
	 * ordinary GPU IRQ on this controller -- so the special case
	 * did nothing but silently refuse to enable one real source.
	 */
	ic = (u32*)IRQBASE;
	/*
	 * 0x10/0x14 are ENABLE_1 and ENABLE_2; 0x18 is ENABLE_BASIC,
	 * which is where irq/32 == 2 lands, so IRQs 64..71 enable
	 * themselves correctly with the same arithmetic.
	 */
	ic[IrqEnable1/4 + irq/32] = 1 << (irq%32);
}

void
gicinit(void)
{
	/*
	 * BCM2836 local controller GPU_INT_ROUTING: bits 1:0 pick the core
	 * that takes the BCM2835 (GPU) peripheral IRQs, bits 3:2 the core
	 * for their FIQ.  Only core 0 runs this kernel -- the others sit at
	 * WFE -- so route both there rather than trusting the reset or
	 * firmware value; a peripheral IRQ routed to a parked core is
	 * simply never seen.
	 */
	*(volatile u32*)0x4000000c = 0;
	coherence();
}

void
trapinit(void)
{
	vectorbuild();
	gicinit();
}

/*
 * Crumb record (l.s crumbentry): words 0-7 are the last exception taken,
 * 144-149 the first taken on a wild SP, 152-155 a label gotolabel refused.
 * The block is mapped Device (mmu.c), uncached, so a record survives a
 * reset that is not a power cycle.
 */
enum { Crumbbase = 0x20000000 };

/*
 * l.s gotolabel found a label whose sp cannot be a kernel stack.
 * Crumb words 152-155: the label, its sp and pc, gotolabel's caller.
 */
void
badlabel(Label *l)
{
	volatile uvlong *c = (volatile uvlong*)Crumbbase;

	splhi();
	serialputs("BADLABEL", -1);
	serialputreg("label", c[152], 8);
	serialputreg("sp", c[153], 16);
	serialputreg("pc", c[154], 8);
	serialputreg("caller", c[155], 8);
	if(up != nil){
		serialputreg("pid", up->pid, 4);
		serialputreg("up", (uintptr)up, 8);
		serialputreg("kstack", (uintptr)up->kstack, 8);
		serialputreg("errlab0", (uintptr)up->errlab, 8);
		serialputreg("nerrlab", up->nerrlab, 4);
		serialputreg("sched", (uintptr)&up->sched, 8);
	}
	serialputs("\n", -1);
	USED(l);
	panic("gotolabel: bad sp %#llux pc %#llux from %#llux", c[153], c[154], c[155]);
}

/*
 * l.s crumbentry moved an exception taken on a wild SP onto wildstack;
 * crumb words 144-149 hold the first such exception's ELR, SPSR, ESR,
 * SP, X30 and X29.
 */
static void
wildspreport(Ureg *ur)
{
	volatile uvlong *c = (volatile uvlong*)Crumbbase;

	serialputs("WILDSP type ", -1);
	serialputdec(ur->type);
	serialputreg("elr", c[144], 8);
	serialputreg("spsr", c[145], 3);
	serialputreg("esr", c[146], 8);
	serialputreg("sp", c[147], 16);
	serialputreg("lr", c[148], 8);
	serialputreg("fp", c[149], 16);
	if(up != nil){
		serialputreg("pid", up->pid, 4);
		serialputreg("kstack", (uintptr)up->kstack, 8);
	}
	serialputs("\n", -1);
	panic("exception on a wild sp %#llux at pc %#llux lr %#llux", c[147], c[144], c[148]);
}

void
trap(Ureg *ur)
{
	u32 pend;
	volatile u32 *ic;
	int irq, bank, v;
	void (*f)(Ureg*, void*);

	{
		extern char wildstack[];
		static int wildseen;
		if(!wildseen && (uchar*)ur >= (uchar*)wildstack && (uchar*)ur < (uchar*)wildstack + 16*1024){
			wildseen = 1;
			splhi();
			wildspreport(ur);
		}
	}
	switch(ur->type){
	case TIrq:
		if(getcntpctl() & CntpIStatus){
			clockintr(ur);
			return;
		}
		/*
		 * Both GPU banks.  The controller carries 64 GPU sources
		 * in IRQ_PENDING1 (0..31) and IRQ_PENDING2 (32..63), and
		 * gicenable() below already writes whichever ENABLE
		 * register a source belongs to.  Reading only the first
		 * pending register therefore left every source from 32 up
		 * armed in the controller and never dispatched -- which is
		 * exactly how the PL011 (GPU IRQ 57) sat enabled and
		 * silent, and why console output had to be drained from
		 * process context alone.
		 */
		ic = (volatile u32*)IRQBASE;
		for(bank = 0; bank < Ngpubank; bank++){
			pend = ic[IrqPending1/4 + bank];
			for(irq = 0; irq < 32; irq++){
				if((pend & (1<<irq)) == 0)
					continue;
				v = bank*32 + irq;
				if((f = irqhandler[v]) != nil)
					f(ur, irqarg[v]);
			}
		}
		/*
		 * The basic bank is a third pending register, and not
		 * adjacent to the other two -- it sits below them, at
		 * offset 0, so it cannot be folded into the loop above.
		 */
		pend = ic[IrqPendingBasic/4] & Basicmask;
		for(irq = 0; irq < Nbasicirq; irq++){
			if((pend & (1<<irq)) == 0)
				continue;
			v = Basicbase + irq;
			if((f = irqhandler[v]) != nil)
				f(ur, irqarg[v]);
		}
		/*
		 * And let a process a handler just readied have the
		 * processor, which is what preempted() is for and what
		 * nothing in this kernel called.  Off by default: it
		 * wedges this board, and the wedge is not the nlocks one
		 * below.  ^\ on a wedged board shows every process in
		 * acquire() -- the Dis interpreter's own hand-off queue,
		 * not a QLock -- waiting for a VM that nobody is running
		 * to release.  Preempting a process that holds the
		 * interpreter is legitimate on its face, and something
		 * about it is not; that is the open question, and
		 * doc/raspi3b-completion-plan.ms carries it with the
		 * numbers that make it worth answering.
		 *
		 * Plan 9's trap() ends every non-clock interrupt with
		 * exactly this, under the same two guards.  Without it a
		 * process woken by a device waits for the clock path --
		 * hzsched raising delaysched, then sched() at a quantum
		 * boundary -- so at HZ=100 an I/O completion costs up to
		 * a tick before its waiter runs, and longer behind
		 * anything queued at the same priority.  Measured in
		 * usbdwc: 3 or 4 microseconds from arming a channel to
		 * the interrupt, then 2.7 to 142 milliseconds to be
		 * scheduled.
		 *
		 * The guards matter, and nlocks is the one that is not
		 * obvious.  sched() delays a reschedule while the process
		 * holds locks -- but only twenty times, and then goes
		 * anyway, "to avoid a missing unlock hanging the entire
		 * kernel".  Called once a tick that escape hatch is never
		 * reached; called on every device interrupt it is reached
		 * in milliseconds, and switching away from a process that
		 * holds a spin lock on a uniprocessor is every other
		 * process spinning on it for ever.  The board wedged
		 * exactly that way, and ^\ said so: every process in
		 * acquire(), the Dis interpreter's lock, and nobody
		 * running.
		 */
		/*
		 * Not islo(): interrupts are masked inside the handler,
		 * so a guard on them never lets this run -- which is what
		 * happened, and the counters in preempted() stayed at
		 * zero.  Plan 9's trap() guards on up and ilockdepth
		 * alone, and sched() panics by itself if it is ever
		 * entered holding an ilock.
		 */
		if(intrpreempt && up != nil && m->ilockdepth == 0 && up->nlocks == 0)
			preempted();
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
		 * Straight to the UART first: iprint() also draws on the
		 * framebuffer console and can wait on locks the faulting code
		 * holds, and a report that never appears looks like a hang.
		 */
		serialputs("TRAP type ", -1);
		serialputdec(ur->type);
		serialputreg("esr", ur->cause, 8);
		serialputreg("pc", ur->pc, 8);
		serialputreg("lr", ur->r30, 8);
		serialputreg("far", ur->tval, 16);
		serialputreg("sp", ur->sp, 8);
		serialputs("\n", -1);
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
	/*
	 * Anything above the basic bank is enabled by nobody and
	 * dispatched by nobody.  Fail here rather than silently: a
	 * source armed in the controller and never delivered is a
	 * quiet fault that costs a long time to find, which is
	 * exactly what IRQ 33 did to the console.
	 */
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
