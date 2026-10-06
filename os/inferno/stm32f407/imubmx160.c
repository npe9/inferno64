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
 *	echo inertia 33333 33333 6667 >/dev/imu.ctl  the tensor,
 *					micro-kg.m^2, a 3U by default
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
	/*
	 * There was a Field here, 450 milligauss, "a plausible earth
	 * field".  There is nothing plausible about one number for it:
	 * the field is 247 milligauss at the magnetic equator at 500km
	 * and twice that at the poles, and a magnetic controller's whole
	 * difficulty is that it varies.  orbitsim.c holds it now and
	 * this file rotates it into the body frame.
	 */
};

/*
 * The trigonometry lives in orbitsim.c now -- a one-degree table there
 * rather than a five-degree one here -- and this file needs none of it:
 * an attitude is a quaternion and a sensor reading is a rotation, so
 * there is no angle to take a sine of.  The square root is a different
 * matter: the quaternion is renormalised on every integration step.
 */
extern long msqrt(vlong);
extern void orbitfield(int*), orbitsun(int*), orbitnadir(int*);
extern int orbitgg(void), orbittimescale(void), orbiteclipse(void);

static I2Cdev *imudev;
static int triedprobe;

/*
 * The scripted state.  ratex..z are DERIVED from the momentum and the
 * attitude on every step rather than integrated; they are kept as
 * variables because the gyroscope reports them and the quaternion
 * update needs them, not because anything accumulates in them.
 */
static int ratex, ratey, ratez;		/* milli-degrees per second */
static int noise = 10;			/* milli-units, peak */
static ulong lastticks;
static int running;

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
 * THE PHYSICS.  A dipole m in a field B feels a torque m x B, and the
 * rate follows Euler's equations for a rigid body with an inertia
 * tensor -- including omega x (I omega), the term that makes an
 * asymmetric satellite precess rather than spin tidily.  The field,
 * the sun and the nadir come from orbitsim.c, which puts the satellite
 * in a real orbit: the field varies by a factor of two and sweeps twice
 * a pass, because that is what a magnetic controller contends with.
 *
 * WHAT IS STILL NOT MODELLED, and each is a decision rather than an
 * omission: no residual magnetic dipole of the spacecraft itself, no
 * eddy-current damping in the structure, no aerodynamic torque (which
 * at 500km is comparable to the gravity gradient and would want a
 * density model and an attitude-dependent area), no flexible modes, and
 * no sensor bias or scale-factor error -- only white noise.  The
 * integration is first order in both the rate and the quaternion, which
 * is what bounds the time scale.
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


/*
 * THE ATTITUDE, AS A QUATERNION AND A RATE, WITH A REAL INERTIA TENSOR.
 *
 * Two versions of this were wrong before this one and both were wrong
 * in ways that let a controller run.
 *
 * The first was an angle about one axis: the field responded only to
 * rotation about z, so B-dot could damp only z and a three-axis tumble
 * fell to exactly 11.0 deg/s and stopped.
 *
 * The second carried the field, gravity and the sun as three separate
 * body-frame vectors, each turned by -omega x v and renormalised on its
 * own.  That responds to every axis and is still not an attitude: three
 * vectors drifting independently stop being orthogonal, so the frame
 * they describe is not a rotation of anything, and nothing in the
 * simulation held a POSITION at all -- the field had constant magnitude
 * and never swept, which is the opposite of what a magnetic controller
 * contends with.
 *
 * This one holds the thing that is actually physical: a rotation from
 * the inertial frame to the body, as a quaternion, and a body rate.
 * Everything a sensor reads is an inertial vector from orbitsim.c
 * rotated through it, so the frame is orthogonal by construction and
 * the field varies because the satellite is somewhere.
 *
 * THE STATE IS THE ANGULAR MOMENTUM, IN THE INERTIAL FRAME, and that
 * is the third version of this and the first one that conserves
 * anything.
 *
 * Euler's equations in the body frame are
 *
 *	I omega' = T - omega x (I omega)
 *
 * and the cross term is why an asymmetric body tumbling about two axes
 * precesses instead of spinning tidily.  A 3U is 4kg and 100x100x300mm,
 * so Ixx = Iyy = 0.0333 and Izz = 0.0067 kg.m^2 -- a five to one ratio,
 * which is where that term earns its place.
 *
 * BUT EXPLICIT EULER ON THAT EQUATION IS UNCONDITIONALLY UNSTABLE.  The
 * free-body motion is a rotation of omega about the momentum axis, so
 * the term's eigenvalues are purely imaginary and |1 + h.lambda| is
 * greater than one for every step length: the amplitude grows by
 * sqrt(1 + (h.omega_n)^2) a step, which at a 3.9 second nutation period
 * and a fifty-millisecond step is 1.0032, and five thousand steps of
 * that is not a satellite.  MEASURED, before this change: the kinetic
 * energy of a torque-free tumble grew 183 per cent and |I.omega| 89 per
 * cent in 262 seconds.  Nothing in the model complained; it was found
 * by asking a free body for the two things a free body keeps.
 *
 * The cross term is an artefact of the frame.  In the INERTIAL frame
 * the equation is simply
 *
 *	L' = T
 *
 * so with L as the state there is no gyroscopic term to integrate and
 * |L| is exactly constant under zero torque -- not nearly, exactly, the
 * integrator never touches it.  The body rate comes out of the state
 * rather than being it:
 *
 *	omega_body = I^-1 . R(q) . L_inertial
 *
 * and the precession is still there, because R(q) is turning.  Energy
 * then drifts only through the attitude integration, which the spin
 * checks in tools/f407/simcheck.py measure at 0.0 to 0.3 per cent.
 *
 * TORQUES: the magnetorquers, m x B, and the gravity gradient,
 * 3mu/r^3 (n x I n) with n the nadir in body axes.  The second is about
 * a hundredth of the first here and is included because it is the one
 * that never switches off -- it is what a satellite with dead torquers
 * ends up pointing by.
 *
 * SCALES.  Quaternion in units of 10000; inertia in micro-kg.m^2;
 * torque worked in nano-newton-metres, which keeps a 0.2 A.m^2 dipole
 * in a 300mG field -- five micro-newton-metres -- three digits clear of
 * the bottom of an int.  Momentum in the product of the two, micro-
 * kg.m^2 times milli-degrees a second, which is a vlong; the body rate
 * that comes out of it is in milli-degrees a second, the unit
 * module/pycubedhw.m names.  Every integer division in both
 * integrators keeps its remainder, because both of them divided to
 * zero over the range that matters: see lifrac.
 *
 * FIRST ORDER, AND THE STEP IS FIXED IN SIMULATED TIME.  Euler
 * integration of both the rate and the quaternion, renormalised every
 * step, in steps of exactly Substep simulated milliseconds whatever
 * the interval being integrated is -- the remainder waits in a
 * backlog.  That is what makes the answer independent of the time
 * scale and of how often anything reads the file; the version before
 * it used the polling interval as the step, so the satellite responded
 * to being watched.
 */
enum {
	Qscale		= 10000,	/* quaternion components */
	Ixx		= 33333,	/* micro-kg.m^2, a 3U */
	Iyy		= 33333,
	Izz		= 6667,

	/*
	 * SIMULATED MILLISECONDS PER INTEGRATION STEP, and the step is
	 * ALWAYS exactly this.  Euler integration is first order, so its
	 * answer depends on the step length; if the step were the
	 * interval between reads then the satellite would respond to how
	 * often it is looked at -- which is the same fault as advancing
	 * only on a read, one level down.  So elapsed time accumulates
	 * in a backlog, whole steps of this length come out of it, and
	 * the remainder waits.  A reader polling flat out and a reader
	 * polling once a second integrate the identical trajectory and
	 * differ only in being up to one step behind.
	 *
	 * 50ms is one degree at a 20 deg/s tumble and a twentieth of the
	 * control loop's period.
	 */
	Defsubstep	= 50,

	/*
	 * And a bound on the steps one call will take, so that a read
	 * after a long quiet period cannot spend a second in the kernel.
	 * What it does not integrate stays in the backlog and comes out
	 * on the next call, so nothing is lost; the backlog is reported
	 * in #P/imu.ctl, because a model running behind real time has to
	 * say so.
	 *
	 * AND IT IS WHAT REALLY BOUNDS THE TIME SCALE.  One call can
	 * integrate at most Maxsteps steps, which is 4096 x 50ms = 204.8
	 * SIMULATED SECONDS however long it has been since the last call.
	 * So the time scale a reader actually gets is 204800 divided by
	 * the milliseconds between its reads: a tenth-second poll
	 * sustains two thousand, and a five-second gap sustains forty.
	 * The ceiling of 200 on #P/orbit.ctl is about the integration
	 * error, not about this, and the two are different limits --
	 * tools/f407/simsoak.py reads the files every few seconds at
	 * timescale 200, which asks for 960 simulated seconds a read, and
	 * the backlog grows without bound.  That is the model saying it
	 * cannot keep up, which is the whole reason the number is
	 * reported.
	 */
	Maxsteps	= 4096,

	/*
	 * A bound on the momentum, so that a runaway torque command
	 * cannot push the state somewhere the arithmetic below cannot
	 * represent.  Ixx times 200 deg/s, which is already six times
	 * what a CubeSat comes off a deployer at.
	 */
	Maxmomentum	= 7000000000LL,	/* micro-kg.m^2 . milli-deg/s */

	/*
	 * Likewise the commanded dipole.  A 3U's torquers are 0.2 to 0.4
	 * A.m^2; two is already generous and the clamp is there so that
	 * a controller with a sign error cannot make the arithmetic
	 * meaningless instead of merely wrong.
	 */
	Maxdipole	= 2000,		/* milli-A.m^2 */
};

static int inert[3] = { Ixx, Iyy, Izz };
static int q[4] = { Qscale, 0, 0, 0 };	/* w, x, y, z: inertial to body */

/*
 * THE REMAINDERS, AND THEY ARE NOT A REFINEMENT.
 *
 * Both integrations are integer divisions, and both of them divided to
 * zero over the range that matters.  The rate update was then
 * T.dt.57296/(I.10^6): a 0.2 A.m^2 dipole in a 250mG field is 5 micro-
 * newton-metres, which over a 10ms tick on a 3U is 0.086 milli-degrees
 * a second -- and (int)0.086 is 0, so AT TIMESCALE 1 THE TORQUERS DID
 * NOTHING AT ALL.  The quaternion update went the same way below about
 * 1.2 deg/s, so a detumble stalled at a rate that looked like a
 * physical plateau and was an arithmetic floor.  The deadband in
 * appl/pycubed/beepsat.b had been tuned to it.
 *
 * Keeping the remainder makes the division exact over any number of
 * steps: the quotient is applied, the remainder carries, and nothing
 * is lost however small the step.  C's division truncates towards zero
 * and its remainder takes the sign of the dividend, so the identity
 * n == (n/d)*d + n%d holds for negative rates too and a deceleration
 * accumulates as faithfully as an acceleration.
 */
static vlong li[3];			/* angular momentum, INERTIAL frame */
static vlong lifrac[3];
static vlong qfrac[4];
static vlong backlog;			/* simulated ms awaiting a step */
/*
 * The step length, settable, and settable for a reason rather than for
 * generality: the only way to tell an integration that has not
 * converged from one that is simply wrong is to halve the step and see
 * whether the error follows.  A first-order scheme's error falls like
 * the step and a second-order one's like its square; an error that does
 * not move is a bug.  "echo step 10 >#P/imu.ctl".
 */
static int substep = Defsubstep;
/*
 * How much simulated time the model has actually integrated, reported
 * in #P/imu.ctl.  It is the only way to check the integrator's clock
 * from outside: a rate that has climbed too far can mean a wrong
 * torque or too much time, and estimating the elapsed time from the
 * host's own sleeps cannot tell those apart.  Steps times the step
 * length against the orbit's phase, which is closed-form, settles it.
 */
static vlong integrated;

/* the body-frame values the sensors report, recomputed every advance */
static int fb[3];			/* field, milli-gauss */
static int gb[3];			/* gravity, milli-g */
static int sb[3];			/* the sun, a unit vector */
static int nb[3];			/* nadir, a unit vector */

/*
 * ROUNDED DIVISION, AND IT IS NOT A NICETY.
 *
 * C truncates towards zero, which is a BIAS: every division here loses
 * up to one unit in the direction of the origin, and the components
 * that suffer are the small ones.  A quaternion turning slowly has a
 * vector part of a handful of units out of ten thousand, so the
 * renormalisation's truncation bled a quarter of it on every step: the
 * attitude integrated 74.8 degrees where the rate asked for 75.8, a 1.3
 * per cent deficit at 1 deg/s and none at all at 10, which is the
 * signature of a quantisation and not of a step length.
 *
 * Where a division is part of an accumulation the remainder is carried
 * instead and the result is exact (see lifrac).  Where it is a rescale
 * -- a normalisation, a frame change -- there is nothing to carry it
 * into, and rounding is what is left.
 */
static vlong
divround(vlong x, vlong d)
{
	if(d == 0)
		return 0;
	if(x >= 0)
		return (x + d/2) / d;
	return (x - d/2) / d;
}

/*
 * THE ROTATION, AS A MATRIX, BUILT ONCE AND USED BOTH WAYS.
 *
 *	R = the matrix of q*, taking an inertial vector to the body
 *
 * at scale Qscale rather than Qscale^2, which is what lets a momentum
 * of several thousand million go through it without leaving a vlong:
 * the entries are at most 10^4, the components at most 10^10, and the
 * products stay four digits clear.
 *
 * Written out rather than as two quaternion multiplies, because the
 * intermediate of a multiply overflows at these scales and the
 * expanded form has no temporaries to think about.
 */
static void
rotmatq(int *qq, vlong *r)
{
	vlong w, x, y, z;
	int i;

	w = qq[0]; x = qq[1]; y = qq[2]; z = qq[3];
	r[0] = w*w + x*x - y*y - z*z;
	r[1] = 2*(x*y + w*z);
	r[2] = 2*(x*z - w*y);
	r[3] = 2*(x*y - w*z);
	r[4] = w*w - x*x + y*y - z*z;
	r[5] = 2*(y*z + w*x);
	r[6] = 2*(x*z + w*y);
	r[7] = 2*(y*z - w*x);
	r[8] = w*w - x*x - y*y + z*z;
	for(i = 0; i < 9; i++)
		r[i] = divround(r[i], Qscale);
}

static void
rotmat(vlong *r)
{
	rotmatq(q, r);
}

/* v in the body frame, from v in the inertial frame */
static void
tobody(int *vi, int *vb)
{
	vlong r[9];
	int i;

	rotmat(r);
	for(i = 0; i < 3; i++)
		vb[i] = (int)divround(r[3*i+0] * vi[0] + r[3*i+1] * vi[1]
			+ r[3*i+2] * vi[2], Qscale);
}

/* the same, for a momentum, which does not fit in an int */
static void
tobodyvq(int *qq, vlong *vi, vlong *vb)
{
	vlong r[9];
	int i;

	rotmatq(qq, r);
	for(i = 0; i < 3; i++)
		vb[i] = divround(r[3*i+0] * vi[0] + r[3*i+1] * vi[1]
			+ r[3*i+2] * vi[2], Qscale);
}

/* and back: the transpose, because a rotation's inverse is its
 * transpose and that is the whole reason for holding an attitude as a
 * rotation rather than as three vectors that drift apart. */
static void
toinertialv(vlong *vb, vlong *vi)
{
	vlong r[9];
	int i;

	rotmat(r);
	for(i = 0; i < 3; i++)
		vi[i] = divround(r[0*3+i] * vb[0] + r[1*3+i] * vb[1]
			+ r[2*3+i] * vb[2], Qscale);
}

/*
 * The body rate, from the momentum and a given attitude.  This is where
 * the precession comes from and there is no term for it: the momentum
 * is fixed in the inertial frame and the body is turning underneath it,
 * so omega in body axes moves whether or not anything is pushing.
 *
 * It takes the attitude rather than reading the global one because the
 * step below asks a TRIAL attitude the same question: see the note
 * there about the midpoint.
 */
static void
ratesfrom(int *qq, int *w)
{
	vlong lb[3];

	tobodyvq(qq, li, lb);
	w[0] = (int)divround(lb[0], inert[0]);
	w[1] = (int)divround(lb[1], inert[1]);
	w[2] = (int)divround(lb[2], inert[2]);
}

static void
bodyrates(void)
{
	int w[3];

	ratesfrom(q, w);
	ratex = w[0];
	ratey = w[1];
	ratez = w[2];
}

/*
 * And the other direction, for the ctl file: a commanded body rate is a
 * momentum once the inertia and the attitude are known.
 */
static void
setbodyrate(int wx, int wy, int wz)
{
	vlong lb[3];
	int i;

	lb[0] = (vlong)inert[0] * wx;
	lb[1] = (vlong)inert[1] * wy;
	lb[2] = (vlong)inert[2] * wz;
	toinertialv(lb, li);
	/*
	 * Clamped here as well as in torques(), because a rate written
	 * to the ctl file is as capable of being absurd as one a
	 * controller integrates into existence -- and then the rate is
	 * taken back OUT of the clamped momentum rather than being the
	 * number that was asked for, so the file never reports a state
	 * the model is not in.
	 */
	for(i = 0; i < 3; i++){
		if(li[i] > Maxmomentum)
			li[i] = Maxmomentum;
		if(li[i] < -Maxmomentum)
			li[i] = -Maxmomentum;
	}
	bodyrates();
}

/*
 * The momentum, forward one step.  bfi and ndi are the field and the
 * nadir in the INERTIAL frame, held by the caller across the whole
 * interval so the orbit is not recomputed a few hundred times for an
 * answer that cannot have moved; the attitude does move, so they are
 * rotated into the body frame on every step.
 *
 * The torques are worked in the body frame, because that is where a
 * magnetorquer and an inertia tensor live, and then rotated out: L is
 * inertial and so is its rate of change.
 */
static void
torques(int *bfi, int *ndi, long ms)
{
	vlong tb[3], ti[3], iw[3], whole, den;
	int gg, i;

	tobody(bfi, fb);
	tobody(ndi, nb);

	/*
	 * m x B, in nano-newton-metres: a dipole in milli-A.m^2 and a
	 * field in milli-gauss give 10^-3 * 10^-7 T = 10^-10, so the
	 * product is in units of 10^-10 N.m and ten of them is a nano.
	 */
	tb[0] = ((vlong)torqy * fb[2] - (vlong)torqz * fb[1]) / 10;
	tb[1] = ((vlong)torqz * fb[0] - (vlong)torqx * fb[2]) / 10;
	tb[2] = ((vlong)torqx * fb[1] - (vlong)torqy * fb[0]) / 10;

	/*
	 * The gravity gradient, 3mu/r^3 (n x I n).  orbitgg returns
	 * 3mu/r^3 scaled by 10^9 and the inertia is micro-kg.m^2, so
	 * the product of those two with a pair of milli-unit vector
	 * components lands in nano-newton-metres after the divisions
	 * below.  About a hundredth of the torquers here, and in because
	 * it is the one that never switches off: it is what a satellite
	 * with dead torquers ends up pointing by.
	 */
	gg = orbitgg();
	iw[0] = (vlong)inert[0] * nb[0];
	iw[1] = (vlong)inert[1] * nb[1];
	iw[2] = (vlong)inert[2] * nb[2];
	tb[0] += ((vlong)gg * (nb[1]*iw[2] - nb[2]*iw[1])) / 1000000000000LL;
	tb[1] += ((vlong)gg * (nb[2]*iw[0] - nb[0]*iw[2])) / 1000000000000LL;
	tb[2] += ((vlong)gg * (nb[0]*iw[1] - nb[1]*iw[0])) / 1000000000000LL;

	/*
	 * There is no omega x (I omega) here and that is the point: the
	 * term exists only because the body frame is rotating, and L is
	 * not held in it.  See the note at the top of the model.
	 */
	toinertialv(tb, ti);

	/*
	 * L += T dt.  A momentum unit is one micro-kg.m^2 times one
	 * milli-degree a second, which is 1.745329e-11 kg.m^2/s; a
	 * torque unit is a nano-newton-metre and a step is a
	 * millisecond, so T.dt is 10^-12 N.m.s and the ratio is
	 * 0.0572958 momentum units per nano-newton-metre-millisecond.
	 * The remainder carries, for the reason given by lifrac.
	 */
	den = 10000000LL;
	for(i = 0; i < 3; i++){
		lifrac[i] = lifrac[i] + ti[i] * ms * 572958;
		whole = lifrac[i] / den;
		lifrac[i] = lifrac[i] - whole * den;
		li[i] = li[i] + whole;
		if(li[i] > Maxmomentum)
			li[i] = Maxmomentum;
		if(li[i] < -Maxmomentum)
			li[i] = -Maxmomentum;
	}
}

/*
 * The attitude, forward one step, BY THE ROTATION ITSELF rather than by
 * its derivative.
 *
 * The first-order step q += (1/2) q (0,omega) dt is what was here, and
 * with the momentum now exactly conserved it became the limiting error:
 * a torque-free tumble kept |L| to the last digit and the DERIVED body
 * rate still moved 5.7 per cent in twelve seconds, because the step's
 * O(theta^2) error tilts the attitude and a tilted attitude resolves a
 * fixed L into the wrong body axes.
 *
 * For a constant rate over the step the exact answer is a quaternion
 * multiply:
 *
 *	q' = q (cos(theta/2), sin(theta/2) omega/|omega|),  theta = |omega| dt
 *
 * and omega is constant over fifty milliseconds to far better than the
 * rest of this model.  The increment is built to second order --
 *
 *	v = omega dt / 2,  w = 1 - |v|^2/2
 *
 * -- and then RENORMALISED, which is what makes it worth doing: the
 * vector part is exactly proportional to omega, so renormalising fixes
 * the angle and leaves the axis alone.  What is left is a systematic
 * scale error on the rate of theta^2/6, which is 1.7e-5 at these step
 * lengths and does not accumulate, where Euler's error was a random
 * walk in the direction.
 *
 * The remainder still carries, for the reason by lifrac: the step is
 * written as an increment to q precisely so that it can.
 */
static void
qstep(int *qq, int *w, long ms, vlong *frac)
{
	vlong dq[4], num[4], n, whole, mag, d;
	int i;

	/*
	 * v = omega dt / 2, in units of 10^-6 radian.  A milli-degree a
	 * second for a millisecond is 1.7453e-8 radian, and half of that
	 * scaled by 10^6 is 8.7265e-3 -- so 87265/10^7.
	 */
	dq[1] = divround((vlong)w[0] * ms * 87265, 10000000LL);
	dq[2] = divround((vlong)w[1] * ms * 87265, 10000000LL);
	dq[3] = divround((vlong)w[2] * ms * 87265, 10000000LL);

	/*
	 * cos v and sin v, to one more term each.
	 *
	 * The first version of this took the vector part as v and then
	 * RENORMALISED the increment, with a comment saying that fixed
	 * the angle and left the axis alone.  Half of that was wrong:
	 * normalising scales the scalar and the vector equally, so the
	 * ratio between them -- which IS the angle -- does not move.  The
	 * construction (1 - v^2/2, v) has an effective half-angle of
	 * atan(v/(1-v^2/2)) = v + v^3/6, a relative error of v^2/6, and
	 * no amount of rescaling touches it.  What the normalisation did
	 * fix was the magnitude, which the next two lines already leave
	 * correct to v^4/8 -- two parts in a thousand million at these
	 * step lengths -- so it was an integer square root in the hot
	 * path for nothing, twice a step.
	 *
	 * So: sin v = v(1 - v^2/6) and cos v = 1 - v^2/2, which puts the
	 * angle right to O(v^4) and needs no root at all.
	 */
	n = dq[1]*dq[1] + dq[2]*dq[2] + dq[3]*dq[3];
	for(i = 1; i < 4; i++)
		dq[i] -= divround(dq[i] * n, 6000000000000LL);
	dq[0] = 1000000LL - divround(n, 2000000LL);

	/* q' = q dq, as an increment, at scale Qscale * 10^6 */
	num[0] = qq[0]*dq[0] - qq[1]*dq[1] - qq[2]*dq[2] - qq[3]*dq[3];
	num[1] = qq[0]*dq[1] + qq[1]*dq[0] + qq[2]*dq[3] - qq[3]*dq[2];
	num[2] = qq[0]*dq[2] - qq[1]*dq[3] + qq[2]*dq[0] + qq[3]*dq[1];
	num[3] = qq[0]*dq[3] + qq[1]*dq[2] - qq[2]*dq[1] + qq[3]*dq[0];
	for(i = 0; i < 4; i++){
		num[i] -= (vlong)qq[i] * 1000000LL;
		if(frac != nil){
			frac[i] = frac[i] + num[i];
			whole = frac[i] / 1000000LL;
			frac[i] = frac[i] - whole * 1000000LL;
		}else
			whole = divround(num[i], 1000000LL);
		qq[i] += (int)whole;
	}

	/*
	 * And the attitude renormalised too, because the increment above
	 * is applied in integers and the rounding is not a rotation.
	 * Without this, gravity grows -- which is how the version before
	 * the one before this was caught.
	 */
	n = 0;
	for(i = 0; i < 4; i++)
		n += (vlong)qq[i] * qq[i];
	if(n <= 0){
		qq[0] = Qscale;
		qq[1] = qq[2] = qq[3] = 0;
		if(frac != nil)
			for(i = 0; i < 4; i++)
				frac[i] = 0;
		return;
	}
	/*
	 * Renormalised to the first order, because the only thing taking
	 * it off the sphere is the integer rounding of the increment and
	 * that is parts per million: with d = |q|^2 - Qscale^2 small, the
	 * factor is 1 - d/(2 Qscale^2).  A square root here ran a Newton
	 * loop of thirty vlong divisions four hundred times a read at the
	 * top time scale, which is not what a satellite's processor is
	 * for.  If it is ever far off the sphere -- a per cent, which
	 * would mean something else is wrong -- the root is still there.
	 */
	d = n - (vlong)Qscale * Qscale;
	if(d > 1000000LL || d < -1000000LL){
		mag = msqrt(n);
		if(mag <= 0)
			return;
		for(i = 0; i < 4; i++)
			qq[i] = (int)divround((vlong)qq[i] * Qscale, mag);
		return;
	}
	for(i = 0; i < 4; i++)
		qq[i] -= (int)divround((vlong)qq[i] * d,
			2LL * Qscale * Qscale);
}

/*
 * One step of the attitude, WITH THE RATE TAKEN AT THE MIDDLE OF IT.
 *
 * The exponential above is exact for a constant omega, and omega is not
 * constant: in body axes it precesses, for a 3U at the default tumble
 * at 0.34 radians a second, which is a degree in a fifty-millisecond
 * step.  Using the rate at the START of the step therefore lags the
 * axis by half a degree every step, and that lag is systematic -- it
 * migrated the momentum towards the low-inertia axis and the kinetic
 * energy of a torque-free tumble grew 156 per cent in 243 seconds while
 * |L| held to 0.002.  An error that is not in the conserved quantity is
 * harder to see and no less wrong.
 *
 * So: a half step on a COPY to find the attitude in the middle, the
 * rate there, and then the whole step from the original attitude with
 * that rate.  Second order, two rotations a step, and the remainder is
 * carried only on the real one -- the trial is thrown away.
 */
static void
rotate(long ms)
{
	int qm[4], w[3], i;
	long half;

	half = ms / 2;
	if(half < 1){
		ratesfrom(q, w);
		qstep(q, w, ms, qfrac);
		return;
	}
	ratesfrom(q, w);
	for(i = 0; i < 4; i++)
		qm[i] = q[i];
	qstep(qm, w, half, nil);
	ratesfrom(qm, w);
	qstep(q, w, ms, qfrac);
}

/*
 * Bring the model up to now.
 *
 * IN ONE PLACE AND CALLED BY EVERY FILE THAT REPORTS STATE, which is
 * the fix for an instrument that lied: this was inlined in imuread, so
 * the model advanced only when #P/imu was read and #P/imu.ctl showed
 * whatever was true at the last read of the other file.  Probing the
 * torque law through the ctl file therefore showed a rate that never
 * moved.
 *
 * AND INDEPENDENT OF HOW OFTEN IT IS CALLED, which is the stronger
 * property and the one that was missing.  The elapsed ticks are turned
 * into simulated milliseconds and integrated in steps of a fixed
 * simulated length, so a reader polling as fast as the shell will go
 * and a reader polling once a second see the same satellite.  Before
 * this, the step WAS the polling interval: the division truncated to
 * zero at short intervals and overshot at long ones, so the answer
 * depended on the observer.
 */
static void
advance(void)
{
	ulong t, dt;
	int bfi[3], ndi[3], sni[3], nsteps;

	t = m != nil? m->ticks: 0;
	if(!running){
		running = 1;
		lastticks = t;
		dt = 0;
	}else{
		dt = t - lastticks;
		lastticks = t;
	}
	backlog = backlog + ((vlong)dt * 1000 * orbittimescale()) / HZ;

	/*
	 * The orbit once per call, the attitude once per step.  The
	 * field moves over minutes and the satellite over seconds, so
	 * holding the inertial vectors across one call is sound; the
	 * body-frame ones are recomputed inside the loop because the
	 * attitude is exactly what is changing.
	 */
	orbitfield(bfi);
	orbitnadir(ndi);
	orbitsun(sni);

	/*
	 * One step: the rate follows from the momentum and the attitude,
	 * the attitude follows the rate, and the momentum follows the
	 * torque.  In that order, so that each uses the state it was
	 * given rather than the state it is producing.
	 */
	for(nsteps = 0; backlog >= substep && nsteps < Maxsteps; nsteps++){
		backlog = backlog - substep;
		integrated = integrated + substep;
		rotate(substep);
		torques(bfi, ndi, substep);
	}
	bodyrates();

	/* and what the sensors see of it */
	tobody(bfi, fb);
	tobody(sni, sb);
	tobody(ndi, nb);
	gb[0] = (nb[0] * Grav) / 1000;
	gb[1] = (nb[1] * Grav) / 1000;
	gb[2] = (nb[2] * Grav) / 1000;
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

static void
nocarry(void)
{
	int i;

	for(i = 0; i < 3; i++)
		lifrac[i] = 0;
	for(i = 0; i < 4; i++)
		qfrac[i] = 0;
}

static s32
imuctlread(Chan*, void *a, s32 n, s64 offset)
{
	/*
	 * 512 and not 256.  Adding the momentum line took the report
	 * past 256 bytes and snprint truncated it MID-LINE, so the last
	 * field arrived without its unit and with the shell's prompt
	 * stuck to it -- which read as a parse bug in the tool and not
	 * as a short buffer in the kernel.  A report that grows a line
	 * at a time wants headroom, and a truncation here is silent.
	 */
	char buf[512];

	advance();

	snprint(buf, sizeof buf,
		"source %s\n"
		"spin %d %d %d\n"
		"noise %d\n"
		"quaternion %d %d %d %d\n"
		"momentum %lld %lld %lld\n"
		"field %d %d %d\n"
		"sun %d %d %d\n"
		"nadir %d %d %d\n"
		"torque %d %d %d\n"
		"inertia %d %d %d\n"
		"eclipse %d\n"
		"timescale %d\n"
		"step %d ms simulated\n"
		"backlog %d ms\n"
		"integrated %lld ms\n",
		imudev != nil? "bmx160": "scripted",
		ratex, ratey, ratez, noise,
		q[0], q[1], q[2], q[3],
		li[0], li[1], li[2],
		fb[0], fb[1], fb[2], sb[0], sb[1], sb[2],
		nb[0], nb[1], nb[2],
		torqx, torqy, torqz,
		inert[0], inert[1], inert[2],
		orbiteclipse(), orbittimescale(), substep, (int)backlog,
		integrated);
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
	/*
	 * Every verb that changes the state advances the model FIRST, so
	 * that the time since the last read is integrated on the state
	 * that was true during it rather than on the one being written.
	 * And the three verbs that set a rate outright clear the carried
	 * remainders: the carry belongs to the rate that earned it.
	 */
	if(strcmp(fld[0], "spin") == 0 && nf == 4){
		advance();
		setbodyrate(atoi(fld[1]) * 1000, atoi(fld[2]) * 1000,
			atoi(fld[3]) * 1000);
		nocarry();
	}else if(strcmp(fld[0], "still") == 0 && nf == 1){
		advance();
		q[0] = Qscale;
		q[1] = q[2] = q[3] = 0;
		setbodyrate(0, 0, 0);
		nocarry();
		/*
		 * And the backlog goes too.  "still" means stop and be
		 * level; integrating forty hours of a state that has just
		 * been thrown away would not be keeping faith with time,
		 * it would be spending it on nothing.  The other verbs
		 * keep it, because they change the state the model is in
		 * rather than declaring where it starts from.
		 */
		backlog = 0;
	}else if(strcmp(fld[0], "tumble") == 0 && nf == 1){
		advance();
		/*
		 * A rate worth detumbling: a CubeSat off a deployer
		 * tumbles at a few degrees a second to a few tens, and
		 * three unequal axes is what makes it a tumble rather
		 * than a spin.
		 */
		setbodyrate(7000, -11000, 23000);
		nocarry();
	}else if(strcmp(fld[0], "inertia") == 0 && nf == 4){
		/*
		 * All three, in micro-kg.m^2, because a tensor is not one
		 * number: the ratio between them is what makes a body
		 * precess, and a verb that set only a scalar could not
		 * express a 3U at all.
		 */
		advance();
		for(v = 1; v < 4; v++){
			int w = atoi(fld[v]);
			if(w < 1)
				error("inertia is three positive figures");
			inert[v-1] = w;
		}
		/*
		 * The momentum is kept and the RATE therefore changes,
		 * which is the only answer that is not a lie: rebuilding
		 * L from the old rate would have the satellite gain or
		 * lose momentum because somebody edited a file.
		 */
		bodyrates();
	}else if(strcmp(fld[0], "step") == 0 && nf == 2){
		v = atoi(fld[1]);
		if(v < 1 || v > 1000)
			error("step is 1 to 1000 simulated ms");
		advance();
		substep = v;
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

static int
clampdipole(int v)
{
	if(v > Maxdipole)
		return Maxdipole;
	if(v < -Maxdipole)
		return -Maxdipole;
	return v;
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
	advance();			/* on the old dipole, before it changes */
	torqx = clampdipole(atoi(fld[0]));
	torqy = clampdipole(atoi(fld[1]));
	torqz = clampdipole(atoi(fld[2]));
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
