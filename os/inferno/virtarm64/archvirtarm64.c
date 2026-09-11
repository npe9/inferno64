#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

void
archreset(void)
{
}

/*
 * The PL031 RTC's data register (offset 0) is a 32-bit count of seconds
 * since the epoch.  main() seeds the time-of-day clock from it, scaled
 * to nanoseconds, so wall time is calendar-correct rather than relative
 * to boot.
 */
vlong
rtctime(void)
{
	u32int sec;

	sec = *(volatile u32int*)(uintptr)(RTC0 + 0x00);	/* PL031 DR */
	return (vlong)sec * 1000000000LL;
}

void
pciarchinit(void)
{
	extern void pciinit(void);
	pciinit();
}

void
archconfinit(void)
{
	/*
	 * The tree, when there is one, rather than DRAMSIZE.  main.c's
	 * fdtfind() runs before confinit() for exactly this.  QEMU's
	 * -M virt puts all of -m in one bank at PHYSDRAM, and
	 * fdtmemory() totals every bank it finds, so on -m 1G this is
	 * 0x40000000 where DRAMSIZE would have said 0x10000000 and
	 * three quarters of the machine's memory would have gone
	 * unused.
	 *
	 * Two guards.  fdtmemory() returns the number of banks it
	 * summed, and only one bank makes base+size a contiguous
	 * extent; two would put the hole between them into the pool.
	 * Every -M virt tree from -m 256 to -m 16G has a single
	 * memory@40000000, checked with -machine dumpdtb, so this is
	 * the guard staying honest about an assumption rather than a
	 * case seen here.  And the base must be PHYSDRAM, because
	 * everything on this board is identity-mapped from there and
	 * confinit() computes npage0 from one range.
	 *
	 * There is deliberately no floor and no ceiling.  A floor was
	 * here -- the tree had to report at least DRAMSIZE -- and it
	 * was wrong in the dangerous direction: at -m 64M the tree said
	 * 0x4000000, the floor rejected it, and the board kept
	 * conf.topofmem at 0x50000000 with real memory ending at
	 * 0x44000000.  The xalloc line read "403cd000 50000000
	 * 264450048": 252MB claimed on a 64MB machine, 192MB of it
	 * addresses -M virt leaves unassigned.  Trusting a tree that
	 * reports less than expected wastes nothing and asserts
	 * nothing; disbelieving it hands out memory that is not there.
	 * No ceiling either: conf.ialloc is a ulong and this board
	 * would need 32GB of RAM before main_pool_pcnt of it overflowed
	 * one.
	 */
	conf.topofmem = PHYSDRAM + DRAMSIZE;
	{
		extern int fdtvalid(void);
		extern int fdtmemory(uvlong*, uvlong*);
		extern char *bootconfline(char*);
		uvlong base, size, top;
		char *p;

		if(fdtvalid() && fdtmemory(&base, &size) == 1
		&& base == (uvlong)PHYSDRAM)
			conf.topofmem = PHYSDRAM + (uintptr)size;
		else if((p = bootconfline("*memtop=")) != nil){
			/*
			 * No tree, so the boot loader's own reading of the
			 * firmware's memory map is the only authority left
			 * -- and it is the authority a SystemReady machine
			 * has rather than a fallback for one that does not.
			 * Without it this board takes mem.h's DRAMSIZE and
			 * gets it wrong in both directions: 256MB claimed
			 * on a 512MB machine wastes half of it, and the
			 * same 256MB claimed on a 128MB machine hands out
			 * addresses that are not there.
			 *
			 * The same two rules the tree gets: the top has to
			 * be above PHYSDRAM to mean anything, and there is
			 * no floor -- a firmware that reports less than
			 * DRAMSIZE is describing a smaller machine, and
			 * disbelieving it is the dangerous direction.
			 */
			top = strtoull(p, nil, 16);
			if(top > (uvlong)PHYSDRAM)
				conf.topofmem = (uintptr)top;
		}
	}
	conf.cpuspeed = 100000000;	/* refined once cntfrq() is read, see clockinit */
}

void
archconsole(void)
{
	/* uartconsole already set consuart / serwrite */
}

void
archreboot(void)
{
	/* PSCI SYSTEM_RESET (0x84000009); QEMU restarts the machine */
	psci(0x84000009ULL, 0, 0, 0);
	for(;;)
		idle();
}

void
archshutdown(void)
{
	/* PSCI SYSTEM_OFF (0x84000008); QEMU powers the machine off */
	psci(0x84000008ULL, 0, 0, 0);
}

void
kbdinit(void)
{
}

void
idlehands(void)
{
	idle();
	clockpoll();
}

void
delay(int ms)
{
	uvlong end;

	if(ms <= 0)
		return;
	end = fastticks(nil) + (uvlong)ms * (m->cpuhz / 1000);
	while(fastticks(nil) < end)
		clockpoll();
}

void
microdelay(int us)
{
	int i, n;

	n = (m->delayloop * us) / 1000;
	if(n <= 0)
		n = 1;
	for(i = 0; i < n; i++)
		;
	if(us >= 100)
		clockpoll();
}

int
cmpswap(s32 *addr, s32 old, s32 new)
{
	int s, r;

	s = splhi();
	if(*addr == old){
		*addr = new;
		r = 1;
	}else
		r = 0;
	splx(s);
	return r;
}

/*
 * interp.h's AINC/ADEC (libinterp's Dis reference-counting primitives)
 * -- spl-masked, same uniprocessor assumption cmpswap above already
 * makes (MAXMACH is 1 on this board).  Nothing in os/inferno provides
 * these for the "arm" (5c) objtype yet; every other board either
 * never actually links a caller of them or has its own equivalent
 * this port didn't inherit.
 */
int
ainc(int *addr)
{
	int s, r;

	s = splhi();
	r = ++*addr;
	splx(s);
	return r;
}

int
adec(int *addr)
{
	int s, r;

	s = splhi();
	r = --*addr;
	splx(s);
	return r;
}

long
archkprofmicrosecondspertick(void)
{
	return 1000000 / HZ;
}

void
archkprofenable(int on)
{
	USED(on);
}
