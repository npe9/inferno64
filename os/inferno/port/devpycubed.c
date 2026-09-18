#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"pycubedif.h"

/*
 * The PyCubed hardware, as files.
 *
 * This is the boundary the mission logic in appl/pycubed sees, and it
 * is a device because that is how Inferno reaches hardware: a read here
 * is one system call into the kernel, the backend answers it, and there
 * is no second process anywhere.  The first version of this boundary
 * was a Limbo program serving the same files through sys->file2chan,
 * which routes every reading out through #s into another Dis process --
 * two scheduler switches and a Chan round trip to fetch a battery
 * voltage, and 29504 bytes of pool for the server.  See doc/pycubed-
 * plan.ms.
 *
 * The files, all text, integers rather than reals because the parts
 * this is for have no double-precision floating point:
 *
 *	source    read   what the backend is
 *	battery   read   "<millivolts>\n"
 *	rgb       write  "<r> <g> <b>"
 *	imu       read   "mag <x> <y> <z>\ngyro ...\naccel ...\n"
 *	radio     read   the packet received, 0 bytes if none
 *	          write  the packet to transmit
 *	radioctl  read   "rssi <dBm>\n"
 *	          write  "listen" or "sleep"
 *
 * The register access is the board's, through PycubedHw in pycubedif.h.
 * Those calls sleep -- I2C and SPI transactions -- so nothing here
 * holds a lock across one, and the device is read-mostly with no state
 * of its own to protect.
 */

enum
{
	Qdir,
	Qsource,
	Qbattery,
	Qrgb,
	Qimu,
	Qradio,
	Qradioctl,

	Maxpkt	= 256,		/* an RFM9x payload is 255 bytes */
};

static Dirtab pycubedtab[]=
{
	".",		{Qdir, 0, QTDIR},	0,	DMDIR|0555,
	"source",	{Qsource},		0,	0444,
	"battery",	{Qbattery},		0,	0444,
	"rgb",		{Qrgb},			0,	0222,
	"imu",		{Qimu},			0,	0444,
	"radio",	{Qradio},		0,	0666,
	"radioctl",	{Qradioctl},		0,	0666,
};

PycubedHw *pycubedhw;

static Chan*
pycubedattach(char *spec)
{
	if(pycubedhw == nil)
		error("no PyCubed hardware backend");
	return devattach('H', spec);
}

static Walkqid*
pycubedwalk(Chan *c, Chan *nc, char **name, s32 nname)
{
	return devwalk(c, nc, name, nname, pycubedtab, nelem(pycubedtab), devgen);
}

static s32
pycubedstat(Chan *c, uchar *db, s32 n)
{
	return devstat(c, db, n, pycubedtab, nelem(pycubedtab), devgen);
}

static Chan*
pycubedopen(Chan *c, u32 omode)
{
	return devopen(c, omode, pycubedtab, nelem(pycubedtab), devgen);
}

static void
pycubedclose(Chan*)
{
}

static s32
pycubedread(Chan *c, void *a, s32 n, s64 offset)
{
	char buf[128];
	int v[3], m;
	uchar pkt[Maxpkt];

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, pycubedtab, nelem(pycubedtab), devgen);

	switch((u32)c->qid.path){
	case Qsource:
		snprint(buf, sizeof buf, "%s\n", pycubedhw->name);
		return readstr(offset, a, n, buf);

	case Qbattery:
		snprint(buf, sizeof buf, "%d\n", pycubedhw->battmv());
		return readstr(offset, a, n, buf);

	case Qimu:
		/*
		 * One read, three lines: a caller asking for attitude
		 * gets the three axes of each sensor from one pass,
		 * rather than three opens that could straddle a motion.
		 */
		m = 0;
		v[0] = v[1] = v[2] = 0;
		if(pycubedhw->mag(v) < 0)
			v[0] = v[1] = v[2] = 0;
		m += snprint(buf+m, sizeof buf - m, "mag %d %d %d\n", v[0], v[1], v[2]);
		v[0] = v[1] = v[2] = 0;
		if(pycubedhw->gyro(v) < 0)
			v[0] = v[1] = v[2] = 0;
		m += snprint(buf+m, sizeof buf - m, "gyro %d %d %d\n", v[0], v[1], v[2]);
		v[0] = v[1] = v[2] = 0;
		if(pycubedhw->accel(v) < 0)
			v[0] = v[1] = v[2] = 0;
		snprint(buf+m, sizeof buf - m, "accel %d %d %d\n", v[0], v[1], v[2]);
		return readstr(offset, a, n, buf);

	case Qradioctl:
		snprint(buf, sizeof buf, "rssi %d\n", pycubedhw->radiorssi());
		return readstr(offset, a, n, buf);

	case Qradio:
		/*
		 * A packet or nothing.  Nothing is a zero-length read,
		 * not an error and not a wait: a radio that may never
		 * speak must not hold a process forever, and the caller
		 * decides how long to keep asking.
		 */
		if(n > Maxpkt)
			n = Maxpkt;
		m = pycubedhw->radiorecv(pkt, n);
		if(m <= 0)
			return 0;
		memmove(a, pkt, m);
		return m;
	}
	error(Egreg);
	return 0;
}

static s32
pycubedwrite(Chan *c, void *a, s32 n, s64)
{
	char buf[64], *fld[4];
	int nf;

	switch((u32)c->qid.path){
	case Qrgb:
		if(n >= sizeof buf)
			error(Ebadarg);
		memmove(buf, a, n);
		buf[n] = 0;
		nf = tokenize(buf, fld, nelem(fld));
		if(nf != 3)
			error(Ebadarg);
		pycubedhw->rgb(atoi(fld[0]), atoi(fld[1]), atoi(fld[2]));
		return n;

	case Qradioctl:
		if(n >= sizeof buf)
			error(Ebadarg);
		memmove(buf, a, n);
		buf[n] = 0;
		nf = tokenize(buf, fld, nelem(fld));
		if(nf != 1)
			error(Ebadarg);
		if(strcmp(fld[0], "listen") == 0)
			pycubedhw->radiolisten();
		else if(strcmp(fld[0], "sleep") == 0)
			pycubedhw->radiosleep();
		else
			error(Ebadarg);
		return n;

	case Qradio:
		if(n > Maxpkt)
			error(Etoobig);
		if(pycubedhw->radiosend(a, n) < 0)
			error(Eio);
		return n;
	}
	error(Eperm);
	return 0;
}

Dev pycubeddevtab = {
	'H',
	"pycubed",

	devreset,
	devinit,
	devshutdown,
	pycubedattach,
	pycubedwalk,
	pycubedstat,
	pycubedopen,
	devcreate,
	pycubedclose,
	pycubedread,
	devbread,
	pycubedwrite,
	devbwrite,
	devremove,
	devwstat,
};
