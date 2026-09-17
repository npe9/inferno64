#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "io.h"
#include "version.h"

extern int distrack;		/* libinterp/heap.c: the Dis heap watchdog */

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
 * What the last boot left in the crumb record at 0x20000000 (l.s
 * crumbentry, trap.c): the last exception taken, and any exception on
 * a wild SP or label gotolabel refused.  RAM there survives a reset
 * that is not a power cycle, so after a hang and a reset this says
 * where the kernel was.  Printed before anything can overwrite it.
 */
static void
crumbdump(void)
{
	volatile uvlong *c = (volatile uvlong*)0x20000000;
	int i;

	if(c[0] != 0x43524d42ULL)	/* power-on contents, not a record */
		goto clear;
	serialputs("CRUMB previous boot: exceptions ", -1);
	serialputdec(c[1]);
	serialputs(", last type ", -1);
	serialputdec(c[7]);
	serialputreg("esr", c[2], 8);
	serialputreg("elr", c[3], 16);
	serialputreg("spsr", c[5], 3);
	serialputreg("sp", c[6], 16);
	serialputs("\n", -1);
	if(c[147] != 0){
		serialputs("CRUMB wildsp elr", -1);
		serialputreg("", c[144], 16);
		serialputreg("spsr", c[145], 3);
		serialputreg("esr", c[146], 8);
		serialputreg("sp", c[147], 16);
		serialputreg("lr", c[148], 16);
		serialputs("\n", -1);
	}
	if(c[153] != 0){
		serialputs("CRUMB badlabel", -1);
		serialputreg("", c[152], 16);
		serialputreg("sp", c[153], 16);
		serialputreg("pc", c[154], 16);
		serialputreg("caller", c[155], 16);
		serialputs("\n", -1);
	}
clear:
	for(i = 0; i < 160; i++)
		c[i] = 0;
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

	uartconsole();
	archconsole();

	/*
	 * xinit() takes xlists with _tas().  On real A53 hardware an
	 * LDXR/STXR lock is not sound while the MMU is off and RAM has no
	 * Normal-memory translation attributes; QEMU happens to accept it.
	 * Establish the identity map before the first kernel lock.
	 */
	mmuinit();
	xinit();
	poolinit();
	poolsizeinit();
	trapinit();
	clockinit();
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

	{	/* VideoCore mailbox probe: verify the property channel */
		extern void mailboxinit(void);
		mailboxinit();
	}

	{	/* hardware RNG: replaces the software LCG behind /dev/random */
		extern void rnginit(void);
		rnginit();
	}

	{	/* power management: the watchdog, and the reset it drives */
		extern void pminit(void);
		pminit();
		{
			extern void pwminit(void);
			extern void systmrinit(void);
			extern void therminit(void);
			pwminit();
			systmrinit();
			therminit();
			{
				extern void otpinit(void);
				extern void dmainit(void);
				otpinit();
				dmainit();
				{
					extern void auxinit(void);
					extern void armtmrinit(void);
					extern void i2sinit(void);
					extern void auxspiinit(void);
					extern void smiinit(void);
					extern void bscslinit(void);
					auxinit();
					armtmrinit();
					i2sinit();
					auxspiinit();
					smiinit();
					bscslinit();
				}
			}
		}
#ifdef SDIOTEST
		{
			extern void sdiocheck(void);
			sdiocheck();
		}
#endif
	}

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

	clockcheckboot();

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
	/*
	 * Interrupts are live from here (spllo() at the top of init0),
	 * which is the earliest the ARM timer's delivery can be tested
	 * at all -- see armtmrintrcheck().
	 */
	{
		extern void armtmrintrcheck(void);
		armtmrintrcheck();
	}
	/*
	 * The polled console path, which panic() and iprint() use and
	 * which no other check reaches.
	 */
	{
		extern void uartputccheck(void);
		uartputccheck();
	}
	/*
	 * This board's ethernet driver, its file server and everything
	 * above them are Limbo, so the Dis interpreter's per-instruction
	 * heap watchdog is charged to every frame that arrives.  Measured
	 * under a hundred frames a second: with it on, the kernel came
	 * back for the next frame every 60ms and the server handed 7
	 * frames straight to a waiting reader; with it off, every 8ms and
	 * 1222.  The Pi needs the machine more than it needs the
	 * instrument, which stays on by default everywhere else.  Set it
	 * back to 1 here to watch a heap corruption on this board.
	 */
	distrack = 0;
	disinit("/osinit.dis");
}

static uintptr	kstacktop(Proc*);

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
	p->sched.sp = kstacktop(p);
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

/*
 * The initial kernel SP of a process, rounded down to 16 bytes.  malloc
 * only promises 8-byte alignment, and SCTLR_EL1.SA makes the A53 take an
 * SP-alignment fault on any stack access through an SP that is not a
 * multiple of 16 -- after which the exception entry, on the same SP,
 * faults again, forever, with every exception masked.  A process whose
 * kstack happened to come back from malloc at ...8 silenced the Pi a
 * few seconds into boot, depending on allocation order; QEMU does not
 * check SP alignment, so it booted every time there.
 */
static uintptr
kstacktop(Proc *p)
{
	return ((uintptr)p->kstack+KSTACK-16) & ~(uintptr)15;
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
	p->sched.sp = kstacktop(p);
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
