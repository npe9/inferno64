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
	fprint(2, "usage: draw [-m mtpt]\n");
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
	Boxx	= 100,			/* where the box goes, and how big */
	Boxy	= 60,
	Boxw	= 300,
	Boxh	= 200,
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

static void
firstclient(char *mtpt)
{
	char buf[64], info[12*12+1];
	uchar m[256], *p;
	int ctl, data, id, wid, hgt;
	ulong in, out;

	fprint(2, "draw: the mount returned; the first client of the server starts\n");
	snprint(buf, sizeof buf, "%s/draw/new", mtpt);
	if((ctl = open(buf, ORDWR)) < 0)
		sysfatal("open %s: %r", buf);
	if(read(ctl, info, 12*12) != 12*12)
		sysfatal("read %s: %r", buf);
	info[12*12] = 0;
	id = field(info, 0);
	wid = field(info, 6) - field(info, 4);
	hgt = field(info, 7) - field(info, 5);
	fprint(2, "draw: the first client is client %d of the server, and the screen it is given is %dx%d, channel %.11s\n",
		id, wid, hgt, info + 2*12);
	snprint(buf, sizeof buf, "%s/draw/%d/data", mtpt, id);
	if((data = open(buf, ORDWR)) < 0)
		sysfatal("open %s: %r", buf);

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
		sysfatal("write %s: %r", buf);

	/*
	 * And read the frame buffer back, one pixel inside the box and
	 * one outside it.  Reading it here rather than trusting the
	 * write's return is the point: the pixels are the result.
	 */
	if(ospreyfb == nil)
		sysfatal("the frame buffer was never attached");
	in = ospreyfb[(Boxy+Boxh/2)*ospreyfbwid + Boxx+Boxw/2];
	out = ospreyfb[(Boxy+Boxh/2)*ospreyfbwid + Boxx+Boxw+40];
	fprint(2, "draw: two draws crossed the pipe and reached the screen: the frame buffer word inside the box is %#.8lux and outside it %#.8lux\n",
		in & 0xFFFFFF, out & 0xFFFFFF);
	close(data);
	close(ctl);
}

void
main(int argc, char **argv)
{
	char *mtpt;

	mtpt = "/dev";
	ARGBEGIN{
	case 'm':
		mtpt = EARGF(usage());
	}ARGEND;
	USED(argc, argv);

	memimageinit();
	D->reset();
	D->init();
	ospreyfbattach();		/* the screen, before there are two of us */
	oscursorstart();		/* the software mouse cursor */
	postmountsrv(&drawsrv, nil, mtpt, MBEFORE);
	firstclient(mtpt);
	exits(nil);
}
