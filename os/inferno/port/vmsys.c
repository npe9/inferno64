/*
 * A context of #H as a process (doc/genesize-plan.ms, phase 18): with
 * "traps sys" written to its ctl, the guest's hypercall (VMCALL,
 * VMMCALL, ECALL) is a system call of this kernel, made on the vCPU's
 * kproc in the namespace and with the file descriptors of whoever
 * wrote it (devvm.c's adoptns).  The CPU substrate is the same as a
 * virtual machine's; what answers its traps is not: Dune's process
 * with hardware, its system calls Inferno's.
 *
 * The call's number and arguments come from the registers the
 * platform names (x86: rax, then rdi rsi rdx r10 r8, as Linux's
 * x86-64 system calls; RISC-V: a7, then a0-a4); the result goes back
 * in rax or a0, -1 for an error, whose string errstr gives.  Buffers
 * are guest-virtual addresses, walked through the guest's own page
 * tables (or physical where it has none).  The calls:
 *
 *	0 exits(status)		the process ends; the vCPU stops with an
 *				"exited status n" exit
 *	1 open(path, mode)	path NUL-terminated
 *	2 close(fd)
 *	3 read(fd, buf, n)
 *	4 write(fd, buf, n)
 *	5 pread(fd, buf, n, off)
 *	6 pwrite(fd, buf, n, off)
 *	7 seek(fd, off, type)
 *	8 errstr(buf, n)	the last error, NUL-terminated
 *
 * A transfer is at most Maxio bytes; a longer one is short, as a read
 * of a pipe can be.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"kernel.h"
#include	"../port/vm.h"

enum {
	Sysexits,
	Sysopen,
	Sysclose,
	Sysread,
	Syswrite,
	Syspread,
	Syspwrite,
	Sysseek,
	Syserrstr,
	Nsys,

	Maxio	= 64*1024,
	Maxpath	= 1024,
};

static char *syscallname[Nsys] = {
[Sysexits]	"exits",
[Sysopen]	"open",
[Sysclose]	"close",
[Sysread]	"read",
[Syswrite]	"write",
[Syspread]	"pread",
[Syspwrite]	"pwrite",
[Sysseek]	"seek",
[Syserrstr]	"errstr",
};

/* a NUL-terminated string from the guest, or an error */
static char*
gstring(Vcpu *v, uvlong va, char *buf, int n)
{
	int i;

	for(i = 0; i < n; i++){
		if(vmplatgcopy(v, va + i, (uchar*)buf + i, 1, 0) != 1)
			error(Ebadarg);
		if(buf[i] == 0)
			return buf;
	}
	error(Etoolong);
	return nil;
}

static vlong
transfer(Vcpu *v, int nr, uvlong a[6])
{
	uchar *buf;
	vlong r;
	s32 n;

	n = a[3];
	if(n < 0)
		error(Ebadarg);
	if(n > Maxio)
		n = Maxio;
	buf = smalloc(n == 0 ? 1 : n);
	if(waserror()){
		free(buf);
		nexterror();
	}
	if(nr == Syswrite || nr == Syspwrite)
		if(vmplatgcopy(v, a[2], buf, n, 0) != n)
			error(Ebadarg);
	switch(nr){
	case Sysread:
		r = kread(a[1], buf, n);
		break;
	case Syspread:
		r = kpread(a[1], buf, n, a[4]);
		break;
	case Syswrite:
		r = kwrite(a[1], buf, n);
		break;
	default:
		r = kpwrite(a[1], buf, n, a[4]);
		break;
	}
	if(r > 0 && (nr == Sysread || nr == Syspread))
		if(vmplatgcopy(v, a[2], buf, r, 1) != r)
			error(Ebadarg);
	poperror();
	free(buf);
	return r;
}

static int
vmsys(Vcpu *v, Vmexit *e)
{
	uvlong a[6];
	char path[Maxpath], *err;
	vlong r;
	int i, nr;

	for(i = 0; i < 6; i++)
		a[i] = vmplatsysarg(v, i);
	nr = a[0];
	v->nsys++;
	if(nr == Sysexits){
		memset(e, 0, sizeof *e);
		e->kind = VxExited;
		e->data = a[1];
		e->rip = vmops->getreg(v, vmops->pc);
		return 0;
	}
	if(waserror()){
		r = -1;
	}else{
		switch(nr){
		case Sysopen:
			r = kopen(gstring(v, a[1], path, sizeof path), a[2]);
			break;
		case Sysclose:
			r = kclose(a[1]);
			break;
		case Sysread:
		case Syswrite:
		case Syspread:
		case Syspwrite:
			r = transfer(v, nr, a);
			break;
		case Sysseek:
			r = kseek(a[1], a[2], a[3]);
			break;
		case Syserrstr:
			err = up->env->errstr;
			i = strlen(err) + 1;
			if(i > a[2])
				i = a[2];
			if(i > 0 && vmplatgcopy(v, a[1], (uchar*)err, i, 1) != i)
				error(Ebadarg);
			r = 0;
			break;
		default:
			error("no such system call");
		}
		poperror();
	}
	if(v->vm->trace)
		print("vm%d.%d: %s -> %lld\n", v->vm->id, v->id,
			nr >= 0 && nr < Nsys ? syscallname[nr] : "?", r);
	vmplatsysret(v, r);
	vmops->setreg(v, vmops->pc, e->rip + e->ilen);
	return 1;
}

void
vmsyslink(void)
{
	vmsysp = vmsys;
}
