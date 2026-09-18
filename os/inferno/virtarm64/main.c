#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "io.h"
#include "version.h"

extern Mach mach0;
Mach *machp[MAXMACH];
Conf conf;

extern ulong kerndate;
extern int cflag;
extern int consoleprint;
extern int main_pool_pcnt;
extern int heap_pool_pcnt;
extern int image_pool_pcnt;

int
segflush(void *p, ulong l)
{
	USED(p, l);
	return 1;
}

void
poolinit(void)
{
}

static void
poolsizeinit(void)
{
	uvlong nb;

	nb = (uvlong)conf.npage * BY2PG;
	poolsize(mainmem, (nb*main_pool_pcnt)/100, 0);
	poolsize(heapmem, (nb*heap_pool_pcnt)/100, 0);
	poolsize(imagmem, (nb*image_pool_pcnt)/100, 1);
}

void
reboot(void)
{
	exit(0);
}

void
halt(void)
{
	spllo();
	print("cpu halted\n");
	for(;;)
		idle();
}

/*
 * All of it is archconfinit()'s now: a UEFI machine's memory is not
 * one run from the end of the kernel to a constant, and building
 * conf.mem[] from the firmware's map is where that has to be decided.
 */
void
confinit(void)
{
	archconfinit();
}

void
machinit(void)
{
	m = &mach0;
	memset(m, 0, sizeof(Mach));
	m->machno = 0;
	machp[0] = m;
	memset(&active, 0, sizeof(active));
	active.machs[0] = 1;
}

void
main(void)
{
	long *p, *ep;

	p = (long*)edata;
	ep = (long*)end;
	while(p < ep)
		*p++ = 0;

	/*
	 * First, because the block it copies lives in the loader's
	 * memory and nothing has reserved that: see
	 * os/inferno/virtarm64/bootargs.c.
	 */
	bootargsinit();

	machinit();
	archreset();
	confinit();
	fpinit();

	/*
	 * Before anything touches the UART.  acpitables() only reads;
	 * spcrconsole() puts the console where the firmware says it is,
	 * silently, because there is nowhere to print yet.  acpiinit()
	 * below reports what both of them found.
	 */
	acpitables();
	spcrconsole();

	serialputs("Inferno/arm64 virt\n", -1);

	uartconsole();
	archconsole();
	showconf();
	archmemreport();

	xinit();
	poolinit();
	poolsizeinit();
	trapinit();
	mmuinit();
	clockinit();
	{	/* seed wall-clock from the PL031 RTC (calendar time) */
		extern vlong rtctime(void);
		vlong t = rtctime();
		if(t > 0)
			todset(t, 0, 0);
	}
	quotefmtinstall();
	printinit();

	atomiccheck();
	memspeed();

	/* prints what acpitables() found, and acts on the rest of it */
	acpiinit();
	startcpus();

	/*
	 * *disdump=1 on the boot line asks for the multicore
	 * instrumentation's dump; see os/inferno/port/dis.c.  Read here
	 * rather than defaulted on, because this board's console on a
	 * rented instance is a serial line and nothing else.
	 */
	{
		extern int disdumpon;		/* os/inferno/port/dis.c */
		char *p;

		if((p = getconf("*disdump")) != nil)
			disdumpon = strtol(p, nil, 0);
	}
	procinit();
	links();
	screeninit();
	{
		/* QEMU passes no DTB in x0 to a bare ELF via -kernel, so this
		 * is inert here; correct if a future Image-header kernel gets
		 * x0.  The reader (../port/fdt.c) is exercised on riscv. */
		extern void *dtbptr;
		extern void fdtinit(void*);
		fdtinit(dtbptr);
	}
	pciarchinit();
	chandevreset();
	uartconsolesetup();

	eve = strdup("inferno");
	kbdinit();

	print("\nInferno %s\n", VERSION);
	print("conf %s (%lud) jit %d\n\n", conffile, kerndate, cflag);

	userinit();
	schedinit();
}

void
init0(void)
{
	Osenv *o;

	up->nerrlab = 0;
	spllo();
	if(waserror())
		panic("init0 %r");

	/*
	 * Here and not in main(): this is the first point at which
	 * processor 0 is itself taking interrupts, and a report that
	 * compared the others against a processor 0 still at splhi would
	 * read as the failure it is looking for.
	 */
	cpuintrreport();

	o = up->env;
	o->pgrp->slash = namec("#/", Atodir, 0, 0);
	pathclose(o->pgrp->slash->path);
	o->pgrp->slash->path = newpath("/");
	o->pgrp->dot = cclone(o->pgrp->slash);

	up->pgrp = o->pgrp;
	up->fgrp = o->fgrp;
	up->egrp = o->egrp;

	chandevinit();

	/*
	 * Put the loader's configuration in /env, the way pc64's init0
	 * does, so a boot under UEFI can be told things -- bootfile,
	 * console, *acpi -- rather than only compiled ones.  Harmless
	 * when there was no loader: bootargsinit() left it empty.
	 */
	setconfenv();

	poperror();
	disinit("/osinit.dis");
}

/*
 * The top of a kernel stack, 16-byte aligned, which AArch64 requires
 * of SP itself: with SCTLR_EL1.SA set, the first SP-relative access
 * after a misaligned SP is loaded raises an alignment fault -- and
 * the fault handler builds its own frame on that same SP, so it
 * faults again, and again, silently, at 100% of the processor.
 *
 * p->kstack is a plain malloc(), and a pool block's data pointer is
 * the block start past a header: it can be, and on a Compute Engine
 * t2a with 4 GiB regularly is, 8 modulo 16.  Rounding the size up to
 * the pool quanta does not make the pointer aligned, which is the
 * reasoning that let this stand -- measured instead: the scheduler
 * was seen jumping into a new process with sp 0x408f0898 from kstack
 * 0x408e88a8, both 8 modulo 16, and the machine spun there with no
 * output.  It depends on where the allocator put that one stack, so
 * it came and went with the machine's memory size: a 4 GiB instance
 * hung, an 8 GiB one did not, and QEMU never did.
 */
#define	KSTACKTOP(p)	((((uintptr)(p)->kstack + KSTACK) & ~(uintptr)15) - 16)

void
userinit(void)
{
	Proc *p;
	Osenv *o;

	p = newproc();
	if(p == nil)
		panic("userinit: no procs");
	if(p->kstack == nil)
		panic("userinit: no kstack");
	o = &p->defenv;
	memset(o, 0, sizeof(*o));
	p->env = o;

	o->fgrp = newfgrp(nil);
	o->egrp = newegrp();
	o->pgrp = newpgrp();
	o->errstr = o->errbuf0;
	o->syserrstr = o->errbuf1;
	kstrdup(&o->user, eve);

	p->fgrp = o->fgrp;
	p->egrp = o->egrp;
	p->pgrp = o->pgrp;
	kstrdup(&p->user, eve);
	kstrdup(&p->text, "interp");
	p->fpstate = FPINIT;
	p->sched.pc = (uintptr)init0entry;
	p->sched.sp = KSTACKTOP(p);
	ready(p);
}

void
exit(int inpanic)
{
	up = 0;
	chandevshutdown();
	if(inpanic){
		print("Hit the reset button\n");
		for(;;)
			clockpoll();
	}
	archreboot();
}


static void
linkproc(void)
{
	spllo();
	if(waserror())
		print("error() underflow: %r\n");
	else
		(*up->kpfun)(up->kparg);
	pexit("end proc", 1);
}

void
kprocchild(Proc *p, void (*func)(void*), void *arg)
{
	p->sched.pc = (uintptr)linkproc;
	p->sched.sp = KSTACKTOP(p);
	p->kpfun = func;
	p->kparg = arg;
}

/* fpinit(): raw CPACR_EL1 enable, l.s -- see its own comment. */

void
FPsave(void*)
{
}

void
FPrestore(void*)
{
}

int
fpusave(void)
{
	return 0;
}

void
fpurestore(int x)
{
	USED(x);
}

/*
 * uintptr, not ulong: ulong is 32 bits under 7c, and this used to
 * truncate every address above 4 GiB (the build said "conversion of
 * pointer to shorter integer" here).  Memory starts at 1 GiB on this
 * board, so a machine with more than 3 GiB has RAM above 4 GiB, and a
 * DMA address for it came out 4 GiB too low -- the device then wrote
 * into whatever kernel memory was there.  A Compute Engine t2a has
 * 4 GiB; every QEMU run here had 1 or 2.
 */
uintptr
va2pa(void *v)
{
	return (uintptr)v;
}
