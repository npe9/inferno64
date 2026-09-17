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

Mach *m;
Conf conf;

int idle_spin;

extern void (*i8237alloc)(void);
extern void bootscreeninit(void);
extern void multibootdebug(void);

void
main(void)
{
	mach0init();
	bootargsinit();
	trapinit0();
	ioinit();
	i8250console();
	quotefmtinstall();
	screeninit();
	print("\nPlan 9\n");
	cpuidentify();
	meminit0();
	archinit();
	if(arch->clockinit)
		arch->clockinit();
	meminit();
	ramdiskinit();
	confinit();
	xinit();
	trapinit();
	mathinit();
	if(i8237alloc != nil)
		i8237alloc();
	pcicfginit();
	bootscreeninit();
	printinit();
	cpuidprint();
	mmuinit();
	if(arch->intrinit)	/* launches other processors on an mp */
		arch->intrinit();
	timersinit();
	if(arch->clockenable)
		arch->clockenable();
	procinit0();
	initseg();
	links();
	chandevreset();
	pageinit();
	userinit();
	schedinit();
}

void
mach0init(void)
{
	conf.nmach = 1;
	MACHP(0) = (Mach*)CPU0MACH;
	m->pdb = (ulong*)CPU0PDB;
	m->gdt = (Segdesc*)CPU0GDT;

	machinit();

	active.machs[0] = 1;
	active.exiting = 0;
}

void
machinit(void)
{
	int machno;
	ulong *pdb;
	Segdesc *gdt;

	machno = m->machno;
	pdb = m->pdb;
	gdt = m->gdt;
	memset(m, 0, sizeof(Mach));
	m->machno = machno;
	m->pdb = pdb;
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
init0(void)
{
	char buf[2*KNAMELEN], **sp;
	int argc;

	chandevinit();

	if(!waserror()){
		snprint(buf, sizeof(buf), "%s %s", arch->id, conffile);
		ksetenv("terminal", buf, 0);
		ksetenv("cputype", "386", 0);
		if(cpuserver)
			ksetenv("service", "cpu", 0);
		else
			ksetenv("service", "terminal", 0);
		setconfenv();
		poperror();
	}
	kproc("alarm", alarmkproc, 0);

	/*
	 * The stack and argument vector the entry is given, as pc64's init0
	 * lays them out (its comments say why at length): the entry, init9.c's
	 * _main, takes the vector, not 9front's argv0 in the parameter slot.
	 * The 9front shape that was here handed it a pointer to the bytes
	 * "boot", which it read as the vector, and the first thing it did
	 * faulted reading address 0x746f6f62 - "boot".
	 *
	 * The words are 4 bytes here, so "legacycontrol" wants four of them
	 * where amd64 needs two, and the block is ten words, not eight.
	 */
	sp = (char**)(USTKTOP - sizeof(Tos) - 8 - sizeof(sp[0])*10);
	strcpy((char*)&sp[4], "boot");
	strcpy((char*)&sp[6], getconf("*legacycontrol") != nil ? "legacycontrol" : "legacy");
	argc = 0;
	sp[argc++] = (char*)&sp[4];	/* argv[0] */
	if(getconf("*legacydemo") != nil || getconf("*legacycontrol") != nil)
		sp[argc++] = (char*)&sp[6];
	sp[argc] = nil;			/* and the vector ends */
	sp[argc+1] = (char*)(USTKTOP - sizeof(Tos));	/* the word past it, which init9prog reads */

	splhi();
	fpukexit(nil);
	/* two words below the vector, as pc64 and ospreyenteruservec leave them */
	touserv((char*)sp, (char*)(sp - 2), up->aoutentry != 0 ? up->aoutentry : (uintptr)UTENTRY);
}

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

		/*
		 * Hack for the big boys. Only good while physmem < 4GB.
		 * Give the kernel fixed max + enough to allocate the
		 * page pool.
		 * This is an overestimate as conf.upages < conf.npages.
		 * The patch of nimage is a band-aid, scanning the whole
		 * page list in imagereclaim just takes too long.
		 */
		if(getconf("*imagemaxmb") == 0)
		if(kpages > (64*MB + conf.npage*sizeof(Page))/BY2PG){
			kpages = (64*MB + conf.npage*sizeof(Page))/BY2PG;
			kpages += (conf.nproc*KSTACK)/BY2PG;
		}
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
	 * can't go past the end of virtual memory
	 * (ulong)-KZERO is 2^32 - KZERO
	 */
	if(kpages > ((ulong)-KZERO)/BY2PG)
		kpages = ((ulong)-KZERO)/BY2PG;

	conf.upages = conf.npage - kpages;
	conf.ialloc = (kpages/2)*BY2PG;

	/*
	 * Guess how much is taken by the large permanent
	 * datastructures. Mntcache and Mntrpc are not accounted for.
	 */
	kpages *= BY2PG;
	kpages -= conf.upages*sizeof(Page)
		+ conf.nproc*sizeof(Proc*)
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
procsetup(Proc *p)
{
	fpuprocsetup(p);

	memset(p->gdt, 0, sizeof(p->gdt));
	p->nldt = 0;
	
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
	/* inherit user descriptors */
	memmove(p->gdt, up->gdt, sizeof(p->gdt));

	/* copy local descriptor table */
	if(up->ldt != nil && up->nldt > 0){
		p->ldt = smalloc(sizeof(Segdesc) * up->nldt);
		memmove(p->ldt, up->ldt, sizeof(Segdesc) * up->nldt);
		p->nldt = up->nldt;
	}

	fpuprocfork(p);
}

void
procrestore(Proc *p)
{
	if(p->dr[7] != 0){
		m->dr7 = p->dr[7];
		putdr(p->dr);
	}
	
	if(p->vmx != nil)
		vmxprocrestore(p);

	fpuprocrestore(p);
}

/*
 *  Save the mach dependent part of the process state.
 */
void
procsave(Proc *p)
{
	/* we could just always putdr7(0) but accessing DR7 might be slow in a VM */
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
	mmuflushtlb(PADDR(m->pdb));
}

static void
rebootjump(uintptr entry, uintptr code, ulong size)
{
	void (*f)(uintptr, uintptr, ulong);
	ulong *pdb;

	arch->introff();

	/*
	 * Modify the machine page table to directly map the low 4MB of memory
	 * This allows the reboot code to turn off the page mapping
	 */
	pdb = m->pdb;
	pdb[PDX(0)] = pdb[PDX(KZERO)];
	mmuflushtlb(PADDR(pdb));

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
	if(m->machno){
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

	rebootjump((ulong)entry & ~0xF0000000UL, PADDR(code), size);
}

/*
 * The adapter's console pieces, as pc64/main.c has them: the port layer
 * (userinit.c's smark, and xpwrite in the microkernel) calls kdebugmark
 * and kdebugputs on whichever machine it was built for.  The 8250 at
 * 0x3F8 is the same part on a 386 as on an amd64, so this is that code
 * unchanged.
 */
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
	 * per-byte wait it is held across is bounded.
	 */
	lock(&kdebuglock);
	while(n-- > 0)
		kdebugputc(*s++);
	unlock(&kdebuglock);
}
