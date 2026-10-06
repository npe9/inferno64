#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/i2c.h"

/*
 * A BQ25883 battery charger at #P/charge, with a scripted charger
 * behind it until a part answers.  imubmx160.c carries the long version
 * of what that division means; it applies here unchanged.
 *
 * THE PACK IS NOT HERE.  pwradm1176.c owns the battery's voltage,
 * because a battery has one voltage however many parts look at it, and
 * this file asks that model to charge rather than keeping a second copy
 * that could disagree with it.  So "echo in on" here makes the voltage
 * #P/power reports go UP, and the two files stay consistent by
 * construction rather than by being updated together.
 *
 * WHAT A CHARGER'S STATE MACHINE IS FOR, and why it is worth
 * simulating rather than hard-coding "charging": the interesting
 * transitions are the ones flight software gets wrong.  Input appears
 * and disappears while the satellite is in and out of sun; a pack at
 * termination voltage stops charging and must not be reported as
 * discharging; a fault latches and has to be cleared rather than
 * cleared by itself.  All four states are reachable from the ctl file,
 * including the fault, because the path nobody can provoke is the path
 * nobody has tested.
 *
 *	echo in on >/dev/charge.ctl	input power present
 *	echo in off >/dev/charge.ctl	eclipse
 *	echo fault >/dev/charge.ctl	latch a fault
 *	echo clear >/dev/charge.ctl	clear it
 *	echo limit 500 >/dev/charge.ctl	input current limit, mA
 *	echo real >/dev/charge.ctl	try the probe again
 */

enum {
	/*
	 * BQ25883 register map, from the datasheet and unconfirmed
	 * against a part.  Only the three this file reads are named;
	 * the charger has a dozen more and naming ones nothing uses
	 * would be a table nobody checks.
	 */
	Addr		= 0x6b,
	Rchargectl	= 0x04,
	  Chgen		= 1<<5,		/* EN_CHG */
	Rstat0		= 0x0b,		/* charge status */
	  Statmask	= 3<<3,
	  Statnone	= 0<<3,
	  Stattrickle	= 1<<3,
	  Statfast	= 2<<3,
	  Statdone	= 3<<3,
	  Pgstat	= 1<<2,		/* input power good */
	Rfault0		= 0x0d,
	Rpartinfo	= 0x17,
	  Bq25883pn	= 0x03,		/* PN field, bits 5:3 */

	Vterm		= 4200,		/* where the scripted pack stops */
};

extern int packvolts(void);
extern void packcharge(int);
extern int packischarging(void);
extern int packfull(void);

static I2Cdev *chgdev;
static int triedprobe;

/* the scripted charger */
static int inpower = 1;			/* input present */
static int faulted;
static int limitma = 500;

static char *
chgstate(void)
{
	if(faulted)
		return "fault";
	if(!inpower)
		return "discharging";
	if(packfull())
		return "done";
	if(packvolts() < 3000 + 100)
		return "trickle";
	return "fast";
}

/*
 * What this charger KNOWS, as opposed to what follows from it: whether
 * there is input and whether it has faulted.  Whether the pack is
 * actually charging depends on the pack's voltage as well, and
 * pwradm1176.c works that out where the voltage is -- see the note on
 * packtick there, and the hour the sun-seeking controller spent
 * steering by a stale flag.
 */
int
chgwants(void)
{
	return inpower && !faulted;
}

/*
 * Nudge the pack so its model is up to date after something here
 * changed.  It no longer carries the decision; packtick derives it.
 */
static void
settle(void)
{
	packcharge(0);
}

static int
chgprobe(void)
{
	I2Cbus *bus;
	int pn;

	if(triedprobe)
		return chgdev != nil;
	triedprobe = 1;
	bus = i2cbus("i2c3");
	if(bus == nil)
		return 0;
	chgdev = i2cdev(bus, Addr);
	if(chgdev == nil)
		return 0;
	pn = i2creadbyte(chgdev, Rpartinfo);
	if(pn < 0 || ((pn >> 3) & 7) != Bq25883pn){
		print("charge: 0x%.2x answered but PART_INFO is 0x%.2x,"
			" PN %d, not a BQ25883's %d\n", Addr, pn,
			pn < 0? -1: (pn >> 3) & 7, Bq25883pn);
		chgdev = nil;
		return 0;
	}
	print("charge: BQ25883 at 0x%.2x on i2c3\n", Addr);
	return 1;
}

static s32
chgread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[160];
	int st, fault;
	char *s;

	if(chgprobe()){
		st = i2creadbyte(chgdev, Rstat0);
		fault = i2creadbyte(chgdev, Rfault0);
		if(st < 0 || fault < 0)
			error("charge: read refused");
		switch(st & Statmask){
		case Stattrickle:	s = "trickle"; break;
		case Statfast:		s = "fast"; break;
		case Statdone:		s = "done"; break;
		default:		s = "discharging"; break;
		}
		if(fault != 0)
			s = "fault";
		snprint(buf, sizeof buf,
			"source bq25883\nstate %s\ninput %d\nfault 0x%.2x\n",
			s, (st & Pgstat) != 0, fault);
	}else{
		settle();
		snprint(buf, sizeof buf,
			"source scripted\nstate %s\ninput %d\nlimit %d\n"
			"volts %d\n",
			chgstate(), inpower, limitma, packvolts());
	}
	return readstr(offset, a, n, buf);
}

static s32
chgctlread(Chan*, void *a, s32 n, s64 offset)
{
	char buf[256];

	settle();
	snprint(buf, sizeof buf,
		"source %s\n"
		"state %s\n"
		"input %d\n"
		"fault %d\n"
		"limit %d\n"
		"charging %d\n",
		chgdev != nil? "bq25883": "scripted",
		chgstate(), inpower, faulted, limitma, packischarging());
	return readstr(offset, a, n, buf);
}

static s32
chgctlwrite(Chan*, void *a, s32 n, s64)
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
	if(strcmp(fld[0], "in") == 0 && nf == 2){
		if(strcmp(fld[1], "on") == 0)
			inpower = 1;
		else if(strcmp(fld[1], "off") == 0)
			inpower = 0;
		else
			error(Ebadarg);
	}else if(strcmp(fld[0], "fault") == 0 && nf == 1)
		faulted = 1;
	else if(strcmp(fld[0], "clear") == 0 && nf == 1)
		faulted = 0;
	else if(strcmp(fld[0], "limit") == 0 && nf == 2){
		v = atoi(fld[1]);
		if(v < 0)
			error(Ebadarg);
		limitma = v;
	}else if(strcmp(fld[0], "real") == 0 && nf == 1){
		triedprobe = 0;
		chgdev = nil;
		chgprobe();
	}else
		error(Ebadctl);
	settle();
	return n;
}

void
chgbq25883link(void)
{
	addarchfile("charge", 0444, chgread, nil);
	addarchfile("charge.ctl", 0666, chgctlread, chgctlwrite);
}
