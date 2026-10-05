/*
 * The platform a RISC-V guest sees (port/vm.h's vmplat*), under the
 * H-extension backend (vmrv.c).
 *
 * On RISC-V the firmware is the platform: a supervisor reaches its
 * console, its timer and its power through the SBI, by ecall, and here
 * the kernel is that SBI -- a VS-mode ecall comes back as an exit and
 * is answered on the vCPU's processor, without a trip to Limbo:
 *
 *	base (0x10)	spec 2.0, this implementation, and probe
 *	legacy 0 to 7	set_timer, console putchar and getchar, the
 *			IPI and remote fences
 *	TIME		set_timer
 *	DBCN		the debug console: write, read, write_byte
 *	IPI, RFENCE	between the harts
 *	HSM		hart_start and hart_get_status
 *	SRST, legacy 8	system reset: not answered here, but handed up
 *			to Limbo as a shutdown exit
 *
 * Beside it is a 16550 (port/vuart.c) at guest-physical 0x10000000,
 * where QEMU's virt machine has one, with no interrupt: Linux's 8250
 * polls a port that has none.  Its loads and stores fault in the G
 * stage and are done here: the access is mtinst's transformed
 * instruction where the processor gives one, else the instruction
 * itself, read from the guest through its own page tables.  The
 * SBI's console and the UART are one console, the machine's console
 * file.
 *
 * A PLIC with one context, the hart's supervisor (hvip.VSEIP), takes
 * the lines of virtio-mmio devices (port/vmvirtio.c) in windows from
 * 0x10001000 on sources from 1, where QEMU's virt machine has its.
 *
 * With AIA, a PCI bus (port/vmpci.c) for functions assigned to the
 * guest: its configuration space in an ECAM window at 0x30000000,
 * where QEMU's virt machine has one, its BARs from 0x40000000, and
 * the functions' MSI-X messages sent on into the guest's interrupt
 * files (vmplatmsi).  Their DMA goes through an IOMMU domain that maps
 * guest-physical addresses onto the guest's memory.
 *
 * The guest's timer is hvip.VSTIP, made pending when the time the
 * guest asked for has come; a WFI with the timer armed sleeps until
 * then, or until console input comes.  A WFI with nothing that could
 * wake it goes up to Limbo.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/vm.h"
#include	"../port/vuart.h"
#include	"../port/vmvirtio.h"
#include	"../port/pci.h"
#include	"../port/iommu.h"
#include	"../port/vmpci.h"
#include	"vmrv.h"

enum {
	Uartbase	= 0x10000000,
	Uartlen		= 0x100,
	Plicbase	= 0x0C000000,
	Pliclen		= 0x600000,
	Nsrc		= 32,		/* sources 1 to 31 */
	Virtiobase	= 0x10001000,	/* window n at Virtiobase + 0x1000*n, on source 1+n */
	Nvirtio		= 8,

	/* AIA, where the processor has IMSIC guest files */
	Aplicbase	= 0x0D000000,	/* an APLIC domain, MSI delivery */
	Apliclen	= 0x8000,
	Imsicbase	= 0x28000000,	/* hart h's interrupt file at Imsicbase + 0x1000*h */

	/* the PCI bus of assigned functions, with AIA */
	Ecambase	= 0x30000000,	/* bus 0 alone */
	Ecamlen		= 0x100000,
	Pcimembase	= 0x40000000,	/* the BARs' window */
	Pcimemend	= 0x80000000,

	/* SBI extensions */
	Xsettimer	= 0x00,
	Xputchar	= 0x01,
	Xgetchar	= 0x02,
	Xshutdown	= 0x08,
	Xbase		= 0x10,
	Xtime		= 0x54494D45,
	Xdbcn		= 0x4442434E,
	Xsrst		= 0x53525354,
	Xipi		= 0x735049,
	Xrfence		= 0x52464E43,
	Xhsm		= 0x48534D,
	Xclearipi	= 0x03,
	Xsendipi	= 0x04,
	Xfencei		= 0x05,
	Xsfencevma	= 0x06,
	Xsfencevmaasid	= 0x07,

	/* SBI errors */
	Enotsupp	= -2,
	Einvalparam	= -3,

	Implid		= 0x494E46,	/* "INF", for whoever asks */

	/* remote fences, as Plat.fence's bits */
	Fencei		= 1,
	Fencevma	= 2,

	/* vsie, in the S positions */
	Stie		= 1<<5,
	Seie		= 1<<9,
	Ssie		= 1<<1,
};

typedef struct Plat Plat;
struct Plat
{
	Lock;
	int	hungup;
	Rendez	consr;		/* readers of the console wait here */
	Vuart	uart;		/* and the SBI's console is its too */
	uvlong	timer[Maxvcpu];	/* when each vCPU's timer fires; ~0 off */
	int	kick[Maxvcpu];	/* wake from WFI */
	uvlong	nsbi;
	uvlong	nin;		/* console input taken, all told */

	/* the PLIC: one context, the hart's supervisor */
	u32int	prio[Nsrc];
	u32int	level;		/* lines up */
	u32int	pend;		/* pending, by source */
	u32int	claimed;	/* claimed and not yet completed */
	u32int	enable;
	u32int	thresh;
	int	eip;		/* the context's interrupt: hvip.VSEIP */
	uvlong	nclaim;

	void	*virt[Nvirtio];	/* virtio-mmio devices (port/vmvirtio.c) */
	int	nvirt;

	/* harts: the SBI's HSM, and IPIs between them */
	int	started[Maxvcpu];	/* hart 0 by "go", the rest by hart_start */
	int	startreq[Maxvcpu];	/* a hart_start for it, not yet taken up */
	uvlong	startpc[Maxvcpu];
	uvlong	startarg[Maxvcpu];
	int	ssip[Maxvcpu];		/* an IPI for it, for its hvip */
	int	fence[Maxvcpu];		/* fences it owes before its next entry: Fencei, Fencevma */
	uvlong	nipi;

	/* the APLIC, AIA's in place of the PLIC */
	int	aia;			/* the processor has a guest file for every hart */
	int	gfile[Maxvcpu];		/* hart h's guest file on its processor (gfilepage); the guest sees it at Imsicbase + 0x1000*h */
	u32int	domaincfg;
	u32int	srccfg[Nsrc];
	u32int	target[Nsrc];
	u32int	aie;			/* enabled, by source */
	u32int	aip;			/* pending, by source */
	u32int	msiaddr[4];		/* mmsiaddrcfg, h; smsiaddrcfg, h: kept, not used */
	uvlong	nmsi;
	uvlong	nrx;		/* and read by the guest from the UART */

	void	*pci;		/* port/vmpci.c's bus, with AIA */
	uvlong	npcimsi;	/* messages from assigned functions */
	uvlong	npcimsilost;	/* to no hart's file */
};

#define	PLAT(vm)	((Plat*)(vm)->plat)

static void	plicirq(Vm*, int, int);
static void	apliclevel(Plat*, Vm*, int, int);
extern uintptr	guestimsic;
extern int	guestbits;
static uvlong	reg(Vcpu*, int);
static void	setreg(Vcpu*, int, uvlong);
extern void	rvhfencevvma(void);
extern void	rvfencei(void);
static void	rvfences(int);
static void	remotefences(Vcpu*, Plat*, uvlong, uvlong, int);

void*
vmplatnew(Vm *vm)
{
	Plat *p;
	int i;

	p = malloc(sizeof *p);
	if(p == nil)
		error(Enomem);
	for(i = 0; i < Maxvcpu; i++)
		p->timer[i] = ~0ULL;
	vuartreset(&p->uart);
	vvirq = plicirq;	/* the virtio devices' lines */
	p->aia = guestimsic != 0;
	if(p->aia){
		if(waserror()){
			free(p);
			nexterror();
		}
		p->pci = vmpcinew(vm, Pcimembase, Pcimemend);
		poperror();
	}
	return p;
}

void
vmplathangup(Vm *vm)
{
	Plat *p;
	int i;

	p = PLAT(vm);
	if(p == nil)
		return;
	p->hungup = 1;
	wakeup(&p->consr);
	/* the devices stop using the guest's memory before it goes */
	for(i = 0; i < p->nvirt; i++)
		vvstop(p->virt[i]);
	vmpcistop(p->pci);
}

void
vmplatfree(Vm *vm)
{
	Plat *p;
	int i;

	p = PLAT(vm);
	if(p != nil){
		for(i = 0; i < p->nvirt; i++)
			vvfree(p->virt[i]);
		vmpcifree(p->pci);
	}
	free(vm->plat);
	vm->plat = nil;
}

/*
 * The PLIC (SiFive's, as Linux's irq-sifive-plic drives it), with one
 * context, the hart's supervisor, whose interrupt is hvip.VSEIP.
 * Sources are level-triggered, as virtio-mmio's are: a line that is up
 * is pending unless claimed, and pending again at completion if it is
 * still up.
 */
static void
plicupdate(Plat *p)
{
	u32int m;
	int i;

	m = p->pend & p->enable;
	p->eip = 0;
	for(i = 1; i < Nsrc; i++)
		if((m & 1<<i) && p->prio[i] > p->thresh)
			p->eip = 1;
}

/*
 * Make vCPU h look at its interrupts again: wake it if it sleeps in a
 * WFI, and poke its processor if that is another one, so that a vCPU
 * in the guest there exits now rather than at that processor's next
 * tick (hartpoke).
 */
static void
kickvcpu(Plat *p, Vm *vm, int h)
{
	p->kick[h] = 1;
	wakeup(&vm->vcpu[h]->r);
	hartpoke(vm->vcpu[h]->machno);
}

/*
 * Hart h's guest interrupt file: number gfile[h] of the supervisor-level
 * IMSIC of the processor it runs on, each processor's IMSIC 2^guestbits
 * pages from the last (QEMU's virt; the device tree gives the bits).
 */
static volatile u32int*
gfilepage(Plat *p, Vm *vm, int h)
{
	return (volatile u32int*)(guestimsic
		+ ((uintptr)vm->vcpu[h]->machno << (guestbits + 12))
		+ 0x1000*p->gfile[h]);
}

static void
kickall(Vm *vm)
{
	Plat *p;
	int i;

	p = PLAT(vm);
	for(i = 0; i < vm->nvcpu; i++)
		kickvcpu(p, vm, i);
}

/* vvirq: a device's line, from the vCPU's kproc or a device's own */
static void
plicirq(Vm *vm, int irq, int level)
{
	Plat *p;
	int eip;

	p = PLAT(vm);
	if(p == nil || irq <= 0 || irq >= Nsrc)
		return;
	if(p->domaincfg & 1<<8){	/* the guest has the APLIC on */
		apliclevel(p, vm, irq, level);
		return;
	}
	ilock(p);
	if(level){
		p->level |= 1<<irq;
		if((p->claimed & 1<<irq) == 0)
			p->pend |= 1<<irq;
	}else{
		p->level &= ~(1<<irq);
		p->pend &= ~(1<<irq);
	}
	plicupdate(p);
	eip = p->eip;
	iunlock(p);
	if(eip)
		kickall(vm);
}

static int
plicmmio(Plat *p, uvlong off, int write, u32int *val)
{
	int i, best;

	ilock(p);
	if(off < 4*Nsrc){
		i = off/4;
		if(write){
			if(i > 0)
				p->prio[i] = *val & 7;
		}else
			*val = p->prio[i];
	}else if(off == 0x1000){
		if(!write)
			*val = p->pend;
	}else if(off == 0x2000){
		if(write)
			p->enable = *val & ~1;
		else
			*val = p->enable;
	}else if(off == 0x200000){
		if(write)
			p->thresh = *val & 7;
		else
			*val = p->thresh;
	}else if(off == 0x200004){
		if(write){
			/* completion: a line still up is pending again */
			i = *val;
			if(i > 0 && i < Nsrc && (p->claimed & 1<<i)){
				p->claimed &= ~(1<<i);
				if(p->level & 1<<i)
					p->pend |= 1<<i;
			}
		}else{
			best = 0;
			for(i = 1; i < Nsrc; i++)
				if((p->pend & p->enable & 1<<i) && p->prio[i] > 0
				&& (best == 0 || p->prio[i] > p->prio[best]))
					best = i;
			if(best){
				p->pend &= ~(1<<best);
				p->claimed |= 1<<best;
				p->nclaim++;
			}
			*val = best;
		}
	}else if(!write)
		*val = 0;
	plicupdate(p);
	iunlock(p);
	return 1;
}

/*
 * The APLIC, for a guest given AIA: one domain in MSI delivery mode
 * (the AIA specification, chapter 4).  A source that becomes pending
 * while enabled is sent as a message straight into the target hart's
 * IMSIC guest file -- its identity written to the file's seteipnum --
 * which the processor then delivers to the guest; the hart is woken in
 * case it waits.  Level-high sources are pending when they rise or
 * when setipnum names them while still up (how Linux retriggers one at
 * EOI); edge sources when they rise.  The guest's MSI address
 * configuration is kept, not used: target hart h's file is the one
 * mapped at Imsicbase + 0x1000*h.
 */
enum {
	Asourcecfg	= 0x0004,
	Asetip		= 0x1C00,
	Asetipnum	= 0x1CDC,
	Ainclrip	= 0x1D00,
	Aclripnum	= 0x1DDC,
	Asetie		= 0x1E00,
	Asetienum	= 0x1EDC,
	Aclrie		= 0x1F00,
	Aclrienum	= 0x1FDC,
	Asetipnumle	= 0x2000,
	Agenmsi		= 0x3000,
	Atarget		= 0x3004,
};

static void
sendmsi(Plat *p, Vm *vm, int src)
{
	u32int t;
	int h;

	t = p->target[src];
	h = t >> 18;
	p->aip &= ~(1<<src);
	if(h >= vm->nvcpu)
		return;		/* nowhere to send it */
	*gfilepage(p, vm, h) = t & 0x7FF;
	coherence();
	p->nmsi++;
	kickvcpu(p, vm, h);
}

/* source src pending: sent at once if the domain and source allow */
static void
aplicpend(Plat *p, Vm *vm, int src)
{
	p->aip |= 1<<src;
	if((p->domaincfg & 1<<8) && (p->aie & 1<<src))
		sendmsi(p, vm, src);
}

static int
aplicactive(Plat *p, int src)
{
	int sm;

	sm = p->srccfg[src] & 7;
	return (p->srccfg[src] & 1<<10) == 0 && sm >= 4;	/* not delegated, an edge or level mode */
}

static void
apliclevel(Plat *p, Vm *vm, int irq, int level)
{
	int was;

	ilock(p);
	was = (p->level >> irq) & 1;
	if(level)
		p->level |= 1<<irq;
	else
		p->level &= ~(1<<irq);
	if(aplicactive(p, irq) && level && !was)
		aplicpend(p, vm, irq);
	iunlock(p);
}

static int
aplicmmio(Plat *p, Vm *vm, uvlong off, int write, u32int *val)
{
	int i, n;
	u32int v;

	ilock(p);
	v = write ? *val : 0;
	if(off == 0){
		if(write)
			p->domaincfg = v & (1<<8 | 1<<2);
		else
			v = 0x80000000 | p->domaincfg | 1<<2;	/* MSI delivery only */
	}else if(off >= Asourcecfg && off < Asourcecfg + 4*(Nsrc-1)){
		i = (off - Asourcecfg)/4 + 1;
		if(write){
			p->srccfg[i] = v & 0x7FF;
			if(!aplicactive(p, i)){
				p->aie &= ~(1<<i);
				p->aip &= ~(1<<i);
			}
		}else
			v = p->srccfg[i];
	}else if(off >= 0x1BC0 && off < 0x1BD0){
		n = (off - 0x1BC0)/4;
		if(write)
			p->msiaddr[n] = v;
		else
			v = p->msiaddr[n];
	}else if(off == Asetip){
		if(write){
			for(i = 1; i < Nsrc; i++)
				if((v & 1<<i) && aplicactive(p, i))
					aplicpend(p, vm, i);
		}else
			v = p->aip;
	}else if(off == Asetipnum || off == Asetipnumle){
		i = v;
		/* a level source is made pending only while it is up */
		if(write && i > 0 && i < Nsrc && aplicactive(p, i)
		&& ((p->srccfg[i] & 7) < 6 || (p->level & 1<<i)))
			aplicpend(p, vm, i);
		if(!write)
			v = 0;
	}else if(off == Ainclrip){
		if(write)
			p->aip &= ~v;
		else
			v = p->level;		/* the rectified inputs */
	}else if(off == Aclripnum){
		if(write && v < Nsrc)
			p->aip &= ~(1<<v);
		if(!write)
			v = 0;
	}else if(off == Asetie){
		if(write){
			for(i = 1; i < Nsrc; i++)
				if((v & 1<<i) && aplicactive(p, i)){
					p->aie |= 1<<i;
					if(p->aip & 1<<i)
						aplicpend(p, vm, i);
				}
		}else
			v = p->aie;
	}else if(off == Asetienum){
		i = v;
		if(write && i > 0 && i < Nsrc && aplicactive(p, i)){
			p->aie |= 1<<i;
			if(p->aip & 1<<i)
				aplicpend(p, vm, i);
		}
		if(!write)
			v = 0;
	}else if(off == Aclrie){
		if(write)
			p->aie &= ~v;
		else
			v = 0;
	}else if(off == Aclrienum){
		if(write && v < Nsrc)
			p->aie &= ~(1<<v);
		if(!write)
			v = 0;
	}else if(off >= Atarget && off < Atarget + 4*(Nsrc-1)){
		i = (off - Atarget)/4 + 1;
		if(write)
			p->target[i] = v & (0x3FFF<<18 | 0x7FF);	/* hart index, identity */
		else
			v = p->target[i];
	}else if(!write)
		v = 0;		/* genmsi, the rest: nothing */
	if(!write)
		*val = v;
	iunlock(p);
	return 1;
}

/*
 * Hart h's IMSIC guest file is file h+1 of this processor's, which it
 * runs with: its IMSIC CSRs reach it in hardware.  Its page in the
 * guest, at Imsicbase + 0x1000*h, is not mapped: a write there -- an
 * IPI from another hart, or an MSI -- comes here (imsicmmio), is put
 * in the file, and wakes the hart, which a write in hardware could not
 * (the guest-external interrupt is supervisor-level, and this kernel
 * runs in machine mode).
 */
static void
aiahart(Vcpu *v, Plat *p)
{
	p->gfile[v->id] = v->id + 1;
	rvvgein(v, v->id + 1);
}

static int
imsicmmio(Plat *p, Vm *vm, uvlong off, int write, u32int *val)
{
	int h;

	h = off / 0x1000;
	off %= 0x1000;
	if(!write){
		*val = 0;
		return 1;
	}
	if(h >= vm->nvcpu || off > 4)
		return 1;
	if(off == 4)	/* seteipnum_be */
		*val = (*val>>24) | (*val>>8 & 0xFF00) | (*val<<8 & 0xFF0000) | *val<<24;
	*gfilepage(p, vm, h) = *val;
	coherence();
	p->nmsi++;
	kickvcpu(p, vm, h);
	return 1;
}

/*
 * An assigned function's MSI-X message, as the guest programmed it:
 * to hart h's interrupt file in the guest's map, the identity in
 * data.  Interrupt context.
 */
void
vmplatmsi(Vm *vm, u32int addr, u32int data)
{
	Plat *p;
	int h;

	p = PLAT(vm);
	p->npcimsi++;
	if(addr < Imsicbase || addr >= Imsicbase + 0x1000*vm->nvcpu || (addr & 0xFFF) != 0){
		p->npcimsilost++;
		return;
	}
	h = (addr - Imsicbase) / 0x1000;
	*gfilepage(p, vm, h) = data;
	coherence();
	kickvcpu(p, vm, h);
}

/*
 * Hart 0 starts from Limbo ("go"); the rest by the SBI's hart_start,
 * which a hart already running makes and the started one's kproc takes
 * up here, on its own processor: at the address it was given, with
 * a0 its hart number and a1 the opaque word, translation off, in
 * supervisor mode -- the SBI's state for a started hart.
 */
int
vmplatsipi(Vcpu *v)
{
	Plat *p;

	p = PLAT(v->vm);
	if(p == nil || !p->startreq[v->id])
		return 0;
	setreg(v, RvPc, p->startpc[v->id]);
	setreg(v, RvA0, v->id);
	setreg(v, RvA1, p->startarg[v->id]);
	setreg(v, RvVsatp, 0);
	setreg(v, RvVsstatus, 0);
	setreg(v, RvVsie, 0);
	p->startreq[v->id] = 0;
	p->started[v->id] = 1;
	return 1;
}

/* there is no INIT on RISC-V: a hart is stopped with the SBI's HSM, by itself */
int
vmplatinit(Vcpu*)
{
	return 0;
}

int
vmplatsipipending(Vcpu *v)
{
	Plat *p;

	p = PLAT(v->vm);
	return p != nil && p->startreq[v->id];
}

/* an IPI for each hart in mask (from base; base ~0 is every hart) */
static void
sendipis(Vcpu *v, Plat *p, uvlong mask, uvlong base)
{
	Vm *vm;
	int h;

	vm = v->vm;
	for(h = 0; h < vm->nvcpu; h++){
		if(base != ~0ULL && (h < base || h - base >= 64 || (mask & 1ULL<<(h - base)) == 0))
			continue;
		p->nipi++;
		if(h == v->id){
			setreg(v, RvHvip, reg(v, RvHvip) | RvVssi);
			continue;
		}
		p->ssip[h] = 1;
		kickvcpu(p, vm, h);
	}
}

/* the SBI's console is the UART's transmitter and receiver */
static void
consput(Plat *p, int c)
{
	u32int v;

	v = c;
	ilock(p);
	vuartio(&p->uart, 0, 0, &v);
	iunlock(p);
}

static int
consget(Plat *p)
{
	u32int lsr, c;

	ilock(p);
	vuartio(&p->uart, 5, 1, &lsr);
	if((lsr & 1) == 0){
		iunlock(p);
		return -1;
	}
	vuartio(&p->uart, 0, 1, &c);
	iunlock(p);
	return c;
}

static uvlong
reg(Vcpu *v, int r)
{
	return vmops->getreg(v, r);
}

static void
setreg(Vcpu *v, int r, uvlong val)
{
	vmops->setreg(v, r, val);
}

static void
settimer(Vcpu *v, Plat *p, uvlong when)
{
	p->timer[v->id] = when;
	/* setting the timer takes back a tick not yet taken */
	setreg(v, RvHvip, reg(v, RvHvip) & ~RvVsti);
}

/*
 * The guest's memory at gpa for n bytes, or nil: the DBCN calls name
 * guest-physical addresses.
 */
static uchar*
gpaptr(Vm *vm, uvlong gpa, uvlong n)
{
	if(gpa >= vm->memsize || n > vm->memsize - gpa)
		return nil;
	return vm->mem + gpa;
}

/* answer an SBI call: 1 if it was, 0 to hand it up */
static int
dosbi(Vcpu *v, Plat *p)
{
	uvlong eid, fid, a0, a1, a2;
	vlong err, val;
	uchar *b;
	int c;
	uvlong i;

	eid = reg(v, RvA7);
	fid = reg(v, RvA6);
	a0 = reg(v, RvA0);
	a1 = reg(v, RvA1);
	a2 = reg(v, RvA2);
	err = 0;
	val = 0;
	p->nsbi++;
	switch(eid){
	case Xsettimer:
		settimer(v, p, a0);
		setreg(v, RvA0, 0);
		goto legacy;
	case Xputchar:
		consput(p, a0);
		wakeup(&p->consr);
		setreg(v, RvA0, 0);
		goto legacy;
	case Xgetchar:
		setreg(v, RvA0, consget(p));
		goto legacy;
	case Xclearipi:
		setreg(v, RvHvip, reg(v, RvHvip) & ~RvVssi);
		setreg(v, RvA0, 0);
		goto legacy;
	case Xsendipi:
		/* a0 is the address of the hart mask; there is hart 0 */
		setreg(v, RvHvip, reg(v, RvHvip) | RvVssi);
		setreg(v, RvA0, 0);
		goto legacy;
	case Xfencei:
	case Xsfencevma:
	case Xsfencevmaasid:
		/* a0 is the address of the hart mask: all of them */
		remotefences(v, p, ~0ULL, ~0ULL, eid == Xfencei ? Fencei : Fencevma);
		setreg(v, RvA0, 0);
		goto legacy;
	case Xshutdown:
		return 0;
	case Xipi:
		if(fid != 0){
			err = Enotsupp;
			break;
		}
		/* hart_mask a0 from hart_mask_base a1; -1 is all of them */
		sendipis(v, p, a0, a1);
		break;
	case Xrfence:
		if(fid > 6){
			err = Enotsupp;
			break;
		}
		/* hart_mask a0 from hart_mask_base a1, as for IPIs */
		remotefences(v, p, a0, a1, fid == 0 ? Fencei : Fencevma);
		break;
	case Xhsm:
		switch(fid){
		case 2:		/* hart_get_status: 0 started, 1 stopped, 3 start pending */
			if(a0 >= v->vm->nvcpu)
				err = Einvalparam;
			else if(a0 == 0 || p->started[a0])
				val = 0;
			else
				val = p->startreq[a0] ? 3 : 1;
			break;
		case 0:		/* hart_start(hart, address, opaque) */
			if(a0 >= v->vm->nvcpu)
				err = Einvalparam;
			else if(a0 == 0 || p->started[a0] || p->startreq[a0])
				err = -6;	/* already available */
			else{
				p->startpc[a0] = a1;
				p->startarg[a0] = a2;
				coherence();
				p->startreq[a0] = 1;
				wakeup(&v->vm->vcpu[a0]->r);
				hartpoke(v->vm->vcpu[a0]->machno);
			}
			break;
		default:
			err = Enotsupp;
		}
		break;
	case Xbase:
		switch(fid){
		case 0:	val = 2<<24; break;	/* spec version 2.0 */
		case 1:	val = Implid; break;
		case 2:	val = 1; break;
		case 3:
			switch(a0){
			case Xbase: case Xtime: case Xdbcn: case Xsrst:
			case Xipi: case Xrfence: case Xhsm:
			case Xsettimer: case Xputchar: case Xgetchar: case Xshutdown:
			case Xclearipi: case Xsendipi: case Xfencei: case Xsfencevma: case Xsfencevmaasid:
				val = 1;
			}
			break;
		case 4: case 5: case 6:	val = 0; break;	/* mvendorid, marchid, mimpid */
		default:	err = Enotsupp;
		}
		break;
	case Xtime:
		if(fid != 0){
			err = Enotsupp;
			break;
		}
		settimer(v, p, a0);
		break;
	case Xdbcn:
		switch(fid){
		case 0:		/* write: a0 bytes at a2:a1 */
			b = gpaptr(v->vm, a2<<32 | (a1 & 0xFFFFFFFF), a0);
			if(b == nil){
				err = Einvalparam;
				break;
			}
			for(i = 0; i < a0; i++)
				consput(p, b[i]);
			wakeup(&p->consr);
			val = a0;
			break;
		case 1:		/* read: up to a0 bytes to a2:a1 */
			b = gpaptr(v->vm, a2<<32 | (a1 & 0xFFFFFFFF), a0);
			if(b == nil){
				err = Einvalparam;
				break;
			}
			for(i = 0; i < a0 && (c = consget(p)) >= 0; i++)
				b[i] = c;
			val = i;
			break;
		case 2:		/* write_byte */
			consput(p, a0);
			wakeup(&p->consr);
			break;
		default:
			err = Enotsupp;
		}
		break;
	case Xsrst:
		if(fid == 0)
			return 0;
		err = Enotsupp;
		break;
	default:
		err = Enotsupp;
	}
	setreg(v, RvA0, err);
	setreg(v, RvA1, val);
legacy:
	setreg(v, RvPc, reg(v, RvPc) + 4);
	return 1;
}

static int
timerdue(Vcpu *v, Plat *p)
{
	return p->timer[v->id] != ~0ULL && rvtime() >= p->timer[v->id];
}

/* the guest's timer interrupt, pending in hvip, once its time has come */
void
vmplatintr(Vcpu *v)
{
	Plat *p;
	int f;

	p = PLAT(v->vm);
	if(p->fence[v->id]){
		ilock(p);
		f = p->fence[v->id];
		p->fence[v->id] = 0;
		iunlock(p);
		rvfences(f);
	}
	if(timerdue(v, p)){
		p->timer[v->id] = ~0ULL;
		setreg(v, RvHvip, reg(v, RvHvip) | RvVsti);
	}
	if(p->aia && p->gfile[v->id] == 0)
		aiahart(v, p);
	if(p->ssip[v->id]){
		p->ssip[v->id] = 0;
		setreg(v, RvHvip, reg(v, RvHvip) | RvVssi);
	}
	/* the PLIC's context is hart 0's */
	if(v->id == 0){
		if(p->eip)
			setreg(v, RvHvip, reg(v, RvHvip) | RvVsei);
		else
			setreg(v, RvHvip, reg(v, RvHvip) & ~RvVsei);
	}
}

static int
wfiwake(void *a)
{
	Vcpu *v;
	Plat *p;

	v = a;
	p = PLAT(v->vm);
	return v->stop || v->quit || v->cmd != nil || p->kick[v->id] || timerdue(v, p)
		|| v->id == 0 && p->eip || p->ssip[v->id]
		|| p->gfile[v->id] && (rvgeip() & 1ULL<<p->gfile[v->id]);
}

static int
dowfi(Vcpu *v, Plat *p)
{
	uvlong ie, now, when;
	long ms;

	ie = reg(v, RvVsie);
	if((ie & (Stie|Seie|Ssie)) == 0)
		return 0;	/* nothing could ever wake it */
	if((reg(v, RvHvip) & RvVsti) != 0 && (ie & Stie) != 0
	|| (reg(v, RvHvip) & RvVssi) != 0 && (ie & Ssie) != 0
	|| v->id == 0 && p->eip && (ie & Seie) != 0
	|| p->ssip[v->id] && (ie & Ssie) != 0
	|| p->gfile[v->id] && (rvgeip() & 1ULL<<p->gfile[v->id]) && (ie & Seie) != 0)
		goto out;	/* already pending */
	when = p->timer[v->id];
	/* with no timer, an external interrupt or an IPI can still wake it */
	if(when == ~0ULL && (ie & (Seie|Ssie)) == 0)
		return 0;
	p->kick[v->id] = 0;
	now = rvtime();
	if(when != ~0ULL && when > now){
		ms = (when - now) / 10000 + 1;	/* QEMU virt's mtime is 10 MHz */
		if(ms > 1000)
			ms = 1000;
	}else if(when == ~0ULL)
		ms = 1000;
	else
		ms = 0;
	if(ms > 0)
		tsleep(&v->r, wfiwake, v, ms);
out:
	setreg(v, RvPc, reg(v, RvPc) + 4);
	return 1;
}

/*
 * A remote fence for the one hart there is, done here: the guest's
 * translations by hfence.vvma (its VMID is the hypervisor's 0), and
 * fence.i for its instruction fetch.
 */
static void
rvfences(int i)
{
	if(i & Fencei)
		rvfencei();
	if(i & Fencevma)
		rvhfencevvma();
}

/*
 * A remote fence: the harts in the mask fence on their own processors.
 * This one fences now; each other owes the fence at its next entry
 * (vmplatintr), and one in the guest on another processor is poked out
 * of it and waited for, since until the call returns it may still use
 * what the fence is to remove, and after, it may not.  One that is not
 * in the guest cannot use anything before it fences.
 */
static void
remotefences(Vcpu *v, Plat *p, uvlong mask, uvlong base, int kind)
{
	Vm *vm;
	Vcpu *t;
	int h, n;

	vm = v->vm;
	for(h = 0; h < vm->nvcpu; h++){
		if(base != ~0ULL && (h < base || h - base >= 64 || (mask & 1ULL<<(h - base)) == 0))
			continue;
		if(h == v->id){
			rvfences(kind);
			continue;
		}
		t = vm->vcpu[h];
		ilock(p);
		p->fence[h] |= kind;
		iunlock(p);
		if(t->machno != m->machno)
			hartpoke(t->machno);
	}
	for(h = 0; h < vm->nvcpu; h++){
		t = vm->vcpu[h];
		if(h == v->id || t->machno == m->machno)
			continue;	/* on this processor it is not running now */
		for(n = 0; p->fence[h] != 0 && rvinguest(t); n++){
			coherence();
			if(n % 1000 == 999)
				hartpoke(t->machno);
		}
	}
}

/*
 * The guest-physical address of a guest virtual one, through the
 * guest's own page tables (vsatp: Sv39, Sv48 or Sv57, or bare);
 * ~0 if it is not mapped.
 */
static uvlong
vswalk(Vcpu *v, uvlong va)
{
	uvlong satp, a, pte, *pp;
	int mode, levels, i;

	satp = reg(v, RvVsatp);
	mode = satp >> 60;
	switch(mode){
	case 0:
		return va;
	case 8:	levels = 3; break;
	case 9:	levels = 4; break;
	case 10:	levels = 5; break;
	default:
		return ~0ULL;
	}
	a = (satp & ((1ULL<<44)-1)) << 12;
	for(i = levels-1; i >= 0; i--){
		pp = (uvlong*)gpaptr(v->vm, a + ((va >> (12+9*i)) & 0x1FF)*8, 8);
		if(pp == nil)
			return ~0ULL;
		pte = *pp;
		if((pte & 1) == 0)
			return ~0ULL;
		a = (pte >> 10) << 12;
		if(pte & (2|8))		/* R or X: a leaf, perhaps a large one */
			return a + (va & ((1ULL<<(12+9*i))-1));
	}
	return ~0ULL;
}

/* the instruction at the guest's pc, and its length; 0 if it cannot be read */
static u32int
fetch(Vcpu *v, int *len)
{
	uvlong pc, gpa;
	uchar *b;
	u32int insn;

	pc = reg(v, RvPc);
	gpa = vswalk(v, pc);
	if(gpa == ~0ULL || (b = gpaptr(v->vm, gpa, 2)) == nil)
		return 0;
	insn = b[0] | b[1]<<8;
	if((insn & 3) != 3){
		*len = 2;
		return insn;
	}
	/* the second half may be on the next page */
	gpa = vswalk(v, pc+2);
	if(gpa == ~0ULL || (b = gpaptr(v->vm, gpa, 2)) == nil)
		return 0;
	*len = 4;
	return insn | (b[0] | b[1]<<8) << 16;
}

/*
 * A load or store as width (bytes), signedness, register and
 * direction, from a 32-bit instruction or a compressed one: the
 * transformed ones mtinst gives are 32-bit loads and stores already.
 */
static int
decode(u32int insn, int len, int *width, int *sign, int *r, int *store)
{
	int f3, op;

	if(len == 2){
		op = insn & 3;
		f3 = (insn >> 13) & 7;
		if(op != 0)
			return 0;
		switch(f3){
		case 2:	*width = 4; *sign = 1; *store = 0; break;	/* c.lw */
		case 3:	*width = 8; *sign = 0; *store = 0; break;	/* c.ld */
		case 6:	*width = 4; *sign = 0; *store = 1; break;	/* c.sw */
		case 7:	*width = 8; *sign = 0; *store = 1; break;	/* c.sd */
		default:
			return 0;
		}
		*r = 8 + ((insn >> 2) & 7);	/* rd' or rs2' */
		return 1;
	}
	op = insn & 0x7F;
	f3 = (insn >> 12) & 7;
	if(op == 0x03){
		if(f3 == 7)
			return 0;
		*width = 1 << (f3 & 3);
		*sign = (f3 & 4) == 0 && f3 != 3;
		*r = (insn >> 7) & 0x1F;
		*store = 0;
		return 1;
	}
	if(op == 0x23){
		if(f3 > 3)
			return 0;
		*width = 1 << f3;
		*sign = 0;
		*r = (insn >> 20) & 0x1F;
		*store = 1;
		return 1;
	}
	return 0;
}

static int
dommio(Vcpu *v, Plat *p, Vmexit *e)
{
	u32int insn, val;
	int len, width, sign, r, store, dev;
	uvlong x;

	if(e->access == 4)
		return 0;
	if(e->gpa >= Uartbase && e->gpa < Uartbase + Uartlen)
		dev = 'u';
	else if(e->gpa >= Plicbase && e->gpa < Plicbase + Pliclen)
		dev = 'p';
	else if(p->aia && e->gpa >= Aplicbase && e->gpa < Aplicbase + Apliclen)
		dev = 'a';
	else if(p->aia && e->gpa >= Imsicbase && e->gpa < Imsicbase + 0x1000*v->vm->nvcpu)
		dev = 'i';
	else if(e->gpa >= Virtiobase && e->gpa < Virtiobase + Nvirtio*Vvmmiosize
	&& (e->gpa - Virtiobase)/Vvmmiosize < p->nvirt)
		dev = 'v';
	else if(p->pci != nil && e->gpa >= Ecambase && e->gpa < Ecambase + Ecamlen)
		dev = 'e';
	else if(p->pci != nil && e->gpa >= Pcimembase && e->gpa < Pcimemend)
		dev = 'b';	/* a trapped page of an assigned function's BAR */
	else
		return 0;
	insn = e->insn;
	if(insn & 1){
		len = (insn & 2) ? 4 : 2;
		insn |= 2;	/* the transformed instruction is a 32-bit one */
		if(!decode(insn, 4, &width, &sign, &r, &store))
			return 0;
	}else{
		insn = fetch(v, &len);
		if(insn == 0 || !decode(insn, len, &width, &sign, &r, &store))
			return 0;
	}
	if(store != (e->access == 2))
		return 0;
	if(dev != 'u'){
		x = store && r != 0 ? reg(v, r) : 0;
		if(dev == 'p' || dev == 'a' || dev == 'i'){
			if(width != 4)
				return 0;
			val = x;
			if(dev == 'p')
				plicmmio(p, e->gpa - Plicbase, store, &val);
			else if(dev == 'a')
				aplicmmio(p, v->vm, e->gpa - Aplicbase, store, &val);
			else
				imsicmmio(p, v->vm, e->gpa - Imsicbase, store, &val);
			x = val;
		}else if(dev == 'e'){
			if(!vmpciecam(p->pci, e->gpa - Ecambase, width, store, &x))
				return 0;
		}else if(dev == 'b'){
			if(!vmpcimmio(p->pci, e->gpa, width, store, &x))
				return 0;
		}else if(!vvmmio(p->virt[(e->gpa - Virtiobase)/Vvmmiosize], e->gpa, width, store, &x))
			return 0;
		if(!store && r != 0){
			if(width < 8)
				x &= (1ULL<<(8*width))-1;
			if(sign && width < 8 && (x & (1ULL<<(8*width-1))))
				x |= ~0ULL << (8*width);
			setreg(v, r, x);
		}
		setreg(v, RvPc, reg(v, RvPc) + len);
		return 1;
	}
	ilock(p);
	if(store){
		x = r == 0 ? 0 : reg(v, r);
		val = x;
		vuartio(&p->uart, e->gpa - Uartbase, 0, &val);
	}else{
		if(e->gpa == Uartbase && (p->uart.lcr & 0x80) == 0 && (p->uart.lsr & 1))
			p->nrx++;
		vuartio(&p->uart, e->gpa - Uartbase, 1, &val);
	}
	iunlock(p);
	if(store)
		wakeup(&p->consr);
	else if(r != 0){
		x = val & ((width >= 8) ? ~0ULL : (1ULL<<(8*width))-1);
		if(sign && width < 8 && (x & (1ULL<<(8*width-1))))
			x |= ~0ULL << (8*width);
		setreg(v, r, x);
	}
	setreg(v, RvPc, reg(v, RvPc) + len);
	return 1;
}

int
vmplatexit(Vcpu *v, Vmexit *e)
{
	Plat *p;

	p = PLAT(v->vm);
	switch(e->kind){
	case VxCall:
		if(dosbi(v, p))
			return 1;
		/* system reset, or the legacy shutdown */
		e->kind = VxShutdown;
		e->raw = reg(v, RvA7) == Xsrst ? reg(v, RvA0) : 0;
		return 0;
	case VxHlt:
		return dowfi(v, p);
	case VxMmio:
		return dommio(v, p, e);
	}
	return 0;
}

/*
 * "virtio blk|net path": a virtio-mmio device, in the next window,
 * on the next of the PLIC's sources (vmlinux(1) describes them in the
 * device tree from what status says).  "assign 0000:bb:dd.f": a PCI
 * function given to the guest, on its PCI bus (AIA only: the
 * functions interrupt by MSI-X, into the guest's interrupt files).
 */
int
vmplatctl(Vm *vm, int nf, char **f)
{
	Plat *p;
	int n;

	p = PLAT(vm);
	if(nf == 3 && strcmp(f[0], "virtio") == 0){
		n = p->nvirt;
		if(n >= Nvirtio)
			error("too many virtio devices");
		p->virt[n] = vvnewmmio(vm, f[1], f[2], n, Virtiobase + n*Vvmmiosize, 1 + n);
		ilock(p);
		p->prio[1+n] = 0;
		iunlock(p);
		coherence();
		p->nvirt = n+1;
		return 1;
	}
	if(nf == 2 && strcmp(f[0], "assign") == 0){
		if(p->pci == nil)
			error("no PCI bus: the guest needs AIA's interrupt files for MSI-X");
		vmpciassign(p->pci, f[1]);
		return 1;
	}
	return 0;
}

static int
consready(void *a)
{
	Plat *p;

	p = a;
	return p->hungup || p->uart.outw != p->uart.outr;
}

long
vmplatconsread(Vm *vm, void *a, long n)
{
	Plat *p;
	uchar *b;
	long i;

	p = PLAT(vm);
	b = a;
	/*
	 * Again until there is something: a wakeup can be stale.  The
	 * guest's store on another processor moves outw and wakes
	 * afterwards, by when this reader may have taken that output
	 * already and slept again -- and a read of nothing is the end of
	 * the file to whoever reads it.
	 */
	for(;;){
		sleep(&p->consr, consready, p);
		if(p->hungup && p->uart.outr == p->uart.outw)
			error(Ehungup);
		ilock(p);
		for(i = 0; i < n && p->uart.outr != p->uart.outw; i++)
			b[i] = p->uart.out[p->uart.outr++ % Uartout];
		iunlock(p);
		if(i > 0)
			return i;
	}
}

long
vmplatconswrite(Vm *vm, void *a, long n)
{
	Plat *p;
	long i;

	p = PLAT(vm);
	ilock(p);
	i = vuartinput(&p->uart, a, n);
	p->nin += i;
	iunlock(p);
	kickall(vm);
	return i;
}

char*
vmplatstatus(Vm *vm, char *s, char *e)
{
	Plat *p;
	int i;

	p = PLAT(vm);
	s = seprint(s, e, "platform sbi calls %llud ipis %llud time %llud\n", p->nsbi, p->nipi, rvtime());
	s = seprint(s, e, "uart ier %#ux lcr %#ux mcr %#ux lsr %#ux fifo %d waiting %d in %llud read %llud out %llud lost %llud\n",
		p->uart.ier, p->uart.lcr, p->uart.mcr, p->uart.lsr, p->uart.rxw - p->uart.rxr,
		p->uart.inw - p->uart.inr, p->nin, p->nrx, p->uart.outw, p->uart.outlost);
	s = seprint(s, e, "plic pend %#ux enable %#ux claimed %#ux thresh %d eip %d claims %llud\n",
		p->pend, p->enable, p->claimed, p->thresh, p->eip, p->nclaim);
	if(p->aia){
		s = seprint(s, e, "aia imsic %#ux files %d aplic %#ux domaincfg %#ux ie %#ux ip %#ux msis %llud geip %#llux",
			Imsicbase, (1<<guestbits)-1, Aplicbase, p->domaincfg, p->aie, p->aip, p->nmsi, rvgeip());
		for(i = 0; i < vm->nvcpu; i++)
			s = seprint(s, e, " hart%d file %d", i, p->gfile[i]);
		s = seprint(s, e, "\n");
	}
	for(i = 0; i < p->nvirt; i++)
		s = vvstatus(p->virt[i], s, e);
	if(p->pci != nil){
		s = seprint(s, e, "pci ecam %#ux %#ux mem %#ux %#ux msis %llud lost %llud\n",
			Ecambase, Ecamlen, Pcimembase, Pcimemend - Pcimembase, p->npcimsi, p->npcimsilost);
		s = vmpcistatus(p->pci, s, e);
	}
	for(i = 0; i < vm->nvcpu; i++)
		if(p->timer[i] != ~0ULL)
			s = seprint(s, e, "vcpu%d timer %llud\n", i, p->timer[i]);
	return s;
}
