#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/pci.h"

/*
 * GICv2m: message-signalled interrupts on a GICv2, which has no ITS.
 *
 * A GICv2 distributor cannot be written by a device -- its enable and
 * pending registers are not a doorbell -- so an SBSA GICv2m frame sits
 * beside it and translates one memory write into one SPI.  A device
 * writes the SPI number as a 32-bit datum to the frame's
 * MSI_SETSPI_NS register and the frame raises that SPI at the
 * distributor.  That is the whole mechanism: no command queue, no
 * device table, no interrupt-translation-table memory to allocate, and
 * nothing to program per device.  It is the reason this board can have
 * MSI at all without first moving to GICv3.
 *
 * The frame is discovered, not assumed.  QEMU's -M virt puts it at
 * 0x08020000 with sixty-four SPIs starting at 80, but it only
 * instantiates it at all when the machine is a GICv2 (hw/arm/virt.c
 * create_gic(): gic-version=3 gets an ITS instead and no frame), and
 * the frame's own MSI_TYPER is the only place its SPI range is
 * written down -- the device-tree node carries "compatible",
 * "msi-controller" and "reg" and no arm,msi-base-spi at all.  So the
 * node gives the address and the register gives the range.
 *
 * The vectors handed out here are ordinary SPIs once they arrive:
 * intrenable() enables them at the distributor and trap() dispatches
 * them through the same irqhandler table as the uart's 33 and the
 * virtio-mmio slots' 48 and up.  Nothing downstream of the GIC knows
 * an MSI happened.
 */
enum {
	V2mTYPER	= 0x008,	/* [25:16] base SPI, [9:0] count */
	V2mSETSPI_NS	= 0x040,	/* write the SPI number here */
};

static uchar	*v2m;		/* mapped frame, or nil */
static int	v2mbase;	/* first SPI it owns */
static int	v2mcount;	/* how many */
static int	v2mnext;	/* next free, base..base+count */
static uvlong	v2mphys;	/* the doorbell as a device must address it */
static int	v2mok;		/* the self-test in gicv2minit() passed */

/*
 * Hand out one vector.  The caller gets the write a device must make
 * (addr, data) and the interrupt number that write will become.
 *
 * The address is the frame's physical doorbell, not the mapped one:
 * this is an address a PCI function will drive onto the bus, and on
 * this machine there is no IOMMU between the two, so the device's
 * view and the cpu's physical view are the same number.  vmap()'s
 * virtual address would be meaningless to the device.
 */
static int
v2malloc(Pcidev *p, uvlong *addr, ulong *data)
{
	int spi;

	USED(p);
	if(v2m == nil || v2mnext >= v2mbase + v2mcount)
		return -1;
	spi = v2mnext++;
	/* the frame pulses this line; a level-configured SPI would drop
	 * it again before it ever became pending -- see gicedge() */
	gicedge(spi);
	*addr = v2mphys + V2mSETSPI_NS;
	*data = spi;
	return spi;
}

/*
 * Called from main() after fdtfind() and before the PCI scan, so that
 * a driver reaching pcimsixintr() finds the router already set.
 * Silent and harmless when there is no frame: pcimsirouter stays nil
 * and every driver keeps the INTx line it had.
 */
void
gicv2minit(void)
{
	extern int fdtreg(char*, uvlong*, uvlong*);
	uvlong base, size;
	u32int typer;

	if(!fdtreg("arm,gic-v2m-frame", &base, &size) || base == 0)
		return;
	if(size < 0x1000)
		size = 0x1000;
	if((v2m = vmap(base, size)) == nil)
		return;
	v2mphys = base;
	typer = *(u32int*)(v2m + V2mTYPER);
	v2mbase = (typer >> 16) & 0x3FF;
	v2mcount = typer & 0x3FF;
	/*
	 * A frame whose TYPER reads back as nothing is a frame that is
	 * not there -- better to fall back to INTx than to hand out
	 * vector 0, which is an SGI.
	 */
	if(v2mbase < GicSpiBase || v2mcount <= 0
	|| v2mbase + v2mcount > GicIRQMax){
		vunmap(v2m, size);
		v2m = nil;
		return;
	}
	v2mnext = v2mbase;

	/*
	 * Prove the frame actually routes before any driver depends on
	 * it.  A store to SETSPI_NS is an ordinary MMIO write, and QEMU's
	 * gicv2m_write() cannot tell a cpu store from a PCI device's --
	 * so ringing the doorbell here exercises exactly the link a
	 * device will use, with no device involved.
	 *
	 * The arrival is read from GICD_ISPENDR rather than by taking the
	 * interrupt: this runs in main(), before procinit(), where
	 * spllo() would also admit the clock and clockintr() has no
	 * process to charge.  The distributor-to-cpu half of the path
	 * needs no proof here anyway -- the virtio-mmio net device's SPI
	 * 79 is one number below these and arrives through the same
	 * gicenable() and the same trap().
	 *
	 * The pending bit is cleared again afterwards, or the vector
	 * would fire the moment interrupts are enabled, at whatever
	 * handler had by then been installed on it.
	 */
	{
		u32int *gicd = (u32int*)GICD;
		int spi = v2mbase;

		gicedge(spi);
		*(u32int*)(v2m + V2mSETSPI_NS) = spi;
		coherence();
		v2mok = (gicd[0x200/4 + spi/32] & (1<<(spi%32))) != 0;
		gicd[0x280/4 + spi/32] = 1 << (spi%32);	/* GICD_ICPENDR */
		coherence();
	}
	if(!v2mok){
		vunmap(v2m, size);
		v2m = nil;
		return;
	}

	pcimsirouter = v2malloc;
}

/* what the board reports about itself; see fdtreport() in main.c */
void
gicv2mreport(void)
{
	if(v2m == nil){
		if(!gicv3itspresent())
			print("msi: no gicv2m frame and no its; pci interrupts are intx\n");
		return;
	}
	print("msi: gicv2m @ %#llux spi %d..%d (%d vectors), doorbell %#llux, MSI-DOORBELL-OK\n",
		v2mphys, v2mbase, v2mbase+v2mcount-1, v2mcount,
		v2mphys + V2mSETSPI_NS);
}
