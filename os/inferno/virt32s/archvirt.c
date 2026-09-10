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
 * The goldfish RTC is a 64-bit nanosecond-since-epoch counter: reading
 * TIME_LOW latches TIME_HIGH, so read low then high.  main() seeds the
 * time-of-day clock with this so wall time is calendar-correct.
 */
vlong
rtctime(void)
{
	u32int lo, hi;

	lo = *(volatile u32int*)(uintptr)(RTC0 + 0x00);
	hi = *(volatile u32int*)(uintptr)(RTC0 + 0x04);
	return (vlong)(((uvlong)hi << 32) | lo);
}

void
pciarchinit(void)
{
	/* no PCI in this board's first-boot config -- see the virt32
	 * config file's own note on what's trimmed and why. */
}

/*
 * KenC loads 32-bit immediates with MOVW (sign-extending).  Values with
 * bit31 set (e.g. 0x80000000) must come from static data so the high
 * word is zero, then loaded with a 64-bit MOV.  DRAMSIZE (256MiB) is fine
 * as an immediate; keep physdram in static storage.
 */
static uintptr physdram = (uintptr)8 << 28;

void
archconfinit(void)
{
	extern int fdtvalid(void);
	extern int fdtmemory(uvlong*, uvlong*);
	extern int fdtblob(uvlong*, uvlong*);
	uvlong base, size, top;

	/*
	 * The device tree rather than DRAMSIZE.  main.c calls fdtinit()
	 * before confinit() for exactly this.  Two guards: exactly one
	 * memory bank, since base and size describe a contiguous extent
	 * only then and two banks would put the hole between them into
	 * the pool; and a base of physdram, since everything here is
	 * identity mapped from there and confinit() computes npage0 from
	 * one range.  The third test is for the 32-bit boards: a tree
	 * naming more memory than a uintptr can hold must be left alone
	 * rather than truncated into a smaller top than it started with.
	 *
	 * There is no floor.  DRAMSIZE said 256MB here while QEMU's
	 * riscv -M virt defaults to 128MB, so this board was claiming
	 * 0x90000000 as the top of a machine whose memory ends at
	 * 0x88000000 -- the xalloc line read "801c7000 90000000
	 * 266571776" -- and 128MB of that pool was addresses the machine
	 * leaves unassigned.  Believing a tree that reports less than
	 * expected costs a smaller pool; disbelieving it hands out
	 * memory that is not there.
	 */
	conf.topofmem = physdram + DRAMSIZE;
	if(fdtvalid() && fdtmemory(&base, &size) == 1
	&& base == (uvlong)physdram && size != 0
	&& base + size == (uvlong)(uintptr)(base + size))
		conf.topofmem = (uintptr)(base + size);

	/*
	 * And keep the allocator off the tree.  QEMU's riscv machines
	 * put the blob at dram_end-2MB -- 0x87e00000 at the 128MB
	 * default, 0xbfe00000 at -m 1G -- which is inside the range
	 * confinit() is about to hand out.  It survived only because
	 * nothing had allocated that far up yet.  xalloc here takes one
	 * range, so the honest move is to stop below the blob rather
	 * than to carve a hole in the middle of it.
	 */
	if(fdtblob(&base, &size) && base >= (uvlong)physdram && base < (uvlong)conf.topofmem){
		top = base & ~((uvlong)BY2PG-1);
		if(top > (uvlong)physdram)
			conf.topofmem = (uintptr)top;
	}
	conf.cpuspeed = 10000000;
}

void
archconsole(void)
{
	/* uartconsole already set consuart / serwrite */
}

extern void	sbisystemreset(int);

void
archreboot(void)
{
	sbisystemreset(0);	/* SBI SRST shutdown; clean QEMU exit */
	for(;;)
		idle();		/* SRST does not return; spin if it somehow does */
}

void
kbdinit(void)
{
}

void
idlehands(void)
{
	/* Timer (CLINT) + UART (PLIC) wake WFI; sync ticks after wake. */
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

void
cycles(uvlong *u)
{
	*u = rdcycle();
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

/*
 * interp.h's AINC/ADEC (libinterp's Dis reference-counting primitives),
 * copied from os/inferno/armv7/archv7.c's own copy of this same gap:
 * spl-masked, same uniprocessor assumption cmpswap above already makes
 * (MAXMACH is 1 on this board).  virt/archvirt.c (riscv64/jc) doesn't
 * need this -- jc must provide it some other way this simpler zc port
 * doesn't have.
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
