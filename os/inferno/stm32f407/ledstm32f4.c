#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"

/*
 * The board's two lamps as a file, at #P/led.
 *
 * WHY.  A clicker 2 has LD1 on PE12 and LD2 on PE15, and until now the
 * only way anything outside the kernel could move one was the radio's
 * own ctl file, through its "led" verb.  That put the indicator
 * downstream of the thing most likely to have failed: a board that
 * cannot find its radio cannot use the lamp to say so.
 *
 * That is not hypothetical.  A second board was flashed with
 * os/inferno/init/armv7mbeacon.b, whose whole purpose is to be useful
 * with no console, and it sat with LD1 solid.  Solid is also where
 * archreset() leaves LD1 at boot, so it meant any of: the radio was not
 * found, a configuration write failed, the data file would not open, or
 * the loop was running and the led write itself was failing.  Four
 * states and one picture, and the cause turned out to be the first --
 * the clicks were in each other's sockets, so cc1120init() found
 * nothing on SPI2 and there was no ctl file to write "led" to at all.
 * An hour went into guessing at that, and a lamp reachable without the
 * radio would have answered it in one reset.
 *
 * devarch.c's own comment lists what #P is for -- "a sensor, a voltage,
 * an LED, anything small and particular to the machine" -- so this is
 * the mechanism working as intended rather than a new one.
 *
 * WHAT IT DOES NOT SOLVE.  LD2 is blinked by idlehands() every fifty
 * ticks, so anything written to it is overwritten within half a second;
 * it is readable here and writable only in the sense that the write
 * succeeds.  LD1 is the radio's lamp whenever a radio was found, and
 * then two writers share it.  Neither is worth locking out: the point
 * is the case where there is no radio, and there LD1 is nobody's.
 *
 *	; echo 1 on >'#P/led'
 *	; echo 2 off >'#P/led'
 *	; cat '#P/led'
 *	1 on
 *	2 off
 *
 * The state read back is the pin's own output register and not a
 * variable kept here, so it does not drift from the hardware and it
 * reports what the radio or idlehands() did as readily as what was
 * written through this file.
 *
 * VERIFIED under qemu: a read gives "1 on / 2 on", "echo 1 off" then
 * reads back "1 off", "echo 1 on" reads back "1 on", and both error
 * paths answer -- "echo 3 on" gives "this board has two lamps, 1 and 2"
 * and "echo 1 sideways" gives "a lamp is on or off".  The second lamp
 * read "on" and then "off" across two of those reads without anything
 * having written it, which is idlehands() blinking it and is the proof
 * that the read is the register and not a variable.
 */

enum
{
	Ld1	= 12,
	Ld2	= 15,
};

static s32
ledread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[32];
	ulong odr;

	odr = *(volatile ulong*)(GPIOE+GPIO_ODR);
	snprint(buf, sizeof buf, "1 %s\n2 %s\n",
		(odr & (1UL<<Ld1))? "on": "off",
		(odr & (1UL<<Ld2))? "on": "off");
	return readstr(offset, a, n, buf);
}

static s32
ledwrite(Chan*, void *a, s32 n, s64)
{
	Cmdbuf *cb;
	int pin, on;

	/*
	 * Initialised because kencc's flow analysis does not know that
	 * error() never returns, and warns "used and not set" for both.
	 * The values are never reached; the error() calls below leave.
	 */
	pin = Ld1;
	on = 0;

	cb = parsecmd(a, n);
	if(waserror()){
		free(cb);
		nexterror();
	}
	if(cb->nf != 2)
		error("usage: <1|2> <on|off>");
	if(strcmp(cb->f[0], "1") == 0)
		pin = Ld1;
	else if(strcmp(cb->f[0], "2") == 0)
		pin = Ld2;
	else
		error("this board has two lamps, 1 and 2");
	if(strcmp(cb->f[1], "on") == 0)
		on = 1;
	else if(strcmp(cb->f[1], "off") == 0)
		on = 0;
	else
		error("a lamp is on or off");
	ledpin(pin, on);
	poperror();
	free(cb);
	return n;
}

void
ledstm32f4link(void)
{
	addarchfile("led", 0664, ledread, ledwrite);
}
