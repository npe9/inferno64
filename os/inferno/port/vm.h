/*
 * The portable half of the hypervisor (doc/genesize-plan.ms, section 3).
 *
 * devvm.c knows machines, vCPUs, guest memory and the files; it
 * reaches the processor's virtualization extensions only through a
 * Vmops, registered by a backend (pc64/vmx.c for Intel VMX, an SVM
 * backend beside it, virt/vmrv.c for the RISC-V H extension).  Exits come back
 * decoded into a Vmexit, so nothing above the backend sees a VMX exit
 * reason or an SVM exit code.
 */
typedef struct Vm Vm;
typedef struct Vcpu Vcpu;
typedef struct Vmexit Vmexit;
typedef struct Vmops Vmops;

/*
 * Registers are the backend's: each names its own (Vmops.regname),
 * by its own index, and says which of them is the program counter.
 */

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
	VxShutdown,	/* the guest asked to be switched off (SBI SRST); raw the reset type */
	VxExited,	/* a process (traps sys) called exits; data its status */
	VxNkind,
};

/*
 * Vm.traps: who answers a context's exits.  The CPU substrate -- a
 * context, its guest memory, its exits -- is the same for all three;
 * what serves it makes it a machine or a process.
 */
enum {
	Trapplatform,	/* the emulated machine (vmplat.c): a VM, its guest kernel above */
	Trapnone,	/* nothing in the kernel: every exit goes up to Limbo */
	Trapsys,	/* hypercalls are this kernel's system calls (vmsys.c): a process */
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
	u32int	insn;		/* the access, where the processor says (RISC-V's mtinst), else 0 */

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

	char	**regname;	/* the registers' names, by index */
	int	nreg;
	int	pc;		/* the index of the program counter */
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
int	vmplatinit(Vcpu*);		/* on the vCPU's processor: an INIT stopped it; wait for SIPI */
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
	uvlong	nsys;		/* Trapsys: system calls made */

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
	int	traps;		/* Trapplatform, Trapnone, Trapsys */
	Pgrp	*spgrp;		/* Trapsys: the namespace its system calls see */
	Fgrp	*sfgrp;		/* and its file descriptors, shared by its vCPUs */
	int	trace;		/* seconds between vCPU heartbeats on the console, 0 none */
	int	nvcpu;
	Vcpu	*vcpu[Maxvcpu];
};

extern Vmops *vmops;

/*
 * vmsys.c: Trapsys's system calls; 0 when the process has exited (e
 * is then VxExited).  Set by vmsyslink where the kernel has them and
 * the platform the hooks below.
 */
extern int	(*vmsysp)(Vcpu*, Vmexit*);

/* from the platform, for vmsys.c: the call's registers, and guest-virtual memory */
uvlong	vmplatsysarg(Vcpu*, int);	/* 0 the call's number, 1-5 its arguments */
void	vmplatsysret(Vcpu*, uvlong);
int	vmplatgcopy(Vcpu*, uvlong va, uchar *buf, int n, int towrite);
void	vmregister(Vmops*);
