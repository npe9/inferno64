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
};

enum {
	/* gpmap prot */
	VmR	= 1,
	VmW	= 2,
	VmX	= 4,
	VmRWX	= 7,
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

	/* a request for the kproc to run on its own processor */
	QLock	cmdlk;
	Rendez	cmdr;
	void	(*cmd)(Vcpu*, void*);
	void	*cmdarg;
	char	*cmderr;
	int	cmddone;
};

enum {
	Maxvcpu	= 1,		/* one until phase 5 */
};

struct Vm
{
	Ref;
	int	id;
	QLock;
	int	dead;
	uchar	*mem;		/* guest RAM, contiguous, gpa 0 up */
	uvlong	memsize;
	void	*gp;		/* the backend's nested page tables */
	int	nvcpu;
	Vcpu	*vcpu[Maxvcpu];
};

extern Vmops *vmops;
void	vmregister(Vmops*);
