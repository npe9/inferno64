/*
 * AMD SVM: the second backend of the portable VM layer (../port/vm.h),
 * beside vmx.c.  Written to the same Vmops so that the layer above is
 * tested against two different processor extensions, and because SVM
 * is what QEMU's TCG emulates on this bench (it has no VMX).
 *
 * Nested paging is required.  The guest starts as vmx.c starts one --
 * 32-bit flat protected mode, paging off -- which SVM runs natively.
 * Every RDMSR and WRMSR and every i/o port access exits (the
 * permission maps are all ones) and is handed up.  The ASID is 1 for
 * every guest and the whole TLB is flushed on each VMRUN: correct,
 * and the simplest thing; ASIDs per machine are an optimisation.
 *
 * Segment access rights travel through #H in VMX's layout (type, S,
 * DPL, P in bits 0-7; AVL, L, D/B, G in 12-15; unusable in 16); the
 * VMCB keeps them packed into twelve bits, and they are converted here.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/vm.h"

typedef struct Svmregs Svmregs;
typedef struct Svmcpu Svmcpu;

/* known to svmrun in l.s */
struct Svmregs
{
	u64int	bx, cx, dx, si, di, bp;
	u64int	r8, r9, r10, r11, r12, r13, r14, r15;
	u64int	h12, h13, h14, h15;
};

extern int svmrun(uvlong, Svmregs*, uvlong);
extern void _clts(void);

enum {
	VM_CR_MSR	= 0xC0010114,
	VM_HSAVE_PA_MSR	= 0xC0010117,
	EferSVME	= 1<<12,

	/* VMCB control area */
	Icr		= 0x000,
	Iexc		= 0x008,
	Ivec3		= 0x00C,
	Ivec4		= 0x010,
	Iopm		= 0x040,
	Msrpm		= 0x048,
	Asid		= 0x058,
	Tlbctl		= 0x05C,
	Intshadow	= 0x068,
	Exitcode	= 0x070,
	Exitinfo1	= 0x078,
	Exitinfo2	= 0x080,
	Exitintinfo	= 0x088,
	Npenable	= 0x090,
	Eventinj	= 0x0A8,
	Ncr3		= 0x0B0,
	Clean		= 0x0C0,
	Nrip		= 0x0C8,

	/* VMCB state save area */
	Ses		= 0x400,
	Scs		= 0x410,
	Sss		= 0x420,
	Sds		= 0x430,
	Sfs		= 0x440,
	Sgs		= 0x450,
	Sgdtr		= 0x460,
	Sldtr		= 0x470,
	Sidtr		= 0x480,
	Str		= 0x490,
	Scpl		= 0x4CB,
	Sefer		= 0x4D0,
	Scr4		= 0x548,
	Scr3		= 0x550,
	Scr0		= 0x558,
	Sdr7		= 0x560,
	Sdr6		= 0x568,
	Srflags		= 0x570,
	Srip		= 0x578,
	Srsp		= 0x5D8,
	Srax		= 0x5F8,
	Scr2		= 0x640,
	Sgpat		= 0x668,

	/* vector 3 intercepts */
	IntINTR		= 1<<0,
	IntNMI		= 1<<1,
	IntCPUID	= 1<<18,
	IntHLT		= 1<<24,
	IntIOIO		= 1<<27,
	IntMSR		= 1<<28,
	IntSHUTDOWN	= 1<<31,
	/* vector 4 */
	IntVMRUN	= 1<<0,
	IntVMMCALL	= 1<<1,

	/* nested page table entry */
	NptP	= 1<<0,
	NptW	= 1<<1,
	NptU	= 1<<2,
};

struct Svmcpu
{
	uchar	*vmcb;		/* 4 KiB, page aligned */
	FPsave	*fp;
	Svmregs	regs;
};

static int nrips;		/* the VMCB reports the next rip */
static int nasid;
static uchar *iopm;		/* 12 KiB, all ones: every port exits */
static uchar *msrpm;		/* 8 KiB, all ones: every MSR exits */
static uchar *hsave[MAXMACH];	/* VM_HSAVE_PA, per processor */
static uchar *hvmsave[MAXMACH];	/* the host's VMSAVE area, per processor */

#define	V8(x, o)	(*(u8int*)((x)->vmcb+(o)))
#define	V16(x, o)	(*(u16int*)((x)->vmcb+(o)))
#define	V32(x, o)	(*(u32int*)((x)->vmcb+(o)))
#define	V64(x, o)	(*(u64int*)((x)->vmcb+(o)))

static int
svmprobe(char *why, int nwhy)
{
	u32int r[4];
	vlong vmcr;

	cpuid(0x80000000, 0, r);
	if(r[0] < 0x8000000A){
		snprint(why, nwhy, "no SVM leaf in CPUID");
		return -1;
	}
	cpuid(0x80000001, 0, r);
	if((r[2] & 1<<2) == 0){
		snprint(why, nwhy, "no SVM in CPUID");
		return -1;
	}
	if(rdmsr(VM_CR_MSR, &vmcr) == 0 && (vmcr & 1<<4) != 0){
		snprint(why, nwhy, "SVM disabled by firmware (VM_CR %#llux)", vmcr);
		return -1;
	}
	cpuid(0x8000000A, 0, r);
	if((r[3] & 1<<0) == 0){
		snprint(why, nwhy, "no nested paging");
		return -1;
	}
	nasid = r[1];
	nrips = (r[3] & 1<<3) != 0;
	iopm = mallocalign(3*BY2PG, BY2PG, 0, 0);
	msrpm = mallocalign(2*BY2PG, BY2PG, 0, 0);
	if(iopm == nil || msrpm == nil){
		snprint(why, nwhy, "no memory for the permission maps");
		return -1;
	}
	memset(iopm, 0xFF, 3*BY2PG);
	memset(msrpm, 0xFF, 2*BY2PG);
	return 0;
}

static char*
svminfo(char *p, char *e)
{
	return seprint(p, e, "svm npt asids %d nrips %d\n", nasid, nrips);
}

static void
svmcpuon(void)
{
	uchar *h, *v;
	vlong efer;

	if(hsave[m->machno] != nil)
		return;
	h = mallocalign(BY2PG, BY2PG, 0, 0);
	v = mallocalign(BY2PG, BY2PG, 0, 0);
	if(h == nil || v == nil){
		free(h);
		free(v);
		error(Enomem);
	}
	memset(h, 0, BY2PG);
	memset(v, 0, BY2PG);
	rdmsr(Efer, &efer);
	wrmsr(Efer, efer | EferSVME);
	wrmsr(VM_HSAVE_PA_MSR, PADDR(h));
	hsave[m->machno] = h;
	hvmsave[m->machno] = v;
	print("svm: cpu%d in SVM operation\n", m->machno);
}

/* VMX access rights to the VMCB's packed attributes, and back */
static u16int
toattr(uvlong ar)
{
	return (ar & 0xFF) | (ar >> 4 & 0xF00);
}

static uvlong
fromattr(u16int a)
{
	return (a & 0xFF) | (uvlong)(a & 0xF00) << 4;
}

static void
setseg(Svmcpu *x, int o, int sel, uvlong ar)
{
	V16(x, o) = sel;
	V16(x, o+2) = toattr(ar);
	V32(x, o+4) = 0xFFFFFFFF;
	V64(x, o+8) = 0;
}

static void
svmvcpuinit(Vcpu *v)
{
	Svmcpu *x;
	int s;

	x = mallocz(sizeof *x, 1);
	if(x == nil)
		error(Enomem);
	x->vmcb = mallocalign(BY2PG, BY2PG, 0, 0);
	x->fp = mallocalign(sizeof(FPsave), 64, 0, 0);
	if(x->vmcb == nil || x->fp == nil){
		free(x->vmcb);
		free(x->fp);
		free(x);
		error(Enomem);
	}
	memset(x->vmcb, 0, BY2PG);
	memset(x->fp, 0, sizeof(FPsave));
	v->arch = x;

	V32(x, Ivec3) = IntINTR|IntNMI|IntCPUID|IntHLT|IntIOIO|IntMSR|IntSHUTDOWN;
	V32(x, Ivec4) = IntVMRUN|IntVMMCALL;	/* VMRUN must be intercepted */
	V64(x, Iopm) = PADDR(iopm);
	V64(x, Msrpm) = PADDR(msrpm);
	V32(x, Asid) = 1;
	V8(x, Tlbctl) = 1;			/* flush everything on VMRUN */
	V64(x, Npenable) = 1;
	V64(x, Ncr3) = PADDR(v->vm->gp);
	V32(x, Clean) = 0;

	/* the guest, as vmx.c starts it */
	setseg(x, Scs, 0x08, 0xC09B);
	setseg(x, Sds, 0x10, 0xC093);
	setseg(x, Ses, 0x10, 0xC093);
	setseg(x, Sfs, 0x10, 0xC093);
	setseg(x, Sgs, 0x10, 0xC093);
	setseg(x, Sss, 0x10, 0xC093);
	setseg(x, Str, 0, 0x8B);
	V32(x, Str+4) = 0xFFFF;
	setseg(x, Sldtr, 0, 0x82);
	V32(x, Sldtr+4) = 0;
	V32(x, Sgdtr+4) = 0xFFFF;
	V32(x, Sidtr+4) = 0xFFFF;
	V8(x, Scpl) = 0;
	V64(x, Sefer) = EferSVME;
	V64(x, Scr0) = 0x11;			/* PE, ET */
	V64(x, Scr3) = 0;
	V64(x, Scr4) = 0;
	V64(x, Sdr7) = 0x400;
	V64(x, Sdr6) = 0xFFFF0FF0;
	V64(x, Srflags) = 2;
	V64(x, Sgpat) = 0x0007040600070406ULL;

	s = splhi();
	fpuprocsave(up);
	fpinit();
	fpsave(x->fp);
	splx(s);
}

static void
svmvcpufree(Vcpu *v)
{
	Svmcpu *x;

	x = v->arch;
	if(x == nil)
		return;
	free(x->vmcb);
	free(x->fp);
	free(x);
}

static void
decode(Svmcpu *x, Vmexit *e)
{
	u64int code, i1, i2;
	int r;

	code = V64(x, Exitcode);
	i1 = V64(x, Exitinfo1);
	i2 = V64(x, Exitinfo2);
	e->raw = code;
	e->qual = i1;
	e->rip = V64(x, Srip);
	e->ilen = 0;
	if(nrips && V64(x, Nrip) > e->rip)
		e->ilen = V64(x, Nrip) - e->rip;
	if(code == ~0ULL){
		e->kind = VxEntryfail;
		return;
	}
	if(code >= 0x40 && code < 0x60){
		e->kind = VxException;
		e->vec = code - 0x40;
		e->errcode = i1;
		return;
	}
	switch(code){
	case 0x60:	/* INTR */
	case 0x61:	/* NMI */
		e->kind = VxExtint;
		break;
	case 0x64:
		e->kind = VxIntrwin;
		break;
	case 0x72:
		e->kind = VxCpuid;
		if(e->ilen == 0)
			e->ilen = 2;
		break;
	case 0x78:
		e->kind = VxHlt;
		if(e->ilen == 0)
			e->ilen = 1;
		break;
	case 0x7B:	/* IOIO */
		e->kind = VxIo;
		e->in = i1 & 1;
		e->string = (i1 >> 2) & 1;
		e->rep = (i1 >> 3) & 1;
		r = (i1 >> 4) & 7;
		e->size = r & 4 ? 4 : r & 2 ? 2 : 1;
		e->port = (i1 >> 16) & 0xFFFF;
		e->data = V64(x, Srax);
		if(i2 > e->rip)
			e->ilen = i2 - e->rip;	/* exitinfo2 is the next rip */
		break;
	case 0x7C:
		e->kind = (i1 & 1) ? VxWrmsr : VxRdmsr;
		e->msr = x->regs.cx;
		if(e->ilen == 0)
			e->ilen = 2;
		break;
	case 0x7F:
		e->kind = VxTriple;
		break;
	case 0x81:
		e->kind = VxCall;
		if(e->ilen == 0)
			e->ilen = 3;
		break;
	case 0x400:	/* nested page fault */
		e->kind = VxMmio;
		e->gpa = i2;
		e->access = 1 | ((i1 & 2) ? 2 : 0) | ((i1 & 16) ? 4 : 0);
		if(i1 & 2)
			e->access &= ~1;
		break;
	default:
		e->kind = VxOther;
		break;
	}
}

static void
svmrunvcpu(Vcpu *v, Vmexit *e)
{
	Svmcpu *x;
	int s;

	x = v->arch;
	s = splhi();
	fpuprocsave(up);
	_clts();
	fprestore(x->fp);
	svmrun(PADDR(x->vmcb), &x->regs, PADDR(hvmsave[m->machno]));
	_clts();
	fpsave(x->fp);		/* leaves TS set */
	splx(s);
	decode(x, e);
}

static int segoff[] = { Scs, Sds, Ses, Sfs, Sgs, Sss, Str, Sldtr };

static u64int*
gpr(Svmcpu *x, int r)
{
	switch(r){
	case VRbx: return &x->regs.bx;
	case VRcx: return &x->regs.cx;
	case VRdx: return &x->regs.dx;
	case VRsi: return &x->regs.si;
	case VRdi: return &x->regs.di;
	case VRbp: return &x->regs.bp;
	case VR8: return &x->regs.r8;
	case VR9: return &x->regs.r9;
	case VR10: return &x->regs.r10;
	case VR11: return &x->regs.r11;
	case VR12: return &x->regs.r12;
	case VR13: return &x->regs.r13;
	case VR14: return &x->regs.r14;
	case VR15: return &x->regs.r15;
	}
	return nil;
}

static uvlong
svmgetreg(Vcpu *v, int r)
{
	Svmcpu *x;
	u64int *p;
	int o;

	x = v->arch;
	if((p = gpr(x, r)) != nil)
		return *p;
	if(r >= VCs && r <= VLdtrattr){
		o = segoff[(r-VCs)/4];
		switch((r-VCs)%4){
		case 0: return V16(x, o);
		case 1: return V64(x, o+8);
		case 2: return V32(x, o+4);
		case 3: return fromattr(V16(x, o+2));
		}
	}
	switch(r){
	case VRax: return V64(x, Srax);
	case VRsp: return V64(x, Srsp);
	case VRip: return V64(x, Srip);
	case VRflags: return V64(x, Srflags);
	case VCr0: return V64(x, Scr0);
	case VCr2: return V64(x, Scr2);
	case VCr3: return V64(x, Scr3);
	case VCr4: return V64(x, Scr4);
	case VEfer: return V64(x, Sefer) & ~(uvlong)EferSVME;
	case VGdtrbase: return V64(x, Sgdtr+8);
	case VGdtrlimit: return V32(x, Sgdtr+4);
	case VIdtrbase: return V64(x, Sidtr+8);
	case VIdtrlimit: return V32(x, Sidtr+4);
	}
	error("svm: no such register");
	return 0;
}

static void
svmsetreg(Vcpu *v, int r, uvlong val)
{
	Svmcpu *x;
	u64int *p;
	int o;

	x = v->arch;
	if((p = gpr(x, r)) != nil){
		*p = val;
		return;
	}
	if(r >= VCs && r <= VLdtrattr){
		o = segoff[(r-VCs)/4];
		switch((r-VCs)%4){
		case 0: V16(x, o) = val; break;
		case 1: V64(x, o+8) = val; break;
		case 2: V32(x, o+4) = val; break;
		case 3: V16(x, o+2) = toattr(val); break;
		}
		if(r == VSsattr)
			V8(x, Scpl) = (val >> 5) & 3;	/* CPL is SS.DPL */
		return;
	}
	switch(r){
	case VRax: V64(x, Srax) = val; return;
	case VRsp: V64(x, Srsp) = val; return;
	case VRip: V64(x, Srip) = val; return;
	case VRflags: V64(x, Srflags) = val | 2; return;
	case VCr0: V64(x, Scr0) = val; return;
	case VCr2: V64(x, Scr2) = val; return;
	case VCr3: V64(x, Scr3) = val; return;
	case VCr4: V64(x, Scr4) = val; return;
	case VEfer: V64(x, Sefer) = val | EferSVME; return;	/* VMRUN requires it */
	case VGdtrbase: V64(x, Sgdtr+8) = val; return;
	case VGdtrlimit: V32(x, Sgdtr+4) = val; return;
	case VIdtrbase: V64(x, Sidtr+8) = val; return;
	case VIdtrlimit: V32(x, Sidtr+4) = val; return;
	}
	error("svm: no such register");
}

/*
 * Nested page tables: the ordinary four-level x86-64 format, every
 * entry user-accessible because the processor treats each nested
 * access as a user one.
 */
static uvlong*
nptwalk(uvlong *tab, uvlong gpa)
{
	uvlong *nt;
	int i;

	for(i = 3; i >= 1; i--){
		tab += (gpa >> (12 + 9*i)) & 0x1FF;
		if((*tab & NptP) == 0){
			nt = mallocalign(BY2PG, BY2PG, 0, 0);
			if(nt == nil)
				error(Enomem);
			memset(nt, 0, BY2PG);
			*tab = PADDR(nt) | NptP|NptW|NptU;
		}
		tab = (uvlong*)(uintptr)(*tab & ~0xFFFULL & ((1ULL<<52)-1));
	}
	return tab + ((gpa >> 12) & 0x1FF);
}

static void
svmgpinit(Vm *vm)
{
	vm->gp = mallocalign(BY2PG, BY2PG, 0, 0);
	if(vm->gp == nil)
		error(Enomem);
	memset(vm->gp, 0, BY2PG);
}

static void
nptfree(uvlong *tab, int level)
{
	int i;

	if(level > 0)
		for(i = 0; i < 512; i++)
			if(tab[i] & NptP)
				nptfree((uvlong*)(uintptr)(tab[i] & ~0xFFFULL & ((1ULL<<52)-1)), level-1);
	free(tab);
}

static void
svmgpfree(Vm *vm)
{
	if(vm->gp != nil)
		nptfree(vm->gp, 3);
	vm->gp = nil;
}

static void
svmgpmap(Vm *vm, uvlong gpa, uvlong hpa, uvlong len, int prot)
{
	uvlong e, bits;

	if((gpa | hpa | len) & 0xFFF)
		error(Ebadarg);
	bits = NptU;
	if(prot & (VmR|VmX))
		bits |= NptP;
	if(prot & VmW)
		bits |= NptP|NptW;
	for(e = gpa + len; gpa < e; gpa += BY2PG, hpa += BY2PG)
		*nptwalk(vm->gp, gpa) = hpa | bits;
	/* every VMRUN flushes the whole TLB (Tlbctl), so nothing to do */
}

static Vmops svmops = {
	"svm",
	svmprobe,
	svmcpuon,
	svmvcpuinit,
	svmvcpufree,
	svmrunvcpu,
	svmgetreg,
	svmsetreg,
	svmgpinit,
	svmgpfree,
	svmgpmap,
	svminfo,
};

void
svmlink(void)
{
	vmregister(&svmops);
}
