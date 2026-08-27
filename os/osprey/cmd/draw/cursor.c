/*
 * cursor.c - a software mouse cursor for the user-level draw server.
 *
 * The draw server owns the exposed frame buffer, so the cursor is drawn
 * here rather than in the mouse driver: a proc reads the same "mousering"
 * segment the kernel fills, tracks the pointer, and composites a small
 * arrow onto the frame buffer, saving the pixels underneath so it can be
 * lifted again.  A single lock, shared with the 9P write path (main.c),
 * hides the cursor around every draw batch so a draw and the cursor never
 * touch the frame buffer at once - the classic software-cursor dance,
 * between two procs of one program.
 */
#include <u.h>
#include <libc.h>

extern ulong	*ospreyfb;	/* the frame buffer (XRGB32), from kshim.c */
extern int	ospreyfbwid, ospreyfbhgt;

Lock	oscurlock;		/* shared with main.c's fswrite */

enum {
	Mousen	= 256,		/* mouse ring capacity, matches the kernel */
	Cw	= 16,		/* cursor sprite is 16x16 */
	Ch	= 16,
};

/* the arrow: 'X' outline (black), '.' body (white), ' ' transparent */
static char *arrow[Ch] = {
	"X               ",
	"XX              ",
	"X.X             ",
	"X..X            ",
	"X...X           ",
	"X....X          ",
	"X.....X         ",
	"X......X        ",
	"X.......X       ",
	"X........X      ",
	"X.....XXXX      ",
	"X..X..X         ",
	"X.X X..X        ",
	"XX   X..X       ",
	"X     X..X      ",
	"       XXX      ",
};

static uchar	*ring;		/* the mousering page */
static uvlong	rp;
static int	mx, my;		/* pointer position */
static int	cx, cy, shown;	/* where the sprite currently sits */
static ulong	save[Cw*Ch];	/* pixels lifted from under the sprite */

static int
nextbyte(void)
{
	uvlong count;

	count = *(uvlong*)ring;
	if(rp >= count)
		return -1;
	if(count - rp > Mousen)
		rp = count - Mousen;
	return ring[8 + (rp++ % Mousen)];
}

/* fold pending PS/2 packets into mx,my; return 1 if the pointer moved */
static int
track(void)
{
	static uchar pkt[3];
	static int pn;
	int b, dx, dy, moved;

	moved = 0;
	for(;;){
		b = nextbyte();
		if(b < 0)
			return moved;
		if(pn == 0 && !(b & 0x08))
			continue;
		pkt[pn++] = (uchar)b;
		if(pn < 3)
			continue;
		pn = 0;
		dx = pkt[1];
		if(pkt[0] & 0x10)
			dx -= 256;
		dy = pkt[2];
		if(pkt[0] & 0x20)
			dy -= 256;
		mx += dx;
		my -= dy;
		if(mx < 0) mx = 0; else if(mx >= ospreyfbwid) mx = ospreyfbwid-1;
		if(my < 0) my = 0; else if(my >= ospreyfbhgt) my = ospreyfbhgt-1;
		moved = 1;
	}
}

/* lift the sprite, restoring what was under it (call with oscurlock held) */
void
oscursoroff(void)
{
	int r, c, px, py;

	if(!shown)
		return;
	for(r = 0; r < Ch; r++)
		for(c = 0; c < Cw; c++){
			if(arrow[r][c] == ' ')
				continue;
			px = cx + c;
			py = cy + r;
			if(px < ospreyfbwid && py < ospreyfbhgt)
				ospreyfb[py*ospreyfbwid + px] = save[r*Cw + c];
		}
	shown = 0;
}

/* drop the sprite at cx,cy, saving what it covers (oscurlock held) */
void
oscursoron(void)
{
	int r, c, px, py;

	if(shown)
		return;
	for(r = 0; r < Ch; r++)
		for(c = 0; c < Cw; c++){
			if(arrow[r][c] == ' ')
				continue;
			px = cx + c;
			py = cy + r;
			if(px >= ospreyfbwid || py >= ospreyfbhgt)
				continue;
			save[r*Cw + c] = ospreyfb[py*ospreyfbwid + px];
			ospreyfb[py*ospreyfbwid + px] =
				arrow[r][c] == 'X' ? 0x000000 : 0xFFFFFF;
		}
	shown = 1;
}

static void
cursorproc(void)
{
	for(;;){
		if(track()){
			lock(&oscurlock);
			oscursoroff();
			cx = mx;
			cy = my;
			oscursoron();
			unlock(&oscurlock);
		}
		sleep(15);
	}
}

/*
 * Start the cursor: map the mouse ring and fork a proc to run it.  The
 * proc shares memory with the server (RFMEM) so oscurlock and the sprite
 * state are the same objects the 9P write path locks.
 */
void
oscursorstart(void)
{
	void *v;

	v = segattach(0, "mousering", 0, Mousen+16);
	if(v == (void*)-1)
		return;			/* no mouse exposed: just no cursor */
	ring = v;
	rp = *(uvlong*)ring;

	/*
	 * Attach the frame buffer now, before the fork, so both this and
	 * the server's own draw path share one mapping (attachscreen reuses
	 * ospreyfb when it is already set).
	 */
	if(ospreyfb == nil){
		v = segattach(0, "framebuffer", 0,
			(ulong)ospreyfbwid*ospreyfbhgt*4);
		if(v == (void*)-1)
			return;
		ospreyfb = v;
	}
	mx = ospreyfbwid/2;
	my = ospreyfbhgt/2;
	cx = mx;
	cy = my;
	switch(rfork(RFPROC|RFMEM|RFNOWAIT)){
	case -1:
		return;
	case 0:
		cursorproc();
		_exits(nil);
	default:
		break;
	}
}
