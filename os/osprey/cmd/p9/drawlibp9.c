/*
 * drawlibp9.c - a program that draws, its operating system a library in
 * its own address space.
 *
 * It speaks the draw protocol to /dev/draw: open /dev/draw/new for a
 * client of its own, read the twelve fields that say what the screen
 * is, open the client's data file, and write the messages - 'b' to
 * allocate an image, 'd' to draw one into another.  That is what
 * libdraw does under an ordinary Plan 9 graphics program, written out
 * here rather than linked, because what is being shown is the path and
 * not the library: the /dev/draw it writes into is the kernel's own
 * devdraw.c compiled into the personality that loaded this program
 * (devdrawp9.c), so the write is a call into code already in memory
 * beside it - no trap, no ring, no server in a container of its own -
 * and the pixels it lands on are the firmware frame buffer the
 * microkernel exposed as a segment.
 *
 * The one thing any of it asks a kernel for is address space.  That is
 * the exokernel claim of the paper, with a picture at the end of it.
 *
 * What it paints is stated here and in the check, both written before
 * the machine was ever booted: 0x112233 over the whole screen and
 * 0xCC7722 in the rectangle (200,150)-(600,450).
 */
#include <u.h>
#include <libc.h>
#include <draw.h>

/*
 * And then the same screen through the real library.  The second half
 * of this program is an ordinary Plan 9 graphics program: initdraw,
 * allocimage, draw, string - the libdraw built from source in
 * 9front/src, unmodified, linked against p9crt.c.  Everything libdraw
 * asks a kernel for it asks the personality instead, by call.  It does
 * not clear the screen: what the first half painted is still there
 * under it, and the check reads both.
 */

enum {
	Back	= 0x112233FF,		/* the whole screen */
	Fore	= 0xCC7722FF,		/* and the rectangle */
	Big	= 0x3FFFFFF,		/* a replicated image's clipping rectangle */

	Lib	= 0x33AA55FF,		/* and what the real libdraw paints */
	Libtext	= 0x000000FF,		/* the string it writes inside it */
	Libx0	= 700,			/* the rectangle it paints, stated here */
	Liby0	= 150,
	Libx1	= 1100,
	Liby1	= 450,
	Textdx	= 20,			/* and where in it the string starts */
	Textdy	= 140,
	Pausems	= 4000,			/* the pause between the two paints */

	Screenid = 0,			/* the draw device's image 0 is the screen */
	Backid	= 1,
	Maskid	= 2,
	Foreid	= 3,
};

static int datafd;
static char chanbuf[32];
static char Libstr[] = "the library is the operating system";

static void
plong(uchar *p, ulong v)
{
	p[0] = v;
	p[1] = v>>8;
	p[2] = v>>16;
	p[3] = v>>24;
}

static uchar*
prect(uchar *p, int x0, int y0, int x1, int y1)
{
	plong(p+0*4, x0);
	plong(p+1*4, y0);
	plong(p+2*4, x1);
	plong(p+3*4, y1);
	return p + 4*4;
}

/*
 * 'b' id[4] screenid[4] refresh[1] chan[4] repl[1] r[4*4] clipr[4*4]
 * value[4]: a one-pixel image replicated over everything, which is what
 * a solid colour is in this protocol.
 */
static int
allocimg(int id, ulong chan, ulong value)
{
	uchar m[64], *p;

	p = m;
	*p++ = 'b';
	plong(p, id); p += 4;
	plong(p, 0); p += 4;		/* not on a screen */
	*p++ = 0;			/* Refnone */
	plong(p, chan); p += 4;
	*p++ = 1;			/* replicated */
	p = prect(p, 0, 0, 1, 1);
	p = prect(p, -Big, -Big, Big, Big);
	plong(p, value); p += 4;
	if(write(datafd, m, p-m) != p-m){
		print("libdraw: allocating image %d: %r\n", id);
		return -1;
	}
	return 0;
}

/* 'd' dstid[4] srcid[4] maskid[4] r[4*4] sp[2*4] mp[2*4] */
static int
drawrect(int dst, int src, int mask, int x0, int y0, int x1, int y1)
{
	uchar m[64], *p;

	p = m;
	*p++ = 'd';
	plong(p, dst); p += 4;
	plong(p, src); p += 4;
	plong(p, mask); p += 4;
	p = prect(p, x0, y0, x1, y1);
	plong(p+0*4, 0); plong(p+1*4, 0); p += 2*4;	/* source point */
	plong(p+0*4, 0); plong(p+1*4, 0); p += 2*4;	/* mask point */
	if(write(datafd, m, p-m) != p-m){
		print("libdraw: drawing %d %d %d %d: %r\n", x0, y0, x1, y1);
		return -1;
	}
	return 0;
}


/*
 * The same screen, through the real library.  Nothing below this line
 * knows it is not on Plan 9: initdraw opens /dev/draw, reads the twelve
 * fields, opens the client's data and refresh files, builds the default
 * font out of libdraw's own compiled-in subfont, reads /dev/winname and
 * attaches to the image named there - and every one of those calls goes
 * to the personality in this program's address space.
 *
 * It paints (700,150)-(1100,450) and writes a string in it.  It does
 * not clear the screen first, which an ordinary libdraw program would:
 * the rectangle the first half painted is asserted by the same check
 * off the same screendump, and clearing would erase it.
 */
static void
libpaint(void)
{
	Image *col;
	Rectangle r;
	Point p, e;
	char wname[64];
	int wfd, wn;

	wname[0] = 0;
	if((wfd = open("/dev/winname", OREAD)) >= 0){
		if((wn = read(wfd, wname, sizeof wname - 1)) > 0)
			wname[wn] = 0;
		close(wfd);
	}
	if(initdraw(nil, nil, "libdraw") < 0){
		print("libdraw: initdraw: %r\n");
		return;
	}
	print("libdraw: initdraw: display image %d %d %d %d, screen \"%s\" %d %d %d %d, chan %s, font %s %d high\n",
		display->image->r.min.x, display->image->r.min.y,
		display->image->r.max.x, display->image->r.max.y,
		wname,
		screen->r.min.x, screen->r.min.y, screen->r.max.x, screen->r.max.y,
		chantostr(chanbuf, screen->chan), font->name, font->height);
	col = allocimage(display, Rect(0,0,1,1), screen->chan, 1, Lib);
	if(col == nil){
		print("libdraw: allocimage: %r\n");
		return;
	}
	r = Rect(Libx0, Liby0, Libx1, Liby1);
	draw(screen, r, col, nil, ZP);
	p = Pt(Libx0+Textdx, Liby0+Textdy);
	e = string(screen, p, display->black, ZP, font, Libstr);
	if(flushimage(display, 1) < 0){
		print("libdraw: flushimage: %r\n");
		return;
	}
	print("libdraw: real libdraw painted %d %d %d %d %06ux and wrote \"%s\" from %d %d to %d %d\n",
		r.min.x, r.min.y, r.max.x, r.max.y, (ulong)(Lib>>8), Libstr,
		p.x, p.y, e.x, e.y);
	freeimage(col);
}

void
startboot(char *argv0, char **argv)
{
	char info[12*12+1], buf[64];
	int ctlfd, n, id, x0, y0, x1, y1;
	vlong t0, t1;

	USED(argv0); USED(argv);
	ctlfd = open("/dev/draw/new", ORDWR);
	if(ctlfd < 0){
		print("libdraw: /dev/draw/new: %r\n");
		exits("draw");
	}
	n = read(ctlfd, info, sizeof info - 1);
	if(n < 12*12){
		print("libdraw: /dev/draw/new said %d bytes, not the twelve fields\n", n);
		exits("draw");
	}
	info[n] = 0;
	id = atoi(info + 0*12);
	x0 = atoi(info + 4*12);
	y0 = atoi(info + 5*12);
	x1 = atoi(info + 6*12);
	y1 = atoi(info + 7*12);
	print("libdraw: client %d, the screen is %d %d %d %d, %.12s, through /dev/draw of the personality that loaded me\n",
		id, x0, y0, x1, y1, info + 2*12);
	snprint(buf, sizeof buf, "/dev/draw/%d/data", id);
	datafd = open(buf, ORDWR);
	if(datafd < 0){
		print("libdraw: %s: %r\n", buf);
		exits("draw");
	}
	/*
	 * The mask is a replicated one-pixel GREY1 image of 1: every pixel
	 * of the destination is written.  Without one the draw would take
	 * the screen itself as its mask, which is not what image 0 is for.
	 */
	if(allocimg(Backid, XRGB32, Back) < 0
	|| allocimg(Maskid, GREY1, 0xFFFFFFFF) < 0
	|| allocimg(Foreid, XRGB32, Fore) < 0)
		exits("draw");
	if(drawrect(Screenid, Backid, Maskid, x0, y0, x1, y1) < 0)
		exits("draw");
	if(drawrect(Screenid, Foreid, Maskid, 200, 150, 600, 450) < 0)
		exits("draw");
	print("libdraw: painted the screen %06ux and 200 150 600 450 %06ux\n",
		(ulong)(Back>>8), (ulong)(Fore>>8));
	close(datafd);
	close(ctlfd);
	/*
	 * A pause between the two paints, and the reason is the picture.
	 * The second half of this program is an ordinary Plan 9 graphics
	 * program, and an ordinary Plan 9 graphics program takes the whole
	 * screen for a window of its own and clears it - libdraw's
	 * gengetwindow allocates the window DWhite - so what the first half
	 * painted is gone the moment initdraw returns.  Both are real and
	 * only one can be on the screen at a time, so the check photographs
	 * the screen twice and this is the gap it does it in.
	 *
	 * It is also the one place this program can say whether sleep works.
	 * nsec(2) is not a system call: libc reads /dev/bintime and preads
	 * it at offset 0, which is the personality's time device through the
	 * personality's own pread, so the number printed here is measured by
	 * the same library operating system that did the sleeping.
	 */
	t0 = nsec();
	sleep(Pausems);
	t1 = nsec();
	print("libdraw: asked to sleep %d ms and slept %ld, timed by nsec through /dev/bintime\n",
		Pausems, (long)((t1 - t0) / 1000000));
	libpaint();
	exits(nil);
}
