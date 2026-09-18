#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "io.h"
#include "version.h"

extern Mach mach0;
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
 * Bring-up probe for a second processor.  secmain() runs on the
 * secondary with a stack and nothing else: no Mach, so no up/m, which
 * means no print() and no lock -- it may only touch these two words.
 * cpu0 polls them.
 */
/* volatile: cpu0 polls these in a loop and cpu1 is the only writer */
static uvlong	secstackbuf[KSTACK/sizeof(uvlong)];
uintptr		secstacktop;
Mach		mach1;		/* cpu1's own Mach */
Mach*		machp[MAXMACH];
uintptr		secmach;	/* &mach1, read by _secondary */
volatile uintptr	secsp;
volatile uintptr	seccflag;	/* set only by C on cpu1 */
int		secgic = -1;
/*
 * Off.  cpu1 can enter the scheduler -- it works, and it runs
 * processes -- but it corrupts the Dis heap about one boot in ten, with
 * the same track: signature doc/inferno-ports.ms is chasing on pc64.
 * Set to 1 to reproduce; see the commit and doc/multicore-plan.ms.
 */
int		secsched = 0;
volatile uintptr	secalive;
volatile uintptr	seccount;

void
secmain(void)
{
	Mach *mm;
	extern void *vectab;
	extern void vectorinit(void*);
	extern int gicsecondary(void);

	mm = (Mach*)gettpidr();
	seccflag = (uintptr)mm;
	if(vectab != nil)
		vectorinit(vectab);
	secgic = gicsecondary();
	if(secgic == 0)
		clockinit();		/* this processor's own generic timer */
	secalive = 5;
	spllo();			/* take interrupts on this processor */
	/*
	 * Into the scheduler.  The portable run queue is already locked
	 * (Schedq embeds a Lock and proc.c takes it), which is the Plan 9
	 * heritage this kernel kept, so the question is whether anything
	 * else in the path assumes cpu0 -- which is what this is finding
	 * out.  schedinit() does not return.
	 */
	active.machs[m->machno] = 1;
	coherence();
#ifdef DISCTXREG
	disctxinit();		/* curP is a register: this processor needs its own */
#endif
	if(secsched)
		schedinit();
	for(;;){
		seccount = mm->ticks;
		coherence();
		idle();
	}
}

/*
 * PSCI CPU_ON (SMC64 0xc4000003): target, entry point, context.  QEMU
 * virt's conduit is HVC, which psci() in l.s already uses for
 * SYSTEM_RESET and SYSTEM_OFF.  Returns the PSCI status: 0 success,
 * -2 invalid parameters, -4 already on, -3 denied.
 */
void
smpprobe(void)
{
	extern void _secondary(void), _main(void);
	void main(void);
	vlong r;
	int i;
	uvlong c0;

	print("smp: PSCI %#llux, cpu1 %s\n", psci(0x84000000ULL, 0, 0, 0),
		psci(0xc4000004ULL, 1, 0, 0) == 1 ? "off" : "not off");
	secstacktop = ((uintptr)secstackbuf + sizeof secstackbuf) & ~(uintptr)15;
	memset(&mach1, 0, sizeof mach1);
	mach1.machno = 1;
	secmach = (uintptr)&mach1;
	machp[1] = &mach1;
	conf.nmach = 2;		/* cpu1 is about to exist */
	settpidr((uintptr)m);		/* cpu0 takes its own slot too */
	r = psci(0xc4000003ULL, 1, (uintptr)_secondary, 0);
	print("smp: PSCI CPU_ON cpu1 entry %#llux -> %lld\n", (uvlong)(uintptr)_secondary, r);
	if(r != 0)
		return;
	for(i = 0; i < 100 && secalive == 0; i++)
		delay(10);
	print("smp: cpu0 tpidr %#llux (m %#llux), cpu1 stage %llud tpidr %#llux (mach1 %#llux)\n",
		(uvlong)gettpidr(), (uvlong)(uintptr)m, (uvlong)secalive,
		(uvlong)seccflag, (uvlong)(uintptr)&mach1);
	/*
	 * alive 1 = reached the entry, 2 = stack up, 3 = running C.
	 * seccount is incremented by cpu1 in a loop, so two reads a
	 * moment apart say whether it is still going.
	 */
	c0 = seccount;
	delay(50);
	print("smp: MACHP(1)->machno %d gic %d; cpu1 clock ticks %llud -> %llud in 50ms\n",
		MACHP(1)->machno, secgic, (uvlong)c0, (uvlong)seccount);
}

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

static char bootargs[512];

void
bootargsinit(void)
{
	u32int n;

	u32int sz;
	int sel;

	/*
	 * FW_CFG_CMDLINE is empty for a bare ELF -- measured, fw_cfg says 0
	 * bytes -- so the options come from a named item instead:
	 *	-fw_cfg name=opt/bootargs,string='*parallelvm=1'
	 */
	sz = 0;
	if((sel = fwcfgfile("opt/bootargs", &sz)) < 0 || sz == 0)
		return;
	n = sz;
	if(n >= sizeof bootargs)
		n = sizeof bootargs - 1;
	if(fwcfgdma(((u32int)sel<<16) | FwCfgDmaSelect | FwCfgDmaRead,
	    bootargs, n) < 0){
		bootargs[0] = 0;
		return;
	}
	bootargs[n] = 0;
	print("bootargs: %s\n", bootargs);
}

/*
 * "name=value", space separated.  Returns a pointer into a static
 * buffer, valid until the next call -- the same contract pc64's has,
 * and every caller copies or converts immediately.
 */
char*
getconf(char *name)
{
	static char val[128];
	char *p, *e;
	int n;

	n = strlen(name);
	for(p = bootargs; (p = strstr(p, name)) != nil; p += n){
		if(p != bootargs && p[-1] != ' ')
			continue;
		if(p[n] != '=')
			continue;
		p += n + 1;
		for(e = p; *e != 0 && *e != ' '; e++)
			;
		if(e - p >= sizeof val)
			return nil;
		memmove(val, p, e - p);
		val[e - p] = 0;
		return val;
	}
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

void
main(void)
{
	long *p, *ep;

	p = (long*)edata;
	ep = (long*)end;
	while(p < ep)
		*p++ = 0;

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

	serialputs("Inferno/arm64 virt\n", -1);

	uartconsole();
	archconsole();

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
	bootargsinit();
	{	/* the same options pc64 takes; see doc/multicore-plan.ms */
		char *p;

		if((p = getconf("*parallelvm")) != nil){
			extern int parallelvm;
			parallelvm = strtol(p, nil, 0);
		}
		if((p = getconf("*soak")) != nil)
			ksetenv("soak", p, 0);
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
	smpprobe();

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

/*
 * Smallest data-cache line in bytes, from CTR_EL0.DminLine (bits 19:16,
 * log2 of the line size in 4-byte words).  DC by VA must stride by the
 * minimum line present or it skips lines; on a big.LITTLE part the
 * clusters need not report the same geometry, which is exactly why the
 * minimum is the one to use.
 */
static usize
dlinesz(void)
{
	static usize ls;

	if(ls == 0)
		ls = 4UL << ((getctr() >> 16) & 0xf);
	return ls;
}

void
cacheflush(void *va, usize len)
{
	uintptr a, e, ls;

	ls = dlinesz();
	a = (uintptr)va & ~(ls - 1);
	e = (uintptr)va + len;
	for(; a < e; a += ls)
		dccvac(a);
	coherence();
}
