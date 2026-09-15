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

/*
 * What the last boot left at 0x20000000 (l.s crumbentry, clockintr):
 * the last exception taken and the last tick, printed before anything
 * overwrites them.  "boots" counts starts, so a value that did not
 * survive the reset shows as 1.
 */
static void
crumbdump(void)
{
	volatile uvlong *c = (volatile uvlong*)0x20000000;

	c[12]++;
	serialputs("CRUMB boots ", -1);
	serialputdec(c[12]);
	if(c[0] == 0x43524d42ULL){
		serialputs(" last exception: count ", -1);
		serialputdec(c[1]);
		serialputreg("type", c[7], 1);
		serialputreg("esr", c[2], 8);
		serialputreg("elr", c[3], 16);
		serialputreg("far", c[4], 16);
		serialputreg("spsr", c[5], 3);
		serialputreg("sp", c[6], 16);
		serialputs(" last tick ", -1);
		serialputdec(c[10]);
		serialputreg("pc", c[11], 16);
		serialputs("\nCRUMB step ", -1);
		serialputdec(c[17]);
		serialputreg("ureg", c[18], 8);
		serialputreg("kstack", c[19], 8);
		serialputreg("pid", c[20], 4);
		serialputreg("splpc", c[21], 8);
		serialputs("\nCRUMB in-handler irq ", -1);
		if(c[14] == ~0ULL)
			serialputs("none", -1);
		else
			serialputdec(c[14]);
		serialputs(" returns ", -1);
		serialputdec(c[15]);
		serialputs(" irqcounts", -1);
		{
			int i;
			for(i = 0; i < 64; i++)
				if(c[40+i] != 0 && c[40+i] < 100000000){
					serialputs(" ", 1);
					serialputdec(i);
					serialputs(":", 1);
					serialputdec(c[40+i]);
				}
		}
		serialputs("\nCRUMB ring (oldest first, type irq pc):", -1);
		{
			int i;
			uvlong e, n;
			n = c[16];
			for(i = 0; i < 16; i++){
				e = c[24 + (n+i)%16];
				if(e == 0)
					continue;
				serialputreg("", e>>56, 1);
				serialputreg("", (e>>48)&0xff, 2);
				serialputreg("", e & 0xffffffffffffULL, 8);
			}
		}
	}
	serialputs("\n", -1);
	c[0] = 0;
	c[1] = 0;
	{
		int i;
		c[14] = ~0ULL;
		c[15] = 0;
		c[16] = 0;
		for(i = 24; i < 104; i++)
			c[i] = 0;
	}
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

	/*
	 * The build's date stamp on the first line, so a serial log says
	 * which image the Pi actually booted -- a stale kernel8.img on the
	 * card looks exactly like a failed fix.  Not snprint: the first use
	 * of a format verb runs fmtinstall(), which takes a spinlock, and an
	 * LDXR/STXR lock before mmuinit() hangs a real Cortex-A53 (QEMU lets
	 * it through).  Doing that here silenced two boots entirely.
	 */
	serialputs("Inferno/arm64 raspi3b build ", -1);
	serialputdec(kerndate);
	serialputs("\n", -1);
	crumbdump();

	uartrxprobe("fw");
	uartconsole();
	serialputs("PL011-OK\n", -1);
	uartrxprobe("uart");
	archconsole();

	/*
	 * xinit() takes xlists with _tas().  On real A53 hardware an
	 * LDXR/STXR lock is not sound while the MMU is off and RAM has no
	 * Normal-memory translation attributes; QEMU happens to accept it.
	 * Establish the identity map before the first kernel lock.
	 */
	mmuinit();
	serialputs("MMU-OK\n", -1);
	uartrxprobe("mmu");
	xinit();
	poolinit();
	poolsizeinit();
	trapinit();
	clockinit();
	uartrxprobe("clock");
	{	/* seed wall-clock from the PL031 RTC (calendar time) */
		extern vlong rtctime(void);
		vlong t = rtctime();
		if(t > 0)
			todset(t, 0, 0);
	}
	quotefmtinstall();
	printinit();

	{	/* I2C probe: needs the console up to report the round trip */
		extern void i2cinit(void);
		i2cinit();
	}

	{	/* SPI0 probe: read the JEDEC id of any attached serial flash */
		extern void spiinit(void);
		spiinit();
	}

	{	/* GPIO probe: drive a pin and read its level back */
		extern void gpioinit(void);
		gpioinit();
	}
	uartrxprobe("gpio");

	{	/* VideoCore mailbox probe: verify the property channel */
		extern void mailboxinit(void);
		mailboxinit();
	}
	uartrxprobe("mbox");

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
	uartrxprobe("screen");
	chandevreset();
	uartconsolesetup();
	uartrxprobe("devreset");

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

	clockcheckboot();
	tkmark("pre-probe");
	uartrxprobe("init0");
	tkmark("post-probe");
	{
		extern void fiqwatchinit(void);
		fiqwatchinit();
	}
	tkmark("post-fiqarm");

	/*
	 * Publish the board MAC the firmware knows (mailbox.c) as
	 * /env/ethaddr so the Limbo USB ethernet driver (etherusb) can
	 * give the LAN9514, which has no EEPROM on the Pi, its address.
	 */
	if(waserror() == 0){
		extern int mboxgetmac(uchar*);
		uchar mac[6];
		char buf[32];

		if(mboxgetmac(mac) == 0){
			snprint(buf, sizeof buf, "%2.2ux%2.2ux%2.2ux%2.2ux%2.2ux%2.2ux",
				mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
			ksetenv("ethaddr", buf, 0);
			print("MBOX ethaddr %s\n", buf);
		}else
			print("MBOX no board mac\n");
		poperror();
	}
	tkmark("pre-disinit");
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
