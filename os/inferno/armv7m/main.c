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
/*
 * How many processes this image wants, from the config's code section
 * rather than from the board's mem.h.
 *
 * It was NPROC, a constant in a header, and that is the wrong place as
 * soon as one board has two images.  os/inferno/stm32f407 does: a shell
 * image wants five, because at seven the shell and lil(1) both die for
 * want of heap, and an AX.25 station image wants seven, because #a
 * starts three kprocs the moment a packet device is attached and at five
 * it gets "no procs for kproc" -- with or without a shell, since an init
 * removes the heap pressure and not the process pressure.  Both numbers
 * are measured; os/inferno/stm32f407/mem.h has all three it was tried
 * at.
 *
 * Which image a board carries is already selected by file, "mk
 * INIT=armv7max25".  This is the matching selection for the number, and
 * it is a value in a config rather than a conditional in a header
 * because that is how this tree picks per-board facts -- the same way
 * main_pool_pcnt beside it does.
 */
extern int nprocwanted;

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
	conf.nproc = nprocwanted;
	conf.nmach = 1;
}

/*
 * THE BOOT AND INTERRUPT STACK, WHICH NOTHING WAS WATCHING.
 *
 * KSTACKWATCH paints every PROCESS stack with 0xbe in newproc() and
 * kstackused() reads back how far the pattern was eaten; that is where
 * "kstack high water 3988 of 4096" comes from.  Nothing did that for
 * the stack in l.s -- "GLOBL stack(SB), $KSTKSIZE", whose top is the
 * initial MSP in the vector table -- and l.s says "everything runs
 * privileged on MSP", so that array carries the boot, the idle loop
 * and every exception taken outside a process.
 *
 * WHY IT MATTERS, measured on os/inferno/stm32f407: the array is
 * KSTKSIZE = 4096 bytes at 0x20005f6c..0x20006f6c, and it sits in the
 * MIDDLE of bss.  Kernel variables are above it (bss ends at
 * 0x20008988) and 24 kilobytes of them are below it, down to the
 * bottom of SRAM at 0x20000000.  There is no guard on either side.
 *
 * So an overflow of these 4096 bytes does not fault.  It writes
 * through 24K of live kernel state, silently, and the machine faults
 * only when SP finally leaves SRAM.  That is what the keyring-plus-ssl
 * arm did: an exception-entry stacking fault at 0x1fffffec, with no
 * fault before it, 28524 bytes below the top of a 4096-byte stack.
 * Everything crossed on the way down was already wrong.
 *
 * Unconditional, unlike its KSTACKWATCH neighbour: one memset at boot,
 * a scan only when something asks, and an instrument that is off is an
 * instrument that is not there when the fault happens.
 */
enum {
	Msppat	= 0xbe,		/* same pattern as KSTACKWATCH, for one habit */
	Mspslack = 128,		/* left unpainted: the painting frame itself */
};

extern uchar stack[];		/* l.s: the boot and interrupt stack */

static uchar *msplo;		/* lowest address painted */
static uchar *mspsp;		/* where SP was when the paint ran */
static uchar *msphi;		/* highest address painted */

void
mspwatchinit(void)
{
	uchar *lo, *hi;
	int here;

	/*
	 * &here is this frame, which is ON this stack, so paint below it
	 * and not through it.  Called as early in main() as there is a
	 * frame to measure from, so "below this frame" is very nearly
	 * the whole array.
	 *
	 * SAYS WHAT IT FOUND, INCLUDING WHEN IT DECLINES.  The first cut
	 * pointed at end[] -- the top of bss -- on the assumption that
	 * the stack grew down towards bss from above.  It does not: bss
	 * ENDS above the initial MSP because the stack is an array
	 * inside it.  So hi <= lo every time, the function returned
	 * quietly, and the watch printed nothing at all -- which reads
	 * exactly like a stack that never came close.  A blind
	 * instrument is the thing this whole exercise is about.
	 *
	 * serialputs and not print: this runs before printinit().
	 */
	lo = stack;
	hi = (uchar*)&here - Mspslack;
	mspsp = (uchar*)&here;
	if(hi <= lo || hi > stack + KSTKSIZE)
		return;			/* mspwatchreport() says so */
	msplo = lo;
	msphi = hi;
	memset(lo, Msppat, hi - lo);
}

/*
 * SAYS WHAT IT FOUND, INCLUDING WHEN IT DECLINED, and says it where a
 * board can hear.
 *
 * The painting has to happen before anything has used the stack, which
 * is before the uart exists -- and the first cut reported from there
 * with serialputs.  Under qemu that works and on silicon it does not:
 * the line went nowhere, so the board printed no geometry at all and
 * the DECLINING case would have been completely silent.  An instrument
 * that cannot report on the hardware it is for is not an instrument.
 *
 * So the paint stays early and the report moves to after printinit().
 */
void
mspwatchreport(void)
{
	if(msplo == nil){
		print("msp stack %#p..%#p sp %#p: sp is not in it,"
			" not watching\n",
			stack, stack + KSTKSIZE, mspsp);
		return;
	}
	print("msp stack %#p..%#p sp %#p, watching %d bytes\n",
		stack, stack + KSTKSIZE, mspsp, (int)(msphi - msplo));
}

/*
 * How much of the array the stack has never touched, which is the
 * number that matters: when it reaches zero the next push is writing
 * over a kernel variable 24K of which lie below, and nothing will say
 * so until something else breaks.
 *
 * -1 if the array was never painted.  A reading of 0 does not prove an
 * overflow -- the pattern is one byte -- but it is the only reading
 * that can.
 */
int
mspheadroom(void)
{
	uchar *p;

	if(msplo == nil)
		return -1;
	for(p = msplo; p < msphi; p++)
		if(*p != Msppat)
			break;
	return p - msplo;
}

/*
 * The array's size, so the headroom reads as a fraction: a reader who
 * does not know the stack is 4096 bytes cannot tell 400 bytes of
 * headroom from 400 bytes of stack.
 */
int
mspspan(void)
{
	return KSTKSIZE;
}


/*
 * HAS SP LEFT ITS STACK?  Asked once a tick, from clockintr, of the
 * exception frame's own address -- which is on whatever stack was
 * current when the exception was taken, so no register is needed.
 *
 * Why this exists.  os/inferno/stm32f407's keyring-plus-ssl arm dies
 * with an exception-entry stacking fault at 0x1fffffec, the bottom of
 * SRAM, with no fault before it and no allocation failure: SP was
 * already outside any stack when the next interrupt tried to push its
 * frame.  Three candidates were ruled out by measurement -- Blocks are
 * not exhausted, the process stacks peak at 3804 to 3908 of 4096, and
 * this array still had 2228 bytes untouched at the last sample -- and
 * all three samples are taken from the IDLE hook, which a dying
 * process outruns.  This is the same question asked somewhere the
 * answer is still true.
 *
 * The boot stack sits at 0x200069ec with 27K of kernel data below it
 * and no guard, so an overflow writes over that data silently and only
 * faults on leaving SRAM.  A frame below the array but still in SRAM is
 * that overflow, caught while SP is sane and the PC still means
 * something.
 *
 * Once only, with iprint: the machine is usually dying by then and the
 * console FIFO loses buffered prints before a panic.
 */
void
stackcheck(void *frame)
{
	static int said;
	uintptr a;

	if(said || frame == nil)
		return;
	a = (uintptr)frame;
	if(a >= (uintptr)stack && a < (uintptr)stack + KSTKSIZE)
		return;			/* the boot and interrupt stack */
	if(inkstack(a))
		return;			/* some process's kernel stack */
	said = 1;
	iprint("STACK ESCAPED: frame %#p is in no stack;"
		" boot %#p..%#p headroom %d",
		frame, stack, stack + KSTKSIZE, mspheadroom());
	if(up != nil)
		iprint(", up pid %d %s kstack %#p", up->pid, up->text,
			up->kstack);
	iprint("\n");
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
	mspwatchinit();
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
	mspwatchreport();

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
