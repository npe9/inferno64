#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * What this board can tell Limbo about itself, as files under #P.
 *
 * On a PyCubed these would be the ADM1176 power monitor and the BMX160
 * IMU over I2C, and the mainboard LED on a GPIO; see doc/pycubed-
 * plan.ms for what every part of that board maps to.  On an MPS2 there
 * is none of it, so every number below is invented and the "arch" file
 * says so.  They are here to exercise the path -- addarchfile(), the
 * device, the Limbo that opens the files -- on the one board that can
 * be run, and to hold the shape a real driver has to meet.
 *
 * This is not a driver, and it is not the PyCubed's radio or its SD
 * card: those map to devether and devsd, which are different mechanisms
 * and are not stood in for here.
 */

static int vbatt = 4000;	/* millivolts, ramped so a low-battery path runs */

static s32
archsrcread(Chan*, void *a, s32 n, s64 offset)
{
	return readstr(offset, a, n,
		"mps2: no sensors on this board, every reading is invented\n");
}

static s32
battread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[32];

	if(vbatt > 3000)
		vbatt -= 40;
	snprint(buf, sizeof buf, "%d\n", vbatt);
	return readstr(offset, a, n, buf);
}

/*
 * One read, three lines: the three axes of each sensor come from one
 * pass, rather than three opens that could straddle a motion.  Still,
 * level and not turning, which for a board on a bench is the one thing
 * that would be true.
 */
static s32
imuread(Chan*, void *a, s32 n, s64 offset)
{
	return readstr(offset, a, n,
		"mag 0 0 0\ngyro 0 0 0\naccel 0 0 1000\n");
}

static s32
rgbwrite(Chan*, void *a, s32 n, s64)
{
	char buf[32], *fld[4];

	if(n >= sizeof buf)
		error(Ebadarg);
	memmove(buf, a, n);
	buf[n] = 0;
	if(tokenize(buf, fld, nelem(fld)) != 3)
		error(Ebadarg);
	print("\tmps2: RGB %s %s %s\n", fld[0], fld[1], fld[2]);
	return n;
}

void
archfilesinit(void)
{
	addarchfile("arch", 0444, archsrcread, nil);
	addarchfile("battery", 0444, battread, nil);
	addarchfile("imu", 0444, imuread, nil);
	addarchfile("rgb", 0222, nil, rgbwrite);
}
