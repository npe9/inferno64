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

/*
 * The firmware's map kept whole, and not only the usable runs of it.
 * conf.mem[] says what may be allocated; this says what exists.  The
 * MMU needs the second: the ACPI tables acpiinit() reads are not type
 * 1 and would be unmapped if the map were built from conf.mem[] alone,
 * and -- the reason this is a separate array rather than a span from
 * PHYSDRAM to conf.topofmem -- the space between two runs is not
 * necessarily memory at all.  See mmuinit().
 */
typedef struct Fwrun Fwrun;
struct Fwrun {
	uvlong	base;
	uvlong	top;
	int	type;
};
static Fwrun fwmap[64];
static int nfwrun;

static void
addfwrun(uvlong base, uvlong top, int type)
{
	if(nfwrun >= nelem(fwmap))
		return;
	fwmap[nfwrun].base = base;
	fwmap[nfwrun].top = top;
	fwmap[nfwrun].type = type;
	nfwrun++;
}

/*
 * The i'th entry of that map, for mmuinit().  Returns 0 past the end.
 */
int
archfwrun(int i, uvlong *base, uvlong *top, int *type)
{
	if(i < 0 || i >= nfwrun)
		return 0;
	*base = fwmap[i].base;
	*top = fwmap[i].top;
	*type = fwmap[i].type;
	return 1;
}

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
		if(base >= top)
			continue;
		addfwrun(base, top, type);
		if(type == 1)
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
	nfwrun = 0;
	if(e820mem(kend) > 0)
		memfromfirmware = 1;
	else {
		conf.topofmem = PHYSDRAM + DRAMSIZE;
		addmemrun(kend, conf.topofmem, kend);
		addfwrun(PHYSDRAM, conf.topofmem, 1);
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
	/*
	 * And the map entire, types and all, because it is what mmuinit()
	 * builds the page tables from -- a run missing from here is a run
	 * that will fault when it is touched, and this is the only place
	 * that says so.  1 usable, 2 reserved or device, 3 ACPI reclaim,
	 * 4 ACPI NVS; os/inferno/boot/efi/efi.c's memtype[] is where the
	 * firmware's own types are turned into these.
	 */
	for(i = 0; i < nfwrun; i++)
		print("\tfw%d %#llux..%#llux type %d\n", i,
			fwmap[i].base, fwmap[i].top, fwmap[i].type);
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
/*
 * What the MMU bought, as a number rather than "it still boots".
 * Uncached RAM and write-back cacheable RAM are not a few per cent
 * apart, and a boot that succeeds either way says nothing about which
 * one it got.  A fixed number of passes over a buffer several times
 * the size of any plausible L1, timed against the generic timer, so
 * the figure is comparable between a kernel with mmuinit() enabled
 * and one without.
 */
void
memspeed(void)
{
	enum { Bufsz = 1024*1024, Npass = 16 };
	static uchar buf[Bufsz];
	uvlong t0, t1, hz;
	ulong sum;
	int i, j;

	cntfrq(&hz);
	cycles(&t0);
	sum = 0;
	for(j = 0; j < Npass; j++)
		for(i = 0; i < Bufsz; i += 64)
			sum += buf[i];
	cycles(&t1);
	USED(sum);
	if(t1 == t0)
		t1++;
	print("memspeed: %d MB read in %llud us, %llud MB/s\n",
		(Bufsz/(1024*1024))*Npass,
		(t1-t0)*1000000/hz,
		((uvlong)Bufsz*Npass*hz)/((t1-t0)*1024*1024));
}

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
