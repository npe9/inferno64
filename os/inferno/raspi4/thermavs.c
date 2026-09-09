/*
 * BCM2711 die temperature sensor, in the AVS monitor (0xfd5d2200).
 *
 * This is not the block thermbcm.c drives.  A BCM2711's sensor is not
 * the BCM2835 one at a different address: it is a different block,
 * with one register instead of two, a different calibration, and it
 * does not live in the main peripheral window at all.  The AVS monitor
 * is at 0x7d5d2000 on the VC bus, which the ARM sees at 0xfd5d2000 --
 * a full 32MB below the peripherals every other driver here talks to.
 *
 * What this drives comes from the two published descriptions of the
 * part rather than from the BCM2835 datasheet:
 *
 *	arch/arm/boot/dts/broadcom/bcm2711.dtsi puts the block at
 *	avs-monitor@7d5d2000 with reg = <0x7d5d2000 0xf00>, and gives
 *	the calibration as coefficients = <(-487) 410040>.
 *
 *	drivers/thermal/broadcom/bcm2711_thermal.c reads one register
 *	in it, at offset 0x200, requires bits 16 and 10 both set for
 *	the reading to be valid, takes the data from bits 9:0, and
 *	converts with temp = slope * data + offset.
 *
 * So, in millidegrees and integers, as thermbcm.c does for its part:
 *
 *	millidegrees C = 410040 - 487 * adc
 *
 * A negative slope, again: a larger reading means a colder die.  The
 * constants differ from the BCM2835's (412000 - 538 * adc) by enough
 * that using the wrong pair reads about eight degrees hot at room
 * temperature and drifts further as the die warms, which is exactly
 * the sort of error that looks plausible until something throttles.
 *
 * There is no enable here.  The BCM2835 sensor needs its regulator and
 * its bandgap turned on before it reads anything; this one is a status
 * register that is already valid, and the driver Linux uses writes
 * nothing at all.  So neither does this.
 *
 * QEMU modelled this block for no machine, so it needed a model as
 * well as a driver: tools/qemu-patches 0024.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

enum {
	Tempstatus	= 0x200/4,	/* AVS_RO_TEMP_STATUS */

	Statdata	= 0x3ff,	/* bits 9:0, the reading */
	Statvalid	= 1<<16 | 1<<10,/* both must be set */

	Offsetmc	= 410040,	/* millidegrees at adc == 0 */
	Coeffmc		= 487,		/* millidegrees lost per adc count */

	/*
	 * What avstemp() returns when the block says its reading is not
	 * valid.  It cannot be -1, the way thermbcm.c's thermread()
	 * signals the same thing: a die really can be below zero, and a
	 * caller testing < 0 would call a cold board a broken sensor.
	 * If anything outside this file ever wants the reading, this has
	 * to move somewhere it can see -- an extern accessor with an
	 * invisible sentinel is worse than no accessor.
	 */
	Nosensor	= -1000000,
};

static u32*
avs(void)
{
	return (u32*)AVSMON;
}

/*
 * The reading in millidegrees, or Nosensor if the block says the value
 * is not valid.  Callers must check: a sensor that is not ready is not
 * a sensor reading zero.
 */
static long
avstemp(void)
{
	u32 *r = avs();
	u32 s;

	s = r[Tempstatus];
	if((s & Statvalid) != Statvalid)
		return Nosensor;
	return Offsetmc - Coeffmc * (long)(s & Statdata);
}

void
thermavsinit(void)
{
	u32 s;
	long mc;

	s = avs()[Tempstatus];
	mc = avstemp();
	if(mc == Nosensor){
		print("THERM-NONE status %8.8ux at %#p has neither valid bit\n",
			s, (void*)AVSMON);
		return;
	}
	print("therm: die %ld.%.3ld C (adc %ud, status %8.8ux) at %#p\n",
		mc/1000, mc%1000, s & Statdata, s, (void*)AVSMON);
	/*
	 * Same bounds thermbcm.c uses: outside them the conversion is
	 * wrong or the chip is about to stop being a chip.  The sensor
	 * steps in 487 millidegrees, so a reading is only ever within
	 * half a step of the truth -- a driver that wants tenths of a
	 * degree out of this block is wrong about the hardware.
	 */
	if(mc < -20000 || mc > 125000){
		print("THERM-FAIL %ld millidegrees is not a plausible die temperature\n", mc);
		return;
	}
	print("THERM-OK sensor reads a plausible die temperature\n");
}
