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
#include	"../port/vm.h"
#include	"vmdev.h"
#include	"vmpci.h"

typedef struct Plat Plat;

struct Plat
{
	Lock;
	Vm	*vm;
	Vpic	pic;
	Vpit	pit;
	Vuart	uart;
	Vlapic	lapic[Maxvcpu];
	void	*pci;		/* vmpci.c's */
	QLock	pcilk;		/* the PCI bus is not touched under the spin lock */
	int	irqwin[Maxvcpu];
	int	kick[Maxvcpu];	/* something for a halted vCPU to look at */
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

void*
vmplatnew(Vm *vm)
{
	Plat *p;
	int i;

	p = malloc(sizeof *p);
	if(p == nil)
		error(Enomem);
	p->vm = vm;
	p->tschz = MACHP(0)->cpuhz;
	vpicreset(&p->pic);
	vpitreset(&p->pit, p->tschz);
	vuartreset(&p->uart);
	for(i = 0; i < Maxvcpu; i++)
		vlapicreset(&p->lapic[i], i);
	if(waserror()){
		free(p);
		nexterror();
	}
	p->pci = vmpcinew(vm);
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
	if(in->write)
		vlapicwrite(a, reg, mmiowval(v, in));
	else
		val = vlapicread(a, reg);
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

/* the interrupt that would be delivered now, or -1; caller holds p */
static int
pendingvec(Plat *p, Vlapic *a)
{
	if(vlapicpending(a))
		return 1;
	if(vpicpending(&p->pic) && vlapicextint(a))
		return 1;
	return 0;
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
	}
	vpicsetirq(&p->pic, 4, vuartirq(&p->uart));
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
	vec = -1;
	want = pendingvec(p, a);
	if(want && vmops->canintr(v)){
		if(vlapicpending(a))
			vec = vlapicack(a);
		else
			vec = vpicack(&p->pic);
		want = 0;
	}
	iunlock(p);
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
		if((rflags & IF) && pendingvec(p, a)){
			iunlock(p);
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
 * An MSI from an assigned function: address 0xFEExxxxx names the
 * destination in bits 19:12, physical or logical by bit 2, and data
 * the vector and delivery mode.  Fixed and lowest-priority delivery to
 * this machine's one vCPU.
 */
void
vmplatmsi(Vm *vm, u32int addr, u32int data)
{
	Plat *p;
	Vlapic *a;
	int dest, mode;

	p = PLAT(vm);
	if(p == nil || vm->nvcpu == 0)
		return;
	a = &p->lapic[0];
	dest = (addr >> 12) & 0xFF;
	mode = (data >> 8) & 7;
	if((addr & 0xFFF00000) != Apicbase || mode > 1)
		return;
	/*
	 * Bit 2 is the destination mode.  Physical: dest is an APIC id.
	 * Logical (what Linux programs): dest is matched against the
	 * logical id the guest put in its LDR -- in the flat model a bit
	 * mask, which is all that is modelled.  0xFF is everyone either way.
	 */
	if(dest != 0xFF && ((addr & 1<<2) ? (dest & (a->ldr >> 24)) == 0 : dest != a->id))
		return;
	ilock(p);
	vlapicsetirr(a, data & 0xFF);
	p->kick[0] = 1;
	p->nmsi++;
	iunlock(p);
	wakeup(&vm->vcpu[0]->r);
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
	if(p->hungup)
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

	p = PLAT(vm);
	a = &p->lapic[0];
	s = seprint(s, e, "platform tschz %llud io %s\n", p->tschz, p->ioignore ? "ignore" : "exit");
	s = seprint(s, e, "platform handled cpuid %llud msr %llud io %llud mmio %llud hlt %llud intr %llud gp %llud msi %llud\n",
		p->ncpuid, p->nmsr, p->nio, p->nmmio, p->nhlt, p->nintr, p->ngp, p->nmsi);
	s = seprint(s, e, "platform lastgpmsr %#ux lastport %#ux conslost %llud\n", p->lastgpmsr, p->lastport, p->uart.outlost);
	s = seprint(s, e, "pic imr %.2ux/%.2ux irr %.2ux/%.2ux isr %.2ux/%.2ux base %.2ux/%.2ux\n",
		p->pic.c[0].imr, p->pic.c[1].imr, p->pic.c[0].irr, p->pic.c[1].irr,
		p->pic.c[0].isr, p->pic.c[1].isr, p->pic.c[0].base, p->pic.c[1].base);
	s = seprint(s, e, "lapic0 base %#llux svr %#ux lvtt %#ux lint0 %#ux tpr %#ux fire %llud\n",
		a->base, a->svr, a->lvt[LvtTimer], a->lvt[LvtLint0], a->tpr, a->fire);
	s = vmpcistatus(p->pci, s, e);
	return s;
}
