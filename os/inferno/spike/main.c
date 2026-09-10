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
	m->cpuhz = 10000000;		/* spike CLINT timebase */
	m->delayloop = m->cpuhz/1000;
	memset(&active, 0, sizeof(active));
	active.machs[0] = 1;
}

static int fdtfound;

/*
 * QEMU's -M spike does hand the kernel a tree, and this board did not
 * read it.  The reset ROM at 0x1000 is six instructions:
 *
 *	auipc	t0, 0
 *	addi	a2, t0, 0x28
 *	csrr	a0, mhartid
 *	ld	a1, 0x20(t0)
 *	ld	t0, 0x18(t0)
 *	jr	t0
 *
 * with the kernel entry at 0x1018 and the DTB address at 0x1020, so
 * a1 holds the tree exactly the way it does on virt and sifiveu.
 * l.s now saves it.
 *
 * This runs before confinit(), because archconfinit() sizes memory
 * from the tree, and therefore long before the console: nothing here
 * can print, and everything it finds is reported later by
 * fdtreport().  A lookup miss leaves the constant in place, so a tree
 * that is absent or unrecognisable cannot stop a board that boots.
 */
void
fdtfind(void)
{
	extern void *dtbptr;
	extern void fdtinit(void*);
	extern int fdtvalid(void);
	extern int fdtu32(char*, u32int*);
	u32int hz;

	fdtinit(dtbptr);
	fdtfound = fdtvalid();
	if(!fdtfound)
		return;
	/*
	 * mtime counts at timebase-frequency, and clock.c divides
	 * m->cpuhz by HZ to program mtimecmp, so this is the one number
	 * in the tree the board acts on rather than merely checks.
	 * What can be shown is that it agrees: QEMU's -M spike reports
	 * 10MHz and machinit() had already guessed 10MHz, and the
	 * machine offers no way to make its CLINT run at another rate,
	 * so this path is demonstrated to agree and is not demonstrated
	 * to correct anything.
	 */
	if(fdtu32("timebase-frequency", &hz) && hz != 0){
		m->cpuhz = hz;
		m->delayloop = m->cpuhz/1000;
	}
}

/*
 * What the tree said against what mem.h compiles in.  The CLINT and
 * the HTIF are reported and not seeded: clock.c and htif.c reach
 * their registers through the constants at compile time, and the
 * console is up long before any of this could speak, so a board that
 * discovered its own console could not tell you it had discovered the
 * wrong one.  Reporting them still has the value of failing loudly if
 * a QEMU release ever moves them.
 */
static void
fdtreport(void)
{
	extern void *dtbptr;
	extern int fdtreg(char*, uvlong*, uvlong*);
	extern int fdtmemory(uvlong*, uvlong*);
	extern int fdtblob(uvlong*, uvlong*);
	extern int fdthas(char*);
	extern volatile uvlong tohost;
	uvlong base, size;
	int ok, nbank;

	if(!fdtfound){
		print("SPIKE-FDT-NONE\n");
		return;
	}
	ok = 1;
	print("fdt: dtb %#p\n", dtbptr);
	nbank = fdtmemory(&base, &size);
	if(nbank == 1)
		print("fdt: memory @ %#llux size %#llux (mem.h PHYSDRAM %#p DRAMSIZE %#ux)\n",
			base, size, (uintptr)PHYSDRAM, (uint)DRAMSIZE);
	else
		ok = 0;
	if(fdtreg("riscv,clint0", &base, &size) && base == CLINT)
		print("fdt: clint @ %#llux size %#llux (mem.h CLINT %#p)\n",
			base, size, (uintptr)CLINT);
	else
		ok = 0;
	/*
	 * Presence, not reg, and the reason is worth writing down.  QEMU
	 * gives the htif node a reg of 0x1000000 only when the kernel it
	 * boots has no tohost symbol in its ELF.  This one does --
	 * elf-htif-syms.py puts tohost and fromhost there after the link
	 * precisely so QEMU maps HTIF over the kernel's own two cells --
	 * so the node arrives with a compatible and nothing else, and
	 * asking it for a reg would report a broken tree.  mem.h's
	 * HTIF_TOHOST is not the address this board uses; &tohost is.
	 */
	if(fdthas("ucb,htif0"))
		print("fdt: htif node present, no reg (tohost %#p, mem.h HTIF_TOHOST %#p unused)\n",
			&tohost, (uintptr)HTIF_TOHOST);
	else
		ok = 0;
	if(fdtblob(&base, &size))
		print("fdt: blob @ %#llux size %#llux (top of mem %#p)\n",
			base, size, (uintptr)conf.topofmem);
	print("fdt: timebase %lud Hz\n", (ulong)m->cpuhz);
	/*
	 * The marker asserts agreement, not merely that nodes were
	 * found: a tree naming addresses this board cannot use would
	 * have satisfied a bare "found it" and told nobody anything.
	 */
	if(ok)
		print("SPIKE-FDT-OK\n");
	else
		print("SPIKE-FDT-FAIL\n");
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
	fdtfind();
	confinit();

	serialputs("Inferno/riscv64 spike\n", -1);

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
	fdtreport();
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
