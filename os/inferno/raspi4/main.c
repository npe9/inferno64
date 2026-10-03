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
 * segflush(): make instructions written as data visible to the fetcher.
 *
 * THIS IS A STUB AND DOES NOTHING, which was not written down anywhere
 * until now.  It cleans no data cache and invalidates no instruction
 * cache, so every caller that writes instructions is relying on a
 * promise this does not keep:
 *
 *	devboot.c	four calls, after loading a kernel image and
 *			before jumping to it
 *	devdbg.c	after writing a process's text
 *	libinterp/comp-aarch64.c
 *			three calls, after the JIT emits code
 *
 * The JIT one is not reachable here today -- this board's config sets
 * cflag = 0, so no Dis is compiled -- but the devboot path is live, and
 * booting a kernel whose instructions may still be sitting in the data
 * cache is exactly the failure this function exists to prevent.
 *
 * raspi3b's is three lines (cacheflush(p, l); cacheiinv(); return 1;)
 * and this board has both of those routines.  It is NOT filled in here
 * because there is no Pi 4 on this desk to test it on, and a cache
 * change that cannot be booted is not an improvement -- it is an
 * untested behavioural change to a port nobody can check.  Written down
 * instead, so whoever has the hardware sees it immediately.
 *
 * And while reading it: cacheiinv() in this board's l.s uses IC IALLU,
 * which invalidates the LOCAL processor's I-cache only.  raspi3b had the
 * same instruction and it was the cause of an intermittent wedge there
 * once the JIT and four cores were both in play -- a core fetching stale
 * instructions and trapping with ESR exception class 0 at a heap pc.
 * See b461ec5f1.  Latent here while cflag is 0 and nothing starts the
 * secondary processors, and wrong the moment either changes.
 */
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

	{	/*
		 * The hardware RNG, which on this board is a Broadcom
		 * RNG200 and not the BCM2835 block raspi3b drives.  It
		 * needed a driver rather than a mapping -- different
		 * registers, and pointing rngbcm.c at it was an external
		 * abort, esr 0x96000050 at the first status read, which
		 * is where this port stopped once the page tables were
		 * fixed.  QEMU modelled the block for no machine at all,
		 * so it needed a model too: tools/qemu-patches 0023.
		 */
		extern void rng200init(void);
		rng200init();
	}

	{	/* power management: the watchdog, and the reset it drives */
		extern void pminit(void);
		pminit();
		{
			/*
			 * Nine of the Pi 3B's peripherals were not mapped on
			 * this machine, and the boundary was a QEMU one
			 * rather than a Broadcom one.
			 * hw/arm/bcm2835_peripherals.c has two realize
			 * functions: a common one every BCM SoC runs, and
			 * bcm2835_peripherals_realize(), which only the Pi
			 * 2/3 machines run.  The Pi 4's realize calls the
			 * common one, so everything the Pi-3-specific realize
			 * mapped was simply absent: the ARM timer, the BSC
			 * slave, I2S, MPHI, PWM, the RNG, SMI and the thermal
			 * sensor.  A BCM2711 has all of them in silicon; the
			 * model was less than the part.
			 *
			 * Patch 0021 moves the five that a BCM2711 carries at
			 * the same offsets with the same programming model --
			 * PWM, I2S, SMI, the BSC slave and the ARM timer,
			 * plus the MPHI mapping -- into the common realize,
			 * so they are here now and driven below.
			 *
			 * Two needed a driver and a model rather than a
			 * mapping, because on this part they are different
			 * blocks: the RNG is a Broadcom RNG200 (rng200bcm.c,
			 * patch 0023) and the temperature sensor is in the
			 * AVS monitor, at an address outside this window
			 * entirely (thermavs.c, patch 0024).  Moving
			 * bcm2835_thermal here would have asserted something
			 * untrue about the hardware to gain a marker.
			 *
			 * The ARM timer's interrupt is tested too, now that
			 * there is a line for it to arrive on: QEMU wired
			 * the timer to the legacy controller for every SoC
			 * and never wired that controller to the GIC, so on
			 * this machine the interrupt died in the model.
			 * Patch 0025 connects it to the GIC at SPI 32, a
			 * number derived rather than read -- armtmrbcm.c and
			 * doc/raspi4-plan.ms both say from what.
			 *
			 * None of this failed quietly, which is what made it
			 * cheap: an unmapped offset in this window is a
			 * synchronous external abort with the address in FAR,
			 * so each named itself in a trap dump.
			 */
			extern void pwminit(void);
			extern void systmrinit(void);
			extern void thermavsinit(void);
			pwminit();
			systmrinit();
			thermavsinit();
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
	 * at all -- see armtmrintrcheck().  The block itself was one of
	 * the nine offsets bcm2838 did not map, and its line was wired
	 * to a legacy controller nothing dispatched; patch 0021 mapped
	 * the block and 0025 wired the line, so this check is back.
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

/*
 * PADDR() is this.  Returning ulong truncated a 64-bit pointer to 32 bits,
 * and the callers feed 64-bit fields: xhole() in ../port/xalloc.c takes
 * uintptr and its Hole.addr is uintptr, and the virtio drivers put the result
 * straight into a DMA descriptor address.  Below 4GB that is invisible; above
 * it, the allocator records the wrong hole and a device DMAs to the wrong
 * physical page, with nothing reported anywhere.  doc/open-issues-plan.ms H4.
 */
uintptr
va2pa(void *v)
{
	return (uintptr)v;
}
