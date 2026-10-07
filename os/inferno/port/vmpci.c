/*
 * The guest's PCI bus, and whole-function assignment (doc/genesize-
 * plan.ms, phase 6).
 *
 * The guest sees one bus: a host bridge at 00:00.0, and each assigned
 * function at 00:N.0, reached through configuration mechanism 1
 * (0xCF8, 0xCFC; vmpciio) on a PC, or through an ECAM window
 * (vmpciecam) where the platform has no I/O ports.  An assigned
 * function's configuration space is the real one's, read and written
 * through, except:
 *
 *	the BARs, which the guest sees at guest-physical addresses this
 *	file chose as firmware would, in the window the platform gave
 *	it, and sizes as the real ones;
 *	the expansion ROM, hidden;
 *	the MSI-X capability's control word, kept here;
 *	the interrupt line, kept here.
 *
 * A memory BAR is mapped uncached in the nested page tables at its
 * guest address onto the real BAR, except the pages holding the MSI-X
 * table: those trap, the table is kept here, and an entry the guest
 * enables and unmasks gets a host vector of its own on the real
 * device, whose handler delivers the guest's message (vmplatmsi).  The
 * function's DMA goes through an IOMMU domain mapping guest-physical
 * addresses onto the guest's memory, so the guest programs the device
 * with guest-physical addresses and it can reach nothing else.
 *
 * When the machine ends (vmpcistop, before its memory is freed), each
 * function it had loses bus
 * mastering, goes from the guest's domain straight into the IOMMU's
 * blocking domain (iommurelease), where DMA it still makes reaches
 * nothing, and is reset by FLR where it has one; it stays blocked
 * until it is assigned again or claimed through #Q.
 *
 * Not done: I/O BARs, MSI (only MSI-X), INTx, extended configuration
 * space (the guest sees 256 bytes, through either), reset on
 * assignment, a reset for functions without FLR, and taking a
 * function back from a host driver -- assign
 * only functions the host has no driver for.  An interrupt raised on
 * a processor other than the vCPU's is seen at the vCPU's next exit,
 * at most a clock tick later; no IPI kicks it out sooner yet.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"../port/pci.h"
#include	"../port/vm.h"
#include	"../port/iommu.h"
#include	"../port/vmpci.h"
#include	"../port/vmvirtio.h"

typedef struct Vpci Vpci;
typedef struct Vpcidev Vpcidev;
typedef struct Vmsix Vmsix;

enum {
	Ndevs		= 8,
	Nvirt		= 8,
	Nmsix		= 64,
};

struct Vmsix
{
	Vpcidev	*d;
	int	i;
	u32int	addrlo, addrhi, data, ctl;
	int	hosted;		/* has a host vector on the real device */
	uvlong	nintr;		/* host interrupts taken for it */
	uvlong	ndrop;		/* of which dropped, masked in the guest's view */
};

struct Vpcidev
{
	Vpci	*bus;
	Pcidev	*p;
	int	dev;		/* guest device number on bus 0 */
	Iodom	*dom;
	Vm	*vm;
	struct {
		uvlong	gpa;
		uvlong	size;
		u32int	flags;	/* the BAR's low bits */
		int	is64;
		u32int	wlo, whi;	/* what the guest last wrote, for sizing */
		int	sizing;
	} bar[6];
	u32int	intline;
	int	msixcap;	/* offset in the real config space, 0 if none */
	int	msixn;
	int	tblbir;
	u32int	tbloff;
	u16int	msixctl;	/* enable 15, function mask 14 */
	Vmsix	msix[Nmsix];
	char	name[KNAMELEN];
};

struct Vpci
{
	Vm	*vm;
	u32int	cf8;
	int	ndev;
	Vpcidev	dev[Ndevs];
	int	nvirt;
	void	*virt[Nvirt];	/* the hypervisor's own functions (vmvirtio.c) */
	int	nextdev;	/* the next device number on bus 0 */
	uvlong	nextbar;
	uvlong	barend;		/* the end of the guest's BAR window */
	uvlong	nmsi;
};

/* a bus whose BARs the guest finds in guest-physical [barbase, barend) */
void*
vmpcinew(Vm *vm, uvlong barbase, uvlong barend)
{
	Vpci *pc;

	pc = mallocz(sizeof *pc, 1);
	if(pc == nil)
		error(Enomem);
	pc->vm = vm;
	pc->nextbar = barbase;
	pc->barend = barend;
	pc->nextdev = 1;
	return pc;
}

static void msixintr(Ureg*, void*);

void
vmpcifree(void *a)
{
	Vpci *pc = a;
	int i;

	if(pc == nil)
		return;
	for(i = 0; i < pc->nvirt; i++)
		vvfree(pc->virt[i]);
	free(pc);
}

/*
 * An assigned function the machine is done with, while its memory is
 * still there (vmpcistop, from killvm): no interrupts, no bus
 * mastering, out of the guest's domain -- which maps memory about to
 * be freed and given to others -- straight into the blocking domain,
 * then reset.
 */
static void
release(Vpcidev *d)
{
	int j, blocked, flr;

	for(j = 0; j < d->msixn; j++)
		if(d->msix[j].hosted){
			pcimsixintrdisable(d->p, j, msixintr, &d->msix[j], d->name);
			d->msix[j].hosted = 0;
		}
	pcicfgw16(d->p, PciPCR, pcicfgr16(d->p, PciPCR) & ~MASen);
	blocked = 0;
	if(d->dom != nil){
		if(!waserror()){
			iommurelease(d->p);
			blocked = 1;
			poperror();
		}else
			print("%s: not blocked: %s\n", d->name, up->errstr);
		if(!waserror()){
			iommudomkill(d->dom);
			poperror();
		}
		d->dom = nil;
	}
	flr = pciflr(d->p);
	print("%s: released: %s, %s\n", d->name,
		blocked ? "blocked" : "NOT blocked", flr ? "reset by FLR" : "no FLR");
}

/*
 * The host's interrupt for one MSI-X entry: deliver the message the
 * guest wrote in that entry.  Interrupt context.
 */
static void
msixintr(Ureg*, void *a)
{
	Vmsix *m;

	m = a;
	m->nintr++;
	if((m->ctl & 1) || (m->d->msixctl & 1<<14)){
		m->ndrop++;
		return;		/* masked in the guest's view: dropped, not pended */
	}
	vmplatmsi(m->d->vm, m->addrlo, m->data);
}

/* bring the host side of entry m into line with the guest's view of it */
static void
msixsync(Vpcidev *d, Vmsix *m)
{
	int on;

	on = (d->msixctl & 1<<15) && !(d->msixctl & 1<<14) && !(m->ctl & 1);
	if(on && !m->hosted){
		if(pcimsixintrenable == nil)
			error("no MSI-X on this machine");
		pcimsixintrenable(d->p, m->i, msixintr, m, d->name);
		m->hosted = 1;
	}else if(m->hosted)
		pcimsixmask(d->p, m->i, !on);
}

static void
mapbar(Vpcidev *d, int i)
{
	Vm *vm;
	uvlong hpa, pg, tlo, thi;

	vm = d->vm;
	if(d->bar[i].size == 0 || d->bar[i].gpa == 0)
		return;
	hpa = d->p->mem[i].bar & ~0xFULL;
	tlo = thi = 0;
	if(d->msixcap && d->tblbir == i){
		tlo = d->tbloff & ~(uvlong)(BY2PG-1);
		thi = (d->tbloff + d->msixn*16 + BY2PG-1) & ~(uvlong)(BY2PG-1);
	}
	for(pg = 0; pg < d->bar[i].size; pg += BY2PG){
		if(pg >= tlo && pg < thi)
			continue;	/* the MSI-X table traps */
		vmops->gpmap(vm, d->bar[i].gpa + pg, hpa + pg, BY2PG, VmR|VmW|VmUC);
	}
}

static void
unmapbar(Vpcidev *d, int i)
{
	if(d->bar[i].size != 0 && d->bar[i].gpa != 0)
		vmops->gpunmap(d->vm, d->bar[i].gpa, (d->bar[i].size + BY2PG-1) & ~(uvlong)(BY2PG-1));
}

/*
 * BAR i of d moves to a: its old pages go, and every BAR on the bus
 * is mapped again, since a guest reprogramming its BARs may have put
 * another where this one was (Linux swapping two does), and taking
 * the old pages away would take that one's too.
 */
static void
movebar(Vpcidev *d, int i, uvlong a)
{
	Vpci *pc;
	int j, k;

	unmapbar(d, i);
	d->bar[i].gpa = a;
	pc = d->bus;
	for(j = 0; j < pc->ndev; j++)
		for(k = 0; k < 6; k++)
			mapbar(&pc->dev[j], k);
}

void
vmpciassign(void *arg, char *bdf)
{
	Vpci *pc = arg;
	char *f[4], *s;
	Pcidev *p;
	Vpcidev *d;
	Vm *vm;
	int i, n, off;
	uvlong size, a;

	vm = pc->vm;
	if(vm->mem == nil)
		error("give the machine memory before assigning a device");
	if(pc->ndev >= Ndevs)
		error("too many assigned devices");
	if(pc->nextdev > 31)
		error("guest PCI bus full");
	s = strdup(bdf);
	if(waserror()){
		free(s);
		nexterror();
	}
	n = getfields(s, f, nelem(f), 0, ":.");
	if(n != 4 || strtol(f[0], nil, 16) != 0)
		error("bad PCI address");
	p = pcimatchtbdf(MKBUS(BusPCI, strtol(f[1], nil, 16), strtol(f[2], nil, 16), strtol(f[3], nil, 16)));
	poperror();
	free(s);
	if(p == nil)
		error("no such PCI function");
	if((pcicfgr8(p, PciHDT) & 0x7F) != 0)
		error("not an endpoint");
	for(i = 0; i < pc->ndev; i++)
		if(pc->dev[i].p == p)
			error("already assigned");

	d = &pc->dev[pc->ndev];
	memset(d, 0, sizeof *d);
	d->bus = pc;
	d->p = p;
	d->vm = vm;
	d->dev = pc->nextdev;
	snprint(d->name, sizeof d->name, "vm%d.%T", vm->id, p->tbdf);

	/* the BARs: same sizes, guest addresses chosen here */
	for(i = 0; i < 6; i++){
		if(p->mem[i].size == 0)
			continue;
		if(p->mem[i].bar & 1)
			error("an I/O BAR: not supported");
		size = p->mem[i].size;
		if(size < BY2PG)
			size = BY2PG;
		d->bar[i].size = p->mem[i].size;
		d->bar[i].flags = pcicfgr32(p, PciBAR0 + 4*i) & 0xF;
		d->bar[i].is64 = ((d->bar[i].flags >> 1) & 3) == 2;
		a = (pc->nextbar + size - 1) & ~(size - 1);
		d->bar[i].gpa = a;
		pc->nextbar = a + size;
		if(d->bar[i].is64)
			i++;
	}
	if(pc->nextbar > pc->barend)
		error("guest BAR space exhausted");

	/* MSI-X: where the table is */
	off = pcicap(p, PciCapMSIX);
	if(off >= 0){
		d->msixcap = off;
		d->msixn = (pcicfgr16(p, off+2) & 0x7FF) + 1;
		if(d->msixn > Nmsix)
			error("too many MSI-X vectors");
		d->tblbir = pcicfgr32(p, off+4) & 7;
		d->tbloff = pcicfgr32(p, off+4) & ~7;
		for(i = 0; i < d->msixn; i++){
			d->msix[i].d = d;
			d->msix[i].i = i;
			d->msix[i].ctl = 1;	/* masked, as at reset */
		}
	}

	/* DMA: guest-physical addresses onto the guest's memory, nothing else */
	d->dom = iommudomain();
	if(waserror()){
		iommudomkill(d->dom);
		nexterror();
	}
	iommudommap(d->dom, 0, PADDR(vm->mem), vm->memsize, IoR|IoW);
	iommudomattach(d->dom, p);
	poperror();

	/* the device starts quiet: no bus mastering until the guest's driver asks */
	pcicfgw16(p, PciPCR, (pcicfgr16(p, PciPCR) | MEMen) & ~MASen);
	for(i = 0; i < 6; i++)
		mapbar(d, i);
	pc->ndev++;
	pc->nextdev++;
	print("vm%d: %T assigned as 00:%.2d.0\n", vm->id, p->tbdf, d->dev);
}

/* a virtio function of the hypervisor's own: "virtio blk /path" */
void
vmpcivirtio(void *arg, char *kind, char *path)
{
	Vpci *pc = arg;
	uvlong a;

	if(pc->vm->mem == nil)
		error("give the machine memory before adding a device");
	if(pc->nvirt >= Nvirt || pc->nextdev > 31)
		error("too many virtio devices");
	a = (pc->nextbar + Vvbarsize - 1) & ~(uvlong)(Vvbarsize - 1);
	if(a + Vvbarsize > pc->barend)
		error("guest BAR space exhausted");
	pc->virt[pc->nvirt] = vvnew(pc->vm, kind, path, pc->nextdev, a);
	pc->nvirt++;
	pc->nextdev++;
	pc->nextbar = a + Vvbarsize;
	print("vm%d: virtio %s %s as 00:%.2d.0\n", pc->vm->id, kind, path, pc->nextdev - 1);
}

/* stop whatever runs for the bus's devices; the guest's memory is going */
void
vmpcistop(void *arg)
{
	Vpci *pc = arg;
	int i;

	if(pc == nil)
		return;
	for(i = 0; i < pc->nvirt; i++)
		vvstop(pc->virt[i]);
	for(i = 0; i < pc->ndev; i++)
		release(&pc->dev[i]);
}

/* a config read of the host bridge: an Intel host bridge, and nothing else */
static u32int
bridgecfg(int reg)
{
	switch(reg){
	case 0x00: return 0x29C08086;
	case 0x08: return 0x06000000;
	case 0x0C: return 0x00000000;
	}
	return 0;
}

static u32int
devcfgread(Vpcidev *d, int reg)
{
	int i;
	u32int v, sz;

	if(reg >= PciBAR0 && reg < PciBAR0 + 24){
		i = (reg - PciBAR0) / 4;
		if(i > 0 && d->bar[i-1].is64 && d->bar[i].size == 0){	/* the high half */
			i--;
			if(d->bar[i].sizing && d->bar[i].whi == 0xFFFFFFFF)
				return ~(u32int)((d->bar[i].size - 1) >> 32);
			return d->bar[i].gpa >> 32;
		}
		if(d->bar[i].size == 0)
			return 0;
		if(d->bar[i].sizing && d->bar[i].wlo == 0xFFFFFFFF){
			sz = d->bar[i].size;
			return ~(sz - 1) | d->bar[i].flags;
		}
		return (u32int)d->bar[i].gpa | d->bar[i].flags;
	}
	if(reg == PciEBAR0)
		return 0;
	if(reg == 0 && d->p->pf != nil)
		return d->p->vid | (u32int)d->p->did << 16;	/* a VF's read all ones: SR-IOV's are in the PF */
	if(reg == 0x3C)
		return (pcicfgr32(d->p, 0x3C) & ~0xFF) | (d->intline & 0xFF);
	v = pcicfgr32(d->p, reg);
	if(d->msixcap && reg == (d->msixcap & ~3))
		v = (v & 0xFFFF) | (u32int)(d->msixctl | (d->msixn - 1)) << 16;
	return v;
}

static void
devcfgwrite(Vpcidev *d, int reg, u32int v, u32int mask)
{
	int i, hi, j;
	u32int old;
	uvlong a;

	if(reg >= PciBAR0 && reg < PciBAR0 + 24){
		i = (reg - PciBAR0) / 4;
		hi = 0;
		if(i > 0 && d->bar[i-1].is64 && d->bar[i].size == 0){
			i--;
			hi = 1;
		}
		if(d->bar[i].size == 0)
			return;
		if(hi)
			d->bar[i].whi = v;
		else
			d->bar[i].wlo = v;
		if(v == 0xFFFFFFFF){
			d->bar[i].sizing = 1;
			return;
		}
		d->bar[i].sizing = 0;
		/* a new address: move the mapping */
		a = d->bar[i].gpa;
		if(hi)
			a = (a & 0xFFFFFFFF) | (uvlong)v << 32;
		else
			a = (a & ~0xFFFFFFFFULL) | (v & ~(u32int)(d->bar[i].size - 1) & ~0xFU);
		if(a != d->bar[i].gpa)
			movebar(d, i, a);
		return;
	}
	if(reg == PciEBAR0)
		return;
	if(reg == 0x3C){
		d->intline = v & 0xFF;
		return;
	}
	if(d->msixcap && reg == (d->msixcap & ~3)){
		if(mask & 0xFFFF0000){
			d->msixctl = (v >> 16) & 0xC000;
			for(j = 0; j < d->msixn; j++)
				msixsync(d, &d->msix[j]);
		}
		v &= 0xFFFF;
		mask &= 0xFFFF;
		if(mask == 0)
			return;
	}
	old = pcicfgr32(d->p, reg);
	pcicfgw32(d->p, reg, (old & ~mask) | (v & mask));
}

/*
 * A configuration access: the 32-bit register reg of bus:dev.fn, the
 * bytes of mask (shifted into place) read or written.
 */
static void
cfgaccess(Vpci *pc, int bus, int dev, int fn, int reg, int write, u32int *val, u32int mask)
{
	Vpcidev *d;
	void *vv;
	int i;

	d = nil;
	vv = nil;
	if(bus == 0 && fn == 0){
		for(i = 0; i < pc->ndev; i++)
			if(pc->dev[i].dev == dev)
				d = &pc->dev[i];
		for(i = 0; i < pc->nvirt; i++)
			if(vvdev(pc->virt[i]) == dev)
				vv = pc->virt[i];
	}
	if(vv != nil){
		if(write)
			vvcfgwrite(vv, reg, *val, mask);
		else
			*val = vvcfgread(vv, reg) & mask;
		return;
	}
	if(!write){
		if(bus != 0 || fn != 0)
			*val = mask;
		else if(dev == 0)
			*val = bridgecfg(reg) & mask;
		else if(d != nil)
			*val = devcfgread(d, reg) & mask;
		else
			*val = mask;
		return;
	}
	if(d != nil)
		devcfgwrite(d, reg, *val, mask);
}

/* configuration mechanism 1: 0xCF8 address, 0xCFC-0xCFF data */
int
vmpciio(void *a, int port, int in, int size, u32int *val)
{
	Vpci *pc = a;
	int sh;
	u32int v, mask;

	if(port == 0xCF8 && size == 4){
		if(in)
			*val = pc->cf8;
		else
			pc->cf8 = *val & 0x80FFFFFC;
		return 1;
	}
	/*
	 * Narrower accesses to 0xCF8-0xCFB are not configuration cycles:
	 * on a PC, 0xCF9 is the reset control register, and Linux's probe
	 * for mechanism 2 writes 0xCFB.  Nothing answers them here: reads
	 * float high and writes go nowhere (a guest asking for a reset
	 * through 0xCF9 does not get one yet).
	 */
	if(port >= 0xCF8 && port <= 0xCFB){
		if(in)
			*val = 0xFFFFFFFF;
		return 1;
	}
	if(port < 0xCFC || port > 0xCFF)
		return 0;
	if((pc->cf8 & 1<<31) == 0){
		if(in)
			*val = 0xFFFFFFFF;
		return 1;
	}
	sh = 8 * (port - 0xCFC);
	mask = (size == 4 ? 0xFFFFFFFF : (1 << 8*size) - 1) << sh;
	v = in ? 0 : *val << sh;
	cfgaccess(pc, (pc->cf8 >> 16) & 0xFF, (pc->cf8 >> 11) & 0x1F, (pc->cf8 >> 8) & 7,
		pc->cf8 & 0xFC, !in, &v, mask);
	if(in)
		*val = v >> sh;
	return 1;
}

/*
 * An access at offset off of an ECAM window (PCIe's enhanced
 * configuration mechanism): bus<<20 | dev<<15 | fn<<12 | register.
 * Registers past the first 256 bytes read as zero and take no writes.
 */
int
vmpciecam(void *a, uvlong off, int size, int write, uvlong *val)
{
	Vpci *pc = a;
	int sh, reg;
	u32int v, mask;

	if(size != 1 && size != 2 && size != 4)
		return 0;
	if(off & (size-1))
		return 0;
	reg = off & 0xFFF;
	if(reg >= 256){
		if(!write)
			*val = 0;
		return 1;
	}
	sh = 8 * (reg & 3);
	mask = (size == 4 ? 0xFFFFFFFF : (1 << 8*size) - 1) << sh;
	v = write ? (u32int)*val << sh : 0;
	cfgaccess(pc, (off >> 20) & 0xFF, (off >> 15) & 0x1F, (off >> 12) & 7, reg & ~3, write, &v, mask);
	if(!write)
		*val = (v & mask) >> sh;
	return 1;
}

/* an access to a trapped page of an assigned function's BAR */
int
vmpcimmio(void *a, uvlong gpa, int size, int write, uvlong *val)
{
	Vpci *pc = a;
	Vpcidev *d;
	Vmsix *m;
	uvlong off;
	uchar *r;
	int i, j, f;

	for(i = 0; i < pc->nvirt; i++)
		if(vvmmio(pc->virt[i], gpa, size, write, val))
			return 1;
	for(i = 0; i < pc->ndev; i++){
		d = &pc->dev[i];
		if(!d->msixcap || d->bar[d->tblbir].gpa == 0)
			continue;
		j = d->tblbir;
		if(gpa < d->bar[j].gpa || gpa + size > d->bar[j].gpa + d->bar[j].size)
			continue;
		off = gpa - d->bar[j].gpa;
		if(off >= d->tbloff && off < d->tbloff + d->msixn*16){
			if(size != 4 && size != 8)
				return 0;
			m = &d->msix[(off - d->tbloff) / 16];
			f = (off - d->tbloff) % 16;
			if(!write){
				switch(f){
				case 0: *val = m->addrlo | (size == 8 ? (uvlong)m->addrhi << 32 : 0); break;
				case 4: *val = m->addrhi; break;
				case 8: *val = m->data | (size == 8 ? (uvlong)m->ctl << 32 : 0); break;
				case 12: *val = m->ctl; break;
				}
				return 1;
			}
			switch(f){
			case 0:
				m->addrlo = *val;
				if(size == 8)
					m->addrhi = *val >> 32;
				break;
			case 4: m->addrhi = *val; break;
			case 8:
				m->data = *val;
				if(size == 8)
					m->ctl = (*val >> 32) & 1;
				break;
			case 12: m->ctl = *val & 1; break;
			}
			if(f >= 8)
				msixsync(d, m);
			return 1;
		}
		/* the rest of a trapped page goes to the device */
		r = vmap((d->p->mem[j].bar & ~0xFULL) + (off & ~(uvlong)(BY2PG-1)), BY2PG);
		if(r == nil)
			return 0;
		r += off & (BY2PG-1);
		switch(size){
		case 1: if(write) *(volatile u8int*)r = *val; else *val = *(volatile u8int*)r; break;
		case 2: if(write) *(volatile u16int*)r = *val; else *val = *(volatile u16int*)r; break;
		case 4: if(write) *(volatile u32int*)r = *val; else *val = *(volatile u32int*)r; break;
		case 8: if(write) *(volatile u64int*)r = *val; else *val = *(volatile u64int*)r; break;
		}
		return 1;
	}
	return 0;
}

char*
vmpcistatus(void *a, char *p, char *e)
{
	Vpci *pc = a;
	Vpcidev *d;
	Vmsix *m;
	int i, j, on;

	if(pc == nil)
		return p;
	for(i = 0; i < pc->nvirt; i++)
		p = vvstatus(pc->virt[i], p, e);
	for(i = 0; i < pc->ndev; i++){
		d = &pc->dev[i];
		p = seprint(p, e, "pci 00:%.2d.0 is %T domain %d", d->dev, d->p->tbdf, d->dom->id);
		for(j = 0; j < 6; j++)
			if(d->bar[j].size != 0)
				p = seprint(p, e, " bar%d %#llux->%#llux", j, d->bar[j].gpa, d->p->mem[j].bar & ~0xFULL);
		on = 0;
		for(j = 0; j < d->msixn; j++)
			on += d->msix[j].hosted;
		p = seprint(p, e, " msix %s%s %d/%d hosted\n", (d->msixctl & 1<<15) ? "on" : "off",
			(d->msixctl & 1<<14) ? " masked" : "", on, d->msixn);
		for(j = 0; j < d->msixn; j++){
			m = &d->msix[j];
			if(!m->hosted && m->addrlo == 0)
				continue;
			p = seprint(p, e, "pci 00:%.2d.0 msix %d guest %#ux/%#ux ctl %d hosted %d intr %llud dropped %llud",
				d->dev, j, m->addrlo, m->data, m->ctl, m->hosted, m->nintr, m->ndrop);
			if(d->p->msixtbl != nil)
				p = seprint(p, e, " host %#ux/%#ux ctl %#ux",
					((u32int*)d->p->msixtbl)[4*j], ((u32int*)d->p->msixtbl)[4*j+2], ((u32int*)d->p->msixtbl)[4*j+3]);
			p = seprint(p, e, "\n");
		}
	}
	return p;
}
