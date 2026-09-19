#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/pci.h"

/*
 * MSI-X through a GICv2m frame.
 *
 * On arm64 a PCI MSI is a memory write, and something has to turn that
 * write into an interrupt.  A GICv2 machine does it with an MSI frame:
 * a page whose SETSPI register takes an SPI number as its data and
 * raises that SPI.  A GICv3 machine does it with an ITS instead, which
 * translates a device id and an event id into an LPI and needs command
 * queues and two levels of table; that is not done here.  Which of the
 * two a machine has comes from the MADT -- GIC MSI frame structures,
 * type 0x0D, and GIC ITS structures, type 0x0F -- so this board asks
 * the firmware rather than guessing from the GIC version.
 *
 * Allocation is the whole of the bookkeeping: one SPI per vector out
 * of the frame's range, never reused while it is live.  There is no
 * affinity to set because the frame raises an ordinary SPI and
 * gicenable() already routes SPIs to processor 0.
 */

enum {
	V2mTyper	= 0x0008,	/* SPI base [25:16], count [9:0] */
	V2mSetspiNs	= 0x0040,	/* write an SPI number to raise it */
};

static uvlong v2mbase;
static int v2mspibase, v2mspicount;
static uchar *v2mused;			/* one byte per SPI in the range */

static int
v2malloc(void)
{
	int i;

	for(i = 0; i < v2mspicount; i++)
		if(v2mused[i] == 0){
			v2mused[i] = 1;
			return v2mspibase + i;
		}
	return -1;
}

static void
v2mfree(int spi)
{
	if(spi >= v2mspibase && spi < v2mspibase + v2mspicount)
		v2mused[spi - v2mspibase] = 0;
}

static void
msixintrenable(Pcidev *p, int vec, void (*f)(Ureg*, void*), void *a, char *name)
{
	int spi;

	if(v2mbase == 0)
		return;
	if((spi = v2malloc()) < 0){
		print("msix: %s vec %d: no spi left in the v2m frame\n", name, vec);
		return;
	}
	if(pcimsixenable(p, vec, v2mbase + V2mSetspiNs, spi) < 0){
		v2mfree(spi);
		print("msix: %s vec %d: pcimsixenable failed\n", name, vec);
		return;
	}
	gicedge(spi);			/* the frame pulses; see trap.c */
	intrenable(spi, f, a, p->tbdf, name);
	print("msix: %s tbdf %#ux vec %d -> spi %d: enabled\n",
		name, p->tbdf, vec, spi);
}

/*
 * Does a write to the frame's SETSPI register actually make an SPI
 * pending?  Interrupts are still masked here, so this cannot wait for
 * a handler to run; it reads GICD_ISPENDR instead, which is the same
 * question one step earlier and needs nothing else to be working.
 *
 * It is here because the answer was no for a while and nothing said
 * so.  A GICv2m frame raises an MSI by pulsing the SPI, and until
 * gicedge() below made the SPI edge-triggered the pulse latched
 * nothing: every vector was allocated and programmed, the driver
 * reported "msix, 2 of 65 vectors", the disk read succeeded because
 * os/inferno/port/sdnvme.c polls its completion queue on a timer, and
 * not one interrupt arrived.  Silent when it works, so a boot log that
 * says nothing here means the path was tested and is good.
 */
static void
msiselftest(void)
{
	volatile u32 *gicd;
	int spi, i, bit;

	spi = v2mspibase + v2mspicount - 1;	/* the last, and unallocated */
	gicd = (u32*)GICD;
	i = (0x200/4) + spi/32;			/* GICD_ISPENDR */
	bit = 1 << (spi%32);
	gicedge(spi);
	/*
	 * The bit has to be clear first or a pass means nothing: a test
	 * that can report success without the thing it tests having
	 * happened is not a test.  Nothing should have made an
	 * unallocated SPI pending, so if one is, say so and stop rather
	 * than read the answer off a dirty register.
	 */
	if(gicd[i] & bit){
		print("msix: spi %d was already pending before the self-test;"
			" the msi path is untested\n", spi);
		return;
	}
	*(volatile u32*)(uintptr)(v2mbase + V2mSetspiNs) = spi;
	coherence();
	if((gicd[i] & bit) == 0)
		print("msix: a write to the v2m frame did not make spi %d"
			" pending; msi will not be delivered\n", spi);
	gicd[(0x280/4) + spi/32] = bit;		/* GICD_ICPENDR: undo it */
}

/*
 * Called from acpiinit(), after the MADT has been read and before
 * pciarchinit() enumerates anything, which is the window in which
 * os/inferno/port/pci.c's pcimsixintrenable has to be set for a driver
 * to find it.
 */
void
msiinit(void)
{
	u32 t;

	if(acpinmsiframe == 0){
		/*
		 * No frame.  A GICv3 machine says so and offers an ITS
		 * instead, which itsvirtarm64.c drives; this board used to
		 * print that msi-x was unavailable and leave the network
		 * driver polling.
		 */
		if(acpinits > 0 && itsinit() == 0)
			return;
		if(acpinits > 0)
			print("msix: this machine has an ITS and it could not be"
				" set up; msi-x is not available\n");
		return;
	}
	v2mbase = acpimsiframe[0].base;
	if(acpimsiframe[0].flags & 1){
		v2mspibase = acpimsiframe[0].spibase;
		v2mspicount = acpimsiframe[0].spicount;
	}else{
		/*
		 * The MADT says its own count and base are not to be
		 * trusted, so read them out of the frame itself.
		 */
		t = *(volatile u32*)(uintptr)(v2mbase + V2mTyper);
		v2mspibase = (t >> 16) & 0x3FF;
		v2mspicount = t & 0x3FF;
	}
	if(v2mspicount <= 0 || v2mspibase < GicSpiBase
	|| v2mspibase + v2mspicount > GicIRQMax){
		print("msix: v2m frame at %#llux spi %d..%d is outside"
			" this board's %d..%d; not used\n",
			v2mbase, v2mspibase, v2mspibase + v2mspicount - 1,
			GicSpiBase, GicIRQMax - 1);
		v2mbase = 0;
		return;
	}
	if((v2mused = malloc(v2mspicount)) == nil){
		v2mbase = 0;
		return;
	}
	pcimsixintrenable = msixintrenable;
	print("msix: v2m frame at %#llux, spi %d..%d, %d vectors\n",
		v2mbase, v2mspibase, v2mspibase + v2mspicount - 1, v2mspicount);
	msiselftest();
}
