#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"

enum {
	IrqTimer	= 7,	/* machine timer */
	IrqExternal	= 11,	/* machine external (PLIC) */
};

/* QEMU virt PLIC: UART=10, virtio-mmio=1..8, PCI INTx from 32 */

/*
 * The PLIC's base address.  It defaults to the compiled-in constant
 * (correct for QEMU virt) but main() overrides it from the device tree
 * before trapinit() runs, so the same kernel finds the PLIC on silicon
 * whose map differs.  If the DTB lookup fails, the constant stands and
 * the board behaves exactly as before - the wiring can never hang a
 * working board.
 */
uintptr	plicbase = PLIC;

/*
 * The base of the first virtio-mmio slot; the drivers scan VIRTIO_NDEV
 * slots upward from here.  Seeded from the DTB in main() (the lowest
 * virtio,mmio node), constant default otherwise - same rule as
 * plicbase: a DTB miss cannot hang a working board.
 */
uintptr	virtiobase = VIRTIO0;
static void	(*irqhandler[96])(Ureg*, void*);
static void	*irqarg[96];

extern char	etext[];

static u32*
plicctx(void)
{
	return (u32*)(plicbase + PlicContext);	/* hart0 M-mode = context 0 */
}

static void
plicenable(int irq)
{
	u32 *en;

	if(irq <= 0)
		return;
	*(u32*)(plicbase + PlicPriority + 4*irq) = 1;
	en = (u32*)(plicbase + PlicEnable);
	en[irq/32] |= 1 << (irq%32);
}

void
plicinit(void)
{
	/*
	 * QEMU's shakti_c maps the sifive PLIC in only a 0x20000-byte
	 * aperture (0x0c000000..0x0c01ffff), so the SiFive context region
	 * the virt board uses at PLIC+0x200000 - threshold and claim - is
	 * off the end and a write there takes a store access fault.  Until
	 * this board's compressed context offset is pinned, leave the PLIC
	 * alone: mie.MEIE stays clear so no external interrupt is delivered
	 * to the hart, the machine timer (CLINT) drives the scheduler, and
	 * console input is polled through clockpoll().  plicenable() and
	 * the claim path (both still compiled, called from intrenable and
	 * trap) are simply never reached because MEIE is off.
	 */
}

void
trapinit(void)
{
	vectorinit();
	plicinit();
}

void
trap(Ureg *ur)
{
	uintptr cause, code;
	u32 irq;
	void (*f)(Ureg*, void*);

	cause = ur->cause;
	if((vlong)cause < 0){
		code = cause & ~((uintptr)1 << 63);
		switch((int)code){
		case IrqTimer:
			clockintr(ur);
			return;
		case IrqExternal:
			irq = plicctx()[PlicClaim/4];
			if(irq == 0)
				return;
			if(irq < nelem(irqhandler) && (f = irqhandler[irq]) != nil)
				f(ur, irqarg[irq]);
			plicctx()[PlicClaim/4] = irq;	/* complete */
			return;
		default:
			print("interrupt cause ");
			print("%#p\n", cause);
			panic("interrupt");
		}
	}
	/* KenC LP64: one arg per print */
	print("exception cause ");
	print("%#p", cause);
	print(" epc ");
	print("%#p", ur->pc);
	print(" tval ");
	print("%#p\n", ur->tval);
	print("  ra ");
	print("%#p", ur->r1);
	print(" sp ");
	print("%#p", ur->sp);
	print(" status ");
	print("%#p\n", ur->status);
	if(up != nil){
		print("  up ");
		print("%#p ", up);
		print("%s\n", up->text);
	}
	dumpstack();
	panic("exception");
}

void
intrenable(int v, void (*f)(Ureg*, void*), void *a, int tbdf, char *name)
{
	USED(tbdf, name);
	if(v <= 0 || v >= nelem(irqhandler))
		panic("intrenable: irq %d", v);
	irqhandler[v] = f;
	irqarg[v] = a;
	plicenable(v);
}

void
intrdisable(int v, void (*f)(Ureg*, void*), void *a, int tbdf, char *name)
{
	USED(tbdf, f, a, name);
	if(v > 0 && v < nelem(irqhandler)){
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
