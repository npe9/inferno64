#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * Where the satellite is, what field it is in, and whether it is in
 * sunlight.  #P/orbit, with #P/orbit.ctl to set it up.
 *
 * WHY THIS IS ITS OWN FILE.  The orbit is not a property of the
 * inertial measurement unit, and it was: the first version of this
 * simulation had a field of constant magnitude rotating about one body
 * axis, with no position, no orbit and no shadow.  That is enough to
 * make a controller run and not enough to tell whether it would work,
 * because the three things a magnetic controller actually contends with
 * are a field whose MAGNITUDE changes by a factor of two, a field whose
 * DIRECTION sweeps twice an orbit, and a power budget interrupted by
 * eclipse for a third of every pass.  None of them existed.
 *
 * So: a circular orbit, a tilted dipole field, a fixed sun and the
 * Earth's shadow.  imubmx160.c rotates these into the body frame for
 * the sensors; pwradm1176.c asks whether there is sun.  Each of them
 * keeps what belongs to it and nothing keeps the orbit but this.
 *
 * WHAT IS MODELLED, with the figures and where they come from:
 *
 *	A CIRCULAR ORBIT at a settable altitude, 500km by default:
 *	radius 6871km, period 5668 seconds, 94.5 minutes.  Circular
 *	rather than elliptical because a CubeSat in a deployed orbit is
 *	nearly circular and an eccentricity would buy nothing the
 *	control software can tell.
 *
 *	A TILTED DIPOLE FIELD, which is the first term of the real one
 *	and the term that matters:
 *
 *		B = B0 (Re/r)^3 [ 3(m.r)r - m ]
 *
 *	with m the geomagnetic axis, 11 degrees off the spin axis.  At
 *	500km that gives 247mG at the magnetic equator and 494 at the
 *	pole -- a factor of two, twice an orbit, which is what a B-dot
 *	controller is really working against.  IGRF would add a few per
 *	cent and a table this part has no room for.
 *
 *	THE SUN as a fixed inertial direction, with a settable beta
 *	angle to the orbit plane.  Fixed because the Earth moves one
 *	degree a day around it and no bench run is a day.
 *
 *	ECLIPSE by a cylindrical shadow: in shadow when the satellite is
 *	on the far side of the Earth from the sun and its distance from
 *	the sun line is less than the Earth's radius.  A cylinder rather
 *	than a cone because the penumbra is a few seconds of a 94-minute
 *	orbit.  At beta zero that is 37 per cent of the orbit in
 *	darkness, which is the number the power budget turns on.
 *
 * THE TIME SCALE, and it is the honest answer to a real tension.  A 3U
 * with 0.2 A.m^2 torquers in the 250mG field at 500km feels 4.9
 * micro-newton-metres, which on the 0.0067 kg.m^2 low-inertia axis is
 * 0.042 degrees a second squared and on the 0.0333 axes 0.0085.  So
 * twenty degrees a second takes eight minutes about the easy axis and
 * forty about the hard ones.  That is the truth and it is not
 * watchable.  Fudging the inertia to make it quick would make every
 * number downstream wrong; a stated multiplier on SIMULATED TIME
 * leaves the physics alone and says what it is doing.  Default 1,
 * settable, and reported in #P/orbit so nothing can mistake a fast run
 * for a fast satellite.
 *
 * AND IT SCALES THE SIMULATION, NOT THE INTEGRATION.  imubmx160.c
 * breaks whatever interval it is given into fixed hundred-millisecond
 * SIMULATED steps, so the attitude at timescale 200 is integrated the
 * same way as at 1 and only the work changes.  The multiplier applies
 * to this file's phase, to the attitude and to the battery's coulomb
 * count, which is every piece of state that is a function of time.
 */

enum {
	Vscale		= 1000,		/* a unit vector's components */
	Degscale	= 1000,		/* milli-degrees */

	Earthradius	= 6371,		/* km */
	Bequator	= 310,		/* mG at the surface, magnetic equator */
	Dipoletilt	= 11,		/* degrees of the geomagnetic axis */

	Defaltitude	= 500,		/* km */
	Definclination	= 51600,	/* milli-degrees, ISS-like */
	Defbeta		= 20000,	/* milli-degrees, sun to orbit plane */
};

/* sin, milli-units, one degree a step, a quarter turn */
static short sintab[91] = {
	   0,   17,   35,   52,   70,   87,  105,  122,  139,  156,
	 174,  191,  208,  225,  242,  259,  276,  292,  309,  326,
	 342,  358,  375,  391,  407,  423,  438,  454,  469,  485,
	 500,  515,  530,  545,  559,  574,  588,  602,  616,  629,
	 643,  656,  669,  682,  695,  707,  719,  731,  743,  755,
	 766,  777,  788,  799,  809,  819,  829,  839,  848,  857,
	 866,  875,  883,  891,  899,  906,  914,  921,  927,  934,
	 940,  946,  951,  956,  961,  966,  970,  974,  978,  982,
	 985,  988,  990,  993,  995,  996,  998,  999,  999, 1000,
	1000,
};

/*
 * sin of an angle in milli-degrees, to milli-units, interpolated
 * between whole degrees.  The table is a quarter turn and the three
 * reflections are done here, which is the whole of the trigonometry in
 * this simulation.
 */
int
msin(int mdeg)
{
	int d, f, a, b;

	mdeg %= 360*Degscale;
	if(mdeg < 0)
		mdeg += 360*Degscale;
	if(mdeg >= 180*Degscale)
		return -msin(mdeg - 180*Degscale);
	if(mdeg > 90*Degscale)
		mdeg = 180*Degscale - mdeg;
	d = mdeg / Degscale;
	f = mdeg % Degscale;
	if(d >= 90)
		return Vscale;
	a = sintab[d];
	b = sintab[d+1];
	return a + ((b - a) * f) / Degscale;
}

int
mcos(int mdeg)
{
	return msin(mdeg + 90*Degscale);
}

/*
 * Integer square root, floor, by Newton.  There were two of these in
 * the simulation and both were "count up from one until the square is
 * big enough" -- 900 iterations here, where it runs once, and ten
 * thousand inside the quaternion renormalisation, where it runs on
 * every integration step.  Newton converges in about thirty for any
 * vlong, so one correct one is cheaper than two wrong ones.
 */
long
msqrt(vlong n)
{
	vlong x, y;

	if(n <= 0)
		return 0;
	x = n;
	y = (x + 1) / 2;
	while(y < x){
		x = y;
		y = (x + n / x) / 2;
	}
	return (long)x;
}

static int altitude = Defaltitude;
static int inclination = Definclination;
static int beta = Defbeta;
static int timescale = 1;

static int phase;			/* argument of latitude, mdeg */
static int period;			/* seconds */
static int radius;			/* km */
static int bfield;			/* B0 (Re/r)^3, mG */

static int ri[3];			/* the position, a unit vector */
static int bi[3];			/* the field, mG, inertial */
static int si[3];			/* the sun, a unit vector, inertial */
static int ineclipse;
static ulong lastticks;
static vlong phasefrac;
static int setup;
static int running, computed;

/*
 * The period of a circular orbit, from r^3/mu, by integer square root.
 *
 *	T = 2 pi sqrt(r^3 / mu)
 *
 * with r in metres and mu 3.986e14.  Worked in kilometres to keep the
 * cube inside a vlong: r^3 in km^3 is at most 10^12 for anything a
 * CubeSat flies, and mu is 3.986e5 km^3/s^2.
 */
static void
reorbit(void)
{
	vlong q;
	int s;

	radius = Earthradius + altitude;
	q = ((vlong)radius * radius * radius) / 398600;
	s = (int)msqrt(q);
	period = (628 * s) / 100;
	if(period < 1)
		period = 1;
	/*
	 * B0 (Re/r)^3, the dipole strength at this altitude.  Done as
	 * one expression so the cube does not lose its precision in
	 * three divisions.
	 */
	bfield = (int)(((vlong)Bequator * Earthradius * Earthradius
		* Earthradius) / ((vlong)radius * radius * radius));
	/*
	 * The kept remainder is in units of the old period, so it means
	 * nothing against the new one.  Less than a milli-degree, and
	 * dropping it is the only answer that does not invent an angle.
	 */
	phasefrac = 0;
	setup = 1;
	computed = 0;
}

/*
 * Advance the orbit to now and recompute everything that follows from
 * where it is.
 *
 * Called by whoever wants a current value, and driven by elapsed ticks
 * times the time scale -- so the simulation is a function of time and
 * not of how often it is read, which is the same property the attitude
 * model has for the same reason.
 *
 * THERE USED TO BE A GAP GUARD HERE, dropping any interval longer than
 * sixty seconds as "the first call, or a long gap".  It did handle the
 * first call, where there is no previous tick to subtract, and it also
 * meant THE ORBIT STOPPED whenever nothing read it for a minute -- so
 * the simulation was a function of being watched after all.  A flag
 * for the first call says what was meant; every interval after it is
 * integrated however long it is, which the closed-form position and
 * the kept remainder below both support exactly.
 */
void
orbitadvance(void)
{
	ulong t, dt;
	int ci, sinc, cu, su, dip[3], mr, i, perp[3], d;
	vlong q;

	if(!setup)
		reorbit();
	t = m != nil? m->ticks: 0;
	if(!running){
		running = 1;
		lastticks = t;
		dt = 0;
	}else{
		dt = t - lastticks;
		lastticks = t;
	}
	/*
	 * Nothing to recompute if no time has passed, and this is not
	 * an optimisation: the attitude integrator below substeps, and
	 * it asks for the field once per step.  Without this the orbit
	 * would be recomputed -- eight sines of it -- a few hundred
	 * times a tick for an answer that cannot have changed.
	 */
	if(dt == 0 && computed)
		return;
	computed = 1;
	/*
	 * Milli-degrees of argument of latitude in this interval.  The
	 * remainder is kept, because at timescale 1 a tick is 0.6
	 * milli-degrees of a 94-minute orbit and the truncation of that
	 * to zero would stop the orbit dead -- which is the same fault
	 * the attitude integrator had.
	 */
	if(dt != 0){
		vlong den, whole;

		den = (vlong)HZ * period;
		phasefrac = phasefrac + (vlong)dt * timescale * 360 * Degscale;
		whole = phasefrac / den;
		phase += (int)whole;
		phasefrac = phasefrac - whole * den;
	}
	phase %= 360 * Degscale;

	/*
	 * The position, in an inertial frame whose x is the ascending
	 * node and whose z is the Earth's spin axis.  u is the argument
	 * of latitude, i the inclination.
	 */
	cu = mcos(phase);
	su = msin(phase);
	ci = mcos(inclination);
	sinc = msin(inclination);
	ri[0] = cu;
	ri[1] = (su * ci) / Vscale;
	ri[2] = (su * sinc) / Vscale;

	/*
	 * The field of a dipole tilted from the spin axis, which points
	 * south: m = (sin tilt, 0, -cos tilt).
	 *
	 *	B = B0 (Re/r)^3 [ 3 (m.r) r - m ]
	 */
	dip[0] = msin(Dipoletilt * Degscale);
	dip[1] = 0;
	dip[2] = -mcos(Dipoletilt * Degscale);
	mr = 0;
	for(i = 0; i < 3; i++)
		mr += (dip[i] * ri[i]) / Vscale;
	for(i = 0; i < 3; i++)
		bi[i] = (int)(((vlong)bfield
			* (3 * mr * ri[i] / Vscale - dip[i])) / Vscale);

	/*
	 * The sun, at beta to the orbit plane.  The orbit plane's normal
	 * is (0, -sin i, cos i) for this frame, so a sun at beta out of
	 * the plane and along the node line is
	 * (cos beta, -sin beta sin i, sin beta cos i) -- near enough,
	 * and the thing that matters is that beta sets the eclipse
	 * fraction.
	 */
	si[0] = mcos(beta);
	si[1] = -(msin(beta) * sinc) / Vscale;
	si[2] = (msin(beta) * ci) / Vscale;

	/*
	 * Eclipse, by a cylinder: behind the Earth, and within its
	 * radius of the sun line.  d is r.s in milli-units; perp is the
	 * component of r across the sun line, and the satellite is in
	 * shadow when that is shorter than the Earth, scaled by the
	 * orbit radius.
	 */
	d = 0;
	for(i = 0; i < 3; i++)
		d += (ri[i] * si[i]) / Vscale;
	ineclipse = 0;
	if(d < 0){
		q = 0;
		for(i = 0; i < 3; i++){
			perp[i] = ri[i] - (d * si[i]) / Vscale;
			q += (vlong)perp[i] * perp[i];
		}
		/* |perp| * radius < Earthradius, squared to avoid a root */
		if(q * radius * radius
		    < (vlong)Earthradius * Earthradius * Vscale * Vscale)
			ineclipse = 1;
	}
}

/* the field in the inertial frame, milli-gauss */
void
orbitfield(int *v)
{
	orbitadvance();
	v[0] = bi[0];
	v[1] = bi[1];
	v[2] = bi[2];
}

/* the sun, a unit vector in the inertial frame */
void
orbitsun(int *v)
{
	orbitadvance();
	v[0] = si[0];
	v[1] = si[1];
	v[2] = si[2];
}

/* nadir: straight down, which is minus the position */
void
orbitnadir(int *v)
{
	orbitadvance();
	v[0] = -ri[0];
	v[1] = -ri[1];
	v[2] = -ri[2];
}

int
orbiteclipse(void)
{
	orbitadvance();
	return ineclipse;
}

/* 3 mu / r^3, scaled by 10^9, for the gravity-gradient torque */
int
orbitgg(void)
{
	if(!setup)
		reorbit();
	return (int)(((vlong)3 * 398600 * 1000000000)
		/ ((vlong)radius * radius * radius));
}

int
orbittimescale(void)
{
	return timescale;
}

static s32
orbitread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[512];

	orbitadvance();
	snprint(buf, sizeof buf,
		"altitude %d km\n"
		"radius %d km\n"
		"period %d s\n"
		"inclination %d.%.3d deg\n"
		"beta %d.%.3d deg\n"
		"phase %d.%.3d deg\n"
		"position %d %d %d\n"
		"field %d %d %d mG\n"
		"strength %d mG at the magnetic equator\n"
		"sun %d %d %d\n"
		"eclipse %d\n"
		"timescale %d\n",
		altitude, radius, period,
		inclination/1000, inclination%1000,
		beta/1000, beta%1000,
		phase/1000, phase%1000,
		ri[0], ri[1], ri[2],
		bi[0], bi[1], bi[2], bfield,
		si[0], si[1], si[2],
		ineclipse, timescale);
	return readstr(offset, a, n, buf);
}

static s32
orbitctlwrite(Chan*, void *a, s32 n, s64)
{
	char buf[64], *fld[3];
	int nf, v;

	if(n >= sizeof buf)
		error(Ebadarg);
	memmove(buf, a, n);
	buf[n] = 0;
	nf = tokenize(buf, fld, nelem(fld));
	if(nf != 2)
		error(Ebadarg);
	v = atoi(fld[1]);
	if(strcmp(fld[0], "altitude") == 0){
		if(v < 150 || v > 40000)
			error("altitude is 150 to 40000 km");
		orbitadvance();
		altitude = v;
		reorbit();
	}else if(strcmp(fld[0], "inclination") == 0){
		if(v < 0 || v > 180000)
			error(Ebadarg);
		orbitadvance();
		inclination = v;
	}else if(strcmp(fld[0], "beta") == 0){
		if(v < -90000 || v > 90000)
			error(Ebadarg);
		orbitadvance();
		beta = v;
	}else if(strcmp(fld[0], "phase") == 0){
		if(v < 0 || v >= 360000)
			error(Ebadarg);
		orbitadvance();
		phase = v;
	}else if(strcmp(fld[0], "timescale") == 0){
		/*
		 * How much faster than real the simulation runs.  Bounded
		 * because the integration is first order: a step long
		 * enough to turn the satellite a long way is a step whose
		 * answer is wrong, and at 1000 a tick is ten seconds of
		 * orbit.
		 */
		if(v < 1 || v > 200)
			error("timescale is 1 to 200");
		orbitadvance();
		timescale = v;
	}else
		error(Ebadctl);
	return n;
}

void
orbitsimlink(void)
{
	reorbit();
	addarchfile("orbit", 0444, orbitread, nil);
	addarchfile("orbit.ctl", 0666, orbitread, orbitctlwrite);
}
