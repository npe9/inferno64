/*
 * BCM2835 PWM (0x3f20c000): two pulse-width modulators sharing a
 * 16-word data FIFO.  On a Pi these drive the analogue audio jack and
 * whatever is wired to GPIO 12/13/18/19 -- a servo, a backlight, an
 * LED.
 *
 * HOW TO DRIVE THIS BLOCK, in the order that matters.
 *
 * 1.  Give it a clock.  The PWM serialiser is fed by the clock
 *     manager, not by the ARM clock, and it does not run until
 *     CM_PWMCTL and CM_PWMDIV are programmed.  A channel enabled
 *     before that sits there doing nothing, which is a confusing
 *     thing to debug on a board, so pwmclock() runs first and
 *     everything else assumes it did.
 *
 * 2.  Stop the clock before changing its divisor.  The hardware
 *     ignores a divisor written while the clock is running, and
 *     stopping is not instantaneous -- CM_PWMCTL's BUSY bit stays set
 *     until the last cycle has drained.  Waiting for BUSY is the step
 *     people skip; the symptom is a divisor that appears to take and
 *     a frequency that does not change.
 *
 * 3.  Every write to the clock manager carries the password 0x5a in
 *     its top byte, exactly like the watchdog block (pmbcm.c).
 *     Without it the write is discarded silently.
 *
 * 4.  Route the pins.  A channel is only visible outside the SoC once
 *     its GPIO is in the right alt function: GPIO 12 and 18 are PWM0
 *     in alt0 and alt5 respectively, GPIO 13 and 19 are PWM1.  The
 *     block runs regardless, which is why this file can be exercised
 *     without any pin being wired to anything.
 *
 * Two ways to set a duty cycle, and they are not the same:
 *
 *   PWM mode (MSEN clear) spreads the on-cycles evenly through the
 *   period, which is what you want for a light or a motor because it
 *   halves the ripple.
 *
 *   Mark/space mode (MSEN set) emits DAT cycles high then the rest
 *   low, one contiguous pulse per period.  That is what a servo or
 *   anything else measuring pulse *width* needs.
 *
 * A driver that uses the wrong one still produces the right average
 * voltage and the wrong behaviour, which is a good reason to say
 * which is which here.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

extern void gpiofsel(int, int);
extern int mboxgetclock(int, u32*);	/* mailbox.c */

/* take CPRMAN's PWM clock; see pwminit() */
int pwmdeep = 0;		/* gpiobcm.c */

enum {
	/* PWM registers, word offsets */
	Ctl	= 0x00/4,
	Sta	= 0x04/4,
	Dmac	= 0x08/4,
	Rng1	= 0x10/4,
	Dat1	= 0x14/4,
	Fif1	= 0x18/4,
	Rng2	= 0x20/4,
	Dat2	= 0x24/4,

	/* Ctl */
	Pwen1	= 1<<0,		/* channel 1 enable */
	Mode1	= 1<<1,		/* 0 = PWM, 1 = serialiser */
	Rptl1	= 1<<2,		/* repeat the last word when the FIFO empties */
	Sbit1	= 1<<3,		/* output state while idle */
	Pola1	= 1<<4,		/* invert the output */
	Usef1	= 1<<5,		/* take data from the FIFO, not Dat1 */
	Clrf1	= 1<<6,		/* clear the FIFO; write-only, reads back 0 */
	Msen1	= 1<<7,		/* 0 = PWM algorithm, 1 = mark/space */
	Pwen2	= 1<<8,
	Msen2	= 1<<15,

	/* Sta */
	Full1	= 1<<0,
	Empt1	= 1<<1,
	Werr1	= 1<<2,		/* wrote to a full FIFO */
	Rerr1	= 1<<3,		/* read from an empty FIFO */
	Berr	= 1<<8,		/* bus error */
	Sta1	= 1<<9,		/* channel 1 transmitting */
	Sta2	= 1<<10,
	Staw1c	= Werr1|Rerr1|Berr|(0xf<<4),	/* write one to clear */

	Fifodepth = 16,

	Pwmclkid = 10,		/* the firmware's id for the PWM clock */

	/* Clock manager, word offsets from CPRMAN */
	Pwmctl	= 0x0a0/4,
	Pwmdiv	= 0x0a4/4,

	Cmpassword = 0x5a000000,
	Cmenable = 1<<4,
	Cmkill	= 1<<5,
	Cmbusy	= 1<<7,
	Cmsrcosc = 1,		/* source 1: the 19.2MHz crystal */

	Oschz	= 19200000,

	/* GPIO alt functions carrying PWM */
	Alt0	= 4,		/* GPIO 12 = PWM0, GPIO 13 = PWM1 */
	Alt5	= 2,		/* GPIO 18 = PWM0, GPIO 19 = PWM1 */

	Timeout	= 100000,
};

static u32*
pwm(void)
{
	return (u32*)PWM0;
}

static u32*
cm(void)
{
	return (u32*)CPRMAN;
}

/*
 * Point the PWM serialiser at the crystal divided by divi, and return
 * the resulting frequency.  Stops the clock first and waits for it to
 * actually stop, because a divisor written to a running clock is
 * ignored.
 */
ulong
pwmclock(int divi)
{
	u32 *r = cm();
	int i;

	if(divi < 2)			/* divisor 0 and 1 are not usable */
		divi = 2;
	if(divi > 0xfff)
		divi = 0xfff;

	r[Pwmctl] = Cmpassword | Cmkill;	/* stop, and drop any cycle */
	for(i = 0; i < Timeout; i++)
		if((r[Pwmctl] & Cmbusy) == 0)
			break;
	if(i == Timeout)
		return 0;

	r[Pwmdiv] = Cmpassword | (divi << 12);	/* integer part, no fraction */
	r[Pwmctl] = Cmpassword | Cmsrcosc;	/* source before enable */
	r[Pwmctl] = Cmpassword | Cmsrcosc | Cmenable;

	/*
	 * Wait for the clock to actually start.  BUSY means the clock is
	 * running, and checking it is the difference between knowing the
	 * serialiser has a clock and merely having asked for one -- the
	 * divisor arithmetic below is this side's opinion, not the
	 * hardware's.
	 */
	for(i = 0; i < Timeout; i++)
		if(r[Pwmctl] & Cmbusy)
			break;
	if(i == Timeout)
		return 0;
	return Oschz / divi;
}

/*
 * Route a PWM channel to a pin.  chan is 0 or 1; the pin must be one
 * the block can actually reach, and the alt function differs between
 * the two pairs.
 */
int
pwmpin(int pin, int chan)
{
	switch(pin){
	case 12: case 13:
		if(pin - 12 != chan)
			return -1;
		gpiofsel(pin, Alt0);
		return 0;
	case 18: case 19:
		if(pin - 18 != chan)
			return -1;
		gpiofsel(pin, Alt5);
		return 0;
	}
	return -1;
}

/*
 * Set channel 1's period and duty in serialiser clock cycles, in
 * mark/space mode -- one contiguous pulse per period, which is what a
 * servo wants.  A 50Hz frame with a 1.5ms pulse is centre on a hobby
 * servo: pwmclock(96) gives 200kHz, so period 4000 and duty 300.
 */
void
pwmmarkspace(ulong period, ulong duty)
{
	u32 *r = pwm();

	if(duty > period)
		duty = period;
	r[Rng1] = period;
	r[Dat1] = duty;
	r[Ctl] = (r[Ctl] & ~Usef1) | Pwen1 | Msen1;
}

/* The same, but with the on-cycles spread through the period. */
void
pwmbalanced(ulong period, ulong duty)
{
	u32 *r = pwm();

	if(duty > period)
		duty = period;
	r[Rng1] = period;
	r[Dat1] = duty;
	r[Ctl] = (r[Ctl] & ~(Usef1|Msen1)) | Pwen1;
}

void
pwmoff(void)
{
	u32 *r = pwm();

	r[Ctl] &= ~(Pwen1|Pwen2);
}

/*
 * Bring the block up and prove it works, the way i2cbcm.c and
 * spibcm.c do for theirs.  This exercises every part of the block a
 * driver touches: the clock manager, both duty-cycle modes, the FIFO
 * with its full and empty flags, and the two error bits -- including
 * that they are cleared by writing one to them, which is easy to get
 * backwards.
 */
void
pwminit(void)
{
	u32 fwhz;
	char *pwmfrom;
	u32 *r = pwm();
	ulong hz;
	int i, bad;

	/*
	 * Is the block there at all?  At reset the FIFO is empty and the
	 * range registers hold 0x20, so a block that answers reads with
	 * zeroes -- unassigned memory, or an emulator without a PWM model
	 * -- is distinguishable from one that is present and idle.
	 */
	if((r[Sta] & Empt1) == 0 && r[Rng1] == 0){
		print("PWM-NONE no PWM block at %#p\n", (void*)PWM0);
		return;
	}

	/*
	 * Ask the firmware what the PWM clock is; do not ask it to change
	 * one, and do not take CPRMAN.
	 *
	 * Setting it through the mailbox looked like the safe way to do
	 * this and is not.  With SET_CLOCK_RATE in the boot the board's
	 * console came back garbled -- the PL011's own output unreadable
	 * while the mini UART's line, clocked separately, was clean --
	 * which is the console's clock moving under it.  The firmware
	 * owns the clock tree and relates the clocks to each other; a
	 * boot-time check has no business rearranging it.  Taking CPRMAN
	 * directly is worse: that is what hung the boot in i2sbcm.c.
	 *
	 * So: use the rate the firmware already has, and if it will not
	 * say, do the checks that need no clock and stop.  pwmdeep takes
	 * CPRMAN on a board where nothing else needs the firmware.
	 */
	hz = 0;
	pwmfrom = "the firmware";
	if(mboxgetclock(Pwmclkid, &fwhz) == 0)
		hz = fwhz;
	if(hz == 0 && pwmdeep){
		pwmfrom = "cprman";
		hz = pwmclock(96);		/* 19.2MHz / 96 = 200kHz */
	}
	if(hz == 0){
		print("PWM-NOCLOCK the block answers; the firmware reports no PWM "
			"clock and this does not set one\n");
		return;
	}
	if(hz == 0){
		print("PWM-FAIL clock never started (ctl %#ux div %#ux)\n",
			cm()[Pwmctl], cm()[Pwmdiv]);
		return;
	}

	/* Mark/space: a 50Hz frame with a 1.5ms pulse, a servo's centre. */
	pwmmarkspace(hz/50, (hz/50)*15/100);
	if(r[Rng1] != hz/50 || r[Dat1] != (hz/50)*15/100){
		print("PWM-FAIL range/data did not read back (%ud/%ud)\n",
			r[Rng1], r[Dat1]);
		return;
	}
	if((r[Sta] & Sta1) == 0){
		print("PWM-FAIL channel 1 not transmitting when enabled "
			"(clock %lud Hz from %s, sta %#ux ctl %#ux)\n",
			hz, pwmfrom, r[Sta], r[Ctl]);
		return;
	}

	/* Balanced mode, half duty. */
	pwmbalanced(1000, 500);
	if(r[Ctl] & Msen1){
		print("PWM-FAIL balanced mode left mark/space set\n");
		return;
	}

	/*
	 * FIFO mode.  Clear it, confirm it reads empty, fill it exactly
	 * and confirm it reads full, then overrun it by one and confirm
	 * the block says so rather than quietly dropping the word.
	 */
	pwmoff();
	r[Ctl] = Clrf1;
	if((r[Ctl] & Clrf1) != 0){
		print("PWM-FAIL Clrf1 is not self-clearing\n");
		return;
	}
	if((r[Sta] & Empt1) == 0 || (r[Sta] & Full1) != 0){
		print("PWM-FAIL FIFO not empty after a clear (sta %#ux)\n", r[Sta]);
		return;
	}
	for(i = 0; i < Fifodepth; i++)
		r[Fif1] = 0x11111111 * (i + 1);
	if((r[Sta] & Full1) == 0 || (r[Sta] & Empt1) != 0){
		print("PWM-FAIL FIFO not full after %d words (sta %#ux)\n",
			Fifodepth, r[Sta]);
		return;
	}
	r[Fif1] = 0xdeadbeef;			/* one too many */
	if((r[Sta] & Werr1) == 0){
		print("PWM-FAIL overrunning the FIFO did not raise Werr1\n");
		return;
	}
	r[Sta] = Werr1;				/* write one to clear */
	if(r[Sta] & Werr1){
		print("PWM-FAIL Werr1 did not clear\n");
		return;
	}

	/*
	 * The FIFO is the serialiser's input and cannot be read back.
	 * Reading it is a driver bug, and the block reports it.
	 */
	bad = r[Fif1];
	USED(bad);
	if((r[Sta] & Rerr1) == 0){
		print("PWM-FAIL reading the write-only FIFO did not raise Rerr1\n");
		return;
	}
	r[Sta] = Rerr1;

	r[Ctl] = Clrf1;
	pwmoff();
	if(r[Sta] & (Werr1|Rerr1|Berr)){
		print("PWM-FAIL status not clean at the end (%#ux)\n", r[Sta]);
		return;
	}

	print("pwm: pwm at %#p, serialiser clock %lud Hz\n", (void*)PWM0, hz);
	print("PWM-OK clock, mark/space, balanced, FIFO full/empty and errors\n");
}
