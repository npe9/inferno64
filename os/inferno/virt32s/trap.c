#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"

enum {
	IrqTimer	= 5,	/* supervisor timer (scause code 5) */
	IrqExternal	= 9,	/* supervisor external / PLIC (scause code 9) */
};

/* QEMU virt PLIC: UART=10, virtio-mmio=1..8, PCI INTx from 32 */

/*
 * PLIC base, defaulting to the constant but overridden from the device
 * tree in main() before trapinit().  A DTB miss leaves the constant, so
 * it cannot hang a working board.
 */
uintptr	plicbase = PLIC;

/*
 * First virtio-mmio slot, likewise: the constant is the default and the
 * DTB overrides it.  ethervirtiommio.c scans up from here.
 */
uintptr	virtiobase = VIRTIO0;
static void	(*irqhandler[96])(Ureg*, void*);
static void	*irqarg[96];

extern char	etext[];

static u32*
plicctx(void)
{
	/* hart0 S-mode is PLIC context 1 (context 0 is hart0 M-mode) */
	return (u32*)(plicbase + PlicContext + 1*0x1000);
}

static void
plicenable(int irq)
{
	u32 *en;

	if(irq <= 0)
		return;
	*(u32*)(plicbase + PlicPriority + 4*irq) = 1;
	en = (u32*)(plicbase + PlicEnable + 1*0x80);	/* context 1 enable bits */
	en[irq/32] |= 1 << (irq%32);
}

void
plicinit(void)
{
	plicctx()[PlicThresh/4] = 0;
	plicenable(Uart0IRQ);
	mextie();
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
	/*
	 * virt/trap.c tests (vlong)cause<0 to read mcause's interrupt bit,
	 * the top bit of XLEN -- bit 63 there.  uintptr is 32 bit here, so
	 * that cast zero-extends and the sign test can never fire; test
	 * bit 31 (this board's actual top bit) directly instead.
	 */
	if((cause & ((uintptr)1 << 31)) != 0){
		code = cause & ~((uintptr)1 << 31);
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
