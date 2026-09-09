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
 * Arm the watchdog, watch it count down, and stop it again.
 *
 * This is a real test of the block and it is deliberately not run at
 * boot.  If the stop does not take, the machine reboots 8 seconds
 * later and keeps doing so -- on a real Pi as much as under an
 * emulator -- so a kernel that arms a watchdog on every boot just to
 * look at it is a kernel that can brick its own boot.  Build with
 * -DWDOGSELFTEST to run it.
 */
#ifdef WDOGSELFTEST
static void
wdogselftest(u32 loaded)
{
	u32 *r = pm();
	u32 armed, stopped, after;

	r[Rstc] = Password | (r[Rstc] & Rstcwrcfgclr) | Rstcfullreset;
	delay(100);
	armed = r[Wdog] & Wdogmask;		/* armed: must be falling */

	wdogstop();
	stopped = r[Wdog] & Wdogmask;
	delay(100);
	after = r[Wdog] & Wdogmask;		/* stopped: must hold again */

	print("pm: armed %ud stopped %ud/%ud\n", armed, stopped, after);
	if(armed >= loaded)
		print("WDOG-FAIL armed counter did not fall\n");
	else if(after != stopped)
		print("WDOG-FAIL counter still running after stop\n");
	else
		print("WDOG-OK armed, counted down and stopped\n");
}
#endif

/*
 * Probe the block without arming a reset.
 *
 * Two things are checkable safely, and both are checked here.  A
 * password write must reach the counter, which a read-back proves.
 * And the counter must NOT move while the watchdog is disarmed: on
 * this SoC nothing counts until PM_RSTC's WRCFG field selects full
 * reset, so a counter that falls on its own is a broken block, and one
 * that holds still is behaving exactly as it should.
 */
void
pminit(void)
{
	u32 *r = pm();
	u32 loaded, idle;

	r[Wdog] = Password | (8 * Wdoghz);
	loaded = r[Wdog] & Wdogmask;
	if(loaded == 0){
		print("WDOG-FAIL counter reads 0 after a password write\n");
		return;
	}
	delay(100);
	idle = r[Wdog] & Wdogmask;
	print("pm: watchdog at %#p loaded %ud idle %ud\n",
		(void*)PMBASE, loaded, idle);
	if(idle != loaded){
		print("WDOG-FAIL counter ran while disarmed\n");
		return;
	}
	print("WDOG-PRESENT loaded and holding while disarmed\n");
#ifdef WDOGSELFTEST
	wdogselftest(loaded);
#endif
}
