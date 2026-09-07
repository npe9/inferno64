#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "io.h"
#include "version.h"

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
volatile uintptr	secsp;
volatile uintptr	secalive;
volatile uintptr	seccount;

void
secmain(void)
{
	secalive = 5;	/* reached C */
	for(;;)
		seccount++;
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
	r = psci(0xc4000003ULL, 1, (uintptr)_secondary, 0);
	print("smp: PSCI CPU_ON cpu1 entry %#llux -> %lld\n", (uvlong)(uintptr)_secondary, r);
	if(r != 0)
		return;
	for(i = 0; i < 100 && secalive == 0; i++)
		delay(10);
	print("smp: cpu1 reached stage %llud, sp %#llux\n", (uvlong)secalive, (uvlong)secsp);
	/*
	 * alive 1 = reached the entry, 2 = stack up, 3 = running C.
	 * seccount is incremented by cpu1 in a loop, so two reads a
	 * moment apart say whether it is still going.
	 */
	c0 = seccount;
	delay(50);
	print("smp: cpu1 alive %llud, seccount %llud -> %llud (%s)\n",
		(uvlong)secalive, (uvlong)c0, (uvlong)seccount,
		seccount != c0 ? "running" : "stopped");
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
