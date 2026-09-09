/*
 * BCM2835 system timer (0x3f003000): a free-running 64-bit counter at
 * a fixed 1MHz, plus four compare registers that raise an interrupt
 * when the low half of the counter matches.
 *
 * This is not the timer the scheduler runs on -- that is the ARM
 * generic timer, in clock.c, whose frequency is whatever CNTFRQ says.
 * The system timer is useful precisely because it is independent of
 * it: a fixed, known 1MHz reference that the VideoCore side also uses.
 * Reading both and comparing is how you find out that one of them is
 * lying, which is otherwise a very hard bug to see.
 *
 * Read the halves in the right order.  The counter is 64 bits behind a
 * 32-bit bus, so it is read as two words, and the low word can wrap
 * between the two reads.  Read high, low, high again, and retry if the
 * high word moved; the alternative is a timestamp that jumps backwards
 * by about 71 minutes roughly once every 71 minutes.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

enum {
	Cs	= 0x00/4,	/* control/status: match flags, write to clear */
	Clo	= 0x04/4,
	Chi	= 0x08/4,
	C0	= 0x0c/4,	/* compare 0..3 */

	Sthz	= 1000000,	/* the system timer is fixed at 1MHz */
};

static u32*
st(void)
{
	return (u32*)SYSTMR;
}

/*
 * The 64-bit counter, read without tearing.
 */
uvlong
systmrread(void)
{
	u32 *r = st();
	u32 hi, lo;

	for(;;){
		hi = r[Chi];
		lo = r[Clo];
		if(r[Chi] == hi)
			return (uvlong)hi<<32 | lo;
	}
}

/* Microseconds since the machine started, which is what 1MHz means. */
uvlong
systmrusec(void)
{
	return systmrread();
}

/*
 * Prove the counter runs, and runs at the rate it claims.
 *
 * The interesting part is not that it advances -- almost anything
 * advances -- but that it advances by the amount a second, independent
 * clock says it should.  delay() is paced by the ARM generic timer, so
 * a 50ms delay should move this counter by 50000 microseconds.  If the
 * two disagree, one of them has the wrong frequency, and this says so
 * rather than leaving it to be discovered by a timeout that is
 * mysteriously ten times too long.
 */
void
systmrinit(void)
{
	uvlong a, b, d;
	long err;

	a = systmrread();
	if(a == 0 && systmrread() == 0){
		print("SYSTMR-NONE counter at %#p is not running\n", (void*)SYSTMR);
		return;
	}

	delay(50);
	b = systmrread();
	if(b <= a){
		print("SYSTMR-FAIL counter did not advance (%llud -> %llud)\n", a, b);
		return;
	}
	d = b - a;

	/* Allow a generous margin: delay() is a calibrated busy loop. */
	err = (long)d - 50000;
	if(err < 0)
		err = -err;
	print("systmr: 1MHz counter at %#p, %llud us over a 50ms delay\n",
		(void*)SYSTMR, d);
	if(err > 15000){
		print("SYSTMR-FAIL 50ms of generic-timer delay measured %llud us here\n", d);
		return;
	}
	print("SYSTMR-OK counter runs, and agrees with the ARM generic timer\n");
}
