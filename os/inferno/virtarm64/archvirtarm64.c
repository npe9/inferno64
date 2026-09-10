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
 * PSCI's conduit is a property of the firmware, not of the
 * architecture.  acpi.c sets this from the FADT's ARM Boot
 * Architecture Flags; nothing said leaves it zero, which is HVC --
 * what this board did before there was any ACPI and what QEMU's virt
 * machine wants.  Getting it wrong is not a wrong answer but an
 * undefined instruction, so the default is the one that is known to
 * work here rather than the one a server is more likely to want.
 */
int pscismcconduit;

uvlong
psci(uvlong fn, uvlong a1, uvlong a2, uvlong a3)
{
	if(pscismcconduit)
		return pscismc(fn, a1, a2, a3);
	return pscihvc(fn, a1, a2, a3);
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

/*
 * How much memory this machine actually has, rather than what mem.h
 * guesses.  DRAMSIZE says 256 MiB and is commented "matches -m 256";
 * every boot this session has been -m 512 or larger, and all of the
 * rest was thrown away silently -- a rented machine with 8 GiB would
 * have run in 256 MiB of it and nothing would have said so.
 *
 * The firmware already knows.  The UEFI loader puts its memory map in
 * the configuration block as *e820=, a sequence of "type base top"
 * triples in hex, and bootargsinit() has parsed it into /env before
 * this runs.  A UEFI map is not one run: on QEMU's virt with -m 1024
 * the usable memory between 0x40000000 and 0x80000000 comes back as
 * eight separate type-1 stretches with the firmware's own reserved
 * regions between them, and the one containing the kernel is the
 * smallest of them at 64 MiB.  Taking only that run is worse than the
 * constant it replaces, so every usable run goes into conf.mem[],
 * which xinit() already walks in full.
 *
 * Two things are clipped out.  The kernel's own image, from PHYSDRAM
 * to the page after end -- the firmware called that EfiLoaderData and
 * so type 1, correctly, since it is only the kernel that knows it is
 * still using it.  And anything below PHYSDRAM, which this board's
 * addressing does not reach.
 */
extern int main_pool_pcnt;

static int nmemrun;
static int memfromfirmware;

static void
addmemrun(uintptr base, uintptr top, uintptr kend)
{
	if(base < PHYSDRAM)
		base = PHYSDRAM;
	if(base < kend && top > kend)		/* clip the kernel image out */
		base = kend;
	if(base >= top || base < kend)
		return;
	base = PGROUND(base);
	top &= ~((uintptr)BY2PG-1);
	if(base >= top || nmemrun >= nelem(conf.mem))
		return;
	conf.mem[nmemrun].base = base;
	conf.mem[nmemrun].npage = (top - base)/BY2PG;
	conf.npage += conf.mem[nmemrun].npage;
	if(top > conf.topofmem)
		conf.topofmem = top;
	nmemrun++;
}

static int
e820mem(uintptr kend)
{
	uintptr base, top;
	int type;
	char *s;

	if((s = getconf("*e820")) == nil)
		return 0;
	for(;;){
		while(*s == ' ')
			s++;
		if(*s == 0)
			break;
		type = 1;
		if(s[1] == ' '){
			type = s[0] - '0';
			s += 2;
		}
		base = strtoull(s, &s, 16);
		if(*s != ' ')
			break;
		top = strtoull(s, &s, 16);
		if(*s != ' ' && *s != 0)
			break;
		if(base < top && type == 1)
			addmemrun(base, top, kend);
	}
	return nmemrun;
}

void
archconfinit(void)
{
	uintptr kend;
	extern int end[];

	kend = PGROUND((uintptr)end);
	conf.npage = 0;
	conf.topofmem = 0;
	nmemrun = 0;
	if(e820mem(kend) > 0)
		memfromfirmware = 1;
	else {
		conf.topofmem = PHYSDRAM + DRAMSIZE;
		addmemrun(kend, conf.topofmem, kend);
	}
	conf.base0 = conf.mem[0].base;
	conf.npage0 = conf.mem[0].npage;
	conf.base1 = 0;
	conf.npage1 = 0;
	conf.ialloc = (ulong)(((((uvlong)conf.npage*main_pool_pcnt)/100)/2)*BY2PG);
	conf.nproc = 200;
	conf.nmach = 1;
	conf.cpuspeed = 100000000;	/* refined once cntfrq() is read, see clockinit */
}

/*
 * Said out loud, and separately, because archconfinit() runs before
 * uartconsole() and anything it printed would go nowhere.  Which of
 * the two answers a machine got is worth the line: it is the
 * difference between using the machine and using a fraction of it.
 */
void
archmemreport(void)
{
	int i;

	print("mem: %llud MB usable in %d runs to %#llux, %s\n",
		(uvlong)conf.npage*BY2PG/(1024*1024), nmemrun,
		(uvlong)conf.topofmem,
		memfromfirmware ? "from the firmware's map" : "mem.h's DRAMSIZE, no map");
	for(i = 0; i < nmemrun; i++)
		print("\tmem%d %#llux..%#llux\n", i,
			(uvlong)conf.mem[i].base,
			(uvlong)(conf.mem[i].base + conf.mem[i].npage*BY2PG));
}

void
archconsole(void)
{
	/* uartconsole already set consuart / serwrite */
}

/*
 * These two are reached only from a panic, so for a long time nothing
 * showed whether they did anything: a panic's log ends at "Hit the
 * reset button" either way.  Called deliberately from main() on the
 * -kernel path, each stops QEMU on its own -- the process exits with
 * status 0 and a print placed after the call never appears, where the
 * same kernel with no call is killed by the timeout.  Neither takes
 * arguments, which is why neither was affected by l.s's psci argument
 * bug; see the comment there.
 */
void
archreboot(void)
{
	/* PSCI SYSTEM_RESET (0x84000009) */
	psci(0x84000009ULL, 0, 0, 0);
	for(;;)
		idle();
}

void
archshutdown(void)
{
	/* PSCI SYSTEM_OFF (0x84000008) */
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
 * The four atomics are hand-written assembly (l.s) and nothing else in
 * the tree tests them, so a subtly wrong one is silent: it does not
 * fail to build, it fails to be atomic.  7l had exactly that shape of
 * bug -- LDAXRW encoded with o2 set, which is LDLARW, a load that does
 * not take the exclusive monitor at all, so every STLXRW paired with
 * it would fail forever -- and it was found by reading the encoding,
 * not by running anything.
 *
 * This runs once, before any other processor exists, and checks what
 * a caller actually depends on: the value stored, the value returned,
 * and, for cmpswap, that a failed compare stores nothing and says so.
 * The negative case is the point; a cmpswap that always succeeds
 * passes every positive check there is.
 */
void
atomiccheck(void)
{
	int v, r;
	char *bad;

	bad = nil;
	v = 41;
	if((r = ainc(&v)) != 42 || v != 42)
		bad = "ainc";
	else if((r = adec(&v)) != 41 || v != 41)
		bad = "adec";
	else if(cmpswap(&v, 41, 7) != 1 || v != 7)
		bad = "cmpswap on a match";
	else if(cmpswap(&v, 41, 9) != 0 || v != 7)
		bad = "cmpswap on a mismatch";
	else if(_tas(&v) != 7 || v != 1)
		bad = "_tas";
	USED(r);
	if(bad != nil)
		panic("atomiccheck: %s is wrong, v %d", bad, v);
	print("atomics: ainc, adec, cmpswap both ways and _tas all correct\n");
}
