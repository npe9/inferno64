/*
 * The RISC-V H extension as a backend of the portable hypervisor
 * (port/vm.h, doc/genesize-plan.ms phase 15).
 *
 * This kernel runs in machine mode with no translation of its own, so
 * the hypervisor is machine mode too: a guest is entered by MRET with
 * mstatus.MPV set and MPP supervisor, which is VS-mode, its addresses
 * put through the G stage -- hgatp, Sv39x4, the guest's RAM mapped at
 * guest-physical 0 in 2 MiB pages.  What the guest's own supervisor
 * handles -- its page faults, its illegal instructions, its user's
 * ecalls, the VS-level interrupts -- is delegated to it, through
 * medeleg and hedeleg and hideleg; everything else comes back to
 * machine mode, through rvexit (l.s), as an exit: its ecalls (the SBI,
 * which vmplat.c is), the G stage's faults (MMIO), WFI (hstatus.VTW),
 * and the host's own interrupts, which the host then takes.
 *
 * The VS CSRs are the guest's supervisor state and are swapped with
 * it, so vCPUs can share a processor.  Interrupts go to the guest by
 * hvip, which the processor delivers once the guest enables them.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/vm.h"
#include	"vmrv.h"

enum {
	/* CSRs */
	Cmisa		= 0x301,
	Cmedeleg	= 0x302,
	Cmcounteren	= 0x306,
	Cmstatus	= 0x300,
	Cpmpcfg0	= 0x3A0,
	Cpmpaddr0	= 0x3B0,
	Chstatus	= 0x600,
	Chedeleg	= 0x602,
	Chideleg	= 0x603,
	Chcounteren	= 0x606,
	Chtimedelta	= 0x605,
	Chvip		= 0x645,
	Chgatp		= 0x680,
	Cvsstatus	= 0x200,
	Cvsie		= 0x204,
	Cvstvec		= 0x205,
	Cvsscratch	= 0x240,
	Cvsepc		= 0x241,
	Cvscause	= 0x242,
	Cvstval		= 0x243,
	Cvsatp		= 0x280,

	/* mstatus */
	Mie		= 1<<3,
	Mpie		= 1<<7,
	Mpp		= 3<<11,
	MppS		= 1<<11,

	/* hstatus */
	Vtw		= 1<<21,

	/* vsstatus */
	Sie		= 1<<1,
	Spie		= 1<<5,
	Spp		= 1<<8,

	/* exceptions, mcause */
	Einstmisalign	= 0,
	Eillegal	= 2,
	Ebreak		= 3,
	Euecall		= 8,
	Evsecall	= 10,
	Einstpf		= 12,
	Eloadpf		= 13,
	Estorepf	= 15,
	Einstgpf	= 20,
	Eloadgpf	= 21,
	Evirtinsn	= 22,
	Estoregpf	= 23,

	/* the exceptions the guest's supervisor takes itself, as KVM delegates them */
	Guestexc	= 1<<Einstmisalign | 1<<Eillegal | 1<<Ebreak | 1<<Euecall
			| 1<<Einstpf | 1<<Eloadpf | 1<<Estorepf,

	/* G-stage PTEs */
	Pv		= 1<<0,
	Pr		= 1<<1,
	Pw		= 1<<2,
	Px		= 1<<3,
	Pu		= 1<<4,	/* every G-stage access is a user one */
	Pa		= 1<<6,
	Pd		= 1<<7,

	Hgatpsv39x4	= 8,
	Rootsize	= 16*1024,	/* Sv39x4's root: 2048 entries */
	Big		= 2*1024*1024,

	Wfi		= 0x10500073,
};

/*
 * The guest's state.  The part up to f[] is reached from l.s by
 * offset (RV_PC and the rest); keep the two the same.
 */
typedef struct Rvcpu Rvcpu;
struct Rvcpu
{
	uvlong	x[32];		/* 0: x0 to x31, x0 unused */
	uvlong	pc;		/* 256 */
	uvlong	hostsp;		/* 264 */
	uvlong	hostra;		/* 272 */
	uvlong	mstatus;	/* 280: on entry, and as the guest left it */
	uvlong	mcause;		/* 288 */
	uvlong	mtval;		/* 296 */
	uvlong	mtval2;		/* 304 */
	uvlong	mtinst;		/* 312 */
	uvlong	f[32];		/* 320 */
	uvlong	fcsr;		/* 576 */
	uvlong	hostf[32];	/* 584 */
	uvlong	hostfcsr;	/* 840 */

	uvlong	vs[RvNreg-RvVsstatus];	/* the VS CSRs and hvip, by register index */
};

typedef struct Gpt Gpt;
struct Gpt
{
	uvlong	*root;
	uint	ntab;		/* page-table pages, for the info line */
};

extern void	rvrun(Rvcpu*);
extern void	rvhfencegvma(void);
extern uvlong	csrrdmisa(void);
extern uvlong	csrrdmstatus(void);
extern uvlong	csrrdhgatp(void);
extern uvlong	csrrdhstatus(void);
extern uvlong	csrrdhvip(void);
extern uvlong	csrrdvsstatus(void);
extern uvlong	csrrdvsie(void);
extern uvlong	csrrdvstvec(void);
extern uvlong	csrrdvsscratch(void);
extern uvlong	csrrdvsepc(void);
extern uvlong	csrrdvscause(void);
extern uvlong	csrrdvstval(void);
extern uvlong	csrrdvsatp(void);
extern void	csrwrmedeleg(uvlong);
extern void	csrwrmcounteren(uvlong);
extern void	csrwrmstatus(uvlong);
extern void	csrwrpmpcfg0(uvlong);
extern void	csrwrpmpaddr0(uvlong);
extern void	csrwrhstatus(uvlong);
extern void	csrwrhedeleg(uvlong);
extern void	csrwrhideleg(uvlong);
extern void	csrwrhcounteren(uvlong);
extern void	csrwrhtimedelta(uvlong);
extern void	csrwrhvip(uvlong);
extern void	csrwrhgatp(uvlong);
extern void	csrwrvsstatus(uvlong);
extern void	csrwrvsie(uvlong);
extern void	csrwrvstvec(uvlong);
extern void	csrwrvsscratch(uvlong);
extern void	csrwrvsepc(uvlong);
extern void	csrwrvscause(uvlong);
extern void	csrwrvstval(uvlong);
extern void	csrwrvsatp(uvlong);
static uvlong	rdcsr(int);
static void	wrcsr(int, uvlong);

static char *rvregname[RvNreg] = {
	"zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
	"s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
	"a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
	"s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
	"pc",
	"vsstatus", "vsie", "vstvec", "vsscratch", "vsepc", "vscause", "vstval", "vsatp",
	"hvip",
};

static int vscsr[] = {
	Cvsstatus, Cvsie, Cvstvec, Cvsscratch, Cvsepc, Cvscause, Cvstval, Cvsatp, Chvip,
};

/*
 * The CSR instructions take their number in the instruction, so
 * reaching one by a number held in a variable needs a switch; these
 * are the ones this file names.
 */
static uvlong
rdcsr(int csr)
{
	uvlong v;

	switch(csr){
	case Cmisa:	v = csrrdmisa(); break;
	case Cmstatus:	v = csrrdmstatus(); break;
	case Chgatp:	v = csrrdhgatp(); break;
	case Chstatus:	v = csrrdhstatus(); break;
	case Chvip:	v = csrrdhvip(); break;
	case Cvsstatus:	v = csrrdvsstatus(); break;
	case Cvsie:	v = csrrdvsie(); break;
	case Cvstvec:	v = csrrdvstvec(); break;
	case Cvsscratch:	v = csrrdvsscratch(); break;
	case Cvsepc:	v = csrrdvsepc(); break;
	case Cvscause:	v = csrrdvscause(); break;
	case Cvstval:	v = csrrdvstval(); break;
	case Cvsatp:	v = csrrdvsatp(); break;
	default:
		panic("vmrv: rdcsr %#ux", csr);
		v = 0;
	}
	return v;
}

static void
wrcsr(int csr, uvlong v)
{
	switch(csr){
	case Cmedeleg:	csrwrmedeleg(v); break;
	case Cmcounteren:	csrwrmcounteren(v); break;
	case Cmstatus:	csrwrmstatus(v); break;
	case Cpmpcfg0:	csrwrpmpcfg0(v); break;
	case Cpmpaddr0:	csrwrpmpaddr0(v); break;
	case Chstatus:	csrwrhstatus(v); break;
	case Chedeleg:	csrwrhedeleg(v); break;
	case Chideleg:	csrwrhideleg(v); break;
	case Chcounteren:	csrwrhcounteren(v); break;
	case Chtimedelta:	csrwrhtimedelta(v); break;
	case Chvip:	csrwrhvip(v); break;
	case Chgatp:	csrwrhgatp(v); break;
	case Cvsstatus:	csrwrvsstatus(v); break;
	case Cvsie:	csrwrvsie(v); break;
	case Cvstvec:	csrwrvstvec(v); break;
	case Cvsscratch:	csrwrvsscratch(v); break;
	case Cvsepc:	csrwrvsepc(v); break;
	case Cvscause:	csrwrvscause(v); break;
	case Cvstval:	csrwrvstval(v); break;
	case Cvsatp:	csrwrvsatp(v); break;
	default:
		panic("vmrv: wrcsr %#ux", csr);
	}
}

static int
rvprobe(char *why, int nwhy)
{
	uvlong h;

	if((rdcsr(Cmisa) & (1<<('H'-'A'))) == 0){
		snprint(why, nwhy, "the processor has no H extension (misa %#llux)", rdcsr(Cmisa));
		return -1;
	}
	/* hgatp's mode is WARL: one it does not have reads back as bare */
	wrcsr(Chgatp, (uvlong)Hgatpsv39x4<<60);
	h = rdcsr(Chgatp);
	wrcsr(Chgatp, 0);
	if((h>>60) != Hgatpsv39x4){
		snprint(why, nwhy, "the G stage has no Sv39x4 (hgatp %#llux)", h);
		return -1;
	}
	return 0;
}

static void
rvcpuon(void)
{
	/*
	 * Lower privilege needs a PMP entry to reach memory at all:
	 * one region, all of it, read, write and execute.  The G stage
	 * is what confines the guest.
	 */
	wrcsr(Cpmpaddr0, ~0ULL);
	wrcsr(Cpmpcfg0, 0x1F);		/* NAPOT, RWX */
	wrcsr(Cmedeleg, Guestexc);
	wrcsr(Chedeleg, Guestexc);
	wrcsr(Chideleg, RvVssi|RvVsti|RvVsei);
	wrcsr(Cmcounteren, 7);		/* cycle, time, instret */
	wrcsr(Chcounteren, 7);
	wrcsr(Chtimedelta, 0);
	/* WFI comes back as a virtual-instruction exception */
	wrcsr(Chstatus, rdcsr(Chstatus) | Vtw);
}

static void
rvvcpuinit(Vcpu *v)
{
	Rvcpu *r;

	r = mallocalign(sizeof *r, 64, 0, 0);
	if(r == nil)
		error(Enomem);
	memset(r, 0, sizeof *r);
	v->arch = r;
}

static void
rvvcpufree(Vcpu *v)
{
	free(v->arch);
}

uvlong
rvtime(void)
{
	return *(volatile uvlong*)(uintptr)(CLINT + 0xBFF8);	/* mtime */
}

static void
hfencegvma(void)
{
	rvhfencegvma();
}

static void
rvrunvcpu(Vcpu *v, Vmexit *e)
{
	Rvcpu *r;
	Gpt *g;
	int i, s;
	uvlong cause, ms;
	u32int insn;
	uchar *p;

	r = v->arch;
	g = v->vm->gp;
	s = splhi();
	wrcsr(Chgatp, (uvlong)Hgatpsv39x4<<60 | (uvlong)PADDR(g->root)>>PGSHIFT);
	hfencegvma();
	for(i = 0; i < nelem(vscsr); i++)
		wrcsr(vscsr[i], r->vs[i]);
	ms = rdcsr(Cmstatus);
	ms &= ~(Mpp|Mie|(1ULL<<39)|(1ULL<<38));
	r->mstatus = ms | MppS | Mpie | 1ULL<<39;	/* MPV: into VS-mode */
	rvrun(r);
	for(i = 0; i < nelem(vscsr); i++)
		r->vs[i] = rdcsr(vscsr[i]);
	/* not virtualised, and nothing of the guest's, from here on */
	wrcsr(Cmstatus, rdcsr(Cmstatus) & ~((1ULL<<39)|(1ULL<<38)|Mpp));
	wrcsr(Chgatp, 0);
	splx(s);	/* a host interrupt that took the guest out is taken now */

	cause = r->mcause;
	e->raw = cause;
	e->qual = r->mtval;
	e->rip = r->pc;
	if((vlong)cause < 0){
		e->kind = VxExtint;
		return;
	}
	switch((int)cause){
	case Evsecall:
		e->kind = VxCall;
		e->ilen = 4;
		break;
	case Einstgpf:
	case Eloadgpf:
	case Estoregpf:
		e->kind = VxMmio;
		e->gpa = r->mtval2<<2 | (r->mtval & 3);
		e->gva = r->mtval;
		e->access = cause == Eloadgpf ? 1 : cause == Estoregpf ? 2 : 4;
		/*
		 * mtinst holds the access as a transformed instruction,
		 * bit 1 saying whether the original was 32 bits or 16;
		 * without it, the instruction is read from the guest
		 * when its supervisor is not translating.
		 */
		insn = r->mtinst;
		if(insn & 1)
			e->ilen = (insn & 2) ? 4 : 2;
		else if(cause != Einstgpf && (r->vs[RvVsatp-RvVsstatus]>>60) == 0
		&& r->pc + 4 <= v->vm->memsize){
			p = v->vm->mem + r->pc;
			e->ilen = (p[0] & 3) == 3 ? 4 : 2;
		}
		break;
	case Evirtinsn:
		/* mtval holds the instruction */
		if((u32int)r->mtval == Wfi){
			e->kind = VxHlt;
			e->ilen = 4;
			break;
		}
		e->kind = VxException;
		e->vec = cause;
		e->errcode = r->mtval;
		break;
	default:
		e->kind = VxException;
		e->vec = cause;
		e->errcode = r->mtval;
		break;
	}
}

static uvlong
rvgetreg(Vcpu *v, int i)
{
	Rvcpu *r;

	r = v->arch;
	if(i == RvZero)
		return 0;
	if(i < RvPc)
		return r->x[i];
	if(i == RvPc)
		return r->pc;
	if(i < RvNreg)
		return r->vs[i-RvVsstatus];
	error("unknown register");
	return 0;
}

static void
rvsetreg(Vcpu *v, int i, uvlong val)
{
	Rvcpu *r;

	r = v->arch;
	if(i == RvZero)
		return;
	if(i < RvPc)
		r->x[i] = val;
	else if(i == RvPc)
		r->pc = val;
	else if(i < RvNreg)
		r->vs[i-RvVsstatus] = val;
	else
		error("unknown register");
}

static uvlong*
gptab(void)
{
	uvlong *t;

	t = mallocalign(BY2PG, BY2PG, 0, 0);
	if(t == nil)
		error(Enomem);
	memset(t, 0, BY2PG);
	return t;
}

static void
rvgpinit(Vm *vm)
{
	Gpt *g;

	g = malloc(sizeof *g);
	if(g == nil)
		error(Enomem);
	g->root = mallocalign(Rootsize, Rootsize, 0, 0);
	if(g->root == nil){
		free(g);
		error(Enomem);
	}
	memset(g->root, 0, Rootsize);
	g->ntab = 4;
	vm->gp = g;
}

static void
gpfreetab(uvlong *t, int level)
{
	int i;

	if(level > 0)
		for(i = 0; i < 512; i++)
			if((t[i] & (Pv|Pr|Pw|Px)) == Pv)
				gpfreetab(KADDR((t[i]>>10)<<PGSHIFT), level-1);
	free(t);
}

static void
rvgpfree(Vm *vm)
{
	Gpt *g;
	int i;

	g = vm->gp;
	if(g == nil)
		return;
	for(i = 0; i < Rootsize/8; i++)
		if((g->root[i] & (Pv|Pr|Pw|Px)) == Pv)
			gpfreetab(KADDR((g->root[i]>>10)<<PGSHIFT), 1);
	free(g->root);
	free(g);
	vm->gp = nil;
}

/* the entry for gpa at level (2 the root, 0 the 4K one), tables made on the way */
static uvlong*
gpwalk(Gpt *g, uvlong gpa, int level, int make)
{
	uvlong *t, *pte;
	int l;

	t = g->root;
	pte = &t[(gpa>>30) & 0x7FF];
	for(l = 2; l > level; l--){
		if((*pte & Pv) == 0){
			if(!make)
				return nil;
			t = gptab();
			g->ntab++;
			*pte = (uvlong)PADDR(t)>>PGSHIFT<<10 | Pv;
		}else if(*pte & (Pr|Pw|Px))
			error("vmrv: G-stage mapping overlaps a large page");
		else
			t = KADDR((*pte>>10)<<PGSHIFT);
		pte = &t[(gpa>>(12+9*(l-1))) & 0x1FF];
	}
	return pte;
}

static void
rvgpmap(Vm *vm, uvlong gpa, uvlong hpa, uvlong len, int prot)
{
	Gpt *g;
	uvlong *pte, bits, n;

	g = vm->gp;
	bits = Pv|Pu|Pa|Pd;
	if(prot & VmR)
		bits |= Pr;
	if(prot & VmW)
		bits |= Pw|Pr;
	if(prot & VmX)
		bits |= Px;
	while(len > 0){
		if((gpa & (Big-1)) == 0 && (hpa & (Big-1)) == 0 && len >= Big){
			pte = gpwalk(g, gpa, 1, 1);
			n = Big;
		}else{
			pte = gpwalk(g, gpa, 0, 1);
			n = BY2PG;
		}
		*pte = hpa>>PGSHIFT<<10 | bits;
		gpa += n;
		hpa += n;
		len -= n;
	}
	coherence();
	hfencegvma();
}

static void
rvgpunmap(Vm *vm, uvlong gpa, uvlong len)
{
	Gpt *g;
	uvlong *pte;

	g = vm->gp;
	while(len > 0){
		pte = gpwalk(g, gpa, 1, 0);
		if(pte != nil && (*pte & (Pr|Pw|Px)) != 0 && (gpa & (Big-1)) == 0 && len >= Big){
			*pte = 0;
			gpa += Big;
			len -= Big;
			continue;
		}
		pte = gpwalk(g, gpa, 0, 0);
		if(pte != nil)
			*pte = 0;
		gpa += BY2PG;
		len -= BY2PG;
	}
	coherence();
	hfencegvma();
}

static char*
rvinfo(char *p, char *e)
{
	return seprint(p, e, "riscv-h misa %#llux hstatus %#llux g-stage sv39x4\n",
		rdcsr(Cmisa), rdcsr(Chstatus));
}

/*
 * An interrupt is one of the VS-level ones, made pending in hvip for
 * the processor to deliver; an exception is taken by the guest's
 * supervisor as the processor would have: sepc, scause and stval set,
 * the previous mode and interrupt enable kept, and on to stvec.
 */
static void
rvinject(Vcpu *v, int type, int vec, int haserr, u32int err)
{
	Rvcpu *r;
	uvlong *st;

	r = v->arch;
	if(type == VeIntr){
		if(vec == 2 || vec == 6 || vec == 10)
			r->vs[RvHvip-RvVsstatus] |= 1<<vec;
		return;
	}
	st = &r->vs[RvVsstatus-RvVsstatus];
	r->vs[RvVsepc-RvVsstatus] = r->pc;
	r->vs[RvVscause-RvVsstatus] = vec;
	r->vs[RvVstval-RvVsstatus] = haserr ? err : 0;
	*st &= ~(Spie|Spp);
	if(*st & Sie)
		*st |= Spie;
	*st |= Spp;	/* from VS-mode: the hypervisor does not know VU from VS here */
	*st &= ~Sie;
	r->pc = r->vs[RvVstvec-RvVsstatus] & ~3ULL;
}

static int
rvcanintr(Vcpu*)
{
	return 1;	/* the processor delivers hvip's when the guest allows */
}

static void
rvirqwin(Vcpu*, int)
{
}

static int
rvrdmsr(Vcpu*, u32int, uvlong*)
{
	return -1;
}

static int
rvwrmsr(Vcpu*, u32int, uvlong)
{
	return -1;
}

static Vmops rvops = {
	"riscv-h",
	rvprobe,
	rvcpuon,
	rvvcpuinit,
	rvvcpufree,
	rvrunvcpu,
	rvgetreg,
	rvsetreg,
	rvgpinit,
	rvgpfree,
	rvgpmap,
	rvinfo,
	rvinject,
	rvcanintr,
	rvirqwin,
	rvrdmsr,
	rvwrmsr,
	rvgpunmap,
	rvregname,
	RvNreg,
	RvPc,
};

void
vmrvlink(void)
{
	vmregister(&rvops);
}
