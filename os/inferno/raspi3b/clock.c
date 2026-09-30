#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"

typedef struct Clock0link Clock0link;
struct Clock0link {
	void		(*clock)(void);
	Clock0link*	link;
};

static Clock0link *clock0link;
static Lock clock0lock;

extern int	vcsweeptick;		/* config: sweep the data segment at this tick */
extern int	livelockticks;		/* config: report a Dis program that will not yield */
static void	livelockcheck(void);
extern void	timercheck(Ureg*);
extern ulong	ticknoup, ticknotrun, tickrun;
extern int	schedclock;
extern void	(*kproftick)(ulong);

static uvlong
now(void)
{
	uvlong u;

	cycles(&u);
	return u;
}

/*
 * A cheap monotonic count for measuring short intervals.  CNTPCT runs
 * at CNTFRQ, 19.2MHz on this part, so one tick is about 52ns and a
 * 32-bit long wraps after about three and a half minutes -- which is
 * why only differences are ever taken from it.
 */
long
lcycles(void)
{
	uvlong u;

	cycles(&u);
	return (long)u;
}

/* Next deadline: HZ period, or sooner soft timer if one is pending. */
uvlong
timernext(uvlong hznext)
{
	uvlong t;

	t = timersoon();
	if(t != 0 && t < hznext)
		return t;
	return hznext;
}

Timer*
addclock0link(void (*clock)(void), int)
{
	Clock0link *lp;

	if((lp = malloc(sizeof(Clock0link))) == 0){
		print("addclock0link: too many links\n");
		return nil;
	}
	ilock(&clock0lock);
	lp->clock = clock;
	lp->link = clock0link;
	clock0link = lp;
	iunlock(&clock0lock);
	return nil;
}

void
clockintr(Ureg *u)
{
	Clock0link *lp;
	uvlong n, hznext, when;

	n = now();
	hznext = n + m->cpuhz/HZ;
	hwtimerset(&hznext);		/* clear the condition; final deadline set below */

	if(kproftick != nil && u != nil)
		kproftick((ulong)u->pc);

	m->ticks++;
	/*
	 * A late sweep, from the config: vcsweeptick ticks after boot, which is
	 * how the data segment gets looked at AFTER the wild store rather than
	 * before it.  The freeze happens about half a second into the first Dis
	 * program, so anything past 100 is late enough, and comveccheck in
	 * trap.c is what keeps the board alive long enough to report.  0 is off.
	 */
	if(vcsweeptick != 0 && m->ticks == (ulong)vcsweeptick)
		vcsweep("late");
	livelockcheck();
	if(schedclock)
		accounttime();
	checkalarms();
	timercheck(u);

	/*
	 * The scheduler's clock, which no native Inferno board in this
	 * tree was wiring up.  hzsched() and accounttime() are both
	 * compiled into every one of these kernels -- they are in
	 * port/proc.c, they are in the link -- and nothing called either
	 * of them, so a process's priority never decayed with the time it
	 * used and its quantum never ended.  That is not a Raspberry Pi
	 * quirk; it is every board here, and it is why a process a device
	 * woke could wait milliseconds behind a Limbo loop.
	 *
	 * hzsched() does not switch anything.  It rebalances the run
	 * queues once a second and sets up->resched when the running
	 * process has had its 100ms or when something better is ready;
	 * vmachine() acts on that at the next Dis instruction boundary.
	 */
	if(up == nil)
		ticknoup++;
	else if(up->state != Running)
		ticknotrun++;
	else
		tickrun++;
	if(schedclock && up != nil && up->state == Running)
		hzsched();

	n = now();
	hznext = n + m->cpuhz/HZ;
	when = timernext(hznext);
	if(when <= n)
		when = n + 1;
	hwtimerset(&when);

	if(canlock(&clock0lock)){
		for(lp = clock0link; lp; lp = lp->link)
			if(lp->clock)
				lp->clock();
		unlock(&clock0lock);
	}
}

void
clockinit(void)
{
	uvlong freq, when;

	cntfrq(&freq);
	m->cpuhz = (ulong)freq;
	m->delayloop = m->cpuhz/1000;
	conf.cpuspeed = m->cpuhz;
	m->ticks = 0;

	/*
	 * Route the non-secure physical timer (CNTPNSIRQ, bit 1) to core 0's
	 * IRQ line through the BCM2836 per-core interrupt controller.  This
	 * is what turns the periodic scheduler tick on.  It was long left off
	 * because a timer IRQ taken mid-transfer corrupted memory -- that was
	 * the vectrap argument-home / UR_R1 collision fixed in l.s (trap()'s
	 * Ureg* argument was spilled onto the saved R1 slot, clobbering a
	 * live loop counter in irestore's R = p->R copy).  With that fixed
	 * the tick is safe, so enable it.
	 */
	*(volatile ulong*)(0x40000040) = 1<<1;	/* Core0 timer int ctl: CNTPNSIRQ -> IRQ */

	when = now() + m->cpuhz/HZ;
	hwtimerset(&when);
	timerie();
}

/*
 * The same two things for a processor that is not processor 0.
 *
 * clockinitsecondary() is clockinit() minus everything that belongs to
 * the machine rather than to this processor: CNTFRQ, CNTP_CVAL, the
 * timer enable and the BCM2836 per-core routing register are all
 * per-processor state, and conf.cpuspeed and the soft-timer queues are
 * not.  The routing register is 0x40000040 + 4*machno -- one per core,
 * bit 1 being CNTPNSIRQ -- so each processor arms its own.
 *
 * clocksecondary() is clockintr() minus everything that touches a
 * process, a queue or a lock: it counts and re-arms.  That is the whole
 * handler, and it is deliberately not clockintr(): accounttime(),
 * checkalarms(), timercheck() and hzsched() all reach shared scheduler
 * state that this kernel's portable half has never been asked to
 * protect against a second processor.  What m->ticks rising on three
 * processors at once proves is narrow and real -- each is taking its
 * own timer interrupt, through its own vector table, into its own Mach.
 */
/*
 * l.s's secirq re-arms the timer with a constant, because a handler that
 * must not read memory cannot divide CNTFRQ by HZ for itself.  The constant
 * is right for this part and silent if it ever is not: under QEMU, whose
 * CNTFRQ is not 19.2MHz, it ran at fifty-one ticks in two hundred
 * milliseconds instead of twenty and nothing said so.  So say so.
 */
enum {
	Secirqperiod	= 192000,	/* the MOV in l.s's secirq */
};

extern int smpstart;

/*
 * Has one Dis program stopped letting anybody else run?
 *
 * This kernel serialises Dis, so a Limbo loop that never yields starves every
 * other Dis process -- etherusb among them, which is why such a thing looks
 * exactly like a dead board: no network, no command poller, and a kernel that
 * is in fact perfectly healthy and still taking these very interrupts.  That
 * is what the "freeze" with the secondaries running turned out to be, after
 * three theories about memory corruption that was never there: core 0 was
 * executing valid JIT-generated Dis code, with X20 holding the address of R
 * and RFP and RMP pointing into the heap, and the program it was running was
 * schedlat()'s deliberate busy loop, "for(;;) n++;".
 *
 * So say so, from inside the machine, rather than halting it over JTAG and
 * reading registers.  Interrupts keep arriving throughout, which is the whole
 * reason this works: if the same process has been Running for livelockticks
 * ticks without the scheduler ever choosing another, print which one it is.
 * The report is rate-limited and repeats at that interval, so a program that
 * legitimately computes for a long time says so once a second rather than
 * flooding, and a program that has genuinely stopped yielding says so for as
 * long as it goes on.
 *
 * It names the process and not yet the Dis instruction: R.IC and R.M would
 * want interp.h in here.  The pid and the text are enough to say which program
 * to look at, which is the step this was missing.
 */
static void
livelockcheck(void)
{
	static Proc *held;
	static ulong since;
	static int nseen;

	if(livelockticks == 0)
		return;
	if(up == nil || up->state != Running || up != held){
		held = up;
		since = m->ticks;
		return;
	}
	if(m->ticks - since < (ulong)livelockticks)
		return;
	since = m->ticks;
	if(++nseen <= 16)
		iprint("LIVELOCK %d: pid %lud (%s) has held the Dis VM for %d"
			" ticks; nothing else has run\n", nseen, (ulong)up->pid,
			up->text != nil? up->text: "?", livelockticks);
}

void
clockinitsecondary(void)
{
	uvlong freq, when;

	cntfrq(&freq);
	m->cpuhz = (ulong)freq;
	m->delayloop = m->cpuhz/1000;
	m->ticks = 0;
	*(volatile ulong*)(0x40000040 + 4*m->machno) = 1<<1;
	coherence();
	if(smpstart >= 3 && m->cpuhz/HZ != Secirqperiod)
		iprint("CPU%d SECIRQ-RATE: cpuhz/HZ is %lud, secirq re-arms at %d;"
			" its tick count is wrong by that ratio\n",
			m->machno, m->cpuhz/HZ, Secirqperiod);
	when = now() + m->cpuhz/HZ;
	hwtimerset(&when);
	timerie();
}

void
clocksecondary(Ureg*)
{
	uvlong when;

	m->ticks++;
	when = now() + m->cpuhz/HZ;
	hwtimerset(&when);
}

void
clockpoll(void)
{
	int c;

	if(consuart != nil && consuart->phys->getc != nil){
		while((c = consuart->phys->getc(consuart)) >= 0)
			uartrecv(consuart, c);
	}
}

void
clockcheck(void)
{
	clockpoll();
}

/*
 * Boot assertions, with interrupts on: the scheduler tick counts during
 * a 250ms busy wait (delay() waits on the counter, not on ticks), and a
 * timed sleep in this process wakes.  A dead tick prints TICK-FAIL with
 * the core's interrupt mask, the timer's enable/ISTATUS and deadline, and
 * the BCM2836 per-core route and pending registers.
 */
void
clockcheckboot(void)
{
	ulong t0, n;
	uvlong now, cval;
	extern ulong getcntpctl(void);
	extern ulong getdaif(void);
	extern void getcntpcval(uvlong*);

	t0 = m->ticks;
	delay(250);
	n = m->ticks - t0;
	if(n >= HZ/8)
		print("TICK-OK %lud ticks in 250ms\n", n);
	else{
		cycles(&now);
		getcntpcval(&cval);
		print("TICK-FAIL %lud ticks in 250ms: daif %#lux cntp_ctl %#lux "
			"cval-now %lld local route %#ux pending %#ux gpu route %#ux\n",
			n, getdaif(), getcntpctl(), (vlong)(cval - now),
			*(volatile u32*)0x40000040, *(volatile u32*)0x40000060,
			*(volatile u32*)0x4000000c);
	}
	t0 = m->ticks;
	tsleep(&up->sleep, return0, nil, 100);
	print("SLEEP-OK tsleep 100ms returned after %lud ticks\n", m->ticks - t0);
}

uvlong
fastticks(uvlong *hz)
{
	if(hz)
		*hz = m->cpuhz ? m->cpuhz : HZ;
	return now();
}

ulong
tk2ms(ulong ticks)
{
	uvlong t, hz;

	t = ticks;
	hz = HZ;
	t *= 1000L;
	t = t/hz;
	return (ulong)t;
}

ulong
ms2tk(ulong ms)
{
	if(ms >= 1000000000/HZ)
		return (ms/1000)*HZ;
	return (ms*HZ+500)/1000;
}
