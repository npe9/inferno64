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

/*
 * The device tree.  QEMU's -M virt always generates one (hw/arm/boot.c
 * have_dtb() is true because the machine sets info->get_dtb), but on
 * the ELF -kernel path it neither passes the address in x0 nor writes
 * the tree at all unless the kernel image leaves the base of RAM free.
 * mem.h's KTZERO comment has the detail; the consequence here is that
 * the tree is found by its magic at PHYSDRAM when x0 is empty.
 */
uintptr virtiobase = VIRTIO0;
static int fdtfound;

void
fdtfind(void)
{
	extern void *dtbptr;
	extern void fdtinit(void*);
	extern int fdtvalid(void);
	extern int fdtreg(char*, uvlong*, uvlong*);
	extern int fdtregmin(char*, uvlong*, uvlong*);
	extern void ecamsetbase(uvlong);
	uvlong base, size;

	fdtinit(dtbptr);
	if(!fdtvalid())
		fdtinit((void*)PHYSDRAM);
	fdtfound = fdtvalid();
	if(!fdtfound)
		return;

	/*
	 * Drive what is already parameterised.  Each of these is a
	 * variable rather than an inline constant precisely so a board
	 * can set it at boot; a lookup that misses leaves the mem.h
	 * default in place.  The GIC, the PL011 and the PCI memory
	 * windows are still compiled-in constants used at many sites,
	 * so fdtreport() prints what the tree says about them beside
	 * what mem.h assumed, which is what would catch a machine whose
	 * layout differs.
	 */
	if(fdtregmin("virtio,mmio", &base, &size) && base != 0)
		virtiobase = (uintptr)base;	/* lowest slot; drivers scan up */
	if(fdtreg("pci-host-ecam-generic", &base, &size) && base != 0)
		ecamsetbase(base);
}

void
fdtreport(void)
{
	extern int fdtreg(char*, uvlong*, uvlong*);
	extern int fdtregmin(char*, uvlong*, uvlong*);
	extern int fdtmemory(uvlong*, uvlong*);
	uvlong base, size;

	if(!fdtfound){
		print("fdt: no device tree\n");
		return;
	}
	print("fdt: tree at %#p\n", (uintptr)PHYSDRAM);
	if(fdtmemory(&base, &size))
		print("fdt: memory @ %#llux size %#llux (mem.h PHYSDRAM %#p DRAMSIZE %#p)\n",
			base, size, (uintptr)PHYSDRAM, (uintptr)DRAMSIZE);
	if(fdtreg("arm,pl011", &base, &size))
		print("fdt: pl011 @ %#llux size %#llux (mem.h UART0 %#p)\n",
			base, size, (uintptr)UART0);
	if(fdtreg("arm,pl031", &base, &size))
		print("fdt: pl031 @ %#llux (mem.h RTC0 %#p)\n", base, (uintptr)RTC0);
	if(fdtreg("arm,cortex-a15-gic", &base, &size))
		print("fdt: gicv2 dist @ %#llux (mem.h GICD %#p GICC %#p)\n",
			base, (uintptr)GICD, (uintptr)GICC);
	else if(fdtreg("arm,gic-v3", &base, &size))
		print("fdt: gicv3 dist @ %#llux (mem.h GICD %#p GICR %#p)\n",
			base, (uintptr)GICD, (uintptr)GICR);
	if(fdtregmin("virtio,mmio", &base, &size))
		print("fdt: virtio-mmio @ %#llux size %#llux, using %#p (mem.h VIRTIO0 %#p)\n",
			base, size, virtiobase, (uintptr)VIRTIO0);
	if(fdtreg("pci-host-ecam-generic", &base, &size))
		print("fdt: pci ecam @ %#llux size %#llux (mem.h PCIECAM %#p PCIECAMSZ %#p)\n",
			base, size, (uintptr)PCIECAM, (uintptr)PCIECAMSZ);
	print("fdt: ok\n");
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
	/*
	 * Before everything, because the bases it sets are read by
	 * drivers that chandevreset() brings up and because confinit()
	 * is where memory sizing will go.  fdtfind() only reads memory
	 * -- no hardware, no allocation, no print -- and every lookup
	 * falls back to the mem.h constant, so a missing or unexpected
	 * tree cannot hang the board: it boots exactly as it did when
	 * it read no tree at all.  fdtreport() prints the findings
	 * later, once print() works.
	 */
	fdtfind();
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
	fdtreport();
	/*
	 * Before pciarchinit(), because the PCI scan is what reaches the
	 * drivers that ask for a vector, and a router set afterwards
	 * would be found nil by every one of them.
	 */
	gicv2minit();
	gicv2mreport();
	pciarchinit();
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
