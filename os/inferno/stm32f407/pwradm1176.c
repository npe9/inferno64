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
 * THE DISCHARGE IS DELIBERATELY FAST.  A 2000mAh pack at 200mA takes
 * ten hours, and a fixture nobody can watch is not a fixture: this
 * falls a millivolt per hundred milliamp-seconds, so 200mA walks
 * 4200mV down to 3000 in about ten minutes.  It is a ramp with noise on
 * it and not a lithium discharge curve -- no plateau, no knee, no
 * internal resistance -- and software tuned against its shape would be
 * tuned against nothing.  What it is for is the THRESHOLD CROSSINGS:
 * beepsat's vbatt task compares against 3.6V and this makes that
 * comparison happen while somebody is looking.
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

	Packfull	= 4200,
	Packempty	= 3000,
	/*
	 * Milliamp-seconds to a millivolt.  See the note above: this
	 * number is chosen so a bench run shows the whole range.
	 */
	Maspermv	= 100,
};

static I2Cdev *pwrdev;
static int triedprobe;
static int shuntmohm = 100;		/* a plausible 0.1 ohm sense */

/* the scripted pack */
static int packmv = Packfull;
static int drainma = 120;
static int charging;
static int simbatt;			/* #P/battery follows the pack */
static int noise = 8;
static ulong lastticks;
static long carry;			/* milliamp-seconds not yet a mV */

static int
jitter(void)
{
	if(noise <= 0)
		return 0;
	return nrand(2*noise + 1) - noise;
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
	long mas;

	t = m != nil? m->ticks: 0;
	dt = t - lastticks;
	lastticks = t;
	if(dt > 100*60)
		return;				/* first call, or a gap */
	mas = ((long)(charging? -drainma: drainma) * (long)dt) / HZ;
	carry += mas;
	while(carry >= Maspermv){
		carry -= Maspermv;
		packmv--;
	}
	while(carry <= -Maspermv){
		carry += Maspermv;
		packmv++;
	}
	if(packmv < Packempty)
		packmv = Packempty;
	if(packmv > Packfull)
		packmv = Packfull;
}

int
packvolts(void)
{
	packtick();
	return packmv;
}

void
packcharge(int on)
{
	packtick();
	charging = on != 0;
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
	return packmv >= Packfull;
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
			"source scripted\nvolts %d\namps %d\ncharging %d\n",
			mv + jitter(),
			(charging? -drainma: drainma) + jitter()/2,
			charging);
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
		"drain %d\n"
		"charging %d\n"
		"battery %s\n"
		"shunt %d\n"
		"noise %d\n",
		pwrdev != nil? "adm1176": "scripted",
		packvolts(), drainma, charging,
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
		packmv = v;
		carry = 0;
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
