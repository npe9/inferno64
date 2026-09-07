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
	 * Sampling for the self-test below.  Nsample intervals of
	 * Samplems each must cover more than one period of the 100Hz
	 * countdown, so that a wrap is actually exercised, while each
	 * single interval stays well short of a period so the
	 * subtraction across it is unambiguous.
	 */
	Nsample	= 8,
	Samplems = 3,

	/*
	 * The ARM timer's interrupt is bit 0 of the controller's basic
	 * bank, which trap.c carries as IRQ 64.  Nothing on this board
	 * used the basic bank before: gicenable() armed it and nothing
	 * dispatched it.
	 */
	Armtimerirq = 64,
	Intrhz	= 100,
	Intrms	= 50,		/* 100Hz for 50ms is 5 interrupts */
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

	armtmrstart(100);			/* 100Hz, i.e. 10ms a period */
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
	 * has stopped, or that parks at zero instead of wrapping, passes a
	 * simple "did it move" test whenever the first and last reads
	 * happen to differ; it cannot pass this one.  The samples are
	 * spaced well under one period so the subtraction below is
	 * unambiguous across a wrap.
	 */
	for(i = 1; i < Nsample; i++){
		ulong fell, want;

		fell = ((ulong)v[i-1] + period - v[i]) % period;
		want = (ulong)(((t[i] - t[i-1]) * rate) / 1000000);
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

	print("armtimer: countdown load %ud at %ud Hz, %d samples wrapped cleanly\n",
		load, rate, Nsample);
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
	 * Half the expected count plus one is the tolerance: delay() is
	 * a busy loop that the clock interrupt itself preempts, so the
	 * window is not exact, and at 100Hz over 50ms the count is
	 * small enough that a single missed edge is a fifth of it.
	 */
	if(expect == 0 || err > (long)(expect/2 + 1)){
		print("ARMTIMER-INTR-FAIL %lud interrupts, expected about %lud\n",
			armtmrintrs, expect);
		return;
	}
	print("ARMTIMER-INTR-OK interrupt arrives at the programmed rate\n");
}
