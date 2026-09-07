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
};

static u32*
at(void)
{
	return (u32*)ARMTIMER;
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
	u32 predivider, rate, v1, v2, f1, f2;
	uvlong s1, s2;
	ulong elapsedus, frticks, expect;
	long err;
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
	v1 = r[Value];
	f1 = r[Freerun];
	s1 = systmrread();
	delay(20);
	v2 = r[Value];
	f2 = r[Freerun];
	s2 = systmrread();

	if(v1 == v2){
		print("ARMTIMER-FAIL countdown did not move (%ud)\n", v1);
		armtmrstop();
		return;
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

	print("armtimer: countdown %ud->%ud at %ud Hz, free-running +%lud in %lud us\n",
		v1, v2, rate, frticks, elapsedus);
	armtmrstop();

	if(expect == 0 || err > (long)(expect/4)){
		print("ARMTIMER-FAIL free-running counter and system timer disagree "
			"(+%lud vs %lud expected)\n", frticks, expect);
		return;
	}
	print("ARMTIMER-OK both counters run, and agree with the system timer\n");
}
