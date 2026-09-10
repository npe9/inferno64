/*
 * p9cursor.c - a mouse cursor for the library-OS personality.
 *
 * There was none, and what that cost was the whole of using the machine:
 * the pointer this personality's i8042 driver decodes is dead reckoned
 * from relative PS/2 packets, so it is wherever the packets have taken
 * it and not wherever the host's cursor happens to be drawn.  With no
 * arrow on the screen a person cannot tell where the guest thinks the
 * pointer is, and a window sweeps somewhere other than where it looked
 * like it would.
 *
 * The draw server has one of these (os/osprey/cmd/draw/cursor.c) and it
 * cannot be used here: it is a program with rfork, sleep and a lock
 * against its own 9P write path.  This personality is one address space
 * with cooperative kprocs, which makes the same job simpler rather than
 * harder - a kproc and the draw device never interleave in the middle of
 * anything, so the classic lock is not needed at all.
 *
 * What is needed is the other half of the dance.  The screen data IS the
 * frame buffer here, so devdraw draws straight onto it and the pixels
 * saved from under the arrow go stale the moment anything is drawn
 * there.  devdraw calls flushmemscreen with the rectangle it drew, which
 * on this personality did nothing; it says so now, and a rectangle that
 * touches the arrow throws the saved pixels away rather than putting
 * them back over what was just drawn.
 *
 * The arrow itself is the kernel's, out of devmouse.c, the same two
 * masks the draw server's cursor.c carries.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

extern ulong	*p9fb;			/* drawscreen.c: the frame buffer */
extern int	p9fbwid, p9fbhgt;

enum {
	Cw	= 16,		/* the sprite is 16x16 */
	Ch	= 16,
	Hotx	= -1,		/* the arrow's hotspot offset */
	Hoty	= -1,
	Valid	= 2,		/* the third int in the page: a position has been reported */
};

/* the Plan 9 arrow: set is the black, clr the white outline around it */
static uchar curclr[32] = {
	0xFF, 0xFF, 0x80, 0x01, 0x80, 0x02, 0x80, 0x0C,
	0x80, 0x10, 0x80, 0x10, 0x80, 0x08, 0x80, 0x04,
	0x80, 0x02, 0x80, 0x01, 0x80, 0x02, 0x8C, 0x04,
	0x92, 0x08, 0x91, 0x10, 0xA0, 0xA0, 0xC0, 0x40,
};
static uchar curset[32] = {
	0x00, 0x00, 0x7F, 0xFE, 0x7F, 0xFC, 0x7F, 0xF0,
	0x7F, 0xE0, 0x7F, 0xE0, 0x7F, 0xF0, 0x7F, 0xF8,
	0x7F, 0xFC, 0x7F, 0xFE, 0x7F, 0xFC, 0x73, 0xF8,
	0x61, 0xF0, 0x60, 0xE0, 0x40, 0x40, 0x00, 0x00,
};

static int	*pos;		/* the pointerpos page: x, y, valid */
static int	cx, cy;		/* where the sprite sits */
static int	shown;		/* it is on the screen */
static int	haveback;	/* and the pixels under it are the ones saved */
static ulong	back[Cw*Ch];

/* is sprite pixel (r,c) black, white, or transparent? */
static int
curpix(int r, int c)
{
	int byte, bit;

	byte = r*2 + c/8;
	bit = 7 - (c%8);
	if((curset[byte] >> bit) & 1)
		return 1;
	if((curclr[byte] >> bit) & 1)
		return 0;
	return -1;
}

static void
cursoroff(void)
{
	int r, c, px, py;

	if(!shown)
		return;
	shown = 0;
	if(!haveback)
		return;		/* something drew there: what is there now is right */
	for(r = 0; r < Ch; r++)
		for(c = 0; c < Cw; c++){
			if(curpix(r, c) < 0)
				continue;
			px = cx + Hotx + c;
			py = cy + Hoty + r;
			if(px < 0 || px >= p9fbwid || py < 0 || py >= p9fbhgt)
				continue;
			p9fb[py*p9fbwid + px] = back[r*Cw + c];
		}
}

static void
cursoron(void)
{
	int r, c, px, py, p;

	if(shown || p9fb == nil)
		return;
	for(r = 0; r < Ch; r++)
		for(c = 0; c < Cw; c++){
			if((p = curpix(r, c)) < 0)
				continue;
			px = cx + Hotx + c;
			py = cy + Hoty + r;
			if(px < 0 || px >= p9fbwid || py < 0 || py >= p9fbhgt)
				continue;
			back[r*Cw + c] = p9fb[py*p9fbwid + px];
			p9fb[py*p9fbwid + px] = p ? 0x000000 : 0xFFFFFF;
		}
	haveback = 1;
	shown = 1;
}

/*
 * devdraw drew on the screen.  If it touched the arrow, the pixels saved
 * from under it are no longer what belongs there, so they are thrown
 * away and the arrow is put back on top of what was drawn.  Called from
 * drawscreen.c's flushmemscreen, which is where devdraw says what it
 * drew and which did nothing at all before.  It takes four ints rather
 * than the Rectangle it is given: this file is compiled with the name
 * space's headers, which have no draw.h in them, and drawscreen.c - the
 * one with the frame buffer - is on the other side of that split and
 * unpacks it.
 */
void
p9cursorflush(int rx0, int ry0, int rx1, int ry1)
{
	int x0, y0, x1, y1;

	if(!shown)
		return;
	x0 = cx + Hotx;
	y0 = cy + Hoty;
	x1 = x0 + Cw;
	y1 = y0 + Ch;
	if(rx1 <= x0 || rx0 >= x1 || ry1 <= y0 || ry0 >= y1)
		return;			/* nowhere near the arrow */
	haveback = 0;			/* what was under it is gone */
	shown = 0;
	cursoron();			/* over what was just drawn */
}

/*
 * Follow the pointer.  The position is the two ints the personality's
 * own input device publishes for exactly this (devinput.c writes them
 * whenever a packet moves the pointer), and the third says whether a
 * packet has arrived at all: an arrow drawn before one has is a mark on
 * the screen nobody put there.
 */
void
p9cursortick(void)
{
	int px, py;

	if(pos == nil){
		pos = (int*)segattach(0, "pointerpos", 0, 4096);
		if(pos == (int*)-1){
			pos = nil;
			return;
		}
	}
	if(p9fb == nil)
		return;
	if(pos[Valid] == 0)
		return;
	px = pos[0];
	py = pos[1];
	if(shown && px == cx && py == cy)
		return;
	cursoroff();
	cx = px;
	cy = py;
	cursoron();
}
