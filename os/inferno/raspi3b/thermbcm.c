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

extern int mboxtag(u32, u32*, int, int, u32*);	/* mailbox.c */

enum {
	Ctl	= 0x00/4,
	Stat	= 0x04/4,

	Ctlenable	= 1<<0,
	Ctlregulator	= 1<<26,

	Statdata	= 0x3ff,	/* 10-bit ADC reading */
	Statvalid	= 1<<10,

	Offsetmc	= 412000,	/* millidegrees at adc == 0 */
	Coeffmc		= 538,		/* millidegrees lost per adc count */

	Taggettemp	= 0x00030006,	/* firmware: get temperature */
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

/*
 * What the firmware says the die is, in millidegrees, or -1.
 *
 * The VideoCore owns this sensor: it is what the firmware throttles
 * on, and on this board the ARM's own enable bit does not produce a
 * valid reading -- THERM-NONE, on every boot, from a chip that is
 * plainly at some temperature.  Linux reads it through the same
 * property tag rather than the registers for the same reason.  The
 * register path is kept and tried first, because where it works it is
 * the direct one and needs nobody's cooperation.
 */
static long
thermfw(void)
{
	u32 v[2], resp;

	v[0] = 0;			/* temperature id 0 */
	v[1] = 0;
	resp = 0;
	if(mboxtag(Taggettemp, v, 2, 1, &resp) < 0)	/* one word of request */
		return -1;
	if((resp & 0x80000000) == 0)
		return -1;
	if(v[1] == 0)
		return -1;
	return (long)v[1];
}

void
therminit(void)
{
	u32 *r = th();
	long mc;
	char *from;

	r[Ctl] = Ctlenable | Ctlregulator;
	from = "the sensor's own registers";
	mc = thermread();
	if(mc < 0){
		mc = thermfw();
		from = "the firmware";
	}
	if(mc < 0){
		print("THERM-NONE no valid reading at %#p and the firmware has none\n",
			(void*)THERMAL);
		return;
	}
	print("therm: die %ld.%.3ld C (adc %ud) from %s\n",
		mc/1000, mc%1000, r[Stat] & Statdata, from);
	/*
	 * Anything outside this is either a broken conversion or a chip
	 * that is about to stop being a chip.
	 */
	if(mc < -20000 || mc > 125000){
		print("THERM-FAIL %ld millidegrees is not a plausible die temperature\n", mc);
		return;
	}
	print("THERM-OK a plausible die temperature, read from %s\n", from);
}
