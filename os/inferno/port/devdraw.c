#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

#define	Image	IMAGE
#include	<draw.h>
#include	<memdraw.h>
#include	<memlayer.h>
#include	<cursor.h>
#include	"screen.h"

enum
{
	Qtopdir		= 0,
	Qnew,
	Qwinname,
	Q3rd,
	Q2nd,
	Qcolormap,
	Qctl,
	Qdata,
	Qrefresh,
};

/*
 * Qid path is:
 *	 4 bits of file type (qids above)
 *	24 bits of mux slot number +1; 0 means not attached to client
 */
#define	QSHIFT	4	/* location in qid of client # */

#define	QID(q)		((((u32)(q).path)&0x0000000F)>>0)
#define	CLIENTPATH(q)	((((u32)q)&0x7FFFFFF0)>>QSHIFT)
#define	CLIENT(q)	CLIENTPATH((q).path)

#define	NHASH		(1<<5)
#define	HASHMASK	(NHASH-1)
#define	IOUNIT		(64*1024)

typedef struct Client Client;
typedef struct Draw Draw;
typedef struct DImage DImage;
typedef struct DScreen DScreen;
typedef struct CScreen CScreen;
typedef struct FChar FChar;
typedef struct Refresh Refresh;
typedef struct Refx Refx;
typedef struct DName DName;

u32 blanktime = 30;	/* in minutes; a half hour */

struct Draw
{
	QLock	q;
	s32		clientid;
	s32		nclient;
	Client**	client;
	s32		nname;
	DName*		name;
	s32		vers;
	s32		softscreen;
	s32		blanked;	/* screen turned off */
	u32		blanktime;	/* time of last operation */
	u32		savemap[3*256];
};

struct Client
{
	Ref		r;
	DImage*		dimage[NHASH];
	CScreen*	cscreen;
	Refresh*	refresh;
	Rendez		refrend;
	QLock		refq;
	uchar*		readdata;
	s32		nreaddata;
	s32		busy;
	s32		clientid;
	s32		slot;
	s32		refreshme;
	s32		infoid;
	s32		op;
	/*
	 * Optional draw3d protocol state (letters 3/M/w/u/z/g/G/h/j/k/K).
	 * Same fields and the same order as emu/port/devdraw.c's Client,
	 * because the helpers below are that file's, unchanged: the two
	 * implementations of this device have to agree about what a 3D
	 * message means or a program is portable only by accident.
	 */
	float		d3model[16];
	float		d3proj[16];
	float		d3mx, d3cx, d3my, d3cy;
	int		d3zenable;
	int		d3clipbehind;
	int		*d3zbuf;
	int		d3zw, d3zh;
	Rectangle	d3zr;
};

struct Refresh
{
	DImage*		dimage;
	Rectangle	r;
	Refresh*	next;
};

struct Refx
{
	Client*		client;
	DImage*		dimage;
};

struct DName
{
	char		*name;
	Client		*client;
	DImage*		dimage;
	int		vers;
};

struct FChar
{
	int		minx;	/* left edge of bits */
	int		maxx;	/* right edge of bits */
	uchar		miny;	/* first non-zero scan-line */
	uchar		maxy;	/* last non-zero scan-line + 1 */
	schar		left;	/* offset of baseline */
	uchar		width;	/* width of baseline */
};

/*
 * Reference counts in DImages:
 *	one per open by original client
 *	one per screen image or fill
 * 	one per image derived from this one by name
 */
struct DImage
{
	int		id;
	int		ref;
	char		*name;
	int		vers;
	Memimage*	image;
	int		ascent;
	int		nfchar;
	FChar*		fchar;
	DScreen*	dscreen;	/* 0 if not a window */
	DImage*		fromname;	/* image this one is derived from, by name */
	DImage*		next;
};

struct CScreen
{
	DScreen*	dscreen;
	CScreen*	next;
};

struct DScreen
{
	int		id;
	int		public;
	int		ref;
	DImage		*dimage;
	DImage		*dfill;
	Memscreen*	screen;
	Client*		owner;
	DScreen*	next;
};

static	Draw		sdraw;
	QLock	drawlock;

static	Memimage	*screenimage;
static	DImage*	screendimage;
static	char	screenname[40];
static	int	screennameid;

static	Rectangle	flushrect;
static	int		waste;
static	DScreen*	dscreen;
extern	void		flushmemscreen(Rectangle);
	void		drawmesg(Client*, void*, int);
	void		drawuninstall(Client*, int);
	void		drawfreedimage(DImage*);
	Client*		drawclientofpath(ulong);
	DImage*	allocdimage(Memimage*);

static	char Enodrawimage[] =	"unknown id for draw image";
static	char Enodrawscreen[] =	"unknown id for draw screen";
static	char Eshortdraw[] =	"short draw message";
static	char Eshortread[] =	"draw read too short";
static	char Eimageexists[] =	"image id in use";
static	char Escreenexists[] =	"screen id in use";
static	char Edrawmem[] =	"image memory allocation failed";
static	char Ereadoutside[] =	"readimage outside image";
static	char Ewriteoutside[] =	"writeimage outside image";
static	char Enotfont[] =	"image not a font";
static	char Eindex[] =		"character index out of range";
static	char Enoclient[] =	"no such draw client";
static	char Enameused[] =	"image name in use";
static	char Enoname[] =	"no image with that name";
static	char Eoldname[] =	"named image no longer valid";
static	char Enamed[] = 	"image already has name";
static	char Ewrongname[] = 	"wrong name for image";

/* Provided by os/port/swcursor.c on virt; stub elsewhere if needed. */
extern void	swcursordounlock(void);
void	drawflush(void);

static void
dlock(void)
{
	qlock(&drawlock);
}

static int
candlock(void)
{
	return canqlock(&drawlock);
}

static void
dunlock(void)
{
	/*
	 * Softscreen boards (virt): push pending flushrect to hardware
	 * even if the client omitted a final 'v'.  Overlay cursor is
	 * painted inside flushmemscreen while we still hold drawlock.
	 */
	drawflush();
	swcursordounlock();
	qunlock(&drawlock);
}

static int
drawgen(Chan *c, char*, Dirtab*, int, int s, Dir *dp)
{
	int t;
	Qid q;
	ulong path;
	Client *cl;

	q.vers = 0;

	if(s == DEVDOTDOT){
		switch(QID(c->qid)){
		case Qtopdir:
		case Q2nd:
			mkqid(&q, Qtopdir, 0, QTDIR);
			devdir(c, q, "#i", 0, eve, 0500, dp);
			break;
		case Q3rd:
			cl = drawclientofpath(c->qid.path);
			if(cl == nil)
				strcpy(up->genbuf, "??");
			else
				sprint(up->genbuf, "%d", cl->clientid);
			mkqid(&q, Q2nd, 0, QTDIR);
			devdir(c, q, up->genbuf, 0, eve, 0500, dp);
			break;
		default:
			panic("drawwalk %llux", c->qid.path);
		}
		return 1;
	}

	/*
	 * Top level directory contains the name of the device.
	 */
	t = QID(c->qid);
	switch(t){
	case Qtopdir:
		if(s == 0){
			mkqid(&q, Q2nd, 0, QTDIR);
			devdir(c, q, "draw", 0, eve, 0555, dp);
			return 1;
		}
		if(s == 1){
	case Qwinname:
			mkqid(&q, Qwinname, 0, QTFILE);
			devdir(c, q, "winname", 0, eve, 0444, dp);
			return 1;
		}
		return -1;
	}

	/*
	 * Second level contains "new" plus all the clients.
	 */
	switch(t){
	case Q2nd:
		if(s == 0){
	case Qnew:
			mkqid(&q, Qnew, 0, QTFILE);
			devdir(c, q, "new", 0, eve, 0666, dp);
			return 1;
		}
		if(s <= sdraw.nclient){
			cl = sdraw.client[s-1];
			if(cl == nil)
				return 0;
			sprint(up->genbuf, "%d", cl->clientid);
			mkqid(&q, (s<<QSHIFT)|Q3rd, 0, QTDIR);
			devdir(c, q, up->genbuf, 0, eve, 0555, dp);
			return 1;
		}
		return -1;
	}

	/*
	 * Third level.
	 */
	path = c->qid.path&~((1<<QSHIFT)-1);	/* slot component */
	q.vers = c->qid.vers;
	q.type = QTFILE;
	switch(s){
	case 0:
		q.path = path|Qcolormap;
		devdir(c, q, "colormap", 0, eve, 0600, dp);
		break;
	case 1:
		q.path = path|Qctl;
		devdir(c, q, "ctl", 0, eve, 0600, dp);
		break;
	case 2:
		q.path = path|Qdata;
		devdir(c, q, "data", 0, eve, 0600, dp);
		break;
	case 3:
		q.path = path|Qrefresh;
		devdir(c, q, "refresh", 0, eve, 0400, dp);
		break;
	default:
		return -1;
	}
	return 1;
}

static
int
drawrefactive(void *a)
{
	Client *c;

	c = a;
	return c->refreshme || c->refresh!=0;
}

static
void
drawrefreshscreen(DImage *l, Client *client)
{
	while(l != nil && l->dscreen == nil)
		l = l->fromname;
	if(l != nil && l->dscreen->owner != client)
		l->dscreen->owner->refreshme = 1;
}

static
void
drawrefresh(Memimage*, Rectangle r, void *v)
{
	Refx *x;
	DImage *d;
	Client *c;
	Refresh *ref;

	if(v == 0)
		return;
	x = v;
	c = x->client;
	d = x->dimage;
	for(ref=c->refresh; ref; ref=ref->next)
		if(ref->dimage == d){
			combinerect(&ref->r, r);
			return;
		}
	ref = malloc(sizeof(Refresh));
	if(ref){
		ref->dimage = d;
		ref->r = r;
		ref->next = c->refresh;
		c->refresh = ref;
	}
}

/*
 * How much damage does one PRESENT carry, and how much of it repeats the
 * previous present's?
 *
 * doc/open-issues-plan.ms H1a.  Double buffering with incremental drawing
 * costs, per frame,
 *
 *	deferred = |damage(N-1) \ damage(N)|
 *	eager    = |damage(N)|
 *
 * so the whole value of the deferred scheme is SUM |damage(N-1) AND damage(N)|,
 * the overlap of consecutive frames' damage.  Two instruments have already
 * tried to measure that and measured something adjacent to it instead: a
 * histogram of flush sizes (which throws the order away, and the question is
 * about order) and a per-flush overlap (which assumes a flush is a frame).
 *
 * THIS one is in the right place, and the reason is 'v'.  A flush is not a
 * frame: dunlock() calls drawflush() on every /dev/draw write that took the
 * drawlock, so damage reaches a driver in however many pieces the writes
 * happened to come in.  But 'v' IS a frame -- it is the client declaring a
 * present, emitted by libdraw's flushimage(d, 1) and by nothing else
 * (flushimage(d, 0) flushes the command buffer without it).  So accumulate
 * the union of damage between 'v' commands and the quantity is exact, with no
 * new interface and nothing platform-specific: a host window's upload and a
 * board's page flip are both downstream of this.
 *
 * nflushper is the number that settles the earlier instrument: flushes
 * accumulated into one present.  At 1 a flush WAS a frame and the per-flush
 * overlap was measuring the right thing after all.  Above 1 it was measuring
 * redundancy within a frame, which a present coalesces.
 *
 * SETTLED FOR TK AND FOR drawink, AND FALSE IN GENERAL.  wm/gfxstress on this
 * board puts about 80 flushes into a single present, so "a flush is a frame" is
 * a property of the WORKLOAD and not of the system -- which means the per-flush
 * overlap instrument over-counts for a fragmenting client, exactly as was first
 * feared and then wrongly dismissed on the strength of two agreeing workloads.
 * nflushpermax is what says which case you are in.  For Tk:
 *
 *	runtests -g   197 flushes / 197 frames  eager 20952256 defer 3084216
 *	wmtest -n 40  122 flushes / 122 frames  eager  8171520 defer 1182672
 *
 * 84.9 per cent both ways, 1770us -> 261us and 1115us -> 161us a frame.  So Tk
 * emits one 'v' per update and there was never any fragmentation to coalesce.
 * (An earlier version of this comment said 196 against 197 with eager differing
 * by "exactly one damage region".  That was a cumulative counter read mid-run,
 * and a gap the size of a plausible finding got explained instead of
 * questioned.  Kept as a note because it is the same error as everything else
 * in this item's history.)  This exists to confirm it on the BOARD, where the
 * client is the same Tk but the damage geometry is this screen's.
 *
 * WHAT THESE COUNTERS CANNOT TELL YOU, said because I nearly claimed they
 * could: nflushper does not distinguish a per-FRAME 'v' from a per-OPERATION
 * one.  libinterp/draw.c's checkflush() sends flushimage(display, 1) after a
 * draw when the image has flush enabled, so 'v' CAN arrive per operation --
 * and in that case each 'v' still produces exactly one flush, so nflushper
 * reads 1 either way.  The unit is established by the peer's 196-against-197
 * result above, not by anything here.  npresent close to nflush is consistent
 * with both readings and proves neither.
 *
 * nsamebb and nnestbb split the overlap the way the two readings differ:
 * an IDENTICAL present rectangle is genuine repaint of the same region, which
 * is what the scheme harvests, while one present strictly inside the next is
 * growth, which is refinement rather than repaint.  Measured on host emu,
 * growth is under 1 per cent of overlap bytes on both workloads, and the
 * peer's caveat is worth keeping: EQUAL rules out growth, not duplication,
 * since a widget repainted next frame and one flushed twice in a frame both
 * read as equal rectangles.  That is what the 'v' boundary settles and a
 * rectangle comparison cannot.
 *
 * Counters, not prints: a kernel print that recurs per frame is a denial of
 * service against every other diagnostic, and these are read by address or
 * from drawpresentstats() at the end of a run.
 *
 * ON A BOARD THAT DOES NOT FLIP these numbers are a HYPOTHETICAL -- "what the
 * two schemes would cost if this board page-flipped" -- because nothing
 * consumes them: screenpresent is nil and no buffer is ever swapped.  That is
 * deliberate, since the whole point is to decide whether a board should flip
 * before making it, but it means a reader of pc64's or virt's numbers is
 * reading a prediction and not a measurement.  Only where screenpresent is
 * non-nil do they describe work actually done.
 */
/*
 * Set by a screen driver that page-flips, called at the end of every present
 * with drawlock held.  A POINTER and not a function every board must define,
 * so no board needs a stub -- the same shape as emu's gpudrawflush.  The
 * driver keeps its own damage accumulation; all it needs from here is the
 * moment, which only 'v' knows.
 */
void	(*screenpresent)(void);

/*
 * Set by the same driver, and called from drawpre() BEFORE a partial-overwrite
 * operation draws, with that operation's rectangle in screen coordinates.
 * Pre-draw and not post: see drawpre().
 *
 * It exists because the hazard is real and measured, not precautionary.  A
 * deferred repair at 'v' excludes damage(N) from the copy, so any pixel inside
 * damage(N) that the frame did not actually write keeps the back buffer's older
 * content and is shown.  On this board, with a Limbo client, drawink reports
 *
 *	DRAW ops 15 full 13 partial 2 partial-in-stale 2
 *
 * -- the text draw is a glyph MASK, so its non-ink pixels are exactly that
 * case, and both partial operations landed in the stale region.  A peer's
 * measurement on another client stack reported zero and suggested no
 * per-operation machinery was needed; this board disagrees.
 */
void	(*screenpartial)(Rectangle);

uvlong	npresent, npresentflush, npresentempty;
uvlong	presenteager, presentdefer, presentoverlap;
uvlong	nsamebb, nnestbb, nflushper[8], nflushpermax;
static Rectangle presentbb = {{10000, 10000}, {-10000, -10000}};
static Rectangle prevpresent;
static int	havepresent;
static int	presentflushes;

/*
 * Called wherever damage is handed to the screen, to accumulate it into the
 * present being built.  Bytes are not known here -- devdraw does not own the
 * depth -- so areas are in PIXELS and a reader multiplies by the screen's
 * bytes per pixel.  Said explicitly because every byte figure this tree has
 * printed for the screen path has been wrong by a factor once already.
 */
static void
presentcharge(Rectangle r)
{
	combinerect(&presentbb, r);
	presentflushes++;
}

/*
 * Called when the client declares a present ('v').  Closes the accumulation
 * window and charges both schemes against the previous present.
 */
void
drawpresent(void)
{
	Rectangle in;
	uvlong ar, aprev, aov;
	int i;

	if(presentbb.min.x >= presentbb.max.x){
		npresentempty++;	/* a 'v' with nothing drawn since the last */
		return;
	}
	npresent++;
	npresentflush += presentflushes;
	i = presentflushes;
	if(i > nelem(nflushper)-1)
		i = nelem(nflushper)-1;
	nflushper[i]++;
	/*
	 * The top bucket SATURATES, so record the maximum beside it.  Measured
	 * need: wm/gfxstress put 2 presents in the >=7 bucket carrying about 80
	 * flushes each, and the histogram alone could not tell 7 from 80.
	 */
	if((uvlong)presentflushes > nflushpermax)
		nflushpermax = presentflushes;
	ar = (uvlong)Dx(presentbb) * Dy(presentbb);
	presenteager += ar;
	if(havepresent){
		aprev = (uvlong)Dx(prevpresent) * Dy(prevpresent);
		in = prevpresent;
		aov = rectclip(&in, presentbb)?
			(uvlong)Dx(in) * Dy(in) : 0;
		presentoverlap += aov;
		presentdefer += aprev - aov;
		if(eqrect(prevpresent, presentbb))
			nsamebb++;
		else if(aprev == aov)
			nnestbb++;	/* prev strictly inside this one */
	}
	prevpresent = presentbb;
	havepresent = 1;
	presentbb = Rect(10000, 10000, -10000, -10000);
	presentflushes = 0;
	if(screenpresent != nil)
		(*screenpresent)();
}

/*
 * Does this operation FULLY OVERWRITE its damage rectangle?
 *
 * It matters because the deferred repair happens at 'v', AFTER the frame is
 * drawn, and so excludes damage(N) from the copy.  Anything inside damage(N)
 * that the frame did not actually write keeps the stale frame-N-2 pixels the
 * back buffer held, and is shown.  See the H1a section in the plan.
 *
 * memdraw's own criterion for its opaque path is mask == memopaque, which sets
 * Fullmask in libmemdraw/draw.c, plus a source carrying no alpha.  That test
 * alone reported 15 of 15 operations PARTIAL on this board, which was the test
 * and not the board:
 *
 *	libinterp/draw.c, imagedraw():
 *		if(f->matte == H) m = d->display->white;    (ones)
 *
 * A Limbo draw with a nil mask passes display->white -- a separately allocated
 * 1x1 REPLICATED all-ones image, not memopaque -- so for any Limbo client,
 * which is to say for essentially every draw on this system, the memopaque
 * test can never succeed and the partial count is 100 per cent noise.
 *
 * So a 1x1 replicated mask is examined rather than assumed.  pixelbits() is
 * static to libmemdraw, but byteaddr() is exported, and for a 1x1 Frepl image
 * the pixel is the whole of its storage: all-ones bytes mean opaque, and
 * anything else is either a transparent mask (which memdraw no-ops while
 * dstflush still charges the rectangle -- precisely the stale-region hazard)
 * or a partial one.  Both must count as partial.
 */
static int
opaquerepl(Memimage *m)
{
	uchar *p;
	int nb, i;

	if((m->flags & Frepl) == 0)
		return 0;
	if(Dx(m->r) != 1 || Dy(m->r) != 1)
		return 0;
	p = byteaddr(m, m->r.min);
	if(p == nil)
		return 0;
	/*
	 * depth < 8 shares a byte with neighbours, but a 1x1 replicated image
	 * has no neighbours, so the whole byte is this pixel's storage and
	 * 0xFF is all-ones for GREY1 as much as for GREY8.
	 */
	nb = m->depth < 8? 1: m->depth / 8;
	for(i = 0; i < nb; i++)
		if(p[i] != 0xFF)
			return 0;
	return 1;
}

static int
fulloverwrite(Memimage *src, Memimage *mask, int op)
{
	if(op != SoverD && op != S)
		return 0;
	if(mask != memopaque && !opaquerepl(mask))
		return 0;
	if(src->flags & Falpha)
		return 0;
	return 1;
}

/*
 * Counts, not a conclusion.  npartialhit is the one that decides whether the
 * deferred scheme needs any per-operation machinery: a partial-overwrite
 * operation landing in the region where the back buffer is stale.  It is an
 * upper bound twice over -- fulloverwrite() is conservative, and this ignores
 * that an opaque background fill earlier in the SAME present has usually
 * already covered the region, which is the normal widget-repaint order.  Zero
 * means the scheme is correct with nothing added.
 */
uvlong	nopfull, noppartial, npartialhit, npresentop;

static void
chargeop(Rectangle r, int full)
{
	Rectangle in;

	npresentop++;
	if(full){
		nopfull++;
		return;
	}
	noppartial++;
	if(!havepresent)
		return;
	in = prevpresent;
	if(rectclip(&in, r))
		npartialhit++;
}

void
drawpresentstats(void)
{
	int i;

	print("DRAW present %llud empty %llud flushes %llud\n",
		npresent, npresentempty, npresentflush);
	print("DRAW dbufpix eager %llud defer %llud overlap %llud"
		" samebb %llud nestbb %llud\n",
		presenteager, presentdefer, presentoverlap, nsamebb, nnestbb);
	print("DRAW ops %llud full %llud partial %llud partial-in-stale %llud\n",
		npresentop, nopfull, noppartial, npartialhit);
	print("DRAW flushper");
	for(i = 0; i < nelem(nflushper); i++)
		print(" %d:%llud", i, nflushper[i]);
	print(" max %llud\n", nflushpermax);
}

static void
addflush(Rectangle r)
{
	int abb, ar, anbb;
	Rectangle nbb;

	if(sdraw.softscreen==0 || screenimage == nil || !rectclip(&r, screenimage->r))
		return;
	if(flushrect.min.x >= flushrect.max.x){
		flushrect = r;
		waste = 0;
		return;
	}
	nbb = flushrect;
	combinerect(&nbb, r);
	ar = Dx(r)*Dy(r);
	abb = Dx(flushrect)*Dy(flushrect);
	anbb = Dx(nbb)*Dy(nbb);
	/*
	 * Area of new waste is area of new bb minus area of old bb,
	 * less the area of the new segment, which we assume is not waste.
	 * This could be negative, but that's OK.
	 */
	waste += anbb-abb - ar;
	if(waste < 0)
		waste = 0;
	/*
	 * absorb if:
	 *	total area is small
	 *	waste is less than half total area
	 * 	rectangles touch
	 */
	if(anbb<=1024 || waste*2<anbb || rectXrect(flushrect, r)){
		flushrect = nbb;
		return;
	}
	/* emit current state */
	if(flushrect.min.x < flushrect.max.x){
		presentcharge(flushrect);
		flushmemscreen(flushrect);
	}
	flushrect = r;
	waste = 0;
}

/*
 * Map a destination rectangle to SCREEN coordinates, or say it does not reach
 * the screen.  Factored out of dstflush() because drawpre() below needs the
 * same walk BEFORE the drawing happens, and duplicating it would be two
 * chances to get the layer deltas wrong.
 */
static int
toscreen(int dstid, Memimage *dst, Rectangle r, Rectangle *out)
{
	Memlayer *l;

	if(dstid == 0){
		*out = r;
		return 1;
	}
	if(screenimage == nil || dst == nil || (l = dst->layer) == nil)
		return 0;
	do{
		if(l->screen->image->data != screenimage->data)
			return 0;
		r = rectaddpt(r, l->delta);
		l = l->screen->image->layer;
	}while(l);
	*out = r;
	return 1;
}

/*
 * Called BEFORE an operation draws, which is the whole point: a
 * partial-overwrite operation composes against whatever the destination
 * already holds, so a stale back buffer has to be brought up to date while the
 * frame can still be drawn over it.  Afterwards is useless -- repairing the
 * region then would copy the front buffer over the glyph that was just drawn.
 *
 * Counting happens in dstflush() after the fact, where it is harmless; only
 * the REPAIR has to be early.
 */
static void
drawpre(int dstid, Memimage *dst, int full)
{
	Rectangle sr, in;

	if(full || screenpartial == nil || !havepresent)
		return;
	/*
	 * The DESTINATION's whole rectangle, not the operation's.  Each
	 * operation computes its own damage box differently -- a line insets
	 * by its thickness, a string spans to the advance, an ellipse by its
	 * radii -- and reproducing five of those expressions here would be
	 * five chances to get one subtly wrong in code that only matters when
	 * it is wrong.  A superset is correct for this purpose because the
	 * driver repairs ALL of the stale region anyway, so the rectangle is
	 * used only to ask "does this destination reach the stale part of the
	 * screen at all".
	 *
	 * The cost of the conservatism is that a frame containing any partial
	 * operation degrades to the eager scheme.  That is the documented
	 * worst case and it is never a wrong picture.
	 */
	if(!toscreen(dstid, dst, dst->r, &sr))
		return;
	in = prevpresent;
	if(rectclip(&in, sr))
		(*screenpartial)(sr);
}

static
void
dstflush(int dstid, Memimage *dst, Rectangle r, int full)
{
	Rectangle sr;

	if(!toscreen(dstid, dst, r, &sr))
		return;
	chargeop(sr, full);
	if(dstid == 0){
		combinerect(&flushrect, sr);
		return;
	}
	addflush(sr);
}

void
drawflush(void)
{
	if(screenimage && flushrect.min.x < flushrect.max.x){
		presentcharge(flushrect);
		flushmemscreen(flushrect);
	}
	flushrect = Rect(10000, 10000, -10000, -10000);
}

static
int
drawcmp(char *a, char *b, int n)
{
	if(strlen(a) != n)
		return 1;
	return memcmp(a, b, n);
}

DName*
drawlookupname(int n, char *str)
{
	DName *name, *ename;

	name = sdraw.name;
	ename = &name[sdraw.nname];
	for(; name<ename; name++)
		if(drawcmp(name->name, str, n) == 0)
			return name;
	return 0;
}

int
drawgoodname(DImage *d)
{
	DName *n;

	/* if window, validate the screen's own images */
	if(d->dscreen)
		if(drawgoodname(d->dscreen->dimage) == 0
		|| drawgoodname(d->dscreen->dfill) == 0)
			return 0;
	if(d->name == nil)
		return 1;
	n = drawlookupname(strlen(d->name), d->name);
	if(n==nil || n->vers!=d->vers)
		return 0;
	return 1;
}

DImage*
drawlookup(Client *client, int id, int checkname)
{
	DImage *d;

	d = client->dimage[id&HASHMASK];
	while(d){
		if(d->id == id){
			if(checkname && !drawgoodname(d))
				error(Eoldname);
			return d;
		}
		d = d->next;
	}
	return 0;
}

DScreen*
drawlookupdscreen(int id)
{
	DScreen *s;

	s = dscreen;
	while(s){
		if(s->id == id)
			return s;
		s = s->next;
	}
	return 0;
}

DScreen*
drawlookupscreen(Client *client, int id, CScreen **cs)
{
	CScreen *s;

	s = client->cscreen;
	while(s){
		if(s->dscreen->id == id){
			*cs = s;
			return s->dscreen;
		}
		s = s->next;
	}
	error(Enodrawscreen);
	return 0;
}

DImage*
allocdimage(Memimage *i)
{
	DImage *d;

	d = malloc(sizeof(DImage));
	if(d == 0)
		return 0;
	d->ref = 1;
	d->name = 0;
	d->vers = 0;
	d->image = i;
	d->dscreen = 0;
	d->nfchar = 0;
	d->fchar = 0;
	d->fromname = 0;
	return d;
}

Memimage*
drawinstall(Client *client, int id, Memimage *i, DScreen *dscreen)
{
	DImage *d;

	d = allocdimage(i);
	if(d == 0)
		return 0;
	d->id = id;
	d->dscreen = dscreen;
	d->next = client->dimage[id&HASHMASK];
	client->dimage[id&HASHMASK] = d;
	return i;
}

Memscreen*
drawinstallscreen(Client *client, DScreen *d, int id, DImage *dimage, DImage *dfill, int public)
{
	Memscreen *s;
	CScreen *c;

	c = malloc(sizeof(CScreen));
	if(dimage && dimage->image && dimage->image->chan == 0)
		panic("bad image %p in drawinstallscreen", dimage->image);

	if(c == 0)
		return 0;
	if(d == 0){
		d = malloc(sizeof(DScreen));
		if(d == 0){
			free(c);
			return 0;
		}
		s = malloc(sizeof(Memscreen));
		if(s == 0){
			free(c);
			free(d);
			return 0;
		}
		s->frontmost = 0;
		s->rearmost = 0;
		d->dimage = dimage;
		if(dimage){
			s->image = dimage->image;
			dimage->ref++;
		}
		d->dfill = dfill;
		if(dfill){
			s->fill = dfill->image;
			dfill->ref++;
		}
		d->ref = 0;
		d->id = id;
		d->screen = s;
		d->public = public;
		d->next = dscreen;
		d->owner = client;
		dscreen = d;
	}
	c->dscreen = d;
	d->ref++;
	c->next = client->cscreen;
	client->cscreen = c;
	return d->screen;
}

void
drawdelname(DName *name)
{
	int i;

	free(name->name);
	i = name-sdraw.name;
	memmove(name, name+1, (sdraw.nname-(i+1))*sizeof(DName));
	sdraw.nname--;
}

void
drawfreedscreen(DScreen *this)
{
	DScreen *ds, *next;

	this->ref--;
	if(this->ref < 0)
		print("negative ref in drawfreedscreen\n");
	if(this->ref > 0)
		return;
	ds = dscreen;
	if(ds == this){
		dscreen = this->next;
		goto Found;
	}
	while(next = ds->next){	/* assign = */
		if(next == this){
			ds->next = this->next;
			goto Found;
		}
		ds = next;
	}
	error(Enodrawimage);

    Found:
	if(this->dimage)
		drawfreedimage(this->dimage);
	if(this->dfill)
		drawfreedimage(this->dfill);
	free(this->screen);
	free(this);
}

void
drawfreedimage(DImage *dimage)
{
	int i;
	Memimage *l;
	DScreen *ds;

	dimage->ref--;
	if(dimage->ref < 0)
		print("negative ref in drawfreedimage\n");
	if(dimage->ref > 0)
		return;

	/* any names? */
	for(i=0; i<sdraw.nname; )
		if(sdraw.name[i].dimage == dimage)
			drawdelname(sdraw.name+i);
		else
			i++;
	if(dimage->fromname){	/* acquired by name; owned by someone else*/
		drawfreedimage(dimage->fromname);
		goto Return;
	}
	ds = dimage->dscreen;
	if(ds){
		l = dimage->image;
		if(screenimage && l->data == screenimage->data)
			addflush(l->layer->screenr);
		if(l->layer->refreshfn == drawrefresh)	/* else true owner will clean up */
			free(l->layer->refreshptr);
		l->layer->refreshptr = nil;
		if(drawgoodname(dimage))
			memldelete(l);
		else
			memlfree(l);
		drawfreedscreen(ds);
	}else
		freememimage(dimage->image);
    Return:
	free(dimage->fchar);
	free(dimage);
}

void
drawuninstallscreen(Client *client, CScreen *this)
{
	CScreen *cs, *next;

	cs = client->cscreen;
	if(cs == this){
		client->cscreen = this->next;
		drawfreedscreen(this->dscreen);
		free(this);
		return;
	}
	while(next = cs->next){	/* assign = */
		if(next == this){
			cs->next = this->next;
			drawfreedscreen(this->dscreen);
			free(this);
			return;
		}
		cs = next;
	}
}

void
drawuninstall(Client *client, int id)
{
	DImage *d, *next;

	d = client->dimage[id&HASHMASK];
	if(d == 0)
		error(Enodrawimage);
	if(d->id == id){
		client->dimage[id&HASHMASK] = d->next;
		drawfreedimage(d);
		return;
	}
	while(next = d->next){	/* assign = */
		if(next->id == id){
			d->next = next->next;
			drawfreedimage(next);
			return;
		}
		d = next;
	}
	error(Enodrawimage);
}

void
drawaddname(Client *client, DImage *di, int n, char *str)
{
	DName *name, *ename, *new, *t;

	name = sdraw.name;
	ename = &name[sdraw.nname];
	for(; name<ename; name++)
		if(drawcmp(name->name, str, n) == 0)
			error(Enameused);
	t = smalloc((sdraw.nname+1)*sizeof(DName));
	memmove(t, sdraw.name, sdraw.nname*sizeof(DName));
	free(sdraw.name);
	sdraw.name = t;
	new = &sdraw.name[sdraw.nname++];
	new->name = smalloc(n+1);
	memmove(new->name, str, n);
	new->name[n] = 0;
	new->dimage = di;
	new->client = client;
	new->vers = ++sdraw.vers;
}

Client*
drawnewclient(void)
{
	Client *cl, **cp;
	int i;

	for(i=0; i<sdraw.nclient; i++){
		cl = sdraw.client[i];
		if(cl == 0)
			break;
	}
	if(i == sdraw.nclient){
		cp = malloc((sdraw.nclient+1)*sizeof(Client*));
		if(cp == 0)
			return 0;
		memmove(cp, sdraw.client, sdraw.nclient*sizeof(Client*));
		free(sdraw.client);
		sdraw.client = cp;
		sdraw.nclient++;
		cp[i] = 0;
	}
	cl = malloc(sizeof(Client));
	if(cl == 0)
		return 0;
	memset(cl, 0, sizeof(Client));
	cl->slot = i;
	cl->clientid = ++sdraw.clientid;
	cl->op = SoverD;
	sdraw.client[i] = cl;
	return cl;
}

static int
drawclientop(Client *cl)
{
	int op;

	op = cl->op;
	cl->op = SoverD;
	return op;
}

Client*
drawclientofpath(ulong path)
{
	Client *cl;
	int slot;

	slot = CLIENTPATH(path);
	if(slot == 0)
		return nil;
	cl = sdraw.client[slot-1];
	if(cl==0 || cl->clientid==0)
		return nil;
	return cl;
}


Client*
drawclient(Chan *c)
{
	Client *client;

	client = drawclientofpath(c->qid.path);
	if(client == nil)
		error(Enoclient);
	return client;
}

Memimage*
drawimage(Client *client, uchar *a)
{
	DImage *d;

	d = drawlookup(client, BG32INT(a), 1);
	if(d == nil)
		error(Enodrawimage);
	return d->image;
}

void
drawrectangle(Rectangle *r, uchar *a)
{
	r->min.x = BG32INT(a+0*4);
	r->min.y = BG32INT(a+1*4);
	r->max.x = BG32INT(a+2*4);
	r->max.y = BG32INT(a+3*4);
}

void
drawpoint(Point *p, uchar *a)
{
	p->x = BG32INT(a+0*4);
	p->y = BG32INT(a+1*4);
}

Point
drawchar(Memimage *dst, Memimage *rdst, Point p, Memimage *src, Point *sp, DImage *font, int index, int op)
{
	FChar *fc;
	Rectangle r;
	Point sp1;
	static Memimage *tmp;

	fc = &font->fchar[index];
	r.min.x = p.x+fc->left;
	r.min.y = p.y-(font->ascent-fc->miny);
	r.max.x = r.min.x+(fc->maxx-fc->minx);
	r.max.y = r.min.y+(fc->maxy-fc->miny);
	sp1.x = sp->x+fc->left;
	sp1.y = sp->y+fc->miny;

	/*
	 * If we're drawing greyscale fonts onto a VGA screen,
	 * it's very costly to read the screen memory to do the
	 * alpha blending inside memdraw.  If this is really a stringbg,
	 * then rdst is the bg image (in main memory) which we can
	 * refer to for the underlying dst pixels instead of reading dst
	 * directly.
	 */
	if(ishwimage(dst) && !ishwimage(rdst) && font->image->depth > 1){
		if(tmp == nil || tmp->chan != dst->chan || Dx(tmp->r) < Dx(r) || Dy(tmp->r) < Dy(r)){
			if(tmp)
				freememimage(tmp);
			tmp = allocmemimage(Rect(0,0,Dx(r),Dy(r)), dst->chan);
			if(tmp == nil)
				goto fallback;
		}
		memdraw(tmp, Rect(0,0,Dx(r),Dy(r)), rdst, r.min, memopaque, ZP, S);
		memdraw(tmp, Rect(0,0,Dx(r),Dy(r)), src, sp1, font->image, Pt(fc->minx, fc->miny), op);
		memdraw(dst, r, tmp, ZP, memopaque, ZP, S);
	}else{
	fallback:
		memdraw(dst, r, src, sp1, font->image, Pt(fc->minx, fc->miny), op);
	}

	p.x += fc->width;
	sp->x += fc->width;
	return p;
}

static DImage*
makescreenimage(void)
{
	int width, depth;
	ulong chan;
	DImage *di;
	Memdata *md;
	Memimage *i;
	Rectangle r;

	if((md = attachscreen(&r, &chan, &depth, &width, &sdraw.softscreen)) == nil)
		return nil;
	assert(md->ref > 0);
	if((i = allocmemimaged(r, chan, md)) == nil){
		if(--md->ref == 0 && md->allocd)
			free(md);
		return nil;
	}
	i->width = width;
	i->clipr = r;
	di = allocdimage(i);
	if(di == nil){
		freememimage(i);	/* frees md */
		return nil;
	}
	if(!waserror()){
		snprint(screenname, sizeof screenname, "noborder.screen.%d", ++screennameid);
		drawaddname(nil, di, strlen(screenname), screenname);
		poperror();
	}
	return di;
}

static int
initscreenimage(void)
{
	if(screenimage != nil)
		return 1;

	screendimage = makescreenimage();
	if(screendimage == nil)
		return 0;
	screenimage = screendimage->image;
// iprint("initscreenimage %p %p\n", screendimage, screenimage);
	/* TODO mouseresize(); */
	return 1;
}

void
deletescreenimage(void)
{
	dlock();
	if(screenimage){
		/* will be freed via screendimage; disable */
		screenimage->clipr = ZR;
		screenimage = nil;
	}
	if(screendimage){
		drawfreedimage(screendimage);
		screendimage = nil;
	}
	dunlock();
}

void
resetscreenimage(void)
{
	dlock();
	initscreenimage();
	dunlock();
}

static Chan*
drawattach(char *spec)
{
	dlock();
	if(!initscreenimage()){
		dunlock();
		error("no frame buffer");
	}
	dunlock();
	return devattach('i', spec);
}

static Walkqid*
drawwalk(Chan *c, Chan *nc, char **name, s32 nname)
{
	if(screenimage == nil)
		error("no frame buffer");
	return devwalk(c, nc, name, nname, 0, 0, drawgen);
}

static int
drawstat(Chan *c, uchar *db, s32 n)
{
	return devstat(c, db, n, 0, 0, drawgen);
}

static Chan*
drawopen(Chan *c, u32 omode)
{
	Client *cl;
	DName *dn;
	DImage *di;

	if(c->qid.type & QTDIR){
		c = devopen(c, omode, 0, 0, drawgen);
		c->iounit = IOUNIT;
	}

	dlock();
	if(waserror()){
		dunlock();
		nexterror();
	}

	if(QID(c->qid) == Qnew){
		cl = drawnewclient();
		if(cl == 0)
			error(Enodev);
		c->qid.path = Qctl|((cl->slot+1)<<QSHIFT);
	}

	switch(QID(c->qid)){
	case Qwinname:
		break;

	case Qnew:
		break;

	case Qctl:
		cl = drawclient(c);
		if(cl->busy)
			error(Einuse);
		cl->busy = 1;
		flushrect = Rect(10000, 10000, -10000, -10000);
		dn = drawlookupname(strlen(screenname), screenname);
		if(dn == 0)
			error("draw: cannot happen 2");
		if(drawinstall(cl, 0, dn->dimage->image, 0) == 0)
			error(Edrawmem);
		di = drawlookup(cl, 0, 0);
		if(di == 0)
			error("draw: cannot happen 1");
		di->vers = dn->vers;
		di->name = smalloc(strlen(screenname)+1);
		strcpy(di->name, screenname);
		di->fromname = dn->dimage;
		di->fromname->ref++;
		incref(&cl->r);
		break;

	case Qcolormap:
	case Qdata:
	case Qrefresh:
		cl = drawclient(c);
		incref(&cl->r);
		break;
	}
	dunlock();
	poperror();
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	c->iounit = IOUNIT;
	return c;
}

static void
drawclose(Chan *c)
{
	int i;
	DImage *d, **dp;
	Client *cl;
	Refresh *r;

	if(QID(c->qid) < Qcolormap)	/* Qtopdir, Qnew, Q3rd, Q2nd have no client */
		return;
	dlock();
	if(waserror()){
		dunlock();
		nexterror();
	}

	cl = drawclient(c);
	if(QID(c->qid) == Qctl)
		cl->busy = 0;
	if((c->flag&COPEN) && (decref(&cl->r)==0)){
		while(r = cl->refresh){	/* assign = */
			cl->refresh = r->next;
			free(r);
		}
		/* free names */
		for(i=0; i<sdraw.nname; )
			if(sdraw.name[i].client == cl)
				drawdelname(sdraw.name+i);
			else
				i++;
		while(cl->cscreen)
			drawuninstallscreen(cl, cl->cscreen);
		/* all screens are freed, so now we can free images */
		dp = cl->dimage;
		for(i=0; i<NHASH; i++){
			while((d = *dp) != nil){
				*dp = d->next;
				drawfreedimage(d);
			}
			dp++;
		}
		sdraw.client[cl->slot] = 0;
		drawflush();	/* to erase visible, now dead windows */
		free(cl);
	}
	dunlock();
	poperror();
}

s32
drawread(Chan *c, void *a, s32 n, s64 off)
{
	int index, m;
	u32 red, green, blue;
	Client *cl;
	uchar *p;
	Refresh *r;
	DImage *di;
	Memimage *i;
	ulong offset = off;
	char buf[16];

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, 0, 0, drawgen);
	if(QID(c->qid) == Qwinname)
		return readstr(off, a, n, screenname);

	cl = drawclient(c);
	dlock();
	if(waserror()){
		dunlock();
		nexterror();
	}
	switch(QID(c->qid)){
	case Qctl:
		if(n < 12*12)
			error(Eshortread);
		if(cl->infoid < 0)
			error(Enodrawimage);
		if(cl->infoid == 0){
			i = screenimage;
			if(i == nil)
				error(Enodrawimage);
		}else{
			di = drawlookup(cl, cl->infoid, 1);
			if(di == nil)
				error(Enodrawimage);
			i = di->image;
		}
		/*
		 * KenC LP64: snprint/va_arg mishandles multiple ints in one
		 * call (second %d reads a pointer-sized slot).  Format fields
		 * without varargs.
		 */
		if(chantostr(buf, i->chan) == nil)
			strcpy(buf, "???");
		{
			char *cp, *ep;
			int repl;
			s32 r0, r1, r2, r3, c0, c1, c2, c3;

			/*
			 * One value per snprint: KenC LP64 va_arg mis-reads
			 * the 2nd+ int in a multi-int vararg list (Qctl was
			 * emitting infoid as a pointer and r as 0,480,0,480).
			 */
			repl = (i->flags&Frepl)==Frepl;
			r0 = i->r.min.x; r1 = i->r.min.y;
			r2 = i->r.max.x; r3 = i->r.max.y;
			c0 = i->clipr.min.x; c1 = i->clipr.min.y;
			c2 = i->clipr.max.x; c3 = i->clipr.max.y;
			cp = a;
			ep = cp + n;
			cp += snprint(cp, ep-cp, "%11d ", cl->clientid);
			cp += snprint(cp, ep-cp, "%11d ", cl->infoid);
			cp += snprint(cp, ep-cp, "%11s ", buf);
			cp += snprint(cp, ep-cp, "%11d ", repl);
			cp += snprint(cp, ep-cp, "%11d ", r0);
			cp += snprint(cp, ep-cp, "%11d ", r1);
			cp += snprint(cp, ep-cp, "%11d ", r2);
			cp += snprint(cp, ep-cp, "%11d ", r3);
			cp += snprint(cp, ep-cp, "%11d ", c0);
			cp += snprint(cp, ep-cp, "%11d ", c1);
			cp += snprint(cp, ep-cp, "%11d ", c2);
			cp += snprint(cp, ep-cp, "%11d ", c3);
			n = cp - (char*)a;
		}
		cl->infoid = -1;
		break;

	case Qcolormap:
		p = malloc(4*12*256+1);
		if(p == 0)
			error(Enomem);
		m = 0;
		for(index = 0; index < 256; index++){
			getcolor(index, &red, &green, &blue);
			m += sprint((char*)p+m, "%11d %11ud %11ud %11ud\n", index, red>>24, green>>24, blue>>24);
		}
		n = readstr(offset, a, n, (char*)p);
		free(p);
		break;

	case Qdata:
		if(cl->readdata == nil)
			error("no draw data");
		if(n < cl->nreaddata)
			error(Eshortread);
		n = cl->nreaddata;
		memmove(a, cl->readdata, cl->nreaddata);
		free(cl->readdata);
		cl->readdata = nil;
		break;

	case Qrefresh:
		if(n < 5*4)
			error(Ebadarg);
		for(;;){
			if(cl->refreshme || cl->refresh)
				break;
			dunlock();
			if(waserror()){
				dlock();
				nexterror();
			}
			eqlock(&cl->refq);
			if(waserror()){
				qunlock(&cl->refq);
				nexterror();
			}
			sleep(&cl->refrend, drawrefactive, cl);
			poperror();
			qunlock(&cl->refq);
			poperror();
			dlock();
		}
		p = a;
		while(cl->refresh && n>=5*4){
			r = cl->refresh;
			BP32INT(p+0*4, r->dimage->id);
			BP32INT(p+1*4, r->r.min.x);
			BP32INT(p+2*4, r->r.min.y);
			BP32INT(p+3*4, r->r.max.x);
			BP32INT(p+4*4, r->r.max.y);
			cl->refresh = r->next;
			free(r);
			p += 5*4;
			n -= 5*4;
		}
		cl->refreshme = 0;
		n = p-(uchar*)a;
		break;
	}
	dunlock();
	poperror();
	return n;
}

void
drawwakeall(void)
{
	Client *cl;
	int i;

	for(i=0; i<sdraw.nclient; i++){
		cl = sdraw.client[i];
		if(cl && (cl->refreshme || cl->refresh))
			wakeup(&cl->refrend);
	}
}

static s32
drawwrite(Chan *c, void *a, s32 n, s64)
{
	char buf[128], *fields[4], *q;
	Client *cl;
	int i, m, red, green, blue, x;

	if(c->qid.type & QTDIR)
		error(Eisdir);
	cl = drawclient(c);
	dlock();
	if(waserror()){
		drawwakeall();
		dunlock();
		nexterror();
	}
	switch(QID(c->qid)){
	case Qctl:
		if(n != 4)
			error("unknown draw control request");
		cl->infoid = BG32INT((uchar*)a);
		break;

	case Qcolormap:
		m = n;
		n = 0;
		while(m > 0){
			x = m;
			if(x > sizeof(buf)-1)
				x = sizeof(buf)-1;
			q = memccpy(buf, a, '\n', x);
			if(q == 0)
				break;
			i = q-buf;
			n += i;
			a = (char*)a + i;
			m -= i;
			*q = 0;
			if(tokenize(buf, fields, nelem(fields)) != 4)
				error(Ebadarg);
			i = strtoul(fields[0], 0, 0);
			red = strtoul(fields[1], 0, 0);
			green = strtoul(fields[2], 0, 0);
			blue = strtoul(fields[3], &q, 0);
			if(fields[3] == q)
				error(Ebadarg);
			if(red>255 || green>255 || blue>255 || i<0 || i>255)
				error(Ebadarg);
			red |= red<<8;
			red |= red<<16;
			green |= green<<8;
			green |= green<<16;
			blue |= blue<<8;
			blue |= blue<<16;
			setcolor(i, red, green, blue);
		}
		break;

	case Qdata:
		drawmesg(cl, a, n);
		drawwakeall();
		break;

	default:
		error(Ebadusefd);
	}
	dunlock();
	poperror();
	return n;
}

uchar*
drawcoord(uchar *p, uchar *maxp, int oldx, int *newx)
{
	int b, x;

	if(p >= maxp)
		error(Eshortdraw);
	b = *p++;
	x = b & 0x7F;
	if(b & 0x80){
		if(p+1 >= maxp)
			error(Eshortdraw);
		x |= *p++ << 7;
		x |= *p++ << 15;
		if(x & (1<<22))
			x |= ~0<<23;
	}else{
		if(b & 0x40)
			x |= ~0<<7;
		x += oldx;
	}
	*newx = x;
	return p;
}

static void
printmesg(char *fmt, uchar *a, int plsprnt)
{
	char buf[256];
	char *p, *q;
	int s;

	if(1|| plsprnt==0){
		SET(s,q,p);
		USED(fmt, a, buf, p, q, s);
		return;
	}
	q = buf;
	*q++ = *a++;
	for(p=fmt; *p; p++){
		switch(*p){
		case 'l':
			q += sprint(q, " %ld", (long)BG32INT(a));
			a += 4;
			break;
		case 'L':
			q += sprint(q, " %.8lux", (ulong)BG32INT(a));
			a += 4;
			break;
		case 'R':
			q += sprint(q, " [%d %d %d %d]", BG32INT(a), BG32INT(a+4), BG32INT(a+8), BG32INT(a+12));
			a += 16;
			break;
		case 'P':
			q += sprint(q, " [%d %d]", BG32INT(a), BG32INT(a+4));
			a += 8;
			break;
		case 'b':
			q += sprint(q, " %d", *a++);
			break;
		case 's':
			q += sprint(q, " %d", BG16INT(a));
			a += 2;
			break;
		case 'S':
			q += sprint(q, " %.4ux", BG16INT(a));
			a += 2;
			break;
		}
	}
	*q++ = '\n';
	*q = 0;
	iprint("%.*s", (int)(q-buf), buf);
}

/*
 * The 719 lines below are emu/port/devdraw.c's draw3d helpers, carried
 * here UNCHANGED, which is deliberate: a draw3d message has to mean the
 * same thing in the kernel as it does hosted, and the cheapest way to
 * guarantee that is for the code to be the same text.  So the two
 * differences between the environments are absorbed here instead of
 * being edited into the body.
 *
 * One: the hosted file uses the float-suffixed libm names.  This kernel
 * has the double ones -- sin and cos from libkern/sin.c, declared in
 * include/mathi.h, and fabs from ../port/lib.h -- so they are wrapped.
 * The arithmetic is float either way; only the call is widened.
 *
 * Two: this kernel's dstflush() takes the destination id as well as the
 * image, because id 0 means the screen itself and is flushed differently
 * from a layer; the hosted one derives everything from the image. So the
 * arms read `dstid = BG32INT(a+1)' beside their drawimage(), which is
 * what this file's own arms already do, and pass it along.
 *
 * Three: the gpudraw* hooks below stay nil here.  Hosted, win-cocoa.m
 * assigns them and the work goes to Metal; nothing on a Pi 3B assigns
 * them yet, so every letter takes the software path, which is what the
 * nil check has always been for.  That is the seam a VideoCore backend
 * would fill, and it needs no change to any of this.
 */
/*
 * THE GPU SEAM. Hosted, emu/MacOSX/win-cocoa.m assigns these and the
 * draw3d letters go to Metal; nil means "not hooked" and every letter
 * takes the software path below. Nothing on a Pi 3B assigns them yet,
 * so they are nil here and the board rasterises in software -- which is
 * the point of the nil check and why the letters work at all before any
 * GPU work exists.
 *
 * Same names, same signatures and the same nil contract as the hosted
 * file, so a VideoCore backend is a file that assigns these and nothing
 * in this device changes.
 */
int	(*gpudrawline)(Memimage*, Point, Point, int, Memimage*, int, float, float);
int	(*gpudrawfillpoly)(Memimage*, Point*, float*, int, Memimage*, int, float);
int	(*gpudrawfillpoly3d)(Memimage*, float*, float*, float*, int, Memimage*, int,
	float, float*, float*, float, float, float, float);
int	(*gpudrawfillpoly3g)(Memimage*, float*, float*, float*, float*, int, Memimage*,
	int, float*, float*, float, float, float, float);
int	(*gpudrawplot)(Memimage*, Point, Memimage*, int, float);
int	(*gpudrawsprite)(Memimage*, Point, int, int, float, Memimage*, Memimage*, float, int);
int	(*gpudrawsprite2d)(Memimage*, Point, int, int, Memimage*, Memimage*, float, int, int);
int	(*gpudrawellipse)(Memimage*, Point, int, int, int, int, Memimage*, int, float);
void	(*gpudrawflush)(void);
void	(*gpudrawreadback)(void);
void	(*gpudrawzclear)(void);
void	(*gpudrawzenable)(int);

extern	double	sin(double);
extern	double	cos(double);
extern	double	sqrt(double);
#define	M_PI	3.14159265358979323846
#define	sinf(x)		((float)sin((double)(x)))
#define	cosf(x)		((float)cos((double)(x)))
#define	fabsf(x)	((float)fabs((double)(x)))
#define	sqrtf(x)	((float)sqrt((double)(x)))

/*
 * draw3d protocol helpers (software raster into Memimage; Metal when hooked).
 * Floats are IEEE754 binary32, little-endian (same endianness as BG32INT).
 * Soft z uses Limbo draw3d/polyfill plane scale (ZSCALE = 1<<20).
 */
enum {
	D3ZSCALE	= 1<<20,
	D3LIMIT		= 1<<11,
	D3CapMatrix	= 1<<0,
	D3CapFill	= 1<<1,
	D3CapLine	= 1<<2,
	D3CapPlot	= 1<<3,
	D3CapSprite	= 1<<4,
	D3CapEllipse	= 1<<5,
	D3CapGPU	= 1<<6,
	D3CapReadback	= 1<<7,
	D3CapNearClip	= 1<<8,
	D3CapDepthOrder	= 1<<9,
	D3CapGouraud	= 1<<10,
	/* 1<<11 is D3LIMIT above, so the next capability is 1<<12. */
	D3CapSprite2d	= 1<<12
};

static float
bgfloat(uchar *p)
{
	u32 u;
	float f;

	u = (u32)BG32INT(p);
	memmove(&f, &u, sizeof f);
	return f;
}

static void
d3loadmat(float *m, uchar *a)
{
	int i;

	for(i = 0; i < 16; i++)
		m[i] = bgfloat(a + i*4);
}

static void
d3mulpoint(float *m, float x, float y, float z, float *ox, float *oy, float *oz)
{
	float x1, y1, z1, w;

	x1 = x*m[0] + y*m[1] + z*m[2] + m[3];
	y1 = x*m[4] + y*m[5] + z*m[6] + m[7];
	z1 = x*m[8] + y*m[9] + z*m[10] + m[11];
	w  = x*m[12] + y*m[13] + z*m[14] + m[15];
	if(w != 0.0f && w != 1.0f){
		x1 /= w;
		y1 /= w;
		z1 /= w;
	}
	*ox = x1;
	*oy = y1;
	*oz = z1;
}

/* Model then proj (matches Limbo draw3d project); returns 0 if clipped. */
static int
d3project(Client *cl, float x, float y, float z, Point *sp, float *eyez)
{
	float ex, ey, ez, cx, cy, cz;

	d3mulpoint(cl->d3model, x, y, z, &ex, &ey, &ez);
	*eyez = ez;
	if(cl->d3clipbehind && ez >= 0.0f)
		return 0;
	d3mulpoint(cl->d3proj, ex, ey, ez, &cx, &cy, &cz);
	sp->x = (int)(cl->d3mx * cx + cl->d3cx);
	sp->y = (int)(cl->d3my * cy + cl->d3cy);
	return 1;
}

/* Clip a segment in eye space instead of dropping it when it crosses z=0. */
static int
d3projectline(Client *cl, float ax, float ay, float az, float bx, float by, float bz,
	Point *pa, Point *pb, float *eza, float *ezb)
{
	float aex, aey, aez, bex, bey, bez, cx, cy, cz, t;
	float const nearz = -1.0e-4f;

	d3mulpoint(cl->d3model, ax, ay, az, &aex, &aey, &aez);
	d3mulpoint(cl->d3model, bx, by, bz, &bex, &bey, &bez);
	if(cl->d3clipbehind){
		if(aez >= nearz && bez >= nearz)
			return 0;
		if(aez >= nearz){
			t = (nearz - bez) / (aez - bez);
			aex = bex + t*(aex-bex);
			aey = bey + t*(aey-bey);
			aez = nearz;
		}else if(bez >= nearz){
			t = (nearz - aez) / (bez - aez);
			bex = aex + t*(bex-aex);
			bey = aey + t*(bey-aey);
			bez = nearz;
		}
	}
	d3mulpoint(cl->d3proj, aex, aey, aez, &cx, &cy, &cz);
	pa->x = (int)(cl->d3mx * cx + cl->d3cx);
	pa->y = (int)(cl->d3my * cy + cl->d3cy);
	d3mulpoint(cl->d3proj, bex, bey, bez, &cx, &cy, &cz);
	pb->x = (int)(cl->d3mx * cx + cl->d3cx);
	pb->y = (int)(cl->d3my * cy + cl->d3cy);
	*eza = aez;
	*ezb = bez;
	return 1;
}

/*
 * The same clip, carrying a per-vertex value with it.
 *
 * The flat path ('k') has clipped against the eye plane since it was
 * written; the Gouraud path ('K') did not, and that was the whole of
 * gorge(1)'s wrong picture through Metal.  A polygon straddling the
 * plane has a vertex with w <= 0 after projection, the triangle wraps,
 * and the GPU paints an enormous wrong face: g3probe(1) measured 185898
 * lit pixels against the software provider's 40596 for a wall running
 * through the eye.
 *
 * Interpolating the lit value by the same parameter is the only
 * addition.  It is right for the same reason the positions are: the
 * model transform is affine, so eye z is affine along a model-space
 * edge, and one parameter serves for every quantity carried along it.
 *
 * Bounded at D3CLIPMAX so the caller can keep its output on the stack.
 * A polygon with more vertices than that is left to the caller, which
 * refuses it to the GPU and lets the CPU path have it - correct, just
 * not accelerated.  Every face either game draws is a triangle or a
 * quad.
 */
enum { D3CLIPMAX = 8 };

static int
d3clipnearlit(Client *cl, float *ix, float *iy, float *iz, float *il, int n,
	float *ox, float *oy, float *oz, float *ol)
{
	float sx, sy, sz, sl, ex, ey, ez, el, qx, qy, sez, eez, t;
	float const nearz = -1.0e-4f;
	int i, m, sin, ein;

	if(!cl->d3clipbehind){
		for(i = 0; i < n; i++){
			ox[i] = ix[i];
			oy[i] = iy[i];
			oz[i] = iz[i];
			ol[i] = il[i];
		}
		return n;
	}
	m = 0;
	sx = ix[n-1]; sy = iy[n-1]; sz = iz[n-1]; sl = il[n-1];
	d3mulpoint(cl->d3model, sx, sy, sz, &qx, &qy, &sez);
	sin = sez < nearz;
	for(i = 0; i < n; i++){
		ex = ix[i]; ey = iy[i]; ez = iz[i]; el = il[i];
		d3mulpoint(cl->d3model, ex, ey, ez, &qx, &qy, &eez);
		ein = eez < nearz;
		if(sin != ein){
			t = (nearz - sez) / (eez - sez);
			ox[m] = sx + t*(ex-sx);
			oy[m] = sy + t*(ey-sy);
			oz[m] = sz + t*(ez-sz);
			ol[m++] = sl + t*(el-sl);
		}
		if(ein){
			ox[m] = ex;
			oy[m] = ey;
			oz[m] = ez;
			ol[m++] = el;
		}
		sx = ex; sy = ey; sz = ez; sl = el; sez = eez; sin = ein;
	}
	return m;
}

/* Sutherland-Hodgman clip against the eye plane used by clipbehind. */
static int
d3clipnear(Client *cl, float *ix, float *iy, float *iz, int n,
	float *ox, float *oy, float *oz)
{
	float sx, sy, sz, ex, ey, ez, qx, qy, sez, eez, t;
	float const nearz = -1.0e-4f;
	int i, m, sin, ein;

	if(!cl->d3clipbehind){
		for(i = 0; i < n; i++){
			ox[i] = ix[i];
			oy[i] = iy[i];
			oz[i] = iz[i];
		}
		return n;
	}
	m = 0;
	sx = ix[n-1]; sy = iy[n-1]; sz = iz[n-1];
	d3mulpoint(cl->d3model, sx, sy, sz, &qx, &qy, &sez);
	sin = sez < nearz;
	for(i = 0; i < n; i++){
		ex = ix[i]; ey = iy[i]; ez = iz[i];
		d3mulpoint(cl->d3model, ex, ey, ez, &qx, &qy, &eez);
		ein = eez < nearz;
		if(sin != ein){
			t = (nearz - sez) / (eez - sez);
			ox[m] = sx + t*(ex-sx);
			oy[m] = sy + t*(ey-sy);
			oz[m++] = sz + t*(ez-sz);
		}
		if(ein){
			ox[m] = ex;
			oy[m] = ey;
			oz[m++] = ez;
		}
		sx = ex; sy = ey; sz = ez; sez = eez; sin = ein;
	}
	return m;
}

static void
d3clearz(Client *cl, Memimage *dst)
{
	int n, i;
	Rectangle r;

	if(dst == nil)
		return;
	r = dst->clipr;
	n = Dx(r) * Dy(r);
	if(n <= 0)
		return;
	if(cl->d3zbuf == nil || cl->d3zw != Dx(r) || cl->d3zh != Dy(r)
	|| !eqrect(cl->d3zr, r)){
		free(cl->d3zbuf);
		cl->d3zbuf = malloc(sizeof(int) * n);
		if(cl->d3zbuf == nil)
			error(Edrawmem);
		cl->d3zw = Dx(r);
		cl->d3zh = Dy(r);
		cl->d3zr = r;
	}
	/* ∞ depth: farther than any projected eye z (more positive = farther). */
	for(i = 0; i < n; i++)
		cl->d3zbuf[i] = 0x7fffffff;
}

/* True iff cl->d3model is the identity matrix. */
static int
d3modelisident(Client *cl)
{
	int i, j;

	for(i = 0; i < 4; i++)
		for(j = 0; j < 4; j++)
			if(cl->d3model[i*4+j] != (i == j ? 1.0f : 0.0f))
				return 0;
	return 1;
}

/*
 * Limbo draw3d fillpoly3 plane in screen space (same formulae as draw3d.b).
 * vx,vy,vz are verts in the same space as the face normal - this formula
 * maps that space to screen coordinates through the viewport scale alone,
 * with no model or projection transform in between, so it's only valid
 * when cl->d3model is identity (the caller must check d3modelisident()
 * first) - a real model matrix (rotation/translation) needs the general,
 * slower d3planefromeyez() below instead, which derives the plane from
 * already-projected screen points + eye z rather than assuming vx/vy/vz
 * map to the screen directly.
 */
static int
d3planecoeffs(Client *cl, float nx, float ny, float nz,
	float *vx, float *vy, float *vz, int n,
	int *pdx, int *pdy, int *pdc)
{
	float d, cz, a, b, dd, α, β, γ, δ;
	int i;

	if(n < 3 || nz == 0.0f)
		return 0;
	d = 0.0f;
	for(i = 0; i < n; i++)
		d += nx*vx[i] + ny*vy[i] + nz*vz[i];
	d /= (float)n;
	α = cl->d3mx;
	β = cl->d3cx;
	γ = cl->d3my;
	δ = cl->d3cy;
	if(α == 0.0f || γ == 0.0f)
		return 0;
	cz = nz;
	if(cz > -1e-6f && cz < 1e-6f)
		return 0;
	a = -nx / (cz * α);
	b = -ny / (cz * γ);
	dd = d / cz - β * a - δ * b;
	if(a <= -(float)D3LIMIT || a >= (float)D3LIMIT
	|| b <= -(float)D3LIMIT || b >= (float)D3LIMIT
	|| dd <= -(float)D3LIMIT || dd >= (float)D3LIMIT)
		return 0;
	/*
	 * Negated, because what the arithmetic above produces is the eye z
	 * itself - negative in front of the viewer - and every producer and
	 * consumer of this buffer uses its negation: positive in front,
	 * smaller nearer.  d3planefromeyez() below starts from -ez[i] and
	 * says so in its own comment; d3zpixel and the 'h' handler compare
	 * (int)(-eyez * D3ZSCALE); draw3d.b's own copy of these formulae
	 * negates too (z0 := -eye[0].z).  This one did not, so a face drawn
	 * through it filled the depth buffer with the sign inverted: the
	 * further face won, and a point in front of a wall lost to it.
	 *
	 * Measured with g3probe(1) and INFERNO_NOGPU=1, so that devdraw's
	 * own rasteriser is what draws - a near green quad and a far red
	 * one, green pixels surviving:
	 *
	 *	order       before   after   software
	 *	far,near       527     594        594
	 *	near,far         0     594        594
	 *
	 * Zero.  The near quad was entirely hidden by the far one, and the
	 * order mattered, which is precisely what a depth buffer is for.
	 */
	*pdx = (int)(-a * (float)D3ZSCALE);
	*pdy = (int)(-b * (float)D3ZSCALE);
	*pdc = (int)(-dd * (float)D3ZSCALE);
	return 1;
}

/* Plane through three screen points with eye-z → fixed-point coeffs. */
static int
d3planefromeyez(Point *pp, float *ez, int n, int *pdx, int *pdy, int *pdc)
{
	float x0, y0, z0, x1, y1, z1, x2, y2, z2;
	float e1x, e1y, e1z, e2x, e2y, e2z, nx, ny, nz, inv;
	float a, b, dd;

	if(n < 3)
		return 0;
	x0 = (float)pp[0].x; y0 = (float)pp[0].y; z0 = -ez[0];
	x1 = (float)pp[1].x; y1 = (float)pp[1].y; z1 = -ez[1];
	x2 = (float)pp[2].x; y2 = (float)pp[2].y; z2 = -ez[2];
	e1x = x1 - x0; e1y = y1 - y0; e1z = z1 - z0;
	e2x = x2 - x0; e2y = y2 - y0; e2z = z2 - z0;
	nx = e1y*e2z - e1z*e2y;
	ny = e1z*e2x - e1x*e2z;
	nz = e1x*e2y - e1y*e2x;
	if(nz > -1e-6f && nz < 1e-6f)
		return 0;
	/* z = a*x + b*y + dd  (eye z on the plane) */
	inv = 1.0f / nz;
	a = -nx * inv;
	b = -ny * inv;
	dd = (nx*x0 + ny*y0 + nz*z0) * inv;
	if(a <= -(float)D3LIMIT || a >= (float)D3LIMIT
	|| b <= -(float)D3LIMIT || b >= (float)D3LIMIT
	|| dd <= -(float)D3LIMIT || dd >= (float)D3LIMIT)
		return 0;
	*pdx = (int)(a * (float)D3ZSCALE);
	*pdy = (int)(b * (float)D3ZSCALE);
	*pdc = (int)(dd * (float)D3ZSCALE);
	return 1;
}

/* Convex point-in-polygon (draw3d faces are convex). */
static int
d3ptconvex(Point p, Point *v, int n)
{
	int i, s, c;
	Point a, b;

	s = 0;
	for(i = 0; i < n; i++){
		a = v[i];
		b = v[(i+1) % n];
		c = (b.x - a.x)*(p.y - a.y) - (b.y - a.y)*(p.x - a.x);
		if(c < 0){
			if(s > 0)
				return 0;
			s = -1;
		}else if(c > 0){
			if(s < 0)
				return 0;
			s = 1;
		}
	}
	return 1;
}

/*
 * Soft z-buffered fill matching Limbo polyfill semantics (closer = smaller z).
 * Falls back to memfillpoly when no z-buffer is allocated.
 */
static void
d3fillpolyz(Client *cl, Memimage *dst, Point *pp, int nw,
	Memimage *src, int op, int dc, int dx, int dy)
{
	Rectangle bbox, clip;
	Point p;
	int x, y, z, k, prevx;
	Memimage *ones;

	if(!cl->d3zenable || cl->d3zbuf == nil){
		/*
		 * pp[0] through a named local, not passed straight from the
		 * array. 7c materialises a struct value taken from an
		 * indexed expression in `nodrat', a STATIC scratch area, and
		 * warns "non-interruptable temporary" because an interrupt
		 * handler doing the same would clobber it -- which matters
		 * in the kernel copy of this file and is harmless hosted.
		 * A named local is a stack slot, so neither copy needs the
		 * scratch and the two stay the same text.
		 */
		p = pp[0];
		memfillpoly(dst, pp, nw+1, ~0, src, p, op);
		return;
	}
	/*
	 * Split, not chained: `a = b = pp[0]' makes the inner assignment's
	 * value feed the outer one, which 7c materialises in its static
	 * scratch and warns about for the same reason as above. Two plain
	 * assignments from a local need no temporary at all.
	 */
	p = pp[0];
	bbox.min = p;
	bbox.max = p;
	for(k = 1; k < nw; k++){
		if(pp[k].x < bbox.min.x) bbox.min.x = pp[k].x;
		if(pp[k].y < bbox.min.y) bbox.min.y = pp[k].y;
		if(pp[k].x > bbox.max.x) bbox.max.x = pp[k].x;
		if(pp[k].y > bbox.max.y) bbox.max.y = pp[k].y;
	}
	bbox.max.x++;
	bbox.max.y++;
	clip = dst->clipr;
	if(!rectclip(&bbox, clip) || !rectclip(&bbox, cl->d3zr))
		return;
	ones = memopaque;
	for(y = bbox.min.y; y < bbox.max.y; y++){
		prevx = 0x7fffffff;
		for(x = bbox.min.x; x < bbox.max.x; x++){
			p = Pt(x, y);
			if(!d3ptconvex(p, pp, nw)){
				if(prevx != 0x7fffffff){
					memdraw(dst, Rect(prevx, y, x, y+1),
						src, Pt(prevx, y), ones, Pt(prevx, y), op);
					prevx = 0x7fffffff;
				}
				continue;
			}
			z = dc + dx*x + dy*y;
			k = (y - cl->d3zr.min.y)*cl->d3zw + (x - cl->d3zr.min.x);
			if(k < 0 || k >= cl->d3zw*cl->d3zh)
				continue;
			if(z < cl->d3zbuf[k]){
				cl->d3zbuf[k] = z;
				if(prevx == 0x7fffffff)
					prevx = x;
			}else if(prevx != 0x7fffffff){
				memdraw(dst, Rect(prevx, y, x, y+1),
					src, Pt(prevx, y), ones, Pt(prevx, y), op);
				prevx = 0x7fffffff;
			}
		}
		if(prevx != 0x7fffffff)
			memdraw(dst, Rect(prevx, y, bbox.max.x, y+1),
				src, Pt(prevx, y), ones, Pt(prevx, y), op);
	}
}

/* Depth-tested software line/point fallback using the Metal plane-depth order. */
static void
d3linez(Client *cl, Memimage *dst, Point a, Point b, int thick,
	Memimage *src, int op, float eza, float ezb)
{
	Rectangle r;
	Point p;
	float vx, vy, len2, t, qx, qy, rad2, eyez;
	int x, y, k, z;

	if(!cl->d3zenable || cl->d3zbuf == nil){
		memline(dst, a, b, Endsquare, Endsquare, thick, src, a, op);
		return;
	}
	r = memlinebbox(a, b, Endsquare, Endsquare, thick);
	if(!rectclip(&r, dst->clipr) || !rectclip(&r, cl->d3zr))
		return;
	vx = b.x-a.x;
	vy = b.y-a.y;
	len2 = vx*vx + vy*vy;
	rad2 = ((float)thick + 0.5f)*((float)thick + 0.5f);
	for(y = r.min.y; y < r.max.y; y++)
		for(x = r.min.x; x < r.max.x; x++){
			if(len2 <= 1.0e-6f)
				t = 0.0f;
			else{
				t = ((x-a.x)*vx + (y-a.y)*vy)/len2;
				if(t < 0.0f) t = 0.0f;
				if(t > 1.0f) t = 1.0f;
			}
			qx = (float)a.x + t*vx;
			qy = (float)a.y + t*vy;
			if((x-qx)*(x-qx) + (y-qy)*(y-qy) > rad2)
				continue;
			eyez = eza + t*(ezb-eza);
			z = (int)(-eyez*(float)D3ZSCALE);
			k = (y-cl->d3zr.min.y)*cl->d3zw + x-cl->d3zr.min.x;
			/*
			 * Nearer OR EQUAL.  The Metal depth state this stands
			 * in for is MTLCompareFunctionLessEqual, so a strict
			 * test here made the CPU fallback disagree with the
			 * GPU it replaces - and threw away every overlapping
			 * step of a stroke drawn at one depth, which is how
			 * temple/lattice draws a ribbon.
			 */
			if(k < 0 || k >= cl->d3zw*cl->d3zh || z > cl->d3zbuf[k])
				continue;
			cl->d3zbuf[k] = z;
			p = Pt(x, y);
			memdraw(dst, Rect(x, y, x+1, y+1), src, p, memopaque, p, op);
		}
}

static int
d3zpixel(Client *cl, Point p, float eyez)
{
	int k, z;

	if(!cl->d3zenable || cl->d3zbuf == nil)
		return 1;
	if(!ptinrect(p, cl->d3zr))
		return 0;
	k = (p.y-cl->d3zr.min.y)*cl->d3zw + p.x-cl->d3zr.min.x;
	if(k < 0 || k >= cl->d3zw*cl->d3zh)
		return 0;
	z = (int)(-eyez*(float)D3ZSCALE);
	if(z >= cl->d3zbuf[k])
		return 0;
	cl->d3zbuf[k] = z;
	return 1;
}

static int
d3maskset(Memimage *mask, Point p)
{
	uchar *q;

	if(mask == nil)
		return 1;
	/*
	 * byteaddr() forms an address from p by arithmetic alone: it never
	 * consults the rectangle and never returns nil, so the `q == nil'
	 * test that used to stand here could not fire, and a p outside the
	 * mask was simply read at whatever address the arithmetic produced.
	 * The caller samples the source with the same shape of expression a
	 * few lines above and range-checks the result; the mask coordinate
	 * beside it was the one that went unchecked.
	 *
	 * Hardening, not a repair: instrumented to report, this guard never
	 * fires on any case in sprite2dtest(1) or draw3dsafetest(1), and the
	 * box is clipped to the destination before the loop, which looks
	 * like the structural reason a caller cannot steer the index out to
	 * the edge.  Forced out by hand, though, the read segfaults emu -
	 * so the cost of two compares buys away a whole class of question.
	 */
	if(!ptinrect(p, mask->r))
		return 0;
	q = byteaddr(mask, p);
	if(mask->depth == 1)
		/*
		 * byteaddr() gives the byte holding pixel p.x; WHICH bit is
		 * p.x&7 from the top, and this used to test bit 7 always - so
		 * seven mask pixels in every eight read their neighbour's
		 * coverage.  Every mask=1 case in sprite2dtest(1) differed on
		 * this once the box convention above was fixed.
		 */
		return (q[0] & (0x80 >> (p.x & 7))) != 0;
	return q[0] != 0;
}

/* Rotated/scaled sprite fallback with constant billboard depth. */
static void
d3spritez(Client *cl, Memimage *dst, Point c, int sw, int sh, float eyez,
	Memimage *src, Memimage *mask, float degz, int flipx, int usez, int op)
{
	Rectangle r;
	Point p, sp, mp;
	float rad, cs, sn, hx, hy, lx, ly, cxf, cyf;
	int x, y, iw, ih, mw, mh, bw, bh, u, v;

	iw = Dx(src->r); ih = Dy(src->r);
	if(iw < 1 || ih < 1 || sw < 1 || sh < 1)
		return;
	rad = degz*(float)M_PI/180.0f;
	cs = cosf(rad); sn = sinf(rad);
	hx = sw*0.5f; hy = sh*0.5f;
	/*
	 * The box, and the sampling centre inside it, exactly as
	 * transformsprite() in appl/math/draw3ddev.b computes them - the
	 * two have to agree pixel for pixel, since the same sprite2d call
	 * reaches one or the other depending only on whether a GPU took it.
	 *
	 * The subtlety is the half pixel.  The Limbo code puts the box at
	 * c - bw/2 with INTEGER division and then samples about the box's
	 * real centre, bw/2.0.  Those differ by half a pixel when bw is odd,
	 * which is whenever the sprite has an odd dimension, and this
	 * function used to sample about c itself: a 7-wide sprite landed a
	 * pixel to the left of where both the Limbo resampler and a plain
	 * draw(2) of the same rectangle put it.  21 of sprite2dtest(1)'s 24
	 * identity cases differed on that alone.
	 */
	bw = (int)((fabsf(cs)*hx + fabsf(sn)*hy)*2.0f) + 2;
	bh = (int)((fabsf(sn)*hx + fabsf(cs)*hy)*2.0f) + 2;
	if(bw < 2 || bh < 2)
		return;
	r = Rect(c.x - bw/2, c.y - bh/2, c.x - bw/2 + bw, c.y - bh/2 + bh);
	cxf = (float)(c.x - bw/2) + bw*0.5f;
	cyf = (float)(c.y - bh/2) + bh*0.5f;
	if(!rectclip(&r, dst->clipr))
		return;
	mw = mask != nil ? Dx(mask->r) : 0;
	mh = mask != nil ? Dy(mask->r) : 0;
	for(y = r.min.y; y < r.max.y; y++)
		for(x = r.min.x; x < r.max.x; x++){
			/* Inverse screen rotation into the unrotated billboard. */
			lx = (x+0.5f-cxf)*cs + (y+0.5f-cyf)*sn;
			ly = -(x+0.5f-cxf)*sn + (y+0.5f-cyf)*cs;
			/* After the inverse rotation, exactly where
			 * transformsprite() in appl/math/draw3ddev.b puts it,
			 * so the two agree pixel for pixel. */
			if(flipx)
				lx = -lx;
			if(lx < -hx || lx >= hx || ly < -hy || ly >= hy)
				continue;
			u = (int)((lx+hx)*iw/sw);
			v = (int)((ly+hy)*ih/sh);
			if(u < 0 || u >= iw || v < 0 || v >= ih)
				continue;	/* the Limbo path guards this too */
			sp = Pt(src->r.min.x + u, src->r.min.y + v);
			mp = ZP;
			if(mask != nil){
				mp = Pt(mask->r.min.x + (int)((lx+hx)*mw/sw),
					mask->r.min.y + (int)((ly+hy)*mh/sh));
				if(!d3maskset(mask, mp))
					continue;
			}
			p = Pt(x, y);
			if(usez && !d3zpixel(cl, p, eyez))
				continue;
			memdraw(dst, Rect(x, y, x+1, y+1), src, sp,
				mask != nil ? mask : memopaque, mp, op);
		}
}

static void
d3ellipsez(Client *cl, Memimage *dst, Point c, int rx, int ry, int thick,
	int fill, Memimage *src, int op, float eyez)
{
	Rectangle r;
	Point p;
	float dx, dy, d, tol;
	int x, y;

	if(rx < 1 || ry < 1)
		return;
	tol = ((float)thick + 0.75f) / (float)(rx < ry ? rx : ry);
	r = Rect(c.x-rx-thick-1, c.y-ry-thick-1,
		c.x+rx+thick+2, c.y+ry+thick+2);
	if(!rectclip(&r, dst->clipr))
		return;
	for(y = r.min.y; y < r.max.y; y++)
		for(x = r.min.x; x < r.max.x; x++){
			dx = (x+0.5f-c.x)/(float)rx;
			dy = (y+0.5f-c.y)/(float)ry;
			d = sqrtf(dx*dx + dy*dy);
			if((fill && d > 1.0f) || (!fill && (d < 1.0f-tol || d > 1.0f+tol)))
				continue;
			p = Pt(x, y);
			if(!d3zpixel(cl, p, eyez))
				continue;
			memdraw(dst, Rect(x, y, x+1, y+1), src, p, memopaque, p, op);
		}
}

/* Tint a solid 32-bit colour by lighting factor; *tmp owns any replacement. */
static Memimage*
d3applylit(Memimage *src, float lit, Memimage **tmp)
{
	u32 c[4];
	int bpp, i;
	uchar *p;

	*tmp = nil;
	if(src == nil || (lit >= 0.999f && lit <= 1.001f))
		return src;
	/*
	 * 24 as well as 32.  This took only depth 32, and the screen here
	 * is 24, so on this host it returned the colour UNLIT every time
	 * and devdraw's own rasteriser applied no per-face lighting at all.
	 * g3probe(1): a white face came back 255,255,255 at every lit from
	 * 1.0 down to 0.2, where Metal gave 254, 211, 158, 110, 62.  The
	 * Limbo provider had the identical bug, keyed to the identical
	 * constant, and this is why castlefrankenstein(1) looked brighter
	 * on the CPU than on the GPU: the GPU was the one doing it right.
	 *
	 * The channels are scaled where they lie and written back where
	 * they lay, so which of them is red does not come into it.
	 */
	if(!(src->flags & Frepl))
		return src;
	bpp = src->depth / 8;
	if(bpp != 3 && bpp != 4)
		return src;
	p = byteaddr(src, src->r.min);
	if(p == nil)
		return src;
	if(lit < 0.0f)
		lit = 0.0f;
	for(i = 0; i < 3; i++){
		c[i] = (u32)(p[i] * lit);
		if(c[i] > 255)
			c[i] = 255;
	}
	c[3] = bpp == 4 ? p[3] : 0;	/* alpha, if there is one, unscaled */
	*tmp = allocmemimage(Rect(0, 0, 1, 1), src->chan);
	if(*tmp == nil)
		return src;
	(*tmp)->flags |= Frepl;
	(*tmp)->clipr = Rect(-0x3FFFFFF, -0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF);
	p = byteaddr(*tmp, (*tmp)->r.min);
	for(i = 0; i < 3; i++)
		p[i] = (uchar)c[i];
	if(bpp == 4)
		p[3] = (uchar)c[3];
	return *tmp;
}
void
drawmesg(Client *client, void *av, int n)
{
	int c, repl, m, y, dstid, scrnid, ni, ci, j, nw, e0, e1, op, ox, oy, oesize, esize, doflush;
	uchar *u, *a, refresh;
	char *fmt;
	ulong value, chan;
	Rectangle r, clipr;
	Point p, q, *pp, sp;
	Memimage *i, *bg, *dst, *src, *mask;
	Memimage *l, **lp;
	Memscreen *scrn;
	DImage *font, *ll, *di, *ddst, *dsrc;
	DName *dn;
	DScreen *dscrn;
	FChar *fc;
	Refx *refx;
	CScreen *cs;
	Refreshfn reffn;

	a = av;
	m = 0;
	fmt = nil;
	if(waserror()){
		if(fmt) printmesg(fmt, a, 1);
	/*	iprint("error: %s\n", up->errstr);	*/
		nexterror();
	}
	while((n-=m) > 0){
		USED(fmt);
		a += m;
		switch(*a){
		default:
			error("bad draw command");
		/* new allocate: 'b' id[4] screenid[4] refresh[1] chan[4] repl[1] R[4*4] clipR[4*4] rrggbbaa[4] */
		case 'b':
			printmesg(fmt="LLbLbRRL", a, 0);
			m = 1+4+4+1+4+1+4*4+4*4+4;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			scrnid = BG32INT(a+5);
			refresh = a[9];
			chan = BG32INT(a+10);
			repl = a[14];
			drawrectangle(&r, a+15);
			drawrectangle(&clipr, a+31);
			value = BG32INT(a+47);
			if(drawlookup(client, dstid, 0))
				error(Eimageexists);
			if(scrnid){
				dscrn = drawlookupscreen(client, scrnid, &cs);
				scrn = dscrn->screen;
				if(repl || chan!=scrn->image->chan)
					error("image parameters incompatible with screen");
				reffn = nil;
				switch(refresh){
				case Refbackup:
					break;
				case Refnone:
					reffn = memlnorefresh;
					break;
				case Refmesg:
					reffn = drawrefresh;
					break;
				default:
					error("unknown refresh method");
				}
				l = memlalloc(scrn, r, reffn, 0, value);
				if(l == 0)
					error(Edrawmem);
				addflush(l->layer->screenr);
				l->clipr = clipr;
				rectclip(&l->clipr, r);
				if(drawinstall(client, dstid, l, dscrn) == 0){
					memldelete(l);
					error(Edrawmem);
				}
				dscrn->ref++;
				if(reffn){
					refx = nil;
					if(reffn == drawrefresh){
						refx = malloc(sizeof(Refx));
						if(refx == 0){
							drawuninstall(client, dstid);
							error(Edrawmem);
						}
						refx->client = client;
						refx->dimage = drawlookup(client, dstid, 1);
					}
					memlsetrefresh(l, reffn, refx);
				}
				continue;
			}
			i = allocmemimage(r, chan);
			if(i == 0)
				error(Edrawmem);
			if(repl)
				i->flags |= Frepl;
			i->clipr = clipr;
			if(!repl)
				rectclip(&i->clipr, r);
			if(drawinstall(client, dstid, i, 0) == 0){
				freememimage(i);
				error(Edrawmem);
			}
			memfillcolor(i, value);
			continue;

		/* allocate screen: 'A' id[4] imageid[4] fillid[4] public[1] */
		case 'A':
			printmesg(fmt="LLLb", a, 1);
			m = 1+4+4+4+1;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			if(dstid == 0)
				error(Ebadarg);
			if(drawlookupdscreen(dstid))
				error(Escreenexists);
			ddst = drawlookup(client, BG32INT(a+5), 1);
			dsrc = drawlookup(client, BG32INT(a+9), 1);
			if(ddst==0 || dsrc==0)
				error(Enodrawimage);
			if(drawinstallscreen(client, 0, dstid, ddst, dsrc, a[13]) == 0)
				error(Edrawmem);
			continue;

		/* set repl and clip: 'c' dstid[4] repl[1] clipR[4*4] */
		case 'c':
			printmesg(fmt="LbR", a, 0);
			m = 1+4+1+4*4;
			if(n < m)
				error(Eshortdraw);
			ddst = drawlookup(client, BG32INT(a+1), 1);
			if(ddst == nil)
				error(Enodrawimage);
			if(ddst->name)
				error("cannot change repl/clipr of shared image");
			dst = ddst->image;
			if(a[5])
				dst->flags |= Frepl;
			drawrectangle(&dst->clipr, a+6);
			continue;

		/* draw: 'd' dstid[4] srcid[4] maskid[4] R[4*4] P[2*4] P[2*4] */
		case 'd':
			printmesg(fmt="LLLRPP", a, 0);
			m = 1+4+4+4+4*4+2*4+2*4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			dstid = BG32INT(a+1);
			src = drawimage(client, a+5);
			mask = drawimage(client, a+9);
			drawrectangle(&r, a+13);
			drawpoint(&p, a+29);
			drawpoint(&q, a+37);
			op = drawclientop(client);
			drawpre(dstid, dst, fulloverwrite(src, mask, op));
			memdraw(dst, r, src, p, mask, q, op);
			dstflush(dstid, dst, r, fulloverwrite(src, mask, op));
			continue;

		/* toggle debugging: 'D' val[1] */
		case 'D':
			printmesg(fmt="b", a, 0);
			m = 1+1;
			if(n < m)
				error(Eshortdraw);
			continue;

		/* ellipse: 'e' dstid[4] srcid[4] center[2*4] a[4] b[4] thick[4] sp[2*4] alpha[4] phi[4]*/
		case 'e':
		case 'E':
			printmesg(fmt="LLPlllPll", a, 0);
			m = 1+4+4+2*4+4+4+4+2*4+2*4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			dstid = BG32INT(a+1);
			drawpre(dstid, dst, 0);	/* spans or a glyph mask: never a full overwrite */
			src = drawimage(client, a+5);
			drawpoint(&p, a+9);
			e0 = BG32INT(a+17);
			e1 = BG32INT(a+21);
			if(e0<0 || e1<0)
				error("invalid ellipse semidiameter");
			j = BG32INT(a+25);
			if(j < 0)
				error("negative ellipse thickness");
			drawpoint(&sp, a+29);
			c = j;
			if(*a == 'E')
				c = -1;
			ox = BG32INT(a+37);
			oy = BG32INT(a+41);
			op = drawclientop(client);
			/* high bit indicates arc angles are present */
			if(ox & (1<<31)){
				if((ox & (1<<30)) == 0)
					ox &= ~(1<<31);
				memarc(dst, p, e0, e1, c, src, sp, ox, oy, op);
			}else
				memellipse(dst, p, e0, e1, c, src, sp, op);
			dstflush(dstid, dst, Rect(p.x-e0-j, p.y-e1-j, p.x+e0+j+1, p.y+e1+j+1), 0);
			continue;

		/* free: 'f' id[4] */
		case 'f':
			printmesg(fmt="L", a, 1);
			m = 1+4;
			if(n < m)
				error(Eshortdraw);
			ll = drawlookup(client, BG32INT(a+1), 0);
			if(ll && ll->dscreen && ll->dscreen->owner != client)
				ll->dscreen->owner->refreshme = 1;
			drawuninstall(client, BG32INT(a+1));
			continue;

		/* free screen: 'F' id[4] */
		case 'F':
			printmesg(fmt="L", a, 1);
			m = 1+4;
			if(n < m)
				error(Eshortdraw);
			drawlookupscreen(client, BG32INT(a+1), &cs);
			drawuninstallscreen(client, cs);
			continue;

		/* initialize font: 'i' fontid[4] nchars[4] ascent[1] */
		case 'i':
			printmesg(fmt="Llb", a, 1);
			m = 1+4+4+1;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			if(dstid == 0)
				error("cannot use display as font");
			font = drawlookup(client, dstid, 1);
			if(font == 0)
				error(Enodrawimage);
			if(font->image->layer)
				error("cannot use window as font");
			ni = BG32INT(a+5);
			if(ni<=0 || ni>4096)
				error("bad font size (4096 chars max)");
			free(font->fchar);	/* should we complain if non-zero? */
			font->fchar = malloc(ni*sizeof(FChar));
			if(font->fchar == 0)
				error("no memory for font");
			memset(font->fchar, 0, ni*sizeof(FChar));
			font->nfchar = ni;
			font->ascent = a[9];
			continue;

		/* load character: 'l' fontid[4] srcid[4] index[2] R[4*4] P[2*4] left[1] width[1] */
		case 'l':
			printmesg(fmt="LLSRPbb", a, 0);
			m = 1+4+4+2+4*4+2*4+1+1;
			if(n < m)
				error(Eshortdraw);
			font = drawlookup(client, BG32INT(a+1), 1);
			if(font == 0)
				error(Enodrawimage);
			if(font->nfchar == 0)
				error(Enotfont);
			src = drawimage(client, a+5);
			ci = BG16INT(a+9);
			if(ci >= font->nfchar)
				error(Eindex);
			drawrectangle(&r, a+11);
			drawpoint(&p, a+27);
			memdraw(font->image, r, src, p, memopaque, p, S);
			fc = &font->fchar[ci];
			fc->minx = r.min.x;
			fc->maxx = r.max.x;
			fc->miny = r.min.y;
			fc->maxy = r.max.y;
			fc->left = a[35];
			fc->width = a[36];
			continue;

		/* draw line: 'L' dstid[4] p0[2*4] p1[2*4] end0[4] end1[4] radius[4] srcid[4] sp[2*4] */
		case 'L':
			printmesg(fmt="LPPlllLP", a, 0);
			m = 1+4+2*4+2*4+4+4+4+4+2*4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			dstid = BG32INT(a+1);
			drawpoint(&p, a+5);
			drawpoint(&q, a+13);
			e0 = BG32INT(a+21);
			e1 = BG32INT(a+25);
			j = BG32INT(a+29);
			if(j < 0)
				error("negative line width");
			src = drawimage(client, a+33);
			drawpoint(&sp, a+37);
			op = drawclientop(client);
			memline(dst, p, q, e0, e1, j, src, sp, op);
			/* avoid memlinebbox if possible */
			if(dstid==0 || dst->layer!=nil){
			drawpre(dstid, dst, 0);	/* spans or a glyph mask: never a full overwrite */
				/* BUG: this is terribly inefficient: update maximal containing rect*/
				r = memlinebbox(p, q, e0, e1, j);
				dstflush(dstid, dst, insetrect(r, -(1+1+j)), 0);
			}
			continue;

		/* create image mask: 'm' newid[4] id[4] */
/*
 *
		case 'm':
			printmesg("LL", a, 0);
			m = 4+4;
			if(n < m)
				error(Eshortdraw);
			break;
 *
 */

		/* attach to a named image: 'n' dstid[4] j[1] name[j] */
		case 'n':
			printmesg(fmt="Lz", a, 0);
			m = 1+4+1;
			if(n < m)
				error(Eshortdraw);
			j = a[5];
			if(j == 0)	/* give me a non-empty name please */
				error(Eshortdraw);
			m += j;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			if(drawlookup(client, dstid, 0))
				error(Eimageexists);
			dn = drawlookupname(j, (char*)a+6);
			if(dn == nil)
				error(Enoname);
			if(drawinstall(client, dstid, dn->dimage->image, 0) == 0)
				error(Edrawmem);
			di = drawlookup(client, dstid, 0);
			if(di == 0)
				error("draw: cannot happen");
			di->vers = dn->vers;
			di->name = smalloc(j+1);
			di->fromname = dn->dimage;
			di->fromname->ref++;
			memmove(di->name, a+6, j);
			di->name[j] = 0;
			client->infoid = dstid;
			continue;

		/* name an image: 'N' dstid[4] in[1] j[1] name[j] */
		case 'N':
			printmesg(fmt="Lbz", a, 0);
			m = 1+4+1+1;
			if(n < m)
				error(Eshortdraw);
			c = a[5];
			j = a[6];
			if(j == 0)	/* give me a non-empty name please */
				error(Eshortdraw);
			m += j;
			if(n < m)
				error(Eshortdraw);
			di = drawlookup(client, BG32INT(a+1), 0);
			if(di == 0)
				error(Enodrawimage);
			if(di->name)
				error(Enamed);
			if(c)
				drawaddname(client, di, j, (char*)a+7);
			else{
				dn = drawlookupname(j, (char*)a+7);
				if(dn == nil)
					error(Enoname);
				if(dn->dimage != di)
					error(Ewrongname);
				drawdelname(dn);
			}
			continue;

		/* position window: 'o' id[4] r.min [2*4] screenr.min [2*4] */
		case 'o':
			printmesg(fmt="LPP", a, 0);
			m = 1+4+2*4+2*4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			if(dst->layer){
				drawpoint(&p, a+5);
				drawpoint(&q, a+13);
				r = dst->layer->screenr;
				ni = memlorigin(dst, p, q);
				if(ni < 0)
					error("image origin failed");
				if(ni > 0){
					addflush(r);
					addflush(dst->layer->screenr);
					ll = drawlookup(client, BG32INT(a+1), 1);
					drawrefreshscreen(ll, client);
				}
			}
			continue;

		/* set compositing operator for next draw operation: 'O' op */
		case 'O':
			printmesg(fmt="b", a, 0);
			m = 1+1;
			if(n < m)
				error(Eshortdraw);
			client->op = a[1];
			continue;

		/* filled polygon: 'P' dstid[4] n[2] wind[4] ignore[2*4] srcid[4] sp[2*4] p0[2*4] dp[2*2*n] */
		/* polygon: 'p' dstid[4] n[2] end0[4] end1[4] radius[4] srcid[4] sp[2*4] p0[2*4] dp[2*2*n] */
		case 'p':
		case 'P':
			printmesg(fmt="LslllLPP", a, 0);
			m = 1+4+2+4+4+4+4+2*4;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			dst = drawimage(client, a+1);
			ni = BG16INT(a+5);
			if(ni < 0)
				error("negative count in polygon");
			e0 = BG32INT(a+7);
			e1 = BG32INT(a+11);
			j = 0;
			if(*a == 'p'){
				j = BG32INT(a+15);
				if(j < 0)
					error("negative polygon line width");
			}
			src = drawimage(client, a+19);
			drawpoint(&sp, a+23);
			drawpoint(&p, a+31);
			ni++;
			pp = malloc(ni*sizeof(Point));
			if(pp == nil)
				error(Enomem);
			drawpre(dstid, dst, 0);	/* spans only: never a full overwrite */
			doflush = 0;
			if(dstid==0 || (screenimage && dst->layer && dst->layer->screen->image->data == screenimage->data))
				doflush = 1;	/* simplify test in loop */
			ox = oy = 0;
			esize = 0;
			u = a+m;
			for(y=0; y<ni; y++){
				q = p;
				oesize = esize;
				u = drawcoord(u, a+n, ox, &p.x);
				u = drawcoord(u, a+n, oy, &p.y);
				ox = p.x;
				oy = p.y;
				if(doflush){
					esize = j;
					if(*a == 'p'){
						if(y == 0){
							c = memlineendsize(e0);
							if(c > esize)
								esize = c;
						}
						if(y == ni-1){
							c = memlineendsize(e1);
							if(c > esize)
								esize = c;
						}
					}
					if(*a=='P' && e0!=1 && e0 !=~0)
						r = dst->clipr;
					else if(y > 0){
						r = Rect(q.x-oesize, q.y-oesize, q.x+oesize+1, q.y+oesize+1);
						combinerect(&r, Rect(p.x-esize, p.y-esize, p.x+esize+1, p.y+esize+1));
					}
					if(rectclip(&r, dst->clipr))		/* should perhaps be an arg to dstflush */
						dstflush(dstid, dst, r, 0);
				}
				pp[y] = p;
			}
			if(y == 1)
				dstflush(dstid, dst, Rect(p.x-esize, p.y-esize, p.x+esize+1, p.y+esize+1), 0);
			op = drawclientop(client);
			if(*a == 'p')
				mempoly(dst, pp, ni, e0, e1, j, src, sp, op);
			else
				memfillpoly(dst, pp, ni, e0, src, sp, op);
			free(pp);
			m = u-a;
			continue;

		/* read: 'r' id[4] R[4*4] */
		case 'r':
			printmesg(fmt="LR", a, 0);
			m = 1+4+4*4;
			if(n < m)
				error(Eshortdraw);
			i = drawimage(client, a+1);
			drawrectangle(&r, a+5);
			if(!rectinrect(r, i->r))
				error(Ereadoutside);
			c = bytesperline(r, i->depth);
			c *= Dy(r);
			free(client->readdata);
			client->readdata = mallocz(c, 0);
			if(client->readdata == nil)
				error("readimage malloc failed");
			/*
			 * A READ DEPENDS ON WHAT THE BUFFER ALREADY HOLDS, which
			 * is the same dependency a partial-overwrite operation
			 * has, so it takes the same hook.
			 *
			 * Without this the deferred scheme breaks every
			 * readback.  After a present the buffer memunload()
			 * reads is the BACK buffer, which by design holds the
			 * frame BEFORE the one just presented -- the repair is
			 * deferred until the next frame draws.  So draw, flush,
			 * read back returns the previous frame's pixels.
			 * Measured: with the flip on and this missing, drawink
			 * failed 5 of 6 checks -- "box inside 0 of 75684
			 * pixels inked" with "box outside" still passing, which
			 * is the signature of reading a buffer nothing was
			 * drawn into rather than of drawing nothing.
			 */
			drawpre(BG32INT(a+1), i, 0);
			client->nreaddata = memunload(i, r, client->readdata, c);
			if(client->nreaddata < 0){
				free(client->readdata);
				client->readdata = nil;
				error("bad readimage call");
			}
			continue;

		/* string: 's' dstid[4] srcid[4] fontid[4] P[2*4] clipr[4*4] sp[2*4] ni[2] ni*(index[2]) */
		/* stringbg: 'x' dstid[4] srcid[4] fontid[4] P[2*4] clipr[4*4] sp[2*4] ni[2] bgid[4] bgpt[2*4] ni*(index[2]) */
		case 's':
		case 'x':
			printmesg(fmt="LLLPRPs", a, 0);
			m = 1+4+4+4+2*4+4*4+2*4+2;
			if(*a == 'x')
				m += 4+2*4;
			if(n < m)
				error(Eshortdraw);

			dst = drawimage(client, a+1);
			dstid = BG32INT(a+1);
			drawpre(dstid, dst, 0);	/* spans or a glyph mask: never a full overwrite */
			src = drawimage(client, a+5);
			font = drawlookup(client, BG32INT(a+9), 1);
			if(font == 0)
				error(Enodrawimage);
			if(font->nfchar == 0)
				error(Enotfont);
			drawpoint(&p, a+13);
			drawrectangle(&r, a+21);
			drawpoint(&sp, a+37);
			ni = BG16INT(a+45);
			u = a+m;
			m += ni*2;
			if(n < m)
				error(Eshortdraw);
			clipr = dst->clipr;
			dst->clipr = r;
			op = drawclientop(client);
			bg = dst;
			if(*a == 'x'){
				/* paint background */
				bg = drawimage(client, a+47);
				drawpoint(&q, a+51);
				r.min.x = p.x;
				r.min.y = p.y-font->ascent;
				r.max.x = p.x;
				r.max.y = r.min.y+Dy(font->image->r);
				j = ni;
				while(--j >= 0){
					ci = BG16INT(u);
					if(ci<0 || ci>=font->nfchar){
						dst->clipr = clipr;
						error(Eindex);
					}
					r.max.x += font->fchar[ci].width;
					u += 2;
				}
				memdraw(dst, r, bg, q, memopaque, ZP, op);
				u -= 2*ni;
			}
			q = p;
			while(--ni >= 0){
				ci = BG16INT(u);
				if(ci<0 || ci>=font->nfchar){
					dst->clipr = clipr;
					error(Eindex);
				}
				q = drawchar(dst, bg, q, src, &sp, font, ci, op);
				u += 2;
			}
			dst->clipr = clipr;
			p.y -= font->ascent;
			dstflush(dstid, dst, Rect(p.x, p.y, q.x, p.y+Dy(font->image->r)), 0);
			continue;

		/* use public screen: 'S' id[4] chan[4] */
		case 'S':
			printmesg(fmt="Ll", a, 0);
			m = 1+4+4;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			if(dstid == 0)
				error(Ebadarg);
			dscrn = drawlookupdscreen(dstid);
			if(dscrn==0 || (dscrn->public==0 && dscrn->owner!=client))
				error(Enodrawscreen);
			if(dscrn->screen->image->chan != BG32INT(a+5))
				error("inconsistent chan");
			if(drawinstallscreen(client, dscrn, 0, 0, 0, 0) == 0)
				error(Edrawmem);
			continue;

		/* top or bottom windows: 't' top[1] nw[2] n*id[4] */
		case 't':
			printmesg(fmt="bsL", a, 0);
			m = 1+1+2;
			if(n < m)
				error(Eshortdraw);
			nw = BG16INT(a+2);
			if(nw < 0)
				error(Ebadarg);
			if(nw == 0)
				continue;
			m += nw*4;
			if(n < m)
				error(Eshortdraw);
			lp = malloc(nw*sizeof(Memimage*));
			if(lp == 0)
				error(Enomem);
			if(waserror()){
				free(lp);
				nexterror();
			}
			for(j=0; j<nw; j++){
				lp[j] = drawimage(client, a+1+1+2+j*4);
				if(lp[j]->layer == 0)
					error("images are not windows");
				if(lp[j]->layer->screen != lp[0]->layer->screen)
					error("images not on same screen");
			}
			if(a[1])
				memltofrontn(lp, nw);
			else
				memltorearn(lp, nw);
			if(screenimage && lp[0]->layer->screen->image->data == screenimage->data)
				for(j=0; j<nw; j++)
					addflush(lp[j]->layer->screenr);
			ll = drawlookup(client, BG32INT(a+1+1+2), 1);
			drawrefreshscreen(ll, client);
			poperror();
			free(lp);
			continue;

		/* visible: 'v' */
		case 'v':
			printmesg(fmt="", a, 0);
			m = 1;
			drawflush();
			drawpresent();	/* the client declared a frame; H1a */
			continue;

		/* write: 'y' id[4] R[4*4] data[x*1] */
		/* write from compressed data: 'Y' id[4] R[4*4] data[x*1] */
		case '3':
			printmesg(fmt="", a, 0);
			m = 1;
			continue;

		case 'C':	/* explicit draw3d capabilities: C dstid[4] */
			printmesg(fmt="L", a, 0);
			m = 1+4;
			if(n < m)
				error(Eshortdraw);
			i = drawimage(client, a+1);
			if(i->depth != 32 || Dx(i->r) < 1 || Dy(i->r) < 1)
				error(Ebadarg);
			value = D3CapMatrix | D3CapFill | D3CapLine | D3CapPlot
				| D3CapSprite | D3CapEllipse | D3CapNearClip | D3CapDepthOrder
				| D3CapGouraud;
			if(gpudrawfillpoly != nil)
				value |= D3CapGPU;
			if(gpudrawreadback != nil)
				value |= D3CapReadback;
			/*
			 * Only when a GPU can actually take it.  With no GPU
			 * the message would be a slower route to the same C
			 * loop, and the Limbo caller's own resampler is the
			 * one every sprite2dtest(1) case was written against.
			 */
			if(gpudrawsprite2d != nil)
				value |= D3CapSprite2d;
			u = byteaddr(i, i->r.min);
			u[0] = value;
			u[1] = value>>8;
			u[2] = value>>16;
			u[3] = value>>24;
			continue;

		case 'M':
			printmesg(fmt="b", a, 0);
			m = 1+1+16*4;
			if(n < m)
				error(Eshortdraw);
			if(a[1] == 0)
				d3loadmat(client->d3model, a+2);
			else if(a[1] == 1)
				d3loadmat(client->d3proj, a+2);
			else
				error(Ebadarg);
			continue;

		case 'w':
			printmesg(fmt="", a, 0);
			m = 1+4*4;
			if(n < m)
				error(Eshortdraw);
			client->d3mx = bgfloat(a+1);
			client->d3cx = bgfloat(a+5);
			client->d3my = bgfloat(a+9);
			client->d3cy = bgfloat(a+13);
			continue;

		case 'u':
			printmesg(fmt="b", a, 0);
			m = 1+1;
			if(n < m)
				error(Eshortdraw);
			client->d3zenable = a[1] & 1;
			client->d3clipbehind = (a[1] & 2) != 0;
			if(gpudrawzenable)
				gpudrawzenable(client->d3zenable);
			continue;

		case 'z':
			printmesg(fmt="L", a, 0);
			m = 1+4;
			if(n < m)
				error(Eshortdraw);
			dst = drawimage(client, a+1);
			d3clearz(client, dst);
			if(gpudrawzclear)
				gpudrawzclear();
			continue;

		case 'g':	/* fillpoly3 (compat) */
		case 'k':	/* fillpoly3 + normal + lit */
			printmesg(fmt="LLS", a, 0);
			m = 1+4+4+2;
			if(*a == 'k')
				m += 4*4;	/* nx ny nz lit */
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);
			nw = BG16INT(a+9);
			if(nw < 3 || nw > 1024)
				error(Ebadarg);
			{
				int hdr;
				float nx, ny, nz, lit;
				float *vx, *vy, *vz, *ix, *iy, *iz;
				Memimage *lsrc, *ltmp;
				int pdx, pdy, pdc, haveplane, gpudone;

				hdr = 11;
				nx = ny = 0.0f;
				nz = 1.0f;
				lit = 1.0f;
				ltmp = nil;
				lsrc = nil;
				if(*a == 'k'){
					nx = bgfloat(a+11);
					ny = bgfloat(a+15);
					nz = bgfloat(a+19);
					lit = bgfloat(a+23);
					hdr = 27;
				}
				m = hdr + nw * 3 * 4;
				if(n < m)
					error(Eshortdraw);
				pp = malloc(sizeof(Point) * (nw + 2));
				if(pp == nil)
					error(Edrawmem);
				if(waserror()){
					free(pp);
					nexterror();
				}
				vx = malloc(sizeof(float) * (nw + 1) * 6);
				if(vx == nil){
					poperror();
					free(pp);
					error(Edrawmem);
				}
				vy = vx + nw + 1;
				vz = vy + nw + 1;
				ix = vz + nw + 1;
				iy = ix + nw + 1;
				iz = iy + nw + 1;
				if(waserror()){
					free(vx);
					nexterror();
				}
				{
					float *ezs, ez;

					ezs = malloc(sizeof(float) * (nw + 1));
					if(ezs == nil){
						poperror();
						free(vx);
						poperror();
						free(pp);
						error(Edrawmem);
					}
					if(waserror()){
						free(ezs);
						nexterror();
					}
					for(j = 0; j < nw; j++){
						float fx, fy, fz;

						fx = bgfloat(a+hdr + j*12);
						fy = bgfloat(a+hdr + j*12 + 4);
						fz = bgfloat(a+hdr + j*12 + 8);
						ix[j] = fx;
						iy[j] = fy;
						iz[j] = fz;
					}
					nw = d3clipnear(client, ix, iy, iz, nw, vx, vy, vz);
					if(nw < 3){
						poperror();
						free(ezs);
						poperror();
						free(vx);
						poperror();
						free(pp);
						goto gdone;
					}
					op = drawclientop(client);
					/*
					 * GPU-T&L: hand the raw clipped world verts straight to
					 * Metal and let vgmain do model*proj+viewport - skips
					 * this whole function's per-vertex d3project() loop
					 * *and* the plane-fit below (d3planecoeffs/
					 * d3planefromeyez only exist because the old
					 * screen-space GPU/software paths interpolate depth
					 * linearly across the triangle; true hardware
					 * perspective-correct interpolation of a real eye-z
					 * needs no such approximation).
					 */
					if(gpudrawfillpoly3d != nil && gpudrawfillpoly3d(dst,
					    vx, vy, vz, nw, src, op, lit, client->d3model,
					    client->d3proj, client->d3mx, client->d3cx,
					    client->d3my, client->d3cy)){
						poperror();
						free(ezs);
						poperror();
						free(vx);
						poperror();
						free(pp);
						goto gdone;
					}
					for(j = 0; j < nw; j++){
						if(!d3project(client, vx[j], vy[j], vz[j], &pp[j], &ez)){
							poperror();
							free(ezs);
							poperror();
							free(vx);
							poperror();
							free(pp);
							goto gdone;
						}
						ezs[j] = ez;
					}
					pp[nw] = pp[0];
					haveplane = 0;
					pdx = pdy = pdc = 0;
					if(client->d3zenable){
						if(*a == 'k' && nz != 0.0f && d3modelisident(client))
							haveplane = d3planecoeffs(client, nx, ny, nz,
								vx, vy, vz, nw, &pdx, &pdy, &pdc);
						if(!haveplane)
							haveplane = d3planefromeyez(pp, ezs, nw,
								&pdx, &pdy, &pdc);
						/* Plane z → eye-like for Metal sort-only depth map. */
						if(haveplane){
							for(j = 0; j < nw; j++){
								float pz;

								pz = ((float)pdc + (float)pdx*(float)pp[j].x
									+ (float)pdy*(float)pp[j].y)
									/ (float)D3ZSCALE;
								/* Map plane z → eye-like: closer ⇒ more negative. */
								ezs[j] = -pz;
							}
						}
					}
					gpudone = 0;
					if(gpudrawfillpoly != nil)
						gpudone = gpudrawfillpoly(dst, pp, ezs, nw, src, op, lit);
					if(!gpudone){
						lsrc = d3applylit(src, lit, &ltmp);
						if(waserror()){
							if(ltmp)
								freememimage(ltmp);
							nexterror();
						}
						if(client->d3zenable && haveplane)
							d3fillpolyz(client, dst, pp, nw, lsrc, op, pdc, pdx, pdy);
						else
							memfillpoly(dst, pp, nw+1, ~0, lsrc, pp[0], op);
						poperror();
						if(ltmp)
							freememimage(ltmp);
					}
					poperror();
					free(ezs);
				}
				/* flush bbox of projected verts */
				r = dst->clipr;
				if(nw > 0){
					p = pp[0];
					r.min = p;
					r.max = p;
					for(j = 1; j < nw; j++){
						if(pp[j].x < r.min.x) r.min.x = pp[j].x;
						if(pp[j].y < r.min.y) r.min.y = pp[j].y;
						if(pp[j].x > r.max.x) r.max.x = pp[j].x;
						if(pp[j].y > r.max.y) r.max.y = pp[j].y;
					}
					r.max.x++;
					r.max.y++;
				}
				/*
				 * THE FOURTH ARGUMENT IS 0 FOR EVERY draw3d
				 * OPERATION, and it is a classification rather
				 * than a request.
				 *
				 * These nine call sites arrived from rio-pi-tk,
				 * where dstflush() takes three arguments; here
				 * it takes a `full' flag as well.  The two
				 * branches had changed the same function in
				 * different ways, and git merged the texts
				 * WITHOUT A CONFLICT -- the definition from one
				 * side, the calls from the other -- so nothing
				 * was reported until 7c counted the arguments.
				 *
				 * `full' reaches only chargeop(), which
				 * classifies the operation as a whole-rectangle
				 * overwrite or a partial one for the page-flip
				 * damage accounting.  It changes no pixels and
				 * no flush.  Every draw3d primitive -- the
				 * polygons here, line3, plot3, the sprite3
				 * family, the immediate-mode ellipse -- paints
				 * a SUBSET of its bounding rectangle, so
				 * partial is the true answer for all of them
				 * and 0 is what they get.
				 *
				 * Getting it wrong would not draw a wrong
				 * picture; it would make nopfull and
				 * noppartial lie about which scheme the frame
				 * used, which is the thing those counters exist
				 * to answer.
				 */
				dstflush(dstid, dst, r, 0);
				poperror();
				free(vx);
				poperror();
				free(pp);
			}
		gdone:
			continue;

		case 'K':	/* fillpoly3 gouraud: dstid srcid n[2] lit[n*4] xyz[n*12] */
			printmesg(fmt="LLS", a, 0);
			m = 1+4+4+2;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);
			nw = BG16INT(a+9);
			if(nw < 3 || nw > 1024)
				error(Ebadarg);
			m = 11 + nw*4 + nw*12;
			if(n < m)
				error(Eshortdraw);
			{
				float *vx, *vy, *vz, *lits;
				float avglit;

				vx = malloc(sizeof(float) * nw * 4);
				if(vx == nil)
					error(Edrawmem);
				vy = vx + nw;
				vz = vy + nw;
				lits = vz + nw;
				if(waserror()){
					free(vx);
					nexterror();
				}
				avglit = 0.0f;
				for(j = 0; j < nw; j++){
					lits[j] = bgfloat(a + 11 + j*4);
					avglit += lits[j];
				}
				avglit /= (float)nw;
				for(j = 0; j < nw; j++){
					vx[j] = bgfloat(a + 11 + nw*4 + j*12);
					vy[j] = bgfloat(a + 11 + nw*4 + j*12 + 4);
					vz[j] = bgfloat(a + 11 + nw*4 + j*12 + 8);
				}
				op = drawclientop(client);
				/*
				 * Real per-vertex Gouraud: hand raw model-space verts +
				 * per-vertex lits straight to whichever GPU hook this
				 * backend has wired (nil on any backend that hasn't -
				 * same nullable-hook convention as gpudrawfillpoly3d/
				 * gpudrawline/etc). Only Cocoa/Metal (win-cocoa.m) hooks
				 * this today, but nothing here is Metal-specific: a
				 * future OpenGL/Vulkan/Direct3D backend wires its own
				 * queue function to gpudrawfillpoly3g the same way, and
				 * any rasterizer with standard perspective-correct
				 * varying interpolation (the normal case for all of
				 * those) gets Gouraud for free from one colour per
				 * vertex, same as Metal's vgmain/fgmain do here.
				 */
				/*
				 * Only if every vertex is in front of the eye.
				 *
				 * A polygon straddling the eye plane has a vertex with
				 * w <= 0 after projection; interpolated across the
				 * triangle that wraps, and the GPU paints an enormous
				 * wrong face instead of the sliver that should be
				 * visible.  g3probe(1): a wall running through the eye
				 * lights 40596 pixels through the software provider
				 * and 185898 through Metal, four and a half times as
				 * many, where the same wall entirely in front of the
				 * eye agrees to within 1%.
				 *
				 * That is gorge(1)'s wrong picture: it flies a canyon
				 * THROUGH the eye, so some faces straddle the plane
				 * every frame, and they came out as the big flat
				 * shapes that swallowed the rest of the scene.
				 *
				 * The right answer is to clip against the near plane
				 * and hand the GPU the piece that is in front.  Until
				 * something does that, decline - the hook is nullable
				 * by convention and declining puts the polygon on the
				 * CPU path, which rejects it exactly as the software
				 * provider does, so the two agree.
				 */
				{
					Point pdrop;
					float ezdrop;
					int infront, nc, gn;
					float cvx[D3CLIPMAX+1], cvy[D3CLIPMAX+1];
					float cvz[D3CLIPMAX+1], cvl[D3CLIPMAX+1];
					float *gx, *gy, *gz, *gl;

					infront = 1;
					for(j = 0; j < nw; j++)
						if(!d3project(client, vx[j], vy[j], vz[j],
						    &pdrop, &ezdrop)){
							infront = 0;
							break;
						}
					gx = vx; gy = vy; gz = vz; gl = lits; gn = nw;
					if(!infront && nw <= D3CLIPMAX){
						/*
						 * Straddles the eye plane.  Clip it and
						 * give the GPU the part in front, the way
						 * the flat path has always done - rather
						 * than the whole thing, which wraps, or
						 * nothing, which puts the nearest and
						 * largest faces back on the CPU.
						 */
						nc = d3clipnearlit(client, vx, vy, vz, lits,
							nw, cvx, cvy, cvz, cvl);
						if(nc >= 3){
							gx = cvx; gy = cvy; gz = cvz;
							gl = cvl; gn = nc;
							infront = 1;
						}
					}
					if(infront && gpudrawfillpoly3g != nil
					&& gpudrawfillpoly3g(dst, gx, gy, gz, gl, gn,
					    src, op, client->d3model, client->d3proj,
					    client->d3mx, client->d3cx, client->d3my,
					    client->d3cy)){
						poperror();
						free(vx);
						goto Kdone;
					}
				}
				/*
				 * No GPU hook wired (or it declined): degrade to a single
				 * flat fill at the average of the per-vertex lits rather
				 * than a from-scratch native Gouraud rasterizer -
				 * deliberately out of scope for this primitive's first
				 * cut. This is the portable path every backend gets
				 * today (X11, a plain framebuffer, etc.) until it grows
				 * its own gpudrawfillpoly3g hook.
				 *
				 * It IS depth-buffered, as 'k''s CPU fallback is.  It
				 * used to say "no z-buffer here either" and mean it,
				 * and that was not a shading approximation but a
				 * missing depth test: g3probe(1)'s occlusion case with
				 * INFERNO_NOGPU=1 - a near green quad and a far red one
				 * drawn in both orders - gave 527 green pixels one way
				 * round and 0 the other, which is painter's order, not
				 * a depth buffer.  The near quad vanished entirely
				 * behind the far one.  Both orders give 594 now, which
				 * is what the software provider and Metal both give.
				 */
				{
					Point *pp2;
					float *ezs2;
					Memimage *lsrc, *ltmp;
					int pdx2, pdy2, pdc2;

					pp2 = malloc(sizeof(Point) * (nw+1)
						+ sizeof(float) * nw);
					if(pp2 == nil)
						error(Edrawmem);
					ezs2 = (float*)(pp2 + nw + 1);
					if(waserror()){
						free(pp2);
						nexterror();
					}
					for(j = 0; j < nw; j++){
						float ez;

						if(!d3project(client, vx[j], vy[j], vz[j], &pp2[j], &ez)){
							/*
							 * BOTH handlers, not one.  This popped
							 * pp2's and jumped, leaving vx's waserror
							 * on the error stack and vx itself leaked.
							 * An unbalanced error stack does not fail
							 * here; it fails later, as "panic: pushrun
							 * addrun" when the next unwind lands on a
							 * frame that has been reused.
							 *
							 * Only a client whose geometry crosses the
							 * near plane ever reaches this, which is
							 * why it looked like "the device provider
							 * panics under wm": under wm the GPU hook
							 * declines, this fallback runs, and gorge
							 * flies a canyon straight through the eye.
							 */
							poperror();
							free(pp2);
							poperror();
							free(vx);
							goto Kdone;
						}
						ezs2[j] = ez;
					}
					pp2[nw] = pp2[0];
					ltmp = nil;
					lsrc = d3applylit(src, avglit, &ltmp);
					if(waserror()){
						if(ltmp)
							freememimage(ltmp);
						nexterror();
					}
					if(client->d3zenable
					&& d3planefromeyez(pp2, ezs2, nw, &pdx2, &pdy2, &pdc2))
						d3fillpolyz(client, dst, pp2, nw, lsrc, op,
							pdc2, pdx2, pdy2);
					else
						memfillpoly(dst, pp2, nw+1, ~0, lsrc, pp2[0], op);
					poperror();
					if(ltmp)
						freememimage(ltmp);
					r = dst->clipr;
					p = pp2[0];
					r.min = p;
					r.max = p;
					for(j = 1; j < nw; j++){
						if(pp2[j].x < r.min.x) r.min.x = pp2[j].x;
						if(pp2[j].y < r.min.y) r.min.y = pp2[j].y;
						if(pp2[j].x > r.max.x) r.max.x = pp2[j].x;
						if(pp2[j].y > r.max.y) r.max.y = pp2[j].y;
					}
					r.max.x++;
					r.max.y++;
					dstflush(dstid, dst, r, 0);
					poperror();
					free(pp2);
				}
				poperror();
				free(vx);
			}
		Kdone:
			continue;

		case 'G':	/* line3 */
			printmesg(fmt="LLl", a, 0);
			m = 1+4+4+4+6*4;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);
			j = BG32INT(a+9);	/* thick */
			if(j < 0)
				error("negative line width");
			{
				float ax, ay, az, bx, by, bz, eza, ezb;
				Point pa, pb;
				int gpudone;

				ax = bgfloat(a+13);
				ay = bgfloat(a+17);
				az = bgfloat(a+21);
				bx = bgfloat(a+25);
				by = bgfloat(a+29);
				bz = bgfloat(a+33);
				if(!d3projectline(client, ax, ay, az, bx, by, bz,
				    &pa, &pb, &eza, &ezb))
					continue;
				op = drawclientop(client);
				gpudone = 0;
				if(gpudrawline != nil)
					gpudone = gpudrawline(dst, pa, pb, j, src, op, eza, ezb);
				if(!gpudone)
					d3linez(client, dst, pa, pb, j, src, op, eza, ezb);
				if(dst == screenimage || dst->layer != nil){
					r = memlinebbox(pa, pb, Endsquare, Endsquare, j);
					dstflush(dstid, dst, insetrect(r, -(1+1+j)), 0);
				}
			}
			continue;

		case 'h':	/* plot3 */
			printmesg(fmt="LL", a, 0);
			m = 1+4+4+3*4;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);
			{
				float fx, fy, fz, ez;
				Point pa;
				int gpudone, zk;

				fx = bgfloat(a+9);
				fy = bgfloat(a+13);
				fz = bgfloat(a+17);
				if(!d3project(client, fx, fy, fz, &pa, &ez))
					continue;
				op = drawclientop(client);
				gpudone = 0;
				if(gpudrawplot != nil)
					gpudone = gpudrawplot(dst, pa, src, op, ez);
				if(!gpudone){
					if(client->d3zenable && client->d3zbuf != nil
					&& ptinrect(pa, client->d3zr)){
						zk = (pa.y - client->d3zr.min.y)*client->d3zw
							+ (pa.x - client->d3zr.min.x);
						if(zk >= 0 && zk < client->d3zw*client->d3zh){
							int z;

							z = (int)((-ez) * (float)D3ZSCALE);
							if(z < client->d3zbuf[zk]){
								client->d3zbuf[zk] = z;
								memdraw(dst, Rect(pa.x, pa.y, pa.x+1, pa.y+1),
									src, ZP, memopaque, ZP, op);
							}
						}else
							memdraw(dst, Rect(pa.x, pa.y, pa.x+1, pa.y+1),
								src, ZP, memopaque, ZP, op);
					}else
						memdraw(dst, Rect(pa.x, pa.y, pa.x+1, pa.y+1),
							src, ZP, memopaque, ZP, op);
				}
				dstflush(dstid, dst, Rect(pa.x, pa.y, pa.x+1, pa.y+1), 0);
			}
			continue;

		case 'j':	/* sprite3 family */
			printmesg(fmt="LLLb", a, 0);
			m = 1+4+4+4+1+4+4+3*4;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);	/* img */
			{
				u32 maskid;
				int flags, gpudone;
				float scale, degz, fx, fy, fz, ez, sc;
				Point sp;
				Memimage *mask;
				Rectangle dr;
				int iw, ih, sw, sh;
				float mat[16];
				float qx, qy, qz;
				DImage *dmask;

				maskid = BG32INT(a+9);
				flags = a[13];
				scale = bgfloat(a+14);
				degz = bgfloat(a+18);
				fx = bgfloat(a+22);
				fy = bgfloat(a+26);
				fz = bgfloat(a+30);
				mask = nil;
				if((flags & 1) && maskid != 0){
					dmask = drawlookup(client, (int)maskid, 1);
					if(dmask != nil)
						mask = dmask->image;
				}
				if(flags & 8){	/* sprite3mat: matrix then origin at p */
					m = 1+4+4+4+1+4+4+3*4+16*4;
					if(n < m)
						error(Eshortdraw);
					d3loadmat(mat, a+34);
					d3mulpoint(mat, 0, 0, 0, &qx, &qy, &qz);
					fx += qx;
					fy += qy;
					fz += qz;
				}
				if(!d3project(client, fx, fy, fz, &sp, &ez))
					continue;
				iw = Dx(src->r);
				ih = Dy(src->r);
				sc = 1.0f;
				if(scale > 0.0f && ez < 0.0f)
					sc = scale / (-ez);
				else if(ez < 0.0f)
					sc = 1.0f / (-ez);
				sw = (int)((float)iw * sc);
				sh = (int)((float)ih * sc);
				if(flags & 4)
					sh = (int)((float)sh * 0.85f);
				if(sw < 1) sw = 1;
				if(sh < 1) sh = 1;
				op = drawclientop(client);
				gpudone = 0;
				if(gpudrawsprite != nil)
					gpudone = gpudrawsprite(dst, sp, sw, sh, ez, src, mask, degz, op);
				if(!gpudone){
					d3spritez(client, dst, sp, sw, sh, ez, src, mask, degz, 0, 1, op);
					dr = Rect(sp.x - sw, sp.y - sh, sp.x + sw + 1, sp.y + sh + 1);
					dstflush(dstid, dst, dr, 0);
				}else
					dstflush(dstid, dst, Rect(sp.x - sw/2, sp.y - sh/2,
						sp.x - sw/2 + sw, sp.y - sh/2 + sh), 0);
			}
			continue;

		/*
		 * sprite2d: 'J' id[4] imgid[4] maskid[4] flags[1] cx[4] cy[4]
		 *           w[4] h[4] degz[4]
		 *
		 * Screen space, no projection and no depth - the 2D half of
		 * draw3d, and the one appl/temple actually leans on.  It is a
		 * separate message from 'j' rather than a flag on it because
		 * 'j' carries a WORLD point and a scale and lets the device
		 * project; a 2D sprite has neither, and giving it a fake world
		 * point would put the current matrices in the way of a call
		 * that has nothing to do with them.
		 *
		 * flags: bit0 a mask follows in maskid, bit1 mirror in x.
		 */
		case 'J':
			printmesg(fmt="LLLb", a, 0);
			m = 1+4+4+4+1+4+4+4+4+4;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);
			{
				u32 maskid;
				int flags, gpudone, sw, sh, flipx;
				float degz;
				Point sp;
				Memimage *mask;
				DImage *dmask;

				maskid = BG32INT(a+9);
				flags = a[13];
				sp.x = BG32INT(a+14);
				sp.y = BG32INT(a+18);
				sw = BG32INT(a+22);
				sh = BG32INT(a+26);
				degz = bgfloat(a+30);
				flipx = (flags & 2) != 0;
				if(sw < 1 || sh < 1)
					continue;
				mask = nil;
				if((flags & 1) && maskid != 0){
					dmask = drawlookup(client, (int)maskid, 1);
					if(dmask != nil)
						mask = dmask->image;
				}
				op = drawclientop(client);
				gpudone = 0;
				if(gpudrawsprite2d != nil)
					gpudone = gpudrawsprite2d(dst, sp, sw, sh, src,
						mask, degz, flipx, op);
				if(!gpudone){
					/*
					 * eyez is unused with usez 0; the box is the
					 * rotated extent, which is why it is not just
					 * sw x sh.
					 */
					d3spritez(client, dst, sp, sw, sh, 0.0f, src,
						mask, degz, flipx, 0, op);
					dstflush(dstid, dst, Rect(sp.x - sw - sh, sp.y - sw - sh,
						sp.x + sw + sh + 1, sp.y + sw + sh + 1), 0);
				}else
					dstflush(dstid, dst, Rect(sp.x - sw - sh, sp.y - sw - sh,
						sp.x + sw + sh + 1, sp.y + sw + sh + 1), 0);
			}
			continue;

		case 'q':	/* circle/ellipse (immediate mode) */
			printmesg(fmt="LLb", a, 0);
			m = 1+4+4+1+4+3*4+4+4;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			dst = drawimage(client, a+1);
			src = drawimage(client, a+5);
			{
				int flags, thick, rx, ry, gpudone, fill;
				float fx, fy, fz, ez;
				Point pa;

				flags = a[9];
				thick = BG32INT(a+10);
				if(thick < 0)
					error("negative ellipse thickness");
				fx = bgfloat(a+14);
				fy = bgfloat(a+18);
				fz = bgfloat(a+22);
				rx = (int)bgfloat(a+26);
				ry = (int)bgfloat(a+30);
				if(rx < 0) rx = -rx;
				if(ry < 0) ry = -ry;
				if(!d3project(client, fx, fy, fz, &pa, &ez))
					continue;
				fill = flags & 1;
				op = drawclientop(client);
				gpudone = 0;
				if(gpudrawellipse != nil)
					gpudone = gpudrawellipse(dst, pa, rx, ry, thick, fill, src, op, ez);
				if(!gpudone)
					d3ellipsez(client, dst, pa, rx, ry, thick, fill, src, op, ez);
				dstflush(dstid, dst, Rect(pa.x - rx - thick - 1, pa.y - ry - thick - 1,
					pa.x + rx + thick + 2, pa.y + ry + thick + 2), 0);
			}
			continue;

		/* write: 'y' id[4] R[4*4] data[x*1] */
		/* write from compressed data: 'Y' id[4] R[4*4] data[x*1] */
		case 'y':
		case 'Y':
			printmesg(fmt="LR", a, 0);
		//	iprint("load %c\n", *a);
			m = 1+4+4*4;
			if(n < m)
				error(Eshortdraw);
			dstid = BG32INT(a+1);
			dst = drawimage(client, a+1);
			drawrectangle(&r, a+5);
			if(!rectinrect(r, dst->r))
				error(Ewriteoutside);
			y = memload(dst, r, a+m, n-m, *a=='Y');
			if(y < 0)
				error("bad writeimage call");
			dstflush(dstid, dst, r, 1);
			m += y;
			continue;
		}
	}
	poperror();
}

int
drawlsetrefresh(ulong qidpath, int id, void *reffn, void *refx)
{
	DImage *d;
	Memimage *i;
	Client *client;

	client = drawclientofpath(qidpath);
	if(client == 0)
		return 0;
	d = drawlookup(client, id, 0);
	if(d == nil)
		return 0;
	i = d->image;
	if(i->layer == nil)
		return 0;
	return memlsetrefresh(i, reffn, refx);
}

Dev drawdevtab = {
	'i',
	"draw",

	devreset,
	devinit,
	devshutdown,
	drawattach,
	drawwalk,
	drawstat,
	drawopen,
	devcreate,
	drawclose,
	drawread,
	devbread,
	drawwrite,
	devbwrite,
	devremove,
	devwstat,
};

/*
 * On 8 bit displays, load the default color map
 */
void
drawcmap(void)
{
	int r, g, b, cr, cg, cb, v;
	int num, den;
	int i, j;

	for(r=0,i=0; r!=4; r++)
	    for(v=0; v!=4; v++,i+=16){
		for(g=0,j=v-r; g!=4; g++)
		    for(b=0;b!=4;b++,j++){
			den = r;
			if(g > den)
				den = g;
			if(b > den)
				den = b;
			if(den == 0)	/* divide check -- pick grey shades */
				cr = cg = cb = v*17;
			else{
				num = 17*(4*den+v);
				cr = r*num/den;
				cg = g*num/den;
				cb = b*num/den;
			}
			setcolor(i+(j&15),
				cr*0x01010101, cg*0x01010101, cb*0x01010101);
		    }
	}
}

void
drawblankscreen(int blank)
{
	int i, nc;
	u32 *p;

	if(blank == sdraw.blanked)
		return;
	if(!canqlock((QLock*)&sdraw))
		return;
	if(!initscreenimage()){
		qunlock((QLock*)&sdraw);
		return;
	}
	p = sdraw.savemap;
	nc = screenimage->depth > 8 ? 256 : 1<<screenimage->depth;

	/*
	 * blankscreen uses the hardware to blank the screen
	 * when possible.  to help in cases when it is not possible,
	 * we set the color map to be all black.
	 */
	if(blank == 0){	/* turn screen on */
		for(i=0; i<nc; i++, p+=3)
			setcolor(i, p[0], p[1], p[2]);
		blankscreen(0);
	}else{	/* turn screen off */
		blankscreen(1);
		for(i=0; i<nc; i++, p+=3){
			getcolor(i, &p[0], &p[1], &p[2]);
			setcolor(i, 0, 0, 0);
		}
	}
	sdraw.blanked = blank;
	qunlock((QLock*)&sdraw);
}

/*
 * record activity on screen, changing blanking as appropriate
 */
void
drawactive(int active)
{
	if(active){
		drawblankscreen(0);
		sdraw.blanktime = 0;
	}else{
		if(blanktime && TK2SEC(sdraw.blanktime)/60 >= blanktime)
			drawblankscreen(1);
		else
			sdraw.blanktime++;
	}
}

void
interf(void)
{
	/* force it to load */
	drawreplxy(0, 0, 0);
}

int
drawidletime(void)
{
	return TK2SEC(MACHP(0)->ticks - sdraw.blanktime)/60;
}
