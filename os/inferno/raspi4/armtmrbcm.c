/*
 * BCM2835 ARM timer (0x3f00b400).
 *
 * The datasheet calls this "an SP804, but it is not fully compatible",
 * and the incompatibilities are the whole reason this file exists
 * rather than a stock SP804 driver:
 *
 *   - the counter is 16-bit unless CONTROL bit 1 selects 23-bit.  Not
 *     32-bit: 23.  A driver that loads a 32-bit period into it gets a
 *     silently truncated one.
 *
 *   - there is a pre-divider between the APB clock and the counter,
 *     which an SP804 does not have.  It resets to 0x7d, so the counter
 *     runs at apb/(0x7d+1) = apb/126 until something says otherwise.
 *
 *   - there is a second, free-running up-counter with its own 8-bit
 *     prescaler, which an SP804 does not have at all.
 *
 * The APB clock is the core clock, nominally 250MHz, and it moves when
 * the firmware scales the core.  That makes this timer a poor choice
 * for wall-clock work -- the system timer (systmrbcm.c) is fixed at
 * 1MHz and the ARM generic timer has its own fixed rate -- and a fine
 * one for periodic interrupts, which is what it is for.
 *
 * LOAD versus RELOAD, which is the other thing to get right: writing
 * LOAD reloads the counter immediately, restarting the current period,
 * while writing RELOAD changes the value taken at the *next* wrap and
 * leaves the period in progress alone.  Changing a running periodic
 * rate through LOAD gives one short or long tick every time.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "ureg.h"

enum {
	Load	= 0x00/4,
	Value	= 0x04/4,	/* read-only */
	Control	= 0x08/4,
	Irqack	= 0x0c/4,	/* write-only */
	Rawirq	= 0x10/4,	/* read-only */
	Mskirq	= 0x14/4,	/* read-only */
	Reload	= 0x18/4,
	Predivider = 0x1c/4,
	Freerun	= 0x20/4,	/* read-only */

	/* Control */
	C23bit	= 1<<1,		/* 0 = 16-bit counter, 1 = 23-bit */
	Cpre1	= 0<<2,
	Cpre16	= 1<<2,
	Cpre256	= 2<<2,
	Cinten	= 1<<5,
	Cenable	= 1<<7,
	Cfreerun = 1<<9,
	Cfrshift = 16,		/* free-running prescaler, 8 bits */

	Apbhz	= 250000000,	/* core clock; see the note above */

	Timeout	= 1000000,

	/*
	 * Sampling for the self-test below.
	 *
	 * This used to ask one sampling scheme two questions -- does the
	 * countdown run at its rate, and does it wrap rather than park
	 * at zero -- by covering more than one period with intervals
	 * each shorter than a period.  That balance held only while
	 * nothing delayed the loop.  A console at a real 115200 delays
	 * it: an interval stretched from 3ms to 14.8ms, crossed the
	 * 10ms period, and the modulo below folded the whole period
	 * away, so a healthy timer was reported as having fallen 9580
	 * where 29418 was expected.  The timer was fine; the check was
	 * wrong, and wrong intermittently, which is worse.
	 *
	 * The two questions are asked separately now, each at a rate
	 * that makes its own measurement unambiguous.  Ratehz is slow
	 * enough that the whole sampling window fits inside one period,
	 * so no interval can span a wrap at all.  Wraphz is fast enough
	 * that a reload is certain to happen while we watch for it.
	 */
	Nsample	= 8,
	Samplems = 3,
	Ratehz	= 4,		/* 250ms a period; window is about 25ms */
	Wraphz	= 50,		/* 20ms a period, for the reload check */
	Wrapms	= 400,		/* twenty of those, counted */

	/*
	 * The ARM timer's interrupt is bit 0 of the controller's basic
	 * bank, which trap.c carries as IRQ 64.  Nothing on this board
	 * used the basic bank before: gicenable() armed it and nothing
	 * dispatched it.
	 */
	Armtimerirq = 64,
	Intrhz	= 100,
	/*
	 * Long enough that the count is worth a tight bound.  At 100Hz
	 * a 50ms window gives 5 interrupts, and a single missed edge is
	 * a fifth of that -- so the tolerance has to be wide enough to
	 * let a timer running at half or double the programmed rate
	 * through, which is the very thing worth catching.  200ms gives
	 * about 20, where a quarter is a real bound and one missed edge
	 * is 5%.  It costs 150ms of boot.
	 */
	Intrms	= 200,
};

static u32*
at(void)
{
	return (u32*)ARMTIMER;
}

static ulong armtmrintrs;

static void
armtmrintr(Ureg*, void*)
{
	u32 *r = at();

	/*
	 * Ack first.  IRQACK is write-only and clears the interrupt at
	 * the source; the line is level, so leaving it asserted would
	 * re-enter this handler the instant it returns and wedge the
	 * board -- the usual way a first interrupt test takes one down.
	 */
	r[Irqack] = 1;
	armtmrintrs++;
}

/*
 * Run the countdown at hz, in 23-bit mode, without interrupts.  The
 * pre-divider is left at its reset value so the arithmetic below
 * matches what a Pi does out of reset.
 */
void
armtmrstart(int hz)
{
	u32 *r = at();
	u32 predivider, rate, load;

	predivider = r[Predivider] & 0x3ff;
	rate = Apbhz / (predivider + 1);
	load = rate / hz;
	if(load == 0)
		load = 1;

	r[Control] = C23bit | Cpre1;		/* mode before load */
	r[Load] = load;
	r[Control] = C23bit | Cpre1 | Cenable | Cfreerun;
}

void
armtmrstop(void)
{
	at()[Control] &= ~(Cenable|Cinten);
}

/*
 * Prove both counters run, and run at the rates the block says.
 *
 * The countdown is checked by watching it fall; the free-running
 * counter is checked against the 1MHz system timer, which shares
 * nothing with it.  Two counters that disagree about how long 20ms is
 * means one of them has the wrong divisor, and that is a much easier
 * thing to see here than as a timer that fires at the wrong rate three
 * subsystems later.
 */
void
armtmrinit(void)
{
	u32 *r = at();
	u32 predivider, rate, load, period, f1, f2;
	u32 v[Nsample];
	uvlong s1, s2;
	uvlong t[Nsample];
	ulong elapsedus, frticks, expect;
	long err;
	int i;
	extern uvlong systmrread(void);

	predivider = r[Predivider] & 0x3ff;
	if(predivider == 0 && r[Control] == 0){
		print("ARMTIMER-NONE no timer at %#p\n", (void*)ARMTIMER);
		return;
	}
	if(predivider != 0x7d)
		print("armtimer: pre-divider is %ud, not the 0x7d reset value\n",
			predivider);
	rate = Apbhz / (predivider + 1);

	armtmrstart(Ratehz);
	load = r[Load];
	period = load + 1;			/* it sits at zero for one tick */

	f1 = r[Freerun];
	s1 = systmrread();
	for(i = 0; i < Nsample; i++){
		v[i] = r[Value];
		t[i] = systmrread();
		delay(Samplems);
	}
	f2 = r[Freerun];
	s2 = systmrread();

	/*
	 * Check every interval, not just the endpoints.  A counter that
	 * has stopped passes a simple "did it move" test whenever the
	 * first and last reads happen to differ; it cannot pass this.
	 *
	 * The subtraction is only meaningful while an interval is shorter
	 * than a period, so that is asserted rather than assumed: an
	 * interval that reached a whole period is reported as a
	 * measurement that could not be made, not as a timer that failed.
	 * Those are different claims and only one of them is about the
	 * hardware.
	 */
	for(i = 1; i < Nsample; i++){
		ulong fell, want;

		fell = ((ulong)v[i-1] + period - v[i]) % period;
		want = (ulong)(((t[i] - t[i-1]) * rate) / 1000000);
		if(want >= period){
			print("ARMTIMER-NONE sample %d spans %lud us, at or past "
				"the %lud us period; the fall across it is "
				"ambiguous and nothing was measured\n",
				i, (ulong)(t[i] - t[i-1]),
				(ulong)(((uvlong)period * 1000000) / rate));
			armtmrstop();
			return;
		}
		err = (long)fell - (long)want;
		if(err < 0)
			err = -err;
		if(want == 0 || err > (long)(want/4)){
			print("ARMTIMER-FAIL countdown fell %lud in %lud us, "
				"expected %lud (sample %d: %ud -> %ud)\n",
				fell, (ulong)(t[i] - t[i-1]), want, i,
				v[i-1], v[i]);
			armtmrstop();
			return;
		}
	}

	/*
	 * The other question, which the rate check above deliberately
	 * cannot answer because it never lets the counter reach zero: a
	 * countdown that parks at zero instead of reloading passes every
	 * rate check that stops short of the end.  So run it fast and
	 * watch for the value to rise, which only a reload can do, then
	 * check it reloaded to Load and not to something else.
	 */
	{
		u32 prev, cur;
		int wraps, expectw;
		uvlong w0, wus;

		/*
		 * Count reloads over a window rather than inspecting the
		 * value at one.  The first attempt read the counter just
		 * after it rose and required the reading to be near Load;
		 * that is only true if nothing happens between the reload
		 * and the read, and something does -- an interrupt landed
		 * in one run of three and the counter had already fallen
		 * to 11478 of 19841 by the time it was read.  The check
		 * was flaky for the same reason the rate check above was:
		 * it assumed a bound on its own scheduling.
		 *
		 * A count over 400ms assumes nothing of the sort.  It
		 * also tests more: a parked counter gives zero, and a
		 * counter reloading at the wrong rate gives the wrong
		 * number, so one measurement answers both.
		 */
		armtmrstart(Wraphz);
		prev = r[Value];
		wraps = 0;
		w0 = systmrread();
		while((wus = systmrread() - w0) < Wrapms*1000){
			cur = r[Value];
			if(cur > prev)
				wraps++;
			prev = cur;
		}
		expectw = (int)((wus * Wraphz) / 1000000);
		if(wraps == 0){
			print("ARMTIMER-FAIL countdown never reloaded in %lud us; "
				"it parks rather than wraps\n", (ulong)wus);
			armtmrstop();
			return;
		}
		err = (long)wraps - (long)expectw;
		if(err < 0)
			err = -err;
		if(expectw == 0 || err > (long)(expectw/4)){
			print("ARMTIMER-FAIL countdown reloaded %d times in "
				"%lud us, expected %d\n",
				wraps, (ulong)wus, expectw);
			armtmrstop();
			return;
		}
		print("armtimer: countdown reloaded %d times in %lud us, "
			"%d expected\n", wraps, (ulong)wus, expectw);
	}

	if(f2 == f1){
		print("ARMTIMER-FAIL free-running counter did not move (%ud)\n", f1);
		armtmrstop();
		return;
	}

	/*
	 * The free-running counter runs at apb/(prescaler+1); the
	 * prescaler is zero here, so it should advance by apb ticks per
	 * second.  Compare against the microseconds the system timer saw.
	 */
	elapsedus = (ulong)(s2 - s1);
	frticks = f2 - f1;
	expect = (ulong)(((uvlong)elapsedus * Apbhz) / 1000000);
	err = (long)frticks - (long)expect;
	if(err < 0)
		err = -err;

	print("armtimer: countdown load %ud, %d intervals each within one period\n",
		load, Nsample-1);
	print("armtimer: free-running +%lud in %lud us\n", frticks, elapsedus);
	armtmrstop();

	if(expect == 0 || err > (long)(expect/4)){
		print("ARMTIMER-FAIL free-running counter and system timer disagree "
			"(+%lud vs %lud expected)\n", frticks, expect);
		return;
	}
	print("ARMTIMER-OK countdown wraps at its programmed rate, "
		"free-running agrees with the system timer\n");
}

/*
 * The interrupt, checked separately and later.
 *
 * It cannot be checked from armtmrinit().  Every device init on this
 * board runs before init0() calls spllo(), so trap() is not entered at
 * all at that point -- a counter in trap() reads zero entries there.
 * An interrupt test run with interrupts masked reports "delivers
 * nothing" whatever the hardware does: a test that cannot pass is as
 * useless as one that cannot fail.
 *
 * So this runs from init0(), after chandevinit(), where interrupts are
 * live.  It checks the thing a counter test cannot stand in for: the
 * block can count perfectly and still never deliver, which is exactly
 * what it did until trap() learned to read the controller's basic
 * bank.  Counting against an independent clock catches a timer that
 * delivers at the wrong rate as well as one that never delivers.
 */
void
armtmrintrcheck(void)
{
	u32 *r = at();
	u32 predivider, rate, load;
	uvlong s1, s2;
	ulong elapsedus, expect;
	long err;
	extern uvlong systmrread(void);

	predivider = r[Predivider] & 0x3ff;
	if(predivider == 0 && r[Control] == 0)
		return;			/* no block; armtmrinit() said so */
	rate = Apbhz / (predivider + 1);
	load = rate / Intrhz;
	if(load == 0)
		load = 1;

	armtmrintrs = 0;
	intrenable(Armtimerirq, armtmrintr, nil, 0, "armtimer");
	r[Control] = C23bit | Cpre1;		/* mode before load */
	r[Load] = load;
	r[Irqack] = 1;				/* drop anything stale */
	r[Control] = C23bit | Cpre1 | Cenable | Cinten;

	s1 = systmrread();
	delay(Intrms);
	s2 = systmrread();
	armtmrstop();
	r[Irqack] = 1;

	elapsedus = (ulong)(s2 - s1);
	expect = (ulong)(((uvlong)elapsedus * Intrhz) / 1000000);
	err = (long)armtmrintrs - (long)expect;
	if(err < 0)
		err = -err;
	print("armtimer: %lud interrupts in %lud us at %d Hz\n",
		armtmrintrs, elapsedus, Intrhz);
	if(armtmrintrs == 0){
		print("ARMTIMER-INTR-FAIL counts correctly but delivers nothing\n");
		return;
	}
	/*
	 * A quarter, matching the counter checks above: delay() is a
	 * busy loop the clock interrupt preempts, so the window is not
	 * exact, but over 200ms that is noise rather than a fifth of
	 * the measurement.
	 */
	if(expect == 0 || err > (long)(expect/4)){
		print("ARMTIMER-INTR-FAIL %lud interrupts, expected about %lud\n",
			armtmrintrs, expect);
		return;
	}
	print("ARMTIMER-INTR-OK interrupt arrives at the programmed rate\n");
}
