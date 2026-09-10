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

	/*
	 * LLP64: ulong is 32-bit.  nb*pcnt overflows above ~71MiB for
	 * pcnt=60 (was silently wrapping image pool to ~30MiB at 128/256MiB).
	 */
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
	/* uvlong: conf.npage*pcnt*BY2PG overflows ulong at 256MiB */
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
	m->cpuhz = 1000000;		/* sifive_u CLINT timebase */
	m->delayloop = m->cpuhz/1000;
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

	serialputs("Inferno/riscv64 sifive_u\n", -1);

	/* console early so print works before printinit */
	uartconsole();
	archconsole();

	/*
	 * Read the device tree before trapinit(), so plicinit() uses the
	 * PLIC base the DTB reports rather than the compiled-in constant,
	 * and before chandevreset() so the GEM driver takes its base from
	 * the same place.  fdtinit() only parses memory - it touches no
	 * hardware - and a lookup miss leaves each variable at its
	 * constant, so this cannot hang a board that boots today.
	 */
	{
		extern void *dtbptr;
		extern void fdtinit(void*);
		extern int fdtreg(char*, uvlong*, uvlong*);
		extern uintptr plicbase, gembase;
		uvlong base, size;

		fdtinit(dtbptr);
		if(fdtreg("riscv,plic0", &base, &size) && base != 0)
			plicbase = (uintptr)base;
		if(fdtreg("sifive,fu540-c000-gem", &base, &size) && base != 0)
			gembase = (uintptr)base;
	}

	xinit();
	poolinit();
	poolsizeinit();
	trapinit();
	mmuinit();
	clockinit();
	quotefmtinstall();	/* Limbo sys->sprint %q / C snprint %q */
	printinit();
	{	/* SPI probe: needs the console up to report the JEDEC ids */
		extern void spiinit(void);
		spiinit();
	}


	procinit();
	links();
	screeninit();
	chandevreset();
	uartconsolesetup();

	eve = strdup("inferno");
	kbdinit();

	print("\nInferno %s\n", VERSION);
	print("conf %s (%lud) jit %d\n\n", conffile, kerndate, cflag);
	/*
	 * What the device tree said, against what mem.h compiles in.  The
	 * UART and the CLINT are reported and not seeded on purpose: the
	 * console is up long before any of this runs and is how a wrong
	 * address would be seen at all, and clockinit() has already used
	 * the CLINT by the time a DTB parse could speak.  A board that
	 * discovers its own console cannot tell you when it discovers the
	 * wrong one.
	 */
	{
		extern void *dtbptr;
		extern uintptr plicbase, gembase;
		extern int fdtreg(char*, uvlong*, uvlong*);
		extern int fdtvalid(void);
		uvlong base, size;
		int ok;

		print("fdt: dtb %#p\n", dtbptr);
		ok = 1;
		if(fdtreg("sifive,uart0", &base, &size))
			print("fdt: uart @ %#llux size %#llux (mem.h UART0 %#p)\n",
				base, size, (uintptr)UART0);
		else
			ok = 0;
		if(fdtreg("riscv,clint0", &base, &size))
			print("fdt: clint @ %#llux size %#llux (mem.h CLINT %#p)\n",
				base, size, (uintptr)CLINT);
		else
			ok = 0;
		print("fdt: plic base %#p (mem.h PLIC %#p)\n", plicbase, (uintptr)PLIC);
		print("fdt: gem base %#p (mem.h GEM0 %#p)\n", gembase, (uintptr)GEM0);
		/*
		 * The marker asserts agreement, not merely that a node was
		 * found: a DTB naming an address the board cannot use would
		 * still have satisfied a bare "found it".
		 */
		if(!fdtvalid())
			print("SIFIVEU-FDT-NONE\n");
		else if(ok && plicbase == PLIC && gembase == GEM0)
			print("SIFIVEU-FDT-OK\n");
		else
			print("SIFIVEU-FDT-FAIL plic %#p gem %#p\n", plicbase, gembase);
	}
	{
		char abibuf[64];

		snprint(abibuf, sizeof abibuf, "%d %d %d %d", 11, 22, 33, 44);
		if(strcmp(abibuf, "11 22 33 44") == 0)
			print("SNPRINT-ABI-OK\n");
		else
			print("SNPRINT-ABI-FAIL %s\n", abibuf);
	}
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

	/* keep 9front-style fields in sync */
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

/* getfcr/setfcr/getfsr/setfsr: libkern/getfcr-riscv64.s
 * FPcontrol/FPstatus: libmath/FPcontrol-Inferno.c */

void
fpinit(void)
{
}

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
