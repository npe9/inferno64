#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/pci.h"

typedef struct Pcisiz Pcisiz;
struct Pcisiz
{
	Pcidev*	dev;
	int	siz;
	int	bar;
	int	typ;
};

int pcimaxdno;

static Lock pcicfglock;
static Pcidev *pcilist, **pcitail;

static char* bustypes[] = {
	"CBUSI",
	"CBUSII",
	"EISA",
	"FUTURE",
	"INTERN",
	"ISA",
	"MBI",
	"MBII",
	"MCA",
	"MPI",
	"MPSA",
	"NUBUS",
	"PCI",
	"PCMCIA",
	"TC",
	"VL",
	"VME",
	"XPRESS",
};

int
tbdffmt(Fmt* fmt)
{
	int type, tbdf;

	switch(fmt->r){
	default:
		return fmtstrcpy(fmt, "(tbdffmt)");

	case 'T':
		tbdf = va_arg(fmt->args, int);
		if(tbdf == BUSUNKNOWN) {
			return fmtstrcpy(fmt, "unknown");
		} else {
			type = BUSTYPE(tbdf);
			if(type < nelem(bustypes)) {
				return fmtprint(fmt, "%s.%d.%d.%d",
					bustypes[type], BUSBNO(tbdf), BUSDNO(tbdf), BUSFNO(tbdf));
			} else {
				return fmtprint(fmt, "%d.%d.%d.%d",
					type, BUSBNO(tbdf), BUSDNO(tbdf), BUSFNO(tbdf));
			}
		}
	}
}

static Pcidev*
pcidevalloc(void)
{
	Pcidev *p;

	p = xalloc(sizeof(*p));
	if(p == nil)
		panic("pci: no memory for Pcidev");
	return p;
}

void
pcidevfree(Pcidev *p)
{
	Pcidev **l;

	if(p == nil)
		return;

	while(p->bridge != nil)
		pcidevfree(p->bridge);

	if(p->parent != nil){
		for(l = &p->parent->bridge; *l != nil; l = &(*l)->link) {
			if(*l == p) {
				*l = p->link;
				break;
			}
		}
	}
	for(l = &pcilist; *l != nil; l = &(*l)->list) {
		if(*l == p) {
			if((*l = p->list) == nil)
				pcitail = l;
			break;
		}
	}
	/* leaked */
}

int
pcicfgr8(Pcidev* p, int rno)
{
	int data;

	ilock(&pcicfglock);
	data = pcicfgrw8(p->tbdf, rno, 0, 1);
	iunlock(&pcicfglock);

	return data;
}
void
pcicfgw8(Pcidev* p, int rno, int data)
{
	ilock(&pcicfglock);
	pcicfgrw8(p->tbdf, rno, data, 0);
	iunlock(&pcicfglock);
}
int
pcicfgr16(Pcidev* p, int rno)
{
	int data;

	ilock(&pcicfglock);
	data = pcicfgrw16(p->tbdf, rno, 0, 1);
	iunlock(&pcicfglock);

	return data;
}
void
pcicfgw16(Pcidev* p, int rno, int data)
{
	ilock(&pcicfglock);
	pcicfgrw16(p->tbdf, rno, data, 0);
	iunlock(&pcicfglock);
}
int
pcicfgr32(Pcidev* p, int rno)
{
	int data;

	ilock(&pcicfglock);
	data = pcicfgrw32(p->tbdf, rno, 0, 1);
	iunlock(&pcicfglock);

	return data;
}
void
pcicfgw32(Pcidev* p, int rno, int data)
{
	ilock(&pcicfglock);
	pcicfgrw32(p->tbdf, rno, data, 0);
	iunlock(&pcicfglock);
}

int
pcibarsize(Pcidev *p, int rno)
{
	int v, size;

	ilock(&pcicfglock);
	v = pcicfgrw32(p->tbdf, rno, 0, 1);
	pcicfgrw32(p->tbdf, rno, -1, 0);
	size = pcicfgrw32(p->tbdf, rno, 0, 1);
	pcicfgrw32(p->tbdf, rno, v, 0);
	iunlock(&pcicfglock);

	if(rno == PciEBAR0 || rno == PciEBAR1){
		size &= ~0x7FF;
	} else if(v & 1){
		size = (short)size;
		size &= ~3;
	} else {
		size &= ~0xF;
	}

	return -size;
}

void
pcisetbar(Pcidev *p, int rno, uvlong bar)
{
	ilock(&pcicfglock);
	pcicfgrw32(p->tbdf, rno, bar, 0);
	if((bar&7) == 4 && rno >= PciBAR0 && rno < PciBAR0+4*(nelem(p->mem)-1))
		pcicfgrw32(p->tbdf, rno+4, bar>>32, 0);
	iunlock(&pcicfglock);
}

void
pcisetwin(Pcidev *p, uvlong base, uvlong limit)
{
	ilock(&pcicfglock);
	if(base & 1){
		pcicfgrw16(p->tbdf, PciIBR, (limit & 0xF000)|((base & 0xF000)>>8), 0);
		pcicfgrw32(p->tbdf, PciIUBR, (limit & 0xFFFF0000)|(base>>16), 0);
	} else if(base & 8){
		pcicfgrw32(p->tbdf, PciPMBR, (limit & 0xFFF00000)|((base & 0xFFF00000)>>16), 0);
		pcicfgrw32(p->tbdf, PciPUBR, base >> 32, 0);
		pcicfgrw32(p->tbdf, PciPULR, limit >> 32, 0);
	} else {
		pcicfgrw32(p->tbdf, PciMBR, (limit & 0xFFF00000)|((base & 0xFFF00000)>>16), 0);
	}
	iunlock(&pcicfglock);
}

static int
pcisizcmp(void *a, void *b)
{
	Pcisiz *aa, *bb;

	aa = a;
	bb = b;
	return aa->siz - bb->siz;
}

static ulong
pcimask(ulong v)
{
	ulong m;

	m = BI2BY*sizeof(v);
	for(m = 1<<(m-1); m != 0; m >>= 1) {
		if(m & v)
			break;
	}

	m--;
	if((v & m) == 0)
		return v;

	v |= m;
	return v+1;
}

void
pcibusmap(Pcidev *root, uvlong *pmema, ulong *pioa, int wrreg)
{
	Pcidev *p;
	int ntb, i, size, rno, hole;
	uvlong mema, smema;
	ulong ioa, sioa, v;
	Pcisiz *table, *tptr, *mtb, *itb;

	ioa = *pioa;
	mema = *pmema;

	ntb = 0;
	for(p = root; p != nil; p = p->link)
		ntb++;

	ntb *= (PciCIS-PciBAR0)/4;
	table = malloc((2*ntb+1)*sizeof(Pcisiz));
	if(table == nil)
		panic("pcibusmap: can't allocate memory");
	itb = table;
	mtb = table+ntb;

	/*
	 * Build a table of sizes
	 */
	for(p = root; p != nil; p = p->link) {
		if(p->ccrb == 0x06) {
			/* carbus bridge? */
			if(p->ccru == 0x07){
				if(pcicfgr32(p, PciBAR0) & 1)
					continue;
				size = pcibarsize(p, PciBAR0);
				if(size == 0)
					continue;
				mtb->dev = p;
				mtb->bar = 0;
				mtb->siz = size;
				mtb->typ = 0;
				mtb++;
				continue;
			}

			/* pci bridge? */
			if(p->ccru != 0x04 || p->bridge == nil)
				continue;

			sioa = ioa;
			smema = mema;
			pcibusmap(p->bridge, &smema, &sioa, 0);

			hole = pcimask(sioa-ioa);
			if(hole < (1<<12))
				hole = 1<<12;
			itb->dev = p;
			itb->bar = -1;
			itb->siz = hole;
			itb->typ = 0;
			itb++;

			hole = pcimask(smema-mema);
			if(hole < (1<<20))
				hole = 1<<20;
			mtb->dev = p;
			mtb->bar = -1;
			mtb->siz = hole;
			mtb->typ = 0;
			mtb++;

			size = pcibarsize(p, PciEBAR1);
			if(size != 0){
				mtb->dev = p;
				mtb->bar = -3;
				mtb->siz = size;
				mtb->typ = 0;
				mtb++;
			}
			continue;
		}

		size = pcibarsize(p, PciEBAR0);
		if(size != 0){
			mtb->dev = p;
			mtb->bar = -2;
			mtb->siz = size;
			mtb->typ = 0;
			mtb++;
		}

		for(i = 0; i < nelem(p->mem); i++) {
			rno = PciBAR0 + i*4;
			v = pcicfgr32(p, rno);
			size = pcibarsize(p, rno);
			if(size == 0)
				continue;
			if(v & 1) {
				itb->dev = p;
				itb->bar = i;
				itb->siz = size;
				itb->typ = 1;
				itb++;
			} else {
				mtb->dev = p;
				mtb->bar = i;
				mtb->siz = size;
				mtb->typ = v & 7;
				if(mtb->typ & 4)
					i++;
				mtb++;
			}
		}
	}

	/*
	 * A BAR is moved with the device's decoders off.  PCI says the
	 * effect of writing a base address while the device is decoding
	 * is undefined, and a machine really does take it that way: on a
	 * Compute Engine t2a the NVMe controller -- which the firmware
	 * had used to boot, and had left enabled -- kept answering at the
	 * address the firmware gave it, so its MSI-X table read back all
	 * ones wherever this code put it, and its interrupts could not be
	 * programmed at all.  The network card, which the firmware never
	 * touched and left disabled, took its new address without
	 * complaint.  pcienable() below turns the decoders back on.
	 */
	if(wrreg){
		for(p = root; p != nil; p = p->link){
			p->pcr = pcicfgr16(p, PciPCR);
			pcicfgw16(p, PciPCR, p->pcr & ~(IOen|MEMen));
		}
	}

	/*
	 * Sort both tables IO smallest first, Memory largest
	 */
	qsort(table, itb-table, sizeof(Pcisiz), pcisizcmp);
	tptr = table+ntb;
	qsort(tptr, mtb-tptr, sizeof(Pcisiz), pcisizcmp);

	/*
	 * Allocate IO address space on this bus
	 */
	for(tptr = table; tptr < itb; tptr++) {
		hole = tptr->siz;
		if(tptr->bar == -1)
			hole = 1<<12;
		ioa = (ioa+hole-1) & ~(hole-1);
		if(wrreg){
			p = tptr->dev;
			if(tptr->bar == -1) {
				p->ioa.bar = ioa;
				p->ioa.size = tptr->siz;
			} else {
				p->mem[tptr->bar].size = tptr->siz;
				p->mem[tptr->bar].bar = ioa|1;
				pcisetbar(p, PciBAR0+tptr->bar*4, p->mem[tptr->bar].bar);
			}
		}
		ioa += tptr->siz;
	}

	/*
	 * Allocate Memory address space on this bus
	 */
	for(tptr = table+ntb; tptr < mtb; tptr++) {
		hole = tptr->siz;
		if(tptr->bar == -1)
			hole = 1<<20;
		mema = (mema+hole-1) & ~((uvlong)hole-1);
		if(wrreg){
			p = tptr->dev;
			if(tptr->bar == -1) {
				p->mema.bar = mema;
				p->mema.size = tptr->siz;
			} else if(tptr->bar == -2) {
				p->rom.bar = mema|1;
				p->rom.size = tptr->siz;
				pcisetbar(p, PciEBAR0, p->rom.bar);
			} else if(tptr->bar == -3) {
				p->rom.bar = mema|1;
				p->rom.size = tptr->siz;
				pcisetbar(p, PciEBAR1, p->rom.bar);
			} else {
				p->mem[tptr->bar].size = tptr->siz;
				p->mem[tptr->bar].bar = mema|tptr->typ;
				pcisetbar(p, PciBAR0+tptr->bar*4, p->mem[tptr->bar].bar);
			}
		}
		mema += tptr->siz;
	}

	*pmema = mema;
	*pioa = ioa;
	free(table);

	if(wrreg == 0)
		return;

	/* the decoders come back on, exactly as they were found */
	for(p = root; p != nil; p = p->link)
		pcicfgw16(p, PciPCR, p->pcr);

	/*
	 * Finally set all the bridge addresses & registers
	 */
	for(p = root; p != nil; p = p->link) {
		if(p->bridge == nil) {
			pcienable(p);
			continue;
		}

		/* Set I/O and Mem windows */
		pcisetwin(p, p->ioa.bar|1, p->ioa.bar+p->ioa.size-1);
		pcisetwin(p, p->mema.bar|0, p->mema.bar+p->mema.size-1);

		/* Disable prefetch */
		pcisetwin(p, 0xFFF00000|8, 0);

		/* Enable the bridge */
		pcienable(p);

		sioa = p->ioa.bar;
		smema = p->mema.bar;
		pcibusmap(p->bridge, &smema, &sioa, 1);
	}
}

static int
pcivalidwin(Pcidev *p, uvlong base, uvlong limit)
{
	Pcidev *bridge = p->parent;
	char *typ;

	if(base & 1){
		typ = "io";
		base &= ~3;
		if(base > limit)
			return 0;
		if(bridge == nil)
			return 1;
		if(base >= bridge->ioa.bar && limit < (bridge->ioa.bar + bridge->ioa.size))
			return 1;
	} else {
		typ = "mem";
		base &= ~0xFULL;
		if(base > limit)
			return 0;
		if(bridge == nil)
			return 1;
		if(base >= bridge->mema.bar && limit < (bridge->mema.bar + bridge->mema.size))
			return 1;
		if(base >= bridge->prefa.bar && limit < (bridge->prefa.bar + bridge->prefa.size))
			return 1;
	}
	print("%T: %.2uX invalid %s-window: %.8llux-%.8llux\n", p->tbdf, p->ccrb, typ, base, limit);
	return 0;
}

static int
pcivalidbar(Pcidev *p, uvlong bar, int size)
{
	if(bar & 1){
		bar &= ~3;
		if(bar == 0 || size < 4 || (bar & (size-1)) != 0)
			return 0;
		return pcivalidwin(p, bar|1, bar+size-1);
	} else {
		bar &= ~0xFULL;
		if(bar == 0 || size < 16 || (bar & (size-1)) != 0)
			return 0;
		return pcivalidwin(p, bar|0, bar+size-1);
	}
}

int
pciscan(int bno, Pcidev** list, Pcidev *parent)
{
	Pcidev *p, *head, **tail;
	int dno, fno, i, hdt, l, maxfno, maxubn, rno, sbn, tbdf, ubn;

	maxubn = bno;
	head = nil;
	tail = nil;
	for(dno = 0; dno <= pcimaxdno; dno++){
		maxfno = 0;
		for(fno = 0; fno <= maxfno; fno++){
			/*
			 * For this possible device, form the
			 * bus+device+function triplet needed to address it
			 * and try to read the vendor and device ID.
			 * If successful, allocate a device struct and
			 * start to fill it in with some useful information
			 * from the device's configuration space.
			 */
			tbdf = MKBUS(BusPCI, bno, dno, fno);

			lock(&pcicfglock);
			l = pcicfgrw32(tbdf, PciVID, 0, 1);
			unlock(&pcicfglock);

			if(l == 0xFFFFFFFF || l == 0)
				continue;
			p = pcidevalloc();
			p->tbdf = tbdf;
			p->vid = l;
			p->did = l>>16;

			p->pcr = pcicfgr16(p, PciPCR);
			p->rid = pcicfgr8(p, PciRID);
			p->ccrp = pcicfgr8(p, PciCCRp);
			p->ccru = pcicfgr8(p, PciCCRu);
			p->ccrb = pcicfgr8(p, PciCCRb);
			p->cls = pcicfgr8(p, PciCLS);
			p->ltr = pcicfgr8(p, PciLTR);
			p->intl = pcicfgr8(p, PciINTL);

			/*
			 * If the device is a multi-function device adjust the
			 * loop count so all possible functions are checked.
			 */
			hdt = pcicfgr8(p, PciHDT);
			if(hdt & 0x80)
				maxfno = MaxFNO;

			/*
			 * If appropriate, read the base address registers
			 * and work out the sizes.
			 */
			switch(p->ccrb) {
			case 0x00:		/* prehistoric */
			case 0x01:		/* mass storage controller */
			case 0x02:		/* network controller */
			case 0x03:		/* display controller */
			case 0x04:		/* multimedia device */
			case 0x07:		/* simple comm. controllers */
			case 0x08:		/* base system peripherals */
			case 0x09:		/* input devices */
			case 0x0A:		/* docking stations */
			case 0x0B:		/* processors */
			case 0x0C:		/* serial bus controllers */
			case 0x0D:		/* wireless controllers */
			case 0x0E:		/* intelligent I/O controllers */
			case 0x0F:		/* sattelite communication controllers */
			case 0x10:		/* encryption/decryption controllers */
			case 0x11:		/* signal processing controllers */
				if((hdt & 0x7F) != 0)
					break;
				rno = PciBAR0;
				for(i = 0; i < nelem(p->mem); i++) {
					p->mem[i].bar = (ulong)pcicfgr32(p, rno);
					p->mem[i].size = pcibarsize(p, rno);
					if((p->mem[i].bar & 7) == 4 && i < nelem(p->mem)-1){
						rno += 4;
						p->mem[i++].bar |= (uvlong)pcicfgr32(p, rno) << 32;
						p->mem[i].bar = 0;
						p->mem[i].size = 0;
					}
					rno += 4;
				}

				p->rom.bar = (ulong)pcicfgr32(p, PciEBAR0);
				p->rom.size = pcibarsize(p, PciEBAR0);
				pcisriovscan(p);
				break;

			case 0x06:		/* bridge device */
				/* cardbus bridge? */
				if(p->ccru == 0x07){
					p->mem[0].bar = (ulong)pcicfgr32(p, PciBAR0);
					p->mem[0].size = pcibarsize(p, PciBAR0);
					break;
				}

				/* pci bridge? */
				if(p->ccru != 0x04)
					break;

				p->rom.bar = (ulong)pcicfgr32(p, PciEBAR1);
				p->rom.size = pcibarsize(p, PciEBAR1);
				break;
			case 0x05:		/* memory controller */
			default:
				break;
			}

			p->parent = parent;
			if(head != nil)
				*tail = p;
			else
				head = p;
			tail = &p->link;

			if(pcilist != nil)
				*pcitail = p;
			else
				pcilist = p;
			pcitail = &p->list;
		}
	}

	*list = head;
	for(p = head; p != nil; p = p->link){
		/*
		 * Find PCI-PCI bridges and recursively descend the tree.
		 */
		switch(p->ccrb) {
		case 0x06:
			if(p->ccru == 0x04)
				break;
		default:
			/* check and clear invalid membars for non bridges */
			for(i = 0; i < nelem(p->mem); i++) {
				if(p->mem[i].size == 0)
					continue;
				if(!pcivalidbar(p, p->mem[i].bar, p->mem[i].size)){
					if(p->mem[i].bar & 1)
						p->mem[i].bar &= 3;
					else
						p->mem[i].bar &= 0xF;
					pcisetbar(p, PciBAR0 + i*4, p->mem[i].bar);
				}
			}
			if(p->rom.size) {
				if((p->rom.bar & 1) == 0
				|| !pcivalidbar(p, p->rom.bar & ~0x7FFULL, p->rom.size)){
					p->rom.bar = 0;
					pcisetbar(p, PciEBAR0, p->rom.bar);
				}
			}
			continue;
		}

		if(p->rom.size) {
			if((p->rom.bar & 1) == 0
			|| !pcivalidbar(p, p->rom.bar & ~0x7FFULL, p->rom.size)){
				p->rom.bar = 0;
				pcisetbar(p, PciEBAR1, p->rom.bar);
			}
		}

		/*
		 * If the secondary or subordinate bus number is not
		 * initialised try to do what the PCI BIOS should have
		 * done and fill in the numbers as the tree is descended.
		 * On the way down the subordinate bus number is set to
		 * the maximum as it's not known how many buses are behind
		 * this one; the final value is set on the way back up.
		 */
		sbn = pcicfgr8(p, PciSBN);
		ubn = pcicfgr8(p, PciUBN);

		if(sbn == 0 || ubn == 0) {
			sbn = maxubn+1;
			/*
			 * Make sure memory, I/O and master enables are
			 * off, set the primary, secondary and subordinate
			 * bus numbers and clear the secondary status before
			 * attempting to scan the secondary bus.
			 *
			 * Initialisation of the bridge should be done here.
			 */
			p->pcr = 0;
			pcicfgw32(p, PciPCR, 0xFFFF0000);
			l = (MaxUBN<<16)|(sbn<<8)|bno;
			pcicfgw32(p, PciPBN, l);
			pcicfgw16(p, PciSPSR, 0xFFFF);

			p->ioa.bar = 0;
			p->ioa.size = 0;
			p->mema.bar = 0;
			p->mema.size = 0;
			p->prefa.bar = 0;
			p->prefa.size = 0;

			pcisetwin(p, 0xFFFFF000|1, 0);
			pcisetwin(p, 0xFFF00000|0, 0);
			pcisetwin(p, 0xFFF00000|8, 0);

			maxubn = pciscan(sbn, &p->bridge, p);
			l = (maxubn<<16)|(sbn<<8)|bno;

			pcicfgw32(p, PciPBN, l);
		}
		else {
			uvlong base, limit;
			ulong v;

			v = pcicfgr16(p, PciIBR);
			limit = (v & 0xF000) | 0x0FFF;
			base  = (v & 0x00F0) << 8;
			if((v & 0x0F) == 0x01){
				v = pcicfgr32(p, PciIUBR);
				limit |= (v & 0xFFFF0000);
				base  |= (v & 0x0000FFFF) << 16;
			}
			if(pcivalidwin(p, base|1, limit)){
				p->ioa.bar = base;
				p->ioa.size = (limit - base)+1;
			} else {
				pcisetwin(p, 0xFFFFF000|1, 0);
				p->ioa.bar = 0;
				p->ioa.size = 0;
			}

			v = pcicfgr32(p, PciMBR);
			limit = (v & 0xFFF00000) | 0x000FFFFF;
			base  = (v & 0x0000FFF0) << 16;
			if(pcivalidwin(p, base|0, limit)){
				p->mema.bar = base;
				p->mema.size = (limit - base)+1;
			} else {
				pcisetwin(p, 0xFFF00000|0, 0);
				p->mema.bar = 0;
				p->mema.size = 0;
			}

			v = pcicfgr32(p, PciPMBR);
			limit = (v & 0xFFF00000) | 0x000FFFFF;
			limit |= (uvlong)pcicfgr32(p, PciPULR) << 32;
			base  = (v & 0x0000FFF0) << 16;
			base  |= (uvlong)pcicfgr32(p, PciPUBR) << 32;
			if(pcivalidwin(p, base|8, limit)){
				p->prefa.bar = base;
				p->prefa.size = (limit - base)+1;
			} else {
				pcisetwin(p, 0xFFF00000|8, 0);
				p->prefa.bar = 0;
				p->prefa.size = 0;
			}

			if(ubn > maxubn)
				maxubn = ubn;
			pciscan(sbn, &p->bridge, p);
		}
	}

	return maxubn;
}

void
pcibussize(Pcidev *root, uvlong *msize, ulong *iosize)
{
	*msize = 0;
	*iosize = 0;
	pcibusmap(root, msize, iosize, 0);
}

Pcidev*
pcimatch(Pcidev* prev, int vid, int did)
{
	if(prev == nil)
		prev = pcilist;
	else
		prev = prev->list;

	while(prev != nil){
		if((vid == 0 || prev->vid == vid)
		&& (did == 0 || prev->did == did))
			break;
		prev = prev->list;
	}
	return prev;
}

Pcidev*
pcimatchtbdf(int tbdf)
{
	Pcidev *pcidev;

	for(pcidev = pcilist; pcidev != nil; pcidev = pcidev->list) {
		if(pcidev->tbdf == tbdf)
			break;
	}
	return pcidev;
}

uchar
pciipin(Pcidev *pci, uchar pin)
{
	if (pci == nil)
		pci = pcilist;

	while (pci != nil) {
		uchar intl;

		if (pcicfgr8(pci, PciINTP) == pin && pci->intl != 0 && pci->intl != 0xff)
			return pci->intl;

		if (pci->bridge && (intl = pciipin(pci->bridge, pin)) != 0)
			return intl;

		pci = pci->list;
	}
	return 0;
}

static void
pcilhinv(Pcidev* p)
{
	int i;
	Pcidev *t;

	for(t = p; t != nil; t = t->link) {
		print("%d  %2d/%d %.2ux %.2ux %.2ux %.4ux %.4ux %3d  ",
			BUSBNO(t->tbdf), BUSDNO(t->tbdf), BUSFNO(t->tbdf),
			t->ccrb, t->ccru, t->ccrp, t->vid, t->did, t->intl);
		for(i = 0; i < nelem(p->mem); i++) {
			if(t->mem[i].size == 0)
				continue;
			print("%d:%.8llux %d ", i, t->mem[i].bar, t->mem[i].size);
		}
		if(t->rom.bar || t->rom.size)
			print("rom:%.8llux %d ", t->rom.bar, t->rom.size);
		if(t->ioa.bar || t->ioa.size)
			print("ioa:%.8llux-%.8llux %d ", t->ioa.bar, t->ioa.bar+t->ioa.size, t->ioa.size);
		if(t->mema.bar || t->mema.size)
			print("mema:%.8llux-%.8llux %d ", t->mema.bar, t->mema.bar+t->mema.size, t->mema.size);
		if(t->prefa.bar || t->prefa.size)
			print("prefa:%.8llux-%.8llux %llud ", t->prefa.bar, t->prefa.bar+t->prefa.size, t->prefa.size);
		if(t->bridge)
			print("->%d", BUSBNO(t->bridge->tbdf));
		print("\n");
	}
	while(p != nil) {
		if(p->bridge != nil)
			pcilhinv(p->bridge);
		p = p->link;
	}
}

void
pcihinv(Pcidev* p)
{
	print("bus dev type     vid  did  intl memory\n");
	pcilhinv(p);
}

void
pcireset(void)
{
	Pcidev *p;

	for(p = pcilist; p != nil; p = p->list) {
		/* don't mess with the bridges */
		if(p->ccrb == 0x06)
			continue;
		pcidisable(p);
	}
}

void
pcisetioe(Pcidev* p)
{
	p->pcr |= IOen;
	pcicfgw16(p, PciPCR, p->pcr);
}

void
pciclrioe(Pcidev* p)
{
	p->pcr &= ~IOen;
	pcicfgw16(p, PciPCR, p->pcr);
}

void
pcisetbme(Pcidev* p)
{
	p->pcr |= MASen;
	pcicfgw16(p, PciPCR, p->pcr);
}

void
pciclrbme(Pcidev* p)
{
	p->pcr &= ~MASen;
	pcicfgw16(p, PciPCR, p->pcr);
}

void
pcisetmwi(Pcidev* p)
{
	p->pcr |= MemWrInv;
	pcicfgw16(p, PciPCR, p->pcr);
}

void
pciclrmwi(Pcidev* p)
{
	p->pcr &= ~MemWrInv;
	pcicfgw16(p, PciPCR, p->pcr);
}

int
pcienumcaps(Pcidev *p, int (*fmatch)(Pcidev*, int, int, int), int arg)
{
	int i, r, cap, off;

	/* status register bit 4 has capabilities */
	if((pcicfgr16(p, PciPSR) & 1<<4) == 0)
		return -1;      
	switch(pcicfgr8(p, PciHDT) & 0x7F){
	default:
		return -1;
	case 0:                         /* etc */
	case 1:                         /* pci to pci bridge */
		off = 0x34;
		break;
	case 2:                         /* cardbus bridge */
		off = 0x14;
		break;
	}
	for(i = 48; i--;){
		off = pcicfgr8(p, off);
		if(off < 0x40 || (off & 3))
			break;
		off &= ~3;
		cap = pcicfgr8(p, off);
		if(cap == 0xff)
			break;
		r = (*fmatch)(p, cap, off, arg);
		if(r < 0)
			break;
		if(r == 0)
			return off;
		off++;
	}
	return -1;
}

static int
matchcap(Pcidev *, int cap, int, int arg)
{
	return cap != arg;
}

static int
matchhtcap(Pcidev *p, int cap, int off, int arg)
{
	int mask;

	if(cap != PciCapHTC)
		return 1;
	if(arg == 0x00 || arg == 0x20)
		mask = 0xE0;
	else
		mask = 0xF8;
	cap = pcicfgr8(p, off+3);
	return (cap & mask) != arg;
}

/*
 * Put back the configuration the host keeps in the Pcidev -- BARs,
 * interrupt line, latency, cache line, then the command register --
 * after something cleared it: D3, a reset.
 */
static void
pcirestore(Pcidev *p)
{
	int i;

	for(i = 0; i < nelem(p->mem); i++){
		if(p->mem[i].size == 0)
			continue;
		pcisetbar(p, PciBAR0+i*4, p->mem[i].bar);
	}
	pcicfgw8(p, PciINTL, p->intl);
	pcicfgw8(p, PciLTR, p->ltr);
	pcicfgw8(p, PciCLS, p->cls);
	pcicfgw16(p, PciPCR, p->pcr);
}

static void
pcidelay(int ms)
{
	if(up != nil)
		tsleep(&up->sleep, return0, nil, ms);
	else
		delay(ms);
}

/*
 * Function-level reset (PCIe base specification, 6.6.2): wait for the
 * function's outstanding transactions, start the reset, wait the 100
 * ms the specification gives it, and put back what the host had
 * configured (pcirestore, from the Pcidev, as pcienable does after
 * D3), which the reset cleared.  Returns 0 for a function without
 * FLR.  The caller has stopped the function first (pcidisable).
 */
int
pciflr(Pcidev *p)
{
	int cap, i;

	cap = pcicap(p, PciCapPCIe);
	if(cap < 0 || (pcicfgr32(p, cap+PcieDEVCAP) & 1<<28) == 0)
		return 0;
	for(i = 0; i < 100 && (pcicfgr16(p, cap+PcieDEVSTS) & 1<<5) != 0; i++)
		pcidelay(1);	/* transactions pending */
	pcicfgw16(p, cap+PcieDEVCTL, pcicfgr16(p, cap+PcieDEVCTL) | 1<<15);
	pcidelay(100);
	for(i = 0; i < 1000 && (pcicfgr32(p, 0) & 0xFFFF) == 0xFFFF; i++)
		pcidelay(1);
	pcirestore(p);
	return 1;
}

/*
 * Secondary bus reset (PCI-to-PCI bridge specification, 3.2.5.17):
 * the bridge above p resets everything below it, so only when p is
 * all that is there.  The reset held 2 ms (Trst is 1 ms), then the
 * 100 ms a function gets to come back, then the host's configuration
 * put back.  Returns 0 where it cannot be done.
 */
int
pcisbr(Pcidev *p)
{
	Pcidev *b, *q;
	int i;

	b = p->parent;
	if(b == nil || b->bridge == nil)
		return 0;
	for(q = pcilist; q != nil; q = q->list)
		if(q != p && q->parent == b)
			return 0;
	pcicfgw16(b, PciBCR, pcicfgr16(b, PciBCR) | 1<<6);
	pcidelay(2);
	pcicfgw16(b, PciBCR, pcicfgr16(b, PciBCR) & ~(1<<6));
	pcidelay(100);
	for(i = 0; i < 1000 && (pcicfgr32(p, 0) & 0xFFFF) == 0xFFFF; i++)
		pcidelay(1);
	pcirestore(p);
	return 1;
}

/*
 * Reset one function as well as can be done without touching others:
 * FLR, else a secondary bus reset where it is alone below its bridge.
 * Says which, or nil.
 */
char*
pcifnreset(Pcidev *p)
{
	if(pciflr(p))
		return "FLR";
	if(pcisbr(p))
		return "secondary bus reset";
	return nil;
}

int
pcicap(Pcidev *p, int cap)
{
	return pcienumcaps(p, matchcap, cap);
}

int
pcihtcap(Pcidev *p, int cap)
{
	return pcienumcaps(p, matchhtcap, cap);
}

static int
pcigetmsi(Pcidev *p)
{
	if(p->msi != 0)
		return p->msi;
	return p->msi = pcicap(p, PciCapMSI);
}

enum {
	MSICtrl = 0x02, /* message control register (16 bit) */
	MSIAddr = 0x04, /* message address register (64 bit) */
	MSIData32 = 0x08, /* message data register for 32 bit MSI (16 bit) */
	MSIData64 = 0x0C, /* message data register for 64 bit MSI (16 bit) */
};

int
pcimsienable(Pcidev *p, uvlong addr, ulong data)
{
	int off, ok64;

	if((off = pcigetmsi(p)) < 0)
		return -1;
	ok64 = (pcicfgr16(p, off + MSICtrl) & (1<<7)) != 0;
	pcicfgw32(p, off + MSIAddr, addr);
	if(ok64) pcicfgw32(p, off + MSIAddr+4, addr >> 32);
	pcicfgw16(p, off + (ok64 ? MSIData64 : MSIData32), data);
	pcicfgw16(p, off + MSICtrl, 1);
	return 0;
}

int
pcimsidisable(Pcidev *p)
{
	int off;

	if((off = pcigetmsi(p)) < 0)
		return -1;
	pcicfgw16(p, off + MSICtrl, 0);
	return 0;
}

enum {
	MSIXCtrl	= 0x02,	/* message control (16 bit) */
	MSIXTbl		= 0x04,	/* table offset, and BIR in its low 3 bits */

	MSIXEnable	= 1<<15,
	MSIXFuncMask	= 1<<14,
	MSIXSizeMask	= 0x7FF,

	MSIXEntSize	= 16,	/* addr lo, addr hi, data, vector control */
	MSIXEntMask	= 1,	/* bit 0 of a vector's control word */
};

/*
 * A driver that wants a vector per queue calls these rather than
 * intrenable(), because intrenable()'s irq argument cannot say which
 * of a device's MSI-X vectors is meant.  They stay nil on a board
 * whose interrupt controller cannot deliver MSI-X; a driver must test
 * before using them and fall back to intrenable().  os/inferno/pc's
 * irqinit() sets them.
 */
void (*pcimsixintrenable)(Pcidev*, int, void (*)(Ureg*, void*), void*, char*);
void (*pcimsixintrdisable)(Pcidev*, int, void (*)(Ureg*, void*), void*, char*);

static int
pcigetmsix(Pcidev *p)
{
	if(p->msix != 0)
		return p->msix;
	return p->msix = pcicap(p, PciCapMSIX);
}

/*
 * How many vectors the device's table holds, or -1 if it has no MSI-X
 * capability.  A driver that wants a queue per vector asks this first.
 */
int
pcimsixcount(Pcidev *p)
{
	int off;

	if((off = pcigetmsix(p)) < 0)
		return -1;
	return (pcicfgr16(p, off + MSIXCtrl) & MSIXSizeMask) + 1;
}

/*
 * MSI-X differs from MSI in where the message lives: not in
 * configuration space but in a table in one of the device's own BARs,
 * one 16-byte entry per vector, which is why this needs vmap() and MSI
 * does not.  Parts that carry no INTx pin at all -- Amazon's ENA, and
 * the current Intel and Mellanox 100G parts -- can be interrupted no
 * other way.
 */
int
pcimsixenable(Pcidev *p, int vec, uvlong addr, ulong data)
{
	int off, nvec, bir;
	uvlong base;
	u32int tbl;
	uchar *e;

	if((off = pcigetmsix(p)) < 0)
		return -1;
	nvec = (pcicfgr16(p, off + MSIXCtrl) & MSIXSizeMask) + 1;
	if(vec < 0 || vec >= nvec)
		return -1;

	if(p->msixtbl == nil){
		tbl = pcicfgr32(p, off + MSIXTbl);
		bir = tbl & 7;
		if(bir >= nelem(p->mem))
			return -1;
		base = p->mem[bir].bar;
		if(base == 0 || (base & 1) != 0)	/* must be a memory bar */
			return -1;
		base &= ~0xFULL;
		p->msixtbl = vmap(base + (tbl & ~7), nvec*MSIXEntSize);
		if(p->msixtbl == nil)
			return -1;
	}

	/* the vector stays masked while its address and data change */
	e = (uchar*)p->msixtbl + vec*MSIXEntSize;
	*(u32int*)(e+12) = MSIXEntMask;
	coherence();
	*(u32int*)(e+0) = addr;
	*(u32int*)(e+4) = addr>>32;
	*(u32int*)(e+8) = data;
	coherence();
	*(u32int*)(e+12) = 0;

	pcicfgw16(p, off + MSIXCtrl,
		(pcicfgr16(p, off + MSIXCtrl) & ~MSIXFuncMask) | MSIXEnable);
	return 0;
}

/*
 * Mask or unmask one vector, leaving the rest of the table and the
 * capability alone.  Disabling a single queue's interrupt on a device
 * whose other queues are still running is this, not pcimsixdisable().
 */
int
pcimsixmask(Pcidev *p, int vec, int mask)
{
	int off, nvec;
	uchar *e;

	if((off = pcigetmsix(p)) < 0 || p->msixtbl == nil)
		return -1;
	nvec = (pcicfgr16(p, off + MSIXCtrl) & MSIXSizeMask) + 1;
	if(vec < 0 || vec >= nvec)
		return -1;
	e = (uchar*)p->msixtbl + vec*MSIXEntSize;
	*(u32int*)(e+12) = mask ? MSIXEntMask : 0;
	coherence();
	return 0;
}

int
pcimsixdisable(Pcidev *p)
{
	int off;

	if((off = pcigetmsix(p)) < 0)
		return -1;
	pcicfgw16(p, off + MSIXCtrl, 0);
	return 0;
}

static int
pcigetpmrb(Pcidev *p)
{
        if(p->pmrb != 0)
                return p->pmrb;
        return p->pmrb = pcicap(p, PciCapPMG);
}

int
pcigetpms(Pcidev* p)
{
	int pmcsr, ptr;

	if((ptr = pcigetpmrb(p)) == -1)
		return -1;

	/*
	 * Power Management Register Block:
	 *  offset 0:	Capability ID
	 *	   1:	next item pointer
	 *	   2:	capabilities
	 *	   4:	control/status
	 *	   6:	bridge support extensions
	 *	   7:	data
	 */
	pmcsr = pcicfgr16(p, ptr+4);

	return pmcsr & 0x0003;
}

int
pcisetpms(Pcidev* p, int state)
{
	int ostate, pmc, pmcsr, ptr;

	if((ptr = pcigetpmrb(p)) == -1)
		return -1;

	pmc = pcicfgr16(p, ptr+2);
	pmcsr = pcicfgr16(p, ptr+4);
	ostate = pmcsr & 0x0003;
	pmcsr &= ~0x0003;

	switch(state){
	default:
		return -1;
	case 0:
		break;
	case 1:
		if(!(pmc & 0x0200))
			return -1;
		break;
	case 2:
		if(!(pmc & 0x0400))
			return -1;
		break;
	case 3:
		break;
	}
	pmcsr |= state;
	pcicfgw16(p, ptr+4, pmcsr);

	return ostate;
}

void
pcienable(Pcidev *p)
{
	uint pcr;
	int i;

	if(p == nil)
		return;

	pcienable(p->parent);

	switch(pcisetpms(p, 0)){
	case 1:
		print("pcienable %T: wakeup from D1\n", p->tbdf);
		break;
	case 2:
		print("pcienable %T: wakeup from D2\n", p->tbdf);
		if(p->bridge != nil)
			delay(100);	/* B2: minimum delay 50ms */
		else
			delay(1);	/* D2: minimum delay 200µs */
		break;
	case 3:
		print("pcienable %T: wakeup from D3\n", p->tbdf);
		delay(100);		/* D3: minimum delay 50ms */
		pcirestore(p);
		break;
	}

	if(p->ltr == 0 || p->ltr == 0xFF){
		p->ltr = 64;
		pcicfgw8(p,PciLTR, p->ltr);
	}
	if(p->cls == 0 || p->cls == 0xFF){
		p->cls = 64/4;
		pcicfgw8(p, PciCLS, p->cls);
	}

	if(p->bridge != nil)
		pcr = IOen|MEMen|MASen;
	else {
		pcr = 0;
		for(i = 0; i < nelem(p->mem); i++){
			if(p->mem[i].size == 0)
				continue;
			if(p->mem[i].bar & 1)
				pcr |= IOen;
			else
				pcr |= MEMen;
		}
	}

	/*
	 * From the register, not from the copy taken when the bus was
	 * walked: anything that has moved a BAR since has had to turn
	 * the decoders off to do it, and a stale copy here would decide
	 * they were already on and leave the device dark.
	 */
	p->pcr = pcicfgr16(p, PciPCR);
	if((p->pcr & pcr) != pcr){
		print("pcienable %T: pcr %ux->%ux\n", p->tbdf, p->pcr, p->pcr|pcr);
		p->pcr |= pcr;
		pcicfgw32(p, PciPCR, 0xFFFF0000|p->pcr);
	}
}

void
pcidisable(Pcidev *p)
{
	if(p == nil)
		return;
	pcimsixdisable(p);
	pcimsidisable(p);
	pciclrbme(p);
}

/*
 * PCI Express: the extended configuration space and what is in it.
 *
 * The 4096-byte space exists only for a PCI Express function, and is
 * only reachable through ECAM; the legacy 0xCF8/0xCFC mechanism names
 * 256 bytes.  A function has it when it has the PCI Express capability
 * and a read of 0x100 comes back as something other than all ones --
 * which is also what a configuration mechanism that cannot reach it
 * returns.  An empty first header (0) is a valid, capability-less
 * extended space.
 */
int
pcicfgspace(Pcidev *p)
{
	if(pcicap(p, PciCapPCIe) < 0)
		return 256;
	if(pcicfgr32(p, 0x100) == -1)
		return 256;
	return 4096;
}

/*
 * Walk the extended capability list from 0x100.  Each header is a
 * 32-bit word: id in bits 15:0, version in 19:16, next offset in 31:20.
 * fmatch is called with (p, id, version, offset, arg) and works as in
 * pcienumcaps: 0 stops with this offset, <0 stops with failure.
 */
int
pcienumextcaps(Pcidev *p, int (*fmatch)(Pcidev*, int, int, int, void*), void *arg)
{
	int i, off, r;
	u32int h;

	if(pcicfgspace(p) < 4096)
		return -1;
	off = 0x100;
	for(i = 0; i < (4096-0x100)/4; i++){
		h = pcicfgr32(p, off);
		if(h == 0 || h == ~0)
			break;
		r = (*fmatch)(p, h & 0xFFFF, (h>>16) & 0xF, off, arg);
		if(r < 0)
			break;
		if(r == 0)
			return off;
		off = (h>>20) & 0xFFC;
		if(off < 0x100)
			break;
	}
	return -1;
}

static int
matchextcap(Pcidev*, int cap, int, int, void *arg)
{
	return cap != *(int*)arg;
}

int
pciextcap(Pcidev *p, int cap)
{
	return pcienumextcaps(p, matchextcap, &cap);
}

char*
pcicapname(int cap)
{
	switch(cap){
	case PciCapPMG:	return "pm";
	case PciCapAGP:	return "agp";
	case PciCapVPD:	return "vpd";
	case PciCapSID:	return "slotid";
	case PciCapMSI:	return "msi";
	case PciCapCHS:	return "hotswap";
	case PciCapPCIX:	return "pcix";
	case PciCapHTC:	return "ht";
	case PciCapVND:	return "vendor";
	case 0x0a:	return "debug";
	case 0x0d:	return "ssvid";
	case PciCapPCIe:	return "pcie";
	case PciCapMSIX:	return "msix";
	case PciCapSATA:	return "sata";
	case 0x13:	return "af";
	case 0x14:	return "ea";
	}
	return "unknown";
}

char*
pciextcapname(int cap)
{
	switch(cap){
	case PciExtCapAER:	return "aer";
	case PciExtCapVC:	return "vc";
	case PciExtCapDSN:	return "dsn";
	case PciExtCapPB:	return "powerbudget";
	case PciExtCapVNDR:	return "vendor";
	case PciExtCapACS:	return "acs";
	case PciExtCapARI:	return "ari";
	case PciExtCapATS:	return "ats";
	case PciExtCapSRIOV:	return "sriov";
	case PciExtCapMRIOV:	return "mriov";
	case PciExtCapMCAST:	return "mcast";
	case PciExtCapPRI:	return "pri";
	case PciExtCapRBAR:	return "rebar";
	case PciExtCapLTR:	return "ltr";
	case PciExtCapSPCIE:	return "secpcie";
	case PciExtCapPASID:	return "pasid";
	case PciExtCapDPC:	return "dpc";
	case PciExtCapL1SS:	return "l1ss";
	case PciExtCapPTM:	return "ptm";
	case PciExtCapDLF:	return "dlf";
	case PciExtCapPL16:	return "pl16";
	}
	return "unknown";
}

/*
 * The device/port type from the PCI Express capability, or -1 for a
 * conventional PCI function.
 */
int
pcieporttype(Pcidev *p)
{
	int off;

	if((off = pcicap(p, PciCapPCIe)) < 0)
		return -1;
	return (pcicfgr16(p, off+PcieCAP) >> 4) & 0xF;
}

/*
 * Find a function's SR-IOV capability and measure its VF BARs, once,
 * while the bus is scanned.  Sizing is the standard write of all ones
 * and read back, and the specification permits it only while VF
 * memory space is disabled; firmware leaves it so, and if it has not,
 * the sizes stay 0 rather than disturb running VFs.  Each write and
 * its restore are under the configuration lock, as pcibarsize() does.
 * After this nothing reads the capability by writing to it.
 */
void
pcisriovscan(Pcidev *p)
{
	int off, i, r;
	u32int v, sz, hi, szhi;
	uvlong size;

	if((off = pciextcap(p, PciExtCapSRIOV)) < 0)
		return;
	p->sriov = off;
	if(pcicfgr16(p, off+SriovCTL) & SriovMSE)
		return;
	for(i = 0; i < 6; i++){
		r = off + SriovBAR0 + 4*i;
		ilock(&pcicfglock);
		v = pcicfgrw32(p->tbdf, r, 0, 1);
		pcicfgrw32(p->tbdf, r, ~0, 0);
		sz = pcicfgrw32(p->tbdf, r, 0, 1);
		pcicfgrw32(p->tbdf, r, v, 0);
		szhi = ~0;
		if(((v >> Barwidthshift) & Barwidthmask) == Barwidth64 && i < 5){
			hi = pcicfgrw32(p->tbdf, r+4, 0, 1);
			pcicfgrw32(p->tbdf, r+4, ~0, 0);
			szhi = pcicfgrw32(p->tbdf, r+4, 0, 1);
			pcicfgrw32(p->tbdf, r+4, hi, 0);
		}
		iunlock(&pcicfglock);
		size = ((uvlong)szhi << 32) | (sz & ~0xF);
		if((sz & ~0xF) != 0)
			p->vfbarsize[i] = -size;
		if(((v >> Barwidthshift) & Barwidthmask) == Barwidth64)
			i++;
	}
}

/*
 * Read the SR-IOV capability into s.  Only reads: the VF BAR sizes
 * come from pcisriovscan().  Mechanism only: nothing here enables a
 * VF or changes NumVFs.
 */
int
pcisriov(Pcidev *p, Pcisriov *s)
{
	int off, i, r;
	u32int v;

	memset(s, 0, sizeof *s);
	if((off = p->sriov) == 0)
		return -1;
	s->off = off;
	s->cap = pcicfgr32(p, off+SriovCAP);
	s->ctl = pcicfgr16(p, off+SriovCTL);
	s->sts = pcicfgr16(p, off+SriovSTS);
	s->initialvfs = pcicfgr16(p, off+SriovINITIAL);
	s->totalvfs = pcicfgr16(p, off+SriovTOTAL);
	s->numvfs = pcicfgr16(p, off+SriovNUM);
	s->fdl = pcicfgr8(p, off+SriovFDL);
	s->vfoffset = pcicfgr16(p, off+SriovOFFSET);
	s->vfstride = pcicfgr16(p, off+SriovSTRIDE);
	s->vfdid = pcicfgr16(p, off+SriovVFDID);
	s->pgsup = pcicfgr32(p, off+SriovPGSUP);
	s->pgsize = pcicfgr32(p, off+SriovPGSIZE);
	for(i = 0; i < 6; i++){
		r = off + SriovBAR0 + 4*i;
		v = pcicfgr32(p, r);
		s->vfbar[i].is64 = ((v >> Barwidthshift) & Barwidthmask) == Barwidth64;
		s->vfbar[i].bar = v & ~0xFULL;
		if(s->vfbar[i].is64 && i < 5)
			s->vfbar[i].bar |= (uvlong)pcicfgr32(p, r+4) << 32;
		s->vfbar[i].size = p->vfbarsize[i];
		if(s->vfbar[i].is64)
			i++;
	}
	return 0;
}

/*
 * The routing ID (bus<<8 | devfn) of VF vf, counting from 0, by the
 * offset and stride the PF reports for its current NumVFs.  The VF
 * may be on a bus number above the PF's.
 */
int
pcivfrid(Pcidev *p, Pcisriov *s, int vf)
{
	int rid;

	rid = (BUSBNO(p->tbdf)<<8) | (BUSDNO(p->tbdf)<<3) | BUSFNO(p->tbdf);
	return (rid + s->vfoffset + vf*s->vfstride) & 0xFFFF;
}

/*
 * Enable n VFs on PF p, or none with n 0, and keep the PCI list in
 * step: each VF found is added as a function of its own, with its BARs
 * the PF's VF BARs offset by its index (they are already assigned --
 * firmware assigns VF BARs, and this kernel does not move BARs).  VFs
 * are on the PF's bus here; a VF the offset and stride put on a bus
 * above it is not enumerated.  Returns nil, or what went wrong.
 *
 * In process context: it sleeps the 100 ms the specification wants
 * between VF Enable and the first configuration access to a VF.
 */
void (*pcidevadded)(Pcidev*);

char*
pcisriovenable(Pcidev *p, int n)
{
	Pcisriov s;
	Pcidev *v, *q, **l;
	int i, j, off, ctl, rid, pcie, ari;
	u32int cls;

	if(p->pf != nil)
		return "a VF has no SR-IOV of its own";
	if(pcisriov(p, &s) < 0)
		return "no SR-IOV capability";
	if(n < 0 || n > s.totalvfs)
		return "more VFs than TotalVFs";
	off = s.off;
	ctl = pcicfgr16(p, off+SriovCTL);
	if((ctl & SriovVFE) && s.numvfs == n)
		return nil;

	/* off first: NumVFs may change only with VF Enable clear */
	if(ctl & SriovVFE){
		pcicfgw16(p, off+SriovCTL, ctl & ~(SriovVFE|SriovMSE));
		for(q = pcilist; q != nil; q = v){
			v = q->list;
			if(q->pf == p)
				pcidevfree(q);
		}
		tsleep(&up->sleep, return0, nil, 100);
	}
	if(n == 0){
		pcicfgw16(p, off+SriovNUM, 0);
		return nil;
	}

	/*
	 * ARI Capable Hierarchy, in the lowest-numbered PF, when the port
	 * above forwards ARI: it changes the offset and stride, so it is
	 * set before they are read.
	 */
	ari = 0;
	if(p->parent != nil && (pcie = pcicap(p->parent, PciCapPCIe)) >= 0)
		ari = (pcicfgr16(p->parent, pcie+PcieDEVCTL2) & PcieAriFwd) != 0;
	ctl = pcicfgr16(p, off+SriovCTL) & ~(SriovVFE|SriovMSE);
	if(BUSFNO(p->tbdf) == 0){
		if(ari)
			ctl |= SriovARI;
		else
			ctl &= ~SriovARI;
		pcicfgw16(p, off+SriovCTL, ctl);
	}
	pcicfgw16(p, off+SriovNUM, n);
	if(pcisriov(p, &s) < 0 || s.numvfs != n)
		return "NumVFs did not take";
	pcicfgw16(p, PciPCR, pcicfgr16(p, PciPCR) | MEMen);
	pcicfgw16(p, off+SriovCTL, ctl | SriovVFE | SriovMSE);
	tsleep(&up->sleep, return0, nil, 100);

	for(i = 0; i < n; i++){
		rid = pcivfrid(p, &s, i);
		if((rid >> 8) != BUSBNO(p->tbdf))
			continue;
		v = pcidevalloc();
		memset(v, 0, sizeof *v);
		v->tbdf = MKBUS(BusPCI, rid >> 8, (rid >> 3) & 0x1F, rid & 7);
		cls = pcicfgr32(v, PciRID);
		if(cls == ~0){
			print("pci: %T VF %d at %T does not answer\n", p->tbdf, i, v->tbdf);
			continue;
		}
		v->vid = p->vid;		/* a VF's own ID registers read 0xFFFF */
		v->did = s.vfdid;
		v->rid = cls;
		v->ccrp = cls >> 8;
		v->ccru = cls >> 16;
		v->ccrb = cls >> 24;
		v->pcr = pcicfgr16(v, PciPCR);
		v->intl = 0xFF;
		for(j = 0; j < 6; j++){
			if(s.vfbar[j].size == 0)
				continue;
			/* the low bits -- width, prefetchability -- as the PF's VF BAR has them */
			v->mem[j].bar = (s.vfbar[j].bar + i*s.vfbar[j].size)
				| (pcicfgr32(p, off + SriovBAR0 + 4*j) & 0xF);
			v->mem[j].size = s.vfbar[j].size;
		}
		v->pf = p;
		v->vfindex = i;
		v->parent = p->parent;
		if(p->parent != nil){
			for(l = &p->parent->bridge; *l != nil; l = &(*l)->link)
				;
			*l = v;
		}
		*pcitail = v;
		pcitail = &v->list;
		if(pcidevadded != nil)
			pcidevadded(v);
	}
	return nil;
}
