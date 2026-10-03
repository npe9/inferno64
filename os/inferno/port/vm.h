/*
 * The portable half of the hypervisor (doc/genesize-plan.ms, section 3).
 *
 * devvm.c knows machines, vCPUs, guest memory and the files; it
 * reaches the processor's virtualization extensions only through a
 * Vmops, registered by a backend (pc64/vmx.c for Intel VMX, an SVM
 * backend beside it, the RISC-V H extension one day).  Exits come back
 * decoded into a Vmexit, so nothing above the backend sees a VMX exit
 * reason or an SVM exit code.
 */
typedef struct Vm Vm;
typedef struct Vcpu Vcpu;
typedef struct Vmexit Vmexit;
typedef struct Vmops Vmops;

/* registers, by portable index */
enum {
	VRax, VRbx, VRcx, VRdx, VRsi, VRdi, VRbp, VRsp,
	VR8, VR9, VR10, VR11, VR12, VR13, VR14, VR15,
	VRip, VRflags,
	VCr0, VCr2, VCr3, VCr4, VEfer,
	VCs, VCsbase, VCslimit, VCsattr,
	VDs, VDsbase, VDslimit, VDsattr,
	VEs, VEsbase, VEslimit, VEsattr,
	VFs, VFsbase, VFslimit, VFsattr,
	VGs, VGsbase, VGslimit, VGsattr,
	VSs, VSsbase, VSslimit, VSsattr,
	VTr, VTrbase, VTrlimit, VTrattr,
	VLdtr, VLdtrbase, VLdtrlimit, VLdtrattr,
	VGdtrbase, VGdtrlimit, VIdtrbase, VIdtrlimit,
	VNreg,
};

/* Vmexit.kind */
enum {
	VxNone,
	VxIo,		/* port i/o: port, size, in, data (out), string, rep */
	VxMmio,		/* nested-paging fault: gpa, gva, read/write/exec */
	VxCpuid,
	VxRdmsr,
	VxWrmsr,
	VxHlt,
	VxCall,		/* vmcall / vmmcall */
	VxException,	/* vec, errcode */
	VxTriple,	/* triple fault, or shutdown */
	VxIntrwin,	/* the guest can take an interrupt */
	VxExtint,	/* a host interrupt arrived; handled, never delivered */
	VxEntryfail,	/* the processor refused the guest state */
	VxStopped,	/* stopped by request, not by the guest */
	VxOther,	/* anything else; raw names the backend's code */
	VxNkind,
};

struct Vmexit
{
	int	kind;
	u32int	raw;		/* the backend's own exit code */
	uvlong	qual;		/* and its qualification / exitinfo1 */
	uvlong	rip;		/* where the guest was */
	int	ilen;		/* length of the exiting instruction, 0 if unknown */

	/* VxIo */
	int	port;
	int	size;		/* 1, 2 or 4 */
	int	in;
	int	string;
	int	rep;
	uvlong	data;		/* rax for an out */

	/* VxMmio */
	uvlong	gpa;
	uvlong	gva;
	int	access;		/* 1 read, 2 write, 4 execute */

	/* VxRdmsr, VxWrmsr: msr is ecx, data edx:eax for a write */
	u32int	msr;

	/* VxException */
	int	vec;
	u32int	errcode;
};

struct Vmops
{
	char	*name;
	int	(*probe)(char *why, int nwhy);	/* 0 if usable, else why not */
	void	(*cpuon)(void);		/* on this processor: VMXON, EFER.SVME */
	void	(*vcpuinit)(Vcpu*);	/* VMCS or VMCB, on the vCPU's processor */
	void	(*vcpufree)(Vcpu*);
	void	(*run)(Vcpu*, Vmexit*);	/* enter the guest; back with an exit */
	uvlong	(*getreg)(Vcpu*, int);
	void	(*setreg)(Vcpu*, int, uvlong);
	void	(*gpinit)(Vm*);		/* EPT or NPT root */
	void	(*gpfree)(Vm*);
	void	(*gpmap)(Vm*, uvlong gpa, uvlong hpa, uvlong len, int prot);
	char*	(*info)(char*, char*);	/* capability summary for #H/vm/backend */

	/* events, delivered at the next entry */
	void	(*inject)(Vcpu*, int type, int vec, int haserr, u32int err);
	int	(*canintr)(Vcpu*);	/* an external interrupt would be taken now */
	void	(*irqwin)(Vcpu*, int);	/* exit (VxIntrwin) once it would be */

	/*
	 * MSRs whose state the processor switches with the guest:
	 * EFER, PAT, FS and GS base, the syscall and sysenter MSRs.
	 * -1 if msr is not one of the backend's.
	 */
	int	(*rdmsr)(Vcpu*, u32int msr, uvlong*);
	int	(*wrmsr)(Vcpu*, u32int msr, uvlong);
	void	(*gpunmap)(Vm*, uvlong gpa, uvlong len);
};

enum {
	/* inject type */
	VeIntr	= 0,	/* external interrupt */
	VeNmi	= 2,
	VeExc	= 3,	/* hardware exception */

	/* exceptions the platform raises */
	VecUD	= 6,
	VecGP	= 13,
};

/*
 * The platform the guest sees -- for x86 the interrupt controllers,
 * the console UART, CPUID and the MSRs that are not the processor's
 * own -- lives below the portable layer (pc/vmplat.c), reached through
 * these.  vmplatexit handles an exit in the kernel if it can and says
 * whether it did; vmplatintr injects whatever interrupt is pending.
 */
void*	vmplatnew(Vm*);
void	vmplatfree(Vm*);
void	vmplathangup(Vm*);
int	vmplatsipi(Vcpu*);		/* on the vCPU's processor: start it if a SIPI came */
int	vmplatsipipending(Vcpu*);
int	vmplatexit(Vcpu*, Vmexit*);
void	vmplatintr(Vcpu*);
int	vmplatctl(Vm*, int, char**);
long	vmplatconsread(Vm*, void*, long);
long	vmplatconswrite(Vm*, void*, long);
char*	vmplatstatus(Vm*, char*, char*);

enum {
	/* gpmap prot */
	VmR	= 1,
	VmW	= 2,
	VmX	= 4,
	VmRWX	= 7,
	VmUC	= 8,	/* uncached: a device's registers, not RAM */
};

enum {
	/* Vcpu.state */
	VcpuNew,	/* not yet initialised on its processor */
	VcpuStopped,	/* waiting for "go" */
	VcpuRunning,
	VcpuExited,	/* stopped at an exit not yet read */
	VcpuDead,	/* failed; error in Vcpu.err */
};

struct Vcpu
{
	Vm	*vm;
	int	id;
	int	machno;		/* the processor it is wired to */
	int	state;
	char	err[ERRMAX];
	void	*arch;		/* the backend's: VMCS or VMCB and the rest */

	Lock;
	Rendez	r;		/* the vCPU's kproc sleeps here */
	Rendez	exitr;		/* readers of exit sleep here */
	int	go;		/* "go" was written */
	int	stop;		/* "stop" was written */
	int	quit;		/* the machine is being destroyed */
	Vmexit	exit;		/* the last one, for the exit file */
	int	exitready;	/* exit holds one not yet read */
	uvlong	nexit;		/* exits taken */
	uvlong	nhandled;	/* of which the kernel handled */
	ulong	lasttrace;	/* ticks at the last heartbeat (Vm.trace) */
	ulong	lastexit;	/* ticks at the last exit, for the watchdog */
	int	silent;		/* the watchdog has reported this silence */
	Proc	*kproc;		/* the vCPU's kproc, for the watchdog */
	uvlong	nkind[VxNkind];	/* and of each kind */

	/* a request for the kproc to run on its own processor */
	QLock	cmdlk;
	Rendez	cmdr;
	void	(*cmd)(Vcpu*, void*);
	void	*cmdarg;
	char	*cmderr;
	int	cmddone;
};

enum {
	Maxvcpu	= 8,
};

/*
 * A Vm is referenced by the table while it lives and by every open
 * file under it; "kill" stops its vCPUs, frees its memory and takes it
 * out of the table, and the structures go with the last close.
 */
struct Vm
{
	Ref;
	int	id;
	QLock;
	int	dead;
	uchar	*mem;		/* guest RAM, contiguous, gpa 0 up */
	void	*memalloc;	/* what xalloc returned for it */
	uvlong	memsize;
	void	*gp;		/* the backend's nested page tables */
	void	*plat;		/* the platform's devices (vmplat.c) */
	int	trace;		/* seconds between vCPU heartbeats on the console, 0 none */
	int	nvcpu;
	Vcpu	*vcpu[Maxvcpu];
};

extern Vmops *vmops;
void	vmregister(Vmops*);
