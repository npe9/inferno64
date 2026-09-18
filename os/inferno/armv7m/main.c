#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "io.h"
#include "version.h"

/*
 * Startup shared by the ARMv7-M boards.  What differs between them --
 * the clock tree, how much memory there is and where, the console -- is
 * behind archconfinit, archreset and the board's uart, so this file is
 * the same for a Cortex-M7 with megabytes and a Cortex-M4 with kilobytes.
 */

extern Mach mach0;
Mach *m;
Proc *up;
Conf conf;

extern ulong kerndate;
extern int cflag;
extern int consoleprint;
extern int main_pool_pcnt;
extern int heap_pool_pcnt;
extern int image_pool_pcnt;

void
poolinit(void)
{
}

char*
getconf(char *name)
{
	USED(name);
	return nil;
}

static void
poolsizeinit(void)
{
	ulong nb;

	nb = conf.npage * BY2PG;
	poolsize(mainmem, (nb/100)*main_pool_pcnt, 0);
	poolsize(heapmem, (nb/100)*heap_pool_pcnt, 0);
	poolsize(imagmem, (nb/100)*image_pool_pcnt, 1);
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

void
confinit(void)
{
	ulong base;

	archconfinit();

	base = PGROUND((uintptr)end);
	conf.base0 = base;
	conf.npage0 = (conf.topofmem - base)/BY2PG;
	conf.npage = conf.npage0 + conf.npage1;
	conf.mem[0].base = base;
	conf.mem[0].npage = conf.npage0;
	if(conf.npage1 != 0){
		conf.mem[1].base = conf.base1;
		conf.mem[1].npage = conf.npage1;
	}
	conf.ialloc = (((conf.npage*main_pool_pcnt)/100)/2)*BY2PG;
	conf.nproc = NPROC;
	conf.nmach = 1;
}

void
machinit(void)
{
	m = &mach0;
	memset(m, 0, sizeof(Mach));
	m->machno = 0;
	m->cpuhz = CPUHZ;
	m->delayloop = m->cpuhz/1000;
	memset(&active, 0, sizeof(active));
	active.machs[0] = 1;
}

void
main(void)
{
	machinit();
	archreset();
	confinit();

	/*
	 * No free-history ring on these parts.  It is 64KiB of allocator
	 * debugging for the pc64 and riscv64 hunts (os/inferno/port/alloc.c),
	 * which is nothing against their pools and is the largest single
	 * item in the bss of a kernel for a part with a couple of hundred
	 * kilobytes of SRAM.  confinit() runs before anything frees, so
	 * clearing it here means it is never allocated.
	 */
	freehistsize = 0;

	/*
	 * And no Dis heap tracker.  distrack already gates it, but it also
	 * costs 24576 bytes of table and a sweep of all of it after every
	 * Dis instruction (libinterp/heap.c:/^checktracked), which is a
	 * price a 120MHz part with a couple of hundred kilobytes of SRAM
	 * should not pay for another board's allocator hunt.
	 */
	distrack = 0;

	/*
	 * And no per-proc instruction trace.  It is a ring of the last 256
	 * Dis instructions a proc dispatched, for the wm.dis hunt in
	 * libinterp/xec.c, and it costs 7168 bytes in every Prog plus
	 * seven stores per instruction interpreted.  Measured from
	 * #c/poolhist on mps2 it was the largest single item in the pool.
	 */
	wmtracesize = 0;

	serialputs("Inferno/", -1);
	serialputs(CONFNAME, -1);
	serialputs("\n", -1);

	uartconsole();
	archconsole();

	xinit();
	poolinit();
	poolsizeinit();
	trapinit();
	mmuinit();
	fpinit();
	clockinit();
	quotefmtinstall();
	printinit();

	procinit();
	links();
	screeninit();
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
	 * A register held live across an exception must come back.  This
	 * puts a sentinel in R1, takes a fault on a double-precision
	 * instruction, and looks at R1 afterwards; on a Cortex-M4 that
	 * fault goes through os/inferno/armv7m/fpiarmv7m.c, and on a
	 * Cortex-M7 there is no fault to take and the check is vacuous.
	 * It is here because it failed: see the note on the outgoing
	 * argument word in os/inferno/armv7m/l.s:/^_trapentry.
	 */
	if(fpr1test() == 0x5a5a5a5aUL)
		print("TRAPREG-OK R1 survives an exception\n");
	else
		print("TRAPREG-FAIL R1 did not survive an exception\n");

	poperror();
	disinit("/osinit.dis");
}

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
	p->sched.sp = (uintptr)p->kstack+KSTACK-16;
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
	p->sched.sp = (uintptr)p->kstack+KSTACK-16;
	p->kpfun = func;
	p->kparg = arg;
}
