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

extern void	timercheck(Ureg*);
static void	sleepwatch(Ureg*);
static void	wdpet(void);
static void	wdarm(void);
static void	heartbeat(Ureg*);
extern void	(*kproftick)(ulong);

static uvlong
now(void)
{
	uvlong u;

	cycles(&u);
	return u;
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
	((volatile uvlong*)0x20000000)[10] = m->ticks;
	((volatile uvlong*)0x20000000)[11] = u != nil? u->pc: 0;
	wdpet();
	checkalarms();
	timercheck(u);
	sleepwatch(u);
	heartbeat(u);

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
 * Boot sleep test.  On the Pi every timed sleep hung (DWC's 25ms tsleep,
 * this test's first version in a kproc) while the tick counted at 100Hz.
 * init0 now sleeps 100ms itself, and if that sleep is still pending a
 * second and then five seconds past its deadline, the clock interrupt
 * reports, straight to the UART, the state it can see without taking a
 * lock: the sleeper's Proc state, whether its timer is still queued or
 * has fired, whether its deadline is still ahead, and what the tick
 * interrupted -- which process, at what pc, with interrupts masked or not.
 */
static Proc	*stp;
static uvlong	stdeadline;
static int	stdone, streports;

/*
 * Every five seconds from the clock interrupt, straight to the UART: is
 * the tick alive, have PL011 interrupts and received bytes arrived, has
 * the idle loop run, and what process and pc the tick interrupted.  At
 * the shell prompt on the Pi, typed input got no answer; this says
 * whether it reached the kernel and what the CPU was doing instead.
 */
static void
heartbeat(Ureg *u)
{
	extern ulong pl011intrs, pl011rxchars, idlecount, fiqcount;

	if(m->ticks % (m->ticks < 120*HZ? HZ: 10*HZ) != 0)
		return;
	serialputs("HB ticks ", -1);
	serialputdec(m->ticks);
	serialputs(" uartintr ", -1);
	serialputdec(pl011intrs);
	serialputs(" fiq ", -1);
	serialputdec(fiqcount);
	serialputs(" rx ", -1);
	serialputdec(pl011rxchars);
	serialputs(" idle ", -1);
	serialputdec(idlecount);
	serialputreg("pc", u != nil? u->pc: 0, 8);
	serialputreg("spsr", u != nil? u->status: 0, 3);
	serialputs(" up ", -1);
	if(up != nil && up->text != nil){
		serialputs(up->text, -1);
		serialputreg("pid", up->pid, 4);
	}else
		serialputs("-", 1);
	serialputs("\n", -1);
}

/*
 * FIQ watchdog.  At the Pi's shell prompt the heartbeat above stopped:
 * the clock interrupt was no longer being taken, so something is holding
 * IRQs masked.  splhi() masks only IRQ, so a FIQ still arrives.  The
 * BCM2835 system timer's compare channel 1 (channels 0 and 2 belong to
 * the VideoCore) is routed to FIQ at 1Hz; if the tick has not advanced
 * since the previous FIQ, the stuck pc, link register, SPSR, the caller
 * of the last splhi() and the process go straight to the UART.
 */
enum {
	StCs	= 0x00/4,
	StClo	= 0x04/4,
	StC1	= 0x10/4,
	IcFiqctl	= 0x0c/4,
};

/*
 * BCM2835 PM watchdog: armed once init0 is running, petted each second
 * from the tick.  If the CPU goes silent the board resets itself ten
 * seconds later, and the crumb record at 0x20000000 (l.s crumbentry and
 * the tick above) tells the next boot where it was.
 */
static int wdarmed;

static void
wdpet(void)
{
	volatile u32 *pm = (volatile u32*)PM0;

	if(!wdarmed || m->ticks % HZ != 0)
		return;
	pm[0x24/4] = 0x5a000000 | (10<<16);		/* WDOG: 10s from now */
}

/*
 * Arm the watchdog, unless arming it resets the board on the spot.
 * The SoC's WDOG does not count until RSTC is armed, so a countdown
 * cannot be tested first; QEMU's bcm2835_powermgt resets the moment RSTC
 * is written.  So leave a marker in the crumb RAM (which survives the
 * reset), arm, and clear the marker: a boot that finds it still set was
 * reset by the arming itself, and leaves the watchdog alone.
 */
enum { Armmark = 0x41524d57 };

static void
wdarm(void)
{
	volatile u32 *pm = (volatile u32*)PM0;
	volatile uvlong *c = (volatile uvlong*)0x20000000;

	if(c[13] == Armmark){
		c[13] = 0;
		serialputs("WATCHDOG reset the board when armed: left unarmed\n", -1);
		return;
	}
	c[13] = Armmark;
	pm[0x24/4] = 0x5a000000 | (10<<16);
	pm[0x1c/4] = 0x5a000000 | (pm[0x1c/4] & ~0x30) | 0x20;
	delay(20);
	c[13] = 0;
	wdarmed = 1;
	serialputs("WATCHDOG armed, 10s\n", -1);
}

int fiqarmed;
static ulong fiqlastticks;
static int fiqreports;
ulong fiqcount;

static void
fiqarm(void)
{
	volatile u32 *st = (volatile u32*)(BCMPERIPH + 0x3000);

	st[StCs] = 1<<1;
	st[StC1] = st[StClo] + 1000000;
}

void
fiqwatchinit(void)
{
	extern void fiqenable(void);

	fiqlastticks = m->ticks;
	fiqarm();
	((volatile u32*)IRQBASE)[IcFiqctl] = 0x80 | 1;	/* FIQ from GPU IRQ 1 */
	fiqarmed = 1;
	fiqenable();
	wdarm();
	serialputs("FIQWATCH armed\n", -1);
}

void
fiqwatch(Ureg *u)
{
	fiqarm();
	fiqcount++;
	if(m->ticks != fiqlastticks || fiqreports >= 30){
		fiqlastticks = m->ticks;
		return;
	}
	fiqreports++;
	serialputs("FIQWATCH ticks stalled at ", -1);
	serialputdec(m->ticks);
	serialputreg("pc", u->pc, 8);
	serialputreg("lr", u->r30, 8);
	serialputreg("sp", u->sp, 8);
	serialputreg("spsr", u->status, 3);
	serialputreg("splpc", m->splpc, 8);
	serialputreg("esr", u->cause, 8);
	{
		/* return addresses on the stack above the stuck frame */
		uintptr *sp, v;
		int n;
		extern char etext[];

		sp = (uintptr*)u->sp;
		serialputs(" stk", -1);
		for(n = 0; n < 256 && (uintptr)sp < u->sp + 4096; sp++){
			v = *sp;
			if(v > KTZERO && v < (uintptr)etext && (v & 3) == 0){
				serialputreg("", v, 8);
				if(++n >= 10)
					break;
			}
		}
	}
	serialputs(" up ", -1);
	if(up != nil && up->text != nil){
		serialputs(up->text, -1);
		serialputreg("pid", up->pid, 4);
	}else
		serialputs("-", 1);
	serialputs("\n", -1);
}

static void
sleepwatch(Ureg *u)
{
	uvlong now, hz;

	if(stp == nil || stdone || streports >= 2)
		return;
	now = fastticks(&hz);
	if(now < stdeadline + (streports == 0? hz: 5*hz))
		return;
	streports++;
	serialputs("SLEEPSTUCK", -1);
	serialputreg("state", stp->state, 2);
	serialputreg("queued", stp->tt != nil, 1);
	serialputreg("ahead", stp->twhen > (Tval)now, 1);
	serialputreg("trend", stp->trend != nil, 1);
	serialputreg("up=sleeper", up == stp, 1);
	serialputreg("upstate", up != nil? up->state: 0xff, 2);
	serialputreg("pc", u != nil? u->pc: 0, 8);
	serialputreg("spsr", u != nil? u->status: 0, 3);
	serialputreg("ticks", m->ticks, 8);
	if(up != nil && up->text != nil){
		serialputs(" up ", -1);
		serialputs(up->text, -1);
	}
	serialputs("\n", -1);
}

/*
 * Boot assertion for the scheduler tick, taken with interrupts on.
 * delay() busy-waits on the counter, not on ticks, so a dead timer
 * interrupt shows as TICK-FAIL with the state of every stage it
 * crosses: the core's IRQ mask, the timer's own enable/ISTATUS and
 * deadline, the BCM2836 per-core route and pending registers.  A
 * timed sleep is then left to report itself: SLEEP-OK never printing
 * means timers never wake anyone, which is the same fault seen from a
 * process.
 */
/*
 * The first half second with interrupts on, reported straight to the
 * UART data register: console output after chandevreset goes through
 * a queue that only the transmit interrupt drains, so if interrupts do
 * not arrive nothing queued ever appears and this is the only word.
 */
static void
irqcheck(void)
{
	uvlong hz, t, end;
	ulong t0, i0, u0;
	extern ulong irqentries, pl011intrs;
	extern ulong getcntpctl(void), getdaif(void), getcurrentel(void), getvbar(void);
	extern void getcntpcval(uvlong*);
	uvlong cval;
	volatile u32 *ic = (volatile u32*)IRQBASE;

	t0 = m->ticks;
	i0 = irqentries;
	u0 = pl011intrs;
	cntfrq(&hz);
	cycles(&t);
	end = t + hz/2;
	while(t < end)
		cycles(&t);
	getcntpcval(&cval);
	serialputs("IRQCHECK 500ms: irqs ", -1);
	serialputdec(irqentries - i0);
	serialputs(" ticks ", -1);
	serialputdec(m->ticks - t0);
	serialputs(" uartintr ", -1);
	serialputdec(pl011intrs - u0);
	serialputreg("el", getcurrentel(), 1);
	serialputreg("daif", getdaif(), 3);
	serialputreg("vbar", getvbar(), 8);
	serialputreg("cntp_ctl", getcntpctl(), 1);
	serialputreg("cval>now", cval > t, 1);
	serialputreg("l40", *(volatile u32*)0x40000040, 2);
	serialputreg("l60", *(volatile u32*)0x40000060, 3);
	serialputreg("l0c", *(volatile u32*)0x4000000c, 2);
	serialputreg("basic", ic[0], 3);
	serialputreg("pend1", ic[1], 8);
	serialputreg("pend2", ic[2], 8);
	serialputreg("en1", ic[4], 8);
	serialputreg("en2", ic[5], 8);
	serialputs("\n", -1);
}

/*
 * Interrupt delivery at a named point: busy-wait 50ms with interrupts as
 * they are and print, straight to the UART, how many ticks and FIQs
 * arrived, DAIF, the timer's state, and the BCM2836 local controller's
 * timer route, pending and GPU route registers plus the BCM2835 FIQ
 * control.  On the Pi both the tick and the FIQ watchdog went silent
 * somewhere between the init0 probe and the shell prompt; the first
 * marker with no ticks names the step.
 */
void
tkmark(char *label)
{
	uvlong hz, t, end, cval;
	ulong t0, f0;
	extern ulong fiqcount;
	extern ulong getcntpctl(void), getdaif(void);
	extern void getcntpcval(uvlong*);

	t0 = m->ticks;
	f0 = fiqcount;
	cntfrq(&hz);
	cycles(&t);
	end = t + hz/20;
	while(t < end)
		cycles(&t);
	getcntpcval(&cval);
	serialputs("TK ", -1);
	serialputs(label, -1);
	serialputs(" ticks+", -1);
	serialputdec(m->ticks - t0);
	serialputs(" at ", -1);
	serialputdec(m->ticks);
	serialputs(" fiq+", -1);
	serialputdec(fiqcount - f0);
	serialputreg("daif", getdaif(), 3);
	serialputreg("ctl", getcntpctl(), 1);
	serialputreg("cval>now", cval > t, 1);
	serialputreg("l40", *(volatile u32*)0x40000040, 2);
	serialputreg("l60", *(volatile u32*)0x40000060, 3);
	serialputreg("l0c", *(volatile u32*)0x4000000c, 2);
	serialputreg("fiqctl", ((volatile u32*)IRQBASE)[0x0c/4], 2);
	serialputs("\n", -1);
}

void
clockcheckboot(void)
{
	ulong t0, n;
	uvlong now, cval;
	extern ulong getcntpctl(void);
	extern ulong getdaif(void);
	extern void getcntpcval(uvlong*);

	irqcheck();
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
	stdeadline = fastticks(nil) + m->cpuhz/10;
	stp = up;
	serialputs("SLEEPTEST tsleep 100ms\n", -1);
	tsleep(&up->sleep, return0, nil, 100);
	stdone = 1;
	serialputs("SLEEP-OK after ", -1);
	serialputdec(m->ticks - t0);
	serialputs(" ticks\n", -1);
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
