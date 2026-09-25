#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "io.h"
#include "armv7m.h"
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

/*
 * A real reset, which is what /dev/reboot is for.  This used to call
 * exit(0), and exit() on this architecture prints "Hit the reset
 * button" and spins -- so the one thing the file exists to do was the
 * one thing it did not.
 *
 * SYSRESETREQ in AIRCR is the architecture's own reset and needs no
 * help from the board: every Cortex-M has it, at the same address,
 * behind the same write key.  On a part whose flash holds a bootloader
 * it lands back in that bootloader, which means a board can be
 * reprogrammed without anyone touching it -- and on
 * os/inferno/stm32f407 that is the difference between a development
 * cycle and a trip across the room.
 */
void
reboot(void)
{
	chandevshutdown();
	*(ulong*)SCB_AIRCR = (0x5faUL<<16) | (1<<2);	/* VECTKEY, SYSRESETREQ */
	coherence();
	for(;;)
		;
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
	conf.npage = conf.npage0 + conf.npage1 + conf.npage2;
	conf.mem[0].base = base;
	conf.mem[0].npage = conf.npage0;
	if(conf.npage1 != 0){
		conf.mem[1].base = conf.base1;
		conf.mem[1].npage = conf.npage1;
	}
	/*
	 * A third bank, for parts that have one.  An STM32F407 does: its
	 * SRAM is 128K, its core coupled memory 64K, and there are 4K of
	 * backup SRAM on top of that -- the "192+4 KB" of the datasheet,
	 * of which the 4 was going unused.  On a board with 172032 bytes
	 * to spend, 4096 is a page and worth having.
	 */
	if(conf.npage2 != 0){
		conf.mem[2].base = conf.base2;
		conf.mem[2].npage = conf.npage2;
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

/*
 * A panic stops; anything else resets the machine.
 *
 * The reset path does not call chandevshutdown() and that is the
 * point of this comment.  On these boards /dev/reboot is how a kernel
 * gets back into a ROM or flash bootloader without anyone pressing
 * anything, which on os/inferno/stm32f407 is the whole flash cycle --
 * and with the shutdown in the way it worked once and hung twice.
 * The once printed every device in chandevshutdown()'s list and
 * "shutdown done" and came back up; the twice printed nothing at all,
 * with the console still echoing from the interrupt handler and no
 * process left to run a command, so it did not even reach the first
 * print with up set to nil.
 *
 * Shutting the devices down first buys nothing here.  SYSRESETREQ
 * resets every peripheral on the part, so a driver that tidies its
 * registers is tidying something that is about to be cleared, and
 * this kernel's root is in flash with no storage under it and nothing
 * to flush.  What it costs is that the one operation that has to work
 * depends on every driver's shutdown being correct, which is a lot of
 * code to be sure of for no gain.
 *
 * A panic keeps it, because there the machine is stopping rather than
 * restarting and whatever a device does on the way out may be the
 * last useful thing it does.  The message goes out first, so a
 * shutdown that hangs there costs the shutdown and not the panic.
 */
void
exit(int inpanic)
{
	up = 0;
	if(inpanic){
		print("Hit the reset button\n");
		chandevshutdown();
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
