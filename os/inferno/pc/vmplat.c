/*
 * The x86 platform a guest of #H sees (doc/genesize-plan.ms, phase 4):
 *
 *	an 8259 pair, an 8254 on IRQ 0, the console on a 16550 at 0x3F8
 *	(IRQ 4), and a local APIC per vCPU (xAPIC at 0xFEE00000, or
 *	x2APIC if the guest enables it) whose timer runs off the TSC in
 *	one-shot, periodic or TSC-deadline mode.  No RTC, IOAPIC, HPET,
 *	ACPI or MP tables; the kernel is told the TSC rate on its command
 *	line.  The PIT is not optional: with no MP or ACPI configuration
 *	Linux never starts the local APIC's clock (it is set up only in
 *	the configured SMP paths), and the PIT through the 8259 is its
 *	tick -- as on QEMU's microvm with pic=on, pit=on, where the guest
 *	reports "Clock Event Device: pit", and not with pit=off, where it
 *	reaches its shell and then runs nothing typed at it.
 *
 * Everything here runs in the vCPU's kproc on the vCPU's processor,
 * from devvm.c's run loop: CPUID, the MSRs that are not the
 * processor's own, these devices' ports, the APIC's MMIO page, HLT,
 * and choosing the interrupt to inject at each entry.  An exit it does
 * not claim goes up to Limbo.  Ports nothing claims are delivered to
 * Limbo too, unless "io ignore" was written to ctl, when an in reads
 * all ones and an out is dropped, as on a bus with nothing there.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"io.h"
#include	"mp.h"
#include	"../port/vm.h"
#include	"../pc/vm86.h"
#include	"vmdev.h"
#include	"../port/vmpci.h"
#include	"../port/vmvirtio.h"

char *vm86regname[VNreg] = {
[VRax] "rax", [VRbx] "rbx", [VRcx] "rcx", [VRdx] "rdx",
[VRsi] "rsi", [VRdi] "rdi", [VRbp] "rbp", [VRsp] "rsp",
[VR8] "r8", [VR9] "r9", [VR10] "r10", [VR11] "r11",
[VR12] "r12", [VR13] "r13", [VR14] "r14", [VR15] "r15",
[VRip] "rip", [VRflags] "rflags",
[VCr0] "cr0", [VCr2] "cr2", [VCr3] "cr3", [VCr4] "cr4", [VEfer] "efer",
[VCs] "cs", [VCsbase] "csbase", [VCslimit] "cslimit", [VCsattr] "csattr",
[VDs] "ds", [VDsbase] "dsbase", [VDslimit] "dslimit", [VDsattr] "dsattr",
[VEs] "es", [VEsbase] "esbase", [VEslimit] "eslimit", [VEsattr] "esattr",
[VFs] "fs", [VFsbase] "fsbase", [VFslimit] "fslimit", [VFsattr] "fsattr",
[VGs] "gs", [VGsbase] "gsbase", [VGslimit] "gslimit", [VGsattr] "gsattr",
[VSs] "ss", [VSsbase] "ssbase", [VSslimit] "sslimit", [VSsattr] "ssattr",
[VTr] "tr", [VTrbase] "trbase", [VTrlimit] "trlimit", [VTrattr] "trattr",
[VLdtr] "ldtr", [VLdtrbase] "ldtrbase", [VLdtrlimit] "ldtrlimit", [VLdtrattr] "ldtrattr",
[VGdtrbase] "gdtrbase", [VGdtrlimit] "gdtrlimit",
[VIdtrbase] "idtrbase", [VIdtrlimit] "idtrlimit",
};

typedef struct Plat Plat;

struct Plat
{
	Lock;
	Vm	*vm;
	Vpic	pic;
	Vpit	pit;
	Vuart	uart;
	Vioapic	ioapic;
	Vlapic	lapic[Maxvcpu];
	void	*pci;		/* vmpci.c's */
	QLock	pcilk;		/* the PCI bus is not touched under the spin lock */
	int	irqwin[Maxvcpu];
	int	kick[Maxvcpu];	/* something for a halted vCPU to look at */
	int	initwait[Maxvcpu];	/* after INIT, before SIPI: waits to be started */
	int	initreq[Maxvcpu];	/* an INIT for one running: it stops, to wait for SIPI */
	int	sipi[Maxvcpu];	/* a startup IPI's vector, not yet acted on; -1 none */
	int	nmi[Maxvcpu];	/* an NMI sent, not yet delivered */
	u32int	poke;		/* vCPUs to wake once the lock is let go */
	uvlong	nipi;
	int	ioignore;
	uvlong	tschz;
	Rendez	consr;		/* readers of the console wait here */
	int	hungup;

	/* what the kernel handled, for status */
	uvlong	ncpuid, nmsr, nio, nmmio, nhlt, nintr, ngp, nmsi;
	u32int	lastgpmsr;
	int	lastport;
};

enum {
	IF	= 1<<9,
	CR0PG	= 1<<31,
	CR4PAE	= 1<<5,
	CR4PSE	= 1<<4,
	EFERLMA	= 1<<10,
};

#define	PLAT(vm)	((Plat*)(vm)->plat)

/*
 * Taking a vCPU out of guest mode on another processor: a host IPI.
 * The VM exit on it is the point; the handler has nothing to do (the
 * interrupt is not acknowledged on exit, so the host takes it, and
 * EOIs it, as any other once out of the guest).
 */
static void
kickintr(Ureg*, void*)
{
}

static void
kickinit(void)
{
	static int done;

	if(done || conf.nmach < 2)
		return;
	done = 1;
	intrenable(IrqVMKICK, kickintr, nil, BUSUNKNOWN, "vmkick");
}

static int
apicof(int machno)
{
	int i;

	for(i = 0; i <= MaxAPICNO; i++)
		if(mpapic[i] != nil && mpapic[i]->type == PcmpPROCESSOR
		&& mpapic[i]->machno == machno && mpapic[i]->online)
			return mpapic[i]->apicno;
	return -1;
}

/*
 * Wake the vCPUs in p->poke: those sleeping in HLT or waiting for a
 * SIPI, and those in guest mode on another processor, which a host
 * IPI takes out to see what they have been sent.  Not under p's lock.
 */
static void
dopokes(Plat *p)
{
	Vm *vm;
	Vcpu *v;
	u32int poke;
	int i, apic, s;

	ilock(p);
	poke = p->poke;
	p->poke = 0;
	iunlock(p);
	vm = p->vm;
	for(i = 0; poke != 0 && i < vm->nvcpu; i++, poke >>= 1){
		if((poke & 1) == 0 || (v = vm->vcpu[i]) == nil)
			continue;
		wakeup(&v->r);
		if(v->state == VcpuRunning && v->machno != m->machno
		&& (apic = apicof(v->machno)) >= 0){
			s = splhi();	/* the ICR is two writes: not split by another IPI */
			lapicicrw(apic<<24, VectorPIC+IrqVMKICK);
			splx(s);
		}
	}
}

/*
 * An IPI from vCPU src's APIC, as written to its ICR: fixed and
 * lowest-priority interrupts (the latter to the first that matches),
 * NMI, INIT and SIPI; SMI and the rest are not modelled.  p's lock held.
 */
static void
ipi(Plat *p, int src, u32int hi, u32int lo)
{
	Vlapic *a;
	u32int dest;
	int i, mode, sh, logical, vec;

	a = &p->lapic[src];
	mode = (lo >> 8) & 7;
	sh = (lo >> 18) & 3;
	logical = (lo >> 11) & 1;
	vec = lo & 0xFF;
	dest = (a->base & ApicX2) ? hi : hi >> 24;
	if(mode == 5 && (lo & 1<<15) && !(lo & 1<<14))
		return;		/* INIT level de-assert: nothing to do */
	p->nipi++;
	for(i = 0; i < p->vm->nvcpu; i++){
		switch(sh){
		case 0:
			if(!vlapicmatch(&p->lapic[i], dest, logical))
				continue;
			break;
		case 1:
			if(i != src)
				continue;
			break;
		case 3:
			if(i == src)
				continue;
			break;
		}
		switch(mode){
		case 0:		/* fixed */
		case 1:		/* lowest priority */
			vlapicsetirr(&p->lapic[i], vec);
			p->kick[i] = 1;
			p->poke |= 1<<i;
			if(mode == 1)
				return;
			break;
		case 4:		/* NMI */
			p->nmi[i] = 1;
			p->kick[i] = 1;
			p->poke |= 1<<i;
			break;
		case 5:		/* INIT: an application processor waits for SIPI */
			if(i != 0){
				/*
				 * One that is running stops first, as a
				 * processor does at INIT, whatever it was
				 * doing -- not carry on with its old code
				 * until a SIPI happened to find it stopped.
				 */
				p->initwait[i] = 1;
				p->initreq[i] = 1;
				p->kick[i] = 1;
				p->poke |= 1<<i;
			}
			break;
		case 6:		/* SIPI: start one that waits, at vec<<12 */
			if(p->initwait[i]){
				p->initwait[i] = 0;
				p->sipi[i] = vec;
				p->poke |= 1<<i;
			}
			break;
		}
	}
}

/*
 * The vCPU's kproc, woken while stopped: if a SIPI is waiting for it,
 * start it -- in real mode at the SIPI's page, as a processor leaves
 * wait-for-SIPI -- and return 1.  On the vCPU's own processor.
 */
int
vmplatsipi(Vcpu *v)
{
	Plat *p;
	int vec, s;

	p = PLAT(v->vm);
	ilock(p);
	vec = p->sipi[v->id];
	p->sipi[v->id] = -1;
	if(vec >= 0)
		p->initreq[v->id] = 0;	/* the INIT this SIPI follows has been obeyed */
	iunlock(p);
	if(vec < 0)
		return 0;
	vmops->setreg(v, VEfer, 0);
	vmops->setreg(v, VCr0, 0x60000010);	/* CD, NW, ET: as at INIT */
	vmops->setreg(v, VCr3, 0);
	vmops->setreg(v, VCr4, 0);
	vmops->setreg(v, VRflags, 2);
	vmops->setreg(v, VRip, 0);
	vmops->setreg(v, VCs, vec << 8);
	vmops->setreg(v, VCsbase, vec << 12);
	vmops->setreg(v, VCslimit, 0xFFFF);
	vmops->setreg(v, VCsattr, 0x9B);
	for(s = VDs; s <= VSs; s += 4){	/* DS, ES, FS, GS, SS */
		vmops->setreg(v, s, 0);
		vmops->setreg(v, s+1, 0);
		vmops->setreg(v, s+2, 0xFFFF);
		vmops->setreg(v, s+3, 0x93);
	}
	vmops->setreg(v, VGdtrbase, 0);
	vmops->setreg(v, VGdtrlimit, 0xFFFF);
	vmops->setreg(v, VIdtrbase, 0);
	vmops->setreg(v, VIdtrlimit, 0xFFFF);
	return 1;
}

/*
 * On the vCPU's own processor, between exits: an INIT came for it.  It
 * leaves the guest without an exit to report and waits, as one that
 * was never started does, for its SIPI.
 */
int
vmplatinit(Vcpu *v)
{
	Plat *p;
	int r;

	p = PLAT(v->vm);
	ilock(p);
	r = p->initreq[v->id];
	p->initreq[v->id] = 0;
	iunlock(p);
	return r;
}

int
vmplatsipipending(Vcpu *v)
{
	return PLAT(v->vm)->sipi[v->id] >= 0;
}

void*
vmplatnew(Vm *vm)
{
	Plat *p;
	int i;

	p = malloc(sizeof *p);
	if(p == nil)
		error(Enomem);
	p->vm = vm;
	vvmsi = vmplatmsi;	/* the virtio functions' interrupts */
	p->tschz = MACHP(0)->cpuhz;
	vpicreset(&p->pic);
	vpitreset(&p->pit, p->tschz);
	vuartreset(&p->uart);
	vioapicreset(&p->ioapic);
	for(i = 0; i < Maxvcpu; i++){
		vlapicreset(&p->lapic[i], i);
		p->sipi[i] = -1;
		p->initwait[i] = i != 0;	/* application processors wait for SIPI */
	}
	kickinit();
	if(waserror()){
		free(p);
		nexterror();
	}
	p->pci = vmpcinew(vm, 0xC0000000, 0xFEC00000);
	poperror();
	return p;
}

void
vmplathangup(Vm *vm)
{
	Plat *p;

	if((p = PLAT(vm)) != nil){
		p->hungup = 1;
		wakeup(&p->consr);
		qlock(&p->pcilk);
		vmpcistop(p->pci);
		qunlock(&p->pcilk);
	}
}

void
vmplatfree(Vm *vm)
{
	Plat *p;

	if((p = PLAT(vm)) == nil)
		return;
	vmpcifree(p->pci);
	free(p);
	vm->plat = nil;
}

/*
 * CPUID: the host's, with what this hypervisor does not provide taken
 * out and the hypervisor bit set.  Hidden: VMX and SVM (no nesting),
 * MONITOR/MWAIT, XSAVE and AVX (no XCR0 handling yet), x2APIC, MTRR,
 * machine check, performance monitoring, thermal and power
 * management, the speculation-control MSRs, INVPCID, RDTSCP and RDPID
 * (VMX needs a control enabled for each), LA57, PKU, TSC_ADJUST.
 * Shown: the local APIC, the TSC-deadline timer, ARAT.
 */
static void
cpuidfilter(Vcpu *v, u32int leaf, u32int sub, u32int r[4])
{
	u32int max, h[4];

	USED(sub);
	cpuid(0, 0, h);
	max = h[0] > 7 ? 7 : h[0];
	if(leaf >= 0x40000000 && leaf < 0x40000100){
		r[0] = r[1] = r[2] = r[3] = 0;
		if(leaf == 0x40000000){
			r[0] = 0x40000000;
			memmove(&r[1], "Infe", 4);
			memmove(&r[2], "rnoH", 4);
			memmove(&r[3], "yper", 4);
		}
		return;
	}
	if(leaf >= 0x80000000){
		cpuid(0x80000000, 0, h);
		if(leaf > (h[0] < 0x80000008 ? h[0] : 0x80000008)){
			r[0] = r[1] = r[2] = r[3] = 0;
			return;
		}
	}else if(leaf > max){
		r[0] = r[1] = r[2] = r[3] = 0;
		return;
	}
	cpuid(leaf, sub, r);
	switch(leaf){
	case 0:
		r[0] = max;
		break;
	case 1:
		r[1] = (r[1] & 0xFFFF) | 1<<16 | v->id << 24;
		r[2] &= ~(1<<3|1<<4|1<<5|1<<6|1<<7|1<<8|1<<15|1<<18|1<<21|1<<26|1<<27|1<<28);
		r[2] |= 1<<24 | 1<<31;		/* TSC deadline, hypervisor */
		r[3] &= ~(1<<7|1<<12|1<<14|1<<21|1<<22|1<<28|1<<29|1<<31);
		r[3] |= 1<<9;			/* APIC */
		break;
	case 5:
		r[0] = r[1] = r[2] = r[3] = 0;
		break;
	case 6:
		/*
		 * Power management is the host's; only ARAT is shown,
		 * because it is true here -- this APIC timer runs whatever
		 * the guest's idle state -- and without it Linux takes the
		 * local timer for one that stops in deep idle.
		 */
		r[0] = 1<<2;
		r[1] = r[2] = r[3] = 0;
		break;
	case 7:
		if(sub != 0){
			r[0] = r[1] = r[2] = r[3] = 0;
			break;
		}
		r[0] = 0;
		r[1] &= ~(1<<1|1<<2|1<<4|1<<5|1<<10|1<<11|1<<12|1<<14|1<<15|1<<16|1<<17
			|1<<21|1<<26|1<<27|1<<28|1<<30|1u<<31);
		/* RDPID (22) reads TSC_AUX, which VMX gives only with RDTSCP enabled */
		r[2] &= ~(1<<1|1<<2|1<<3|1<<4|1<<5|1<<6|1<<11|1<<12|1<<14|1<<16|1<<22|1<<30);
		r[3] = 0;
		break;
	case 0x80000001:
		r[2] &= ~(1<<2|1<<9|1<<12|1<<13|1<<15|1<<23|1<<24|1<<26|1<<28);
		r[3] &= ~(1<<27);		/* RDTSCP */
		break;
	case 0x80000007:
		r[0] = r[1] = r[2] = 0;
		r[3] &= 1<<8;			/* invariant TSC */
		break;
	case 0x80000008:
		r[1] = 0;
		r[2] = 0;
		break;
	}
}

static void
docpuid(Vcpu *v, Vmexit *e)
{
	u32int r[4];

	cpuidfilter(v, vmops->getreg(v, VRax), vmops->getreg(v, VRcx), r);
	vmops->setreg(v, VRax, r[0]);
	vmops->setreg(v, VRbx, r[1]);
	vmops->setreg(v, VRcx, r[2]);
	vmops->setreg(v, VRdx, r[3]);
	vmops->setreg(v, VRip, e->rip + e->ilen);
}

static void
gp(Vcpu *v, Plat *p)
{
	p->ngp++;
	vmops->inject(v, VeExc, VecGP, 1, 0);
}

/*
 * MSRs.  The processor's own (EFER, PAT, segment bases, syscall)
 * belong to the backend; the APIC's are the APIC's; a few that
 * firmware or the processor would answer are answered; any other
 * raises #GP, which Linux expects of an MSR that is not there.
 */
static void
domsr(Vcpu *v, Plat *p, Vmexit *e)
{
	uvlong val, now;
	Vlapic *a;
	u32int msr;
	int ok;

	p->nmsr++;
	msr = e->msr;
	a = &p->lapic[v->id];
	if(e->kind == VxRdmsr){
		ok = 1;
		if(vmops->rdmsr(v, msr, &val) == 0)
			;
		else if(msr == 0x10)			/* TSC */
			cycles(&val);
		else if(msr == 0x1B)			/* IA32_APIC_BASE */
			val = a->base;
		else if(msr == 0x6E0)			/* IA32_TSC_DEADLINE */
			val = a->tscdeadline;
		else if(msr == 0x3A)			/* IA32_FEATURE_CONTROL: locked, VMX off */
			val = 1;
		else if(msr == 0x1A0)			/* IA32_MISC_ENABLE: fast strings */
			val = 1;
		else if(msr == 0x17 || msr == 0x8B)	/* platform id, microcode revision */
			val = 0;
		else if(msr >= 0x800 && msr < 0x900 && (a->base & ApicX2) && msr != 0x80B && msr != 0x83F)
			val = msr == 0x830 ? (uvlong)a->icrhi << 32 | a->icrlo : vlapicread(a, msr - 0x800);
		else
			ok = 0;
		if(!ok){
			p->lastgpmsr = msr;
			gp(v, p);
			return;
		}
		vmops->setreg(v, VRax, (u32int)val);
		vmops->setreg(v, VRdx, val >> 32);
	}else{
		val = vmops->getreg(v, VRdx) << 32 | (u32int)vmops->getreg(v, VRax);
		ok = 1;
		if(vmops->wrmsr(v, msr, val) == 0)
			;
		else if(msr == 0x1B){
			/*
			 * Enable and x2APIC mode may change; the base may
			 * not.  Leaving x2APIC mode straight to xAPIC is
			 * invalid (SDM 11.12.5).
			 */
			if((val & ~0xFFFULL) != Apicbase
			|| (a->base & ApicX2) && !(val & ApicX2) && (val & ApicEnable))
				ok = 0;
			else
				a->base = val & (Apicbase | ApicEnable | ApicX2) | (a->base & ApicBsp);
		}else if(msr == 0x6E0){
			cycles(&now);
			vlapicsetdeadline(a, val, now);
		}else if(msr == 0x10 || msr == 0x8B || msr == 0x1A0)
			;	/* TSC writes, microcode loads, MISC_ENABLE: dropped */
		else if(msr >= 0x800 && msr < 0x900 && (a->base & ApicX2)){
			if(msr == 0x830){
				a->icrhi = val >> 32;
				ok = vlapicwrite(a, 0x30, val);
			}else
				ok = vlapicwrite(a, msr - 0x800, val);
			if(ok == 2)
				ipi(p, v->id, a->icrhi, a->icrlo);
		}else
			ok = 0;
		if(!ok){
			p->lastgpmsr = msr;
			gp(v, p);
			return;
		}
	}
	vmops->setreg(v, VRip, e->rip + e->ilen);
}

static int
doio(Vcpu *v, Plat *p, Vmexit *e)
{
	u32int val, mask;
	uvlong now;
	int port, claimed;

	port = e->port;
	mask = e->size == 4 ? 0xFFFFFFFF : (1 << 8*e->size) - 1;
	val = e->in ? 0 : e->data & mask;
	claimed = 0;
	if(!e->string && !e->rep){
		if(port >= 0x3F8 && port <= 0x3FF)
			claimed = vuartio(&p->uart, port - 0x3F8, e->in, &val);
		else if(port == 0x20 || port == 0x21 || port == 0xA0 || port == 0xA1
		|| port == 0x4D0 || port == 0x4D1)
			claimed = vpicio(&p->pic, port, e->in, &val);
		else if(port >= 0x40 && port <= 0x43 || port == 0x61){
			cycles(&now);
			claimed = vpitio(&p->pit, port, e->in, &val, now);
		}
		else if(port == 0x80){		/* POST code: a delay, nothing more */
			claimed = 1;
			val = 0xFF;
		}
	}
	if(!claimed){
		if(!p->ioignore)
			return 0;
		p->lastport = port;
		val = 0xFFFFFFFF;
	}
	p->nio++;
	if(e->in){
		if(e->string)
			;	/* nothing there: memory is left as it was */
		else
			vmops->setreg(v, VRax, vmops->getreg(v, VRax) & ~(uvlong)mask | val & mask);
	}
	vmops->setreg(v, VRip, e->rip + e->ilen);
	return 1;
}

/*
 * The xAPIC page.  An access to it is a nested-paging fault, and the
 * value comes from the instruction, so the instruction is fetched
 * through the guest's own page tables and decoded.  Only the moves a
 * compiler emits for a volatile 32-bit load or store are decoded --
 * MOV between a register or an immediate and memory -- which is all
 * Linux's apic accessors are; anything else is handed up.
 */
static uchar*
gpaptr(Vm *vm, uvlong gpa, int n)
{
	if(gpa >= vm->memsize || gpa + n > vm->memsize)
		return nil;
	return vm->mem + gpa;
}

static int
gwalk(Vcpu *v, uvlong va, uvlong *gpa)
{
	Vm *vm;
	uvlong cr0, cr4, efer, e, tab;
	uchar *p;
	int l;

	vm = v->vm;
	cr0 = vmops->getreg(v, VCr0);
	if((cr0 & CR0PG) == 0){
		*gpa = va & 0xFFFFFFFF;
		return 0;
	}
	cr4 = vmops->getreg(v, VCr4);
	efer = vmops->getreg(v, VEfer);
	tab = vmops->getreg(v, VCr3);
	if(efer & EFERLMA){
		tab &= ~0xFFFULL;
		for(l = 3; l >= 0; l--){
			if((p = gpaptr(vm, tab + ((va >> (12+9*l)) & 0x1FF)*8, 8)) == nil)
				return -1;
			e = *(uvlong*)p;
			if((e & 1) == 0)
				return -1;
			if(l > 0 && l < 3 && (e & 0x80)){
				*gpa = (e & 0x000FFFFFFFFFF000ULL & ~((1ULL<<(12+9*l))-1)) | (va & ((1ULL<<(12+9*l))-1));
				return 0;
			}
			tab = e & 0x000FFFFFFFFFF000ULL;
		}
		*gpa = tab | (va & 0xFFF);
		return 0;
	}
	if(cr4 & CR4PAE){
		tab &= ~0x1FULL;
		if((p = gpaptr(vm, tab + ((va >> 30) & 3)*8, 8)) == nil)
			return -1;
		e = *(uvlong*)p;
		for(l = 1; l >= 0; l--){
			if((e & 1) == 0)
				return -1;
			tab = e & 0x000FFFFFFFFFF000ULL;
			if((p = gpaptr(vm, tab + ((va >> (12+9*l)) & 0x1FF)*8, 8)) == nil)
				return -1;
			e = *(uvlong*)p;
			if((e & 1) == 0)
				return -1;
			if(l == 1 && (e & 0x80)){
				*gpa = (e & 0x000FFFFFFFE00000ULL) | (va & 0x1FFFFF);
				return 0;
			}
		}
		*gpa = (e & 0x000FFFFFFFFFF000ULL) | (va & 0xFFF);
		return 0;
	}
	tab &= ~0xFFFULL;
	if((p = gpaptr(vm, tab + ((va >> 22) & 0x3FF)*4, 4)) == nil)
		return -1;
	e = *(u32int*)p;
	if((e & 1) == 0)
		return -1;
	if((cr4 & CR4PSE) && (e & 0x80)){
		*gpa = (e & 0xFFC00000) | (va & 0x3FFFFF);
		return 0;
	}
	if((p = gpaptr(vm, (e & ~0xFFFULL) + ((va >> 12) & 0x3FF)*4, 4)) == nil)
		return -1;
	e = *(u32int*)p;
	if((e & 1) == 0)
		return -1;
	*gpa = (e & ~0xFFFULL) | (va & 0xFFF);
	return 0;
}

static int
fetch(Vcpu *v, uvlong rip, uchar *buf, int n)
{
	uvlong va, gpa;
	uchar *p;
	int i;

	va = vmops->getreg(v, VCsbase) + rip;
	for(i = 0; i < n; i++){
		if(gwalk(v, va + i, &gpa) < 0 || (p = gpaptr(v->vm, gpa, 1)) == nil)
			break;
		buf[i] = *p;
	}
	return i;
}

static int gprindex[16] = {
	VRax, VRcx, VRdx, VRbx, VRsp, VRbp, VRsi, VRdi,
	VR8, VR9, VR10, VR11, VR12, VR13, VR14, VR15,
};

/* register r as an operand of size bytes; rex says whether a REX prefix was present */
static uvlong
getop(Vcpu *v, int r, int size, int rex)
{
	if(size == 1 && !rex && r >= 4 && r < 8)	/* AH, CH, DH, BH */
		return (vmops->getreg(v, gprindex[r-4]) >> 8) & 0xFF;
	return vmops->getreg(v, gprindex[r]);
}

static void
setop(Vcpu *v, int r, int size, int rex, uvlong val)
{
	uvlong old;

	switch(size){
	case 1:
		if(!rex && r >= 4 && r < 8){
			old = vmops->getreg(v, gprindex[r-4]);
			vmops->setreg(v, gprindex[r-4], old & ~0xFF00ULL | (val & 0xFF) << 8);
			return;
		}
		old = vmops->getreg(v, gprindex[r]);
		vmops->setreg(v, gprindex[r], old & ~0xFFULL | (val & 0xFF));
		return;
	case 2:
		old = vmops->getreg(v, gprindex[r]);
		vmops->setreg(v, gprindex[r], old & ~0xFFFFULL | (val & 0xFFFF));
		return;
	case 4:
		vmops->setreg(v, gprindex[r], val & 0xFFFFFFFF);	/* zero-extended */
		return;
	}
	vmops->setreg(v, gprindex[r], val);
}

typedef struct Insn Insn;
struct Insn
{
	int	len;
	int	write;		/* to memory */
	int	size;		/* operand bytes */
	int	reg;		/* register operand, -1 for an immediate */
	int	rex;
	int	zext;		/* movzx */
	uvlong	imm;
};

static int
decode(uchar *b, int n, int long64, Insn *in)
{
	int i, opsz, rex, op, modrm, mod, rm, len, immsz;

	memset(in, 0, sizeof *in);
	opsz = 0;
	rex = 0;
	for(i = 0; i < n; i++){
		switch(b[i]){
		case 0x66: opsz = 1; continue;
		case 0x67: case 0xF0: case 0xF2: case 0xF3:
		case 0x26: case 0x2E: case 0x36: case 0x3E: case 0x64: case 0x65:
			continue;
		}
		break;
	}
	if(i < n && long64 && (b[i] & 0xF0) == 0x40)
		rex = b[i++];
	if(i >= n)
		return -1;
	op = b[i++];
	in->size = (rex & 8) ? 8 : opsz ? 2 : 4;
	immsz = 0;
	switch(op){
	case 0x88: in->write = 1; in->size = 1; break;
	case 0x89: in->write = 1; break;
	case 0x8A: in->size = 1; break;
	case 0x8B: break;
	case 0xC6: in->write = 1; in->size = 1; immsz = 1; break;
	case 0xC7: in->write = 1; immsz = in->size == 2 ? 2 : 4; break;
	case 0x0F:
		if(i >= n)
			return -1;
		op = b[i++];
		if(op != 0xB6 && op != 0xB7)
			return -1;
		in->zext = op == 0xB6 ? 1 : 2;
		break;
	default:
		return -1;
	}
	if(i >= n)
		return -1;
	modrm = b[i++];
	mod = modrm >> 6;
	rm = modrm & 7;
	if(mod == 3)
		return -1;		/* register to register: not a memory access */
	in->reg = ((modrm >> 3) & 7) | ((rex & 4) ? 8 : 0);
	if(immsz != 0){
		if(((modrm >> 3) & 7) != 0)
			return -1;	/* C6/C7 with reg != 0 is not a MOV */
		in->reg = -1;
	}
	len = 0;
	if(rm == 4){
		if(i >= n)
			return -1;
		if(mod == 0 && (b[i] & 7) == 5)
			len = 4;
		i++;
	}else if(mod == 0 && rm == 5)
		len = 4;		/* disp32, or rip-relative in 64-bit mode */
	if(mod == 1)
		len = 1;
	else if(mod == 2)
		len = 4;
	i += len;
	if(immsz != 0){
		if(i + immsz > n)
			return -1;
		in->imm = immsz == 1 ? b[i] : immsz == 2 ? (b[i] | b[i+1]<<8)
			: (uvlong)(vlong)(s32int)(b[i] | b[i+1]<<8 | b[i+2]<<16 | (u32int)b[i+3]<<24);
		i += immsz;
	}
	in->rex = rex != 0;
	in->len = i;
	return i <= n ? 0 : -1;
}

/* decode the instruction that faulted on an MMIO page; 0 if it is not a MOV we know */
static int
mmioinsn(Vcpu *v, Vmexit *e, Insn *in)
{
	uchar buf[15];
	int n, long64;

	n = fetch(v, e->rip, buf, sizeof buf);
	long64 = (vmops->getreg(v, VEfer) & EFERLMA) && (vmops->getreg(v, VCsattr) & 1<<13);
	return n > 0 && decode(buf, n, long64, in) == 0;
}

static void
mmiofinish(Vcpu *v, Vmexit *e, Insn *in, uvlong val)
{
	if(!in->write){
		if(in->zext)
			setop(v, in->reg, 4, in->rex, val & (in->zext == 1 ? 0xFF : 0xFFFF));
		else
			setop(v, in->reg, in->size, in->rex, val);
	}
	vmops->setreg(v, VRip, e->rip + in->len);
}

static uvlong
mmiowval(Vcpu *v, Insn *in)
{
	return in->reg < 0 ? in->imm : getop(v, in->reg, in->size, in->rex);
}

/* the local APIC's page; the platform's lock held */
static int
apicmmio(Vcpu *v, Plat *p, Vmexit *e, Insn *in)
{
	Vlapic *a;
	int reg;
	uvlong val;

	a = &p->lapic[v->id];
	if((a->base & (ApicEnable|ApicX2)) != ApicEnable)
		return 0;
	if((e->gpa & 0xF) != 0 || in->size != 4 && in->zext == 0)
		return 0;		/* the APIC is 32-bit registers on 16-byte boundaries */
	reg = (e->gpa & 0xFF0) >> 4;
	p->nmmio++;
	val = 0;
	if(in->write){
		if(vlapicwrite(a, reg, mmiowval(v, in)) == 2)
			ipi(p, v->id, a->icrhi, a->icrlo);
	}else
		val = vlapicread(a, reg);
	mmiofinish(v, e, in, val);
	return 1;
}

/* the I/O APIC's page; the platform's lock held */
static int
ioapicmmio(Vcpu *v, Plat *p, Vmexit *e, Insn *in)
{
	uvlong val;
	int off;

	off = e->gpa & 0xFFF;
	if(in->size != 4 && in->zext == 0)
		return 0;
	p->nmmio++;
	val = 0;
	if(in->write)
		vioapicwrite(&p->ioapic, off, mmiowval(v, in));
	else
		val = vioapicread(&p->ioapic, off);
	mmiofinish(v, e, in, val);
	return 1;
}

/* a trapped page of an assigned function's BAR; no spin lock held */
static int
pcimmio(Vcpu *v, Plat *p, Vmexit *e, Insn *in)
{
	uvlong val;
	int r, size;

	size = in->zext ? in->zext : in->size;
	val = in->write ? mmiowval(v, in) : 0;
	qlock(&p->pcilk);
	if(waserror()){
		qunlock(&p->pcilk);
		nexterror();
	}
	r = vmpcimmio(p->pci, e->gpa, size, in->write, &val);
	poperror();
	qunlock(&p->pcilk);
	if(r){
		p->nmmio++;
		mmiofinish(v, e, in, val);
	}
	return r;
}

/*
 * Whether an interrupt would be delivered now; caller holds p.  The
 * PIC is wired to the bootstrap processor's LINT0 only.
 */
static int
pendingvec(Plat *p, Vlapic *a)
{
	if(vlapicpending(a))
		return 1;
	if(a == &p->lapic[0] && vpicpending(&p->pic) && vlapicextint(a))
		return 1;
	return 0;
}

/*
 * An I/O APIC input; an edge it delivers goes to the APICs its entry
 * names (fixed: all that match; lowest priority: the first).  p's lock
 * held; the vCPUs to wake are left in p->poke.
 */
static void
ioapicin(Plat *p, int pin, int level)
{
	uvlong r;
	int i, mode;

	if(!vioapicset(&p->ioapic, pin, level, &r))
		return;
	mode = (r >> 8) & 7;
	if(mode > 1)
		return;		/* fixed and lowest priority only */
	for(i = 0; i < p->vm->nvcpu; i++){
		if(!vlapicmatch(&p->lapic[i], r >> 56, (r >> 11) & 1))
			continue;
		vlapicsetirr(&p->lapic[i], r & 0xFF);
		p->kick[i] = 1;
		p->poke |= 1<<i;
		if(mode == 1)
			break;
	}
}

static void
update(Plat *p, Vlapic *a)
{
	uvlong now;

	cycles(&now);
	vlapictimer(a, now);
	if(vpittimer(&p->pit, now)){
		vpicsetirq(&p->pic, 0, 1);	/* an edge on IRQ 0 */
		vpicsetirq(&p->pic, 0, 0);
		ioapicin(p, 2, 1);		/* GSI 2: ACPI's override of IRQ 0 */
		ioapicin(p, 2, 0);
	}
	vpicsetirq(&p->pic, 4, vuartirq(&p->uart));
	ioapicin(p, 4, vuartirq(&p->uart));
}

void
vmplatintr(Vcpu *v)
{
	Plat *p;
	Vlapic *a;
	int vec, want;

	p = PLAT(v->vm);
	a = &p->lapic[v->id];
	ilock(p);
	update(p, a);
	/*
	 * An NMI goes in when an interrupt could: injecting one while the
	 * guest blocks NMIs (in its handler, or after MOV SS) would fail
	 * the VM entry, and with interrupts on and no shadow it is not in
	 * an NMI handler -- Linux's run with interrupts off.  So an NMI
	 * sent to a processor spinning with interrupts off waits.
	 */
	if(p->nmi[v->id] && vmops->canintr(v)){
		p->nmi[v->id] = 0;
		iunlock(p);
		if(p->poke)
			dopokes(p);	/* update() may have sent the I/O APIC's */
		vmops->inject(v, VeNmi, 2, 0, 0);
		return;
	}
	vec = -1;
	want = pendingvec(p, a) || p->nmi[v->id];
	if(want && vmops->canintr(v)){
		if(vlapicpending(a))
			vec = vlapicack(a);
		else
			vec = vpicack(&p->pic);
		want = 0;
	}
	iunlock(p);
	if(p->poke)
		dopokes(p);
	if(vec >= 0){
		p->nintr++;
		vmops->inject(v, VeIntr, vec, 0, 0);
	}
	if(want != p->irqwin[v->id]){
		vmops->irqwin(v, want);
		p->irqwin[v->id] = want;
	}
}

static int
hltwake(void *a)
{
	Vcpu *v;
	Plat *p;

	v = a;
	p = PLAT(v->vm);
	return p->kick[v->id] || v->stop || v->quit || v->cmd != nil;
}

/*
 * HLT with interrupts on: the vCPU sleeps in the kernel until an
 * interrupt it can take is pending -- its timer firing, console
 * input -- or it is stopped.
 */
static void
dohlt(Vcpu *v, Plat *p, Vmexit *e)
{
	Vlapic *a;
	uvlong now, rflags, next;
	int ms;

	p->nhlt++;
	vmops->setreg(v, VRip, e->rip + e->ilen);
	a = &p->lapic[v->id];
	rflags = vmops->getreg(v, VRflags);
	USED(rflags);
	for(;;){
		ilock(p);
		update(p, a);
		p->kick[v->id] = 0;
		if((rflags & IF) && pendingvec(p, a) || p->nmi[v->id]){
			iunlock(p);
			if(p->poke)
				dopokes(p);
			return;
		}
		ms = 1000;
		next = a->fire;
		if(vpitnext(&p->pit) != 0 && (next == 0 || vpitnext(&p->pit) < next))
			next = vpitnext(&p->pit);
		if((rflags & IF) && next != 0 && p->tschz != 0){
			cycles(&now);
			if(next <= now)
				ms = 0;
			else
				ms = (next - now) * 1000 / p->tschz + 1;
			if(ms > 1000)
				ms = 1000;
		}
		iunlock(p);
		if(p->poke)
			dopokes(p);	/* an I/O APIC edge update() sent elsewhere */
		if(v->stop || v->quit || v->cmd != nil)
			return;
		if(ms > 0)
			tsleep(&v->r, hltwake, v, ms);
	}
}

/* configuration mechanism 1, without the spin lock */
static int
pciio(Vcpu *v, Plat *p, Vmexit *e)
{
	u32int val, mask;
	int r;

	mask = e->size == 4 ? 0xFFFFFFFF : (1 << 8*e->size) - 1;
	val = e->in ? 0 : e->data & mask;
	qlock(&p->pcilk);
	if(waserror()){
		qunlock(&p->pcilk);
		nexterror();
	}
	r = vmpciio(p->pci, e->port, e->in, e->size, &val);
	poperror();
	qunlock(&p->pcilk);
	if(!r)
		return 0;
	p->nio++;
	if(e->in)
		vmops->setreg(v, VRax, vmops->getreg(v, VRax) & ~(uvlong)mask | val & mask);
	vmops->setreg(v, VRip, e->rip + e->ilen);
	return 1;
}

/*
 * An MSI, from an assigned function or one of the hypervisor's own:
 * address 0xFEExxxxx names the destination in bits 19:12, physical or
 * logical by bit 2 (matched as the guest's APICs say: vlapicmatch),
 * and data the vector and delivery mode.  Fixed delivery goes to every
 * APIC that matches, lowest-priority to the first.  Interrupt context.
 */
void
vmplatmsi(Vm *vm, u32int addr, u32int data)
{
	Plat *p;
	int i, dest, mode, any;

	p = PLAT(vm);
	if(p == nil || vm->nvcpu == 0)
		return;
	dest = (addr >> 12) & 0xFF;
	mode = (data >> 8) & 7;
	if((addr & 0xFFF00000) != Apicbase || mode > 1)
		return;
	any = 0;
	ilock(p);
	for(i = 0; i < vm->nvcpu; i++){
		if(!vlapicmatch(&p->lapic[i], dest, (addr & 1<<2) != 0))
			continue;
		vlapicsetirr(&p->lapic[i], data & 0xFF);
		p->kick[i] = 1;
		p->poke |= 1<<i;
		any = 1;
		if(mode == 1)
			break;
	}
	if(any)
		p->nmsi++;
	iunlock(p);
	dopokes(p);
}

int
vmplatexit(Vcpu *v, Vmexit *e)
{
	Plat *p;
	Insn in;
	int r;

	p = PLAT(v->vm);
	switch(e->kind){
	case VxCpuid:
		p->ncpuid++;
		docpuid(v, e);
		return 1;
	case VxRdmsr:
	case VxWrmsr:
		ilock(p);
		domsr(v, p, e);
		iunlock(p);
		if(p->poke)
			dopokes(p);
		return 1;
	case VxIo:
		if(e->port >= 0xCF8 && e->port <= 0xCFF && !e->string && !e->rep)
			return pciio(v, p, e);
		ilock(p);
		r = doio(v, p, e);
		iunlock(p);
		if(p->uart.outw != p->uart.outr)
			wakeup(&p->consr);
		return r;
	case VxMmio:
		if(!mmioinsn(v, e, &in))
			return 0;
		if((e->gpa & ~0xFFFULL) == Apicbase){
			ilock(p);
			r = apicmmio(v, p, e, &in);
			iunlock(p);
			if(p->poke)
				dopokes(p);
			return r;
		}
		if((e->gpa & ~0xFFFULL) == Ioapicbase){
			ilock(p);
			r = ioapicmmio(v, p, e, &in);
			iunlock(p);
			return r;
		}
		return pcimmio(v, p, e, &in);
	case VxHlt:
		/*
		 * HLT with interrupts off is a guest that has stopped
		 * for good -- nothing can wake it -- so that one goes up
		 * to Limbo, at the HLT.
		 */
		if((vmops->getreg(v, VRflags) & IF) == 0)
			return 0;
		dohlt(v, p, e);
		return 1;
	case VxIntrwin:
		return 1;
	}
	return 0;
}

int
vmplatctl(Vm *vm, int nf, char **f)
{
	Plat *p;

	p = PLAT(vm);
	if(nf == 2 && strcmp(f[0], "io") == 0){
		if(strcmp(f[1], "ignore") == 0)
			p->ioignore = 1;
		else if(strcmp(f[1], "exit") == 0)
			p->ioignore = 0;
		else
			error(Ebadarg);
		return 1;
	}
	if(nf == 2 && strcmp(f[0], "assign") == 0){
		qlock(&p->pcilk);
		if(waserror()){
			qunlock(&p->pcilk);
			nexterror();
		}
		vmpciassign(p->pci, f[1]);
		poperror();
		qunlock(&p->pcilk);
		return 1;
	}
	if(nf == 3 && strcmp(f[0], "virtio") == 0){
		qlock(&p->pcilk);
		if(waserror()){
			qunlock(&p->pcilk);
			nexterror();
		}
		vmpcivirtio(p->pci, f[1], f[2]);
		poperror();
		qunlock(&p->pcilk);
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
	sleep(&p->consr, consready, p);
	/*
	 * What the guest wrote before it was killed is still here, in
	 * the platform, which outlives the machine's memory: give it out
	 * before saying the machine has gone.
	 */
	if(p->hungup && p->uart.outr == p->uart.outw)
		error(Ehungup);
	b = a;
	ilock(p);
	for(i = 0; i < n && p->uart.outr != p->uart.outw; i++)
		b[i] = p->uart.out[p->uart.outr++ % Uartout];
	iunlock(p);
	return i;
}

long
vmplatconswrite(Vm *vm, void *a, long n)
{
	Plat *p;
	int i, got;

	p = PLAT(vm);
	ilock(p);
	got = vuartinput(&p->uart, a, n);
	for(i = 0; i < vm->nvcpu; i++)
		p->kick[i] = 1;
	iunlock(p);
	for(i = 0; i < vm->nvcpu; i++)
		wakeup(&vm->vcpu[i]->r);
	return got;
}

char*
vmplatstatus(Vm *vm, char *s, char *e)
{
	Plat *p;
	Vlapic *a;
	int i;

	p = PLAT(vm);
	s = seprint(s, e, "platform tschz %llud io %s\n", p->tschz, p->ioignore ? "ignore" : "exit");
	s = seprint(s, e, "platform handled cpuid %llud msr %llud io %llud mmio %llud hlt %llud intr %llud gp %llud msi %llud\n",
		p->ncpuid, p->nmsr, p->nio, p->nmmio, p->nhlt, p->nintr, p->ngp, p->nmsi);
	s = seprint(s, e, "platform lastgpmsr %#ux lastport %#ux conslost %llud\n", p->lastgpmsr, p->lastport, p->uart.outlost);
	s = seprint(s, e, "pic imr %.2ux/%.2ux irr %.2ux/%.2ux isr %.2ux/%.2ux base %.2ux/%.2ux\n",
		p->pic.c[0].imr, p->pic.c[1].imr, p->pic.c[0].irr, p->pic.c[1].irr,
		p->pic.c[0].isr, p->pic.c[1].isr, p->pic.c[0].base, p->pic.c[1].base);
	for(i = 0; i < vm->nvcpu; i++){
		a = &p->lapic[i];
		s = seprint(s, e, "lapic%d id %d base %#llux svr %#ux ldr %#ux lvtt %#ux lint0 %#ux tpr %#ux fire %llud%s\n",
			i, a->id, a->base, a->svr, a->ldr, a->lvt[LvtTimer], a->lvt[LvtLint0], a->tpr, a->fire,
			i == 0 ? "" : p->initwait[i] ? " waiting for SIPI" : "");
	}
	if(p->nipi)
		s = seprint(s, e, "platform ipis %llud\n", p->nipi);
	for(i = 0; i < Nioapic; i++)
		if((p->ioapic.rte[i] & 1<<16) == 0)
			s = seprint(s, e, "ioapic pin %d rte %#llux\n", i, p->ioapic.rte[i]);
	s = vmpcistatus(p->pci, s, e);
	return s;
}
