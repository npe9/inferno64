#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * What this board can tell the PyCubed mission about itself, as files
 * under #P.
 *
 * module/pycubedhw.m is the protocol and it is a directory of files,
 * not a module of functions: battery gives millivolts, imu gives three
 * lines of three axes, rgb takes three bytes.  os/inferno/mps2/
 * archfiles.c serves the same four names with every number invented,
 * which was the only thing possible on a board with no sensors and no
 * radio.  This is the same shape on a board that has some of the parts,
 * and the point of the "arch" file is to say WHICH.
 *
 * ONE OF THE THREE IS REAL HERE, and saying so precisely is the whole
 * value of this file.
 *
 *	battery  REAL.  adcbattmv() in adcstm32f4.c converts the
 *	         part's VBAT channel -- channel 18 through an internal
 *	         divide-by-two, RM0090 13.11 -- and returns millivolts.
 *	         On a clicker 2 with no coin cell on VBAT that is the
 *	         3.3V rail and reads about 3294, which is a voltage this
 *	         board actually has rather than a number from a plan.
 *	         It is NOT a flight battery: a PyCubed's is an ADM1176
 *	         on I2C measuring a LiPo, and this board has neither.
 *
 *	imu      INVENTED.  There is no inertial part on a clicker 2.
 *	         mikroBUS 1 is empty and #J already enumerates whatever
 *	         answers on I2C, so a 6DOF or 9DOF click would make this
 *	         real; until one is fitted the numbers are level and not
 *	         turning, which for a board on a bench is the one thing
 *	         that is true.
 *
 *	rgb      RECORDED, NOT DISPLAYED, and this is a deliberate
 *	         refusal rather than a shortcut.  A clicker 2 has two
 *	         LEDs, not three, and both already have owners:
 *	         ledstm32f4.c gives LD1 to the radio as its "a packet
 *	         arrived" lamp and idlehands() blinks LD2 as the
 *	         heartbeat.  Driving either from here would destroy a
 *	         working diagnostic to show a colour nobody is looking
 *	         at.  So the write is accepted and the last value is
 *	         readable, which exercises the path the mission uses and
 *	         costs nothing that was already there.
 *
 * The radio is not here and is not stood in for: it is #W/radio0, it is
 * real, and doc/radio-plan.ms is the measurement of it.
 */

static int rgbr, rgbg, rgbb;
static int rgbseen;

static s32
archsrcread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[256];

	snprint(buf, sizeof buf,
		"stm32f407: battery real, from the part's VBAT channel\n"
		"stm32f407: imu invented, no inertial part on this board\n"
		"stm32f407: rgb recorded not displayed, two LEDs and both owned\n"
		"stm32f407: radio real at #W/radio0\n");
	return readstr(offset, a, n, buf);
}

/*
 * Millivolts and nothing else, because that is what the protocol says
 * and a mission should not parse a five-line diagnostic to find one
 * figure.  #P/adc is still there for whoever wants all five channels.
 *
 * A converter that did not finish gives -1, which a caller can tell
 * from a voltage; inventing a plausible number here would be the one
 * thing this file exists not to do.
 */
static s32
battread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[32];
	extern int adcbattmv(void);

	snprint(buf, sizeof buf, "%d\n", adcbattmv());
	return readstr(offset, a, n, buf);
}

static s32
imuread(Chan*, void *a, s32 n, s64 offset)
{
	return readstr(offset, a, n,
		"mag 0 0 0\ngyro 0 0 0\naccel 0 0 1000\n");
}

static s32
rgbread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[64];

	if(!rgbseen)
		snprint(buf, sizeof buf, "nothing written\n");
	else
		snprint(buf, sizeof buf, "%d %d %d\n", rgbr, rgbg, rgbb);
	return readstr(offset, a, n, buf);
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
	rgbr = atoi(fld[0]);
	rgbg = atoi(fld[1]);
	rgbb = atoi(fld[2]);
	rgbseen = 1;
	return n;
}

void
archfilespycubedlink(void)
{
	addarchfile("arch", 0444, archsrcread, nil);
	addarchfile("battery", 0444, battread, nil);
	addarchfile("imu", 0444, imuread, nil);
	/*
	 * Readable as well as writable, unlike the mps2's, because here
	 * the value is kept rather than printed and a file that keeps a
	 * value and will not say it back is not worth having.
	 */
	addarchfile("rgb", 0666, rgbread, rgbwrite);
}
