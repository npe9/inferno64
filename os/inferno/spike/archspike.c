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

static uintptr physdram = (uintptr)8 << 28;

void
archconfinit(void)
{
	extern int fdtvalid(void);
	extern int fdtmemory(uvlong*, uvlong*);
	extern int fdtblob(uvlong*, uvlong*);
	uvlong base, size, top;

	conf.topofmem = physdram + DRAMSIZE;
	/*
	 * The tree rather than DRAMSIZE, on the same two guards
	 * virtarm64 uses: exactly one bank, because base and size
	 * describe a contiguous extent only then and two banks would
	 * put the hole between them into the pool; and the base must be
	 * physdram, because everything here is identity mapped from
	 * there and confinit() computes npage0 from one range.  QEMU's
	 * -M spike has a single memory@80000000 whatever -m says, from
	 * 64M to 2G.  No floor: a tree that reports less than DRAMSIZE
	 * is reporting a smaller machine, and believing it wastes
	 * nothing where disbelieving it would hand out memory that is
	 * not there.
	 */
	if(fdtvalid() && fdtmemory(&base, &size) == 1
	&& base == (uvlong)physdram)
		conf.topofmem = physdram + (uintptr)size;

	/*
	 * And then keep the allocator off the tree itself.  This is
	 * where spike differs from virtarm64 and the difference is not
	 * cosmetic: -M virt writes the tree below the kernel's link
	 * address, under conf.base0, where nothing will ever reach it,
	 * but -M spike writes it 2MB below the top of RAM -- 0x87e00000
	 * at the default -m 128M, 0x8fe00000 at 256M, 0xffe00000 at 2G,
	 * always dram_end-2MB -- which is inside the range confinit()
	 * is about to hand out.  Before this the tree survived only
	 * because nothing had allocated that far up yet; that is luck,
	 * not a guarantee, and it would have become a live bug the
	 * moment anything read the tree after the pool filled.
	 *
	 * Trimming rather than reserving: xalloc here takes one range,
	 * so the honest move is to stop below the blob.  The cost is
	 * the 2MB tail QEMU chose to put it in, and only when the blob
	 * lies inside memory at all.
	 */
	if(fdtblob(&base, &size) && base >= (uvlong)physdram && base < (uvlong)conf.topofmem){
		top = base & ~((uvlong)BY2PG-1);
		if(top > (uvlong)physdram)
			conf.topofmem = (uintptr)top;
	}
	conf.cpuspeed = m->cpuhz;	/* the tree's timebase if it named one, else machinit()'s guess */
}

void
archconsole(void)
{
}

void
archreboot(void)
{
	for(;;)
		idle();
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
