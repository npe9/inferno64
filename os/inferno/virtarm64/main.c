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

/*
 * The boot loader's configuration, copied out of the loader's own
 * memory before anything can allocate over it.
 *
 * os/inferno/boot/efi puts the block at 0x48000000, 128M into DRAM,
 * because arm64 has no low memory to put it in the way a pc kernel's
 * CONFADDR does -- and that is inside the range xalloc() hands out.
 * So it is copied here, at the top of main(), after the bss clear and
 * before anything else runs.  Reading it later would be reading
 * whatever the allocator had since put there.
 *
 * x1 is not trusted.  The Linux arm64 boot protocol requires it to be
 * zero and QEMU's ELF -kernel path leaves it zero, but "probably zero"
 * is not a thing to copy 4K from, so the block has to look like a
 * configuration first: printable text, at least one assignment, and a
 * NUL inside the first 4K.
 */
static char bootconf[4096];

static void
confcopy(void)
{
	extern void *confptr;
	char *p;
	int i, eq;

	p = confptr;
	if(p == nil)
		return;
	eq = 0;
	for(i = 0; i < sizeof(bootconf)-1; i++){
		if(p[i] == 0)
			break;
		if(p[i] == '=')
			eq++;
		if(p[i] != '\n' && (p[i] < 0x20 || p[i] > 0x7e))
			return;		/* not text; x1 held something else */
	}
	if(i == sizeof(bootconf)-1 || eq == 0)
		return;			/* no terminator, or no name=value */
	memmove(bootconf, p, i);
	bootconf[i] = 0;
}

/*
 * One line of it, by name, with the name included in what is returned
 * the way the loader's own findconf() does.  nil when the loader
 * passed nothing or the name is not there.
 */
char*
bootconfline(char *name)
{
	char *p;
	int n;

	if(bootconf[0] == 0)
		return nil;
	n = strlen(name);
	for(p = bootconf; *p != 0; ){
		if(strncmp(p, name, n) == 0)
			return p + n;
		while(*p != 0 && *p != '\n')
			p++;
		while(*p == '\n')
			p++;
	}
	return nil;
}

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
	/*
	 * The fallback, and the switch that turns it off.
	 *
	 * QEMU writes its device tree at the bottom of DRAM and does not
	 * pass the address on the ELF -kernel path, so scanning for the
	 * magic there is how this board has always found its tree.  It
	 * is also why a UEFI boot with ACPI and no device tree still
	 * works: the kernel finds QEMU's tree anyway, and every check
	 * passes without a line of ACPI being read.
	 *
	 * A machine that is not QEMU has nothing at the bottom of DRAM.
	 * So *nofdtscan= in the loader's configuration suppresses the
	 * scan, and a board that boots with it set is a board that found
	 * its tree properly.  That is the only way an ACPI path can be
	 * shown to be doing anything at all; without it a completely
	 * broken one would look exactly like this.
	 */
	if(!fdtvalid() && bootconfline("*nofdtscan=") == nil)
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
	extern int fdtregn(char*, int, uvlong*, uvlong*);
	extern int fdtregmin(char*, uvlong*, uvlong*);
	extern int fdtmemory(uvlong*, uvlong*);
	uvlong base, size;

	/*
	 * What the loader passed, before what the tree says, because on a
	 * UEFI boot the first is how the second was found -- or was not.
	 * *acpi= is the RSDP, which is the pointer the tables a real
	 * SystemReady machine hands over are reached through; it is
	 * printed rather than used, because nothing reads them yet.
	 */
	if(bootconf[0] != 0){
		char *p;

		print("conf: %ld bytes from the loader\n", strlen(bootconf));
		if((p = bootconfline("*acpi=")) != nil){
			int n;

			for(n = 0; p[n] != 0 && p[n] != '\n'; n++)
				;
			print("conf: rsdp %.*s, ACPI-RSDP-OK\n", n, p);
		}
		if(bootconfline("*nofdtscan=") != nil)
			print("conf: the device-tree scan at PHYSDRAM is off\n");
		/*
		 * What the firmware's memory map said, and what mem.h
		 * would have said instead.  Printed together because the
		 * whole point is that they differ: on a 512MB machine
		 * with no device tree this board used to claim mem.h's
		 * 256MB and lose half the memory, and on a smaller one it
		 * would have claimed memory that is not there.
		 */
		if((p = bootconfline("*memtop=")) != nil){
			int n;

			for(n = 0; p[n] != 0 && p[n] != '\n'; n++)
				;
			print("conf: memtop %.*s from the loader"
				" (mem.h would say %#p)\n",
				n, p, (uintptr)(PHYSDRAM + DRAMSIZE));
		}
	}
	if(!fdtfound){
		print("fdt: no device tree\n");
		return;
	}
	print("fdt: tree at %#p\n", (uintptr)PHYSDRAM);
	if(fdtmemory(&base, &size))
		print("fdt: memory @ %#llux size %#llux (mem.h PHYSDRAM %#p DRAMSIZE %#p)\n",
			base, size, (uintptr)PHYSDRAM, (uintptr)DRAMSIZE);
	/*
	 * Without mem.h beside them, for the reason gicreport() carries:
	 * uartreport() and rtcreport() say which source was used, and a
	 * comparison against a constant that agrees is what let these be
	 * discovered and ignored.
	 */
	if(fdtreg("arm,pl011", &base, &size))
		print("fdt: pl011 @ %#llux size %#llux\n", base, size);
	if(fdtreg("arm,pl031", &base, &size))
		print("fdt: pl031 @ %#llux\n", base);
	/*
	 * The distributor and whatever the node's second reg entry is --
	 * the MMIO cpu interface on a v2, the redistributor range on a
	 * v3.  Printed without mem.h beside them: gicreport() says which
	 * source the GIC code latched, which is the line that means
	 * something, and a comparison against a constant that agrees is
	 * what let these be discovered and ignored.
	 */
	if(fdtregn("arm,cortex-a15-gic", 0, &base, &size)){
		uvlong c;

		c = 0;
		fdtregn("arm,cortex-a15-gic", 1, &c, nil);
		print("fdt: gicv2 dist @ %#llux cpuif @ %#llux\n", base, c);
	} else if(fdtregn("arm,gic-v3", 0, &base, &size)){
		uvlong r;

		r = 0;
		fdtregn("arm,gic-v3", 1, &r, nil);
		print("fdt: gicv3 dist @ %#llux redist @ %#llux\n", base, r);
	}
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
	 * Before fdtfind(), which reads it, and before anything that
	 * allocates: the block it copies from is in memory this kernel
	 * is about to hand out.
	 */
	confcopy();
	/*
	 * And the tables, if the loader passed an RSDP.  Same contract as
	 * fdtfind() below and for the same reason: reads memory, touches
	 * no hardware, allocates nothing, prints nothing, and every
	 * lookup falls back.  acpireport() prints later.
	 */
	acpifind();
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
	/*
	 * Before the first serialputs() below, which is the first output
	 * this kernel makes: a console discovered after it would print
	 * the banner through mem.h's address and the rest through the
	 * real one, and on a machine where those differ the banner is
	 * the part that goes missing.
	 */
	uartdiscover();
	rtcdiscover();
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
	acpireport();
	fdtreport();
	gicreport();
	uartreport();
	rtcreport();
	/*
	 * Before pciarchinit(), because the PCI scan is what reaches the
	 * drivers that ask for a vector, and a router set afterwards
	 * would be found nil by every one of them.
	 */
	/*
	 * One or the other, never both: QEMU's create_gic() gives a
	 * gic-version=2 machine a v2m frame and a gic-version=3 machine
	 * an ITS, and each init returns silently when its node is not in
	 * the tree.  Whichever finds itself sets pcimsirouter, and the
	 * order between them does not matter for that reason.
	 *
	 * The report comes after both, because the only board that has
	 * neither is the one that should say so, and gicv2mreport()
	 * cannot know that until the ITS has had its look.  Run before
	 * gicv3itsinit(), it told a gic-version=3 machine its interrupts
	 * were intx a line before the ITS claimed them.
	 */
	gicv2minit();
	gicv3itsinit();
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
	p->sched.sp = ((uintptr)p->kstack+KSTACK-16) & ~(uintptr)15;	/* SP must be 16-aligned (SCTLR_EL1.SA); malloc gives 8 */
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
	p->sched.sp = ((uintptr)p->kstack+KSTACK-16) & ~(uintptr)15;	/* SP must be 16-aligned (SCTLR_EL1.SA); malloc gives 8 */
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
