#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"

/*
 * The part's own serial number, at #P/uid.
 *
 * WHY A BOARD NEEDS A NAME, AND WHY THIS IS IT.
 *
 * Every calibration this bench has measured belongs to one board and
 * not to the kernel: the crystal error, the RSSI offset, the carrier
 * sense threshold.  spistm32f4.c carries ".ppb = -3550, measured on
 * this board and not taken from anywhere" -- and with two boards here
 * that comment became a bug, because the second one wants +60300 and no
 * single image can be right for both.  Either every board gets its own
 * image, which is a flash cycle per measurement and a kernel that is
 * wrong on the bench next door, or the image carries the calibrations
 * for every board it knows and each board picks its own.  The second
 * wants an identity, and asking the board to remember a name it was
 * told is circular -- the thing that would tell it is what needs to
 * know.
 *
 * An STM32F4 has one in silicon.  RM0090 section 39.1: a 96-bit unique
 * device ID at 0x1fff7a10, three 32-bit words, read-only, programmed at
 * the factory and different on every part.  Nothing writes it and
 * nothing can, so it is the one fact about this board that survives a
 * reflash, a bootloader and an empty flash.
 *
 * Printed as twenty-four hex digits, most significant word first, so it
 * sorts and compares as a string and can be the key of an attrdb(6)
 * entry without any arithmetic.  See doc/radio-plan.ms item 8 and
 * ndb(6).
 */

enum {
	Uidbase	= 0x1fff7a10,	/* RM0090 39.1, 96 bits */
	Uidwords = 3,
};

static s32
uidread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[32];
	volatile u32 *u;
	int i;
	char *p;

	u = (u32*)Uidbase;
	p = buf;
	/*
	 * Most significant word first.  The order is a choice and this
	 * one is recorded rather than left to whoever reads it next: a
	 * number written the other way round is a different name for the
	 * same board, and an entry keyed on it would silently miss.
	 */
	for(i = Uidwords-1; i >= 0; i--)
		p += snprint(p, sizeof buf - (p - buf), "%.8ux", u[i]);
	*p++ = '\n';
	*p = 0;
	return readstr(offset, a, n, buf);
}

void
uidstm32f4link(void)
{
	addarchfile("uid", 0444, uidread, nil);
}
