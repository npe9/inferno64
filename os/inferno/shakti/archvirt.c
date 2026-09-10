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
 * time-of-day clock with this so wall time is calendar-correct, not
 * just relative to boot.  Returns ns since the epoch, or -1 if the read
 * looks bogus (a board without the RTC leaves tod on the tick counter).
 */
vlong
rtctime(void)
{
	return -1;	/* shakti_c has no RTC in its memory map */
}

void
pciarchinit(void)
{
	/* shakti_c has no PCI */
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
	 * riscv machines default to 128MB, so a board that took DRAMSIZE
	 * as the top was claiming 0x90000000 on a machine whose memory
	 * ends at 0x88000000.  Believing a tree that reports less than
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
	 * put the blob at dram_end-2MB, which is inside the range
	 * confinit() is about to hand out; it survived only because
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

void
archreboot(void)
{
	/*
	 * QEMU's sifive,test0 finisher powers the machine off on a write
	 * of 0x5555 (0x7777 would reboot), the machine-mode counterpart of
	 * the supervisor boards' SBI SRST call.  So exit() actually stops
	 * the machine instead of spinning here.
	 */
	*(volatile u32int*)(uintptr)SYSCON = 0x5555;
	for(;;)
		idle();		/* not reached if the finisher works */
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
