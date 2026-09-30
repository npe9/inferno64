#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "io.h"
#include "version.h"

extern int distrack;		/* libinterp/heap.c: the Dis heap watchdog */

extern Mach mach0;
/*
 * m and up are external registers now (dat.h), so there is no
 * definition of either here and no initialiser to give them.  What the
 * initialiser was for still matters: m must never be nil, not even for
 * the instant between a JTAG image load and machinit(), because a warm
 * restart arrives with the generic timer still armed and pending at the
 * per-core controller -- measured: core timer irq control 0x2, core0 irq
 * source 0x2 -- so clockintr can run before machinit() and fault on
 * "p->time[p->insyscall]++" with p = m->proc.  Every build of this board
 * took that fault, and the trap report said "m = 0000000000000000".
 * boot1 in l.s sets R27 to &mach0 and R26 to nil before it calls main,
 * which is the same guarantee one instruction earlier than a data-segment
 * initialiser could give it.
 */
Mach *machp[MAXMACH];		/* machp[0] = &mach0; the rest set by cpustart() */
Conf conf;

extern ulong kerndate;
extern int cflag;
extern int watchcomvec;		/* config: watch libinterp's comvec for stores */
extern int consoleprint;
extern int main_pool_pcnt;
extern int heap_pool_pcnt;
extern int image_pool_pcnt;

/*
 * segflush(): make instructions written as data visible to the fetcher.
 *
 * This was "USED(p, l); return 1;" -- a no-op -- which was harmless only
 * while cflag was 0 and every instruction was interpreted.  It is not
 * harmless with a code generator: the JIT writes instructions through
 * the data side, and on an A53 the instruction side will happily fetch
 * whatever was in its lines before.  Clean the range to the point of
 * coherency and then drop the stale instruction lines; cacheiinv() ends
 * in DSB and ISB, which orders the next fetch behind both.
 *
 * QEMU would never have caught this.  TCG does not model a split
 * instruction and data cache, so a missing flush passes under emulation
 * and fails only on silicon, which is the worst shape a bug can have on
 * this board.
 */
int
segflush(void *p, ulong l)
{
	cacheflush(p, l);
	cacheiinv();
	return 1;
}

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

void
confinit(void)
{
	ulong base;

	archconfinit();

	base = PGROUND((uintptr)end);
	conf.base0 = base;
	conf.base1 = 0;
	conf.npage1 = 0;
	conf.npage0 = (conf.topofmem - base)/BY2PG;
	conf.npage = conf.npage0 + conf.npage1;
	conf.mem[0].base = base;
	conf.mem[0].npage = conf.npage0;
	conf.ialloc = (ulong)(((((uvlong)conf.npage*main_pool_pcnt)/100)/2)*BY2PG);
	conf.nproc = 200;
	conf.nmach = 1;
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

/*
 * What the last boot left in the crumb record at 0x20000000 (l.s
 * crumbentry, trap.c): the last exception taken, and any exception on
 * a wild SP or label gotolabel refused.  RAM there survives a reset
 * that is not a power cycle, so after a hang and a reset this says
 * where the kernel was.  Printed before anything can overwrite it.
 */
static void
crumbdump(void)
{
	volatile uvlong *c = (volatile uvlong*)0x20000000;
	int i;

	if(c[0] != 0x43524d42ULL)	/* power-on contents, not a record */
		goto clear;
	serialputs("CRUMB previous boot: exceptions ", -1);
	serialputdec(c[1]);
	serialputs(", last type ", -1);
	serialputdec(c[7]);
	serialputreg("esr", c[2], 8);
	serialputreg("elr", c[3], 16);
	serialputreg("spsr", c[5], 3);
	serialputreg("sp", c[6], 16);
	serialputs("\n", -1);
	if(c[147] != 0){
		serialputs("CRUMB wildsp elr", -1);
		serialputreg("", c[144], 16);
		serialputreg("spsr", c[145], 3);
		serialputreg("esr", c[146], 8);
		serialputreg("sp", c[147], 16);
		serialputreg("lr", c[148], 16);
		serialputs("\n", -1);
	}
	if(c[153] != 0){
		serialputs("CRUMB badlabel", -1);
		serialputreg("", c[152], 16);
		serialputreg("sp", c[153], 16);
		serialputreg("pc", c[154], 16);
		serialputreg("caller", c[155], 16);
		serialputs("\n", -1);
	}
clear:
	for(i = 0; i < 160; i++)
		c[i] = 0;
}

/*
 * Put the JTAG restart trampoline where a loaded image cannot reach it.
 *
 * l.s's jtagstub undoes what a running kernel has done to the machine
 * -- MMU, caches, TTBRs, VBAR, TLBs -- so that a kernel loaded over
 * JTAG can be entered at KTZERO with the state its entry code assumes.
 * It cannot live in the image it is replacing, so it is copied below
 * KTZERO, into the region the firmware's own stub used and has no
 * further use for.
 *
 * Copied after mmuinit(), because it is cleaned to the point of
 * coherency: the CPU will fetch it with the caches off, so it has to
 * be in memory and not only in a dirty line.
 */
static void
jtagstubinstall(void)
{
	extern void jtagstub(void), jtagstubend(void);
	usize n;

	n = (uchar*)jtagstubend - (uchar*)jtagstub;
	if(n == 0 || n > 4096){
		print("jtagstub: %lud bytes is not a sane stub; not installed\n", (ulong)n);
		return;
	}
	memmove((void*)Jtagstub, (void*)jtagstub, n);
	cacheflush((void*)Jtagstub, n);
	print("JTAG-STUB %lud bytes at %#p\n", (ulong)n, (void*)Jtagstub);
}

void
main(void)
{
	long *p, *ep;
	int n;

	/*
	 * FIRST, before the BSS is zeroed and before anything else: stop the
	 * timer interrupt reaching cores 1-3.
	 *
	 * A warm restart through the JTAG trampoline does not reset the
	 * cores, so a secondary that a previous kernel started is still
	 * running, with its VBAR pointing at that kernel's vector table and
	 * its timer armed -- and this image is being written over both.  The
	 * per-core timer routing registers in the BCM2836 local controller
	 * are writable from any core, so core 0 can take those interrupts
	 * away before it disturbs anything the other cores could be
	 * executing.  Nothing here depends on the MMU, which is still off.
	 *
	 * A cold boot makes this a no-op three times over; that is the price
	 * of it being unconditional.  smpbcm.c turns each core's route back
	 * on as it starts that core.
	 */
	for(n = 1; n < MAXMACH; n++)
		*(volatile ulong*)(0x40000040 + 4*n) = 0;

	p = (long*)edata;
	ep = (long*)end;
	while(p < ep)
		*p++ = 0;

	machinit();
	archreset();
	confinit();
	fpinit();

	/*
	 * The build's date stamp on the first line, so a serial log says
	 * which image the Pi actually booted -- a stale kernel8.img on the
	 * card looks exactly like a failed fix.  Not snprint: the first use
	 * of a format verb runs fmtinstall(), which takes a spinlock, and an
	 * LDXR/STXR lock before mmuinit() hangs a real Cortex-A53 (QEMU lets
	 * it through).  Doing that here silenced two boots entirely.
	 */
	serialputs("Inferno/arm64 raspi3b build ", -1);
	serialputdec(kerndate);
	/*
	 * And how we got here.  The JTAG trampoline enters with x0 =
	 * "JTAG" (tools/jtag/README); the firmware passes a DTB pointer.
	 * Printing it makes the boot ABI something the console shows
	 * rather than something the documentation asserts -- the first
	 * restart over JTAG was diagnosed by reading registers through
	 * the debugger precisely because the kernel said nothing about
	 * which way it had been entered.
	 *
	 * It matters beyond bookkeeping: a warm restart leaves the SoC
	 * peripherals as the previous kernel had them -- DMA channels
	 * possibly active, the eMMC possibly mid-transaction, USB and
	 * the interrupt controller untouched -- and none of that is
	 * reset by a trampoline that only normalises the CPU.
	 */
	if(bootx0 == Jtagmagic)
		serialputs(" (warm, entered over JTAG)", -1);
	serialputs("\n", -1);
	crumbdump();

	uartconsole();
	archconsole();

	/*
	 * xinit() takes xlists with _tas().  On real A53 hardware an
	 * LDXR/STXR lock is not sound while the MMU is off and RAM has no
	 * Normal-memory translation attributes; QEMU happens to accept it.
	 * Establish the identity map before the first kernel lock.
	 */
	mmuinit();
	jtagstubinstall();
	xinit();
	poolinit();
	poolsizeinit();
	trapinit();
	clockinit();
	{	/* seed wall-clock from the PL031 RTC (calendar time) */
		extern vlong rtctime(void);
		vlong t = rtctime();
		if(t > 0)
			todset(t, 0, 0);
	}
	quotefmtinstall();
	printinit();

	cpuboot();			/* the other three cores; smpbcm.c */

	if(watchcomvec){
		/*
		 * Arm the one hardware watchpoint on libinterp's comvec, the
		 * JIT entry trampoline, because that is the word found holding
		 * a framebuffer-shaped address when the board freezes with the
		 * secondaries taking interrupts (doc/raspi3b-completion-plan.ms).
		 * Its address is taken here rather than written in the config,
		 * since it moves with every build.
		 *
		 * Every store is reported, the legitimate ones included --
		 * comvec's own assignment by compile() is the first hit -- since
		 * a watchpoint that guesses which store is the wrong one is not
		 * an instrument.
		 */
		extern void (*comvec)(void);
		void (*save)(void);

		print("WATCH arming on comvec at %#p\n", &comvec);
		save = comvec;
		watchset(&comvec);
		/*
		 * And immediately test it, by storing to the word it is
		 * watching and putting it back.  A watchpoint that is not
		 * firing looks exactly like an address nobody writes, and
		 * three separate things have to be right for it to fire at all
		 * -- DBGWCR's PAC field, MDSCR.MDE, and PSTATE.D, which boot1
		 * leaves masked.  So the instrument says so itself: two WATCH
		 * lines here mean it works, and none means every later silence
		 * is meaningless.
		 */
		comvec = nil;
		comvec = save;
		{
			uvlong w[4];

			watchstate(w);
			print("WATCH self-test done; wvr %#llux wcr %#llux"
				" mdscr %#llux daif %#llux\n", w[0], w[1], w[2], w[3]);
		}
	}

	{	/* I2C probe: needs the console up to report the round trip */
		extern void i2cinit(void);
		i2cinit();
	}

	{	/* SPI0 probe: read the JEDEC id of any attached serial flash */
		extern void spiinit(void);
		spiinit();
	}

	{	/* GPIO probe: drive a pin and read its level back */
		extern void gpioinit(void);
		gpioinit();
	}

	{	/* VideoCore mailbox probe: verify the property channel */
		extern void mailboxinit(void);
		mailboxinit();
	}

	{	/*
		 * Bluetooth: power the radio through the firmware's GPIO
		 * expander and give it the PL011.  After the mailbox,
		 * which is the only way to BT_ON, and after the GPIO
		 * probe, whose pins it takes four of.
		 */
		extern void btinit(void);
		btinit();
	}

	{	/* hardware RNG: replaces the software LCG behind /dev/random */
		extern void rnginit(void);
		rnginit();
	}

	{	/* power management: the watchdog, and the reset it drives */
		extern void pminit(void);
		pminit();
		{
			extern void pwminit(void);
			extern void systmrinit(void);
			extern void therminit(void);
			pwminit();
			systmrinit();
			therminit();
			{
				extern void otpinit(void);
				extern void dmainit(void);
				otpinit();
				dmainit();
				{
					extern void auxinit(void);
					extern void armtmrinit(void);
					extern void i2sinit(void);
					extern void auxspiinit(void);
					extern void smiinit(void);
					extern void bscslinit(void);
					auxinit();
					armtmrinit();
					i2sinit();
					auxspiinit();
					smiinit();
					bscslinit();
				}
			}
		}
#ifdef SDIOTEST
		{
			extern void sdiocheck(void);
			sdiocheck();
		}
#endif
	}

	procinit();
	iprint("links\n");
	links();
	iprint("screeninit\n");
	screeninit();
	iprint("fdtinit\n");
	{
		/* QEMU passes no DTB in x0 to a bare ELF via -kernel, so this
		 * is inert here; correct if a future Image-header kernel gets
		 * x0.  The reader (../port/fdt.c) is exercised on riscv. */
		extern void *dtbptr;
		extern void fdtinit(void*);
		fdtinit(dtbptr);
	}
	iprint("chandevreset\n");
	chandevreset();
	uartconsolesetup();

	eve = strdup("inferno");
	kbdinit();

	vcsweep("boot");		/* the baseline list; smpbcm.c */

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
	poperror();

	clockcheckboot();

	/*
	 * Publish the board MAC the firmware knows (mailbox.c) as
	 * /env/ethaddr so the Limbo USB ethernet driver (etherusb) can
	 * give the LAN9514, which has no EEPROM on the Pi, its address.
	 */
	if(waserror() == 0){
		extern int mboxgetmac(uchar*);
		uchar mac[6];
		char buf[32];

		if(mboxgetmac(mac) == 0){
			snprint(buf, sizeof buf, "%2.2ux%2.2ux%2.2ux%2.2ux%2.2ux%2.2ux",
				mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
			ksetenv("ethaddr", buf, 0);
			print("MBOX ethaddr %s\n", buf);
		}else
			print("MBOX no board mac\n");
		poperror();
	}
	/*
	 * Interrupts are live from here (spllo() at the top of init0),
	 * which is the earliest the ARM timer's delivery can be tested
	 * at all -- see armtmrintrcheck().
	 */
	{
		extern void armtmrintrcheck(void);
		armtmrintrcheck();
	}
	/*
	 * The polled console path, which panic() and iprint() use and
	 * which no other check reaches.
	 */
	{
		extern void uartputccheck(void);
		uartputccheck();
	}
	/*
	 * This board's ethernet driver, its file server and everything
	 * above them are Limbo, so the Dis interpreter's per-instruction
	 * heap watchdog is charged to every frame that arrives.  Measured
	 * under a hundred frames a second: with it on, the kernel came
	 * back for the next frame every 60ms and the server handed 7
	 * frames straight to a waiting reader; with it off, every 8ms and
	 * 1222.  The Pi needs the machine more than it needs the
	 * instrument, which stays on by default everywhere else.  Set it
	 * back to 1 here to watch a heap corruption on this board.
	 */
	distrack = 0;
	disinit("/osinit.dis");
}

static uintptr	kstacktop(Proc*);

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
	p->sched.sp = kstacktop(p);
	ready(p);
}

void
exit(int inpanic)
{
	extern void wdogset(int);	/* pmbcm.c */

	up = 0;
	/*
	 * Say so, because one thing reads it: pl011_kick bounds how much
	 * it will poll out under ilock, so that a print() from inside a
	 * handler cannot hold interrupts off for the length of the
	 * console queue -- and lifts that bound while the machine is
	 * stopping, when nothing will come back for the rest of the
	 * line.  chandevshutdown() below prints with interrupts off and
	 * is exactly that case: it is what once left a reboot stopped
	 * mid-line at "#S/sd".
	 */
	active.exiting = 1;
	/*
	 * Arm the watchdog before shutting anything down, not after.
	 *
	 * The way out of here is archreboot(), which is the watchdog with
	 * a short count -- and it is at the far end of chandevshutdown().
	 * A device that hangs on the way out therefore leaves the machine
	 * neither running nor restarting, which is what a reboot on this
	 * board did twice: the console stopped and the network went, and
	 * the board sat there until its power was pulled.  Eight seconds
	 * is long enough for an orderly shutdown to beat it and short
	 * enough not to be waited on.
	 */
	if(!inpanic)
		wdogset(8000);
	chandevshutdown();
	if(inpanic){
		print("Hit the reset button\n");
		for(;;)
			clockpoll();
	}
	archreboot();
}

/*
 * The initial kernel SP of a process, rounded down to 16 bytes.  malloc
 * only promises 8-byte alignment, and SCTLR_EL1.SA makes the A53 take an
 * SP-alignment fault on any stack access through an SP that is not a
 * multiple of 16 -- after which the exception entry, on the same SP,
 * faults again, forever, with every exception masked.  A process whose
 * kstack happened to come back from malloc at ...8 silenced the Pi a
 * few seconds into boot, depending on allocation order; QEMU does not
 * check SP alignment, so it booted every time there.
 */
static uintptr
kstacktop(Proc *p)
{
	return ((uintptr)p->kstack+KSTACK-16) & ~(uintptr)15;
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
	p->sched.sp = kstacktop(p);
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

ulong
va2pa(void *v)
{
	return (ulong)v;
}
