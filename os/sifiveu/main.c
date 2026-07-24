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

	xinit();
	poolinit();
	poolsizeinit();
	trapinit();
	mmuinit();
	clockinit();
	quotefmtinstall();	/* Limbo sys->sprint %q / C snprint %q */
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
