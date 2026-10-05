#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/i2c.h"

/*
 * A BMX160 inertial measurement unit at #P/imu, with a scripted
 * simulation behind it until a part answers.
 *
 * WHICH HALF IS WHICH, because this file is both and a reader has to be
 * able to tell:
 *
 *	THE I2C HALF IS REAL CODE AND UNEXERCISED.  The register numbers
 *	below are from the BMX160 datasheet and have never been read off
 *	a part on this bench, because there is no inertial part on a
 *	clicker 2.  They are named rather than spelled inline so that
 *	checking them against the datasheet is one pass down one table.
 *	Nothing claims the part exists: imuprobe() reads CHIP_ID and
 *	refuses unless it reads 0xd8, so a wrong address, a bus with
 *	nothing on it, or a different Bosch part all come out as "no
 *	part" rather than as plausible numbers.
 *
 *	THE SIMULATION IS SCRIPTED AND SAYS SO.  #P/arch names it, and
 *	#P/imuctl drives it.  It is a fixture for the flight software
 *	above -- doc/pycubed-plan.ms phase 4, which wants an IMU to react
 *	to -- and not a stand-in for a measurement.  No number out of it
 *	is evidence about anything physical.
 *
 * WHEN THE PART ARRIVES nothing here changes but which branch runs:
 * the probe finds it, imuread() takes the datasheet path, and #P/arch
 * says "real" instead of "scripted".  One image works before and after,
 * which is the point of writing it this way round.
 *
 * THE MOTION MODEL, because a static reading exercises nothing.  The
 * body turns at a configurable rate about one axis; gravity is a
 * constant vector in the world and therefore sweeps round the body
 * frame as it turns, which is what an accelerometer on a tumbling
 * satellite sees and is the signal a detumble controller is looking
 * for.  The magnetometer sweeps with it, ninety degrees out.  The
 * gyroscope reads the rate itself.  Every axis gets independent noise,
 * because a reading without error is the one thing a real sensor never
 * gives and software that has only ever seen clean data has not been
 * tested.
 *
 *	echo spin 0 0 30 >/dev/imu.ctl	30 deg/s about z
 *	echo still >/dev/imu.ctl		stop, level
 *	echo tumble >/dev/imu.ctl	a representative three-axis rate
 *	echo noise 20 >/dev/imu.ctl	+-20 milli-units of error
 *	echo real >/dev/imu.ctl		try the probe again
 */

enum {
	/*
	 * BMX160 register map.  From the datasheet; see the warning
	 * above about what that means here.
	 */
	Addr		= 0x68,		/* 0x69 with SDO high */
	Rchipid		= 0x00,		/*   reads 0xd8 */
	  Bmx160id	= 0xd8,
	Rmagx		= 0x04,		/* 6 bytes, little endian */
	Rgyrx		= 0x0c,		/* 6 bytes */
	Raccx		= 0x12,		/* 6 bytes */
	Rcmd		= 0x7e,
	  Cmdaccnorm	= 0x11,		/* accelerometer to normal mode */
	  Cmdgyrnorm	= 0x15,
	  Cmdmagnorm	= 0x19,

	/*
	 * Full-scale defaults after a soft reset, which decide the
	 * conversion to the milli-units module/pycubedhw.m asks for:
	 * +-2g over 16 bits is 16384 counts to a g, and +-2000 deg/s is
	 * 16.4 counts to a degree.  Both are datasheet figures.
	 */
	Accperg		= 16384,
	Gyrperdeg	= 164,		/* tenths, so divide by 10 */

	Grav		= 1000,		/* milli-g, what level reads */
	Field		= 450,		/* milli-gauss, a plausible earth field */
};

/* one quarter of a sine, in milli-units, every five degrees */
static short sintab[19] = {
	0, 87, 174, 259, 342, 423, 500, 574, 643, 707,
	766, 819, 866, 906, 940, 966, 985, 996, 1000,
};

static int
isin(int deg)
{
	int q, i, f, a, b;

	deg %= 360;
	if(deg < 0)
		deg += 360;
	if(deg >= 180)
		return -isin(deg - 180);
	if(deg > 90)
		deg = 180 - deg;
	i = deg / 5;
	f = deg % 5;
	a = sintab[i];
	b = sintab[i+1 > 18? 18: i+1];
	q = a + ((b - a) * f) / 5;
	return q;
}

/*
 * Not static: pwradm1176.c asks for it, because the sun on a panel is
 * the cosine of the same angle this file tracks and two tables would be
 * two things to get wrong.
 */
int
icos(int deg)
{
	return isin(deg + 90);
}

static I2Cdev *imudev;
static int triedprobe;

/* the scripted state */
static int ratex, ratey, ratez;		/* milli-degrees per second */
static int noise = 10;			/* milli-units, peak */
static int angle;			/* degrees, about the spin axis */
static ulong lastticks;

/*
 * THE ACTUATOR, AND WHY THE MODEL NEEDED ONE.
 *
 * Until now this file reported a tumble and nothing could do anything
 * about it: the rate was whatever #P/imu.ctl was last told, so the
 * mission could read the IMU all day and never change it.  A sensor
 * nothing can act on is a fixture.  A sensor whose reading responds to
 * an actuator is a model, and the difference is the whole point of
 * giving the flight software something to control.
 *
 * So: three magnetorquers, as a commanded dipole in milli-A.m^2 on
 * #P/torque, and the rate responds to them.
 *
 * THE PHYSICS, HONESTLY.  A dipole m in a field B feels a torque
 * m x B, and the rate changes by that torque over the moment of
 * inertia.  What is here is first order and deliberately crude: one
 * scalar inertia instead of a tensor, no cross-coupling between axes,
 * no gravity gradient, no residual dipole, and the field treated as
 * constant in magnitude.  A controller tuned against this is tuned
 * against arithmetic, not against a spacecraft.
 *
 * WHAT IT IS FAITHFUL ABOUT is the SIGN and the SHAPE: a dipole
 * opposing the field's rate of change takes energy out of the tumble,
 * which is what B-dot control is, and the rate falls off roughly
 * exponentially as a real detumble does.  That is enough to tell a
 * controller that works from one that drives the rate up, which is the
 * failure mode worth catching on the ground.
 */
static int torqx, torqy, torqz;		/* commanded dipole, milli-A.m^2 */
static int inertia = 2000;		/* scaled; see spin() below */

/*
 * The torque the commanded dipole makes, applied for dt ticks.
 *
 * m x B with the field along x in the body frame at angle 0 -- which is
 * how imuread below reports the magnetometer -- gives a z torque from
 * my and a y torque from mz, with the sign of the cross product.  The
 * rate is in milli-degrees a second and the dipole in milli-A.m^2, so
 * inertia is a scale factor chosen to make a plausible dipole detumble
 * a plausible rate in a minute or two rather than a figure with units.
 * It is named so that it is clear it is a knob and not a measurement.
 */
static void
spin(ulong dt)
{
	int bx, by, tx, ty, tz;
	long ms;

	ms = ((long)dt * 1000) / HZ;
	if(ms <= 0)
		return;
	bx = Field * icos(angle) / 1000;
	by = -Field * isin(angle) / 1000;
	/* m x B, with Bz = 0 */
	tx = -torqz * by;
	ty = torqz * bx;
	tz = torqx * by - torqy * bx;
	ratex += (int)((long)tx * ms / (1000L * inertia));
	ratey += (int)((long)ty * ms / (1000L * inertia));
	ratez += (int)((long)tz * ms / (1000L * inertia));
}

/*
 * Bring the model up to now: the torque for however long it has been,
 * then the attitude over the same interval.
 *
 * IN ONE PLACE AND CALLED BY BOTH FILES, which is the fix for an
 * instrument that lied.  This was inlined in imuread, so the model
 * advanced only when #P/imu was read -- and #P/imu.ctl, which exists
 * to report the model's state, showed whatever was true at the last
 * read of the OTHER file.  Probing the torque law through the ctl file
 * therefore showed "spin 0 0 20000, angle 157" three times, three
 * seconds apart, with a rate that never moved: which reads as a model
 * that ignores its actuator, and is a model nobody had advanced.
 *
 * The motion is a function of time and not of how often anybody looks,
 * which is the property worth having and the reason elapsed ticks drive
 * it rather than a count of reads.
 */
static void
advance(void)
{
	ulong t, dt;

	t = m != nil? m->ticks: 0;
	dt = t - lastticks;
	lastticks = t;
	if(dt > 100*60)			/* first call, or a long gap */
		return;
	spin(dt);
	angle += (int)((ratez * (long)dt) / (HZ * 1000));
	angle %= 360;
}

static int
jitter(void)
{
	if(noise <= 0)
		return 0;
	return nrand(2*noise + 1) - noise;
}

/*
 * CHIP_ID or nothing.  A part that does not identify itself is not this
 * part, whatever else answered at the address.
 */
static int
imuprobe(void)
{
	I2Cbus *bus;
	int id;

	if(triedprobe)
		return imudev != nil;
	triedprobe = 1;
	/*
	 * mikroBUS 1's I2C, which is the socket a click would go in: the
	 * ccRF click is in socket 2.  i2cbus() probes the bus as a side
	 * effect, which is what registers the devices i2cdev() looks up.
	 */
	bus = i2cbus("i2c3");
	if(bus == nil)
		return 0;
	imudev = i2cdev(bus, Addr);
	if(imudev == nil)
		return 0;
	id = i2creadbyte(imudev, Rchipid);
	if(id != Bmx160id){
		print("imu: 0x%.2x answered at 0x%.2x but CHIP_ID is 0x%.2x,"
			" not a BMX160's 0x%.2x\n", Addr, Addr, id, Bmx160id);
		imudev = nil;
		return 0;
	}
	/* the three sensors come out of reset suspended */
	i2cwritebyte(imudev, Rcmd, Cmdaccnorm);
	i2cwritebyte(imudev, Rcmd, Cmdgyrnorm);
	i2cwritebyte(imudev, Rcmd, Cmdmagnorm);
	print("imu: BMX160 at 0x%.2x on i2c3\n", Addr);
	return 1;
}

/*
 * le16 and not s16: u.h already has s16 as a typedef, and a static
 * function of that name compiles until something includes both.
 */
static int
le16(uchar *p)
{
	return (short)(p[0] | (p[1] << 8));
}

/*
 * One pass over all three sensors, so that the nine numbers belong to
 * one instant.  That is why the file gives three lines on one read
 * rather than three files: module/pycubedhw.m says so, and the reason
 * is that three opens could straddle a motion.
 */
static s32
imuread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[160];
	uchar raw[18];
	int mx, my, mz, gx, gy, gz, ax, ay, az;

	if(imuprobe()){
		if(i2crecv(imudev, raw, sizeof raw, Rmagx) != sizeof raw)
			error("imu: short read");
		mx = le16(raw+0); my = le16(raw+2); mz = le16(raw+4);
		/* raw+6 is RHALL, the magnetometer's hall resistance */
		gx = le16(raw+8); gy = le16(raw+10); gz = le16(raw+12);
		ax = le16(raw+14);
		/*
		 * Only four of the six accelerometer bytes are in this
		 * window, so the last axis is a second transfer rather
		 * than a guess.  Spelled out because an off-by-one in a
		 * burst read gives axes that look like axes.
		 */
		{
			uchar z[2];

			if(i2crecv(imudev, z, 2, Raccx+4) != 2)
				error("imu: short read");
			az = le16(z);
		}
		ay = le16(raw+16);
		ax = (ax * Grav) / Accperg;
		ay = (ay * Grav) / Accperg;
		az = (az * Grav) / Accperg;
		/*
		 * MILLI-degrees a second, which is what
		 * module/pycubedhw.m asks for and what both halves of
		 * this file used to get wrong: they divided to whole
		 * degrees, so the protocol said milli-units and the
		 * file delivered units.
		 *
		 * It mattered.  The scripted half then added its noise
		 * -- documented in milli-units, ten of them -- to a
		 * value in whole degrees, which is plus or minus ten
		 * DEGREES a second on a rate of twenty.  A detumble
		 * controller watching that sees no trend at all, and the
		 * first run of one read 14, 22, 26, 18, 28 and 34 while
		 * the rate underneath it was falling.
		 */
		gx = (gx * 10000) / Gyrperdeg;
		gy = (gy * 10000) / Gyrperdeg;
		gz = (gz * 10000) / Gyrperdeg;
	}else{
		advance();

		/* milli-degrees a second, the units the protocol names */
		gx = ratex + jitter();
		gy = ratey + jitter();
		gz = ratez + jitter();
		/*
		 * Gravity in the body frame as it turns about z: when the
		 * spin is about the axis gravity lies along, the vector
		 * does not sweep, so this tilts it thirty degrees first.
		 * Otherwise a "spin 0 0 30" would look like no motion at
		 * all to an accelerometer, which is true of the physics
		 * and useless as a fixture.
		 */
		ax = (Grav * isin(30) / 1000) * icos(angle) / 1000 + jitter();
		ay = (Grav * isin(30) / 1000) * isin(angle) / 1000 + jitter();
		az = Grav * icos(30) / 1000 + jitter();
		mx = Field * icos(angle) / 1000 + jitter();
		my = -Field * isin(angle) / 1000 + jitter();
		mz = jitter();
	}

	snprint(buf, sizeof buf,
		"mag %d %d %d\ngyro %d %d %d\naccel %d %d %d\n",
		mx, my, mz, gx, gy, gz, ax, ay, az);
	return readstr(offset, a, n, buf);
}

static s32
imuctlread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[256];

	advance();

	snprint(buf, sizeof buf,
		"source %s\n"
		"spin %d %d %d\n"
		"noise %d\n"
		"angle %d\n"
		"torque %d %d %d\n"
		"inertia %d\n",
		imudev != nil? "bmx160": "scripted",
		ratex, ratey, ratez, noise, angle,
		torqx, torqy, torqz, inertia);
	return readstr(offset, a, n, buf);
}

static s32
imuctlwrite(Chan*, void *a, s32 n, s64)
{
	char buf[64], *fld[5];
	int nf;

	if(n >= sizeof buf)
		error(Ebadarg);
	memmove(buf, a, n);
	buf[n] = 0;
	nf = tokenize(buf, fld, nelem(fld));
	if(nf < 1)
		error(Ebadarg);
	if(strcmp(fld[0], "spin") == 0 && nf == 4){
		ratex = atoi(fld[1]) * 1000;
		ratey = atoi(fld[2]) * 1000;
		ratez = atoi(fld[3]) * 1000;
	}else if(strcmp(fld[0], "still") == 0 && nf == 1){
		ratex = ratey = ratez = 0;
		angle = 0;
	}else if(strcmp(fld[0], "tumble") == 0 && nf == 1){
		/*
		 * A rate worth detumbling: a CubeSat off a deployer
		 * tumbles at a few degrees a second to a few tens, and
		 * three unequal axes is what makes it a tumble rather
		 * than a spin.
		 */
		ratex = 7000;
		ratey = -11000;
		ratez = 23000;
	}else if(strcmp(fld[0], "noise") == 0 && nf == 2){
		noise = atoi(fld[1]);
		if(noise < 0)
			noise = 0;
	}else if(strcmp(fld[0], "real") == 0 && nf == 1){
		/* try the bus again, for a part plugged in since boot */
		triedprobe = 0;
		imudev = nil;
		imuprobe();
	}else
		error(Ebadctl);
	return n;
}

static s32
torqueread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[96];

	snprint(buf, sizeof buf, "%d %d %d\n", torqx, torqy, torqz);
	return readstr(offset, a, n, buf);
}

static s32
torquewrite(Chan*, void *a, s32 n, s64)
{
	char buf[64], *fld[4];

	if(n >= sizeof buf)
		error(Ebadarg);
	memmove(buf, a, n);
	buf[n] = 0;
	if(tokenize(buf, fld, nelem(fld)) != 3)
		error(Ebadarg);
	torqx = atoi(fld[0]);
	torqy = atoi(fld[1]);
	torqz = atoi(fld[2]);
	return n;
}

/*
 * Where the body is pointing, for whoever cares about sun on a panel.
 * pwradm1176.c asks: a tumbling satellite charges intermittently and a
 * pointed one charges steadily, which is the loop that makes attitude
 * control worth doing rather than merely possible.
 */
int
imuattitude(void)
{
	return angle;
}

int
imurate(void)
{
	int r;

	/* the magnitude that matters to a detumble, in milli-degrees/s */
	r = ratex < 0? -ratex: ratex;
	if((ratey < 0? -ratey: ratey) > r)
		r = ratey < 0? -ratey: ratey;
	if((ratez < 0? -ratez: ratez) > r)
		r = ratez < 0? -ratez: ratez;
	return r;
}

void
imubmx160link(void)
{
	addarchfile("imu", 0444, imuread, nil);
	addarchfile("imu.ctl", 0666, imuctlread, imuctlwrite);
	/*
	 * The magnetorquers.  Readable as well as writable, because a
	 * controller that cannot read back what it commanded cannot tell
	 * a write that was refused from one that did nothing.
	 */
	addarchfile("torque", 0666, torqueread, torquewrite);
}
