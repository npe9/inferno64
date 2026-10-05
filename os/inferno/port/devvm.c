/*
 * #H: virtual machines (doc/genesize-plan.ms, phases 3-5)
 *
 *	#H/vm/clone		open to make a machine; the chan becomes
 *				its ctl, and reading it gives the number
 *	#H/vm/backend		which processor extension, and what it has
 *	#H/vm/host		what this host has left for machines: its
 *				processors, free memory and the largest
 *				contiguous run of it (a machine's memory is
 *				one run), the machines and vCPUs it runs --
 *				what a scheduler placing machines reads
 *	#H/vm/N/ctl		"mem bytes": guest RAM at guest-physical 0
 *				"kill": destroy the machine
 *	#H/vm/N/status		the machine and each vCPU's state
 *	#H/vm/N/mem		guest-physical memory, offset = address
 *	#H/vm/N/vcpuM/ctl	"go", "skip" (advance past the exiting
 *				instruction, then go), "stop"
 *	#H/vm/N/vcpuM/regs	"name value" lines, read and written
 *				while the vCPU is stopped
 *	#H/vm/N/vcpuM/exit	blocks until the vCPU stops at an exit
 *				the kernel does not handle itself, and
 *				says what it was
 *
 * Each vCPU is a kproc wired to one processor: a VMCS or VMCB belongs
 * to the processor that loaded it, and so do VMXON and EFER.SVME.  The
 * kproc does everything that touches the processor's virtualization
 * state -- registers included -- so a read of regs from Limbo is a
 * request to that kproc, not a VMREAD on whatever processor the Limbo
 * program happens to be on.
 *
 * Nothing here is VMX or SVM: that is behind vmops (port/vm.h).
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/vm.h"

enum {
	Qroot,
	Qvmdir,
	Qclone,
	Qbackend,
	Qhost,
	Qn,		/* vm/N */
	Qctl,
	Qstatus,
	Qmem,
	Qconsole,
	Qcpu,		/* vm/N/vcpuM */
	Qcpuctl,
	Qregs,
	Qexit,

	Nvm	= 16,
	Memalign	= 2*1024*1024,
};

/* path: vm+1 in bits 16-23, vcpu in 8-15, type in 0-7 */
#define QPATH(vm, cpu, t)	((((vm)+1)<<16)|((cpu)<<8)|(t))
#define QTYPE(q)	((ulong)(q).path & 0xFF)
#define QCPU(q)		(((ulong)(q).path >> 8) & 0xFF)
#define QVM(q)		((int)(((ulong)(q).path >> 16) & 0xFF) - 1)

Vmops *vmops;
static Vm* chanvm(Chan*);
static char vmwhy[ERRMAX] = "no hypervisor backend linked";

static QLock vmtablk;
static Vm *vmtab[Nvm];


static char *xkindname[VxNkind] = {
[VxNone]	"none",
[VxIo]		"io",
[VxMmio]	"mmio",
[VxCpuid]	"cpuid",
[VxRdmsr]	"rdmsr",
[VxWrmsr]	"wrmsr",
[VxHlt]		"hlt",
[VxCall]	"vmcall",
[VxException]	"exception",
[VxTriple]	"triple",
[VxIntrwin]	"irqwin",
[VxExtint]	"extint",
[VxEntryfail]	"entryfail",
[VxStopped]	"stopped",
[VxOther]	"other",
[VxShutdown]	"shutdown",
};

static char *vcpustate[] = {
[VcpuNew]	"new",
[VcpuStopped]	"stopped",
[VcpuRunning]	"running",
[VcpuExited]	"exited",
[VcpuDead]	"dead",
};

/*
 * A backend calls this from its link function.  The first one whose
 * processor has what it needs is the one used.
 */
void
vmregister(Vmops *ops)
{
	char why[ERRMAX];

	if(vmops != nil)
		return;
	why[0] = 0;
	if(ops->probe(why, sizeof why) < 0){
		snprint(vmwhy, sizeof vmwhy, "%s: %s", ops->name, why);
		print("vm: %s\n", vmwhy);
		return;
	}
	vmops = ops;
	print("vm: %s\n", ops->name);
}

static Vm*
getvm(int id)
{
	Vm *vm;

	if(id < 0 || id >= Nvm)
		error(Enonexist);
	qlock(&vmtablk);
	vm = vmtab[id];
	qunlock(&vmtablk);
	if(vm == nil || vm->dead)
		error(Enonexist);
	return vm;
}

static Vcpu*
getvcpu(Vm *vm, int id)
{
	if(id < 0 || id >= vm->nvcpu || vm->vcpu[id] == nil)
		error(Enonexist);
	return vm->vcpu[id];
}

/*
 * The vCPU's kproc.
 */
static int
vcpuwork(void *a)
{
	Vcpu *v;

	v = a;
	return v->go || v->cmd != nil || v->quit || vmplatsipipending(v);
}

static void
vcpuexit(Vcpu *v, Vmexit *e)
{
	ilock(v);
	v->exit = *e;
	v->exitready = 1;
	v->state = VcpuExited;
	iunlock(v);
	wakeup(&v->exitr);
}

/*
 * "trace n": every n seconds the vCPU's kproc prints, on the kernel's
 * console and nowhere else, where it is -- which needs no other process
 * to run, so it still speaks when the host is starved.
 */
static void
heartbeat(Vcpu *v, Vmexit *e)
{
	char buf[256], *p, *ep;
	int k;

	p = buf;
	ep = buf + sizeof buf;
	p = seprint(p, ep, "vm%d.%d: rip %#llux last %s exits %llud handled %llud",
		v->vm->id, v->id, e->rip, e->kind < VxNkind ? xkindname[e->kind] : "?", v->nexit, v->nhandled);
	for(k = 0; k < VxNkind; k++)
		if(v->nkind[k] != 0)
			p = seprint(p, ep, " %s %llud", xkindname[k], v->nkind[k]);
	USED(p);
	print("%s\n", buf);
}

/*
 * While any machine is traced, a watchdog looks once a second for a
 * running vCPU that has taken no exit in three trace periods -- whose
 * kproc, then, is not running guest code -- and prints every process,
 * where it sleeps, once per silence.  The heartbeat cannot report that
 * case: it is printed by the kproc that has stopped.
 */
static Rendez watchr;
static int watching;

static void
vmwatch(void*)
{
	Vm *vm;
	Vcpu *v;
	int i, j, any;
	ulong ms;

	for(;;){
		tsleep(&watchr, return0, nil, 1000);
		if(!canqlock(&vmtablk)){
			print("vmwatch: vmtablk held\n");
			continue;
		}
		any = 0;
		for(i = 0; i < Nvm; i++){
			if((vm = vmtab[i]) == nil || vm->trace <= 0)
				continue;
			any = 1;
			for(j = 0; j < vm->nvcpu; j++){
				v = vm->vcpu[j];
				if(v->state != VcpuRunning){
					v->silent = 0;
					continue;
				}
				ms = TK2MS(MACHP(0)->ticks - v->lastexit);
				if(ms < 3*vm->trace*1000){
					v->silent = 0;
					continue;
				}
				if(v->silent)
					continue;
				v->silent = 1;
				print("vm%d.%d: no exit for %lud ms; kproc %s, processes:\n",
					vm->id, v->id, ms,
					v->kproc != nil ? (v->kproc->psstate != nil ? v->kproc->psstate : statename[v->kproc->state]) : "none");
				procdump();
			}
		}
		qunlock(&vmtablk);
		if(!any){
			watching = 0;
			pexit("", 0);
		}
	}
}

static void
vcpuproc(void *a)
{
	Vcpu *v;
	Vmexit e;
	void (*f)(Vcpu*, void*);

	v = a;
	v->kproc = up;
	procwired(up, v->machno);
	sched();
	if(waserror()){
		kstrcpy(v->err, up->env->errstr, sizeof v->err);
		print("vm%d: vcpu%d: %s\n", v->vm->id, v->id, v->err);
		v->state = VcpuDead;
		ilock(v);
		if(v->cmd != nil){
			v->cmderr = v->err;
			v->cmddone = 1;
		}
		iunlock(v);
		wakeup(&v->cmdr);
		wakeup(&v->exitr);
		while(!v->quit)
			sleep(&v->r, vcpuwork, v);
		v->arch = nil;
		v->quit = 2;
		wakeup(&v->cmdr);
		pexit("", 0);
	}
	vmops->cpuon();
	vmops->vcpuinit(v);
	v->state = VcpuStopped;
	wakeup(&v->cmdr);

	for(;;){
		sleep(&v->r, vcpuwork, v);
		if(v->quit)
			break;
		if((f = v->cmd) != nil){
			if(waserror()){
				kstrcpy(v->err, up->env->errstr, sizeof v->err);
				v->cmderr = v->err;
			}else{
				f(v, v->cmdarg);
				poperror();
			}
			v->cmd = nil;
			v->cmddone = 1;
			wakeup(&v->cmdr);
			continue;
		}
		/* an application processor is started by its SIPI, not by "go" */
		if(!v->go && !vmplatsipi(v))
			continue;
		v->go = 0;
		v->stop = 0;
		v->lastexit = MACHP(0)->ticks;
		v->state = VcpuRunning;
		for(;;){
			/*
			 * A kproc is not preempted: the clock only marks
			 * it (hzsched sets delaysched when its slice is used
			 * and something else is ready).  A guest that never
			 * halts would otherwise keep its processor from
			 * everything else -- on a one-processor host, the
			 * Limbo copying the guest's console, whose output
			 * stopped mid-line.  The mark is honoured here, after
			 * every exit: when the guest makes a stream of exits
			 * the kernel handles, most clock interrupts arrive in
			 * this loop rather than as exits, so looking only at
			 * external-interrupt exits was not enough.
			 */
			if(up->delaysched)
				sched();
			/* an INIT stopped it: back to waiting, no exit to report */
			if(vmplatinit(v)){
				memset(&e, 0, sizeof e);	/* VxNone */
				break;
			}
			memset(&e, 0, sizeof e);
			vmplatintr(v);
			vmops->run(v, &e);
			v->nexit++;
			v->lastexit = MACHP(0)->ticks;
			if(e.kind >= 0 && e.kind < VxNkind)
				v->nkind[e.kind]++;
			/*
			 * The platform -- interrupt controllers, console,
			 * CPUID, MSRs, HLT -- is handled here, on the
			 * vCPU's own processor, without a trip to Limbo.
			 */
			/* processor 0's ticks: an application processor's need not advance */
			if(v->vm->trace && TK2MS(MACHP(0)->ticks - v->lasttrace) >= v->vm->trace*1000){
				v->lasttrace = MACHP(0)->ticks;
				heartbeat(v, &e);
			}
			if(vmplatexit(v, &e)){
				v->nhandled++;
				if(v->stop || v->quit || v->cmd != nil){
					memset(&e, 0, sizeof e);
					e.kind = VxStopped;
					e.rip = vmops->getreg(v, vmops->pc);
					break;
				}
				continue;
			}
			if(e.kind == VxExtint || e.kind == VxIntrwin){
				/*
				 * The host's own interrupt took the
				 * processor back; it has been serviced.
				 * This is also how a guest that never exits
				 * is stopped: a clock tick lands here.
				 */
				if(v->stop || v->quit || v->cmd != nil){
					e.kind = VxStopped;
					break;
				}
				continue;
			}
			break;
		}
		if(e.kind == VxNone && v->state == VcpuRunning){
			v->state = VcpuStopped;	/* INIT: waiting for SIPI again */
			continue;
		}
		vcpuexit(v, &e);
	}
	vmops->vcpufree(v);
	v->arch = nil;
	poperror();
	v->quit = 2;
	wakeup(&v->cmdr);
	pexit("", 0);
}

static int
cmddone(void *a)
{
	Vcpu *v;

	v = a;
	return v->cmddone || v->state == VcpuDead;
}

static int
vcpuinitdone(void *a)
{
	Vcpu *v;

	v = a;
	return v->state != VcpuNew;
}

/*
 * Run f(v, arg) in the vCPU's kproc, on its processor, and wait.
 * The vCPU must not be running.
 */
static void
vcpucmd(Vcpu *v, void (*f)(Vcpu*, void*), void *arg)
{
	qlock(&v->cmdlk);
	if(waserror()){
		qunlock(&v->cmdlk);
		nexterror();
	}
	while(!vcpuinitdone(v))
		sleep(&v->cmdr, vcpuinitdone, v);
	if(v->state == VcpuDead)
		error(v->err);
	if(v->state == VcpuRunning)
		error("vcpu is running");
	v->cmderr = nil;
	v->cmddone = 0;
	v->cmdarg = arg;
	v->cmd = f;
	wakeup(&v->r);
	while(!cmddone(v))
		sleep(&v->cmdr, cmddone, v);
	if(v->cmderr != nil)
		error(v->cmderr);
	poperror();
	qunlock(&v->cmdlk);
}

typedef struct Regbuf Regbuf;
struct Regbuf {
	char	*p;
	char	*e;
	char	*s;	/* for writes: the text */
};

static void
cmdgetregs(Vcpu *v, void *a)
{
	Regbuf *b;
	int i;

	b = a;
	for(i = 0; i < vmops->nreg; i++)
		b->p = seprint(b->p, b->e, "%s %#llux\n", vmops->regname[i], vmops->getreg(v, i));
}

static void
cmdsetregs(Vcpu *v, void *a)
{
	Regbuf *b;
	char *f[2], *line, *next;
	int i, n;

	b = a;
	for(line = b->s; line != nil && *line != 0; line = next){
		next = strchr(line, '\n');
		if(next != nil)
			*next++ = 0;
		n = tokenize(line, f, nelem(f));
		if(n == 0)
			continue;
		if(n != 2)
			error(Ebadarg);
		for(i = 0; i < vmops->nreg; i++)
			if(strcmp(f[0], vmops->regname[i]) == 0)
				break;
		if(i == vmops->nreg)
			error("unknown register");
		vmops->setreg(v, i, strtoull(f[1], nil, 0));
	}
}

static void
cmdskip(Vcpu *v, void *)
{
	if(v->exit.ilen <= 0)
		error("no instruction to skip");
	vmops->setreg(v, vmops->pc, vmops->getreg(v, vmops->pc) + v->exit.ilen);
}

static Vcpu*
newvcpu(Vm *vm)
{
	Vcpu *v;
	char name[KNAMELEN];

	if(vm->nvcpu >= Maxvcpu)
		error("too many vcpus");
	v = malloc(sizeof *v);
	if(v == nil)
		error(Enomem);
	v->vm = vm;
	v->id = vm->nvcpu;
	v->state = VcpuNew;
	/* the last processor: the bootstrap one keeps the clock and the console */
	v->machno = (conf.nmach - 1 - v->id) % conf.nmach;
	if(v->machno < 0)
		v->machno += conf.nmach;
	vm->vcpu[vm->nvcpu++] = v;
	snprint(name, sizeof name, "vm%d.%d", vm->id, v->id);
	kproc(name, vcpuproc, v, 0);
	return v;
}

/*
 * "vcpus n": processors 1 to n-1 of the machine, each a kproc on a
 * processor of its own where there are enough; they wait, as an
 * application processor does, for the INIT and SIPI that start them.
 */
static void
setvcpus(Vm *vm, int n)
{
	Vcpu *v;

	if(n < 1 || n > Maxvcpu)
		error(Ebadarg);
	qlock(vm);
	if(waserror()){
		qunlock(vm);
		nexterror();
	}
	if(n < vm->nvcpu)
		error("vcpus cannot be taken away");
	while(vm->nvcpu < n){
		v = newvcpu(vm);
		while(!vcpuinitdone(v))
			sleep(&v->cmdr, vcpuinitdone, v);
		if(v->state == VcpuDead)
			error(v->err);
	}
	poperror();
	qunlock(vm);
}

static Vm*
newvm(void)
{
	Vm *vm;
	int i;

	if(vmops == nil)
		error(vmwhy);
	qlock(&vmtablk);
	if(waserror()){
		qunlock(&vmtablk);
		nexterror();
	}
	for(i = 0; i < Nvm; i++)
		if(vmtab[i] == nil)
			break;
	if(i == Nvm)
		error("too many machines");
	vm = malloc(sizeof *vm);
	if(vm == nil)
		error(Enomem);
	vm->id = i;
	vm->ref = 1;
	vmops->gpinit(vm);
	vm->plat = vmplatnew(vm);
	vmtab[i] = vm;
	poperror();
	qunlock(&vmtablk);
	newvcpu(vm);
	return vm;
}

static int
vcpugone(void *a)
{
	return ((Vcpu*)a)->quit == 2;
}

static void
vmput(Vm *vm)
{
	int i;

	if(decref(vm) != 0)
		return;
	for(i = 0; i < vm->nvcpu; i++)
		free(vm->vcpu[i]);
	vmplatfree(vm);
	free(vm);
}

/*
 * Stop the machine and give back what it holds.  Channels still open
 * on it see Ehungup; the Vm and its Vcpus are freed by the last
 * vmput().
 */
static void
killvm(Vm *vm)
{
	Vcpu *v;
	int i;

	qlock(vm);
	if(vm->dead){
		qunlock(vm);
		return;
	}
	vm->dead = 1;
	qunlock(vm);
	for(i = 0; i < vm->nvcpu; i++){
		v = vm->vcpu[i];
		v->quit = 1;
		wakeup(&v->r);
		wakeup(&v->exitr);
		while(!vcpugone(v))
			sleep(&v->cmdr, vcpugone, v);
	}
	/* before the memory goes: the platform's devices stop using it */
	vmplathangup(vm);
	qlock(vm);
	vmops->gpfree(vm);
	if(vm->memalloc != nil){
		xfree(vm->memalloc);
		vm->memalloc = nil;
	}
	vm->mem = nil;
	vm->memsize = 0;
	qunlock(vm);
	qlock(&vmtablk);
	vmtab[vm->id] = nil;
	qunlock(&vmtablk);
	vmput(vm);
}

/*
 * Guest RAM is one contiguous run of host memory, mapped at guest-
 * physical 0.  It comes from xalloc and not xspanalloc, because a
 * machine asking for more than there is must fail, not panic the
 * host; the run is aligned to 2 MiB by hand.
 */
static void
setmem(Vm *vm, uvlong size)
{
	uchar *a;
	uintptr p;

	if(size == 0 || size > 64ULL*1024*1024*1024)
		error(Ebadarg);
	size = (size + Memalign-1) & ~(uvlong)(Memalign-1);
	qlock(vm);
	if(waserror()){
		qunlock(vm);
		nexterror();
	}
	if(vm->mem != nil)
		error("memory already set");
	a = xalloc(size + Memalign);
	if(a == nil)
		error(Enomem);
	p = ((uintptr)a + Memalign-1) & ~(uintptr)(Memalign-1);
	vm->memalloc = a;
	vm->mem = (uchar*)p;
	vm->memsize = size;
	memset(vm->mem, 0, size);
	vmops->gpmap(vm, 0, PADDR(vm->mem), size, VmRWX);
	poperror();
	qunlock(vm);
}

static int
vmgen(Chan *c, char *, Dirtab*, int, int s, Dir *dp)
{
	Qid q;
	Vm *vm;
	int id, cpu, t;
	char *name;

	t = QTYPE(c->qid);
	id = QVM(c->qid);
	cpu = QCPU(c->qid);
	if(s == DEVDOTDOT){
		switch(t){
		case Qroot:
		case Qvmdir:
			q = (Qid){QPATH(-1, 0, Qroot), 0, QTDIR};
			devdir(c, q, "#H", 0, eve, 0555, dp);
			return 1;
		case Qn:
			q = (Qid){QPATH(-1, 0, Qvmdir), 0, QTDIR};
			devdir(c, q, "vm", 0, eve, 0555, dp);
			return 1;
		case Qcpu:
			q = (Qid){QPATH(id, 0, Qn), 0, QTDIR};
			snprint(up->genbuf, sizeof up->genbuf, "%d", id);
			devdir(c, q, up->genbuf, 0, eve, 0555, dp);
			return 1;
		}
		return -1;
	}
	switch(t){
	case Qroot:
		if(s != 0)
			return -1;
		q = (Qid){QPATH(-1, 0, Qvmdir), 0, QTDIR};
		devdir(c, q, "vm", 0, eve, 0555, dp);
		return 1;
	case Qvmdir:
		if(s == 0){
			q = (Qid){QPATH(-1, 0, Qclone), 0, QTFILE};
			devdir(c, q, "clone", 0, eve, 0666, dp);
			return 1;
		}
		if(s == 1){
			q = (Qid){QPATH(-1, 0, Qbackend), 0, QTFILE};
			devdir(c, q, "backend", 0, eve, 0444, dp);
			return 1;
		}
		if(s == 2){
			q = (Qid){QPATH(-1, 0, Qhost), 0, QTFILE};
			devdir(c, q, "host", 0, eve, 0444, dp);
			return 1;
		}
		s -= 3;
		qlock(&vmtablk);
		for(id = 0; id < Nvm; id++)
			if(vmtab[id] != nil && !vmtab[id]->dead && s-- == 0)
				break;
		qunlock(&vmtablk);
		if(id == Nvm)
			return -1;
		q = (Qid){QPATH(id, 0, Qn), 0, QTDIR};
		snprint(up->genbuf, sizeof up->genbuf, "%d", id);
		devdir(c, q, up->genbuf, 0, eve, 0555, dp);
		return 1;
	case Qn:
		qlock(&vmtablk);
		vm = (id >= 0 && id < Nvm) ? vmtab[id] : nil;
		qunlock(&vmtablk);
		if(vm == nil)
			return -1;
		switch(s){
		case 0:
			q = (Qid){QPATH(id, 0, Qctl), 0, QTFILE};
			devdir(c, q, "ctl", 0, eve, 0660, dp);
			return 1;
		case 1:
			q = (Qid){QPATH(id, 0, Qstatus), 0, QTFILE};
			devdir(c, q, "status", 0, eve, 0444, dp);
			return 1;
		case 2:
			q = (Qid){QPATH(id, 0, Qmem), 0, QTFILE};
			devdir(c, q, "mem", vm->memsize, eve, 0660, dp);
			return 1;
		case 3:
			q = (Qid){QPATH(id, 0, Qconsole), 0, QTFILE};
			devdir(c, q, "console", 0, eve, 0660, dp);
			return 1;
		}
		s -= 4;
		if(s >= vm->nvcpu)
			return -1;
		q = (Qid){QPATH(id, s, Qcpu), 0, QTDIR};
		snprint(up->genbuf, sizeof up->genbuf, "vcpu%d", s);
		devdir(c, q, up->genbuf, 0, eve, 0555, dp);
		return 1;
	case Qcpu:
		switch(s){
		case 0: t = Qcpuctl; name = "ctl"; break;
		case 1: t = Qregs; name = "regs"; break;
		case 2: t = Qexit; name = "exit"; break;
		default: return -1;
		}
		q = (Qid){QPATH(id, cpu, t), 0, QTFILE};
		devdir(c, q, name, 0, eve, t == Qexit ? 0444 : 0660, dp);
		return 1;
	}
	return -1;
}

static Chan*
vmattach(char *spec)
{
	Chan *c;

	c = devattach('H', spec);
	c->qid = (Qid){QPATH(-1, 0, Qroot), 0, QTDIR};
	return c;
}

static Walkqid*
vmwalk(Chan *c, Chan *nc, char **name, s32 nname)
{
	return devwalk(c, nc, name, nname, nil, 0, vmgen);
}

static s32
vmstat(Chan *c, uchar *db, s32 n)
{
	return devstat(c, db, n, nil, 0, vmgen);
}

static Chan*
vmopen(Chan *c, u32 omode)
{
	Vm *vm;

	if(QTYPE(c->qid) == Qclone){
		if(!iseve())
			error(Eperm);
		vm = newvm();
		c->qid = (Qid){QPATH(vm->id, 0, Qctl), 0, QTFILE};
	}
	vm = nil;
	if(QVM(c->qid) >= 0){
		vm = getvm(QVM(c->qid));
		incref(vm);
	}
	if(waserror()){
		if(vm != nil)
			vmput(vm);
		nexterror();
	}
	c = devopen(c, omode, nil, 0, vmgen);
	poperror();
	c->aux = vm;
	return c;
}

static void
vmclose(Chan *c)
{
	if((c->flag & COPEN) && c->aux != nil){
		vmput(c->aux);
		c->aux = nil;
	}
}

/* the machine an open file is on; Ehungup once it is killed */
static Vm*
chanvm(Chan *c)
{
	Vm *vm;

	vm = c->aux;
	if(vm == nil)
		return getvm(QVM(c->qid));
	if(vm->dead)
		error(Ehungup);
	return vm;
}

static void
hostinfo(char *p, char *e)
{
	Vm *vm;
	int i, nvm, nvcpu;
	uvlong mem;

	nvm = nvcpu = 0;
	mem = 0;
	qlock(&vmtablk);
	for(i = 0; i < Nvm; i++)
		if((vm = vmtab[i]) != nil && !vm->dead){
			nvm++;
			nvcpu += vm->nvcpu;
			mem += vm->memsize;
		}
	qunlock(&vmtablk);
	seprint(p, e, "backend %s cpus %d memfree %llud memlargest %llud machines %d vcpus %d guestmem %llud\n",
		vmops != nil ? vmops->name : "none", conf.nmach, xfreebytes(), xlargest(), nvm, nvcpu, mem);
}

/*
 * Every sleep here is in a loop on its condition: a wakeup can be
 * stale, made on another processor for a change this process has
 * already seen and slept again after, and sleep() does not look again.
 */
static int
exitready(void *a)
{
	Vcpu *v;

	v = a;
	return v->exitready || v->state == VcpuDead || v->quit;
}

static s32
exitread(Vcpu *v, char *a, s32 n, s64 off)
{
	char buf[512], *p, *e;
	Vmexit x;

	USED(off);
	while(!exitready(v))
		sleep(&v->exitr, exitready, v);
	if(v->state == VcpuDead)
		error(v->err);
	if(v->quit)
		error(Ehungup);
	ilock(v);
	x = v->exit;
	v->exitready = 0;
	iunlock(v);
	p = buf;
	e = buf + sizeof buf;
	p = seprint(p, e, "%s rip %#llux ilen %d raw %#ux qual %#llux",
		x.kind < VxNkind ? xkindname[x.kind] : "?", x.rip, x.ilen, x.raw, x.qual);
	switch(x.kind){
	case VxIo:
		p = seprint(p, e, " %s port %#ux size %d", x.in ? "in" : "out", x.port, x.size);
		if(!x.in)
			p = seprint(p, e, " data %#llux", x.data);
		if(x.string)
			p = seprint(p, e, " string");
		if(x.rep)
			p = seprint(p, e, " rep");
		break;
	case VxMmio:
		p = seprint(p, e, " gpa %#llux gva %#llux access %d", x.gpa, x.gva, x.access);
		break;
	case VxRdmsr:
	case VxWrmsr:
		p = seprint(p, e, " msr %#ux", x.msr);
		break;
	case VxException:
		p = seprint(p, e, " vec %d errcode %#ux", x.vec, x.errcode);
		break;
	}
	seprint(p, e, "\n");
	return readstr(0, a, n, buf);
}

static s32
vmread(Chan *c, void *a, s32 n, s64 off)
{
	Vm *vm;
	Vcpu *v;
	char *buf, *p, *e;
	Regbuf rb;
	int i, k;
	s32 r;

	switch(QTYPE(c->qid)){
	case Qroot:
	case Qvmdir:
	case Qn:
	case Qcpu:
		return devdirread(c, a, n, nil, 0, vmgen);
	case Qbackend:
		buf = smalloc(READSTR);
		if(waserror()){
			free(buf);
			nexterror();
		}
		if(vmops == nil)
			snprint(buf, READSTR, "none: %s\n", vmwhy);
		else
			vmops->info(buf, buf+READSTR);
		r = readstr(off, a, n, buf);
		poperror();
		free(buf);
		return r;
	case Qhost:
		buf = smalloc(READSTR);
		if(waserror()){
			free(buf);
			nexterror();
		}
		hostinfo(buf, buf+READSTR);
		r = readstr(off, a, n, buf);
		poperror();
		free(buf);
		return r;
	case Qctl:
		/* the bare number, as a Plan 9 clone file gives it */
		vm = chanvm(c);
		snprint(up->genbuf, sizeof up->genbuf, "%d", vm->id);
		return readstr(off, a, n, up->genbuf);
	case Qstatus:
		vm = chanvm(c);
		buf = smalloc(READSTR);
		if(waserror()){
			free(buf);
			nexterror();
		}
		e = buf + READSTR;
		p = seprint(buf, e, "vm %d backend %s mem %llud vcpus %d\n",
			vm->id, vmops->name, vm->memsize, vm->nvcpu);
		for(i = 0; i < vm->nvcpu; i++){
			v = vm->vcpu[i];
			p = seprint(p, e, "vcpu%d cpu %d state %s exits %llud%s%s\n", i, v->machno,
				vcpustate[v->state], v->nexit,
				v->state == VcpuDead ? " error " : "", v->state == VcpuDead ? v->err : "");
			p = seprint(p, e, "vcpu%d handled %llud exits", i, v->nhandled);
			for(k = 0; k < VxNkind; k++)
				if(v->nkind[k] != 0)
					p = seprint(p, e, " %s %llud", xkindname[k], v->nkind[k]);
			p = seprint(p, e, "\n");
		}
		p = vmplatstatus(vm, p, e);
		USED(p);
		r = readstr(off, a, n, buf);
		poperror();
		free(buf);
		return r;
	case Qconsole:
		vm = chanvm(c);
		return vmplatconsread(vm, a, n);
	case Qmem:
		vm = chanvm(c);
		if(off < 0)
			error(Ebadarg);
		qlock(vm);
		if(vm->mem == nil || off >= vm->memsize){
			qunlock(vm);
			return 0;
		}
		if(off + n > vm->memsize)
			n = vm->memsize - off;
		memmove(a, vm->mem + off, n);
		qunlock(vm);
		return n;
	case Qregs:
		vm = chanvm(c);
		v = getvcpu(vm, QCPU(c->qid));
		buf = smalloc(READSTR);
		if(waserror()){
			free(buf);
			nexterror();
		}
		rb.p = buf;
		rb.e = buf + READSTR;
		vcpucmd(v, cmdgetregs, &rb);
		r = readstr(off, a, n, buf);
		poperror();
		free(buf);
		return r;
	case Qexit:
		vm = chanvm(c);
		v = getvcpu(vm, QCPU(c->qid));
		return exitread(v, a, n, off);
	case Qcpuctl:
		return 0;
	}
	error(Egreg);
	return 0;
}

static s32
vmwrite(Chan *c, void *a, s32 n, s64 off)
{
	Vm *vm;
	Vcpu *v;
	Cmdbuf *cb;
	Regbuf rb;
	char *s;

	switch(QTYPE(c->qid)){
	case Qctl:
		vm = chanvm(c);
		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf == 2 && strcmp(cb->f[0], "mem") == 0)
			setmem(vm, strtoull(cb->f[1], nil, 0));
		else if(cb->nf == 1 && strcmp(cb->f[0], "kill") == 0)
			killvm(vm);
		else if(cb->nf == 2 && strcmp(cb->f[0], "vcpus") == 0)
			setvcpus(vm, atoi(cb->f[1]));
		else if(cb->nf == 2 && strcmp(cb->f[0], "trace") == 0){
			vm->trace = atoi(cb->f[1]);
			if(vm->trace > 0 && !watching){
				watching = 1;
				kproc("vmwatch", vmwatch, nil, 0);
			}
		}
		else if(!vmplatctl(vm, cb->nf, cb->f))
			error(Ebadctl);
		poperror();
		free(cb);
		return n;
	case Qmem:
		vm = chanvm(c);
		qlock(vm);
		if(vm->mem == nil || off < 0 || off >= vm->memsize){
			qunlock(vm);
			error(vm->mem == nil ? "no memory" : Ebadarg);
		}
		if(off + n > vm->memsize)
			n = vm->memsize - off;
		memmove(vm->mem + off, a, n);
		qunlock(vm);
		return n;
	case Qconsole:
		vm = chanvm(c);
		return vmplatconswrite(vm, a, n);
	case Qcpuctl:
		vm = chanvm(c);
		v = getvcpu(vm, QCPU(c->qid));
		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf != 1)
			error(Ebadctl);
		if(strcmp(cb->f[0], "go") == 0 || strcmp(cb->f[0], "skip") == 0){
			if(cb->f[0][0] == 's')
				vcpucmd(v, cmdskip, nil);
			qlock(&v->cmdlk);
			if(v->state == VcpuDead){
				qunlock(&v->cmdlk);
				error(v->err);
			}
			if(v->state == VcpuRunning){
				qunlock(&v->cmdlk);
				error("vcpu is running");
			}
			if(vm->mem == nil){
				qunlock(&v->cmdlk);
				error("no memory");
			}
			v->exitready = 0;
			v->go = 1;
			wakeup(&v->r);
			qunlock(&v->cmdlk);
		}else if(strcmp(cb->f[0], "stop") == 0)
			v->stop = 1;
		else
			error(Ebadctl);
		poperror();
		free(cb);
		return n;
	case Qregs:
		vm = chanvm(c);
		v = getvcpu(vm, QCPU(c->qid));
		if(off != 0)
			error(Ebadarg);
		s = smalloc(n+1);
		if(waserror()){
			free(s);
			nexterror();
		}
		memmove(s, a, n);
		s[n] = 0;
		rb.s = s;
		vcpucmd(v, cmdsetregs, &rb);
		poperror();
		free(s);
		return n;
	}
	error(Eperm);
	return 0;
}

Dev vmdevtab = {
	'H',
	"vm",

	devreset,
	devinit,
	devshutdown,
	vmattach,
	vmwalk,
	vmstat,
	vmopen,
	devcreate,
	vmclose,
	vmread,
	devbread,
	vmwrite,
	devbwrite,
	devremove,
	devwstat,
};
