#include	"u.h"
#include	"tos.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/pci.h"
#include	"ureg.h"
#include	"pool.h"
#include	"rebootcode.i"

Conf conf;
int idle_spin;

extern void (*i8237alloc)(void);
extern void bootscreeninit(void);

void
confinit(void)
{
	char *p;
	int i, userpcnt;
	ulong kpages;

	if(p = getconf("service")){
		if(strcmp(p, "cpu") == 0)
			cpuserver = 1;
		else if(strcmp(p,"terminal") == 0)
			cpuserver = 0;
	}

	if(p = getconf("*kernelpercent"))
		userpcnt = 100 - strtol(p, 0, 0);
	else
		userpcnt = 0;

	conf.npage = 0;
	for(i=0; i<nelem(conf.mem); i++)
		conf.npage += conf.mem[i].npage;

	conf.nproc = 100 + ((conf.npage*BY2PG)/MB)*5;
	if(cpuserver)
		conf.nproc *= 3;
	if(conf.nproc > 4000)
		conf.nproc = 4000;
	conf.nimage = 200;
	conf.nswap = conf.nproc*80;
	conf.nswppo = 4096;

	if(cpuserver) {
		if(userpcnt < 10)
			userpcnt = 70;
		kpages = conf.npage - (conf.npage*userpcnt)/100;
		conf.nimage = conf.nproc;
	} else {
		if(userpcnt < 10) {
			if(conf.npage*BY2PG < 16*MB)
				userpcnt = 50;
			else
				userpcnt = 60;
		}
		kpages = conf.npage - (conf.npage*userpcnt)/100;

		/*
		 * Make sure terminals with low memory get at least
		 * 4MB on the first Image chunk allocation.
		 */
		if(conf.npage*BY2PG < 16*MB)
			imagmem->minarena = 4*MB;
	}

	/*
	 * can't go past the end of virtual memory.
	 */
	if(kpages > ((uintptr)-KZERO)/BY2PG)
		kpages = ((uintptr)-KZERO)/BY2PG;

	conf.upages = conf.npage - kpages;
	conf.ialloc = (kpages/2)*BY2PG;

	/*
	 * Guess how much is taken by the large permanent
	 * datastructures. Mntcache and Mntrpc are not accounted for.
	 */
	kpages *= BY2PG;
	kpages -= conf.nproc*sizeof(Proc*)
		+ conf.nimage*sizeof(Image)
		+ conf.nswap
		+ conf.nswppo*sizeof(Page*);
	mainmem->maxsize = kpages;

	/*
	 * the dynamic allocation will balance the load properly,
	 * hopefully. be careful with 32-bit overflow.
	 */
	imagmem->maxsize = kpages - (kpages/10);
	if(p = getconf("*imagemaxmb")){
		imagmem->maxsize = strtol(p, nil, 0)*MB;
		if(imagmem->maxsize > mainmem->maxsize)
			imagmem->maxsize = mainmem->maxsize;
	}
}

void
machinit(void)
{
	int machno;
	Segdesc *gdt;
	uintptr *pml4;

	machno = m->machno;
	pml4 = m->pml4;
	gdt = m->gdt;
	memset(m, 0, sizeof(Mach));
	m->machno = machno;
	m->pml4 = pml4;
	m->gdt = gdt;
	m->perf.period = 1;

	/*
	 * For polled uart output at boot, need
	 * a default delay constant. 100000 should
	 * be enough for a while. Cpuidentify will
	 * calculate the real value later.
	 */
	m->loopconst = 100000;
}

void
mach0init(void)
{
	conf.nmach = 1;

	MACHP(0) = (Mach*)CPU0MACH;

	m->machno = 0;
	m->pml4 = (u64int*)CPU0PML4;
	m->gdt = (Segdesc*)CPU0GDT;

	machinit();

	active.machs[0] = 1;
	active.exiting = 0;
}

extern long regtorture(long);		/* regtorture.s */
extern long regtorturecli(long);
extern uvlong regtorturebad;

/*
 * A fixed number of iterations, with the clock read before and after so
 * that the run says how many ticks it actually spanned.
 *
 * Fixed rather than bounded by the clock, and that is a correction: a
 * loop that spins until the tick count has moved cannot spin, it can
 * only wait, and on a guest whose clock advances in bursts rather than
 * with instructions retired it waits for a very long time.  The other
 * session on this machine measured four ticks costing thirty seconds of
 * boot on its guest, for coverage a fixed count gave free.  This one
 * behaves itself - a tick here is about a million iterations - but the
 * shape is wrong either way, because it pays most exactly where it
 * proves least.
 *
 * What the tick count is for is unchanged: it is the evidence that any
 * interrupt happened at all, so a run that spanned none says so and
 * claims nothing.  Four million iterations spans a few ticks here, and
 * a few is enough for what this catches: an entry that loses a register
 * loses it on every interrupt, not on a rare one.
 *
 * The interrupts-off run is the control.  If both are clean the
 * registers survive; if only the interrupts-on one is dirty the trap
 * entry is where they go; if both are dirty the loop itself is wrong
 * and the answer means nothing.  Running the control in the same boot
 * is what makes the pair a measurement rather than an observation.
 */
static void
regcheck(void)
{
	enum { Niter = 4*1000*1000 };
	ulong t0, ticks;
	long bad, clibad;

	clibad = regtorturecli(100*1000);
	t0 = MACHP(0)->ticks;
	bad = regtorture(Niter);
	ticks = MACHP(0)->ticks - t0;
	if(bad != 0)
		print("osprey regcheck: register %ld came back as %#llux across an interrupt, after %lud ticks\n",
			bad, regtorturebad, ticks);
	else if(clibad != 0)
		print("osprey regcheck: the loop is wrong: a register moved with interrupts off\n");
	else if(ticks == 0)
		print("osprey regcheck: inconclusive, no clock tick passed while it ran\n");
	else
		print("osprey regcheck: twelve registers survived %d iterations over %lud clock ticks, and the same loop with interrupts off is clean\n",
			Niter, ticks);
}

/*
 * A frame buffer this layer can set for itself: there is none.  The EFI
 * loader sets a mode and writes *bootscreen, and every boot of this
 * machine comes through it, so the port layer's fallback has nothing to
 * ask for here.  os/osprey/pc/machfb.c is the other machine's answer.
 */
int
ospreymachfb(int*, int*, int*, uvlong*, ulong*)
{
	return -1;
}

void
init0(void)
{
	char buf[2*KNAMELEN], **sp;
	int argc;

	chandevinit();

	if(!waserror()){
		snprint(buf, sizeof(buf), "%s %s", arch->id, conffile);
		ksetenv("terminal", buf, 0);
		ksetenv("cputype", "amd64", 0);
		if(cpuserver)
			ksetenv("service", "cpu", 0);
		else
			ksetenv("service", "terminal", 0);
		setconfenv();
		poperror();
	}
	alarmkprocstart();
	regcheck();
	/*
	 * The stack initcode is entered on.  The user entry (init9.c's
	 * _main) is handed the argument vector itself - the first argument
	 * register, which touser leaves holding the stack pointer, is the
	 * nil-terminated array of argument strings - so the stack pointer
	 * is that array: argv[0] and a nil, with the name's bytes above
	 * them where the program's own frame cannot reach.
	 *
	 * It used to be the other shape, the one 9front has: the vector
	 * made out of the parameter slot itself, argv0 at sp[1] and the nil
	 * that ends it at sp[2].  When exec grew an argument vector
	 * (phase 2.1) _main was changed to take the array and every
	 * microkernel path was given it, and this one - the full
	 * personality's, the only caller of init0 - was not.  argv[0] was
	 * then the nil at sp[0], and initcode's exec of /boot/boot was
	 * refused with "bad arg in system call" before any of the boot file
	 * system was reached.  Both entries lay the vector out the one way
	 * now (ospreyenteruservec in userinit.c is the other).
	 *
	 * sp[0] was the nil that touser leaves where a return address would
	 * be, and is argv[0] now.  Nothing returns through it: startboot
	 * ends by _exits, as it does on the microkernel entry, which has
	 * had this same shape since 2.1.
	 */
	/*
	 * A second word when the machine was configured for it.  A
	 * demonstration that ends the task - an ordinary Plan 9 binary,
	 * whose exits is a real system call and ends the container it runs
	 * in - cannot be in the boot every other check is written against,
	 * for the same reason the window system is behind *riodemo: it is
	 * a thing that happens to the machine rather than a thing the
	 * machine does.  So it is asked for, in plan9.ini, and the
	 * personality is told by its argument vector.
	 */
	sp = (char**)(USTKTOP - sizeof(Tos) - 8 - sizeof(sp[0])*8);
	strcpy((char*)&sp[4], "boot");
	/*
	 * "legacy" runs the unmodified binary with the personality serving
	 * its system calls; "legacycontrol" runs the same binary with the
	 * service not asked for, which is the control that says what the
	 * service is doing.  Thirteen bytes, so two words.
	 */
	strcpy((char*)&sp[6], getconf("*legacycontrol") != nil ? "legacycontrol" : "legacy");
	argc = 0;
	sp[argc++] = (char*)&sp[4];	/* argv[0] */
	if(getconf("*legacydemo") != nil || getconf("*legacycontrol") != nil)
		sp[argc++] = (char*)&sp[6];
	sp[argc] = nil;			/* and the vector ends */
	sp[argc+1] = (char*)(USTKTOP - sizeof(Tos));	/* the word past it, which init9prog reads */

	splhi();
	fpukexit(nil);
	/*
	 * Where the image this task was given actually starts.  init0 used
	 * to enter UTZERO+0x28 outright, which is initcode's entry and was
	 * every image's entry while nothing else was loaded; the p964
	 * personality is linked high now so that an ordinary Plan 9 binary
	 * can have UTZERO, and it comes in through this same init0.  A task
	 * whose loader named no entry - initcode, which proc0 lays down by
	 * hand rather than through a loader - keeps the old address.
	 */
	/*
	 * touserv and not touser: the argument register names the vector
	 * and the stack starts two words below it.  They cannot be the same
	 * word.  The entry spills its argument into the caller's frame at
	 * 8(SP), and with SP on the vector that spill lands on argv[1] -
	 * which was nil and unread while the personality took no arguments,
	 * and is a real argument now.  The *legacydemo word went in and
	 * never came out, because the entry had overwritten it with a
	 * pointer before startboot looked.  ospreyenteruservec leaves the
	 * same two words for the same reason (pc64/l.s says it at length).
	 */
	touserv((char*)sp, (char*)(sp - 2), up->aoutentry != 0 ? up->aoutentry : (uintptr)UTENTRY);
}

static void
serialstr(char *s)
{
	while(*s != 0){
		outb(0x3f8, *s);
		s++;
	}
}

void
main(void)
{
	mach0init();
	bootargsinit();
	if(getconf("console") == nil)
		addconf("console", "0");
	trapinit0();
	ioinit();
	i8250console();
	quotefmtinstall();
	print("osprey: hello world\n");
	print("\nPlan 9\n");
	cpuidentify();
	meminit0();
	archinit();
	if(arch->clockinit)
		arch->clockinit();
	meminit();
	print("init: ramdisk\n");
	ramdiskinit();
	print("init: conf\n");
	confinit();
	print("init: xalloc\n");
	xinit();
	print("init: trap\n");
	trapinit();
	print("init: math\n");
	mathinit();
	if(i8237alloc != nil)
		i8237alloc();
	print("init: pci\n");
	pcicfginit();
	print("init: bootscreen\n");
	bootscreeninit();
	print("init: print\n");
	printinit();
	print("init: cpuid\n");
	cpuidprint();
	print("init: mmu\n");
	mmuinit();
	if(arch->intrinit)
		arch->intrinit();
	print("init: timers\n");
	timersinit();
	if(arch->clockenable)
		arch->clockenable();
	print("init: proc\n");
	procinit0();
	print("init: seg\n");
	initseg();
	print("init: links\n");
	links();
	print("init: devreset\n");
	chandevreset();
	print("init: pages\n");
	preallocpages();
	pageinit();
	serialstr("osprey: entering user space\n");
	print("init: user\n");
	userinit();
	print("init: sched\n");
	schedinit();
}

static void
rebootjump(uintptr entry, uintptr code, ulong size)
{
	void (*f)(uintptr, uintptr, ulong);
	uintptr *pte;

	arch->introff();

	/*
	 * This allows the reboot code to turn off the page mapping
	 */
	*mmuwalk(m->pml4, 0, 3, 0) = *mmuwalk(m->pml4, KZERO, 3, 0);
	*mmuwalk(m->pml4, 0, 2, 0) = *mmuwalk(m->pml4, KZERO, 2, 0);

	if((pte = mmuwalk(m->pml4, REBOOTADDR, 1, 0)) != nil)
		*pte &= ~PTENOEXEC;
	if((pte = mmuwalk(m->pml4, REBOOTADDR, 0, 0)) != nil)
		*pte &= ~PTENOEXEC;

	mmuflushtlb(PADDR(m->pml4));

	/* setup reboot trampoline function */
	f = (void*)REBOOTADDR;
	memmove(f, rebootcode, sizeof(rebootcode));

	/* off we go - never to return */
	coherence();
	(*f)(entry, code, size);

	for(;;);
}

void
exit(int)
{
	cpushutdown();
	splhi();

	if(m->machno)
		rebootjump(0, 0, 0);

	/* clear secrets */
	zeroprivatepages();
	poolreset(secrmem);

	arch->reset();
}

void
reboot(void *entry, void *code, ulong size)
{
	writeconf();
	vmxshutdown();

	/*
	 * the boot processor is cpu0.  execute this function on it
	 * so that the new kernel has the same cpu0.  this only matters
	 * because the hardware has a notion of which processor was the
	 * boot processor and we look at it at start up.
	 */
	while(m->machno != 0){
		procwired(up, 0);
		sched();
	}
	cpushutdown();
	delay(1000);
	splhi();

	/* turn off buffered serial console */
	serialoq = nil;

	/* shutdown devices */
	chandevshutdown();

	/* clear secrets */
	zeroprivatepages();
	poolreset(secrmem);

	/* disable pci devices */
	pcireset();

	rebootjump((uintptr)entry & (ulong)~0xF0000000UL, PADDR(code), size);
}

void
procsetup(Proc *p)
{
	fpuprocsetup(p);

	/* clear debug registers */
	memset(p->dr, 0, sizeof(p->dr));
	if(m->dr7 != 0){
		m->dr7 = 0;
		putdr7(0);
	}
}

void
procfork(Proc *p)
{
	fpuprocfork(p);
}

void
procrestore(Proc *p)
{
	/*
	 * A Linux process's thread pointer.  FS is the register a Linux
	 * libc keeps it in - every access to a thread-local, and musl's and
	 * glibc's own bookkeeping, is fs-relative - and this kernel uses FS
	 * for nothing (mmuinit sets its base to zero and leaves it), so the
	 * whole of what arch_prctl(ARCH_SET_FS) has to do is put the base
	 * in the register and keep it across a switch.  GS is not free the
	 * same way: it carries the Mach pointer.
	 */
	if(p->linuxfsbase != 0)
		wrmsr(FSbase, (uvlong)p->linuxfsbase);

	if(p->dr[7] != 0){
		m->dr7 = p->dr[7];
		putdr(p->dr);
	}
	
	if(p->vmx != nil)
		vmxprocrestore(p);

	fpuprocrestore(p);
}

void
procsave(Proc *p)
{
	/*
	 * And back to zero on the way out, so that a process which never
	 * set one does not inherit the last one's thread pointer from the
	 * processor.
	 */
	if(p->linuxfsbase != 0)
		wrmsr(FSbase, 0ull);

	if(m->dr7 != 0){
		m->dr7 = 0;
		putdr7(0);
	}
	if(p->state == Moribund)
		p->dr[7] = 0;

	fpuprocsave(p);

	/*
	 * While this processor is in the scheduler, the process could run
	 * on another processor and exit, returning the page tables to
	 * the free list where they could be reallocated and overwritten.
	 * When this processor eventually has to get an entry from the
	 * trashed page tables it will crash.
	 *
	 * If there's only one processor, this can't happen.
	 * You might think it would be a win not to do this in that case,
	 * especially on VMware, but it turns out not to matter.
	 */
	mmuflushtlb(PADDR(m->pml4));
}

int
pcibiosinit(int *, int *)
{
	return -1;
}

/*
 * Last-resort console: a direct polled write to COM1, owing nothing to
 * the uart driver or the console device.  This is the debug putchar seL4
 * keeps - the one output that must work before any driver task exists
 * and after the console has moved to userspace.  It is not the fast
 * path; it is the path that must never depend on anything, so it drives
 * the 8250 by hand rather than through consuart.
 */
enum {
	Com1	= 0x3F8,	/* COM1 base */
	Thr	= 0,		/* transmit holding (DLAB=0) */
	Dll	= 0,		/* divisor latch low (DLAB=1) */
	Dlm	= 1,		/* divisor latch high (DLAB=1) */
	Ier	= 1,		/* interrupt enable */
	Fcr	= 2,		/* FIFO control */
	Lcr	= 3,		/* line control */
	Lsr	= 5,		/* line status */
	Thre	= 0x20,		/* transmit holding empty */
	Dlab	= 0x80,		/* divisor latch access */
};

/*
 * Configure COM1 for 115200 8N1 the first time the last-resort console
 * is used, so it owes nothing to firmware or the uart driver having set
 * the port up.  Idempotent: done once, guarded by a static flag.
 */
static void
kdebugsetup(void)
{
	static int done;

	if(done)
		return;
	done = 1;
	outb(Com1+Ier, 0);		/* no interrupts: this is polled */
	outb(Com1+Lcr, Dlab);		/* divisor latch */
	outb(Com1+Dll, 1);		/* 115200 = 115200/1 */
	outb(Com1+Dlm, 0);
	outb(Com1+Lcr, 3);		/* 8 bits, no parity, 1 stop; DLAB off */
	outb(Com1+Fcr, 0xC7);		/* enable and clear the FIFOs */
}

void
kdebugputc(int c)
{
	int i;

	kdebugsetup();
	if(c == '\n')
		kdebugputc('\r');
	for(i = 0; i < 100000 && (inb(Com1+Lsr) & Thre) == 0; i++)
		;
	outb(Com1+Thr, c);
}

static Lock kdebuglock;

/*
 * A locked raw COM1 write for the boot marker (smark).  It shares
 * kdebuglock with kdebugputs so the marker and the user tasks' console
 * writes do not interleave, but it does NOT call kdebugsetup - that would
 * disable COM1 interrupts, which is fatal to pc64's interrupt-driven
 * console, and smark runs on every kernel.  It waits for the transmit
 * register per byte, which is what keeps bytes from dropping.
 */
void
kdebugmark(char *s, int n)
{
	int i;

	lock(&kdebuglock);
	while(n-- > 0){
		for(i = 0; i < 100000 && (inb(0x3fd) & 0x20) == 0; i++)
			;
		outb(0x3f8, *s++);
	}
	unlock(&kdebuglock);
}

void
kdebugputs(char *s, int n)
{
	extern uvlong kdebugputsbytes;
	kdebugputsbytes += n;

	/*
	 * Serialise whole strings so the two user tasks' console writes do
	 * not interleave: each waits for the UART per byte, and with both
	 * writing at once their bytes would splice together mid-line, which
	 * is legible to a person but splits a string a test greps for.
	 *
	 * Safe to lock here on this kernel: only the user write syscall
	 * (xpwrite) reaches kdebugputs - panic and print take a different
	 * path (putstrn -> screenputs), and the boot marker smark writes COM1
	 * raw - so no panic or interrupt path waits on this lock, and the
	 * per-byte wait it is held across is bounded.  On pc64 nothing calls
	 * kdebugputs at all, so the lock never runs there.
	 */
	lock(&kdebuglock);
	while(n-- > 0)
		kdebugputc(*s++);
	unlock(&kdebuglock);
}
