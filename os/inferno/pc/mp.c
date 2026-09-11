#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/pci.h"
#include "ureg.h"

#include "mp.h"
#include "apbootstrap.i"

#define DP if(1){}else print
extern void i8259init(void);

/* filled in by pcmpinit or acpiinit */
Bus* mpbus;
Bus* mpbuslast;
int mpisabus = -1;
int mpeisabus = -1;
Apic *mpioapic[MaxAPICNO+1];
Apic *mpapic[MaxAPICNO+1];

int
mpintrinit(Bus* bus, PCMPintr* intr, int vno, int /*irq*/)
{
	int el, po, v;

	/*
	 * Parse an I/O or Local APIC interrupt table entry and
	 * return the encoded vector.
	 */
	v = vno;

	po = intr->flags & PcmpPOMASK;
	el = intr->flags & PcmpELMASK;

	switch(intr->intr){
	default:				/* PcmpINT */
		v |= ApicFIXED;			/* no-op */
		break;

	case PcmpNMI:
		v |= ApicNMI;
		po = PcmpHIGH;
		el = PcmpEDGE;
		break;

	case PcmpSMI:
		v |= ApicSMI;
		break;

	case PcmpExtINT:
		v |= ApicExtINT;
		/*
		 * The AMI Goliath doesn't boot successfully with it's LINTR0
		 * entry which decodes to low+level. The PPro manual says ExtINT
		 * should be level, whereas the Pentium is edge. Setting the
		 * Goliath to edge+high seems to cure the problem. Other PPro
		 * MP tables (e.g. ASUS P/I-P65UP5 have a entry which decodes
		 * to edge+high, so who knows.
		 * Perhaps it would be best just to not set an ExtINT entry at
		 * all, it shouldn't be needed for SMP mode.
		 */
		po = PcmpHIGH;
		el = PcmpEDGE;
		break;
	}

	/*
	 */
	if(bus->type == BusEISA && !po && !el /*&& !(i8259elcr & (1<<irq))*/){
		po = PcmpHIGH;
		el = PcmpEDGE;
	}
	if(!po)
		po = bus->po;
	if(po == PcmpLOW)
		v |= ApicLOW;
	else if(po != PcmpHIGH){
		print("mpintrinit: bad polarity 0x%uX\n", po);
		return ApicIMASK;
	}

	if(!el)
		el = bus->el;
	if(el == PcmpLEVEL)
		v |= ApicLEVEL;
	else if(el != PcmpEDGE){
		print("mpintrinit: bad trigger 0x%uX\n", el);
		return ApicIMASK;
	}

	return v;
}

uvlong
tscticks(uvlong *hz)
{
	if(hz != nil)
		*hz = m->cpuhz;

	cycles(&m->tscticks);	/* Uses the rdtsc instruction */
	return m->tscticks;
}

void
syncclock(void)
{
	uvlong x;

	if(arch->fastclock != tscticks)
		return;

	if(m->machno == 0){
		wrmsr(0x10, 0);
		m->tscticks = 0;
	} else {
		x = MACHP(0)->tscticks;
		while(x == MACHP(0)->tscticks)
			;
		wrmsr(0x10, MACHP(0)->tscticks);
		cycles(&m->tscticks);
	}
}

static void
showglobalconfig(void)
{
	u64 flags;
	u32 iopl;
	uintptr apic_base;

	print("APIC global configuration\n");
	flags = rflags();
	print("	RFLAGS: 0x%zux, ", flags);
	if(flags & 0x200)
		print("maskable interrupts enabled, ");
	else
		print("maskable interrupts disabled, ");
	iopl = flags & (0x11 << 12);
	print("iopl 0x%x", iopl);
	print("\n");

	rdmsr(0x1B, (s64*)&apic_base);
	print("	APIC_BASE: 0x%zux, ", apic_base);
	if(apic_base & 0x100)
		print("BSP, ");
	else
		print("not BSP, ");
	if(apic_base & 0x400)
		print("enable x2APIC mode, ");
	else
		print("disable x2APIC mode, ");
	if(apic_base & 0x800)
		print("APIC global enable");
	else
		print("APIC global disable");
	print("\n");
}

static int pcmsixrouter(Pcidev *p, uvlong *addr, ulong *data);

void
mpinit(void)
{
	int ncpu, i;
	Apic *apic;
	char *cp;

	/* showglobalconfig(); */
	i8259init();
	syncclock();

	/*
	 * Installed here rather than at pcicfginit() time because the
	 * vectors it hands out are LAPIC vectors: a machine that came
	 * up on archgeneric has no allocvector() pool to draw them
	 * from, and leaving the pointer nil there is exactly right --
	 * pcimsixintr() then returns -1 and every driver falls back to
	 * the pin, which is what those machines did before this.
	 */
	pcimsirouter = pcmsixrouter;
	DP("mpinit after syncclock getconf(*apicdebug) %s\n", getconf("*apicdebug"));

	if(getconf("*apicdebug")){
		Bus *b;
		Aintr *ai;
		PCMPintr *pi;

		for(i=0; i<=MaxAPICNO; i++){
			if(apic = mpapic[i])
				print("LAPIC%d: pa=%lux va=%#p flags=%x\n",
					i, apic->paddr, apic->addr, apic->flags);
			if(apic = mpioapic[i])
				print("IOAPIC%d: pa=%lux va=%#p flags=%x gsibase=%d mre=%d\n",
					i, apic->paddr, apic->addr, apic->flags, apic->gsibase, apic->mre);
		}
		for(b = mpbus; b; b = b->next){
			print("BUS%d type=%d flags=%x\n", b->busno, b->type, b->po|b->el);
			for(ai = b->aintr; ai; ai = ai->next){
				if(pi = ai->intr)
					print("\ttype=%d irq=%d (%d [%c]) apic=%d intin=%d flags=%x\n",
						pi->type, pi->irq, pi->irq>>2, "ABCD"[pi->irq&3],
						pi->apicno, pi->intin, pi->flags);
			}
		}
	}

	apic = nil;
	for(i=0; i<=MaxAPICNO; i++){
		if(mpapic[i] == nil)
			continue;
		if(mpapic[i]->flags & PcmpBP){
			apic = mpapic[i];
			break;
		}
	}

	if(apic == nil){
		panic("mpinit: no bootstrap processor");
		return;
	}
	apic->online = 1;

	lapicinit(apic);
	/* lapicerror(nil,nil); */

	/*
	 * These interrupts are local to the processor
	 * and do not appear in the I/O APIC so it is OK
	 * to set them now.
	 */
	intrenable(IrqTIMER, lapicclock, 0, BUSUNKNOWN, "clock");
	intrenable(IrqERROR, lapicerror, 0, BUSUNKNOWN, "lapicerror");
	intrenable(IrqSPURIOUS, lapicspurious, 0, BUSUNKNOWN, "lapicspurious");
	lapiconline();
	/* lapicerror(nil,nil); */

	/*
	 * Initialise the application processors.
	 */
	if(cp = getconf("*ncpu")){
		ncpu = strtol(cp, 0, 0);
		if(ncpu < 1)
			ncpu = 1;
		else if(ncpu > MAXMACH)
			ncpu = MAXMACH;
	}
	else
		ncpu = MAXMACH;
	if(sizeof(apbootstrap) > 4*KiB)
		print("mpinit: sizeof(apbootstrap) 0x%x > 4*KiB -- fix it\n", sizeof(apbootstrap));
	memmove((void*)APBOOTSTRAP, apbootstrap, sizeof(apbootstrap));
	/*
	for(i=0;i<sizeof(apbootstrap);i++){
		DP(" %x", *((uchar*)APBOOTSTRAP+i));
	}
	DP("\n");
	*/
	for(i=0; i<nelem(mpapic); i++){
		if((apic = mpapic[i]) == nil)
			continue;
		if(apic->machno >= MAXMACH)
			continue;
		if(ncpu <= 1)
			break;
		if((apic->flags & (PcmpBP|PcmpEN)) == PcmpEN){
			mpstartap(apic);
			conf.nmach++;
			ncpu--;
		}
	}

	/*
	 *  we don't really know the number of processors till
	 *  here.
	 *
	 *  set conf.copymode here if nmach > 1.
	 *  Should look for an ExtINT line and enable it.
	 */
	if(m->cpuidfamily == 3 || conf.nmach > 1)
		conf.copymode = 1;
}

static int
mpintrcpu(void)
{
	static Lock physidlock;
	static int physid;
	int i;

	/*
	 * The bulk of this code was written ~1995, when there was
	 * one architecture and one generation of hardware, the number
	 * of CPUs was up to 4(8) and the choices for interrupt routing
	 * were physical, or flat logical (optionally with lowest
	 * priority interrupt). Logical mode hasn't scaled well with
	 * the increasing number of packages/cores/threads, so the
	 * fall-back is to physical mode, which works across all processor
	 * generations, both AMD and Intel, using the APIC and xAPIC.
	 *
	 * Interrupt routing policy can be set here.
	 * Currently, just assign each interrupt to a different CPU on
	 * a round-robin basis. Some idea of the packages/cores/thread
	 * topology would be useful here, e.g. to not assign interrupts
	 * to more than one thread in a core, or to use a "noise" core.
	 * But, as usual, Intel make that an onerous task. 
	 */
	lock(&physidlock);
	for(;;){
		i = physid++;
		if(physid >= nelem(mpapic))
			physid = 0;
		if(mpapic[i] == nil)
			continue;
		if(mpapic[i]->online)
			break;
	}
	unlock(&physidlock);

	return mpapic[i]->apicno;
}

/*
 * With the APIC a unique vector can be assigned to each
 * request to enable an interrupt. There are two reasons this
 * is a good idea:
 * 1) to prevent lost interrupts, no more than 2 interrupts
 *    should be assigned per block of 16 vectors (there is an
 *    in-service entry and a holding entry for each priority
 *    level and there is one priority level per block of 16
 *    interrupts).
 * 2) each input pin on the IOAPIC will receive a different
 *    vector regardless of whether the devices on that pin use
 *    the same IRQ as devices on another pin.
 */
static int
allocvector(void)
{
	static int round = 0, num = 0;
	static Lock l;
	int vno;
	
	lock(&l);
	vno = VectorAPIC + num;
	if(vno < MaxVectorAPIC-7)
		num += 8;
	else
		num = ++round % 8;
	unlock(&l);
	return vno;
}

static int
ioapicirqenable(Vctl *v, int shared)
{
	Aintr *aintr = v->aux;
	int lo, hi;

	if(shared)
		return 0;
	hi = v->cpu<<24;
	lo = mpintrinit(aintr->bus, aintr->intr, v->vno, v->irq);
	lo |= ApicPHYSICAL;			/* no-op */
 	ioapicrdtw(aintr->apic, aintr->intr->intin, hi, lo);
	return 0;
}

static int
ioapicirqdisable(Vctl *v, int shared)
{
	Aintr *aintr = v->aux;
	int lo, hi;

	if(shared)
		return 0;
	hi = 0;
	lo = ApicIMASK;
 	ioapicrdtw(aintr->apic, aintr->intr->intin, hi, lo);
	return 0;
}

static int
mpintrassignx(Vctl* v, int tbdf)
{
	Bus *bus;
	Pcidev *pci;
	Aintr *aintr;
	int bno, dno, pin, irq, type, lo, hi, n;

	type = BUSTYPE(tbdf);
	bno = BUSBNO(tbdf);
	dno = BUSDNO(tbdf);

	pin = 0;
	pci = nil;
	if(type == BusPCI){
		if((pci = pcimatchtbdf(tbdf)) != nil)
			pin = pcicfgr8(pci, PciINTP);
	} else if(type == BusISA)
		bno = mpisabus;

Findbus:
	for(bus = mpbus; bus != nil; bus = bus->next){
		if(bus->type != type)
			continue;
		if(bus->busno == bno)
			break;
	}

	if(bus == nil){
		/*
		 * if the PCI device is behind a bridge thats not described
		 * by the MP or ACPI tables then walk up the bus translating
		 * interrupt pin to parent bus.
		 */
		if(pci != nil && pci->parent != nil && pin > 0){
			pci = pci->parent;
			if(pci->ccrb == 6 && pci->ccru == 7){
				/* Cardbus bridge, use controllers interrupt pin */
				pin = pcicfgr8(pci, PciINTP);
			} else {
				/* PCI-PCI bridge */
				pin = ((dno+(pin-1))%4)+1;
			}
			bno = BUSBNO(pci->tbdf);
			dno = BUSDNO(pci->tbdf);
			goto Findbus;
		}
		print("mpintrassign: can't find bus type %d, number %d\n", type, bno);
		return -1;
	}

	/*
	 * For PCI devices the interrupt pin (INT[ABCD]) and device
	 * number are encoded into the entry irq field, so create something
	 * to match on.
	 */
	if(bus->type == BusPCI){
		if(pin > 0)
			irq = (dno<<2)|(pin-1);
		else
			irq = -1;
	} else
		irq = v->irq;

	/*
	 * Find a matching interrupt entry from the list of interrupts
	 * attached to this bus.
	 */
	for(aintr = bus->aintr; aintr != nil; aintr = aintr->next){
		if(aintr->intr->irq != irq)
			continue;

		/*
		 * Check if already enabled. Multifunction devices may share
		 * INT[A-D]# so, if already enabled, check the polarity matches
		 * and the trigger is level.
		 */
		ioapicrdtr(aintr->apic, aintr->intr->intin, &hi, &lo);
		if(lo & ApicIMASK){
			v->vno = allocvector();
			v->cpu = mpintrcpu();
			lo = mpintrinit(aintr->bus, aintr->intr, v->vno, v->irq);
			lo |= ApicPHYSICAL;			/* no-op */
			if(lo & ApicIMASK){
				print("mpintrassign: disabled irq %d, tbdf %uX, lo %8.8uX, hi %8.8uX\n",
					v->irq, v->tbdf, lo, hi);
				break;
			}
		} else {
			v->vno = lo & 0xFF;
			v->cpu = hi >> 24;
			lo &= ~(ApicRemoteIRR|ApicDELIVS);
			n = mpintrinit(aintr->bus, aintr->intr, v->vno, v->irq);
			n |= ApicPHYSICAL;			/* no-op */
			if(lo != n){
				print("mpintrassign: multiple botch irq %d, tbdf %uX, lo %8.8uX, n %8.8uX\n",
					v->irq, v->tbdf, lo, n);
				break;
			}
		}

		v->isr = lapicisr;
		v->eoi = lapiceoi;

		if((aintr->apic->flags & PcmpEN) && aintr->apic->type == PcmpIOAPIC){
			v->aux = aintr;
			v->enable = ioapicirqenable;
			v->disable = ioapicirqdisable;
		}

		return v->vno;
	}

	return -1;
}

enum {
	HTMSIMapping	= 0xA8,
	HTMSIFlags	= 0x02,
	HTMSIFlagsEn	= 0x01,
};

static int
htmsicapenable(Pcidev *p)
{
	int cap, flags;

	if((cap = pcihtcap(p, HTMSIMapping)) <= 0)
		return -1;
	flags = pcicfgr8(p, cap + HTMSIFlags);
	if((flags & HTMSIFlagsEn) == 0)
		pcicfgw8(p, cap + HTMSIFlags, flags | HTMSIFlagsEn);
	return 0;
}

static int
htmsienable(Pcidev *pdev)
{
	Pcidev *p;

	p = nil;
	while((p = pcimatch(p, 0x1022, 0)) != nil)
		if(p->did == 0x1103 || p->did == 0x1203)
			break;

	if(p == nil)
		return 0;	/* not hypertransport platform */

	p = nil;
	while((p = pcimatch(p, 0x10de, 0)) != nil){
		switch(p->did){
		case 0x02f0:	/* NVIDIA NFORCE C51 MEMC0 */
		case 0x02f1:	/* NVIDIA NFORCE C51 MEMC1 */
		case 0x02f2:	/* NVIDIA NFORCE C51 MEMC2 */
		case 0x02f3:	/* NVIDIA NFORCE C51 MEMC3 */
		case 0x02f4:	/* NVIDIA NFORCE C51 MEMC4 */
		case 0x02f5:	/* NVIDIA NFORCE C51 MEMC5 */
		case 0x02f6:	/* NVIDIA NFORCE C51 MEMC6 */
		case 0x02f7:	/* NVIDIA NFORCE C51 MEMC7 */
		case 0x0369:	/* NVIDIA NFORCE MCP55 MEMC */
			htmsicapenable(p);
			break;
		}
	}

	if(htmsicapenable(pdev) == 0)
		return 0;

	for(p = pdev->parent; p != nil; p = p->parent)
		if(htmsicapenable(p) == 0)
			return 0;

	return -1;
}

static int
msiirqenable(Vctl *v, int)
{
	Pcidev *pci = v->aux;
	return pcimsienable(pci, 0xFEE00000ULL | (v->cpu << 12), v->vno | (1<<14));
}

static int
msiirqdisable(Vctl *v, int)
{
	Pcidev *pci = v->aux;
	return pcimsidisable(pci);
}

/*
 * The board's MSI-X router, in the sense port/pci.c means it: hand
 * back the address and data a device must write to raise an
 * interrupt, and the number that write will arrive as.
 *
 * On a GIC board (os/inferno/virtarm64/gicv2m.c, the only other one)
 * the number is an SPI, which is already something intrenable()
 * understands.  Here it is a LAPIC vector out of allocvector(), which
 * is not an IOAPIC pin and which mpintrassign() below has to be
 * taught to recognise; that is the whole of the x86 difference.  The
 * message itself is the one msiintrenable() sends -- the 0xFEE00000
 * window with the destination CPU in bits 19:12, the vector in the
 * low byte of the data word and the assert bit above it.  Only where
 * the device keeps that address and data differs: MSI puts them in
 * config space, MSI-X in a table inside one of its BARs, which is why
 * pcimsixenable() lives in the portable file and this does not.
 *
 * Why a router and not a hook inside intrenable(), which is where MSI
 * sits four functions down.  Enabling MSI-X on a function changes how
 * that function delivers interrupts, and for several device classes
 * the driver has to say where: a virtio 1.0 device leaves every queue
 * at VIRTIO_MSI_NO_VECTOR until the driver writes queue_msix_vector,
 * and an e1000e leaves its IVAR registers unmapped.  Turning the
 * capability on behind such a driver's back does not upgrade it, it
 * silences it.  That was measured, not reasoned: an earlier version
 * of this change did enable MSI-X for every PCI function inside
 * mpintrassign(), and on the same pc64dev boot the virtio disk
 * stopped reporting interrupts entirely (it polls its used ring, so
 * it still read sector 0 and said nothing) and DHCP over the i82574
 * failed outright.
 *
 * pcimsixintr() is the driver's own request, so a router is opt-in by
 * construction: only sdnvme, sdvirtio10 and usbxhcipci call it, and
 * those three are exactly the drivers written to program whatever
 * their device needs beyond the table entry.  Nothing else on the
 * board changes, and the i82574 and the ICH keep the plain MSI they
 * already had.
 */
static int
pcmsixrouter(Pcidev *p, uvlong *addr, ulong *data)
{
	int vno, cpu;

	USED(p);
	/*
	 * *nomsi turns off message-signalled interrupts, and MSI-X is
	 * one however separately the two capabilities are named;
	 * *nomsix turns off this half alone.  Returning -1 here rather
	 * than refusing later is what makes the fallback clean:
	 * pcimsixintr() reports -1 to the driver, the driver uses
	 * p->intl, and the board is on the pin it would have used if
	 * this function did not exist.
	 */
	if(getconf("*nomsi") != nil || getconf("*nomsix") != nil)
		return -1;

	vno = allocvector();
	cpu = mpintrcpu();
	if(vno < VectorPIC || cpu < 0)
		return -1;
	*addr = 0xFEE00000ULL | (cpu << 12);
	*data = vno | (1<<14);
	return vno;
}

static int
msiintrenable(Vctl *v)
{
	Pcidev *pci;
	int tbdf;

	if(getconf("*nomsi") != nil)
		return -1;

	tbdf = v->tbdf;
	if(tbdf == BUSUNKNOWN || BUSTYPE(tbdf) != BusPCI)
		return -1;
	pci = pcimatchtbdf(tbdf);
	if(pci == nil) {
		print("msiintrenable: could not find Pcidev for tbdf %uX\n", tbdf);
		return -1;
	}
	if(htmsienable(pci) < 0)
		return -1;
	if(pcimsidisable(pci) < 0)
		return -1;

	v->vno = allocvector();
	v->cpu = mpintrcpu();
	v->isr = lapicisr;
	v->eoi = lapiceoi;

	v->aux = pci;
	v->enable = msiirqenable;
	v->disable = msiirqdisable;

	return v->vno;
}

int
mpintrassign(Vctl* v)
{
	int irq, tbdf, vno;
	Pcidev *pcidev;

	/*
	 * A vector pcmsixrouter() already allocated and pcimsixintr()
	 * already wrote into this function's MSI-X table.  It arrives
	 * here as v->irq because that is what the driver was told to
	 * hand intrenable(), and it is not a pin: no bus lookup can
	 * find it and MaxIrqPIC is far below it.  pcimsixintr() records
	 * it on the Pcidev, so this needs no table of its own -- and
	 * the same record is what makes a driver that disables and
	 * re-enables its unit get the same vector back rather than
	 * spend a new one each cycle.
	 *
	 * No v->enable: the table entry is written already, and
	 * irq.c's intrenable() skips a nil one.  isr and eoi are the
	 * LAPIC's, the same two msiintrenable() installs, because an
	 * MSI-X message is acknowledged at the local APIC like any
	 * other message-signalled interrupt.
	 */
	if(BUSTYPE(v->tbdf) == BusPCI && (pcidev = pcimatchtbdf(v->tbdf)) != nil
	&& pcidev->msixirq > 0 && pcidev->msixirq == v->irq){
		v->isr = lapicisr;
		v->eoi = lapiceoi;
		return v->irq;
	}

	vno = msiintrenable(v);
	if(vno != -1)
		return vno;

	/*
	 * If the bus is known, try it.
	 * BUSUNKNOWN is given both by [E]ISA devices and by
	 * interrupts local to the processor (local APIC, coprocessor
	 * breakpoint and page-fault).
	 */
	tbdf = v->tbdf;
	if(tbdf != BUSUNKNOWN && (vno = mpintrassignx(v, tbdf)) != -1)
		return vno;

	irq = v->irq;
	if(irq >= IrqLINT0 && irq <= MaxIrqLAPIC){
		v->local = 1;
		if(irq != IrqSPURIOUS)
			v->isr = lapiceoi;
		return VectorPIC+irq;
	}
	if(irq < 0 || irq > MaxIrqPIC){
		print("mpintrassign: irq %d out of range\n", irq);
		return -1;
	}

	/*
	 * Either didn't find it or have to try the default buses
	 * (ISA and EISA). This hack is due to either over-zealousness 
	 * or laziness on the part of some manufacturers.
	 *
	 * The MP configuration table on some older systems
	 * (e.g. ASUS PCI/E-P54NP4) has an entry for the EISA bus
	 * but none for ISA. It also has the interrupt type and
	 * polarity set to 'default for this bus' which wouldn't
	 * be compatible with ISA.
	 */
	if(mpeisabus != -1){
		vno = mpintrassignx(v, MKBUS(BusEISA, 0, 0, 0));
		if(vno != -1)
			return vno;
	}
	if(mpisabus != -1){
		vno = mpintrassignx(v, MKBUS(BusISA, 0, 0, 0));
		if(vno != -1)
			return vno;
	}
	print("mpintrassign: out of choices eisa %d isa %d tbdf %uX irq %d\n",
		mpeisabus, mpisabus, v->tbdf, v->irq);
	return -1;
}

void
mpshutdown(void)
{
	/*
	 * Park application processors.
	 */
	if(m->machno != 0){
		splhi();
		arch->introff();
		for(;;) idle();
	}
	delay(1000);
	splhi();

	/*
	 * INIT all excluding self.
	 */
	lapicicrw(0, 0x000C0000|ApicINIT);

	pcireset();
}
