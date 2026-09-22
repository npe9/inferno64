#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"radio.h"

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
 * WHAT HAS BEEN RUN, AND WHAT HAS NOT.  Nothing here has been spoken
 * to a radio.  There is no FT-891 on this bench and no serial port
 * free on the board that has the CC1120 in it -- a clicker 2's second
 * uart is mikroBUS 2's and the radio click is in that socket.  What is
 * tested is that it compiles, that the command strings are built and
 * parsed as the manual describes them, and that #W serves a radio with
 * no packet files without complaint.  A CAT string is exactly the kind
 * of thing that looks right and is not, so read anything below about
 * what a radio "answers" as what the manual says it answers.
 */

enum {
	Catlen		= 32,		/* longest command or reply */
	Catwaitms	= 500,		/* a set is acknowledged or not */
};

typedef struct Ft891 Ft891;
struct Ft891
{
	Radio;
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
	error(Ebadctl);
	return 0;
}

static int
ft891stat(Radio *r, char *p, int n)
{
	Ft891 *f;
	char buf[Catlen];
	uvlong hz;

	f = (Ft891*)r;
	hz = f->hz;
	if(cat(f, "FA;", buf, sizeof buf) > 3)
		hz = strtoul(buf+2, nil, 10);

	return snprint(p, n,
		"part FT-891 cat\n"
		"freq %llud\n"
		"mode %s\n"
		"state %d\n"
		"smeter %d\n"
		"power %d\n",
		hz,
		f->mode > 0? ft891modename[f->mode]: "unset",
		f->ptt? 2: 1,
		ft891smeter(f),
		f->watts);
}

static Radiodev ft891dev = {
	"FT-891",
	0,				/* no packets: see radio.h */
	nil,				/* and so no send */
	ft891ctl,
	ft891stat,
};

Radio*
ft891init(Serialport *p)
{
	Ft891 *f;
	char buf[Catlen];

	f = malloc(sizeof(Ft891));
	if(f == nil)
		return nil;
	f->dev = &ft891dev;
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
