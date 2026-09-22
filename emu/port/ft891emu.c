/*
 * An FT-891 on a host serial port, as #W/radio0 under emu.
 *
 * Two pieces that are deliberately separate.  The radio is
 * os/inferno/radio/ft891.c and knows CAT and nothing else; this file
 * is the Serialport underneath it -- a host device opened with
 * open(2), set to a line rate with termios, read with a timeout --
 * and knows nothing about radios.  That is the split radio.h
 * describes, and an FT-891 driven from a board's uart would replace
 * this file and nothing else.
 *
 * The port is not chosen at compile time.  A host has a dozen serial
 * devices and which one has a radio behind it is not something a
 * kernel can know:
 *
 *	; bind -a '#W' /dev
 *	; echo port /dev/cu.usbserial-0121C13C0 >/dev/radio0/ctl
 *	; echo rate 38400 >/dev/radio0/ctl
 *	; cat /dev/radio0/ctl
 *
 * Until a port is set the radio answers what it can and says the rest
 * is unknown, which is better than refusing to exist: the ctl file is
 * how you tell it where to look, so it has to be there first.
 */
#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"radio.h"

#include	<sys/types.h>
#include	<sys/stat.h>
#include	<fcntl.h>
#include	<termios.h>
#include	<unistd.h>
#include	<errno.h>
#include	<sys/select.h>

typedef struct Hostport Hostport;
struct Hostport
{
	Serialport p;			/* first: a Hostport* is a Serialport* */
	int	fd;
	int	rate;
	char	path[256];
	QLock	l;
};

static Hostport hostport;
static Radio *theradio;

static void
hplock(Serialport *p)
{
	qlock(&((Hostport*)p)->l);
}

static void
hpunlock(Serialport *p)
{
	qunlock(&((Hostport*)p)->l);
}

static int
hpwrite(Serialport *p, void *buf, int n)
{
	Hostport *h;

	h = (Hostport*)p;
	if(h->fd < 0)
		return -1;
	return write(h->fd, buf, n);
}

/*
 * Read up to n bytes, waiting no longer than ms for the first of
 * them.  A CAT reply is a line ending in ';' and a radio that is
 * switched off sends none at all, so the caller gets what arrived and
 * decides; see the note in ft891.c about treating silence as an
 * answer.
 */
static int
hpread(Serialport *p, void *buf, int n, int ms)
{
	Hostport *h;
	struct timeval tv;
	fd_set r;
	int rv;

	h = (Hostport*)p;
	if(h->fd < 0)
		return -1;
	FD_ZERO(&r);
	FD_SET(h->fd, &r);
	tv.tv_sec = ms / 1000;
	tv.tv_usec = (ms % 1000) * 1000;
	rv = select(h->fd+1, &r, nil, nil, &tv);
	if(rv <= 0)
		return 0;
	rv = read(h->fd, buf, n);
	return rv < 0? 0: rv;
}

/*
 * Open a host device and set the line.  8N2 is what a Yaesu CAT port
 * wants; the rate is a menu item on the radio and so is a setting
 * here rather than a constant.
 */
static int
hpopen(Hostport *h, char *path, int rate)
{
	struct termios t;
	int fd;

	fd = open(path, O_RDWR|O_NOCTTY|O_NONBLOCK);
	if(fd < 0)
		return -1;
	if(tcgetattr(fd, &t) < 0){
		close(fd);
		return -1;
	}
	cfmakeraw(&t);
	t.c_cflag = CS8 | CREAD | CLOCAL | CSTOPB;	/* 8N2 */
	t.c_cc[VMIN] = 0;
	t.c_cc[VTIME] = 0;
	cfsetispeed(&t, rate);
	cfsetospeed(&t, rate);
	if(tcsetattr(fd, TCSANOW, &t) < 0){
		close(fd);
		return -1;
	}
	if(h->fd >= 0)
		close(h->fd);
	h->fd = fd;
	h->rate = rate;
	utfecpy(h->path, h->path+sizeof h->path, path);
	return 0;
}

/*
 * The port and rate commands.  These reach here through the
 * Serialport's ctl, after ft891.c has failed to recognise them --
 * which is right, because a radio does not know what a serial port
 * is.
 */
static int
hpctl(Serialport *p, char *buf, int n)
{
	char *f[3], cbuf[300];
	int nf;

	USED(p);
	if(n >= sizeof cbuf)
		n = sizeof cbuf - 1;
	memmove(cbuf, buf, n);
	cbuf[n] = 0;
	nf = tokenize(cbuf, f, nelem(f));
	if(nf >= 1 && strcmp(f[0], "port") == 0 && nf == 2){
		if(hpopen(&hostport, f[1], hostport.rate) < 0)
			error("radio: cannot open that port");
		return n;
	}
	if(nf >= 1 && strcmp(f[0], "rate") == 0 && nf == 2){
		int rate;

		rate = atoi(f[1]);
		if(rate < 300 || rate > 921600)
			error(Ebadctl);
		if(hostport.path[0] != 0 && hpopen(&hostport, hostport.path, rate) < 0)
			error("radio: cannot set that rate");
		hostport.rate = rate;
		return n;
	}
	error(Ebadctl);
	return 0;
}

/*
 * One radio, socket 0.  #W asks about every socket it serves and a
 * nil answer is how a socket says nothing is fitted, so anything but
 * 0 must be nil -- otherwise the same radio appears in every slot.
 */
Radio*
radioget(int i)
{
	return i == 0? theradio: nil;
}

/*
 * Called by #W's init.  There is one radio here and it is an FT-891
 * on whatever serial port the ctl file is later told about; the set
 * is not asked anything until then, so this cannot fail for want of
 * a radio being switched on.
 */
void
radiolink(void)
{
	hostport.p.name = "host";
	hostport.fd = -1;
	hostport.rate = 38400;
	hostport.p.write = hpwrite;
	hostport.p.read = hpread;
	hostport.p.lock = hplock;
	hostport.p.unlock = hpunlock;
	hostport.p.ctl = hpctl;
	theradio = ft891init(&hostport.p);
}
