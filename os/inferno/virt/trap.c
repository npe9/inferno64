#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/pci.h"

enum {
	IrqSoft		= 3,	/* machine software: CLINT msip, another hart's poke */
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

/*
 * Interrupt identities: a wired source's number, below Nsource (the
 * PLIC's sources, or the APLIC's, which in MSI mode sends each as the
 * identity of its number); and, with an IMSIC, MSI-X vectors from
 * Msifirst, each a message a device writes to the IMSIC's page.
 */
enum {
	Nsource		= 96,
	Msifirst	= 128,
	Nid		= 256,
};
static void	(*irqhandler[Nid])(Ureg*, void*);
static void	*irqarg[Nid];
static struct {
	Pcidev	*p;	/* nil when free */
	int	vec;
} msivec[Nid];

extern char	etext[];

/*
 * The Advanced Interrupt Architecture, where the machine has it
 * instead of a PLIC (main sets these from the device tree): the root
 * APLIC domain in MSI mode turns each wired source into a message to
 * this hart's machine-level IMSIC, identity = source number, and an
 * external interrupt is claimed from the IMSIC through mtopei.
 */
uintptr	imsicbase;
uintptr	aplicbase;
uintptr	guestimsic;	/* the supervisor-level IMSIC, whose guest files guests get (vmplat.c) */
int	guestbits;	/* riscv,guest-index-bits: (1<<guestbits)-1 guest files */

enum {
	Aplicdomaincfg	= 0x0000,
	Aplicsourcecfg	= 0x0004,	/* +4*(source-1) */
	Aplicmmsiaddr	= 0x1BC0,
	Aplicmmsiaddrh	= 0x1BC4,
	Aplicsetipnum	= 0x1CDC,
	Aplicinclrip	= 0x1D00,	/* +4*(source/32): reads the rectified inputs */
	Aplicsetienum	= 0x1EDC,
	Aplictarget	= 0x3004,	/* +4*(source-1) */

	DomIE		= 1<<8,
	DomDM		= 1<<2,		/* MSI delivery */
	SrcLevelHigh	= 6,

	/* IMSIC registers, by miselect */
	Eidelivery	= 0x70,
	Eithreshold	= 0x72,
	Eie0		= 0xC0,		/* 64 identities a register on RV64, even numbers only */
};

extern void	csrwrmiselect(uvlong);
extern uvlong	csrrdmireg(void);
extern void	csrwrmireg(uvlong);
extern uvlong	csrclaimmtopei(void);

#define	APLIC(r)	(*(u32*)(aplicbase + (r)))

static void
imsicwr(int reg, uvlong v)
{
	csrwrmiselect(reg);
	csrwrmireg(v);
}

static uvlong
imsicrd(int reg)
{
	csrwrmiselect(reg);
	return csrrdmireg();
}

static void
aiainit(void)
{
	APLIC(Aplicdomaincfg) = DomDM;	/* off while it is set up */
	APLIC(Aplicmmsiaddr) = imsicbase >> 12;
	APLIC(Aplicmmsiaddrh) = 0;
	imsicwr(Eithreshold, 0);
	imsicwr(Eidelivery, 1);
	APLIC(Aplicdomaincfg) = DomIE | DomDM;
}

static void
imsicenable(int id, int on)
{
	int r;

	r = Eie0 + 2*(id/64);
	if(on)
		imsicwr(r, imsicrd(r) | 1ULL<<(id%64));
	else
		imsicwr(r, imsicrd(r) & ~(1ULL<<(id%64)));
}

static void
aiaenable(int irq)
{
	APLIC(Aplicsourcecfg + 4*(irq-1)) = SrcLevelHigh;
	APLIC(Aplictarget + 4*(irq-1)) = irq;	/* hart 0, guest 0, identity irq */
	imsicenable(irq, 1);
	APLIC(Aplicsetienum) = irq;
}

/*
 * MSI-X (port/pci.h's pcimsixintrenable): a vector of the device's
 * is an identity of the IMSIC's own, which the device's message, to
 * the IMSIC's page, makes pending.  The message is a DMA write: behind
 * an IOMMU the page must be reachable through the device's domain
 * (rviommu.c maps it into every domain).
 */
static void
msixintrenable(Pcidev *p, int vec, void (*f)(Ureg*, void*), void *a, char *name)
{
	int id, s;

	s = splhi();
	for(id = Msifirst; id < Nid; id++)
		if(msivec[id].p == nil)
			break;
	if(id == Nid){
		splx(s);
		print("msix: %s vec %d: no IMSIC identity left\n", name, vec);
		return;
	}
	msivec[id].p = p;
	msivec[id].vec = vec;
	irqhandler[id] = f;
	irqarg[id] = a;
	imsicenable(id, 1);
	splx(s);
	if(pcimsixenable(p, vec, imsicbase, id) < 0){
		s = splhi();
		imsicenable(id, 0);
		irqhandler[id] = nil;
		msivec[id].p = nil;
		splx(s);
		print("msix: %s vec %d: pcimsixenable failed\n", name, vec);
	}
}

static void
msixintrdisable(Pcidev *p, int vec, void (*)(Ureg*, void*), void*, char*)
{
	int id, s;

	for(id = Msifirst; id < Nid; id++)
		if(msivec[id].p == p && msivec[id].vec == vec)
			break;
	if(id == Nid)
		return;
	pcimsixmask(p, vec, 1);
	s = splhi();
	imsicenable(id, 0);
	irqhandler[id] = nil;
	irqarg[id] = nil;
	msivec[id].p = nil;
	splx(s);
}

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
	if(imsicbase != 0){
		aiaenable(irq);
		return;
	}
	*(u32*)(plicbase + PlicPriority + 4*irq) = 1;
	en = (u32*)(plicbase + PlicEnable);
	en[irq/32] |= 1 << (irq%32);
}

void
plicinit(void)
{
	if(imsicbase != 0){
		aiainit();
		pcimsixintrenable = msixintrenable;
		pcimsixintrdisable = msixintrdisable;
		plicenable(Uart0IRQ);
		mextie();
		return;
	}
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
	if((vlong)cause < 0){
		code = cause & ~((uintptr)1 << 63);
		switch((int)code){
		case IrqTimer:
			clockintr(ur);
			return;
		case IrqSoft:
			*(volatile u32int*)(CLINT + ClintMsip + 4*m->machno) = 0;
			return;
		case IrqExternal:
			if(imsicbase != 0){
				/* claimed by reading and clearing mtopei: identity in 26:16 */
				while((irq = csrclaimmtopei() >> 16) != 0){
					if(irq < nelem(irqhandler) && (f = irqhandler[irq]) != nil)
						f(ur, irqarg[irq]);
					/*
					 * In MSI mode a level source is pending
					 * again only when it rises: one still up
					 * after its handler -- more came while it
					 * ran -- is sent again, as Linux does at
					 * EOI, or it is lost.
					 */
					if(irq < Nsource && (APLIC(Aplicinclrip + 4*(irq/32)) & 1<<(irq%32)))
						APLIC(Aplicsetipnum) = irq;
				}
				return;
			}
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
	if(v <= 0 || v >= Nsource)
		panic("intrenable: irq %d", v);
	irqhandler[v] = f;
	irqarg[v] = a;
	plicenable(v);
}

void
intrdisable(int v, void (*f)(Ureg*, void*), void *a, int tbdf, char *name)
{
	USED(tbdf, f, a, name);
	if(v > 0 && v < Nsource){
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
