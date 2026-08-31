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

extern void	vecreset(void);
extern void	vecundef(void);
extern void	vecswi(void);
extern void	vecpabt(void);
extern void	vecdabt(void);
extern void	vecirq(void);
extern void	vecfiq(void);

/*
 * The exception vector table, built as data at runtime rather than as
 * linked branch code -- 5l's branch-folding pass collapses a TEXT
 * block that is nothing but unconditional branches and lays other
 * code out over the address VBAR ends up pointing at (confirmed: no
 * run of B-family instructions survives anywhere in the linked image,
 * and VBAR readback landed on an unrelated function's RET).  A table
 * built as data survives because there is no branch for the linker to
 * fold.
 *
 * Each of the first 8 words is the identical trampoline
 * "ldr pc,[pc,#24]" (0xe59ff018, verified against arm-none-eabi-as):
 * at slot i, PC-at-execute is base+4*i+8, so "+#24" loads from
 * base+4*i+32 -- exactly slot (8+i) below, which holds that vector's
 * real handler address.  VBAR only requires 5-bit (32 byte) alignment
 * of the table's start, which the raw array below is not guaranteed
 * to have on its own, so the buffer is oversized and vectorbuild()
 * picks the first 32-byte-aligned word inside it at runtime.
 */
#define	VBAR_ALIGN	32
static u32	rawvectab[8+8 + VBAR_ALIGN/4];

static void
vectorbuild(void)
{
	u32 *v;
	void *targets[8];
	int i;

	v = (u32*)(((uintptr)rawvectab + VBAR_ALIGN-1) & ~(VBAR_ALIGN-1));

	targets[0] = (void*)vecreset;
	targets[1] = (void*)vecundef;
	targets[2] = (void*)vecswi;
	targets[3] = (void*)vecpabt;
	targets[4] = (void*)vecdabt;
	targets[5] = nil;			/* reserved slot, never fetched */
	targets[6] = (void*)vecirq;
	targets[7] = (void*)vecfiq;

	for(i = 0; i < 8; i++){
		v[i] = 0xe59ff018;		/* ldr pc, [pc, #24] */
		v[8+i] = (u32)targets[i];
	}
	vectorinit(v);
}

static void
gicenable(int irq)
{
	u32 *gicd;

	if(irq <= 0 || irq >= GicIRQMax)
		return;
	gicd = (u32*)GICD;
	*((uchar*)GICD + 0x400 + irq) = 0xa0;		/* GICD_IPRIORITYR[irq] */
	gicd[GicdISENABLER + irq/32] = 1 << (irq%32);
}

void
gicinit(void)
{
	u32 *gicd, *gicc;

	gicd = (u32*)GICD;
	gicc = (u32*)GICC;
	gicd[GicdCTLR] = 1;
	gicc[GiccPMR] = 0xff;
	gicc[GiccCTLR] = 1;
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
		gicc = (u32*)GICC;
		iar = gicc[GiccIAR];
		irq = iar & 0x3ff;
		if(irq == GicPPITimer){
			clockintr(ur);
			gicc[GiccEOIR] = iar;
			return;
		}
		if(irq < GicIRQMax && (f = irqhandler[irq]) != nil)
			f(ur, irqarg[irq]);
		gicc[GiccEOIR] = iar;
		return;
	default:
		/*
		 * ureg0 is one shared static buffer (see l.s's vectrap
		 * comment) -- fine while a trap runs to completion before
		 * interrupts are re-admitted, but print()/panic() below can
		 * go through a Lock whose iunlock() calls splx() and
		 * re-enables IRQs.  A timer tick landing in that window
		 * calls back into trap() with the same ur, overwriting
		 * fields this fatal path hasn't printed yet -- caught by a
		 * register dump where r0/r14 (printed first) were plausible
		 * and r4/r5 (printed after some print() calls) were not.
		 * splhi() before touching anything else keeps this path's
		 * own read of ur trustworthy.
		 */
		splhi();
		print("trap type %d psr %#8.8ux pc %#8.8ux\n",
			ur->type, ur->psr, ur->pc);
		print(" r0 %#8.8ux r14 %#8.8ux\n", ur->r0, ur->r14);
		print(" r1 %#8.8ux r4 %#8.8ux r5 %#8.8ux\n", ur->r1, ur->r4, ur->r5);
		if(up != nil)
			print(" up %#p %s\n", up, up->text);
		dumpstack();
		panic("trap");
	}
}

void
intrenable(int v, int tbdf, void (*f)(Ureg*, void*), void *a, char *name)
{
	USED(tbdf, name);
	if(v <= 0 || v >= GicIRQMax)
		panic("intrenable: irq %d", v);
	irqhandler[v] = f;
	irqarg[v] = a;
	gicenable(v);
}

void
intrdisable(int v, int tbdf, void (*f)(Ureg*, void*), void *a, char *name)
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

	print("dumpstack\n");
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
			print("%.8lux\n", (ulong)v);
			if(++n >= 32)
				break;
		}
	}
}
