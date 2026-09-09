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

	serialputs("Inferno/arm64 raspi4\n", -1);

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

	/*
	 * No hardware RNG on this board, and this is not an omission.
	 *
	 * A BCM2711 does not have the BCM2835 RNG.  It has a Broadcom
	 * RNG200 at the same offset, which is a different block with
	 * different registers, and QEMU models neither for this machine:
	 * hw/arm/bcm2835_peripherals.c maps TYPE_BCM2835_RNG from
	 * bcm2835_peripherals_realize(), the Pi-3-specific realize, and
	 * bcm2838_peripherals_realize() calls only the common one.  So
	 * 0xfe104000 answers nothing.
	 *
	 * Driving the raspi3b driver here is not a near-miss that reads
	 * zeroes; it is a synchronous external abort, esr 0x96000050 at
	 * the first status read, which is where this port stopped after
	 * the page tables were fixed.  /dev/random falls back to the
	 * software generator until an RNG200 driver exists.
	 */

	{	/* power management: the watchdog, and the reset it drives */
		extern void pminit(void);
		pminit();
		{
			/*
			 * Nine of the Pi 3B's peripherals are not mapped on
			 * this machine, and the boundary is a QEMU one rather
			 * than a Broadcom one.  hw/arm/bcm2835_peripherals.c
			 * has two realize functions: a common one every BCM
			 * SoC runs, and bcm2835_peripherals_realize(), which
			 * only the Pi 2/3 machines run.  The Pi 4's
			 * bcm2838_peripherals_realize() calls the common one
			 * and adds emmc2 and its own GPIO, so everything the
			 * Pi-3-specific realize maps is simply absent here:
			 * the ARM timer, the BSC slave, I2S, MPHI, PWM, the
			 * RNG, SMI and the thermal sensor.
			 *
			 * A BCM2711 has all of those in silicon.  This is
			 * the model being less than the part, not the part
			 * being less than the Pi 3.  Six of the eight are
			 * models written for this port (tools/qemu-patches
			 * 0007, 0009, 0011, 0014, 0015 and the thermal
			 * sensor), and the work to do is to map them for the
			 * Pi 4 as well rather than to delete their drivers.
			 * They are left out here so the board boots and the
			 * rest can be brought up; nothing about them is
			 * wrong.
			 *
			 * The failure is not quiet if one is driven anyway:
			 * a read of an unmapped offset in this window is a
			 * synchronous external abort, esr 0x96000010, which
			 * is how each was found.
			 *
			 * Still mapped and still driven: the system timer,
			 * OTP, DMA, AUX and its SPI masters, all of which
			 * the common realize carries.
			 */
			extern void systmrinit(void);
			systmrinit();
			{
				extern void otpinit(void);
				extern void dmainit(void);
				otpinit();
				dmainit();
				{
					extern void auxinit(void);
					extern void auxspiinit(void);
					auxinit();
					auxspiinit();
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
