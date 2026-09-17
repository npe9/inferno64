#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

/*
 * The input device: two files, kbd and mouse, which are the two rio
 * reads.
 *
 * The bytes come from p9kbd.c, the user-space i8042 driver this
 * personality already runs: it owns the whole controller, reads every
 * byte off port 0x60 with its own inb, and routes each by the status
 * port's aux bit.  Until now it printed what it read.  It hands the
 * keyboard's scancodes and the mouse's packets here instead, and this
 * device makes them the two files a Plan 9 program expects - /dev/kbd
 * in the character form ("c" then the rune) and /dev/mouse in the
 * record form ("m" then four twelve-column fields).
 *
 * Why here rather than in a program of its own.  The microkernel
 * exposes the PS/2 controller exactly once, and on this configuration
 * it exposes it as two interrupt notifications to this container, with
 * the ports granted to this process - not as the polled "kbdring" and
 * "mousering" physical segments the full personality's kbd.c and
 * mouse.c segattach.  Both arrangements cannot run at once: the
 * kernel's own handler would drain the byte the driver's handshake is
 * waiting for, and arming both hangs the boot in the command-byte
 * read.  So on this personality the driver is p9kbd.c, and the file a
 * container opens is served by the personality that holds the driver -
 * which is what the buddy is for.  A container asks for /dev/kbd and
 * the call is answered here, in user space, above the kernel.
 *
 * The device is #m.  Plan 9 puts /dev/mouse on #m and /dev/kbd on the
 * console device, and one letter cannot be both; here it is one device
 * because it is one driver reading one controller, and #m is the letter
 * of the two a program is more likely to look for by name.  #I, which
 * would have been the obvious letter for an input device, is devip's -
 * a bind of it succeeds and puts the IP stack's files on /dev, and the
 * open of /dev/mouse that follows says only that it does not exist.
 *
 * There are two more files, and they are here because rio opens them
 * before it will believe it has a keyboard: it opens /dev/cons and
 * /dev/consctl and gives up if either fails, and only then does it look
 * for /dev/kbd and prefer it.  So cons is the same runes as kbd without
 * the leading c - which is what cons is on a Plan 9 machine, the
 * keyboard as characters - and consctl takes rawon and rawoff and does
 * nothing with them, because there is no cooked mode here to turn off:
 * this device never echoes and never assembles a line.  A write to cons
 * goes to the console, which is what makes it a console.
 *
 * A read of kbd, cons or mouse waits.  It waits on a worker, because a
 * forwarded call runs on one, and there are four of them; rio parks two
 * of the four for as long as it runs, which is worth knowing before a
 * fifth blocking reader is added.
 */

enum {
	Qdir = 0,
	Qkbd,
	Qmouse,
	Qcons,
	Qconsctl,

	Nrune	= 64,		/* the keyboard's queue of runes */
	Winw	= 1280,		/* the exposed frame buffer, as kbd.c and mouse.c have it */
	Winh	= 800,
};

static Dirtab inputdir[] = {
	".",		{Qdir, 0, QTDIR},	0,	DMDIR|0555,
	"kbd",		{Qkbd},			0,	0666,
	"mouse",	{Qmouse},		0,	0666,
	"cons",		{Qcons},		0,	0666,
	"consctl",	{Qconsctl},		0,	0222,
};

static Rune	kq[Nrune];
static ulong	kin, kout;		/* the queue's ends, counted not wrapped */
static Rendez	kr;
static int	nkeysaid;

static int	mx = Winw/2, my = Winh/2, mb;

/*
 * Where the pointer is, for the container that draws it.
 *
 * The arrow is the draw server's to composite, because the draw server
 * owns the frame buffer, and this personality is the one that knows
 * where the pointer is: the controller is granted whole to this
 * container and this driver reads port 0x60 itself, so no kernel handler
 * fills the "mousering" page the full personality's draw server reads.
 * The kernel publishes a page for the position instead - "pointerpos",
 * two ints at offset 0 - and this writes it every time the position
 * changes.  Attached lazily, on the first packet, because the device is
 * initialised before the segment exists; a personality on a kernel
 * without one just has no arrow, as before.
 */
static int	*ptrpos;
static int	ptrtried;

static void
pointerpos(void)
{
	void *v;

	if(ptrpos == nil){
		if(ptrtried)
			return;
		ptrtried = 1;
		v = (void*)segattach(0, "pointerpos", 0, 4096);
		if(v == (void*)-1 || v == nil)
			return;
		ptrpos = v;
	}
	ptrpos[0] = mx;
	ptrpos[1] = my;
	ptrpos[2] = 1;			/* and that a pointer has been reported at all */
}

static ulong	mgen = 1;		/* bumped by every change; a reader's mark */
static Rendez	mr;
static int	nmousesaid;

extern vlong	p9nsec(void);		/* the kernel's clock, through devtime's xcall */

/*
 * Called by p9kbd.c for each rune it has translated.  It runs in the
 * driver kproc, so it may not sleep: it drops the oldest rune when the
 * queue is full rather than wait for a reader that may not exist.
 */
void
inputkey(Rune r)
{
	if(kin - kout >= Nrune)
		kout++;			/* the queue is full: lose the oldest */
	kq[kin++ % Nrune] = r;
	/*
	 * Say what arrived, for the first few.  The driver's own print says
	 * a scancode was read off the port; this says a rune reached the
	 * file, which is the translation and the queue and not the same
	 * claim.  Rate-limited because a keyboard in use is not a log.
	 */
	if(nkeysaid < 8){
		nkeysaid++;
		if(r >= ' ' && r < 0x7f)
			print("p9 input: /dev/kbd queued the rune %#ux, '%c'\n", r, (char)r);
		else
			print("p9 input: /dev/kbd queued the rune %#ux\n", r);
	}
	wakeup(&kr);
}

/*
 * And for each mouse packet, as the driver decoded it: a relative
 * movement and the three buttons in PS/2 order.  The position is kept
 * here, clamped to the screen, because /dev/mouse is absolute.
 */
void
inputmouse(int dx, int dy, int buttons)
{
	mx += dx;
	my -= dy;			/* PS/2 counts up, the screen counts down */
	if(mx < 0) mx = 0;
	if(mx >= Winw) mx = Winw-1;
	if(my < 0) my = 0;
	if(my >= Winh) my = Winh-1;
	/* PS/2 has left, right, middle in bits 0, 1, 2; Plan 9 has 1, 2, 4 */
	mb = (buttons & 1) | ((buttons & 4) ? 2 : 0) | ((buttons & 2) ? 4 : 0);
	mgen++;
	pointerpos();			/* and where the draw server should put the arrow */
	/* and the same for the mouse: where the packet put the pointer */
	if(nmousesaid < 8){
		nmousesaid++;
		print("p9 input: /dev/mouse is at %d %d %d after a packet\n", mx, my, mb);
	}
	wakeup(&mr);
}

static int
haverune(void*)
{
	return kin != kout;
}

static int
moved(void *a)
{
	return mgen != *(ulong*)a;
}

static Chan*
inputattach(char *spec)
{
	return devattach('m', spec);
}

static Walkqid*
inputwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, inputdir, nelem(inputdir), devgen);
}

static int
inputstat(Chan *c, uchar *dp, int n)
{
	return devstat(c, dp, n, inputdir, nelem(inputdir), devgen);
}

static Chan*
inputopen(Chan *c, int omode)
{
	c = devopen(c, omode, inputdir, nelem(inputdir), devgen);
	/*
	 * A fid's own mark in the mouse's sequence.  One behind, so that
	 * the first read answers with where the pointer is rather than
	 * waiting for a movement nobody has made yet - which is what
	 * libdraw's first readmouse expects.
	 */
	if((ulong)c->qid.path == Qmouse)
		c->aux = (void*)(uintptr)(mgen - 1);
	return c;
}

static void
inputclose(Chan*)
{
}

static long
inputread(Chan *c, void *a, long n, vlong)
{
	char buf[64];			/* room to spare: the fourth field outgrows 11 columns */
	ulong mark;
	Rune r;
	int m;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, inputdir, nelem(inputdir), devgen);
	switch((ulong)c->qid.path){
	case Qkbd:
		ksleep(&kr, haverune, nil);
		r = kq[kout++ % Nrune];
		buf[0] = 'c';
		m = 1 + runetochar(buf+1, &r);
		buf[m++] = 0;		/* rio overwrites the last byte with 0 */
		break;
	case Qcons:
		ksleep(&kr, haverune, nil);
		r = kq[kout++ % Nrune];
		m = runetochar(buf, &r);	/* the character itself, uncooked */
		break;
	case Qconsctl:
		error(Eperm);
		return 0;
	case Qmouse:
		mark = (ulong)(uintptr)c->aux;
		ksleep(&mr, moved, &mark);
		c->aux = (void*)(uintptr)mgen;
		/*
		 * The fourth field is milliseconds.  rio takes differences of
		 * it - the interval between two clicks - so what matters is
		 * that it runs forward at the right rate, and this is the
		 * kernel's wall clock in milliseconds rather than a count
		 * since boot: an offset, not a drift.
		 */
		m = snprint(buf, sizeof buf, "m%11d %11d %11d %11lud ",
			mx, my, mb, (ulong)(p9nsec()/1000000));
		break;
	default:
		error(Egreg);
		return 0;
	}
	if(n > m)
		n = m;
	memmove(a, buf, n);
	return n;
}

/*
 * A write to /dev/mouse moves the pointer, which is how a window system
 * warps it; anything else is refused.  /dev/kbd takes no writes: the
 * bytes come from the controller.
 */
static long
inputwrite(Chan *c, void *a, long n, vlong)
{
	char buf[64], *f[4];
	int nf;

	if((ulong)c->qid.path == Qconsctl)
		return n;		/* rawon, rawoff: nothing here is cooked */
	if((ulong)c->qid.path == Qcons){
		print("%.*s", (int)n, (char*)a);
		return n;
	}
	if((ulong)c->qid.path != Qmouse)
		error(Eperm);
	if(n <= 0 || n >= (long)sizeof buf)
		error(Ebadarg);
	memmove(buf, a, n);
	buf[n] = 0;
	if(buf[0] != 'm')
		error(Ebadarg);
	nf = tokenize(buf+1, f, nelem(f));
	if(nf < 2)
		error(Ebadarg);
	mx = atoi(f[0]);
	my = atoi(f[1]);
	if(mx < 0) mx = 0;
	if(mx >= Winw) mx = Winw-1;
	if(my < 0) my = 0;
	if(my >= Winh) my = Winh-1;
	mgen++;
	pointerpos();			/* a program moved the pointer: the arrow moves too */
	wakeup(&mr);
	return n;
}

Dev inputdevtab = {
	'm',
	"input",

	devreset,
	devinit,
	devshutdown,
	inputattach,
	inputwalk,
	inputstat,
	inputopen,
	devcreate,
	inputclose,
	inputread,
	devbread,
	inputwrite,
	devbwrite,
	devremove,
	devwstat,
};
