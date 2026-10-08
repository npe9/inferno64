#include	"u.h"
#include	"tos.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"ureg.h"
#include	"rebootcode.i"
#include	"kernel.h"		/* for kopen() only */

#define X86STEPPING(x)	((x) & 0x0F)
#define X86MODEL(x)	(((x)>>4) & 0x0F)
#define X86FAMILY(x)	(((x)>>8) & 0x0F)

Conf conf;
int idle_spin;

extern u32 kerndate;
extern void bootscreeninit(void);
extern int main_pool_pcnt;
extern int heap_pool_pcnt;
extern int image_pool_pcnt;
int	pckdebug;

static  uchar *sp;	/* stack pointer for /boot */

char bootdisk[KNAMELEN];

extern void ffmain(void);	/* forth interpreter */
extern intptr mventry_dp;
extern intptr mc_dp;
extern intptr dtop;
/* until I sort out the mp initialization issue */
extern void startaps(void);

static void
doc(char *m)
{
	/*int i;*/
	print("%s...\n", m);
	/*for(i = 0; i < 100*1024*1024; i++)
		i++;*/
}

enum {
	VGA_COLOR_BLACK = 0,
	VGA_COLOR_BLUE = 1,
	VGA_COLOR_GREEN = 2,
	VGA_COLOR_CYAN = 3,
	VGA_COLOR_RED = 4,
	VGA_COLOR_MAGENTA = 5,
	VGA_COLOR_BROWN = 6,
	VGA_COLOR_LIGHT_GREY = 7,
	VGA_COLOR_DARK_GREY = 8,
	VGA_COLOR_LIGHT_BLUE = 9,
	VGA_COLOR_LIGHT_GREEN = 10,
	VGA_COLOR_LIGHT_CYAN = 11,
	VGA_COLOR_LIGHT_RED = 12,
	VGA_COLOR_LIGHT_MAGENTA = 13,
	VGA_COLOR_LIGHT_BROWN = 14,
	VGA_COLOR_WHITE = 15,
	Nvideo = 80*25,
};

extern u64 MemMin;
u32 nchars = 0;

void
writemsg(char *msg, int msglen)
{
	u8 *video = (u8*)0xB8000;
	u8 colour = VGA_COLOR_LIGHT_GREY | (VGA_COLOR_BLACK<<4);
	u32 i;

	if(nchars == 0){
		memset(video, 0, Nvideo*2);
	}else if(nchars + msglen >= Nvideo){
		memmove(video, video+(2*msglen), 2*(nchars-msglen));
		nchars -= msglen;
	}
	video += nchars*2;
	for(i = nchars; i < nchars+msglen; i++){
		*video++ = *msg++;
		*video++ = colour;
	}
	nchars += msglen;
}

/* used by ff */
void
show_ff_return_stack(void)
{
	intptr* i;

	for(i = (intptr*)0x112000; i<(intptr*)0x112020; i++){
		print("0x%p: 0x%zx\n", i, *i);
	}
}

void
screenput(char *msg, int msglen)
{
	show_ff_return_stack();
	print("msg %c, msglen %d\n", *msg, msglen);
	if(screenputs != nil)
		screenputs(msg, 1);
	else
		writemsg(msg, msglen);
	print("\nscreenput exiting\n");
	show_ff_return_stack();
	print("\n");
}

void
ptedebug(uintptr pa, char *desc)
{
	uintptr *pml4e, *pdpe, *pde;
	char pdestr[64] = "unmapped";

	pml4e = mmuwalk((uintptr*)PML4ADDR, pa, 3, 0);
	pdpe = mmuwalk((uintptr*)PML4ADDR, pa, 2, 0);
	pde = mmuwalk((uintptr*)PML4ADDR, pa, 1, 0);
	if((intptr)pde > 0){
		snprint(pdestr, 64, "at 0x%p i %zd has 0x%p",
				pde, ((intptr)pde-(intptr)PD0ADDR)/sizeof(intptr), *pde);
	}
	print("\tpage of address 0x%zux (%s) with pml4 at 0x%p\n"
			"\t\tpml4 entry at 0x%p i %zd has 0x%p\n"
			"\t\tpdp entry at 0x%p i %zd has 0x%p\n"
			"\t\tpd entry %s\n",
			pa, desc, m->pml4,
			pml4e, (pml4e-m->pml4)/sizeof(intptr), *pml4e,
			pdpe, ((intptr)pdpe-(intptr)PDPADDR)/sizeof(intptr), *pdpe,
			pdestr);
}

void
showconfig(void)
{
	showconf();
	print("Important Addresses\n"
		"\tkdzero 0x%p confaddr 0x%p apbootstrap 0x%p idtaddr 0x%p\n"
		"\tcpu0mach 0x%p cpu0sp 0x%p cpu0gdt 0x%p\n"
		"\tcpu0pml4 0x%p cpu0pdp 0x%p  cpu0pd 0x%p\n"
		"\tcpu0end 0x%p\n"
		"\tetext 0x%p edata 0x%p end 0x%p\n",
		(void*)KDZERO, CONFADDR,APBOOTSTRAP,
		IDTADDR, CPU0MACH, CPU0SP, GDTADDR,
		PML4ADDR, PDPADDR, PD0ADDR, CPU0END,
		etext, edata, end);
	print("Some page table entries\n");
	ptedebug(1*MiB,"1 MiB");
	ptedebug(2*MiB,"2 MiB");
	ptedebug(400*MiB,"400 MiB");
	ptedebug(466*MiB,"466 MiB");
	ptedebug(468*MiB,"468 MiB");
	ptedebug(470*MiB,"470 MiB");
	ptedebug(512*MiB,"512 MiB");
	ptedebug(1*GiB,"1 GiB");
	ptedebug(4ull*GiB,"4 GiB");
}

/* to check from acid on whether the data segment is being trashed */
/* static int globaldatatest = 0x12345678; */
void
main(void)
{
	outb(0x3F2, 0x00);		/* botch: turn off the floppy motor */

	mach0init();
	bootargsinit();
	{
		char *p;

		/*
		 * Here, not with the other boot options further down: the
		 * page tables are built by meminit0() and meminit(), both
		 * of which run long before those are read, so a flag that
		 * governs the mapping has to be read as soon as there is a
		 * configuration to read it from.  Placed after meminit() it
		 * changed nothing, and both arms of the measurement came
		 * out identical -- which is how that was noticed.
		 */
		if((p = getconf("*pmaplarge")) != nil){
			extern int pmaplarge;
			pmaplarge = strtol(p, nil, 0);
		}
	}
	trapinit0();			/* set up idt, check notes on why so early */
	ioinit();
	i8250console();
	quotefmtinstall();
	screeninit();
	consdebug = rdb;
	print("\nInferno release built at %ud\n", kerndate);
	showconfig();
	cpuidentify();
	meminit0();			/* builds the memmap */
	doc("archinit");
	archinit();
	/*
	 * archinit() maps the ACPI tables, so this is the first moment
	 * the console ACPI names can be reached.  See i8250spcrconsole()
	 * in ../pc/uarti8250.c.
	 */
	doc("i8250spcrconsole");
	i8250spcrconsole();
	doc("arch->clockinit");
	if(arch->clockinit)
		arch->clockinit();
	{
		char *p;

		/*
		 * Before meminit(), because that is where the mapping is
		 * built: read later it would arrive after the decision it
		 * governs.  The rest of the boot options are read further
		 * down, where the devices they concern are set up.
		 */
	}
	doc("meminit");
	meminit();			/* builds the conf.mem entries */
	doc("confinit");
	confinit();
	doc("xinit");
	xinit();
	/* TODO 9front does this for dma
	if(i8237alloc != nil)
		i8237alloc(); */
	doc("pcicfginit");
	pcicfginit();
	doc("bootscreeninit");
	bootscreeninit();	/* vga maps pages for the frame buffer TODO bug causes an i8042 system reset in poolsizeinit() */
	trapinit();
	printinit();
	cpuidprint();
	doc("mmuinit");
	mmuinit();		/* builds the page tables, lgdt, lidt */
	memmapdump();
	doc("poolsizeinit");
	poolsizeinit();
	memmapdump();
	doc("eve inferno");
	eve = strdup("inferno");
	doc("arch->intrinit");
	if(arch->intrinit){	/* launches other processors on an mp */
		doc("intrinit");
		arch->intrinit();
	}
	doc("timersinit");
	timersinit();
	{
		/*
		 * Seed the wall clock from the CMOS RTC.
		 *
		 * Nothing on this board ever did, so the calendar began at
		 * the epoch on every boot: files were created in January
		 * 1970 and, more to the point, every TLS handshake failed
		 * with "leaf certificate expired or not yet valid",
		 * because a certificate valid now is not yet valid then.
		 * The clock is a prerequisite for talking to anything that
		 * authenticates itself, which on a cloud machine is
		 * everything.
		 *
		 * os/inferno/pc/devrtc.c has had rtctime() all along and
		 * os/inferno/virtarm64/main.c has done exactly this with
		 * its PL031 since that board was written; pc64 was the odd
		 * one out.  A machine with a dead cell reads 0 and is left
		 * at the epoch rather than being moved somewhere worse.
		 */
		extern vlong rtctime(void);
		vlong t = rtctime();
		if(t > 0)
			todset(t, 0, 0);
	}
	doc("mathinit");
	mathinit();
	if(arch->clockenable){
		doc("clockinit");
		arch->clockenable();
	}
	/*
	 * *parallelvm=1 on the boot line runs the Dis interpreter without
	 * the VM lock.  A boot option rather than a compile-time constant
	 * because both modes then come from one kernel: measuring the
	 * other one used to mean an edit, a rebuild of dis.c and a relink,
	 * which is a slow way to ask a question that a boot can answer.
	 * It defaults to 0, which is the tested configuration.
	 */
	{
		extern int parallelvm;		/* os/inferno/port/dis.c */
		extern int disdumpon;		/* likewise */
		char *p;

		if((p = getconf("*parallelvm")) != nil)
			parallelvm = strtol(p, nil, 0);
		if((p = getconf("*disdump")) != nil)
			disdumpon = strtol(p, nil, 0);
	}
	{	/* BISECTION, temporary: *chanlock=0 keeps the restructuring
		 * (cqfill, isendx/irecvx, the deferral) but drops the lock,
		 * so the two halves of the channel change can be measured
		 * apart.  See chanlock() in os/inferno/port/dis.c. */
		extern int chanlockon;
		char *p;

		if((p = getconf("*chanlock")) != nil)
			chanlockon = strtol(p, nil, 0);
	}
	{	/* INSTRUMENTATION, temporary: positive control for rootset's
		 * rootraced counter.  See gcwalkdelayfn() in dis.c. */
		extern int gcwalkms;
		char *p;

		if((p = getconf("*gcwalkdelay")) != nil)
			gcwalkms = strtol(p, nil, 0);
	}
	{
		extern int teardrop;
		char *p;

		if((p = getconf("*spawnwoken")) != nil){
			extern int spawnwoken;
			spawnwoken = strtol(p, nil, 0);
		}
		if((p = getconf("*spawncap")) != nil){
			extern int spawncap;
			spawncap = strtol(p, nil, 0);
		}
		if((p = getconf("*pmaplarge")) != nil){
			extern int pmaplarge;
			pmaplarge = strtol(p, nil, 0);
		}
		if((p = getconf("*runqaudit")) != nil){
			extern int runqaudit;
			runqaudit = strtol(p, nil, 0);
		}
		if((p = getconf("*gcatomic")) != nil){
			extern int gcatomic;
			gcatomic = strtol(p, nil, 0);
		}
		/*
		 * The Dis word tracker, off unless asked for.  It runs once
		 * per Dis instruction over a table initmem() fills, and a
		 * profile put ninety-six per cent of the interpreter inside
		 * it; see the note above distrack in libinterp/heap.c.  It
		 * is a boot word so that a measurement cannot inherit it.
		 */
		if((p = getconf("*distrack")) != nil){
			extern int distrack;
			distrack = strtol(p, nil, 0);
		}
		if((p = getconf("*gcunwind")) != nil){
			extern int gcunwindon;
			gcunwindon = strtol(p, nil, 0);
		}
		if((p = getconf("*idlesingle")) != nil){
			extern int idlesingle;
			idlesingle = strtol(p, nil, 0);
		}
		if((p = getconf("*ctxcap")) != nil){
			extern int ctxcap;
			ctxcap = strtol(p, nil, 0);	/* claimctx() clamps it */
		}
		if((p = getconf("*syncfix")) != nil){
			extern int syncfix;
			syncfix = strtol(p, nil, 0);
		}
		if((p = getconf("*cflag")) != nil){
			extern int cflag;
			cflag = strtol(p, nil, 0);
		}
		if((p = getconf("*fddefer")) != nil){
			extern int fddefer;
			fddefer = strtol(p, nil, 0);
		}
		if((p = getconf("*teardrop")) != nil)
			teardrop = strtol(p, nil, 0);
	}
	doc("procinit");
	procinit();
	doc("links");
	links(); /* runs etherlink() of the link'ed ethernet devices */
	doc("chandevreset");
	chandevreset(); /* reset() all devices */
	doc("userinit");
	userinit(); /* calls init0, which calls chandevinit to init() all devices */
	doc("schedinit");
	active.thunderbirdsarego = 1;
	schedinit();
}

void
mach0init(void)
{
	conf.nmach = 1;

	MACHP(0) = (Mach*)CPU0MACH;

	m->machno = 0;
	m->pml4 = (u64*)PML4ADDR;
	m->gdt = (Segdesc*)GDTADDR;

	machinit();

	active.machs[0] = 1;
	active.exiting = 0;
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
	m->ilockdepth = 0;

	/*
	 * For polled uart output at boot, need
	 * a default delay constant. 100000 should
	 * be enough for a while. Cpuidentify will
	 * calculate the real value later.
	 */
	m->loopconst = 100000;

#ifdef DISCTXREG
	/*
	 * curP is a register (include/disreg.h), so libinterp's
	 * "Pctx* curP = &_pctx" initialiser does not exist and nothing
	 * else gives R13 a value.  Every processor starts on the default
	 * context; sched() moves it to the running Proc's.  This runs on
	 * cpu0 through mach0init() and on each AP through squidboy(),
	 * which is every executor there is.
	 */
#ifdef DISCTXREG
	disctxinit();
#endif
#endif
}

/*
 * could move this to port/userinit.c as 9front does
 * there is nothing arch specific here
 */
void
init0(void)
{
	/*char buf[2*KNAMELEN];*/

	up->nerrlab = 0;

	spllo();
	if(waserror()){
		/*
		 * %r is a documented no-op in this kernel (see
		 * ../port/print.c) -- it only works from Limbo, where
		 * lib9's errfmt() installs it.  print up->errstr
		 * directly or this prints its prefix and nothing else.
		 */
		print("init0: waserror() loop: %s\n", up->errstr);
		panic("init0: %s", up->errstr);
	}
	/*
	 * These are o.k. because rootinit is null.
	 * Then early kproc's will have a root and dot.
	 */
	up->pgrp->slash = namec("#/", Atodir, 0, 0);
	pathclose(up->pgrp->slash->path);
	up->pgrp->slash->path = newpath("/");
	up->pgrp->dot = cclone(up->pgrp->slash);

	chandevinit();
/*	print("devtab\n");
	for(int i=0; devtab[i] != nil; i++){
		print("	i %d devtab[i] 0x%p dc %d name %s\n", i, devtab[i], devtab[i]->dc, devtab[i]->name);
		print("		reset 0x%p init 0x%p shutdown 0x%p\n", devtab[i]->reset, devtab[i]->init, devtab[i]->shutdown);
		print("		attach 0x%p walk 0x%p stat 0x%p\n", devtab[i]->attach, devtab[i]->walk, devtab[i]->stat);
		print("		open 0x%p create 0x%p close 0x%p\n", devtab[i]->open, devtab[i]->create, devtab[i]->close);
		print("		read 0x%p bread 0x%p write 0x%p\n", devtab[i]->read, devtab[i]->bread, devtab[i]->write);
	}*/

	if(waserror() == 0){
		char *sk;

		/*
		 * *soak=1 puts "soak" in the environment, which /dis/init
		 * reads to repeat its workload instead of running it once.
		 * Here, not with the other boot options above: ksetenv()
		 * writes through up->egrp, and up is nil that early -- a page
		 * fault at mathinit(), with "up 0" in the register dump.
		 * Every table in doc/multicore-plan.ms is a 90-second boot of
		 * the one-shot workload, so the default stays exactly that.
		 */
		if((sk = getconf("*poolchain")) != nil){
			extern int poolchainck;

			poolchainck = strtol(sk, nil, 0);
		}
		if((sk = getconf("*gcoff")) != nil){
			extern int gcoff;

			gcoff = strtol(sk, nil, 0);
		}
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
		ksetenv("cputype", "am64", 0);
		//snprint(buf, sizeof(buf), "amd64 %s", conffile);
		//ksetenv("terminal", buf, 0);
		setconfenv();
		poperror();
	}
	kproc("alarm", alarmkproc, 0, 0);

	/*
	 * Run with interrupts on and before any Dis runs:
	 * os/inferno/pc64/regtorture.s says whether an interrupt on this
	 * machine gives every register back.  See doc/inferno-cloud-plan.ms.
	 *
	 * Off unless *regtorture=1 is set in plan9.ini.  It was written
	 * for the interrupt heisenbug that _intrcommon's AX=0 turned out
	 * to be, and that is fixed; what it costs is not small.  Measured
	 * with scripts/boot-profile.py: 6.4 seconds, on a boot whose whole
	 * kernel half is 14.6 -- the single largest gap in the profile and
	 * getting on for half the time this image takes to reach a shell.
	 * The comment below still says two million iterations "cost under
	 * two", which was true when it was written and is not now.
	 *
	 * Kept rather than deleted because it is the reproducer for a
	 * class of bug that cost this branch weeks, and a cloud image
	 * whose entire argument is cold start should not pay for it on
	 * every boot to keep it.
	 */
	if(getconf("*regtorture") != nil){
		extern int regtorture(int);
		extern int regtorturecli(int);
		extern uvlong regtorturebad;
		ulong t0, dt;
		int r, rc;

		/*
		 * Two things this must not be able to say, both of which
		 * the osprey-port branch pointed out after porting the
		 * file: "the registers survived" when no interrupt ever
		 * arrived, and "the registers survived" when the loop
		 * never ran.  So report how many clock ticks the run
		 * spanned and call it inconclusive at zero, and require
		 * the interrupts-off control -- the identical loop, which
		 * must come back clean -- in the same boot.
		 *
		 * The loop is bounded by iterations rather than by ticks.
		 * Spinning until the tick counter moves is the more
		 * obvious way to guarantee coverage and it is far too dear
		 * here: this guest's clock advances in bursts under QEMU,
		 * so waiting for four ticks cost about thirty seconds of
		 * wall time before the shell came up, where two million
		 * iterations cost under two and span ticks anyway.
		 */
		rc = regtorturecli(10*1000);
		t0 = m->ticks;
		r = regtorture(2*1000*1000);
		dt = m->ticks - t0;
		if(r != 0)
			print("regtorture: interrupts on: REGISTER %d became %#llux\n",
				r, regtorturebad);
		else if(rc != 0)
			print("regtorture: INCONCLUSIVE: the interrupts-off control failed\n");
		else if(dt == 0)
			print("regtorture: INCONCLUSIVE: no clock tick during the run\n");
		else
			/* no semicolon in this line: the console prompt is
			 * "; " and a batch that greps for it must not
			 * match our own output */
			print("regtorture: 12 registers survived 2M iterations over %lud ticks, control clean\n", dt);
	}

	/*
	 * This kernel came from 9ferno (github.com/gophone2015), whose
	 * own userland is a Forth interpreter -- goforth(up->fmem) ran
	 * init.f, this board's equivalent of init.rc, from here, and
	 * needed fd0/1/2 on #c/cons open on init0's own fgrp for it.
	 * This tree wants an Inferno native kernel: userinit() now
	 * populates up->env the way every other board does, so the real
	 * Inferno init can run instead, and disinit() below opens
	 * #c/cons itself -- opening it twice on the one shared fgrp left
	 * disinit()'s own kopen() finding fd 0-2 already taken and
	 * handing back fd 3, which its "!= 0" check then panicked on.
	 */
	poperror();
	disinit("/osinit.dis");
	/* init0 will never return */
	panic("init0");
}

void
userinit(void)
{
	Proc *p;

	/*
	 * newforthproc() is for a running process to spawn another
	 * Forth kproc: it calls waserror() and reads up->user, both of
	 * which need a live up.  There is no process yet at all here --
	 * this call built the address it read up->nerrlab through from
	 * a garbage 32-bit count found at physical address 0x330, giving
	 * setlabel() a bogus Label* and a page fault on its first store.
	 * Every other board's userinit() builds its first process with
	 * plain newproc() for exactly this reason; do the same here and
	 * let init0, once it is actually running as up, be the first
	 * Forth process the ordinary way.
	 */
	up = nil;
	if((p = newproc()) == nil){
		panic("no procs for userinit");
	}

	/*
	 * disinit()/schedmod() read the process's namespace through
	 * up->env (Osenv), the Inferno VM convention; devproc.c and the
	 * rest of the portable device layer read it through p->pgrp
	 * directly, the 9front convention this Proc struct also carries.
	 * Populate both, pointing at the same objects, the way every
	 * other board's userinit() does -- portdat.h's comment on Osenv
	 * says exactly this is why it is kept alongside the flat fields.
	 */
	p->env = &p->defenv;
	memset(p->env, 0, sizeof(*p->env));
	p->env->errstr = p->env->errbuf0;
	p->env->syserrstr = p->env->errbuf1;

	p->fgrp = p->env->fgrp = newfgrp(nil);
	p->egrp = p->env->egrp = newegrp();
	p->pgrp = p->env->pgrp = newpgrp();
	kstrdup(&p->user, eve);
	kstrdup(&p->env->user, eve);

	/*
	 * kstrdup, not strcpy.  Proc.text is a char* (portdat.h), not a
	 * buffer, and nothing has set it for this process yet -- newproc()
	 * does not, and only kproc() does, with kstrdup.  So this wrote
	 * "*init*" through a nil pointer, into physical address 0, which
	 * is mapped here and so took the write without complaining.
	 *
	 * It sat harmless for as long as nothing read a pointer back out
	 * of address 0.  The parallel-VM merge made something do: with
	 * curP nil on this path, curP->field reads from 0+offset, picked
	 * up the bytes of the string, and dereferenced them -- a page
	 * fault at CR2 0x2a74696e692a, which is "*init*" in little-endian
	 * ASCII.  The other eleven boards in this tree all say
	 * kstrdup(&p->text, "interp"); pc64 was the only one that did not.
	 */
	kstrdup(&p->text, "*init*");
	/*
	 * Kernel Stack
	 *
	 * N.B. make sure there's
	 *	8 bytes for gotolabel's return PC
	 */
	p->sched.pc = (uintptr)init0;
	p->sched.sp = (uintptr)p->kstack+KSTACK-sizeof(uintptr) - sizeof(Tos) -sizeof(uintptr)/* for the string "boot" */;
	((uintptr*)p->sched.sp)[0] = 0;
	strcpy((char*)p->sched.sp+1,"boot");

	ready(p);
}

void
confinit(void)
{
	char *p;
	int pcnt;
	u64 maxmem;
	int i;

	if(p = getconf("*maxmem"))
		maxmem = strtoull(p, 0, 0);
	else
		maxmem = 0;
	if(p = getconf("*kernelpercent"))
		pcnt = 100 - strtol(p, 0, 0);
	else
		pcnt = 0;

	conf.npage = 0;
	for(i=0; i<nelem(conf.mem); i++)
		conf.npage += conf.mem[i].npage;

	if(pcnt < 10)
		pcnt = 70;
	conf.ialloc = (((conf.npage*(100-pcnt))/100)/2)*BY2PG;
	conf.nproc = 100 + ((conf.npage*BY2PG)/MiB)*5;
	if(conf.nproc > 2000)
		conf.nproc = 2000;
	print("conf.npage %zd conf.ialloc %zud conf.nproc %d\n",
			conf.npage, conf.ialloc, conf.nproc);
	USED(maxmem);
}

void
poolsizeinit(void)
{
	print("poolsizeinit conf.npage %zd\n", conf.npage);
	poolsize(mainmem, ((conf.npage*main_pool_pcnt)/100)*BY2PG, 0);
	poolsize(heapmem, ((conf.npage*heap_pool_pcnt)/100)*BY2PG, 0);
	poolsize(imagmem, ((conf.npage*image_pool_pcnt)/100)*BY2PG, 1);
	print("after poolsizeinit\n");
}

/*
 *  Save the mach dependent part of the process state.
 */
void
procsave(Proc *p)
{
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
	/* TODO obsolete with linear memory? */
	mmuflushtlb();
}
void
procrestore(Proc *p)
{
	if(p->dr[7] != 0){
		m->dr7 = p->dr[7];
		putdr(p->dr);
	}
	
/*	if(p->vmx != nil)
		vmxprocrestore(p);
*/

	fpuprocrestore(p);
}

void
exit(int ispanic)
{
	USED(ispanic);

	up = 0;
	print("exiting\n");

	/* Shutdown running devices */
	chandevshutdown();

	arch->reset();
}

void
reboot(void)
{
	exit(0);
}
