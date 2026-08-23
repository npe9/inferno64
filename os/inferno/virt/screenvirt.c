/*
 * Framebuffer for Inferno/riscv64 virt.
 * Optional QEMU ramfb via fw_cfg @ 0x10100000 (etc/ramfb).
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

	/* KenC: avoid 0x10100000ULL sign-extension; 0x101<<20 */
	FwCfgBase	= ((uintptr)0x101 << 20),
	FwCfgSel	= FwCfgBase + 8,
	FwCfgDmaReg	= FwCfgBase + 16,

	FwCfgFileDir	= 0x19,
	FwCfgDmaRead	= 1<<1,
	FwCfgDmaSelect	= 1<<3,
	FwCfgDmaWrite	= 1<<4,
};

/* DRM fourcc XRGB8888 ('XR24') */
enum { FourccXRGB8888 = 0x34325258 };

/*
 * QEMU RAMFBCfg is packed 28 bytes. KenC pads a struct with trailing u32
 * to 32; oversized DMA writes are rejected, so pack into a byte buffer.
 */
enum { RamfbCfgSize = 28 };

typedef struct FwDmaDesc FwDmaDesc;
struct FwDmaDesc
{
	u32int	control;
	u32int	length;
	u64int	address;
};

static Memdata	scrdata;
Memimage	*gscreen;
static uchar	*fb;		/* ramfb + gscreen (same buffer) */
static int	ramfbok;
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

static u32int
be32(u32int v)
{
	return (v>>24) | ((v>>8)&0xff00) | ((v<<8)&0xff0000) | (v<<24);
}

static u64int
be64(u64int v)
{
	return ((u64int)be32((u32int)v)<<32) | (u64int)be32((u32int)(v>>32));
}

static void
fwcfgsel(u16int sel)
{
	/* big-endian 16-bit selector */
	*(volatile u16int*)FwCfgSel = (u16int)(((sel&0xff)<<8) | ((sel>>8)&0xff));
}

static int
fwcfgdma(u32int control, void *buf, u32int len)
{
	FwDmaDesc *dma;
	u64int dmap;

	dma = malloc(sizeof(*dma));
	if(dma == nil)
		return -1;
	memset(dma, 0, sizeof(*dma));
	dma->control = be32(control);
	dma->length = be32(len);
	dma->address = be64((u64int)(uintptr)buf);
	coherence();
	dmap = (u64int)(uintptr)dma;
	*(volatile u32int*)FwCfgDmaReg = be32((u32int)(dmap>>32));
	*(volatile u32int*)(FwCfgDmaReg+4) = be32((u32int)dmap);
	while(be32(dma->control) & ~(u32int)1)
		;
	if(be32(dma->control) & 1){
		free(dma);
		return -1;
	}
	free(dma);
	return 0;
}

/*
 * Scan fw_cfg file directory for etc/ramfb; return selector or -1.
 * Directory entry: be32 size, be16 select, be16 reserved, name[56].
 */
static int
ramfbsel(void)
{
	u32int count, i;
	uchar ent[64];
	u16int sel;

	if(fwcfgdma(((u32int)FwCfgFileDir<<16) | FwCfgDmaSelect | FwCfgDmaRead,
	    &count, 4) < 0)
		return -1;
	count = be32(count);
	if(count > 512)
		count = 512;
	for(i = 0; i < count; i++){
		if(fwcfgdma(FwCfgDmaRead, ent, 64) < 0)
			return -1;
		sel = ((u16int)ent[4]<<8) | ent[5];
		if(strncmp((char*)(ent+8), "etc/ramfb", 9) == 0)
			return (int)sel;
	}
	return -1;
}

static void
putbe32(uchar *p, u32int v)
{
	p[0] = v>>24;
	p[1] = v>>16;
	p[2] = v>>8;
	p[3] = v;
}

static void
putbe64(uchar *p, u64int v)
{
	putbe32(p, (u32int)(v>>32));
	putbe32(p+4, (u32int)v);
}

static void
ramfbconfigure(void)
{
	uchar cfg[RamfbCfgSize];
	int sel;

	USED(fwcfgsel);
	sel = ramfbsel();
	if(sel < 0){
		print("ramfb: no etc/ramfb (add -device ramfb)\n");
		return;
	}
	memset(cfg, 0, sizeof cfg);
	putbe64(cfg+0, (u64int)(uintptr)fb);
	putbe32(cfg+8, FourccXRGB8888);
	putbe32(cfg+12, 0);			/* flags */
	putbe32(cfg+16, ScrX);
	putbe32(cfg+20, ScrY);
	putbe32(cfg+24, ScrX * ScrPix);		/* stride */
	if(fwcfgdma(((u32int)sel<<16) | FwCfgDmaSelect | FwCfgDmaWrite,
	    cfg, RamfbCfgSize) < 0)
		print("ramfb: configure failed\n");
	else{
		ramfbok = 1;
		print("ramfb: %ludx%lud @ %lux\n", (ulong)ScrX, (ulong)ScrY, (ulong)fb);
	}
}

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

	memimageinit();
	nbytes = ScrX * ScrY * ScrPix;
	/* One buffer: gscreen draws straight into ramfb (no soft→fb copy). */
	fb = xalloc(nbytes);
	if(fb == nil){
		print("screen: no memory for %d byte fb\n", nbytes);
		return;
	}
	memset(fb, 0x40, nbytes);

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

	ramfbconfigure();

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
