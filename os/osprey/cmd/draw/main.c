/*
 * main.c - the front end of the user-level /dev/draw server.
 *
 * The kernel's draw device, devdraw.c, is reused whole; this hands the
 * 9p requests a client makes - attach, walk, open, read, write - to that
 * device's own Chan-based entry points (drawdevtab), and turns its
 * kernel-style error() unwinding back into a 9p Rerror.  The device draws
 * onto the frame buffer the microkernel exposes (see attachscreen in
 * kshim.c).  Mounted at /dev, it makes /dev/draw, which rio opens.
 */
#include "kshim.h"
#include <auth.h>
#include <fcall.h>
#include <9p.h>

void
usage(void)
{
	fprint(2, "usage: draw [-c] [-m mtpt]\n");
	exits("usage");
}

extern Dev drawdevtab;
#define D (&drawdevtab)

/*
 * memdraw's shared images (memopaque/memwhite/memblack/memones).  In the
 * kernel these are set up by the port screen init; the device never does
 * it.  A user-space server must call this itself, or every mask defaults
 * to a nil memopaque and memdraw faults reading mask->layer.
 */
extern void memimageinit(void);

/*
 * The software cursor (cursor.c) draws onto the same frame buffer.  Its
 * lock is held around every draw batch so a draw and the cursor never
 * touch the frame buffer at once.
 */
extern Lock oscurlock;
extern void oscursoron(void);
extern void oscursoroff(void);
extern void oscursorstart(void);

/* the frame buffer the microkernel exposed, attached by kshim.c */
extern ulong *ospreyfb;
extern int ospreyfbwid;
extern void ospreyfbattach(void);

static void
fsattach(Req *r)
{
	Chan *c;

	if(waserror()){
		respond(r, up->errstr);
		return;
	}
	c = D->attach(r->ifcall.aname);
	poperror();
	r->fid->aux = c;
	r->fid->qid = c->qid;
	r->ofcall.qid = c->qid;
	respond(r, nil);
}

static char*
fsclone(Fid *old, Fid *new)
{
	Chan *oc, *nc;

	oc = old->aux;
	if(oc == nil)
		return nil;
	nc = mallocz(sizeof(Chan), 1);
	if(nc == nil)
		return "out of memory";
	*nc = *oc;
	new->aux = nc;
	return nil;
}

static char*
fswalk1(Fid *fid, char *name, Qid *qid)
{
	Chan *c;
	Walkqid *wq;
	char *e;

	c = fid->aux;
	e = nil;
	if(waserror()){
		e = up->errstr;
		return e;
	}
	wq = D->walk(c, c, &name, 1);
	poperror();
	if(wq == nil || wq->nqid < 1){
		free(wq);
		return "no such file";
	}
	free(wq);
	*qid = c->qid;
	fid->qid = c->qid;
	return nil;
}

static void
fsopen(Req *r)
{
	Chan *c;

	c = r->fid->aux;
	if(waserror()){
		respond(r, up->errstr);
		return;
	}
	D->open(c, r->ifcall.mode);
	poperror();
	r->fid->qid = c->qid;
	r->ofcall.qid = c->qid;
	respond(r, nil);
}

static void
fsread(Req *r)
{
	Chan *c;
	long n;

	c = r->fid->aux;
	if(waserror()){
		respond(r, up->errstr);
		return;
	}
	n = D->read(c, r->ofcall.data, r->ifcall.count, r->ifcall.offset);
	poperror();
	r->ofcall.count = n;
	respond(r, nil);
}

static void
fswrite(Req *r)
{
	Chan *c;
	long n;

	c = r->fid->aux;
	if(waserror()){
		respond(r, up->errstr);
		return;
	}
	lock(&oscurlock);		/* lift the cursor across the draw */
	oscursoroff();
	n = D->write(c, r->ifcall.data, r->ifcall.count, r->ifcall.offset);
	oscursoron();
	unlock(&oscurlock);
	poperror();
	r->ofcall.count = n;
	respond(r, nil);
}

static void
fsdestroyfid(Fid *fid)
{
	Chan *c;

	c = fid->aux;
	if(c == nil)
		return;
	fid->aux = nil;
	if(!waserror()){
		if(c->flag & COPEN)
			D->close(c);
		poperror();
	}
	free(c);
}

static Srv drawsrv = {
	.attach = fsattach,
	.clone = fsclone,
	.walk1 = fswalk1,
	.open = fsopen,
	.read = fsread,
	.write = fswrite,
	.destroyfid = fsdestroyfid,
};

/*
 * The first client of this server, run in the process that mounted it.
 * A draw client opens /dev/draw/new, reads from the ctl file it gets
 * back the client number and the shape of the screen, and writes draw
 * messages to the data file beside it.  That is all libdraw does, and
 * doing it by hand here keeps the demonstration to the protocol and off
 * a second library.
 *
 * The two halves are different containers: postmountsrv forked, the
 * child answers 9P on the pipe, and every open, read and write below
 * crosses it.  They share memory - the fork lib9p makes is RFMEM - so
 * the frame buffer the server drew on is the one read back here, and
 * the check sees pixels rather than a return code.
 *
 * The colours are written as their channel descriptors rather than
 * through draw.h, whose Image would collide with the device's own.
 * XRGB32 is CHAN4(CIgnore,8,CRed,8,CGreen,8,CBlue,8) and GREY1 is
 * CHAN1(CGrey,1), with CRed 0, CGreen 1, CBlue 2, CGrey 3, CIgnore 6
 * and CHAN1(a,b) = a<<4|b.
 */
enum {
	Xrgb32	= 0x68081828,
	Grey1	= 0x31,
	Blue	= 0x0000FFFF,		/* RGBA, as the draw protocol wants */
	Green	= 0x00FF00FF,
	Red	= 0xFF0000FF,
	Boxx	= 100,			/* the first client's box */
	Boxy	= 60,
	Boxw	= 300,
	Boxh	= 200,
	Box2x	= 200,			/* the second client's, inside it */
	Box2y	= 100,
	Box2w	= 100,
	Box2h	= 60,
};

static uchar*
putl(uchar *p, ulong v)
{
	p[0] = v; p[1] = v>>8; p[2] = v>>16; p[3] = v>>24;
	return p+4;
}

static uchar*
putr(uchar *p, int x0, int y0, int x1, int y1)
{
	p = putl(p, x0); p = putl(p, y0); p = putl(p, x1); return putl(p, y1);
}

/* b id[4] screenid[4] refresh[1] chan[4] repl[1] r[16] clipr[16] color[4] */
static uchar*
allocimage(uchar *p, int id, ulong chan, ulong color)
{
	*p++ = 'b';
	p = putl(p, id);
	p = putl(p, 0);			/* not on a screen: a plain image */
	*p++ = 0;			/* refresh, unused off a screen */
	p = putl(p, chan);
	*p++ = 1;			/* replicated: one pixel, everywhere */
	p = putr(p, 0, 0, 1, 1);
	p = putr(p, -0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF);
	return putl(p, color);
}

/* d dstid[4] srcid[4] maskid[4] r[16] srcp[8] maskp[8] */
static uchar*
drawmsg(uchar *p, int dst, int src, int mask, int x0, int y0, int x1, int y1)
{
	*p++ = 'd';
	p = putl(p, dst);
	p = putl(p, src);
	p = putl(p, mask);
	p = putr(p, x0, y0, x1, y1);
	p = putl(p, 0); p = putl(p, 0);	/* src point */
	p = putl(p, 0); return putl(p, 0);	/* mask point */
}

static int
field(char *info, int i)
{
	return atoi(info + i*12);
}

/*
 * Open the server's ctl file and say what it hands back: the client
 * number, and the shape and channel of the screen it is given.  The
 * data file beside it is where the draw messages go.
 */
static int
drawopen(char *mtpt, char *who, int *wid, int *hgt)
{
	char buf[64], info[12*12+1];
	int ctl, data, id;

	snprint(buf, sizeof buf, "%s/draw/new", mtpt);
	if((ctl = open(buf, ORDWR)) < 0)
		sysfatal("open %s: %r", buf);
	if(read(ctl, info, 12*12) != 12*12)
		sysfatal("read %s: %r", buf);
	info[12*12] = 0;
	id = atoi(info);
	*wid = atoi(info + 6*12) - atoi(info + 4*12);
	*hgt = atoi(info + 7*12) - atoi(info + 5*12);
	fprint(2, "draw: %s is client %d of the server, and the screen it is given is %dx%d, channel %.11s\n",
		who, id, *wid, *hgt, info + 2*12);
	snprint(buf, sizeof buf, "%s/draw/%d/data", mtpt, id);
	if((data = open(buf, ORDWR)) < 0)
		sysfatal("open %s: %r", buf);
	close(ctl);
	return data;
}

/*
 * Read the screen back.  A draw client has no business mapping the
 * frame buffer - that is the server's - and this does it anyway,
 * because the result of a draw is pixels and the only way to say so is
 * to look at them.  The kernel exposes the segment to any container
 * that asks for it, so the check can look from either end.
 */
static ulong
pixel(int x, int y)
{
	if(ospreyfb == nil)
		ospreyfbattach();
	if(ospreyfb == nil)
		sysfatal("the frame buffer could not be mapped: %r");
	return ospreyfb[y*ospreyfbwid + x] & 0xFFFFFF;
}

/*
 * The first client of this server, run in the process that mounted it.
 * A draw client opens /dev/draw/new, reads from the ctl file the client
 * number and the shape of the screen, and writes draw messages to the
 * data file beside it.  That is all libdraw does, and doing it by hand
 * here keeps the demonstration to the protocol and off a second
 * library.
 *
 * The two halves are different containers: postmountsrv forked, the
 * child answers 9P on the pipe, and every open, read and write below
 * crosses it.
 */
static void
firstclient(char *mtpt)
{
	uchar m[256], *p;
	int data, wid, hgt;

	fprint(2, "draw: the mount returned; the first client of the server starts\n");
	data = drawopen(mtpt, "the first client", &wid, &hgt);

	/*
	 * Three images and two draws: the whole screen blue, then a box
	 * of green in it.  The mask is a replicated one-bit image of all
	 * ones, which is what libdraw's display->opaque is and what a
	 * draw with no mask means.
	 */
	p = m;
	p = allocimage(p, 1, Xrgb32, Blue);
	p = allocimage(p, 2, Xrgb32, Green);
	p = allocimage(p, 3, Grey1, ~0);
	p = drawmsg(p, 0, 1, 3, 0, 0, wid, hgt);
	p = drawmsg(p, 0, 2, 3, Boxx, Boxy, Boxx+Boxw, Boxy+Boxh);
	if(write(data, m, p-m) != p-m)
		sysfatal("write draw messages: %r");
	fprint(2, "draw: two draws crossed the pipe and reached the screen: the frame buffer word inside the box is %#.8lux and outside it %#.8lux\n",
		pixel(Boxx+Boxw/2, Boxy+Boxh/2), pixel(Boxx+Boxw+40, Boxy+Boxh/2));
	close(data);
}

/*
 * The other end of the same server, in a container of its own: it never
 * had the mount the server's own process made, and finds the server the
 * way anything else on the machine would - by name in /srv, which is
 * where postmountsrv posted the pipe.  This is what rio will do.
 */
/*
 * Find a server by the name it posted in /srv and mount it, the way a
 * container that never had the mount must: the name is in the name
 * space every container shares, the descriptor behind it is the
 * server's pipe, and mounting it puts the server's tree under mtpt.
 */
static void
mountsrv(char *name, char *mtpt)
{
	char path[64];
	int fd;

	snprint(path, sizeof path, "/srv/%s", name);
	if((fd = open(path, ORDWR)) < 0)
		sysfatal("open %s: %r", path);
	if(mount(fd, -1, mtpt, MBEFORE, "") < 0)
		sysfatal("mount %s at %s: %r", path, mtpt);
	close(fd);
}

/*
 * The three files rio wants, in one name space.  /dev/draw is this
 * container's own mount of the draw server it found in /srv; /dev/kbd
 * and /dev/mouse are the personality's, served out of the i8042 driver
 * it runs in user space and reached the way every other file call from
 * a container is reached, through the buddy.  The mouse is read once -
 * the driver answers the first read with where the pointer is rather
 * than waiting for a movement nobody made - and the keyboard is opened
 * and not read, because a read of it waits for a key and nobody is at
 * this keyboard.
 */
static void
threedevices(char *mtpt)
{
	char buf[64], path[64];
	int fd, n;

	snprint(path, sizeof path, "%s/mouse", mtpt);
	if((fd = open(path, ORDWR)) < 0)
		sysfatal("open %s: %r", path);
	n = read(fd, buf, sizeof buf - 1);
	if(n <= 0)
		sysfatal("read %s: %r", path);
	buf[n] = 0;
	close(fd);
	fprint(2, "draw: and %s reads a record: %s\n", path, buf);

	snprint(path, sizeof path, "%s/kbd", mtpt);
	if((fd = open(path, OREAD)) < 0)
		sysfatal("open %s: %r", path);
	close(fd);
	fprint(2, "draw: and %s opens beside them; it is not read, because a read of it waits for a key\n", path);
	fprint(2, "draw: one container holds /dev/draw, /dev/mouse and /dev/kbd - the three rio wants\n");
}

static void
otherclient(char *mtpt)
{
	uchar m[256], *p;
	int data, wid, hgt;

	mountsrv("draw", mtpt);
	fprint(2, "draw: a second container found the server by name in /srv and mounted it at %s\n", mtpt);
	data = drawopen(mtpt, "the second container's client", &wid, &hgt);

	/* one box of red, inside the green one the first client drew */
	p = m;
	p = allocimage(p, 1, Xrgb32, Red);
	p = allocimage(p, 2, Grey1, ~0);
	p = drawmsg(p, 0, 1, 2, Box2x, Box2y, Box2x+Box2w, Box2y+Box2h);
	if(write(data, m, p-m) != p-m)
		sysfatal("write draw messages: %r");
	/*
	 * Inside the second box, and inside the first box but outside the
	 * second: the new colour where it was drawn and the old one where
	 * it was not, which is one screen written by two containers.
	 */
	fprint(2, "draw: and it drew on the same screen: inside its own box the frame buffer word is %#.8lux, and inside the first client's box but outside its own it is still %#.8lux\n",
		pixel(Box2x+Box2w/2, Box2y+Box2h/2), pixel(Boxx+20, Boxy+Boxh-20));
	close(data);
	threedevices(mtpt);
}

void
main(int argc, char **argv)
{
	char *mtpt;
	int client;

	mtpt = "/dev";
	client = 0;
	ARGBEGIN{
	case 'm':
		mtpt = EARGF(usage());
		break;
	case 'c':
		client = 1;
		break;
	}ARGEND;
	USED(argc, argv);

	/*
	 * -c is the same binary run as nothing but a draw client, in a
	 * container of its own, to show that the server is reachable
	 * from outside the process that started it.
	 */
	if(client){
		otherclient(mtpt);
		exits(nil);
	}
	memimageinit();
	D->reset();
	D->init();
	ospreyfbattach();		/* the screen, before there are two of us */
	oscursorstart();		/* the software mouse cursor */
	postmountsrv(&drawsrv, "draw", mtpt, MBEFORE);
	firstclient(mtpt);
	exits(nil);
}
