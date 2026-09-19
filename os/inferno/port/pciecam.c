#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/pci.h"

/*
 * PCI on QEMU's -M virt: the generic ECAM host (pci-host-ecam-generic).
 * ../port/pci.c does the bus walk, the BAR assignment and keeps the
 * Pcidev list, the same code pc64 uses; this file is only what that
 * code asks of a board: configuration-space access through the ECAM
 * window, and which PLIC interrupt each INTx pin lands on.
 *
 * The board's mem.h defines PCIECAM and PCIECAMSZ (the window),
 * PCIMMIO and PCIMMIOSZ (where memory BARs are placed) and PCIPIO
 * and PCIPIOSZ (the I/O-space window, unused by any driver here).
 */

static Pcidev *pciroot;

/*
 * The ECAM base is 64-bit on arm64 (0x4010000000).  Kept in a
 * DATA-initialised variable, not used as an inline constant: 7l
 * materialises a wide constant inside an expression with only its low
 * 32 bits, but an 8-byte DATA holds the whole value (doc/inferno-
 * ports.ms).  Harmless on riscv, where the base fits in 32 bits.
 */
static uvlong Ecambase = PCIECAM;

/*
 * Set by a board that can find the window at run time rather than
 * only in mem.h: os/inferno/virtarm64/acpi.c points this at its MCFG
 * reader.  Nil on a board with no firmware description, which is every
 * RISC-V one here, and then Ecambase stays what mem.h said.  Same
 * shape and the same name as os/inferno/pc/pcipc.c's, which
 * archacpi.c sets from the PC's MCFG.
 */
uvlong (*pciecam)(int*, int*);

static uintptr
ecamaddr(int tbdf, int rno)
{
	return (uintptr)Ecambase
		| ((uintptr)BUSBNO(tbdf) << 20)
		| ((uintptr)BUSDNO(tbdf) << 15)
		| ((uintptr)BUSFNO(tbdf) << 12)
		| (rno & 0xFFF);
}

static int
pcicfgrw8ecam(int tbdf, int rno, int data, int read)
{
	volatile u8 *p;

	p = (volatile u8*)ecamaddr(tbdf, rno);
	if(read)
		return *p;
	*p = data;
	return 0;
}

static int
pcicfgrw16ecam(int tbdf, int rno, int data, int read)
{
	volatile u16 *p;

	p = (volatile u16*)ecamaddr(tbdf, rno & ~1);
	if(read)
		return *p;
	*p = data;
	return 0;
}

static int
pcicfgrw32ecam(int tbdf, int rno, int data, int read)
{
	volatile u32 *p;

	p = (volatile u32*)ecamaddr(tbdf, rno & ~3);
	if(read)
		return *p;
	*p = data;
	return 0;
}

int (*pcicfgrw8)(int, int, int, int) = pcicfgrw8ecam;
int (*pcicfgrw16)(int, int, int, int) = pcicfgrw16ecam;
int (*pcicfgrw32)(int, int, int, int) = pcicfgrw32ecam;

/*
 * QEMU's virt machines route the four INTx pins of slot s to a small
 * run of interrupts, rotated by slot (the interrupt-map in the device
 * tree).  The base differs per board - PLIC 32 on riscv, GIC SPI 35 on
 * arm64 - so it is PCIINTXBASE in the board's mem.h.
 */
static int
pciintx(Pcidev *p)
{
	int pin;

	pin = pcicfgr8(p, PciINTP);	/* 1 = INTA .. 4 = INTD, 0 = none */
	if(pin == 0)
		return -1;
	return PCIINTXBASE + ((BUSDNO(p->tbdf) + pin - 1) & 3);
}

/* called from archvirt.c's pciarchinit() */
void
pciinit(void)
{
	Pcidev *p;
	uvlong mema;
	ulong ioa;
	int i;

	fmtinstall('T', tbdffmt);
	pcimaxdno = 31;

	if(pciecam != nil){
		uvlong pa;
		int b0, b1;

		b0 = 0;
		b1 = 255;
		if((pa = (*pciecam)(&b0, &b1)) != 0){
			if(pa != Ecambase)
				print("pci: ecam %#llux from the firmware, mem.h says %#llux\n",
					pa, (uvlong)Ecambase);
			Ecambase = pa;
		}
	}
	pciscan(0, &pciroot, nil);
	if(pciroot == nil){
		print("pci ecam %#llux: no devices\n", (uvlong)Ecambase);
		return;
	}
	/* firmware has assigned nothing; place every BAR ourselves */
	mema = (uvlong)PCIMMIO;
	ioa = (ulong)PCIPIO;
	pcibusmap(pciroot, &mema, &ioa, 1);
	for(p = pcimatch(nil, 0, 0); p != nil; p = pcimatch(p, 0, 0)){
		p->intl = pciintx(p);
		print("pci %T: %.4ux/%.4ux class %.6lux irq %d\n",
			p->tbdf, p->vid, p->did, p->ccrb<<16|p->ccru<<8|p->ccrp, p->intl);
		/*
		 * A bar above 4 GiB, and only that.  On a board that maps
		 * its address space rather than running flat, where the
		 * firmware put the windows decides how wide the virtual
		 * addresses have to be: QEMU's arm64 virt has a high PCIe
		 * MMIO window at 0x8000000000, which a 39-bit VA cannot
		 * reach at all, and virtarm64's mmuinit() carries a fourth
		 * table level for it.  This printed every bar while that
		 * question was open and the answer here was that none is
		 * high; the question stays open for a machine with more
		 * devices than QEMU's, so what is left is the line that
		 * would say so, on the boot where it first happens.
		 */
		for(i = 0; i < nelem(p->mem); i++)
			if(p->mem[i].size != 0
			&& ((uvlong)p->mem[i].bar & ~0xFULL) >= 0x100000000ULL)
				print("\tbar%d %#llux size %#llux: above 4G\n", i,
					(uvlong)p->mem[i].bar & ~0xFULL,
					(uvlong)p->mem[i].size);
	}
}
