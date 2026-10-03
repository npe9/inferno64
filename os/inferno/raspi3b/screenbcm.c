/*
 * Framebuffer for Inferno/arm64 raspi3b via the BCM2835 VideoCore
 * fw_cfg @ 0x9020000 - the arm64 virt machine's fw_cfg, where riscv's
 * is at 0x10100000).  ramfb-only: the arm64 board reaches its devices
 * over PCI, not the virtio-mmio slots the riscv screen also probes, so
 * there is no virtio-gpu fallback here.
 *
 * gscreen draws directly into the ramfb buffer (no soft→fb memcpy).
 * Soft cursor is an overlay: save/restore under the 16×16 footprint
 * so Bounce holding drawlock cannot permanently hide the pointer.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "screen.h"

enum {
	ScrX	= 640,
	ScrY	= 480,
	ScrDepth= 32,
	ScrChan	= XRGB32,
	ScrPix	= ScrDepth/8,
};

extern int mboxfballoc(int, int, uintptr*, u32*, u32*);

static Memdata	scrdata;
Memimage	*gscreen;
static uchar	*fb;		/* software gscreen buffer memdraw draws into */
static uchar	*vfb;		/* visible mailbox framebuffer in VC RAM */

/*
 * Draw straight into the scanout buffer instead of into a shadow and
 * copying.  0 restores the shadow buffer and the per-frame copy; see
 * screeninit() for what that costs and for the tearing this trades it
 * against.
 */
enum { Directfb = 1 };
static int	fbok;

static int	cursenable;
static int	cursprocok;
static Rendez	cursrendez;
static Rectangle curslast;	/* last painted cursor footprint on fb */
static Point	curshot;	/* last painted hotpoint */
static uchar	under[CURSWID*CURSHGT*ScrPix];
static int	underok;

/* cheap screen path counters (printed from #K dump) */
static uvlong	nflush, nflushbyte, ncompose, ncomposeskip;
static uvlong	tcycles_flush, tcycles_compose;

/* Standard Inferno arrow (same bits as os/pc/screen.c). */
static Cursor arrow = {
	{ -1, -1 },
	{ 0xFF, 0xFF, 0x80, 0x01, 0x80, 0x02, 0x80, 0x0C,
	  0x80, 0x10, 0x80, 0x10, 0x80, 0x08, 0x80, 0x04,
	  0x80, 0x02, 0x80, 0x01, 0x80, 0x02, 0x8C, 0x04,
	  0x92, 0x08, 0x91, 0x10, 0xA0, 0xA0, 0xC0, 0x40,
	},
	{ 0x00, 0x00, 0x7F, 0xFE, 0x7F, 0xFC, 0x7F, 0xF0,
	  0x7F, 0xE0, 0x7F, 0xE0, 0x7F, 0xF0, 0x7F, 0xF8,
	  0x7F, 0xFC, 0x7F, 0xFE, 0x7F, 0xFC, 0x73, 0xF8,
	  0x61, 0xF0, 0x60, 0xE0, 0x40, 0x40, 0x00, 0x00,
	},
};
static Cursor	curcursor;

static Rectangle
cursrect(Point p)
{
	Rectangle r;
	Cursor *c;

	c = &curcursor;
	r.min.x = p.x + c->offset.x;
	r.min.y = p.y + c->offset.y;
	r.max.x = r.min.x + CURSWID;
	r.max.y = r.min.y + CURSHGT;
	return r;
}

/* Save fb pixels under r into under[] (r is CURSWID×CURSHGT, may be clipped). */
static void
fbsaveunder(Rectangle r)
{
	int y, stride, n;
	uchar *src, *dst;

	if(fb == nil || gscreen == nil)
		return;
	if(!rectclip(&r, gscreen->r)){
		underok = 0;
		return;
	}
	stride = ScrX * ScrPix;
	n = Dx(r) * ScrPix;
	src = fb + r.min.y*stride + r.min.x*ScrPix;
	dst = under;
	for(y = r.min.y; y < r.max.y; y++){
		memmove(dst, src, n);
		src += stride;
		dst += n;
	}
	underok = 1;
	curslast = r;
}

/* Restore previously saved under[] onto fb at curslast. */
static void
fbrestoreunder(void)
{
	int y, stride, n;
	uchar *src, *dst;
	Rectangle r;

	if(!underok || fb == nil)
		return;
	r = curslast;
	stride = ScrX * ScrPix;
	n = Dx(r) * ScrPix;
	src = under;
	dst = fb + r.min.y*stride + r.min.x*ScrPix;
	for(y = r.min.y; y < r.max.y; y++){
		memmove(dst, src, n);
		src += n;
		dst += stride;
	}
	underok = 0;
	curslast = ZR;
}

/* Paint cursor glyph onto ramfb (XRGB32). */
static void
fbpaintcursor(Point p)
{
	Cursor *c;
	int y, b, j, sx, sy;
	uchar set, clr, bit;
	u32int *pix;

	if(fb == nil)
		return;
	c = &curcursor;
	for(y = 0; y < CURSHGT; y++){
		sy = p.y + c->offset.y + y;
		if(sy < 0 || sy >= ScrY)
			continue;
		for(b = 0; b < 2; b++){
			set = c->set[y*2 + b];
			clr = c->clr[y*2 + b];
			for(j = 0; j < 8; j++){
				bit = 0x80 >> j;
				if(((set|clr) & bit) == 0)
					continue;
				sx = p.x + c->offset.x + b*8 + j;
				if(sx < 0 || sx >= ScrX)
					continue;
				pix = (u32int*)(fb + (sy*ScrX + sx)*ScrPix);
				if(set & bit)
					*pix = 0x00000000;
				else
					*pix = 0x00FFFFFF;
			}
		}
	}
}

/*
 * Restore old footprint, save under new hotpoint, paint glyph.
 * Safe without drawlock; never blocks on Bounce holding drawlock.
 */
void
cursorcompose(void)
{
	Point p;
	Rectangle n;
	uvlong t0, t1;

	if(!cursenable || fb == nil)
		return;
	cycles(&t0);
	p = mousexy();
	if(underok)
		fbrestoreunder();
	n = cursrect(p);
	fbsaveunder(n);
	fbpaintcursor(p);
	curshot = p;
	swcursormarked(p);
	cycles(&t1);
	ncompose++;
	tcycles_compose += t1 - t0;
}

void
screenstats(void)
{
	print("SCREEN flush ");
	print("%llud ", nflush);
	print("bytes ");
	print("%llud ", nflushbyte);
	print("cyc ");
	print("%llud\n", tcycles_flush);
	print("SCREEN compose ");
	print("%llud ", ncompose);
	print("skip ");
	print("%llud ", ncomposeskip);
	print("cyc ");
	print("%llud\n", tcycles_compose);
}

void
screeninit(void)
{
	Rectangle r;
	Memimage *i;
	int nbytes;

	uintptr fbpa;
	u32 pitch, fbsize;

	memimageinit();
	nbytes = ScrX * ScrY * ScrPix;
	/*
	 * One buffer: the firmware allocates the framebuffer in VC RAM and
	 * gscreen draws straight into it (no soft->fb copy).  The returned
	 * pitch must equal ScrX*ScrPix so gscreen->width (in words) is ScrX.
	 */
	if(mboxfballoc(ScrX, ScrY, &fbpa, &pitch, &fbsize) < 0){
		print("screen: mailbox framebuffer alloc failed\n");
		return;
	}
	if(pitch != ScrX * ScrPix){
		print("screen: unexpected pitch %ud (want %d)\n", pitch, ScrX*ScrPix);
		return;
	}
	/*
	 * memdraw draws into fb; flushmemscreen() delivers it to vfb, the
	 * buffer the GPU scans out.
	 *
	 * With Directfb, fb IS vfb: memdraw draws straight into the scanout
	 * buffer and the flush only has to clean the dirty rectangle out of
	 * the cache.  THE SOFT-TO-FB COPY IS THE PI'S BIGGEST DRAW COST --
	 * measured on silicon at 91% of the screen path and about ten times
	 * the drawing it delivers (memdraw 2090us a fill, screen+flush
	 * 23333-24444us at 640x480, three boots) -- so not making it is
	 * worth more than anything else in this file.
	 *
	 * This used to say that drawing straight into the VC-RAM buffer
	 * "faults deep in memdraw".  That was true when written and is not
	 * now: it predates mmuinit().  With the MMU off all of RAM is
	 * Device-nGnRnE, where unaligned accesses fault architecturally and
	 * memdraw makes them constantly.  mmuenable() in l.s now sets
	 * $0x1005 (M|C|I) from mmuinit() at main.c:249, and mmu.c maps every
	 * 2MB block below BCMPERIPH as Pnormal, so the mailbox buffer
	 * (fbpa 0x3c100000) is ordinary cacheable memory.  Probed rather
	 * than argued: pointing fb at fbpa boots to DRAW-OK, TK-OK and the
	 * same 564 bytes of glyph ink, with no fault.
	 *
	 * IT TEARS, AND THAT IS NOT FIXED HERE.  Nothing now separates
	 * drawing from scanout, so a frame can be displayed half-drawn.
	 * The cure is double buffering: the mailbox already pins virtual
	 * height to physical with tag 0x00048004 and already sends tag
	 * 0x00048009 (virtual offset) as 0,0, and asking for 2*h returns
	 * exactly twice the allocation while y=h moves the scanout -- both
	 * verified under QEMU.  What is NOT verified is landing the flip in
	 * vertical blank, and without that the tear moves rather than
	 * vanishing.  Until that is done this trades a tear for the copy.
	 * Set Directfb to 0 to get the copy, and the old behaviour, back.
	 *
	 * See doc/raspi3b-draw-plan.ms for the measurements and the gates.
	 */
	vfb = (uchar*)fbpa;
	if(Directfb)
		fb = vfb;
	else
		fb = xalloc(nbytes);
	if(fb == nil){
		print("screen: no memory for %d byte soft fb\n", nbytes);
		return;
	}
	memset(fb, 0x40, nbytes);
	if(fb != vfb)
		memmove(vfb, fb, nbytes);
	/*
	 * Clean the initial fill out to the point of coherency, which the
	 * copy above never did: the GPU scans vfb out uncached, so without
	 * this the first frame can show whatever was in that memory.
	 */
	cacheflush(vfb, nbytes);
	scrdata.base = nil;
	scrdata.bdata = fb;
	scrdata.ref = 1;
	scrdata.imref = nil;
	scrdata.allocd = 0;

	r = Rect(0, 0, ScrX, ScrY);
	i = allocmemimaged(r, ScrChan, &scrdata);
	if(i == nil){
		print("screen: allocmemimaged failed\n");
		return;
	}
	/* width is scanline length in 32-bit words */
	i->width = ScrX;
	gscreen = i;

	fbok = 1;
	USED(fbok);

	curcursor = arrow;
	swcursorinit();
	swcursorload(&curcursor);
	cursenable = 0;
	curslast = ZR;
	curshot = Pt(-10000, -10000);
	underok = 0;

	/* Seed coords only (cursenable off → no cursor paint yet). */
	mousetrack(0, ScrX/2, ScrY/2, 0);
}

void
screenrotate(int)
{
}

Memdata*
attachscreen(Rectangle *r, ulong *chan, int *d, int *width, int *softscreen)
{
	if(gscreen == nil)
		return nil;
	*r = gscreen->r;
	*chan = gscreen->chan;
	*d = gscreen->depth;
	*width = gscreen->width;
	*softscreen = 1;
	scrdata.ref++;
	return &scrdata;
}

void
flushmemscreen(Rectangle r)
{
	Point p;
	Rectangle cr;
	uvlong t0, t1;
	int moved, hit;

	/*
	 * gscreen == ramfb: drawing already landed in the visible buffer.
	 * flush only repairs the soft-cursor overlay where the dirty rect
	 * (or a move) disturbed it.  No soft→fb memcpy.
	 */
	if(fb == nil || gscreen == nil)
		return;
	if(!rectclip(&r, gscreen->r))
		return;
	cycles(&t0);
	nflush++;
	nflushbyte += (uvlong)Dx(r) * Dy(r) * ScrPix;
	if(cursenable){
		p = mousexy();
		cr = cursrect(p);
		moved = p.x != curshot.x || p.y != curshot.y;
		hit = (underok && rectXrect(r, curslast)) || rectXrect(r, cr);
		if(moved || hit){
			/*
			 * Memdraw already wrote r into the visible fb.  Saved
			 * under[] overlapping r is stale — drop it.  If the
			 * old footprint sits entirely outside r, restore it.
			 */
			if(underok && rectXrect(r, curslast))
				underok = 0;
			cursorcompose();
		}else
			ncomposeskip++;
	}
	cycles(&t1);
	tcycles_flush += t1 - t0;

	/*
	 * Push the dirty rectangle to the visible framebuffer the GPU scans
	 * out.  (Cursor overlay, when enabled, is composited into fb above,
	 * so it rides along in this copy.)
	 */
	if(vfb != nil){
		int y, stride, nb;
		uchar *sp, *dp;
		stride = ScrX * ScrPix;
		nb = Dx(r) * ScrPix;
		sp = fb + r.min.y*stride + r.min.x*ScrPix;
		dp = vfb + r.min.y*stride + r.min.x*ScrPix;
		for(y = r.min.y; y < r.max.y; y++){
			if(dp != sp)		/* Directfb: nothing to copy */
				memmove(dp, sp, nb);
			/*
			 * Clean this scanline to the point of coherency: the
			 * GPU scans vfb out uncached, so without the clean it
			 * would show stale pixels on real hardware.  Only the
			 * dirty span (nb bytes at dp), not the whole line, and
			 * a no-op under QEMU which models no data cache.
			 */
			cacheflush(dp, nb);
			sp += stride;
			dp += stride;
		}
		nflushbyte += (uvlong)Dy(r) * nb;
	}

	/* Long Tk update holds the Dis VM; keep soft timers alive. */
	clockcheck();
}

void
getcolor(u32 p, u32 *pr, u32 *pg, u32 *pb)
{
	USED(p);
	*pr = *pg = *pb = 0;
}

int
setcolor(u32 p, u32 r, u32 g, u32 b)
{
	USED(p, r, g, b);
	return 0;
}

void
blankscreen(int blank)
{
	USED(blank);
}

static int
cursready(void*)
{
	return cursenable && swcursorneeded();
}

/*
 * Lock-free overlay updates.  Input kproc only want+wakeup (no paint).
 * Never wait on drawlock — that was how Bounce made the pointer vanish.
 * One compose per wakeup (not a busy while): tablet floods used to
 * peg the CPU here and starve Bounce's monitor.
 */
static void
cursorproc(void*)
{
	for(;;){
		sleep(&cursrendez, cursready, 0);
		if(cursenable && fb != nil && swcursorneeded())
			cursorcompose();
	}
}

void
cursoron(void)
{
	if(!cursenable || fb == nil)
		return;
	swcursorwant();
	wakeup(&cursrendez);
}

void
cursoroff(void)
{
	if(underok)
		fbrestoreunder();
}

void
setcursor(Cursor *c)
{
	if(c == nil)
		c = &arrow;
	curcursor = *c;
	swcursorload(&curcursor);
	if(cursenable)
		cursorcompose();
}

void
cursorenable(void)
{
	cursenable = 1;
	if(fb == nil)
		return;
	if(!cursprocok){
		cursprocok = 1;
		kproc("swcursor", cursorproc, 0, 0);
	}
	swcursorload(&curcursor);
	cursorcompose();
}

void
cursordisable(void)
{
	cursenable = 0;
	cursoroff();
}

void
drawcursor(Drawcursor *c)
{
	Cursor curs;
	int j, i, h, bpl;
	uchar *bc, *bs, *cclr, *cset;

	if(c == nil || c->data == nil){
		setcursor(&arrow);
		return;
	}
	memset(&curs, 0, sizeof curs);
	curs.offset = Pt(c->hotx, c->hoty);
	bpl = bytesperline(Rect(c->minx, c->miny, c->maxx, c->maxy), 1);
	h = (c->maxy - c->miny) / 2;
	if(h > CURSHGT)
		h = CURSHGT;
	bc = c->data;
	bs = c->data + h * bpl;
	cclr = curs.clr;
	cset = curs.set;
	for(i = 0; i < h; i++){
		for(j = 0; j < 2 && j < bpl; j++){
			cclr[j] = bc[j];
			cset[j] = bs[j];
		}
		bc += bpl;
		bs += bpl;
		cclr += 2;
		cset += 2;
	}
	setcursor(&curs);
}

int
hwdraw(Memdrawparam *par)
{
	/*
	 * Overlay cursor: softscreen never contains the glyph, so there
	 * is nothing to avoid/hide when apps draw (including Bounce).
	 */
	USED(par);
	return 0;
}

int
ishwimage(Memimage *i)
{
	USED(i);
	return 0;
}
