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

extern int mboxfballoc(int, int, int, uintptr*, u32*, u32*);
extern int mboxvirtoffset(int, int);
extern void (*screenpresent)(void);
extern void (*screenpartial)(Rectangle);
extern int mboxvsync(void);
extern void drawpresentstats(void);
static void vsyncprobe(void);
static void bcmpresent(void);
static void bcmpartial(Rectangle);
static uchar *backaddr(void);

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

/*
 * Double buffering with a page flip.  PROVEN AND OFF.
 *
 * It works on silicon -- 15 flips, 0 failures, drawink 6 of 6 with glyph
 * figures identical to the single-buffered path -- and it is 0 because working
 * is not the same as being an improvement:
 *
 *	THE TEAR IS NOT FIXED.  bcmpresent() does not wait for vertical
 *	blank, so the flip itself becomes the tear line: the tear MOVES
 *	rather than vanishing.  The wait cannot simply be added -- see
 *	bcmpresent() for why it would hold mboxlock for a whole frame under
 *	drawlock -- so tear-freedom is a design question still open.
 *
 *	THE COST IS NOT ESTABLISHED on a real workload.  On drawink the
 *	repair is 608k a frame against eager's 677k, about 90 per cent of
 *	eager, because drawink reads back after every draw AND draws glyphs
 *	straight at the screen.  The 84.9 per cent saving a peer measured
 *	needs a client that does neither, which is Tk, and that has not been
 *	measured here.
 *
 * So turning it on today would trade a known tear for a moved tear plus a
 * cost.  The code is proven rather than hoped, and still off.
 *
 * The audit it was once waiting on is DONE and came out much shorter than
 * feared.
 *
 * The flip is three lines:
 *
 *	scrdata.bdata = base + (front? ScrY*stride: 0);
 *	fb = vfb = scrdata.bdata;
 *	mboxvirtoffset(0, front? 0: ScrY);
 *
 * and the reason it is that cheap is that attachscreen() hands devdraw the
 * Memdata ITSELF, which allocmemimaged() then shares into the screen Memimage.
 * Memimage.data is a Memdata*, and the byte pointer is Memdata.bdata inside
 * it.  So reassigning bdata propagates to every Memimage sharing it at once,
 * and every identity test in the system keeps working, because all of them
 * compare the Memdata POINTER and not the bytes:
 *
 *	devdraw.c:639   l->screen->image->data != screenimage->data
 *	devdraw.c:901   l->data == screenimage->data
 *	devdraw.c:2097  dst->layer->screen->image->data == screenimage->data
 *	devdraw.c:2286  lp[0]->layer->screen->image->data == screenimage->data
 *	screenbcm.c     par->dst->data == gscreen->data   (the tear probe)
 *
 * I listed the tear probe and dstflush() as hazards in an earlier version of
 * this comment.  They are not.  Nor is memlayer, whose per-layer save[] are
 * their own allocations.
 *
 * WHAT IS LEFT IS ONE REAL HAZARD, and it is the cursor.  fbsaveunder() copies
 * the pixels under the cursor out of fb and fbrestoreunder() puts them back,
 * with underok and curslast persisting BETWEEN frames.  A save in frame N
 * restored after a flip writes frame N's pixels into the buffer that is now
 * visible, at a moment when it holds frame N-1.  The fix is one line at the
 * flip -- underok = 0 -- because the cursor is recomposed on the next flush
 * anyway, and invalidating is cheaper than remembering which buffer a save
 * came from.
 *
 * memdraw computes byte addresses per call and the flip happens at 'v' with
 * drawlock held, so nothing holds a byte address across it.
 *
 * Still 0 because none of this has been run on the board, and the batch
 * scoring the I-cache fix owns the board.  What is written is the mailbox half
 * (mboxfballoc's virtual height, mboxvirtoffset) and the measurement
 * (devdraw's per-present accounting); what is not is these three lines, the
 * underok invalidation, and the deferred repair at 'v'.
 */
enum { Dbuf = 0 };

/*
 * SKIP THE FORWARD COPY, so the acceptance test can be shown able to fail.
 *
 * drawink(1)'s "undrawn region" check asserts that what a frame did not redraw
 * still holds the previous frame.  With a single buffer it passes trivially,
 * and with a correct flip it passes for the right reason -- which means a PASS
 * proves nothing on its own.  Setting this to 1 makes the repair a no-op,
 * reproducing exactly the bug the first version of bcmpresent() had (an
 * inverted ternary that copied the back buffer onto itself), and the check must
 * then FAIL with "TWO FRAMES STALE".  If it does not, the check is watching the
 * wrong region.
 *
 * IT MUST DISABLE BOTH REPAIRS, and the first version did not.  Gating only
 * the deferred repair in bcmpresent() left bcmpartial() running, and drawink is
 * readback-heavy: every readback takes the pre-draw hook, eagerly repairs the
 * whole stale region, and keeps the picture correct.  Measured -- the control
 * run reported "eager-repairs 9 REPAIR DISABLED" and drawink passed all six
 * checks, so the control proved nothing.
 *
 * The lesson is not that the check is blind.  Reading the counters instead of
 * the verdict showed the control had disabled the wrong mechanism, and had I
 * trusted the PASS I would have drawn a wrong conclusion (the check is
 * watching the wrong region) from a correct observation (the control did not
 * fire).
 *
 * Data, not a conditional compile, and the same discipline as Tearprobe above
 * and as drawink's own -k flag, which leaves the cursor in place to prove its
 * other checks can fail.  Until this has been run both ways on hardware the
 * undrawn check is written rather than verified.
 */
enum { Dbufnorepair = 0 };

static uchar	*fbbase;	/* base of the whole (2*ScrY tall) allocation */
static int	fbfront;	/* which half the GPU is scanning out */
static Rectangle dmg;		/* damage(N), accumulating */
static Rectangle dmgprev;	/* damage(N-1): where BACK is stale */
static int	havedmgprev;
static uvlong	nflip, nflipfail, nrepairbyte, nrepairrect, neagerrepair;
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

/*
 * How big is a damage rectangle, by distribution and not by mean?
 *
 * doc/open-issues-plan.ms H1a turns on this.  Tear-freedom needs page
 * flipping, flipping with incremental drawing needs a damage-sized copy
 * per frame, and that copy is what Directfb removed -- 20452us of a
 * 23900us screen path for a FULL-SCREEN fill, against 818us for a
 * 128x96 widget.  So whether the copy is affordable is entirely a
 * question of how big the damage usually is, and the mean cannot say:
 * one full-screen flush among a thousand widget flushes moves the mean
 * and decides nothing.
 *
 * Five buckets, by bytes.  The top one is >1MB, which on this 1228800-byte
 * screen is 85 per cent of it and NOT the quarter an earlier version of this
 * comment claimed; a quarter is 307200 bytes and falls in the 256KB bucket.
 *
 * These buckets were cut for the rule "flip when the damage covers the
 * screen, copy when it does not", and that rule has since been WITHDRAWN --
 * see chargeoverlap() below and the H1a correction in the plan.  The saving
 * is the overlap between consecutive frames, which this histogram cannot
 * see at all, because it throws the order away.  The buckets are kept
 * because the COST question they answer is still live and the numbers taken
 * with them are still good; they just do not decide the rule.
 */
enum {
	Tearprobe	= 1,	/* data, not a conditional compile */
	Driftframes	= 240,	/* 4 seconds: long enough for a slope to show */
	Tearframes	= 120,	/* close the window after this many frames */
};

static uvlong	vsbase;		/* cycles at a known vertical blank */
static uvlong	vsperiod;	/* cycles per frame while ACCOUNTING, else 0 */
static uvlong	vsmeasured;	/* the same period, in 19.2MHz TICKS */
static uvlong	vsmeasuredus;	/* and in microseconds, for comparing against costs */
static uvlong	vsend;		/* cycles at which the window closes */
static uvlong	ntearop, ntearrow, nopchecked;
static int	vsclosed;	/* the window filled up before it was read */

static void teararm(void);
static void vsdrift(void);

static uvlong	ndamage[5];
static char	*damagename[5] = {
	"<=4KB", "<=64KB", "<=256KB", "<=1MB", ">1MB",
};

static void
chargedamage(uvlong nb)
{
	int i;

	if(nb <= 4*1024)
		i = 0;
	else if(nb <= 64*1024)
		i = 1;
	else if(nb <= 256*1024)
		i = 2;
	else if(nb <= 1024*1024)
		i = 3;
	else
		i = 4;
	ndamage[i]++;
}

/*
 * What the flip/copy rule actually turns on, which the histogram above
 * CANNOT answer.  doc/open-issues-plan.ms, H1a correction: with two
 * buffers the back buffer holds frame N-2 at the start of frame N, so
 * bringing it up to date before drawing costs
 *
 *	deferred cost(N) = |damage(N-1) \ damage(N)|
 *	eager    cost(N) = |damage(N)|
 *
 * and the difference between the two schemes is exactly the OVERLAP of
 * consecutive frames' damage, summed.  Coverage of the screen does not
 * enter it; a widget redrawing in place overlaps itself completely and
 * costs the deferred scheme nothing at all.
 *
 * Every damage number taken so far -- here and in a peer's session -- is a
 * distribution over flushes with the ORDER THROWN AWAY, and the question is
 * about order.  That is why this exists: one remembered rectangle, one
 * rectclip and an add.
 *
 * Both areas below are EXACT even though prev\r is not a rectangle: devdraw
 * hands flushmemscreen a bounding box, so prev and r are rectangles, and the
 * AREA of the difference is |prev| - |prev AND r| whatever shape it is.
 *
 * nfulladj is the cheapest possible answer to the sequence question: how
 * often is a near-full-screen flush PRECEDED by another one.  Deferred beats
 * eager on dropped frames only for consecutive full frames; for an isolated
 * one the big copy merely moves a frame later.  If this stays near zero on a
 * real session the rule saves no drops at all on it.
 *
 * WHAT THIS MEASURES IS FLUSH-TO-FLUSH, NOT FRAME-TO-FRAME, and the scheme's
 * arithmetic is about frames.  A flip is once per frame, so the deferred copy
 * is against the UNION of the previous frame's flushes; this charges it
 * against the previous flush alone.  The two agree exactly when a frame is
 * one flush and not otherwise.
 *
 * It is not fixable here, and that is the item itself: flushmemscreen is
 * given a rectangle and no indication of where one frame's drawing began --
 * devdraw's addflush() emits mid-batch whenever the bounding box wastes too
 * much area, so one frame can arrive as several flushes, and nothing in the
 * interface says which.  That is the same missing frame boundary the pre-draw
 * hint exists to supply, so this instrument is approximate for precisely the
 * reason the thing it measures is worth building.
 *
 * The error runs in BOTH directions, which I first wrote down as a one-sided
 * bound and then found a counter-example to, so both are recorded:
 *
 *	UNDER-states.  Frame A arrives as two disjoint flushes a1,a2 and
 *	frame B repaints both as b1,b2.  Every adjacent pair is disjoint, so
 *	this reports 0, where the frame-level union reports all of A.
 *
 *	OVER-states.  One frame flushes the same rectangle w twice and the
 *	next frame repaints elsewhere.  This reports |w| from the w,w pair,
 *	where frame-level accounting reports 0 -- a frame does not overlap
 *	itself.
 *
 * I ARGUED THE OVER-STATING CASE AWAY AND THE ARGUMENT WAS WRONG; it is kept
 * here because the mistake is instructive.  addflush() emits the accumulated
 * box only when
 *
 *	anbb > 1024 && waste*2 >= anbb && !rectXrect(flushrect, r)
 *
 * so a MID-BATCH emission happens precisely when the new rectangle does not
 * intersect the box being emitted, and I concluded that consecutive flushes
 * within one frame begin disjoint, hence that overlapping adjacent flushes
 * indicate a frame boundary.  That covers only mid-batch emissions.
 * dunlock() calls drawflush() on EVERY /dev/draw write that took the drawlock,
 * so the ordinary flush is one per write batch and carries no disjointness
 * guarantee against the next batch at all.  The bound does not follow.
 *
 * A peer's per-transition data says the unit is probably not a frame:
 * damage(N-1) lies entirely INSIDE damage(N) in 132 of 196 transitions on one
 * workload and 120 of 121 on another, and NO transition anywhere has zero
 * overlap.  Nested growing rectangles are what several write batches refining
 * one logical update look like, not what independent frames repainting the
 * same widget look like -- those would repeat a rectangle, not grow through
 * it.
 *
 * So the overlap below is an UPPER bound on the deferred saving, not a lower
 * one: a real present coalesces those nested flushes into one damage region,
 * and the overlap between coalesced regions is the quantity the scheme is
 * about.  nsamerect is the discriminator that matters after all, for the
 * reason it was nearly dropped: repeated IDENTICAL rectangles are genuine
 * frame-to-frame repaint, while strict growth is refinement within one update.
 *
 * THE FRAME BOUNDARY DOES EXIST, which this comment used to deny.  'v' in
 * devdraw is the client's present -- libdraw's flushimage(d, 1) emits it,
 * flushimage(d, 0) does not -- and drawflush() runs on it.  What makes the
 * stream ambiguous is only that dunlock() flushes unconditionally as well, so
 * real presents and incidental per-write flushes are mixed.  Accumulating
 * damage between 'v' commands is therefore measurable without any new
 * interface, and it belongs in devdraw where 'v' is visible, not here.  'v' is
 * still a POST-draw signal, so it gives the boundary for MEASUREMENT and not
 * the pre-draw damage the decision needs.
 */
enum {
	Fullish	= (uvlong)ScrX*ScrY*ScrPix*85/100,	/* the >85% bucket */
};
static uvlong	neagerbyte, ndeferbyte, noverlapbyte;
static uvlong	ndeferzero, ndeferover, nfulladj, nfullish, nsamerect;
static Rectangle prevdamage;
static int	haveprev;

static void
chargeoverlap(Rectangle r)
{
	Rectangle in;
	uvlong ar, aprev, aov;

	ar = (uvlong)Dx(r) * Dy(r) * ScrPix;
	neagerbyte += ar;
	if(haveprev){
		if(eqrect(prevdamage, r))
			nsamerect++;
		aprev = (uvlong)Dx(prevdamage) * Dy(prevdamage) * ScrPix;
		in = prevdamage;
		aov = rectclip(&in, r)?
			(uvlong)Dx(in) * Dy(in) * ScrPix : 0;
		noverlapbyte += aov;
		ndeferbyte += aprev - aov;
		if(aprev == aov)
			ndeferzero++;
		/*
		 * Did this frame's own deferred copy blow a frame?  Charged
		 * against the MEASURED vsync period when there is one, and
		 * against 16665us otherwise, because a claim about dropped
		 * frames needs the real frame clock and not a nominal 60Hz.
		 */
		if((aprev - aov) * 166 / 10000 > (vsmeasuredus? vsmeasuredus: 16665))
			ndeferover++;
		if(ar >= Fullish && aprev >= Fullish)
			nfulladj++;
	}
	if(ar >= Fullish)
		nfullish++;
	prevdamage = r;
	haveprev = 1;
}
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
	int i;

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
	print("SCREEN damage");
	for(i = 0; i < nelem(ndamage); i++)
		print(" %s %llud", damagename[i], ndamage[i]);
	print("\n");
	/*
	 * The two double-buffering schemes, costed over this session's actual
	 * SEQUENCE of damage rectangles rather than its distribution.  eager
	 * is the scheme that needs no pre-draw hint; defer is the one the
	 * flip/copy rule proposes; overlap is exactly the difference, and
	 * "skipped" counts frames the deferred scheme copies NOTHING for.
	 * "over" counts frames whose deferred copy alone exceeds a frame.
	 * fullish/adj is the sequence question: how many near-full flushes,
	 * and how many of those followed another one.
	 */
	/*
	 * devdraw's per-PRESENT accounting, reported from here rather than
	 * from devkprof.c beside screenstats(): shakti and sifiveu configure
	 * kprof WITHOUT draw, so a hook there is an undefined symbol on those
	 * boards and would need a stub in each, which is why screenstats()
	 * itself needs screennone.c.  Calling it from a board that has a
	 * screen needs no stub anywhere.
	 */
	drawpresentstats();
	if(Dbuf)
		print("SCREEN flip %llud failed %llud repair %llud bytes in %llud rects"
			" eager-repairs %llud%s\n",
			nflip, nflipfail, nrepairbyte, nrepairrect, neagerrepair,
			Dbufnorepair? " REPAIR DISABLED (control run)": "");
	print("SCREEN dbuf eager %llud defer %llud overlap %llud"
		" skipped %llud over %llud fullish %llud adj %llud samerect %llud\n",
		neagerbyte, ndeferbyte, noverlapbyte,
		ndeferzero, ndeferover, nfullish, nfulladj, nsamerect);
	print("SCREEN tear ops %llud of %llud rows %llud period %llud ticks (%llud us) %s\n",
		ntearop, nopchecked, ntearrow, vsmeasured, vsmeasuredus,
		vsmeasured == 0? "NOT CALIBRATED":
		(vsclosed? "window full": "window open"));
	vsyncprobe();
	vsdrift();
	teararm();
}

/*
 * Does this firmware answer SET_VSYNC, and with what period?
 *
 * doc/open-issues-plan.ms H1a: double buffering cures the tear only if
 * the flip lands in vertical blank, and nothing here has ever been shown
 * to know where vertical blank is.  The tag is documented and Linux uses
 * it; a Pi 3B's blob may answer it, may return at once, or may not know
 * it, and the three are told apart by TIMING rather than by a return
 * code.
 *
 * So: eight waits, the gap between each printed in microseconds.  A real
 * vsync is a stable period near a frame -- 16667us at 60Hz; an
 * unimplemented tag returns immediately and the gaps are a handful of
 * microseconds, which is the mailbox round trip and nothing else.  Eight
 * and not one, because a single gap cannot tell a period from a
 * coincidence, and the SPREAD is the evidence: a frame clock is regular
 * and a mailbox round trip is not.
 *
 * Printed from screenstats() -- the board's existing screen measurement
 * hook, reached from userland through devkprof -- rather than wired into
 * the flush, because this call BLOCKS THE CALLING CORE for up to a frame
 * and nothing in a draw path may use it until the numbers are in.
 *
 * CHECKED BEFORE TRUSTING THE RESULT: mboxread() bounds its wait with a
 * SPIN COUNT, not a timeout, and a spin count that expires inside a
 * legitimately slow reply is how this tree once read a working SD card
 * as a stalled one.  Spins is 10 million, about a second of uncached
 * reads by mailbox.c's own comment, against a frame of 16.7ms -- sixty
 * frames of headroom, so it cannot expire inside a real vsync wait.
 *
 * Which also means the three outcomes stay separable, and both numbers
 * below are needed to separate them:
 *
 *	errors 0, gaps near 16667us	it works
 *	errors 0, gaps of a few us	the firmware ignores the tag
 *	errors 8, gaps of a few us	the firmware refuses it
 *	errors 8, gaps near a second	the spin expired after all, and
 *					the reasoning above is wrong
 */
static void
vsyncprobe(void)
{
	uvlong t[9];
	int i, err;
	ulong hz;

	/*
	 * m->cpuhz is NOT the CPU clock on this board: clockinit() sets it
	 * from cntfrq(), which is the 19.2MHz counter cycles() reads, so
	 * this division is the right one.  Said here because the name
	 * invites the opposite assumption and a 62-fold error in a frame
	 * period would still look like a plausible number.
	 */
	hz = m->cpuhz;
	if(hz == 0){
		print("SCREEN vsync no cpuhz\n");
		return;
	}
	err = 0;
	cycles(&t[0]);
	for(i = 1; i <= 8; i++){
		if(mboxvsync() < 0)
			err++;
		cycles(&t[i]);
	}
	print("SCREEN vsync errors %d gaps(us)", err);
	for(i = 1; i <= 8; i++)
		print(" %llud", (t[i] - t[i-1]) * 1000000 / (uvlong)hz);
	print("\n");
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
	 *
	 * Dbuf asks for a virtual height of 2*ScrY instead, two stacked buffers
	 * in one allocation, so a page flip is mboxvirtoffset(0, 0 or ScrY)
	 * and copies nothing.  The flip, the deferred repair and the cursor
	 * invalidation are all written below; Dbuf is 0 because none of it has
	 * run on the board.  doc/open-issues-plan.ms H1a.
	 */
	if(mboxfballoc(ScrX, ScrY, Dbuf? 2*ScrY: ScrY, &fbpa, &pitch, &fbsize) < 0){
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
	 * IT TEARS WHILE Dbuf IS 0.  Nothing then separates drawing from
	 * scanout, so a frame can be displayed half-drawn.  The cure is the
	 * double buffering below: mboxfballoc() now takes a virtual height, so
	 * 2*ScrY gives two stacked buffers, and mboxvirtoffset() moves the
	 * scanout between them.
	 *
	 * WHAT IS STILL NOT VERIFIED is landing the flip in vertical blank, and
	 * without that the tear MOVES rather than vanishing -- the flip itself
	 * becomes the tear line.  mboxvsync() exists and vsyncprobe() measures
	 * the period, but bcmpresent() does not wait, because a vsync wait holds
	 * the mailbox lock for a whole frame and whether that is affordable is
	 * its own measurement.  So double buffering as written removes the
	 * half-drawn frame and does not yet promise a tear-free one.
	 * Set Directfb to 0 to get the shadow buffer and the per-frame copy back.
	 *
	 * See doc/raspi3b-draw-plan.ms for the measurements and the gates.
	 */
	vfb = (uchar*)fbpa;
	if(Directfb)
		fb = vfb;
	else
		fb = xalloc(nbytes);
	if(Dbuf && Directfb){
		/*
		 * Two stacked buffers in one allocation.  The GPU starts at
		 * offset 0, so draw into the SECOND half and the first flip
		 * shows it.  scrdata.bdata is set below from fb, and devdraw
		 * shares that same Memdata, so reassigning it at each flip
		 * moves every Memimage at once.
		 */
		if(fbsize < (u32)(2 * nbytes)){
			print("screen: fb %ud too small for 2x%d\n", fbsize, nbytes);
			return;
		}
		fbbase = vfb;
		fbfront = 0;			/* the GPU starts at offset 0 */
		fb = vfb = backaddr();		/* so draw into the second half */
		screenpresent = bcmpresent;
		screenpartial = bcmpartial;
	}
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

/*
 * THE PAGE FLIP, and the deferred repair that makes incremental drawing
 * correct across it.  doc/open-issues-plan.ms H1a.
 *
 * Invariant at the start of a frame: FRONT is being scanned out and holds the
 * last presented frame; BACK is what memdraw draws into and holds the frame
 * before that, so BACK is stale exactly in dmgprev, the last present's damage.
 *
 * At the present:
 *	1. copy dmgprev \ dmg from FRONT to BACK.  BACK is now this frame
 *	   everywhere -- inside dmg it was drawn, inside dmgprev\dmg it is
 *	   copied, and outside both it already agreed.
 *	2. flip, so BACK becomes FRONT.
 *	3. the new BACK (the old FRONT) holds the previous frame and is stale
 *	   exactly in this frame's damage, which becomes the next dmgprev.
 *
 * The copy costs |dmgprev \ dmg|, which is measured at 84.9 per cent less than
 * copying the damage every frame: 261us against 1770us on a Tk workload at this
 * geometry.  The saving is the OVERLAP of consecutive frames' damage and has
 * nothing to do with how much of the screen is covered.
 *
 * It is correct only because every operation Tk sends to a window fully
 * overwrites its damage rectangle -- otherwise pixels inside dmg that the
 * frame did not actually write would keep BACK's stale content and be shown.
 * Measured on a Tk workload: zero of 8628 draws was anything but SoverD with
 * an opaque mask and source, and no string, line, polygon or ellipse reached
 * the screen path at all, because Tk renders into per-widget images and blits
 * them opaquely.  devdraw's npartialhit counts violations if that ever stops
 * being true.  The mask-alpha and source-alpha cases are UNTESTED rather than
 * confirmed: that workload never exercised them.
 */
/*
 * s minus c, as up to four rectangles.  Returns how many were written.
 */
/*
 * Which half is which.  Named rather than written inline as a ternary at each
 * use, because the first version of the repair below had the ternary inverted
 * and copied the back buffer onto itself -- a no-op whose only symptom would
 * have been subtly stale pixels in whatever a frame did not redraw, which is
 * the hardest kind of wrong picture to notice.
 *
 * fbfront is the half the GPU is scanning out: 0 means offset 0.
 */
static uchar*
frontaddr(void)
{
	return fbbase + (fbfront? ScrY*ScrX*ScrPix: 0);
}

static uchar*
backaddr(void)
{
	return fbbase + (fbfront? 0: ScrY*ScrX*ScrPix);
}

static int
rectsub(Rectangle s, Rectangle c, Rectangle *out)
{
	int n;

	if(!rectclip(&c, s)){		/* disjoint: all of s survives */
		out[0] = s;
		return 1;
	}
	n = 0;
	if(c.min.y > s.min.y)
		out[n++] = Rect(s.min.x, s.min.y, s.max.x, c.min.y);
	if(c.max.y < s.max.y)
		out[n++] = Rect(s.min.x, c.max.y, s.max.x, s.max.y);
	if(c.min.x > s.min.x)
		out[n++] = Rect(s.min.x, c.min.y, c.min.x, c.max.y);
	if(c.max.x < s.max.x)
		out[n++] = Rect(c.max.x, c.min.y, s.max.x, c.max.y);
	return n;
}

static void
fbcopy(uchar *from, uchar *to, Rectangle r)
{
	int y, stride, nb;
	uchar *sp, *dp;

	stride = ScrX * ScrPix;
	nb = Dx(r) * ScrPix;
	if(nb <= 0)
		return;
	sp = from + r.min.y*stride + r.min.x*ScrPix;
	dp = to + r.min.y*stride + r.min.x*ScrPix;
	for(y = r.min.y; y < r.max.y; y++){
		memmove(dp, sp, nb);
		cacheflush(dp, nb);	/* the GPU will scan this out uncached */
		sp += stride;
		dp += stride;
	}
	nrepairbyte += (uvlong)nb * Dy(r);
	nrepairrect++;
}

/*
 * Called from devdraw's drawpre() BEFORE an operation that does not fully
 * overwrite its damage rectangle draws into the stale region.
 *
 * Such an operation composes against whatever the back buffer holds, and the
 * back buffer is a frame behind in dmgprev.  So bring ALL of dmgprev up to
 * date now, while the frame can still be drawn over it, and record that
 * nothing is stale any more -- which also means bcmpresent() has no repair
 * left to do for this frame.  The frame then costs what the eager scheme would
 * have cost, which is the documented worst case and is never a wrong picture.
 *
 * Repairing all of dmgprev rather than just the operation's rectangle is
 * deliberate: the rectangle devdraw passes is the DESTINATION's, a superset of
 * the operation's own, and a partial repair would leave the rest of dmgprev
 * stale for the deferred copy that now will not happen.
 */
static void
bcmpartial(Rectangle r)
{
	USED(r);
	if(fbbase == nil || !havedmgprev || Dbufnorepair)
		return;
	fbcopy(frontaddr(), backaddr(), dmgprev);
	havedmgprev = 0;
	neagerrepair++;
}

/*
 * Called from devdraw's drawpresent() at every 'v', with drawlock held.
 */
static void
bcmpresent(void)
{
	Rectangle sub[4];
	int i, n;

	if(fbbase == nil || dmg.min.x >= dmg.max.x)
		return;
	/* 1. repair the part of BACK that this frame did not redraw */
	if(havedmgprev && !Dbufnorepair){
		n = rectsub(dmgprev, dmg, sub);
		for(i = 0; i < n; i++)
			fbcopy(frontaddr(), backaddr(), sub[i]);
	}
	/* 2. show the buffer just completed */
	if(mboxvirtoffset(0, fbfront? 0: ScrY) < 0){
		nflipfail++;
		/*
		 * The firmware clamped or the exchange failed, so the buffer
		 * being scanned out is NOT the one just drawn.  Leave
		 * everything alone: the frame is stale rather than torn, and
		 * swapping fb now would draw the next frame into the visible
		 * buffer with no repair behind it.
		 */
		return;
	}
	fbfront = !fbfront;
	nflip++;
	/* 3. draw into what used to be shown */
	fb = vfb = scrdata.bdata = backaddr();
	/*
	 * NO VERTICAL-BLANK WAIT HERE, and it cannot simply be added.
	 * bcmpresent() runs with drawlock held, and mboxvirtoffset() takes
	 * mboxlock.  That is safe as it stands, because a property exchange is
	 * short and nothing holding mboxlock wants drawlock, so there is no
	 * deadlock -- only a brief coupling.  A vsync wait is different: it
	 * holds mboxlock for a WHOLE FRAME, and doing that under drawlock
	 * would stop every Dis draw operation in the system for up to 16.7ms
	 * while also starving sdhostbcm, sdhcibcm, btbcm and pwmbcm, which all
	 * come back to the mailbox at runtime.  mboxprop()'s own comment
	 * already rules out a periodic vsync kproc for the same reason.  So
	 * landing the flip in vertical blank needs the wait OUTSIDE both
	 * locks, which is a design question and not a line of code.
	 *
	 * The region this frame drew was already cleaned to the point of
	 * coherency by flushmemscreen(), per flush, so only the repair above
	 * has to clean anything here.
	 *
	 * The cursor's saved pixels came out of the OTHER buffer.  Restoring
	 * them now would write this frame's pixels into the visible buffer
	 * while it holds the previous frame.  Invalidate: the cursor is
	 * recomposed on the next flush anyway, and that is cheaper than
	 * remembering which buffer a save came from.
	 */
	underok = 0;
	dmgprev = dmg;
	havedmgprev = 1;
	dmg = Rect(10000, 10000, -10000, -10000);
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
	chargedamage((uvlong)Dx(r) * Dy(r) * ScrPix);
	chargeoverlap(r);
	if(Dbuf)
		combinerect(&dmg, r);	/* damage(N), closed at the present */
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
		/*
		 * NOT counted again here.  nb is Dx(r)*ScrPix, so Dy(r)*nb is
		 * the same quantity the counter already took at the top of
		 * this function, and every "bytes" figure this driver has ever
		 * printed was exactly DOUBLE the damage.  Found by the damage
		 * histogram disagreeing with it: three flushes totalling
		 * 2457600 bytes, every one of them in the 256KB-1MB bucket,
		 * which cannot both be true.  doc/open-issues-plan.ms H1a
		 * proposes reading the damage distribution off this counter,
		 * so a factor of two in it is not cosmetic.
		 */
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

/*
 * TEAR ACCOUNTING, and why it is arithmetic rather than a picture.
 *
 * With Directfb memdraw writes the scanout buffer, so a row written
 * after the beam has already passed it shows the OLD pixels for the rest
 * of that frame: the displayed frame is new below the beam and old
 * above, which is the tear.  Nothing in software can SEE that -- the
 * framebuffer is never torn, so a readback (drawink(1) included) would
 * report success on a wildly tearing display, which is what
 * doc/open-issues-plan.ms H1a originally prescribed.
 *
 * What can be computed is the condition itself.  The beam's position is
 * known once the frame clock is: the vsync tag gives 16.665ms stable to
 * 2us, so 480 rows at 34.72us each, and the beam row at any instant is
 * the phase since a known vertical blank scaled into rows.  For a draw
 * covering rows [min,max), every row BELOW min and above the beam was
 * written late.
 *
 * MEASURED AT hwdraw, which is called from memimagedraw BEFORE any pixel
 * is written, so the timestamp is the write's own and not the flush's.
 * The flush would be later and would overstate the beam; this understates
 * it, because a long draw's lower rows are written after its start while
 * the beam also advances -- but a full-screen fill runs eight times
 * faster than the beam, so the gap is small and the number is a LOWER
 * BOUND on rows torn.
 *
 * A BOUNDED WINDOW, not a running monitor.  Keeping a live vsync
 * timestamp would need a kproc waiting on the mailbox sixty times a
 * second, and a vsync wait holds the mailbox lock for a whole frame, so
 * that would starve every other user of it (see mailbox.c).  Instead the
 * window is armed from screenstats(), which measures the period over
 * eight frames and then accounts for a bounded run.  Within two seconds
 * the extrapolation error is about one row; over a minute it would be
 * half a frame and worthless, which is why the window closes itself.
 *
 * Arm and read with two writes of "dump" to /dev/kpctl: the first arms,
 * the workload runs, the second reports and re-arms.
 */
/*
 * CAN THE VERTICAL BLANK BE PREDICTED, instead of waited for?
 *
 * This is the gating question for the one thing still between the page flip and
 * turning it on.  bcmpresent() cannot wait for vblank: it runs with drawlock
 * held, and mboxvsync() holds mboxlock for a whole frame, so waiting there
 * stalls every Dis draw for up to 16.7ms while starving sdhostbcm, sdhcibcm,
 * btbcm and pwmbcm.  mboxprop()'s own comment already rules out a periodic
 * vsync kproc for the same reason: at 60 waits a second it holds the mailbox
 * essentially always.
 *
 * But a wait is only one way to know where vblank is.  If the period is stable,
 * the phase can be COMPUTED from cycles() against a known base -- no mailbox
 * call per frame at all, which removes the lock problem rather than scheduling
 * around it.  vsbase and vsperiod already exist for the tear probe.
 *
 * So: calibrate over a SHORT span, then check how far a prediction from it has
 * drifted after a LONG one.  The short-span period is what a kproc would use;
 * the residual is the error it would accumulate.  An eight-frame probe reported
 * gaps of 16658..16674us -- a 16us spread about 16665.6 -- and whether that is
 * noise or slope cannot be told from eight samples.
 */
static void
vsdrift(void)
{
	uvlong t0, t8, tn, t2n, t2nend;
	int i, err;

	if(m->cpuhz == 0)
		return;
	err = 0;
	if(mboxvsync() < 0)
		return;
	cycles(&t0);
	for(i = 0; i < 8; i++)
		if(mboxvsync() < 0)
			err++;
	cycles(&t8);
	for(i = 8; i < Driftframes; i++)
		if(mboxvsync() < 0)
			err++;
	cycles(&tn);
	cycles(&t2n);
	for(i = 0; i < Driftframes; i++)
		if(mboxvsync() < 0)
			err++;
	cycles(&t2nend);
	/*
	 * RAW TIMESTAMPS ONLY.  The kernel reports, the host computes.
	 *
	 * Three versions of this printed a derived figure and all three were
	 * wrong about the same thing -- integer division.  An 8-frame fit lost
	 * 1-2 ticks and amplified them 30x (12 and 24us); a 240-frame fit lost
	 * 0.90 of a tick and amplified it 240x (11us).  Every residual came out
	 * EARLY, never late, which is the signature of truncation rather than
	 * drift.
	 *
	 * Doing the arithmetic here buys nothing and costs precision: uvlong
	 * division truncates, the host has arbitrary precision, and the quantity
	 * wanted is a ratio of differences that needs no division at all until
	 * the last step.  So print the five instants and let tools/jtag/vsfit
	 * do it.
	 *
	 * This is also smaller kernel code than the version it replaces, which
	 * matters because the version it replaces panicked this board three
	 * times at a fixed pc.
	 */
	print("SCREEN drift raw frames %d err %d hz %lud\n",
		Driftframes, err, (ulong)m->cpuhz);
	print("SCREEN drift raw t0 %llud t8 %llud tn %llud t2n %llud t2nend %llud\n",
		t0, t8, tn, t2n, t2nend);
}

static void
teararm(void)
{
	uvlong a, b;
	int i;

	if(!Tearprobe)
		return;
	ntearop = ntearrow = nopchecked = 0;
	vsperiod = vsmeasured = vsmeasuredus = 0;
	vsclosed = 0;
	if(mboxvsync() < 0)
		return;
	cycles(&a);
	/*
	 * Eight frames, not one: the period divides the measurement error
	 * by the number of frames spanned, and the error is what limits how
	 * long the window can stay open.
	 */
	for(i = 0; i < 8; i++)
		if(mboxvsync() < 0)
			return;
	cycles(&b);
	if(b <= a)
		return;
	vsperiod = vsmeasured = (b - a) / 8;
	/*
	 * And in microseconds, because every cost in this file is in
	 * microseconds and vsmeasured is in cycles() ticks.  A comparison
	 * across the two silently never fires: ndeferover was tested against
	 * vsmeasured directly, so at 19.2MHz a 16.665ms frame is 320000 and
	 * no damage-sized copy in microseconds ever exceeded it.  m->cpuhz is
	 * the 19.2MHz counter frequency here, not the CPU clock -- see
	 * vsyncprobe().
	 */
	vsmeasuredus = m->cpuhz? vsmeasured * 1000000 / (uvlong)m->cpuhz: 0;
	vsbase = b;
	vsend = b + (uvlong)Tearframes * vsperiod;
}

/*
 * The counters are plain increments and drawing can in principle run on
 * more than one core, so a lost increment is possible; devdraw holds
 * drawlock across a draw, which is why it has not been made atomic, and
 * the direction of any error is to UNDERCOUNT.  That matters only if the
 * answer is near zero, and a near-zero answer is the one claim this probe
 * must not make on its own.
 */
static void
tearcharge(Rectangle r)
{
	uvlong now, phase;
	int beam, hi;

	if(vsperiod == 0)
		return;
	cycles(&now);
	if(now >= vsend){
		/*
		 * Stop accounting, but keep the period for the report: it is
		 * cleared here and read later, and zeroing both made the
		 * report say "period 0", which reads as "never calibrated"
		 * rather than "the window closed".  Two states that look
		 * alike in a number are two states that get confused.
		 */
		vsperiod = 0;
		vsclosed = 1;
		return;
	}
	phase = (now - vsbase) % vsperiod;
	beam = (int)((phase * ScrY) / vsperiod);
	nopchecked++;
	hi = r.max.y < beam? r.max.y: beam;
	if(hi > r.min.y){
		ntearop++;
		ntearrow += hi - r.min.y;
	}
}

int
hwdraw(Memdrawparam *par)
{
	/*
	 * Overlay cursor: softscreen never contains the glyph, so there
	 * is nothing to avoid/hide when apps draw (including Bounce).
	 *
	 * Returns 0 always: this accelerates nothing and only measures.
	 */
	/*
	 * dst->data, NOT dst == gscreen.  A Tk window is a Memlayer whose
	 * Memimage is its own but whose Memdata is "shared by windows in
	 * this image" (memdraw.h), so a comparison against gscreen itself
	 * matches only draws straight to the root and would have reported
	 * zero torn rows for every window in a real session -- a probe
	 * silently measuring nothing, which is the failure this one was
	 * written to replace.  A layer's rectangle is already in screen
	 * coordinates, so par->r needs no translation.
	 */
	if(Tearprobe && par != nil && gscreen != nil
	&& par->dst != nil && par->dst->data == gscreen->data)
		tearcharge(par->r);
	return 0;
}

int
ishwimage(Memimage *i)
{
	USED(i);
	return 0;
}
