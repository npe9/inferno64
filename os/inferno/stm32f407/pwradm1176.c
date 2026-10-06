#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/i2c.h"

/*
 * An ADM1176 power monitor at #P/power, with a scripted battery behind
 * it until a part answers.  imubmx160.c carries the long version of
 * what that division means and it applies here unchanged: the I2C half
 * is real code that has never been run against a part, the simulation
 * says so in #P/arch, and the probe is what decides which runs.
 *
 * THIS FILE OWNS THE PACK, which is why the charger is a separate file
 * and this is not.  A battery has one voltage however many parts are
 * looking at it, so the model lives in one place and chgbq25883.c asks
 * it to charge rather than keeping a second copy that could disagree.
 *
 * THE BATTERY IS A CELL AND NOT A RAMP, which is the difference
 * between a fixture and a model.
 *
 * It was a millivolt per hundred milliamp-seconds: a straight line from
 * 4200 to 3000 with noise on it.  That is wrong in the way that matters
 * to software, because the SHAPE is what a state-of-charge estimate and
 * every low-voltage threshold are read against.  A linear cell has no
 * plateau, so a threshold placed on it means nothing and an estimator
 * tuned to its slope would see nothing like a real pack.
 *
 * What is here now:
 *
 *	COULOMB COUNTING.  The state is charge in milliamp-seconds, not
 *	voltage.  2600mAh is 9360000 mA.s, a 1S 18650, which is what a
 *	3U actually carries.
 *
 *	AN OPEN-CIRCUIT CURVE, ocvtab below: 4200mV full, a long plateau
 *	through the middle at 3700 to 3800, and a knee under twenty per
 *	cent falling to 3000.  Twelve points interpolated, which is the
 *	shape every lithium datasheet shows, with the resolution put at
 *	the knee because that is where a threshold sits and where a
 *	straight line is most wrong.
 *
 *	INTERNAL RESISTANCE, 80 milliohms, so the terminals sag under
 *	load and rise under charge: 120mA of draw costs 10mV and 260mA
 *	of charge gains 21mV.  This is why a pack reads differently in
 *	sun and in eclipse at the same state of charge, and why a naive
 *	low-voltage cutout trips in eclipse on a battery that is fine.
 *
 *	ECLIPSE, from orbitsim.c.  A 500km orbit is in shadow for about
 *	a third of every 94-minute pass, so the pack cycles every orbit
 *	whatever the attitude is -- and the balance over a whole orbit
 *	is what actually keeps a satellite alive.
 *
 *	echo drain 200 >/dev/power.ctl		milliamps
 *	echo volts 4200 >/dev/power.ctl		set the pack
 *	echo charging on >/dev/power.ctl		count up instead
 *	echo battery sim >/dev/power.ctl		#P/battery follows the pack
 *	echo battery adc >/dev/power.ctl		back to the real VBAT
 *	echo shunt 100 >/dev/power.ctl		milliohms, for a real part
 *	echo real >/dev/power.ctl		try the probe again
 */

enum {
	/*
	 * The ADM1176 is NOT a register file, which is why there is no
	 * table of register numbers here and why this is worth saying:
	 * a write of one command byte arms the converter, and a read of
	 * three bytes gives twelve bits of voltage and twelve of
	 * current packed across them.  Datasheet figures, unconfirmed
	 * against a part.
	 */
	Addr		= 0x4a,		/* 0x4a to 0x4d by part option */
	Cmdvicont	= 0x05,		/* V_CONT | I_CONT */
	Vfullmv		= 26350,	/* 26.35V across 4096 counts */
	Ifullmv		= 105840,	/* 105.84mV of shunt drop, microvolts/10 */

	Capacity	= 9360000,	/* mA.s: 2600mAh, a 1S 18650 */
	Resistance	= 80,		/* milliohms */
	Packfull	= 4200,
	Packempty	= 3000,
};

static I2Cdev *pwrdev;
static int triedprobe;
static int shuntmohm = 100;		/* a plausible 0.1 ohm sense */

extern int chgwants(void);
extern int orbiteclipse(void), orbittimescale(void);

/*
 * Open-circuit voltage against state of charge, in millivolts.  The
 * first two steps are five per cent and the rest ten, so the
 * resolution is at the knee -- which is where a threshold sits and
 * where a straight line is most wrong.
 */
static short ocvtab[12] = {
	3000, 3300, 3450, 3600, 3660, 3700,
	3740, 3790, 3860, 3950, 4060, 4200,
};

/* the modelled pack: the state is CHARGE and voltage follows from it */
static long charge = Capacity/2;	/* mA.s */
static int drainma = 120;
static int charging;
static int simbatt;			/* #P/battery follows the pack */
static int noise = 8;
static int sunma = 260;		/* panel current in full sun, mA */
static int solar;		/* what it is making now */
static ulong lastticks;
static int running;
/*
 * The milliamp-ticks not yet a milliamp-second.  Divided away, this was
 * a systematic undercount: at 450mA and a seven-tick interval the
 * quotient is 31.5 and the half was dropped on every read, so a pack
 * discharged more slowly the more often it was looked at.  The same
 * carry as the attitude integrator's, for the same reason.
 */
static vlong chargefrac;

static int
jitter(void)
{
	if(noise <= 0)
		return 0;
	return nrand(2*noise + 1) - noise;
}

/*
 * The open-circuit voltage at a state of charge given in tenths of a
 * per cent, interpolated inside whichever step it falls in.  Taking
 * the argument rather than reading the global is what lets the curve
 * be walked backwards, below.
 */
static int
ocvat(int pm)
{
	int i, lo, hi, span, base;

	if(pm <= 0)
		return ocvtab[0];
	if(pm >= 1000)
		return ocvtab[11];
	if(pm < 50){ i = 0; base = 0; span = 50; }
	else if(pm < 100){ i = 1; base = 50; span = 50; }
	else { i = pm/100 + 1; base = (i - 1) * 100; span = 100; }
	lo = ocvtab[i];
	hi = ocvtab[i+1];
	return lo + ((hi - lo) * (pm - base)) / span;
}

/* where the pack is on that curve now */
static int
soc(void)
{
	return (int)(((vlong)charge * 1000) / Capacity);
}

static int
ocv(void)
{
	return ocvat(soc());
}

/*
 * And backwards: the charge whose open-circuit voltage is v.  The
 * curve is monotonic, so a walk finds it, and a walk is honest about
 * the plateau -- several tenths of a per cent share a millivolt there,
 * and this returns the first, which is the pessimistic one.
 */
static long
chargefor(int mv)
{
	int pm;

	for(pm = 0; pm < 1000; pm++)
		if(ocvat(pm) >= mv)
			break;
	return (long)(((vlong)pm * Capacity) / 1000);
}

/*
 * What a voltmeter on the terminals reads: the open-circuit voltage
 * less the drop across the internal resistance, which becomes a rise
 * when charging.  Milliamps times milliohms is microvolts.
 *
 * This is why a pack reads differently in sun and in eclipse at the
 * same state of charge, and why a naive low-voltage cutout trips in
 * eclipse on a battery that is fine.
 */
static int
terminal(void)
{
	return ocv() - ((drainma - solar) * Resistance) / 1000;
}

/*
 * Advance the pack to now.  Called from every read of anything that
 * depends on it, so the curve is a function of time rather than of how
 * often it is looked at -- a pack that only discharges when observed
 * would make a task that polls twice as often see a different battery.
 */
void
packtick(void)
{
	ulong t, dt;
	vlong whole;

	t = m != nil? m->ticks: 0;
	if(!running){
		running = 1;
		lastticks = t;
		return;
	}
	dt = (t - lastticks) * orbittimescale();
	lastticks = t;
	/*
	 * ASK THE CHARGER RATHER THAN BE TOLD BY IT, which is the fix
	 * for a flag that went stale in a way nothing could see.
	 *
	 * chgbq25883.c used to PUSH "charging" here whenever its own
	 * files were read or written, and that is a decision stored
	 * where it is not used.  The init writes "in on" to the charger
	 * and then "volts 3700" to the pack -- in that order -- so the
	 * charger evaluated itself while the pack was still at its 4200
	 * default, concluded the battery was full, and set charging to
	 * zero.  Nothing re-evaluated it afterwards, so the panel made
	 * nothing for ever: the sun-seeking controller read "0mA of
	 * 260" on every sample and turned one way for an hour, steering
	 * by a number that no attitude could change.
	 *
	 * So the charger exports only what it knows -- whether there is
	 * input and whether it has faulted -- and whether charging is
	 * actually happening is worked out HERE, where the pack's
	 * voltage is, every time the pack moves.  One decision, made
	 * where both of its inputs are.
	 */
	charging = chgwants() && charge < Capacity && !orbiteclipse();
	/*
	 * SUN ON THE PANELS, which is what makes attitude control worth
	 * doing rather than merely possible: a tumbling satellite sweeps
	 * its panels through the sun and charges in pulses averaging
	 * under the draw, and a pointed one charges steadily.  The
	 * battery file is what says whether the control worked.
	 *
	 * And nothing charges in eclipse, however well it is pointed,
	 * which is the term above.
	 */
	if(charging){
		extern void imusunvec(int*);
		int sv[3], sun;

		/*
		 * TWO PANELS, ON +x AND +z, which is a geometry and not a
		 * convenience.  A 1U CubeSat carries body-mounted cells on
		 * several faces; one face is the arrangement nothing
		 * flies, and it is also the arrangement that makes
		 * sun-seeking impossible -- a single panel reads zero over
		 * a whole hemisphere, so a controller steering by its
		 * current has no gradient for half of all attitudes.  The
		 * sun task measured exactly that: "0mA of 260" on every
		 * sample, turning one way for ever.
		 *
		 * Each face sees max(0, its component), because a cell
		 * facing away makes nothing rather than negative power,
		 * and the two are summed and halved so that full sun
		 * square-on to one face is the full figure.  So the
		 * current is attitude-dependent -- which is what makes
		 * pointing worth doing -- and almost never flat, which is
		 * what makes it findable.
		 */
		imusunvec(sv);
		sun = 0;
		if(sv[0] > 0)
			sun += sv[0];
		if(sv[2] > 0)
			sun += sv[2];
		solar = (sunma * sun) / 2000;
	}else
		solar = 0;
	/*
	 * Coulomb counting.  net is positive when the load exceeds the
	 * panels, and the voltage is not stored at all -- it is read off
	 * the cell's curve whenever anybody asks.
	 */
	chargefrac = chargefrac + (vlong)(drainma - solar) * (vlong)dt;
	whole = chargefrac / HZ;
	chargefrac = chargefrac - whole * HZ;
	charge -= (long)whole;
	if(charge < 0)
		charge = 0;
	if(charge > Capacity)
		charge = Capacity;
}

int
packvolts(void)
{
	packtick();
	return terminal();
}

/*
 * Kept so the charger can say that something changed, but the flag
 * itself is now derived in packtick: see the note there.
 */
void
packcharge(int)
{
	packtick();
}

int
packischarging(void)
{
	return charging;
}

int
packfull(void)
{
	packtick();
	return charge >= Capacity;
}

/*
 * What #P/battery reports, or -1 to say "not me".  archfilespycubed.c
 * asks this first and falls back to the part's own VBAT channel, so the
 * default is a real measurement and the simulation has to be asked for.
 */
int
simpackmv(void)
{
	if(!simbatt)
		return -1;
	return packvolts() + jitter();
}

static int
pwrprobe(void)
{
	I2Cbus *bus;

	if(triedprobe)
		return pwrdev != nil;
	triedprobe = 1;
	bus = i2cbus("i2c3");
	if(bus == nil)
		return 0;
	pwrdev = i2cdev(bus, Addr);
	if(pwrdev == nil)
		return 0;
	/*
	 * There is no identity register to check, which is the honest
	 * difficulty with this part: anything that acknowledges at 0x4a
	 * looks like an ADM1176.  So the probe says what it assumed
	 * rather than claiming to have recognised anything.
	 */
	print("pwr: something answered at 0x%.2x on i2c3; assuming an"
		" ADM1176, which has no ID register to confirm it\n", Addr);
	return 1;
}

static s32
pwrread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[160];
	uchar d[3];
	int mv, ma;

	if(pwrprobe()){
		uchar cmd;

		cmd = Cmdvicont;
		if(i2csend(pwrdev, &cmd, 1, 0) != 1)
			error("pwr: command refused");
		if(i2crecv(pwrdev, d, sizeof d, 0) != sizeof d)
			error("pwr: short read");
		/*
		 * Twelve bits each, the low nibbles sharing the third
		 * byte: V in d[0] and the high nibble of d[2], I in d[1]
		 * and its low nibble.
		 */
		mv = (int)(((d[0] << 4) | (d[2] >> 4)) * (vlong)Vfullmv / 4096);
		ma = (int)(((d[1] << 4) | (d[2] & 0xf)) * (vlong)Ifullmv / 4096);
		/* shunt drop in microvolts/10 over milliohms gives mA */
		ma = shuntmohm > 0? ma / shuntmohm: -1;
		snprint(buf, sizeof buf,
			"source adm1176\nvolts %d\namps %d\nshunt %d\n",
			mv, ma, shuntmohm);
	}else{
		mv = packvolts();
		snprint(buf, sizeof buf,
			"source scripted\nvolts %d\namps %d\ncharging %d\n"
			"solar %d\ndraw %d\nopen %d\nsoc %d\neclipse %d\n",
			mv + jitter(),
			(drainma - solar) + jitter()/2,
			charging, solar, drainma,
			ocv(), soc(), orbiteclipse());
	}
	return readstr(offset, a, n, buf);
}

static s32
pwrctlread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[256];

	snprint(buf, sizeof buf,
		"source %s\n"
		"volts %d\n"
		"open %d\n"
		"soc %d per mille\n"
		"eclipse %d\n"
		"drain %d\n"
		"charging %d\n"
		"solar %d of %d in full sun\n"
		"battery %s\n"
		"shunt %d\n"
		"noise %d\n",
		pwrdev != nil? "adm1176": "scripted",
		packvolts(), ocv(), soc(), orbiteclipse(), drainma, charging, solar, sunma,
		simbatt? "sim": "adc", shuntmohm, noise);
	return readstr(offset, a, n, buf);
}

static s32
pwrctlwrite(Chan*, void *a, s32 n, s64)
{
	char buf[64], *fld[4];
	int nf, v;

	if(n >= sizeof buf)
		error(Ebadarg);
	memmove(buf, a, n);
	buf[n] = 0;
	nf = tokenize(buf, fld, nelem(fld));
	if(nf < 1)
		error(Ebadarg);
	if(strcmp(fld[0], "drain") == 0 && nf == 2){
		v = atoi(fld[1]);
		if(v < 0)
			error(Ebadarg);
		packtick();
		drainma = v;
	}else if(strcmp(fld[0], "volts") == 0 && nf == 2){
		v = atoi(fld[1]);
		if(v < Packempty || v > Packfull)
			error(Ebadarg);
		packtick();
		charge = chargefor(v);
	}else if(strcmp(fld[0], "charging") == 0 && nf == 2){
		if(strcmp(fld[1], "on") == 0)
			packcharge(1);
		else if(strcmp(fld[1], "off") == 0)
			packcharge(0);
		else
			error(Ebadarg);
	}else if(strcmp(fld[0], "battery") == 0 && nf == 2){
		if(strcmp(fld[1], "sim") == 0)
			simbatt = 1;
		else if(strcmp(fld[1], "adc") == 0)
			simbatt = 0;
		else
			error(Ebadarg);
	}else if(strcmp(fld[0], "sun") == 0 && nf == 2){
		v = atoi(fld[1]);
		if(v < 0)
			error(Ebadarg);
		packtick();
		sunma = v;
	}else if(strcmp(fld[0], "shunt") == 0 && nf == 2){
		v = atoi(fld[1]);
		if(v <= 0)
			error(Ebadarg);
		shuntmohm = v;
	}else if(strcmp(fld[0], "noise") == 0 && nf == 2){
		noise = atoi(fld[1]);
		if(noise < 0)
			noise = 0;
	}else if(strcmp(fld[0], "real") == 0 && nf == 1){
		triedprobe = 0;
		pwrdev = nil;
		pwrprobe();
	}else
		error(Ebadctl);
	return n;
}

void
pwradm1176link(void)
{
	addarchfile("power", 0444, pwrread, nil);
	addarchfile("power.ctl", 0666, pwrctlread, pwrctlwrite);
}
