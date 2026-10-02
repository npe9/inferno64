/*
 * Intel VMX: the reference backend of the portable VM layer
 * (../port/vm.h, ../port/devvm.c; doc/genesize-plan.ms, section 3).
 *
 * Taken from 9front's devvmx.c (os/9front/pc/devvmx.c) and cut down to
 * the processor side: VMXON, the VMCS, EPT, entry and exit.  What
 * 9front's vmx(1) does in user space -- instruction decoding and
 * device models -- is not here; an exit this file does not decode is
 * handed up as VxOther with its raw reason.
 *
 * Differences from 9front that matter:
 *
 * - Guest memory is kernel memory devvm.c allocated, not a user
 *   segment, and EPT maps it 4 KiB at a time.
 * - MSRs: every RDMSR and WRMSR exits (the bitmap is all ones) and
 *   is handed up, so the guest cannot reach a host MSR and there are
 *   no MSR load/store areas.  EFER and PAT are switched by the VMCS
 *   entry and exit controls.
 * - The exit path in l.s restores the host's R12-R15 from the register
 *   block rather than reloading up from Mach: this kernel's 6c
 *   reserves R12 and R13 (R13 is the Dis context, curP), and its Mach
 *   does not have up where 9front's does.
 * - No VPID: the TLB is flushed on every entry and exit.  Correct, and
 *   slower; VPID is a later optimisation.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/vm.h"

extern int vmxon(u64int);
extern int vmxoff(void);
extern int vmclear(u64int);
extern int vmptrld(u64int);
extern int vmread(u32int, uintptr*);
extern int vmwrite(u32int, uintptr);
extern int invept(u32int, uvlong, uvlong);

typedef struct Vmxregs Vmxregs;
typedef struct Vmxcpu Vmxcpu;

/*
 * The block vmlaunch() and vmrestore() in l.s read and write; the
 * offsets are known to the assembler.
 */
struct Vmxregs
{
	u64int	ax, bx, cx, dx, si, di, bp;
	u64int	r8, r9, r10, r11, r12, r13, r14, r15;
	u64int	h12, h13, h14, h15;	/* the host's, across the guest */
};

extern int vmlaunch(Vmxregs*, int);
extern void _clts(void);

enum {
	VMX_BASIC_MSR = 0x480,
	VMX_PINB_CTLS_MSR = 0x481,
	VMX_PROCB_CTLS_MSR = 0x482,
	VMX_VMEXIT_CTLS_MSR = 0x483,
	VMX_VMENTRY_CTLS_MSR = 0x484,
	VMX_MISC_MSR = 0x485,
	VMX_CR0_FIXED0 = 0x486,
	VMX_CR0_FIXED1 = 0x487,
	VMX_CR4_FIXED0 = 0x488,
	VMX_CR4_FIXED1 = 0x489,
	VMX_PROCB_CTLS2_MSR = 0x48B,
	VMX_EPT_VPID_CAP_MSR = 0x48C,
	VMX_TRUE_PINB_CTLS_MSR = 0x48D,
	VMX_TRUE_PROCB_CTLS_MSR = 0x48E,
	VMX_TRUE_EXIT_CTLS_MSR = 0x48F,
	VMX_TRUE_ENTRY_CTLS_MSR = 0x490,
	FEATURE_CONTROL_MSR = 0x3A,
	PAT_MSR = 0x277,

	PINB_CTLS = 0x4000,
	PINB_EXITIRQ = 1<<0,
	PINB_EXITNMI = 1<<3,

	PROCB_CTLS = 0x4002,
	PROCB_IRQWIN = 1<<2,
	PROCB_EXITHLT = 1<<7,
	PROCB_EXITMWAIT = 1<<10,
	PROCB_EXITMOVDR = 1<<23,
	PROCB_EXITIO = 1<<24,
	PROCB_MSRBITMAP = 1<<28,
	PROCB_EXITMONITOR = 1<<29,
	PROCB_USECTLS2 = 1<<31,

	PROCB_CTLS2 = 0x401E,
	PROCB_EPT = 1<<1,
	PROCB_UNRESTR = 1<<7,

	EXC_BITMAP = 0x4004,
	PFAULT_MASK = 0x4006,
	PFAULT_MATCH = 0x4008,
	CR3_TARGCNT = 0x400a,
	MSR_BITMAP = 0x2004,

	VMEXIT_CTLS = 0x400c,
	VMEXIT_ST_DEBUG = 1<<2,
	VMEXIT_HOST64 = 1<<9,
	VMEXIT_ST_IA32_PAT = 1<<18,
	VMEXIT_LD_IA32_PAT = 1<<19,
	VMEXIT_ST_IA32_EFER = 1<<20,
	VMEXIT_LD_IA32_EFER = 1<<21,
	VMEXIT_MSRSTCNT = 0x400e,
	VMEXIT_MSRLDCNT = 0x4010,

	VMENTRY_CTLS = 0x4012,
	VMENTRY_LD_DEBUG = 1<<2,
	VMENTRY_GUEST64 = 1<<9,
	VMENTRY_LD_IA32_PAT = 1<<14,
	VMENTRY_LD_IA32_EFER = 1<<15,
	VMENTRY_MSRLDCNT = 0x4014,
	VMENTRY_INTRINFO = 0x4016,

	VMCS_LINK = 0x2800,

	GUEST_ES = 0x800,
	GUEST_CS = 0x802,
	GUEST_SS = 0x804,
	GUEST_DS = 0x806,
	GUEST_FS = 0x808,
	GUEST_GS = 0x80A,
	GUEST_LDTR = 0x80C,
	GUEST_TR = 0x80E,
	GUEST_CR0 = 0x6800,
	GUEST_CR3 = 0x6802,
	GUEST_CR4 = 0x6804,
	GUEST_ESLIMIT = 0x4800,
	GUEST_CSLIMIT = 0x4802,
	GUEST_SSLIMIT = 0x4804,
	GUEST_DSLIMIT = 0x4806,
	GUEST_FSLIMIT = 0x4808,
	GUEST_GSLIMIT = 0x480A,
	GUEST_LDTRLIMIT = 0x480C,
	GUEST_TRLIMIT = 0x480E,
	GUEST_GDTRLIMIT = 0x4810,
	GUEST_IDTRLIMIT = 0x4812,
	GUEST_ESPERM = 0x4814,
	GUEST_CSPERM = 0x4816,
	GUEST_SSPERM = 0x4818,
	GUEST_DSPERM = 0x481A,
	GUEST_FSPERM = 0x481C,
	GUEST_GSPERM = 0x481E,
	GUEST_LDTRPERM = 0x4820,
	GUEST_TRPERM = 0x4822,
	GUEST_CANINTR = 0x4824,
	GUEST_ACTIVITY = 0x4826,
	GUEST_CR0MASK = 0x6000,
	GUEST_CR4MASK = 0x6002,
	GUEST_CR0SHADOW = 0x6004,
	GUEST_CR4SHADOW = 0x6006,
	GUEST_ESBASE = 0x6806,
	GUEST_CSBASE = 0x6808,
	GUEST_SSBASE = 0x680A,
	GUEST_DSBASE = 0x680C,
	GUEST_FSBASE = 0x680E,
	GUEST_GSBASE = 0x6810,
	GUEST_LDTRBASE = 0x6812,
	GUEST_TRBASE = 0x6814,
	GUEST_GDTRBASE = 0x6816,
	GUEST_IDTRBASE = 0x6818,
	GUEST_DR7 = 0x681A,
	GUEST_RSP = 0x681C,
	GUEST_RIP = 0x681E,
	GUEST_RFLAGS = 0x6820,
	GUEST_PENDDBG = 0x6822,
	GUEST_IA32_DEBUGCTL = 0x2802,
	GUEST_IA32_PAT = 0x2804,
	GUEST_IA32_EFER = 0x2806,

	HOST_ES = 0xC00,
	HOST_CS = 0xC02,
	HOST_SS = 0xC04,
	HOST_DS = 0xC06,
	HOST_FS = 0xC08,
	HOST_GS = 0xC0A,
	HOST_TR = 0xC0C,
	HOST_CR0 = 0x6C00,
	HOST_CR3 = 0x6C02,
	HOST_CR4 = 0x6C04,
	HOST_FSBASE = 0x6C06,
	HOST_GSBASE = 0x6C08,
	HOST_TRBASE = 0x6C0A,
	HOST_GDTR = 0x6C0C,
	HOST_IDTR = 0x6C0E,
	HOST_IA32_PAT = 0x2C00,
	HOST_IA32_EFER = 0x2C02,

	VM_INSTRERR = 0x4400,
	VM_EXREASON = 0x4402,
	VM_EXINTRINFO = 0x4404,
	VM_EXINTRCODE = 0x4406,
	VM_EXINSTRLEN = 0x440C,
	VM_EXQUALIF = 0x6400,
	VM_GUESTVA = 0x640A,
	VM_GUESTPA = 0x2400,

	VM_EPTP = 0x201A,

	INVEPTSINGLE = 1,
	INVEPTALL = 2,

	CR0PE = 1<<0,
	CR0NE = 1<<5,
	CR0PG = 1<<31,
	CR4VMXE = 1<<13,
	EFERLMA = 1<<10,

	/* EPT leaf: read, write, execute, memory type WB, ignore PAT */
	EptR = 1<<0,
	EptW = 1<<1,
	EptX = 1<<2,
	EptWB = 6<<3,
};

struct Vmxcpu
{
	uchar	*vmcs;		/* 4 KiB, page aligned */
	uchar	*msrbits;	/* 4 KiB, page aligned */
	FPsave	*fp;		/* guest floating point, 64-byte aligned */
	Vmxregs	regs;
	uintptr	cr2;
	u32int	entryctls;
	int	launched;
	int	flushept;
};

static int vmxrev;		/* VMCS revision identifier */
static uvlong cr0fixed0, cr0fixed1, cr4fixed0, cr4fixed1;
static u32int pinctls, procctls, procctls2, exitctls, entryctls;
static int eptwb;		/* EPT paging structures may be WB */
static uchar *vmxonpage[MAXMACH];
static Vmxcpu *vmxcur[MAXMACH];	/* VMCS current on each processor */

static uvlong
rdmsrv(int msr)
{
	vlong v;

	if(rdmsr(msr, &v) < 0)
		error("vmx: rdmsr failed");
	return v;
}

/*
 * The allowed settings of a control: bits that must be 1 are the low
 * word of the capability MSR, bits that may be 1 the high word.
 */
static u32int
ctlbits(uvlong cap, u32int want)
{
	return ((u32int)cap | want) & (u32int)(cap >> 32);
}

static uvlong
vmcsread(u32int f)
{
	uintptr v;

	v = 0;
	if(vmread(f, &v) < 0)
		error("vmx: vmread failed");
	return v;
}

static void
vmcswrite(u32int f, uvlong v)
{
	char buf[64];

	if(vmwrite(f, v) < 0){
		snprint(buf, sizeof buf, "vmx: vmwrite %#ux = %#llux failed", f, v);
		error(buf);
	}
}

static int
vmxprobe(char *why, int nwhy)
{
	u32int r[4];
	uvlong b, c, c2;
	vlong fc;

	cpuid(1, 0, r);
	if((r[2] & 1<<5) == 0){
		snprint(why, nwhy, "no VMX in CPUID");
		return -1;
	}
	/*
	 * IA32_FEATURE_CONTROL: bit 0 locks it, bit 2 allows VMXON
	 * outside SMX.  Firmware normally locks it either way; if it was
	 * left unlocked, allow VMX and lock it, as firmware would.
	 */
	if(rdmsr(FEATURE_CONTROL_MSR, &fc) < 0){
		snprint(why, nwhy, "no IA32_FEATURE_CONTROL");
		return -1;
	}
	if((fc & 5) != 5){
		if((fc & 1) == 0){
			wrmsr(FEATURE_CONTROL_MSR, fc | 5);
			rdmsr(FEATURE_CONTROL_MSR, &fc);
		}
		if((fc & 5) != 5){
			snprint(why, nwhy, "VMX disabled by firmware (IA32_FEATURE_CONTROL %#llux)", fc);
			return -1;
		}
	}
	if(rdmsr(VMX_BASIC_MSR, (vlong*)&b) < 0
	|| rdmsr(VMX_PROCB_CTLS_MSR, (vlong*)&c) < 0){
		snprint(why, nwhy, "no VMX capability MSRs");
		return -1;
	}
	if((c >> 32 & PROCB_USECTLS2) == 0
	|| rdmsr(VMX_PROCB_CTLS2_MSR, (vlong*)&c2) < 0){
		snprint(why, nwhy, "no secondary processor controls");
		return -1;
	}
	if((c2 >> 32 & PROCB_EPT) == 0 || (c2 >> 32 & PROCB_UNRESTR) == 0){
		snprint(why, nwhy, "no EPT or no unrestricted guest");
		return -1;
	}
	vmxrev = b & 0x7FFFFFFF;
	eptwb = (rdmsrv(VMX_EPT_VPID_CAP_MSR) & 1<<14) != 0;
	cr0fixed0 = rdmsrv(VMX_CR0_FIXED0);
	cr0fixed1 = rdmsrv(VMX_CR0_FIXED1);
	cr4fixed0 = rdmsrv(VMX_CR4_FIXED0);
	cr4fixed1 = rdmsrv(VMX_CR4_FIXED1);

	/* the TRUE MSRs, when there, allow clearing default-1 bits */
	if(b & 1ULL<<55){
		pinctls = ctlbits(rdmsrv(VMX_TRUE_PINB_CTLS_MSR), PINB_EXITIRQ|PINB_EXITNMI);
		procctls = ctlbits(rdmsrv(VMX_TRUE_PROCB_CTLS_MSR),
			PROCB_EXITHLT|PROCB_EXITMWAIT|PROCB_EXITMONITOR|PROCB_EXITMOVDR|
			PROCB_EXITIO|PROCB_MSRBITMAP|PROCB_USECTLS2);
		exitctls = ctlbits(rdmsrv(VMX_TRUE_EXIT_CTLS_MSR),
			VMEXIT_HOST64|VMEXIT_ST_DEBUG|VMEXIT_ST_IA32_PAT|VMEXIT_LD_IA32_PAT|
			VMEXIT_ST_IA32_EFER|VMEXIT_LD_IA32_EFER);
		entryctls = ctlbits(rdmsrv(VMX_TRUE_ENTRY_CTLS_MSR),
			VMENTRY_LD_DEBUG|VMENTRY_LD_IA32_PAT|VMENTRY_LD_IA32_EFER);
	}else{
		pinctls = ctlbits(rdmsrv(VMX_PINB_CTLS_MSR), PINB_EXITIRQ|PINB_EXITNMI);
		procctls = ctlbits(c,
			PROCB_EXITHLT|PROCB_EXITMWAIT|PROCB_EXITMONITOR|PROCB_EXITMOVDR|
			PROCB_EXITIO|PROCB_MSRBITMAP|PROCB_USECTLS2);
		exitctls = ctlbits(rdmsrv(VMX_VMEXIT_CTLS_MSR),
			VMEXIT_HOST64|VMEXIT_ST_DEBUG|VMEXIT_ST_IA32_PAT|VMEXIT_LD_IA32_PAT|
			VMEXIT_ST_IA32_EFER|VMEXIT_LD_IA32_EFER);
		entryctls = ctlbits(rdmsrv(VMX_VMENTRY_CTLS_MSR),
			VMENTRY_LD_DEBUG|VMENTRY_LD_IA32_PAT|VMENTRY_LD_IA32_EFER);
	}
	procctls2 = ctlbits(c2, PROCB_EPT|PROCB_UNRESTR);
	if((exitctls & VMEXIT_HOST64) == 0){
		snprint(why, nwhy, "cannot exit to a 64-bit host");
		return -1;
	}
	return 0;
}

static char*
vmxinfo(char *p, char *e)
{
	return seprint(p, e, "vmx rev %#ux ept unrestricted ept-wb %d pin %#ux proc %#ux proc2 %#ux exit %#ux entry %#ux cr0fixed %#llux/%#llux cr4fixed %#llux/%#llux\n",
		vmxrev, eptwb, pinctls, procctls, procctls2, exitctls, entryctls,
		cr0fixed0, cr0fixed1, cr4fixed0, cr4fixed1);
}

/*
 * VMXON on this processor, once.  CR4.VMXE and CR0.NE are set first
 * and both control registers checked against the fixed-bit MSRs.
 */
static void
vmxcpuon(void)
{
	uchar *p;
	uvlong cr;
	int s;

	if(vmxonpage[m->machno] != nil)
		return;
	p = mallocalign(BY2PG, BY2PG, 0, 0);
	if(p == nil)
		error(Enomem);
	memset(p, 0, BY2PG);
	*(u32int*)p = vmxrev;
	s = splhi();
	putcr4(getcr4() | CR4VMXE);
	putcr0(getcr0() | CR0NE);
	cr = getcr0();
	if((cr & cr0fixed0) != cr0fixed0 || (cr & ~cr0fixed1) != 0){
		splx(s);
		free(p);
		error("vmx: CR0 not allowed in VMX operation");
	}
	cr = getcr4();
	if((cr & cr4fixed0) != cr4fixed0 || (cr & ~cr4fixed1) != 0){
		splx(s);
		free(p);
		error("vmx: CR4 not allowed in VMX operation");
	}
	if(vmxon(PADDR(p)) < 0){
		splx(s);
		free(p);
		error("vmx: VMXON failed");
	}
	vmxonpage[m->machno] = p;
	splx(s);
	print("vmx: cpu%d in VMX operation\n", m->machno);
}

/* make this vCPU's VMCS the current one on this processor */
static void
vmxload(Vmxcpu *x)
{
	if(vmxcur[m->machno] == x)
		return;
	if(vmptrld(PADDR(x->vmcs)) < 0)
		error("vmx: VMPTRLD failed");
	vmxcur[m->machno] = x;
}

static uvlong
eptp(Vm *vm)
{
	return PADDR(vm->gp) | 3<<3 | (eptwb ? 6 : 0);
}

static void
vmcsinit(Vcpu *v, Vmxcpu *x)
{
	vlong msr;

	vmcswrite(PINB_CTLS, pinctls);
	vmcswrite(PROCB_CTLS, procctls);
	vmcswrite(PROCB_CTLS2, procctls2);
	vmcswrite(VMEXIT_CTLS, exitctls);
	x->entryctls = entryctls & ~VMENTRY_GUEST64;
	vmcswrite(VMENTRY_CTLS, x->entryctls);
	vmcswrite(VMEXIT_MSRSTCNT, 0);
	vmcswrite(VMEXIT_MSRLDCNT, 0);
	vmcswrite(VMENTRY_MSRLDCNT, 0);
	vmcswrite(CR3_TARGCNT, 0);
	vmcswrite(VMENTRY_INTRINFO, 0);
	vmcswrite(VMCS_LINK, ~0ULL);
	vmcswrite(EXC_BITMAP, 0);
	vmcswrite(PFAULT_MASK, 0);
	vmcswrite(PFAULT_MATCH, 0);

	/* the host, as this processor is now */
	vmcswrite(HOST_CS, KESEL);
	vmcswrite(HOST_DS, KDSEL);
	vmcswrite(HOST_ES, KDSEL);
	vmcswrite(HOST_FS, KDSEL);
	vmcswrite(HOST_GS, KDSEL);
	vmcswrite(HOST_SS, KDSEL);
	vmcswrite(HOST_TR, TSSSEL);
	vmcswrite(HOST_CR0, getcr0() & ~0xe);	/* MP, EM, TS clear */
	vmcswrite(HOST_CR3, getcr3());
	vmcswrite(HOST_CR4, getcr4());
	rdmsr(FSbase, &msr);
	vmcswrite(HOST_FSBASE, msr);
	rdmsr(GSbase, &msr);
	vmcswrite(HOST_GSBASE, msr);
	vmcswrite(HOST_TRBASE, (uintptr)m->tss);
	vmcswrite(HOST_GDTR, (uintptr)m->gdt);
	vmcswrite(HOST_IDTR, IDTADDR);
	vmcswrite(HOST_IA32_PAT, rdmsrv(PAT_MSR));
	vmcswrite(HOST_IA32_EFER, rdmsrv(Efer));

	/*
	 * The guest: 32-bit flat protected mode with paging off, which
	 * is how the Linux boot protocol's 32-bit entry is reached and
	 * which unrestricted guest allows.  Limbo changes any of it
	 * through regs before the first "go".
	 */
	vmcswrite(GUEST_CS, 0x08);
	vmcswrite(GUEST_DS, 0x10);
	vmcswrite(GUEST_ES, 0x10);
	vmcswrite(GUEST_FS, 0x10);
	vmcswrite(GUEST_GS, 0x10);
	vmcswrite(GUEST_SS, 0x10);
	vmcswrite(GUEST_CSBASE, 0);
	vmcswrite(GUEST_DSBASE, 0);
	vmcswrite(GUEST_ESBASE, 0);
	vmcswrite(GUEST_FSBASE, 0);
	vmcswrite(GUEST_GSBASE, 0);
	vmcswrite(GUEST_SSBASE, 0);
	vmcswrite(GUEST_CSLIMIT, 0xFFFFFFFF);
	vmcswrite(GUEST_DSLIMIT, 0xFFFFFFFF);
	vmcswrite(GUEST_ESLIMIT, 0xFFFFFFFF);
	vmcswrite(GUEST_FSLIMIT, 0xFFFFFFFF);
	vmcswrite(GUEST_GSLIMIT, 0xFFFFFFFF);
	vmcswrite(GUEST_SSLIMIT, 0xFFFFFFFF);
	vmcswrite(GUEST_CSPERM, 0xC09B);	/* G, D, P, code, read, accessed */
	vmcswrite(GUEST_DSPERM, 0xC093);	/* G, B, P, data, write, accessed */
	vmcswrite(GUEST_ESPERM, 0xC093);
	vmcswrite(GUEST_FSPERM, 0xC093);
	vmcswrite(GUEST_GSPERM, 0xC093);
	vmcswrite(GUEST_SSPERM, 0xC093);
	vmcswrite(GUEST_LDTR, 0);
	vmcswrite(GUEST_LDTRBASE, 0);
	vmcswrite(GUEST_LDTRLIMIT, 0);
	vmcswrite(GUEST_LDTRPERM, 1<<16);	/* unusable */
	vmcswrite(GUEST_TR, 0);
	vmcswrite(GUEST_TRBASE, 0);
	vmcswrite(GUEST_TRLIMIT, 0xFFFF);
	vmcswrite(GUEST_TRPERM, 0x8B);		/* P, busy 32-bit TSS */
	vmcswrite(GUEST_GDTRBASE, 0);
	vmcswrite(GUEST_GDTRLIMIT, 0xFFFF);
	vmcswrite(GUEST_IDTRBASE, 0);
	vmcswrite(GUEST_IDTRLIMIT, 0xFFFF);

	/*
	 * CR0 and CR4: the bits VMX forces (NE, VMXE) are owned by the
	 * host through the masks, and the guest reads its own value
	 * from the shadows.  PE and PG are exempt under unrestricted
	 * guest.
	 */
	vmcswrite(GUEST_CR0MASK, cr0fixed0 & ~(uvlong)(CR0PE|CR0PG) | ~cr0fixed1);
	vmcswrite(GUEST_CR4MASK, cr4fixed0 | ~cr4fixed1);
	vmcswrite(GUEST_CR0, CR0PE | 0x10 | (cr0fixed0 & ~(uvlong)(CR0PE|CR0PG)));
	vmcswrite(GUEST_CR0SHADOW, CR0PE | 0x10);
	vmcswrite(GUEST_CR3, 0);
	vmcswrite(GUEST_CR4, cr4fixed0);
	vmcswrite(GUEST_CR4SHADOW, 0);
	vmcswrite(GUEST_IA32_EFER, 0);
	vmcswrite(GUEST_IA32_PAT, 0x0007040600070406ULL);
	vmcswrite(GUEST_IA32_DEBUGCTL, 0);
	vmcswrite(GUEST_DR7, 0x400);
	vmcswrite(GUEST_RSP, 0);
	vmcswrite(GUEST_RIP, 0);
	vmcswrite(GUEST_RFLAGS, 2);
	vmcswrite(GUEST_ACTIVITY, 0);
	vmcswrite(GUEST_CANINTR, 0);
	vmcswrite(GUEST_PENDDBG, 0);

	memset(x->msrbits, 0xFF, BY2PG);
	vmcswrite(MSR_BITMAP, PADDR(x->msrbits));
	vmcswrite(VM_EPTP, eptp(v->vm));
	x->flushept = 1;
}

static void
vmxvcpuinit(Vcpu *v)
{
	Vmxcpu *x;
	int s;

	x = mallocz(sizeof *x, 1);
	if(x == nil)
		error(Enomem);
	x->vmcs = mallocalign(BY2PG, BY2PG, 0, 0);
	x->msrbits = mallocalign(BY2PG, BY2PG, 0, 0);
	x->fp = mallocalign(sizeof(FPsave), 64, 0, 0);
	if(x->vmcs == nil || x->msrbits == nil || x->fp == nil){
		free(x->vmcs);
		free(x->msrbits);
		free(x->fp);
		free(x);
		error(Enomem);
	}
	memset(x->vmcs, 0, BY2PG);
	memset(x->fp, 0, sizeof(FPsave));
	*(u32int*)x->vmcs = vmxrev;
	v->arch = x;
	if(vmclear(PADDR(x->vmcs)) < 0)
		error("vmx: VMCLEAR failed");
	vmxload(x);
	vmcsinit(v, x);

	/* the guest's FPU starts as a reset one */
	s = splhi();
	fpuprocsave(up);
	fpinit();
	fpsave(x->fp);
	splx(s);
}

static void
vmxvcpufree(Vcpu *v)
{
	Vmxcpu *x;

	x = v->arch;
	if(x == nil)
		return;
	if(vmxcur[m->machno] == x)
		vmxcur[m->machno] = nil;
	vmclear(PADDR(x->vmcs));
	free(x->vmcs);
	free(x->msrbits);
	free(x->fp);
	free(x);
}

static void
decode(Vcpu *v, Vmexit *e)
{
	u32int reason, info;
	uvlong q;

	USED(v);
	reason = vmcsread(VM_EXREASON);
	e->raw = reason;
	e->rip = vmcsread(GUEST_RIP);
	q = vmcsread(VM_EXQUALIF);
	e->qual = q;
	e->ilen = vmcsread(VM_EXINSTRLEN);
	if(reason & 1<<31){
		e->kind = VxEntryfail;
		e->ilen = 0;
		return;
	}
	switch(reason & 0xFFFF){
	case 0:		/* exception or NMI */
		info = vmcsread(VM_EXINTRINFO);
		if(((info >> 8) & 7) == 2){
			/*
			 * Interruption type 2 is an NMI, and with NMI
			 * exiting on it is the host's, not the guest's:
			 * a host event, like an external interrupt.
			 */
			e->kind = VxExtint;
			break;
		}
		e->kind = VxException;
		e->vec = info & 0xFF;
		if(info & 1<<11)
			e->errcode = vmcsread(VM_EXINTRCODE);
		break;
	case 1:
		e->kind = VxExtint;
		break;
	case 2:
		e->kind = VxTriple;
		break;
	case 7:
		e->kind = VxIntrwin;
		break;
	case 10:
		e->kind = VxCpuid;
		break;
	case 12:
		e->kind = VxHlt;
		break;
	case 18:
		e->kind = VxCall;
		break;
	case 30:
		e->kind = VxIo;
		e->size = (q & 7) + 1;
		e->in = (q >> 3) & 1;
		e->string = (q >> 4) & 1;
		e->rep = (q >> 5) & 1;
		e->port = (q >> 16) & 0xFFFF;
		e->data = ((Vmxcpu*)v->arch)->regs.ax;
		break;
	case 31:
		e->kind = VxRdmsr;
		e->msr = ((Vmxcpu*)v->arch)->regs.cx;
		break;
	case 32:
		e->kind = VxWrmsr;
		e->msr = ((Vmxcpu*)v->arch)->regs.cx;
		break;
	case 48:	/* EPT violation */
		e->kind = VxMmio;
		e->gpa = vmcsread(VM_GUESTPA);
		if(q & 1<<7)
			e->gva = vmcsread(VM_GUESTVA);
		e->access = q & 7;
		e->ilen = 0;	/* not reported for this exit */
		break;
	default:
		e->kind = VxOther;
		break;
	}
}

static void
vmxrun(Vcpu *v, Vmexit *e)
{
	Vmxcpu *x;
	vlong fsbase;
	int s, rc;
	char buf[64];

	x = v->arch;
	vmxload(x);
	if(x->flushept){
		if(invept(INVEPTSINGLE, eptp(v->vm), 0) < 0
		&& invept(INVEPTALL, 0, 0) < 0)
			error("vmx: INVEPT failed");
		x->flushept = 0;
	}

	s = splhi();
	rdmsr(FSbase, &fsbase);
	vmwrite(HOST_FSBASE, fsbase);
	fpuprocsave(up);
	_clts();
	fprestore(x->fp);
	if(x->cr2 != getcr2())
		putcr2(x->cr2);
	rc = vmlaunch(&x->regs, x->launched);
	x->cr2 = getcr2();
	_clts();
	fpsave(x->fp);		/* leaves TS set */
	splx(s);

	if(rc < 0){
		snprint(buf, sizeof buf, "vmx: %s failed, instruction error %llud",
			x->launched ? "VMRESUME" : "VMLAUNCH", vmcsread(VM_INSTRERR));
		error(buf);
	}
	x->launched = 1;
	decode(v, e);
}

static u32int segfield[][4] = {	/* selector, base, limit, access rights */
	{GUEST_CS, GUEST_CSBASE, GUEST_CSLIMIT, GUEST_CSPERM},
	{GUEST_DS, GUEST_DSBASE, GUEST_DSLIMIT, GUEST_DSPERM},
	{GUEST_ES, GUEST_ESBASE, GUEST_ESLIMIT, GUEST_ESPERM},
	{GUEST_FS, GUEST_FSBASE, GUEST_FSLIMIT, GUEST_FSPERM},
	{GUEST_GS, GUEST_GSBASE, GUEST_GSLIMIT, GUEST_GSPERM},
	{GUEST_SS, GUEST_SSBASE, GUEST_SSLIMIT, GUEST_SSPERM},
	{GUEST_TR, GUEST_TRBASE, GUEST_TRLIMIT, GUEST_TRPERM},
	{GUEST_LDTR, GUEST_LDTRBASE, GUEST_LDTRLIMIT, GUEST_LDTRPERM},
};

static u64int*
gpr(Vmxcpu *x, int r)
{
	switch(r){
	case VRax: return &x->regs.ax;
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
vmxgetreg(Vcpu *v, int r)
{
	Vmxcpu *x;
	u64int *p;
	uvlong mask;

	x = v->arch;
	vmxload(x);
	if((p = gpr(x, r)) != nil)
		return *p;
	if(r >= VCs && r <= VLdtrattr)
		return vmcsread(segfield[(r-VCs)/4][(r-VCs)%4]);
	switch(r){
	case VRsp: return vmcsread(GUEST_RSP);
	case VRip: return vmcsread(GUEST_RIP);
	case VRflags: return vmcsread(GUEST_RFLAGS);
	case VCr0:
		mask = vmcsread(GUEST_CR0MASK);
		return vmcsread(GUEST_CR0) & ~mask | vmcsread(GUEST_CR0SHADOW) & mask;
	case VCr2: return x->cr2;
	case VCr3: return vmcsread(GUEST_CR3);
	case VCr4:
		mask = vmcsread(GUEST_CR4MASK);
		return vmcsread(GUEST_CR4) & ~mask | vmcsread(GUEST_CR4SHADOW) & mask;
	case VEfer: return vmcsread(GUEST_IA32_EFER);
	case VGdtrbase: return vmcsread(GUEST_GDTRBASE);
	case VGdtrlimit: return vmcsread(GUEST_GDTRLIMIT);
	case VIdtrbase: return vmcsread(GUEST_IDTRBASE);
	case VIdtrlimit: return vmcsread(GUEST_IDTRLIMIT);
	}
	error("vmx: no such register");
	return 0;
}

static void
vmxsetreg(Vcpu *v, int r, uvlong val)
{
	Vmxcpu *x;
	u64int *p;

	x = v->arch;
	vmxload(x);
	if((p = gpr(x, r)) != nil){
		*p = val;
		return;
	}
	if(r >= VCs && r <= VLdtrattr){
		vmcswrite(segfield[(r-VCs)/4][(r-VCs)%4], val);
		return;
	}
	switch(r){
	case VRsp: vmcswrite(GUEST_RSP, val); return;
	case VRip: vmcswrite(GUEST_RIP, val); return;
	case VRflags: vmcswrite(GUEST_RFLAGS, val | 2); return;
	case VCr0:
		/* the forced bits stay forced; the guest sees what it set */
		vmcswrite(GUEST_CR0SHADOW, val);
		vmcswrite(GUEST_CR0, val | (cr0fixed0 & ~(uvlong)(CR0PE|CR0PG)));
		return;
	case VCr2: x->cr2 = val; return;
	case VCr3: vmcswrite(GUEST_CR3, val); return;
	case VCr4:
		vmcswrite(GUEST_CR4SHADOW, val);
		vmcswrite(GUEST_CR4, val | cr4fixed0);
		return;
	case VEfer:
		vmcswrite(GUEST_IA32_EFER, val);
		/* IA-32e mode guest must agree with EFER.LMA */
		if(val & EFERLMA)
			x->entryctls |= VMENTRY_GUEST64;
		else
			x->entryctls &= ~VMENTRY_GUEST64;
		vmcswrite(VMENTRY_CTLS, x->entryctls);
		return;
	case VGdtrbase: vmcswrite(GUEST_GDTRBASE, val); return;
	case VGdtrlimit: vmcswrite(GUEST_GDTRLIMIT, val); return;
	case VIdtrbase: vmcswrite(GUEST_IDTRBASE, val); return;
	case VIdtrlimit: vmcswrite(GUEST_IDTRLIMIT, val); return;
	}
	error("vmx: no such register");
}

/*
 * EPT: four levels, 4 KiB leaves.  The tables are kernel memory,
 * identity mapped, so a table's address is its physical address.
 */
static uvlong*
eptwalk(uvlong *tab, uvlong gpa)
{
	uvlong *nt;
	int i;

	for(i = 3; i >= 1; i--){
		tab += (gpa >> (12 + 9*i)) & 0x1FF;
		if((*tab & 7) == 0){
			nt = mallocalign(BY2PG, BY2PG, 0, 0);
			if(nt == nil)
				error(Enomem);
			memset(nt, 0, BY2PG);
			*tab = PADDR(nt) | EptR|EptW|EptX;
		}
		tab = (uvlong*)(uintptr)(*tab & ~0xFFFULL);
	}
	return tab + ((gpa >> 12) & 0x1FF);
}

static void
vmxgpinit(Vm *vm)
{
	vm->gp = mallocalign(BY2PG, BY2PG, 0, 0);
	if(vm->gp == nil)
		error(Enomem);
	memset(vm->gp, 0, BY2PG);
}

static void
eptfree(uvlong *tab, int level)
{
	int i;

	if(level > 0)
		for(i = 0; i < 512; i++)
			if(tab[i] & 7)
				eptfree((uvlong*)(uintptr)(tab[i] & ~0xFFFULL), level-1);
	free(tab);
}

static void
vmxgpfree(Vm *vm)
{
	if(vm->gp != nil)
		eptfree(vm->gp, 3);
	vm->gp = nil;
}

static void
vmxgpmap(Vm *vm, uvlong gpa, uvlong hpa, uvlong len, int prot)
{
	uvlong e, bits;
	int i;

	if((gpa | hpa | len) & 0xFFF)
		error(Ebadarg);
	bits = EptWB;
	if(prot & VmR)
		bits |= EptR;
	if(prot & VmW)
		bits |= EptW;
	if(prot & VmX)
		bits |= EptX;
	for(e = gpa + len; gpa < e; gpa += BY2PG, hpa += BY2PG)
		*eptwalk(vm->gp, gpa) = hpa | bits;
	/* the vCPUs flush before their next entry */
	for(i = 0; i < vm->nvcpu; i++)
		if(vm->vcpu[i] != nil && vm->vcpu[i]->arch != nil)
			((Vmxcpu*)vm->vcpu[i]->arch)->flushept = 1;
}

static Vmops vmxops = {
	"vmx",
	vmxprobe,
	vmxcpuon,
	vmxvcpuinit,
	vmxvcpufree,
	vmxrun,
	vmxgetreg,
	vmxsetreg,
	vmxgpinit,
	vmxgpfree,
	vmxgpmap,
	vmxinfo,
};

void
vmxlink(void)
{
	vmregister(&vmxops);
}
