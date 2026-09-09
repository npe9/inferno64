/*
 * BCM2835 temperature sensor (0x3f212000).
 *
 * Two registers.  CTL enables the sensor and its regulator; STAT
 * carries a 10-bit ADC reading and a valid bit.  The reading is not a
 * temperature: it is converted with the constants the SoC is
 * characterised with,
 *
 *	degrees C = 412 - 0.538 * adc
 *
 * which is a negative slope -- a *larger* ADC reading means a *colder*
 * chip.  Getting that backwards produces a driver that reports the
 * die cooling down as it heats up, which is the kind of thing that
 * only shows up under load.
 *
 * The arithmetic is done in millidegrees with integers, because this
 * is a kernel and 0.538 is not available here: 412000 - 538 * adc.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

enum {
	Ctl	= 0x00/4,
	Stat	= 0x04/4,

	Ctlenable	= 1<<0,
	Ctlregulator	= 1<<26,

	Statdata	= 0x3ff,	/* 10-bit ADC reading */
	Statvalid	= 1<<10,

	Offsetmc	= 412000,	/* millidegrees at adc == 0 */
	Coeffmc		= 538,		/* millidegrees lost per adc count */
};

static u32*
th(void)
{
	return (u32*)THERMAL;
}

/*
 * Die temperature in millidegrees C, or -1 if the sensor has no valid
 * reading yet.
 */
long
thermread(void)
{
	u32 *r = th();
	u32 s;

	s = r[Stat];
	if((s & Statvalid) == 0)
		return -1;
	return Offsetmc - Coeffmc * (long)(s & Statdata);
}

void
therminit(void)
{
	u32 *r = th();
	long mc;

	r[Ctl] = Ctlenable | Ctlregulator;
	mc = thermread();
	if(mc < 0){
		print("THERM-NONE no valid reading at %#p\n", (void*)THERMAL);
		return;
	}
	print("therm: die %ld.%.3ld C (adc %ud) at %#p\n",
		mc/1000, mc%1000, r[Stat] & Statdata, (void*)THERMAL);
	/*
	 * Anything outside this is either a broken conversion or a chip
	 * that is about to stop being a chip.
	 */
	if(mc < -20000 || mc > 125000){
		print("THERM-FAIL %ld millidegrees is not a plausible die temperature\n", mc);
		return;
	}
	print("THERM-OK sensor reads a plausible die temperature\n");
}
