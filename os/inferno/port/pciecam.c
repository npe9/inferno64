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

static uintptr
ecamaddr(int tbdf, int rno)
{
	return (uintptr)PCIECAM
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
 * QEMU's virt machine routes the four INTx pins of slot s to PLIC
 * interrupts 32..35, rotated by slot: pin A of slot 0 is 32, pin A
 * of slot 1 is 33, and so on (the interrupt-map in its device tree).
 */
static int
pciintx(Pcidev *p)
{
	int pin;

	pin = pcicfgr8(p, PciINTP);	/* 1 = INTA .. 4 = INTD, 0 = none */
	if(pin == 0)
		return -1;
	return 32 + ((BUSDNO(p->tbdf) + pin - 1) & 3);
}

/* called from archvirt.c's pciarchinit() */
void
pciinit(void)
{
	Pcidev *p;
	uvlong mema;
	ulong ioa;

	fmtinstall('T', tbdffmt);
	pcimaxdno = 31;
	pciscan(0, &pciroot, nil);
	if(pciroot == nil){
		print("pci ecam %#p: no devices\n", (uintptr)PCIECAM);
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
	}
}
