/*
 * The same file under emu and under a board kernel.  Only the
 * headers differ, and only because emu's are named differently; the
 * driver below is identical, which is the whole claim radio.h makes.
 */
#ifdef EMU
#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"radio.h"
#else
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"radio.h"
#endif

/*
 * A Yaesu FT-891, or anything else that speaks Yaesu CAT, as a #W
 * radio.
 *
 * This file exists to find out whether #W's idea of a radio is a
 * radio's or a CC1120's.  It shares nothing with cc1120.c: no SPI, no
 * registers, no FIFO, no interrupt, no packets at all.  What it has is
 * a frequency, a mode and a transmit key, which is what radio.h says a
 * radio is.  If the interface needed changing to fit this, the
 * interface was a description of one chip.
 *
 * It did need one change and only one: maxpayload is zero here, and #W
 * now serves no data and no pkt file for a radio that has none.  An
 * FT-891 has a microphone socket, not a payload.  lora(3), ax25(3) and
 * kiss(3) attach to data by file descriptor and so cannot run on this,
 * which is correct and is said in radio.h.
 *
 * CAT, from the FT-891 manual's reference: ASCII commands terminated
 * by ';', answers likewise.
 *
 *	FA<9 digits>;	set VFO A, in hertz.  FA; asks.
 *	MD0<n>;		set mode.  MD0; asks.
 *	TX1; / TX0;	key and unkey.  TX; asks.
 *	SM0;		read the S meter, SM0<3 digits>;
 *	PC<3 digits>;	transmit power in watts.  PC; asks.
 *	ID;		answers ID0650; on an FT-891.
 *
 * The mode digits are the manual's: 1 LSB, 2 USB, 3 CW, 4 FM, 5 AM,
 * 6 RTTY-LSB, 7 CW-R, 8 DATA-LSB, 9 RTTY-USB, A DATA-FM, B FM-N,
 * C DATA-USB, D AM-N, E C4FM.
 *
 * WHAT HAS BEEN RUN.  This has been spoken to an FT-891, over its own
 * USB port -- a CP2105's Enhanced Com Port, 4800 8N2 -- from emu on a
 * Mac.  The set answers ID0650; to ID;, its VFO follows FA, and FA;
 * reads back what was set.  See the emu #W notes in
 * emu/port/ft891emu.c for the host side.
 *
 * One trap cost an afternoon and is worth writing down, because from
 * above it looks exactly like a driver bug.  The FT-891's menu 05-08
 * CAT RTS defaults to ENABLE, and what that means is that the set
 * will not send a reply unless the PC has its RTS line deasserted.
 * Commands work perfectly -- the VFO moves, the mode changes -- and
 * every query is met with silence, so the natural conclusion is that
 * the replies are being lost somewhere in the host.  They are not
 * being sent.  Either set the line the way the set wants it or turn
 * the menu item off:
 *
 *	; echo 'cat EX05080;' >'#W/radio0/ctl'
 *
 * After that the modem lines do not matter at all, which was
 * confirmed over the four combinations of RTS and DTR.
 */

enum {
	Catlen		= 32,		/* longest command or reply */
	Catwaitms	= 500,		/* a set is acknowledged or not */
};

typedef struct Ft891 Ft891;
struct Ft891
{
	/*
	 * Named, not anonymous.  Plan 9 C would let this be "Radio;"
	 * and cc1120.c does exactly that, but this file is compiled by
	 * the host's compiler for emu as well, and ISO C has no
	 * anonymous member of a named type.  First, so that a Ft891*
	 * is a Radio*, which is what #W holds.
	 */
	Radio	r;
	Serialport *port;
	uvlong	hz;
	int	mode;			/* the manual's digit, as a char */
	int	ptt;
	int	watts;
};

static char ft891modes[] = "0123456789ABCDE";
static char *ft891modename[] = {
	nil, "lsb", "usb", "cw", "fm", "am", "rtty-l", "cw-r",
	"data-l", "rtty-u", "data-fm", "fm-n", "data-u", "am-n", "c4fm",
};

/*
 * One command, and the answer if the caller wants one.  A CAT reply
 * ends in ';'; silence is an answer too -- a radio that is switched
 * off says nothing, and waiting for ever for it is not better than
 * saying so.
 */
static int
cat(Ft891 *f, char *cmd, char *reply, int n)
{
	Serialport *p;
	uchar c;
	int i;

	p = f->port;
	p->lock(p);
	/*
	 * Anything still in the port is the tail of an earlier
	 * exchange -- a reply that arrived after its caller gave up,
	 * or the set volunteering something.  Left there it would be
	 * read as the answer to this command, and every answer after
	 * it would be one behind.
	 */
	if(reply != nil)
		while(p->read(p, &c, 1, 0) == 1)
			;
	if(p->write(p, cmd, strlen(cmd)) < 0){
		p->unlock(p);
		return -1;
	}
	if(reply == nil){
		p->unlock(p);
		return 0;
	}
	for(i = 0; i < n-1; ){
		if(p->read(p, &c, 1, Catwaitms) != 1)
			break;
		reply[i++] = c;
		if(c == ';')
			break;
	}
	p->unlock(p);
	reply[i] = 0;
	return i;
}

/*
 * Ask, and give back the body of the answer: everything between the
 * echoed command name and the ';'.  nil if the set said nothing or
 * said something else, which is not an error -- a set that is
 * switched off is a normal state of a radio, and the caller falls
 * back on what it last set.
 */
static char*
ft891ask(Ft891 *f, char *cmd, char *buf, int n)
{
	int i, ncmd;

	if(cat(f, cmd, buf, n) <= 0)
		return nil;
	for(ncmd = 0; cmd[ncmd] != 0 && cmd[ncmd] != ';'; ncmd++)
		;
	if(strncmp(buf, cmd, ncmd) != 0)
		return nil;
	for(i = ncmd; buf[i] != 0; i++)
		if(buf[i] == ';'){
			buf[i] = 0;
			break;
		}
	return buf + ncmd;
}

/*
 * What the set is doing now, as against what it was last told.  They
 * are not the same thing: an FT-891 has a knob, and a driver that
 * reports its own last command is reporting the past.
 */
static uvlong
ft891askfreq(Ft891 *f)
{
	char buf[Catlen], *v;

	v = ft891ask(f, "FA;", buf, sizeof buf);
	if(v == nil || *v == 0)
		return f->hz;
	f->hz = strtoul(v, nil, 10);
	return f->hz;
}

static int
ft891askmode(Ft891 *f)
{
	char buf[Catlen], *v;
	int i;

	v = ft891ask(f, "MD0;", buf, sizeof buf);
	if(v == nil || *v == 0)
		return f->mode;
	for(i = 1; i < nelem(ft891modes) && ft891modes[i] != 0; i++)
		if(ft891modes[i] == v[0]){
			f->mode = i;
			break;
		}
	return f->mode;
}

static int
ft891askptt(Ft891 *f)
{
	char buf[Catlen], *v;

	v = ft891ask(f, "TX;", buf, sizeof buf);
	if(v == nil || *v == 0)
		return f->ptt;
	/* 0 receiving, 1 transmitting by CAT, 2 transmitting by PTT */
	f->ptt = v[0] != '0';
	return f->ptt;
}

static int
ft891askpower(Ft891 *f)
{
	char buf[Catlen], *v;

	v = ft891ask(f, "PC;", buf, sizeof buf);
	if(v == nil || *v == 0)
		return f->watts;
	f->watts = atoi(v);
	return f->watts;
}

static int
ft891freq(Ft891 *f, uvlong hz)
{
	char buf[Catlen];

	if(hz < 30000ULL || hz > 56000000ULL)
		return -1;		/* the set's own range */
	snprint(buf, sizeof buf, "FA%.9llud;", hz);
	if(cat(f, buf, nil, 0) < 0)
		return -1;
	f->hz = hz;
	return 0;
}

static int
ft891mode(Ft891 *f, char *name)
{
	char buf[Catlen];
	int i;

	for(i = 1; i < nelem(ft891modename); i++)
		if(ft891modename[i] != nil && strcmp(name, ft891modename[i]) == 0)
			break;
	if(i >= nelem(ft891modename))
		return -1;
	snprint(buf, sizeof buf, "MD0%c;", ft891modes[i]);
	if(cat(f, buf, nil, 0) < 0)
		return -1;
	f->mode = i;
	return 0;
}

static int
ft891key(Ft891 *f, int on)
{
	if(cat(f, on? "TX1;": "TX0;", nil, 0) < 0)
		return -1;
	f->ptt = on != 0;
	return 0;
}

/*
 * The S meter, as dBm.  SM0 gives 0 to 255 across the scale; S9 is
 * -73dBm by convention and the scale below it is 6dB an S point.  The
 * conversion is the usual approximation and is not a calibration of
 * any particular set, which is why stat says "smeter" beside it.
 */
static int
ft891smeter(Ft891 *f)
{
	char buf[Catlen];
	int raw;

	if(cat(f, "SM0;", buf, sizeof buf) < 4)
		return -128;
	raw = atoi(buf+3);
	return -127 + (raw * 94) / 255;
}

static int
ft891ctl(Radio *r, char *buf, int n)
{
	Ft891 *f;
	char *fl[4], cbuf[64];
	int nf;

	f = (Ft891*)r;
	if(n >= sizeof cbuf)
		n = sizeof cbuf - 1;
	memmove(cbuf, buf, n);
	cbuf[n] = 0;
	nf = tokenize(cbuf, fl, nelem(fl));
	if(nf < 1)
		error(Ebadctl);

	if(strcmp(fl[0], "freq") == 0 && nf == 2){
		if(ft891freq(f, strtoul(fl[1], nil, 0)) < 0)
			error("radio: outside this set's range");
		return n;
	}
	if(strcmp(fl[0], "mode") == 0 && nf == 2){
		if(ft891mode(f, fl[1]) < 0)
			error("radio: this set has no such mode");
		return n;
	}
	if(strcmp(fl[0], "ptt") == 0 && nf == 2){
		if(ft891key(f, strcmp(fl[1], "on") == 0) < 0)
			error("radio: the set did not answer");
		return n;
	}
	if(strcmp(fl[0], "power") == 0 && nf == 2){
		char cmd[Catlen];
		int w;

		/*
		 * The set takes watts and #W's vocabulary is dBm, so
		 * this converts: 30dBm is 1W and every 10dB is ten
		 * times the power.  Integer, and deliberately coarse --
		 * an HF set's power control is a knob with a hundred
		 * positions, not a calibration.
		 */
		w = atoi(fl[1]);
		if(w >= 30)
			w = (w >= 50)? 100: (w >= 40)? 10: 1;
		else
			w = 1;
		snprint(cmd, sizeof cmd, "PC%.3d;", w);
		if(cat(f, cmd, nil, 0) < 0)
			error("radio: the set did not answer");
		f->watts = w;
		return n;
	}
	if(strcmp(fl[0], "rx") == 0){
		ft891key(f, 0);
		return n;
	}
	if(strcmp(fl[0], "idle") == 0){
		ft891key(f, 0);
		return n;
	}
	if(strcmp(fl[0], "cat") == 0 && nf == 2){
		/*
		 * Anything the manual has and this driver has not.  The
		 * bench, as reg is on the CC1120: a radio with a
		 * hundred CAT commands should not need a kernel change
		 * to answer one of them.
		 */
		char reply[Catlen];

		if(cat(f, fl[1], reply, sizeof reply) < 0)
			error("radio: the set did not answer");
		print("cat %s %s\n", fl[1], reply);
		return n;
	}
	/*
	 * Not a radio's verb.  A serial-attached radio sits on a port
	 * that has settings of its own -- which device, what rate --
	 * and those belong to the transport, not to the set.  If it
	 * has a ctl, it gets the chance before this is an error.
	 */
	if(f->port->ctl != nil)
		return f->port->ctl(f->port, buf, n);
	error(Ebadctl);
	return 0;
}

static int
ft891stat(Radio *r, char *p, int n)
{
	Ft891 *f;
	uvlong hz;
	int mode, ptt;

	f = (Ft891*)r;
	hz = ft891askfreq(f);
	mode = ft891askmode(f);
	ptt = ft891askptt(f);

	return snprint(p, n,
		"part FT-891 cat\n"
		"freq %llud\n"
		"mode %s\n"
		"state %d\n"
		"smeter %d\n"
		"power %d\n",
		hz,
		mode > 0? ft891modename[mode]: "unset",
		ptt? 2: 1,
		ft891smeter(f),
		ft891askpower(f));
}

/*
 * The set's bands, from the FT-891 manual's specifications: it
 * receives 30kHz to 56MHz continuously and transmits in the amateur
 * allocations inside that.  The power is 5 to 100W, which is +37 to
 * +50dBm.
 *
 * These are the set's, not this driver's: nothing here has asked an
 * FT-891 what it has, and a radio that has been modified or is sold
 * to a different administration has different ones.  Hamlib solves
 * that with a table per model; this is one model.
 */
static struct {
	uvlong	lo;
	uvlong	hi;
} ft891tx[] = {
	{  1800000ULL,   2000000ULL },
	{  3500000ULL,   4000000ULL },
	{  5330500ULL,   5403500ULL },
	{  7000000ULL,   7300000ULL },
	{ 10100000ULL,  10150000ULL },
	{ 14000000ULL,  14350000ULL },
	{ 18068000ULL,  18168000ULL },
	{ 21000000ULL,  21450000ULL },
	{ 24890000ULL,  24990000ULL },
	{ 28000000ULL,  29700000ULL },
	{ 50000000ULL,  54000000ULL },
};

static int
ft891caps(Radio *r, char *p, int n)
{
	Ft891 *f;
	char *e, *q;
	int i;

	f = (Ft891*)r;
	q = p;
	e = p + n;
	/*
	 * The settable part is read from the set and not from this
	 * struct.  devvga and devaudio answer a ctl read with what may
	 * be written to it, and what may be written here is what the
	 * set is doing -- so "cat ctl >ctl" has to be the identity, and
	 * it is not if the knob has been turned since.
	 */
	q = seprint(q, e, "freq %llud\n", ft891askfreq(f));
	i = ft891askmode(f);
	q = seprint(q, e, "mode %s\n", i > 0? ft891modename[i]: "unset");
	q = seprint(q, e, "ptt %s\n", ft891askptt(f)? "on": "off");
	q = seprint(q, e, "power %d\n", ft891askpower(f));
	q = seprint(q, e, "band rx 30000 56000000\n");
	for(i = 0; i < nelem(ft891tx); i++)
		q = seprint(q, e, "band tx %llud %llud 37 50\n",
			ft891tx[i].lo, ft891tx[i].hi);
	q = seprint(q, e, "modes");
	for(i = 1; i < nelem(ft891modename); i++)
		if(ft891modename[i] != nil)
			q = seprint(q, e, " %s", ft891modename[i]);
	q = seprint(q, e, "\n");
	q = seprint(q, e, "levels strength rfpower\n");
	return q - p;
}

static Radiodev ft891dev = {
	"FT-891",
	0,				/* no packets: see radio.h */
	nil,				/* and so no send */
	ft891ctl,
	ft891stat,
	nil,				/* no bench: it is not our radio */
	ft891caps,
};

Radio*
ft891init(Serialport *p)
{
	Ft891 *f;
	char buf[Catlen];

	f = malloc(sizeof(Ft891));
	if(f == nil)
		return nil;
	f->r.dev = &ft891dev;
	f->port = p;

	/*
	 * Ask what it is.  An FT-891 answers ID0650;.  A set that is
	 * switched off answers nothing, which is not an error worth
	 * refusing over -- it may be switched on later -- so this says
	 * what it found and carries on.
	 */
	if(cat(f, "ID;", buf, sizeof buf) > 0)
		print("ft891 %s: answered %s\n", p->name, buf);
	else
		print("ft891 %s: no answer to ID;\n", p->name);
	return f;
}
