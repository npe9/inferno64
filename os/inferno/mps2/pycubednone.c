#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/pycubedif.h"

/*
 * A PyCubed backend for a board that is not one.
 *
 * There is no ADM1176, no BMX160 and no RFM9x on an MPS2.  Every number
 * below is invented, and the "source" file of os/inferno/port/
 * devpycubed.c says so, so that a run cannot be mistaken for a reading.
 *
 * It is here rather than in port/ because it is this board's answer to
 * "what hardware is there", the way archmps2.c is this board's answer
 * to "how much memory".  A real PyCubed replaces this file and nothing
 * else: the device above it, the file protocol, and every line of Limbo
 * in appl/pycubed stay as they are.  That is what it is for.
 */

/*
 * The battery discharges so that the low-battery path in the mission's
 * vbatt task can be reached at all.  It is a ramp, not a measurement.
 */
static int vbatt = 4000;

static int
nonebattmv(void)
{
	if(vbatt > 3000)
		vbatt -= 40;
	return vbatt;
}

static void
nonergb(int r, int g, int b)
{
	print("\tpycubed-none: RGB %d %d %d\n", r, g, b);
}

static int
nonemag(int v[3])
{
	v[0] = v[1] = v[2] = 0;		/* no magnetometer to have a field */
	return 0;
}

static int
nonegyro(int v[3])
{
	v[0] = v[1] = v[2] = 0;		/* not turning */
	return 0;
}

static int
noneaccel(int v[3])
{
	v[0] = v[1] = 0;
	v[2] = 1000;			/* a board on a bench: 1g down */
	return 0;
}

static void
nonelisten(void)
{
	print("\tpycubed-none: radio listen\n");
}

static void
nonesleep(void)
{
	print("\tpycubed-none: radio sleep\n");
}

static int
nonesend(uchar *p, int n)
{
	print("\tpycubed-none: radio send %d bytes: %.*s\n", n, n, (char*)p);
	return n;
}

/*
 * Nothing is ever received.  A radio with no antenna and no
 * correspondent hears nothing, and inventing traffic would be
 * inventing a result rather than standing in for one.
 */
static int
nonerecv(uchar*, int)
{
	return 0;
}

static int
nonerssi(void)
{
	return -137;
}

static PycubedHw nonehw = {
	"pycubed-none: no hardware on this board, every reading is invented",
	nonebattmv,
	nonergb,
	nonemag,
	nonegyro,
	noneaccel,
	nonelisten,
	nonesleep,
	nonesend,
	nonerecv,
	nonerssi,
};

void
pycubedhwinit(void)
{
	pycubedhw = &nonehw;
}
