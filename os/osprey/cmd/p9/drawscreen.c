/*
 * drawscreen.c - the screen the personality's draw device draws onto.
 *
 * devdraw wants a Memdata whose pixels are the display's, and the
 * microkernel exposes the firmware frame buffer as the physical segment
 * "framebuffer".  So the screen is that segment: the draw device's
 * screen image points straight at it and a draw lands on the display
 * with nothing to flush afterwards.
 *
 * Compiled against the user headers rather than the name space's,
 * because segattach here is libc's - the microkernel call - and not the
 * name space's own.  That is the same split ring9p.c and blkvirtio.c
 * are on, and the reason a library operating system can have a screen
 * at all: the one thing it asks a kernel for is address space.
 */
#include <u.h>
#include <libc.h>
#include <draw.h>
#include <memdraw.h>

enum {
	Wid	= 1280,		/* the exposed frame buffer, as devinput.c has it */
	Hgt	= 800,
};

ulong	*p9fb;			/* the frame buffer, once attached */
int	p9fbwid = Wid;
int	p9fbhgt = Hgt;

int
ishwimage(Memimage *i)
{
	USED(i);
	return 0;
}

void
getcolor(ulong p, ulong *pr, ulong *pg, ulong *pb)
{
	ulong v;

	v = (p & 0xff) * 0x01010101;	/* a grey ramp: this screen is true colour */
	*pr = *pg = *pb = v;
}

int	setcolor(ulong, ulong, ulong, ulong){ return 0; }
void	mouseresize(void){}
void	blankscreen(int){}
/*
 * The screen data IS the frame buffer, so there is nothing to copy - but
 * this is still where devdraw says what it drew, and the cursor needs to
 * be told: the pixels it saved from under the arrow are stale the moment
 * something is drawn there.
 */
extern void p9cursorflush(int, int, int, int);
void	flushmemscreen(Rectangle r){ p9cursorflush(r.min.x, r.min.y, r.max.x, r.max.y); }

Memdata*
attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen)
{
	static Memdata md;
	static int done;
	ulong *fb;

	if(!done){
		fb = (ulong*)segattach(0, "framebuffer", 0, (ulong)Wid*Hgt*4);
		if(fb == (ulong*)-1)
			return nil;
		p9fb = fb;
		print("p9 draw: the frame buffer is mapped at %#p, %lud bytes\n",
			fb, (ulong)Wid*Hgt*4);
		md.base = fb;
		md.bdata = (uchar*)fb;
		md.ref = 1;
		md.imref = nil;
		md.allocd = 0;		/* never freed: it is the hardware */
		done = 1;
	}
	if(p9fb == nil)
		return nil;
	*r = Rect(0, 0, Wid, Hgt);
	*chan = XRGB32;
	*depth = 32;
	*width = Wid;			/* words per scan line, one word a pixel */
	*softscreen = 0;		/* draws land straight on the frame buffer */
	md.ref++;
	return &md;
}
