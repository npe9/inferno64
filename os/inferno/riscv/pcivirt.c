/*
 * Generic PCI ECAM host for QEMU -M virt (pci-host-ecam-generic).
 * Board mem.h must define PCIECAM, PCIECAMSZ, PCIMMIO, PCIMMIOSZ.
 *
 * Assigns MEM BARs into PCIMMIO and exposes pcimatch() for drivers.
 * Also walks Virtio vendor capabilities (modern transport).
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

enum {
	PciVendor	= 0x00,
	PciCmd		= 0x04,
	PciStatus	= 0x06,
	PciClassRev	= 0x08,
	PciHeaderType	= 0x0E,
	PciBar0		= 0x10,
	PciCapPtr	= 0x34,
	PciIrqLine	= 0x3C,

	PciCmdIo	= 1<<0,
	PciCmdMem	= 1<<1,
	PciCmdMaster	= 1<<2,
	PciStCaps	= 1<<4,

	PciCapId	= 0,
	PciCapNext	= 1,
	PciCapVndr	= 0x09,

	VirtioPciVendor	= 0x1AF4,

	VcapCommon	= 1,
	VcapNotify	= 2,
	VcapIsr		= 3,
	VcapDevice	= 4,
};

#ifndef PCIECAM

void
pciinit(void)
{
}

PciDev*
pcimatch(PciDev*, int, int)
{
	return nil;
}

#else

enum { MAXPCIDEV = 32 };

PciDev	pcidev[MAXPCIDEV];
int	npcidev;

static uintptr	pcimmioalloc;

static uchar*
ecam(int bus, int dev, int fn, int reg)
{
	uintptr a;

	a = (uintptr)PCIECAM
		+ ((uintptr)bus << 20)
		+ ((uintptr)dev << 15)
		+ ((uintptr)fn << 12)
		+ (reg & 0xFFF);
	if(a >= (uintptr)PCIECAM + (uintptr)PCIECAMSZ)
		return nil;
	return (uchar*)a;
}

static u8
pcicfgr8(int bus, int dev, int fn, int reg)
{
	uchar *p;

	p = ecam(bus, dev, fn, reg);
	if(p == nil)
		return 0xFF;
	return *p;
}

static u16
pcicfgr16(int bus, int dev, int fn, int reg)
{
	uchar *p;

	p = ecam(bus, dev, fn, reg);
	if(p == nil)
		return 0xFFFF;
	return *(u16*)p;
}

static u32
pcicfgr32(int bus, int dev, int fn, int reg)
{
	uchar *p;

	p = ecam(bus, dev, fn, reg);
	if(p == nil)
		return 0xFFFFFFFF;
	return *(u32*)p;
}

static void
pcicfgw16(int bus, int dev, int fn, int reg, u16 v)
{
	uchar *p;

	p = ecam(bus, dev, fn, reg);
	if(p != nil)
		*(u16*)p = v;
}

static void
pcicfgw32(int bus, int dev, int fn, int reg, u32 v)
{
	uchar *p;

	p = ecam(bus, dev, fn, reg);
	if(p != nil)
		*(u32*)p = v;
}

static uintptr
barsize(int bus, int dev, int fn, int barreg, u32 *rawp)
{
	u32 raw, size;

	raw = pcicfgr32(bus, dev, fn, barreg);
	*rawp = raw;
	if(raw == 0 || raw == 0xFFFFFFFF)
		return 0;
	if(raw & 1)	/* I/O BAR — skip on virt */
		return 0;
	pcicfgw32(bus, dev, fn, barreg, 0xFFFFFFFF);
	size = pcicfgr32(bus, dev, fn, barreg);
	pcicfgw32(bus, dev, fn, barreg, raw);
	size &= ~0xFUL;
	size = ~size + 1;
	return (uintptr)size;
}

static void
assignbars(PciDev *d)
{
	int i, reg;
	u32 raw;
	uintptr sz, addr;

	for(i = 0; i < 6; i++){
		reg = PciBar0 + 4*i;
		sz = barsize(d->bus, d->dev, d->fn, reg, &raw);
		if(sz == 0){
			d->bar[i].addr = 0;
			d->bar[i].size = 0;
			continue;
		}
		/* 64-bit MEM BAR consumes two slots */
		if((raw & 0x6) == 0x4){
			addr = (pcimmioalloc + (sz-1)) & ~(sz-1);
			if(addr + sz > (uintptr)PCIMMIO + (uintptr)PCIMMIOSZ){
				print("pci: BAR%d no MMIO space\n", i);
				continue;
			}
			pcimmioalloc = addr + sz;
			pcicfgw32(d->bus, d->dev, d->fn, reg, (u32)addr);
			pcicfgw32(d->bus, d->dev, d->fn, reg+4, (u32)(addr>>32));
			d->bar[i].addr = addr;
			d->bar[i].size = (usize)sz;
			d->bar[i+1].addr = 0;
			d->bar[i+1].size = 0;
			i++;
			continue;
		}
		addr = (pcimmioalloc + (sz-1)) & ~(sz-1);
		if(addr + sz > (uintptr)PCIMMIO + (uintptr)PCIMMIOSZ){
			print("pci: BAR%d no MMIO space\n", i);
			continue;
		}
		pcimmioalloc = addr + sz;
		pcicfgw32(d->bus, d->dev, d->fn, reg, (u32)addr | (raw & 0xF));
		d->bar[i].addr = addr;
		d->bar[i].size = (usize)sz;
	}
}

static uchar*
barptr(PciDev *d, int bar, u32 off)
{
	if(bar < 0 || bar >= 6 || d->bar[bar].addr == 0)
		return nil;
	if((uintptr)off >= (uintptr)d->bar[bar].size)
		return nil;
	return (uchar*)(d->bar[bar].addr + off);
}

static void
virtiocaps(PciDev *d)
{
	int cap, next, bar;
	u8 cfgtype;
	u32 off, len, mul;

	d->common = d->notify = d->isr = d->device = nil;
	d->notify_off_mul = 0;

	if((pcicfgr16(d->bus, d->dev, d->fn, PciStatus) & PciStCaps) == 0)
		return;
	cap = pcicfgr8(d->bus, d->dev, d->fn, PciCapPtr);
	for(; cap != 0; cap = next){
		next = pcicfgr8(d->bus, d->dev, d->fn, cap+PciCapNext);
		if(pcicfgr8(d->bus, d->dev, d->fn, cap+PciCapId) != PciCapVndr)
			continue;
		cfgtype = pcicfgr8(d->bus, d->dev, d->fn, cap+3);
		bar = pcicfgr8(d->bus, d->dev, d->fn, cap+4);
		off = pcicfgr32(d->bus, d->dev, d->fn, cap+8);
		len = pcicfgr32(d->bus, d->dev, d->fn, cap+12);
		USED(len);
		switch(cfgtype){
		case VcapCommon:
			d->common = barptr(d, bar, off);
			break;
		case VcapNotify:
			d->notify = barptr(d, bar, off);
			mul = pcicfgr32(d->bus, d->dev, d->fn, cap+16);
			d->notify_off_mul = mul;
			break;
		case VcapIsr:
			d->isr = barptr(d, bar, off);
			break;
		case VcapDevice:
			d->device = barptr(d, bar, off);
			break;
		}
	}
}

static void
pciscan(void)
{
	int bus, dev, fn, i;
	u32 id, class, ht;
	u16 vid, did;
	PciDev *d;

	npcidev = 0;
	pcimmioalloc = (uintptr)PCIMMIO;

	for(bus = 0; bus < 16 && npcidev < MAXPCIDEV; bus++){
		for(dev = 0; dev < 32 && npcidev < MAXPCIDEV; dev++){
			for(fn = 0; fn < 8 && npcidev < MAXPCIDEV; fn++){
				id = pcicfgr32(bus, dev, fn, PciVendor);
				vid = id & 0xFFFF;
				did = id >> 16;
				if(vid == 0xFFFF || vid == 0){
					if(fn == 0)
						break;
					continue;
				}
				class = pcicfgr32(bus, dev, fn, PciClassRev);
				d = &pcidev[npcidev++];
				memset(d, 0, sizeof *d);
				d->bus = bus;
				d->dev = dev;
				d->fn = fn;
				d->vid = vid;
				d->did = did;
				d->class = class >> 8;
				/* QEMU virt gpex: INTx → PLIC 32+(slot+pin)%4 style; best-effort */
				d->irq = 32 + ((dev + pcicfgr8(bus,dev,fn,PciIrqLine)) & 3);

				assignbars(d);
				pcicfgw16(bus, dev, fn, PciCmd,
					PciCmdMem|PciCmdMaster|PciCmdIo);

				if(vid == VirtioPciVendor)
					virtiocaps(d);

				print("pci %d.%d.%d: %04ux/%04ux class %06lux irq %d",
					bus, dev, fn, vid, did, (ulong)d->class, d->irq);
				for(i = 0; i < 6; i++)
					if(d->bar[i].size)
						print(" bar%d=%#p/%#lux", i,
							d->bar[i].addr, (ulong)d->bar[i].size);
				if(d->common)
					print(" virtio-modern");
				print("\n");

				if(fn == 0){
					ht = pcicfgr32(bus, dev, 0, PciHeaderType);
					if(((ht >> 16) & 0x80) == 0)
						break;
				}
			}
		}
	}
}

PciDev*
pcimatch(PciDev *prev, int vid, int did)
{
	int i, start;

	start = 0;
	if(prev != nil){
		start = (int)(prev - pcidev) + 1;
		if(start < 0 || start > npcidev)
			return nil;
	}
	for(i = start; i < npcidev; i++){
		if(vid != 0 && pcidev[i].vid != (u16)vid)
			continue;
		if(did != 0 && pcidev[i].did != (u16)did)
			continue;
		return &pcidev[i];
	}
	return nil;
}

void
pciinit(void)
{
	print("pci ecam %#p size %#lux mmio %#p\n",
		(uintptr)PCIECAM, (ulong)PCIECAMSZ, (uintptr)PCIMMIO);
	pciscan();
}

#endif /* PCIECAM */
