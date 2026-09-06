/*
 * BCM2835 power management block (0x3f100000): the watchdog, and the
 * reset the watchdog drives.  On this SoC a reset IS a watchdog
 * expiry -- there is no separate reset register -- so the two are one
 * driver.
 *
 * Every write to the block must carry the password 0x5a in the top
 * byte or the hardware ignores it silently, which is the single
 * easiest way to write a watchdog that appears to arm and never fires.
 *
 * WHY THIS REPLACES PSCI.  archreboot() used to call PSCI
 * SYSTEM_RESET, which works under QEMU because QEMU implements the
 * PSCI conduit for it.  A real Raspberry Pi 3B has no ATF and no
 * secure-monitor firmware behind HVC, so on the board that call
 * reaches nothing and the machine does not reboot -- an emulator-only
 * reset path, exactly what AGENTS.md says not to leave lying around.
 * The PM watchdog is how a Pi actually reboots (it is what Linux's
 * bcm2835_restart does), and QEMU models the block
 * (hw/misc/bcm2835_powermgt.c), so the hardware-correct path is also
 * the testable one.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

enum {
	Rstc	= 0x1c/4,
	Rsts	= 0x20/4,
	Wdog	= 0x24/4,

	Password	= 0x5a000000,
	Wdogmask	= 0x000fffff,	/* Wdog counts in 65536ths of a second */

	Rstcwrcfgclr	= 0xffffffcf,	/* clear the WRCFG field */
	Rstcfullreset	= 0x00000020,	/* WRCFG = full reset on expiry */
	Rstcreset	= 0x00000102,	/* stop a running watchdog */

	Wdoghz		= 65536,	/* watchdog ticks per second */
};

static u32*
pm(void)
{
	return (u32*)PMBASE;
}

/*
 * Arm the watchdog to reset the machine in ms milliseconds.  Re-arming
 * before it expires is how a watchdog is kept fed.
 */
void
wdogset(int ms)
{
	u32 *r = pm();
	u32 ticks;

	ticks = ((uvlong)ms * Wdoghz) / 1000;
	if(ticks == 0)
		ticks = 1;
	if(ticks > Wdogmask)
		ticks = Wdogmask;
	r[Wdog] = Password | ticks;
	r[Rstc] = Password | (r[Rstc] & Rstcwrcfgclr) | Rstcfullreset;
}

void
wdogstop(void)
{
	u32 *r = pm();

	r[Rstc] = Password | Rstcreset;
}

/*
 * Reset the machine.  Arm the shortest watchdog the block will take and
 * wait for it; if the block is not answering, the caller's idle loop
 * takes over and the machine simply stops, which is the honest outcome
 * rather than pretending a reset happened.
 */
void
pmreset(void)
{
	wdogset(1);
}

/*
 * Probe the block without arming a reset.  Loading PM_WDOG is
 * harmless on its own: on real silicon nothing happens until PM_RSTC's
 * WRCFG field is set to full-reset, which is what starts the countdown.
 * So write the counter, read it back, and report -- this proves the
 * password-protected register write reaches the block, and it says
 * whether the emulator models a countdown at all.
 */
void
pminit(void)
{
	u32 *r = pm();
	u32 a, b;

	r[Wdog] = Password | (8 * Wdoghz);
	a = r[Wdog] & Wdogmask;
	delay(100);
	b = r[Wdog] & Wdogmask;
	if(a == 0){
		print("WDOG-FAIL counter reads 0 after a password write\n");
		return;
	}
	print("pm: watchdog at %#p loaded %ud, %ud after 100ms%s\n",
		(void*)PMBASE, a, b,
		b < a? " (counting) WDOG-OK": " (emulator: no countdown) WDOG-STATIC");
}
