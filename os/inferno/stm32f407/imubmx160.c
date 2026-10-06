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
 *	echo inertia 200 >/dev/imu.ctl	how briskly a dipole turns it
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
/*
 * 200 and not 2000, which is the difference between a demonstration
 * somebody can watch and one they cannot.
 *
 * It is a scale and not a measurement -- one scalar where a spacecraft
 * has a tensor -- so what it is really setting is how briskly a
 * plausible dipole turns a plausible satellite.  At 2000 a 23 deg/s
 * tumble took four minutes to reach 9 and would have taken twenty to
 * settle; at 200 the same control settles it in about a minute, which
 * is the same argument the discharge curve in pwradm1176.c makes for
 * being deliberately fast.  A 1U CubeSat is a kilogram and ten
 * centimetres, so brisk is not the unphysical end of the range.
 *
 * Settable from #P/imu.ctl, because the right figure for a fixture and
 * the right figure for a plausible spacecraft are not the same number
 * and the file should not pretend otherwise.
 */
static int inertia = 200;

/*
 * THE MODEL, AS THREE VECTORS IN THE BODY FRAME.
 *
 * This was an angle about one axis and a pair of sines, and that was
 * not merely crude -- it was wrong in the way that broke the thing it
 * existed for.  The field responded only to rotation about z, so B-dot
 * could damp only z: a three-axis tumble of (7, -11, 23) degrees a
 * second fell to exactly 11.0 and stopped there, because two of the
 * three rates moved nothing the magnetometer could see.  Measured, and
 * it reads as a controller that stalls.
 *
 * The right model is simpler than the wrong one.  The field, gravity
 * and the sun are all FIXED IN THE WORLD; what turns is the body.  So
 * in the body frame each of them obeys
 *
 *	dv/dt = -omega x v
 *
 * which is three multiplies and no trigonometry, and which responds to
 * rotation about every axis because that is what a cross product does.
 * B-dot then damps all three, as it does on a spacecraft.
 *
 * Integer arithmetic in milli-units with omega in milli-degrees a
 * second: the 17453 below is pi/180 scaled by a million.  The products
 * reach 10^13, so the intermediate is a vlong -- this part has no
 * divider worth avoiding that for, and a wrong answer is dearer than a
 * slow one.
 *
 * STILL NOT A SPACECRAFT: one scalar inertia rather than a tensor, so a
 * torque about x and one about z cost the same; no gravity gradient, no
 * residual dipole, no eddy damping, and the sun never sets unless the
 * charger is told it has.  What it is faithful about is that every axis
 * is reachable and that energy only leaves the tumble when the dipole
 * opposes dB/dt.
 */
enum {
	Degtomicrorad	= 17453,	/* pi/180 * 1e6 */
};

/* body-frame vectors, milli-units, renormalised to these magnitudes */
static int fb[3] = { Field, 0, 0 };		/* the field */
static int gb[3] = { 0, 0, Grav };		/* gravity */
static int sb[3] = { 1000, 0, 0 };		/* the sun, a unit vector */

/*
 * v -= (omega x v) dt, with omega in milli-degrees a second and dt in
 * ticks, then renormalised -- because integer steps SHORTEN a vector
 * that should only turn, and a magnetometer whose field decays hands a
 * controller a dB/dt that is partly nothing to do with rotation.
 */
static void
turn(int *v, int nominal, ulong dt)
{
	vlong c[3], q;
	int i, mag;

	c[0] = (vlong)ratey * v[2] - (vlong)ratez * v[1];
	c[1] = (vlong)ratez * v[0] - (vlong)ratex * v[2];
	c[2] = (vlong)ratex * v[1] - (vlong)ratey * v[0];
	for(i = 0; i < 3; i++)
		v[i] -= (int)((c[i] * (vlong)dt * Degtomicrorad)
			/ ((vlong)HZ * 1000000000));
	q = 0;
	for(i = 0; i < 3; i++)
		q += (vlong)v[i] * v[i];
	if(q <= 0){
		/* collapsed: put it back rather than divide by zero */
		v[0] = nominal;
		v[1] = v[2] = 0;
		return;
	}
	mag = 1;
	while((vlong)mag * mag < q)
		mag++;
	for(i = 0; i < 3; i++)
		v[i] = (int)(((vlong)v[i] * nominal) / mag);
}

/*
 * The torque a commanded dipole makes in the field as it now stands,
 * for dt ticks.  T = m x B, and the rate changes by T over the moment
 * of inertia.
 */
static void
spin(ulong dt)
{
	long ms;
	int tx, ty, tz;

	ms = ((long)dt * 1000) / HZ;
	if(ms <= 0)
		return;
	tx = torqy * fb[2] - torqz * fb[1];
	ty = torqz * fb[0] - torqx * fb[2];
	tz = torqx * fb[1] - torqy * fb[0];
	ratex += (int)((long)tx * ms / (1000L * inertia));
	ratey += (int)((long)ty * ms / (1000L * inertia));
	ratez += (int)((long)tz * ms / (1000L * inertia));
}

/*
 * Bring the model up to now: the torque for however long it has been,
 * then every vector turned over the same interval.
 *
 * IN ONE PLACE AND CALLED BY BOTH FILES, which is the fix for an
 * instrument that lied.  This was inlined in imuread, so the model
 * advanced only when #P/imu was read -- and #P/imu.ctl, which exists to
 * report the model's state, showed whatever was true at the last read
 * of the OTHER file.  Probing the torque law through the ctl file
 * therefore showed a rate that never moved, which reads as a model
 * ignoring its actuator and is a model nobody had advanced.
 *
 * The motion is a function of time and not of how often anybody looks.
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
	turn(fb, Field, dt);
	turn(gb, Grav, dt);
	turn(sb, 1000, dt);
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
		mx = fb[0] + jitter();
		my = fb[1] + jitter();
		mz = fb[2] + jitter();
		ax = gb[0] + jitter();
		ay = gb[1] + jitter();
		az = gb[2] + jitter();
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
		"field %d %d %d\n"
		"sun %d %d %d\n"
		"torque %d %d %d\n"
		"inertia %d\n",
		imudev != nil? "bmx160": "scripted",
		ratex, ratey, ratez, noise,
		fb[0], fb[1], fb[2], sb[0], sb[1], sb[2],
		torqx, torqy, torqz, inertia);
	return readstr(offset, a, n, buf);
}

static s32
imuctlwrite(Chan*, void *a, s32 n, s64)
{
	char buf[64], *fld[5];
	int nf, v;

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
		fb[0] = Field; fb[1] = fb[2] = 0;
		gb[0] = gb[1] = 0; gb[2] = Grav;
		sb[0] = 1000; sb[1] = sb[2] = 0;
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
	}else if(strcmp(fld[0], "inertia") == 0 && nf == 2){
		v = atoi(fld[1]);
		if(v < 1)
			error(Ebadarg);
		advance();
		inertia = v;
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
 * Where the sun is, in the body frame, as a unit vector in milli-units.
 *
 * The PANEL GEOMETRY is not here: it belongs to whatever converts sun
 * into current, which is pwradm1176.c.  This is the attitude and
 * nothing else.
 *
 * It was a single milli-cosine against body +x, and that had a flaw
 * worth recording because it is a real spacecraft problem and not an
 * arithmetic one: one panel on one face reads ZERO over a whole
 * hemisphere, so a controller hill-climbing on its current has no
 * gradient to climb for half of all attitudes.  Measured -- the sun
 * task reported "0mA of 260" on every sample and turned one way for
 * ever, because nothing it did changed the number it was steering by.
 * And the single-axis torque it commands cannot fix that: rotating
 * about body z never moves a sun vector that lies along z.
 */
void
imusunvec(int *v)
{
	advance();
	v[0] = sb[0];
	v[1] = sb[1];
	v[2] = sb[2];
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
