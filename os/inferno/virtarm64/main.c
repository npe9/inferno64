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

/*
 * Make newly written instructions fetchable: clean the JIT's stores out
 * of the D-cache to the point of coherency, then drop the stale I-cache
 * lines, with cacheiinv()'s DSB/ISB ordering the next fetch behind it.
 * arm64's I- and D-caches are not coherent, so this is required on one
 * core, never mind several.  Was a no-op; see doc/dis-numa-survey.ms.
 */
/*
 * The bring-up that used to live here -- secmain(), smpprobe() and the
 * globals they passed through -- is gone into startcpu.c, which is
 * where the cloud side had already written it and where it belongs:
 * that version hands each processor a record rather than a set of
 * globals, so they can start at once, and it turns the MMU on over
 * there, which this board did not have when the first version was
 * written.  What came across with it is the part this branch cared
 * about: the secondary enters the scheduler, conf.nmach counts
 * processors that arrive, and PSCI discovers them when there is no
 * ACPI to ask.  See doc/multicore-plan.ms.
 */
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

/*
 * Boot options on this board.
 *
 * pc64 gets them from the multiboot command line; this board is loaded
 * as a bare ELF and QEMU hands it no DTB in x0 (see fdtinit() below), so
 * neither route exists.  QEMU does put -append into fw_cfg, which this
 * board already talks to for ramfb, so that is where they come from:
 * FW_CFG_CMDLINE_SIZE then FW_CFG_CMDLINE_DATA, read once into bootargs
 * and parsed on demand.  Without it *parallelvm and the rest are
 * unreachable here and the board can only ever run the default.
 */
enum {
	FwCfgDmaRead		= 1<<1,
	FwCfgDmaSelect		= 1<<3,
};

extern int fwcfgdma(u32int, void*, u32int);
extern int fwcfgfile(char*, u32int*);


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
#ifdef DISCTXREG
	/*
	 * curP is a register now (include/disreg.h), so libinterp's
	 * "Pctx* curP = &_pctx" initialiser does not exist and nothing
	 * else gives R25 a value.  Every processor starts on the default
	 * context and sched() moves it to the running Proc's; this is
	 * cpu0's, and secondary() does the same for the other one.
	 */
	disctxinit();
#endif
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
	/*
	 * NOT a second bootargsinit() here.  fw_cfg is device memory and
	 * the MMU is on by this point, so the read traps; the first call,
	 * before mmuinit(), is where that has to happen.  Under -kernel
	 * the boot options therefore need fw_cfg read early or mapped
	 * late, which is the next piece of work -- see
	 * doc/multicore-bare-metal-plan.ms.
	 */
	{	/* the same options pc64 takes; see doc/multicore-plan.ms */
		char *p;

		if((p = getconf("*parallelvm")) != nil){
			extern int parallelvm;
			parallelvm = strtol(p, nil, 0);
		}
		if((p = getconf("*spawncap")) != nil){
			extern int spawncap;
			spawncap = strtol(p, nil, 0);
		}
		if((p = getconf("*runqaudit")) != nil){
			extern int runqaudit;
			runqaudit = strtol(p, nil, 0);
		}
		/*
		 * The JIT, as a boot option, the way pc64 takes it.
		 *
		 * Without this the second axis of the matrix in
		 * doc/multicore-plan.ms needed a rebuild per cell on this
		 * board, so nobody ran it: *parallelvm was a boot word and
		 * cflag was a config file, and a two-by-two where one axis
		 * costs a relink is a two-by-two that gets done once.
		 *
		 * disinit() refuses cflag=1 with parallelvm=1 unless the
		 * code generator updates Heap.ref atomically, and the
		 * generator this board links -- comp-aarch64.c, chosen by
		 * OBJTYPE -- says it does not.  So that cell is expected to
		 * report the refusal rather than run, and the point of
		 * having the option is to see it say so.
		 */
		if((p = getconf("*cflag")) != nil){
			extern int cflag, jitpresent;

			cflag = strtol(p, nil, 0);
			/*
			 * Here and not only in disinit(), so that the banner
			 * a few lines below tells the truth.  It prints
			 * "jit %d" from cflag, and with a stub generator the
			 * log said "jit 1" while every instruction was
			 * interpreted -- a line that gets grepped later and
			 * believed.  disinit() still carries the same check
			 * for a kernel whose cflag comes from its config
			 * file rather than a boot word, and stays quiet when
			 * this one has already spoken.
			 */
			if(cflag != 0 && jitpresent == 0){
				print("dis: this build has no code generator"
					" for its architecture -- JIT"
					" ignored.\n");
				cflag = 0;
			}
		}
		/*
		 * *soak is NOT read here.  ksetenv() writes through
		 * up->egrp and up is nil this early, so the call faults --
		 * pc64's main.c carries the same note.  It is read beside
		 * setconfenv() below, once there is an environment to put
		 * it in.
		 */
		if((p = getconf("*secsched")) != nil){
			extern int secsched;

			/*
			 * The matrix in doc/multicore-plan.ms was measured by
			 * editing this and rebuilding; now it is a boot
			 * option, so one kernel measures both and the arms
			 * can be interleaved.  Read here because smpprobe()
			 * below is what starts the secondary, and the
			 * secondary tests this once, before its idle loop.
			 */
			secsched = strtol(p, nil, 0);
		}
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
	{
		char *sk;

		/*
		 * *soak=1 puts "soak" in the environment, which /dis/init
		 * reads to repeat its workload instead of running it once.
		 * Here rather than with the other boot options, for the
		 * reason pc64/main.c gives: ksetenv() writes through
		 * up->egrp, and up is nil while the options are read.
		 */
		if((sk = getconf("*poolstat")) != nil){
			extern int poolstat;

			poolstat = strtol(sk, nil, 0);
		}
		if((sk = getconf("*progquar")) != nil){
			extern int progquar;

			progquar = strtol(sk, nil, 0);
		}
		if((sk = getconf("*soak")) != nil){
			extern int soakon;

			ksetenv("soak", sk, 0);
			soakon = 1;	/* soakline() follows the workload */
		}
	}

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
