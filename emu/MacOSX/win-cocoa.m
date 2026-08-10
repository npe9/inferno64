/*
 * Cocoa window backend for Inferno emu (MacOSX arm64 / modern macOS).
 * Softscreen is XBGR32 (LE bytes R,G,B,X); presented via Metal (CAMetalLayer).
 * UI runs on the process main thread (see main-cocoa.m).
 */
/* MacTypes.h (via Cocoa) also defines Point/Rect/nil — rename while importing. */
#define Point	MacPoint
#define Rect	MacRect
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#undef Point
#undef Rect
#undef nil

#include "dat.h"
#include "fns.h"
#include <unistd.h>
#undef log2
#include <draw.h>
#define attachscreen	attachscreen_memdraw_proto
#include <memdraw.h>
#undef attachscreen
#include <memlayer.h>
#include "cursor.h"
#include "keyboard.h"
#include "keycodes.h"

#define	Kup	Up
#define	Kleft	Left
#define	Kdown	Down
#define	Kright	Right
#define	Kalt	LAlt
#define	Kctl	LCtrl
#define	Kshift	LShift
#define	Kpgup	Pgup
#define	Kpgdown	Pgdown
#define	Khome	Home
#define	Kins	Ins
#define	Kend	End

enum {
	SnarfSize = 100*1024,
};

Memimage	*gscreen;

extern Memimage	*screenimage;	/* emu/port/devdraw.c */

static int		readybit;
static Rendez		rend;
static int		triedscreen;
static int		dx, dy;
static NSWindow		*win;
static NSView		*view;
static NSCursor		*customcursor;
static int		mousebuttons;
static int		mouseX, mouseY;
static int		altPressed;
static int		button2, button3;
static char		snarf[3*SnarfSize+1];

static int	live_resizing;
static int	miniaturized;
static int	fullscreen_transition;
static int	wm_notify_generation;
static volatile int	present_dirty;
static volatile int	present_queued;

/* Metal softscreen present (CAMetalLayer) + direct draw3d 'G' lines. */
static id<MTLDevice>		mtl_device;
static id<MTLCommandQueue>	mtl_queue;
static id<MTLRenderPipelineState>	mtl_pipe;
static id<MTLRenderPipelineState>	mtl_line_pipe;	/* BGRA8 drawable */
static id<MTLTexture>		mtl_tex;
static int	mtl_tex_w, mtl_tex_h;
static CAMetalLayer	*mtl_layer;
static Rectangle	soft_upload;	/* dirty softscreen region since last present */
static int	soft_upload_valid;

enum {
	MaxGPULines = 16384,
};

typedef struct GPULine GPULine;
struct GPULine {
	float	x0, y0, x1, y1;
	float	r, g, b, a;
};

/* Screen-space segments held until present (no Memimage writeback). */
static GPULine	glines[MaxGPULines];
static int	nglines;

/* Soft Plan9 Paper desktop (#C4C0B4); must match appl/wm/wm.b Background. */
enum {
	PaperR = 0xC4,
	PaperG = 0xC0,
	PaperB = 0xB4,
	/* XBGR32 little-endian memory: R,G,B,X */
	PaperPix = (0xFF<<24) | (PaperB<<16) | (PaperG<<8) | PaperR,
};

/*
 * Line vertex layout MUST stay 6 tightly packed floats.
 * (float2+float4 in Metal inserts 8 bytes of padding → 32-byte stride while
 * a C {x,y,r,g,b,a} is 24 bytes — that made every line share a bogus origin.)
 */
static NSString *const kSoftscreenMetalSrc =
	@"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct VOut { float4 pos [[position]]; float2 uv; };\n"
	"vertex VOut vmain(uint vid [[vertex_id]]) {\n"
	"  float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
	"  float2 u[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };\n"
	"  VOut o; o.pos = float4(p[vid], 0, 1); o.uv = u[vid]; return o;\n"
	"}\n"
	"fragment float4 fmain(VOut in [[stage_in]],\n"
	"    texture2d<float> tex [[texture(0)]],\n"
	"    sampler samp [[sampler(0)]]) {\n"
	"  return tex.sample(samp, in.uv);\n"
	"}\n"
	"struct LIn { float x, y, r, g, b, a; };\n"
	"struct LOut { float4 pos [[position]]; float4 color; };\n"
	"vertex LOut vlmain(uint vid [[vertex_id]],\n"
	"    constant LIn *v [[buffer(0)]],\n"
	"    constant float2 &wh [[buffer(1)]]) {\n"
	"  LIn i = v[vid];\n"
	"  LOut o;\n"
	"  float2 ndc = float2(i.x/wh.x*2.0-1.0, 1.0-i.y/wh.y*2.0);\n"
	"  o.pos = float4(ndc, 0, 1);\n"
	"  o.color = float4(i.r, i.g, i.b, i.a);\n"
	"  return o;\n"
	"}\n"
	"fragment float4 flmain(LOut in [[stage_in]]) { return in.color; }\n";

/* Assigned from metal_init; declared in emu/port/devdraw.c */
extern int	(*gpudrawline)(Memimage*, Point, Point, int, Memimage*, int);
extern void	(*gpudrawflush)(void);

static void	metal_flush_lines(void);
static int	metal_queue_line(Memimage*, Point, Point, int, Memimage*, int);
static void	metal_present_lines(id<MTLCommandBuffer>, id<MTLTexture>, int, int);

static void
invalidate_mtl_tex(void)
{
	mtl_tex = nil;
	mtl_tex_w = mtl_tex_h = 0;
	soft_upload_valid = 0;
}

static int
metal_init(void)
{
	NSError *err;
	id<MTLLibrary> lib;
	MTLRenderPipelineDescriptor *pd;

	if(mtl_device != nil)
		return 0;
	mtl_device = MTLCreateSystemDefaultDevice();
	if(mtl_device == nil)
		return -1;
	mtl_queue = [mtl_device newCommandQueue];
	if(mtl_queue == nil)
		return -1;
	lib = [mtl_device newLibraryWithSource:kSoftscreenMetalSrc options:nil error:&err];
	if(lib == nil)
		return -1;
	pd = [[MTLRenderPipelineDescriptor alloc] init];
	pd.vertexFunction = [lib newFunctionWithName:@"vmain"];
	pd.fragmentFunction = [lib newFunctionWithName:@"fmain"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	mtl_pipe = [mtl_device newRenderPipelineStateWithDescriptor:pd error:&err];
	if(mtl_pipe == nil)
		return -1;

	/* Lines composite directly onto the CAMetalLayer drawable (BGRA8). */
	pd = [[MTLRenderPipelineDescriptor alloc] init];
	pd.vertexFunction = [lib newFunctionWithName:@"vlmain"];
	pd.fragmentFunction = [lib newFunctionWithName:@"flmain"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	pd.colorAttachments[0].blendingEnabled = NO;
	mtl_line_pipe = [mtl_device newRenderPipelineStateWithDescriptor:pd error:&err];
	if(mtl_line_pipe == nil)
		return -1;

	gpudrawline = metal_queue_line;
	gpudrawflush = metal_flush_lines;
	return 0;
}

static id<MTLTexture>
metal_soft_tex(int pw, int ph)
{
	MTLTextureDescriptor *td;

	if(mtl_tex != nil && mtl_tex_w == pw && mtl_tex_h == ph)
		return mtl_tex;
	td = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		width:pw height:ph mipmapped:NO];
	td.usage = MTLTextureUsageShaderRead;
	td.storageMode = MTLStorageModeShared;
	mtl_tex = [mtl_device newTextureWithDescriptor:td];
	mtl_tex_w = pw;
	mtl_tex_h = ph;
	return mtl_tex;
}

static int
src_rgba(Memimage *src, float *r, float *g, float *b, float *a)
{
	uchar *p;

	if(src == nil || src->data == nil || src->data->bdata == nil)
		return -1;
	p = byteaddr(src, src->r.min);
	if(p == nil)
		return -1;
	*a = 1.0f;
	switch(src->chan){
	case RGB24:
		*r = p[0] / 255.0f;
		*g = p[1] / 255.0f;
		*b = p[2] / 255.0f;
		return 0;
	case RGBA32:
		*r = p[0] / 255.0f;
		*g = p[1] / 255.0f;
		*b = p[2] / 255.0f;
		*a = p[3] / 255.0f;
		return 0;
	case XBGR32:
	case XRGB32:
		*r = p[0] / 255.0f;
		*g = p[1] / 255.0f;
		*b = p[2] / 255.0f;
		return 0;
	default:
		if(src->depth == 32){
			*r = p[0] / 255.0f;
			*g = p[1] / 255.0f;
			*b = p[2] / 255.0f;
			return 0;
		}
		return -1;
	}
}

/*
 * Resolve clear layered windows to softscreen (screen coords).
 * Obscured layers stay on the software memline path.
 */
static Memimage*
line_pixdst(Memimage *dst, Point *p0, Point *p1)
{
	Memlayer *l;

	if(dst == nil)
		return nil;
	l = dst->layer;
	if(l == nil)
		return dst;
	if(!l->clear)
		return nil;
	*p0 = addpt(*p0, l->delta);
	*p1 = addpt(*p1, l->delta);
	return l->screen->image;
}

static void
soft_bresenham(Memimage *dst, GPULine *L)
{
	int x0, y0, x1, y1, dx, dy, sx, sy, err, e2;
	u32 pix;
	uchar *p;
	Rectangle clip;

	if(dst == nil)
		return;
	x0 = (int)L->x0;
	y0 = (int)L->y0;
	x1 = (int)L->x1;
	y1 = (int)L->y1;
	pix = ((u32)(L->a * 255) << 24) | ((u32)(L->b * 255) << 16)
		| ((u32)(L->g * 255) << 8) | (u32)(L->r * 255);
	clip = dst->clipr;
	dx = x1 > x0 ? x1 - x0 : x0 - x1;
	dy = y1 > y0 ? y1 - y0 : y0 - y1;
	sx = x0 < x1 ? 1 : -1;
	sy = y0 < y1 ? 1 : -1;
	err = dx - dy;
	for(;;){
		if(x0 >= clip.min.x && x0 < clip.max.x && y0 >= clip.min.y && y0 < clip.max.y){
			p = byteaddr(dst, Pt(x0, y0));
			if(p != nil)
				*(u32*)p = pix;
		}
		if(x0 == x1 && y0 == y1)
			break;
		e2 = 2 * err;
		if(e2 > -dy){
			err -= dy;
			x0 += sx;
		}
		if(e2 < dx){
			err += dx;
			y0 += sy;
		}
	}
}

/*
 * Direct path: 'G' segments stay queued until present.  No Memimage writeback.
 * gpudrawflush is a no-op so 2D draws after line3 do not force a CPU round-trip;
 * lines composite onto the drawable after the softscreen blit.
 */
static void
metal_flush_lines(void)
{
	/* retained until metal_present_lines */
}

static void
metal_present_lines(id<MTLCommandBuffer> cmd, id<MTLTexture> drawabletex, int pw, int ph)
{
	int i, n, nv;
	float wh[2];
	id<MTLBuffer> vbuf;
	id<MTLRenderCommandEncoder> enc;
	MTLRenderPassDescriptor *rp;
	typedef struct { float x, y, r, g, b, a; } LVert;
	LVert *verts;

	n = nglines;
	if(n == 0 || cmd == nil || drawabletex == nil || mtl_line_pipe == nil)
		return;
	nglines = 0;

	nv = n * 2;
	vbuf = [mtl_device newBufferWithLength:sizeof(LVert) * nv options:MTLResourceStorageModeShared];
	if(vbuf == nil){
		/* Emergency: burn into softscreen so the frame is not blank. */
		for(i = 0; i < n; i++)
			soft_bresenham(gscreen, &glines[i]);
		return;
	}
	verts = vbuf.contents;
	for(i = 0; i < n; i++){
		verts[2*i].x = glines[i].x0;
		verts[2*i].y = glines[i].y0;
		verts[2*i].r = glines[i].r;
		verts[2*i].g = glines[i].g;
		verts[2*i].b = glines[i].b;
		verts[2*i].a = glines[i].a;
		verts[2*i+1].x = glines[i].x1;
		verts[2*i+1].y = glines[i].y1;
		verts[2*i+1].r = glines[i].r;
		verts[2*i+1].g = glines[i].g;
		verts[2*i+1].b = glines[i].b;
		verts[2*i+1].a = glines[i].a;
	}
	wh[0] = (float)pw;
	wh[1] = (float)ph;

	rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = drawabletex;
	rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;

	enc = [cmd renderCommandEncoderWithDescriptor:rp];
	[enc setRenderPipelineState:mtl_line_pipe];
	[enc setVertexBuffer:vbuf offset:0 atIndex:0];
	[enc setVertexBytes:wh length:sizeof(wh) atIndex:1];
	[enc drawPrimitives:MTLPrimitiveTypeLine vertexStart:0 vertexCount:nv];
	[enc endEncoding];
}

static int
metal_queue_line(Memimage *dst, Point p0, Point p1, int thick, Memimage *src, int op)
{
	Memimage *pix;
	Point a, b;
	float r, g, bl, al;
	GPULine *L;
	int i;

	USED(thick);
	if(op != SoverD && op != S)
		return 0;
	if(thick > 0)
		return 0;
	a = p0;
	b = p1;
	pix = line_pixdst(dst, &a, &b);
	if(pix == nil)
		return 0;
	/* Direct present only composites onto the softscreen drawable. */
	if(pix != gscreen && pix != screenimage)
		return 0;
	if(src_rgba(src, &r, &g, &bl, &al) < 0)
		return 0;
	if(nglines >= MaxGPULines){
		/* Overflow: fold oldest into softscreen so we do not drop geometry. */
		for(i = 0; i < nglines; i++)
			soft_bresenham(gscreen, &glines[i]);
		nglines = 0;
	}
	L = &glines[nglines++];
	L->x0 = (float)a.x;
	L->y0 = (float)a.y;
	L->x1 = (float)b.x;
	L->y1 = (float)b.y;
	L->r = r;
	L->g = g;
	L->b = bl;
	L->a = al;
	return 1;
}

/*
 * Softscreen blit, then direct Metal line overlay onto the drawable.
 * 2D/wm stay in the softscreen; draw3d 'G' is GPU-composited on top
 * (no upload/download round-trip for the wireframe).
 */
static void
present_softscreen(void)
{
	int pw, ph, bpl, ux, uy, uw, uh;
	uchar *base, *row;
	id<MTLTexture> tex;
	id<CAMetalDrawable> drawable;
	id<MTLCommandBuffer> cmd;
	id<MTLRenderCommandEncoder> enc;
	MTLRenderPassDescriptor *rp;
	MTLRegion region;
	MTLSamplerDescriptor *sd;
	static id<MTLSamplerState> samp;
	Rectangle ur;

	if(view == nil || mtl_layer == nil || mtl_device == nil || mtl_pipe == nil)
		return;
	if(gscreen == nil || gscreen->data == nil || gscreen->data->bdata == nil)
		return;
	pw = Dx(gscreen->r);
	ph = Dy(gscreen->r);
	if(pw < 1 || ph < 1)
		return;
	bpl = gscreen->width * (int)sizeof(u32);
	base = gscreen->data->bdata;

	mtl_layer.drawableSize = CGSizeMake(pw, ph);
	drawable = [mtl_layer nextDrawable];
	if(drawable == nil)
		return;
	tex = metal_soft_tex(pw, ph);
	if(tex == nil)
		return;

	if(soft_upload_valid){
		ur = soft_upload;
		if(!rectclip(&ur, gscreen->r))
			ur = gscreen->r;
	}else
		ur = gscreen->r;
	soft_upload_valid = 0;
	ux = ur.min.x - gscreen->r.min.x;
	uy = ur.min.y - gscreen->r.min.y;
	uw = Dx(ur);
	uh = Dy(ur);
	if(uw > 0 && uh > 0){
		row = base + uy * bpl + ux * 4;
		region = MTLRegionMake2D(ux, uy, uw, uh);
		[tex replaceRegion:region mipmapLevel:0 withBytes:row bytesPerRow:bpl];
	}

	if(samp == nil){
		sd = [[MTLSamplerDescriptor alloc] init];
		sd.minFilter = MTLSamplerMinMagFilterNearest;
		sd.magFilter = MTLSamplerMinMagFilterNearest;
		samp = [mtl_device newSamplerStateWithDescriptor:sd];
	}

	cmd = [mtl_queue commandBuffer];

	rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = drawable.texture;
	rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;

	enc = [cmd renderCommandEncoderWithDescriptor:rp];
	[enc setRenderPipelineState:mtl_pipe];
	[enc setFragmentTexture:tex atIndex:0];
	[enc setFragmentSamplerState:samp atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[enc endEncoding];

	/* Direct wireframe onto the drawable (after 2D softscreen). */
	metal_present_lines(cmd, drawable.texture, pw, ph);

	[cmd presentDrawable:drawable];
	[cmd commit];
}

static void
present_on_main(void)
{
	present_queued = 0;
	if(!present_dirty)
		return;
	present_dirty = 0;
	present_softscreen();
}

/*
 * Coalesce presents onto the next main-queue turn (or run now if already there).
 * After wmclient Flushoff, Flushnow is once per composed frame — no need to wait
 * for CVDisplayLink (that added up to a refresh of latency and felt sluggish).
 * Multiple Flushnows in one quantum still collapse to a single blit.
 */
static void
mark_view_dirty(void)
{
	if(view == nil)
		return;
	present_dirty = 1;
	if([NSThread isMainThread]){
		present_queued = 0;
		present_on_main();
		return;
	}
	if(present_queued)
		return;
	present_queued = 1;
	dispatch_async(dispatch_get_main_queue(), ^{
		present_on_main();
	});
}

static void
fillscreen(Memimage *m, u32 color)
{
	int x, y, w, h;
	u32 *pix;

	if(m == nil || m->data == nil || m->data->bdata == nil)
		return;
	w = Dx(m->r);
	h = Dy(m->r);
	pix = (u32*)m->data->bdata;
	for(y = 0; y < h; y++)
		for(x = 0; x < w; x++)
			pix[y * m->width + x] = color;
}

/*
 * Grow/shrink the softscreen to the view size.
 * notify!=0 publishes a pointer resize so wm can reshape clients.
 * Transient host gestures (live drag, zoom animation, fullscreen,
 * miniaturize) rebind pixels only; a single coalesced notify follows.
 */
static void
screenresize(int w, int h, int notify)
{
	Memimage *old, *next;
	int copyw, copyh, y, bpl;

	if(w < 1 || h < 1)
		return;
	/*
	 * Same size: leave softscreen alone.  Do not mouseresize here —
	 * deminiaturize / duplicate DidResize events used to poke wm with a
	 * same-size resize and tear every client window down to grey.
	 * Callers that must sync wm after a live drag use flush_wm_notify.
	 */
	if(w == dx && h == dy)
		return;
	next = allocmemimage(Rect(0, 0, w, h), XBGR32);
	if(next == nil)
		return;
	old = gscreen;
	/* Newly exposed pixels: Soft Plan9 Paper (not host-window grey). */
	bpl = next->width * sizeof(u32);
	fillscreen(next, PaperPix);
	if(old != nil){
		copyw = old->r.max.x - old->r.min.x;
		if(copyw > w) copyw = w;
		copyh = old->r.max.y - old->r.min.y;
		if(copyh > h) copyh = h;
		for(y = 0; y < copyh; y++)
			memmove(next->data->bdata + y * bpl,
				old->data->bdata + y * old->width * sizeof(u32),
				(size_t)copyw * sizeof(u32));
	}
	gscreen = next;
	dx = w;
	dy = h;
	Xsize = w;
	Ysize = h;
	invalidate_mtl_tex();
	if(notify)
		drawscreenresize(gscreen);
	else
		drawscreenrebind(gscreen);
	mark_view_dirty();
	/* Existing Draw images may still reference the old screen data while
	 * the window system processes its resize notification.  Retain it until
	 * process teardown rather than freeing it under those clients. */
}

static void
notify_screen_size(void)
{
	NSRect r;
	int w, h;

	if(view == nil || !readybit || miniaturized)
		return;
	r = [view bounds];
	w = (int)r.size.width;
	h = (int)r.size.height;
	if(w < 1 || h < 1)
		return;
	/*
	 * Size unchanged: do nothing.  A setNeedsDisplay here used to feed a
	 * layout→DidResize→debounce→display loop that blinked the whole UI
	 * even though Inferno pixels were stable.
	 */
	if(w == dx && h == dy)
		return;
	screenresize(w, h, 1);
}

/*
 * Zoom / animated setFrame deliver many intermediate sizes without
 * live-resize begin/end.  Coalesce to one wm reshape after the dust settles.
 * 150ms covers typical macOS zoom animation frame gaps without mid-gesture
 * reshape storms that left apps as grey placeholders.
 */
static void
schedule_wm_notify(void)
{
	int gen;

	if(!readybit || miniaturized || live_resizing || fullscreen_transition)
		return;
	gen = ++wm_notify_generation;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
		dispatch_get_main_queue(), ^{
			if(gen != wm_notify_generation)
				return;
			if(miniaturized || live_resizing || fullscreen_transition)
				return;
			notify_screen_size();
		});
}

/*
 * Live-resize end / fullscreen transitions: softscreen already tracks the
 * view, so screenresize is a no-op on size — still must mouseresize so wm
 * reshapes clients to the final geometry.
 */
static void
flush_wm_notify(void)
{
	NSRect r;
	int w, h;

	wm_notify_generation++;	/* cancel pending debounce */
	if(view == nil || !readybit || miniaturized)
		return;
	r = [view bounds];
	w = (int)r.size.width;
	h = (int)r.size.height;
	if(w < 1 || h < 1)
		return;
	if(w != dx || h != dy)
		screenresize(w, h, 1);
	else if(gscreen != nil)
		mouseresize(dx, dy);
}

static int
bytesperline1(Rectangle r)
{
	return ((r.max.x - r.min.x) + 7) / 8;
}

static int
isready(void *a)
{
	USED(a);
	return readybit;
}

static void
sendbuttons(int b, int x, int y)
{
	mousetrack(b, x, y, 0);
}

static int
convert_key(unsigned short key, unichar ch)
{
	switch(key) {
	case QZ_IBOOK_ENTER:
	case QZ_RETURN:
	case QZ_KP_ENTER:
		return '\n';
	case QZ_ESCAPE:
		return 27;
	case QZ_BACKSPACE:
		return '\b';
	case QZ_LALT:
	case QZ_RALT:
		return Kalt;
	case QZ_LCTRL:
	case QZ_RCTRL:
		return Kctl;
	case QZ_LSHIFT:
	case QZ_RSHIFT:
		return Kshift;
	case QZ_F1: return KF+1;
	case QZ_F2: return KF+2;
	case QZ_F3: return KF+3;
	case QZ_F4: return KF+4;
	case QZ_F5: return KF+5;
	case QZ_F6: return KF+6;
	case QZ_F7: return KF+7;
	case QZ_F8: return KF+8;
	case QZ_F9: return KF+9;
	case QZ_F10: return KF+10;
	case QZ_F11: return KF+11;
	case QZ_F12: return KF+12;
	case QZ_INSERT:
		return Kins;
	case QZ_DELETE:
		return 0x7F;
	case QZ_HOME:
		return Khome;
	case QZ_END:
		return Kend;
	case QZ_TAB:
		return '\t';
	case QZ_PAGEUP:
		return Kpgup;
	case QZ_PAGEDOWN:
		return Kpgdown;
	case QZ_UP:
		return Kup;
	case QZ_DOWN:
		return Kdown;
	case QZ_LEFT:
		return Kleft;
	case QZ_RIGHT:
		return Kright;
	case QZ_KP_PLUS:
		return '+';
	case QZ_KP_MINUS:
		return '-';
	case QZ_KP_MULTIPLY:
		return '*';
	case QZ_KP_DIVIDE:
		return '/';
	case QZ_KP_PERIOD:
		return '.';
	case QZ_KP0: return '0';
	case QZ_KP1: return '1';
	case QZ_KP2: return '2';
	case QZ_KP3: return '3';
	case QZ_KP4: return '4';
	case QZ_KP5: return '5';
	case QZ_KP6: return '6';
	case QZ_KP7: return '7';
	case QZ_KP8: return '8';
	case QZ_KP9: return '9';
	default:
		if(ch != 0 && ch < Spec)
			return (int)ch;
		return -1;
	}
}

@interface InfernoView : NSView
@end

@implementation InfernoView
+ (Class)layerClass
{
	return [CAMetalLayer class];
}

- (BOOL)acceptsFirstResponder
{
	return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)e
{
	(void)e;
	return YES;
}

- (BOOL)isOpaque
{
	return YES;
}

- (BOOL)wantsUpdateLayer
{
	return NO;
}

- (void)updateTrackingAreas
{
	NSTrackingAreaOptions opts;
	NSTrackingArea *ta;

	[super updateTrackingAreas];
	for(ta in [NSArray arrayWithArray:[self trackingAreas]])
		[self removeTrackingArea:ta];
	opts = NSTrackingMouseMoved
		| NSTrackingMouseEnteredAndExited
		| NSTrackingActiveInKeyWindow
		| NSTrackingInVisibleRect
		| NSTrackingEnabledDuringMouseDrag;
	ta = [[NSTrackingArea alloc] initWithRect:[self bounds]
		options:opts
		owner:self
		userInfo:nil];
	[self addTrackingArea:ta];
}

- (void)viewDidChangeBackingProperties
{
	[super viewDidChangeBackingProperties];
}

- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	if(mtl_layer != nil){
		[self setWantsLayer:YES];
		self.layer = mtl_layer;
	}
}

- (void)setFrameSize:(NSSize)size
{
	int w, h;

	[super setFrameSize:size];
	if(!readybit || gscreen == nil || size.width < 1 || size.height < 1)
		return;
	/*
	 * Miniaturized: leave the softscreen alone (dock preview / restore).
	 * Live drag: rebind pixels so newly exposed areas exist; wm at end.
	 * Zoom / animated setFrame: do not touch the softscreen on intermediate
	 * sizes — AppKit stretches prior layer contents; one resize+notify at end
	 * avoids wiping client pixels into grey mid-gesture.
	 */
	if(miniaturized)
		return;
	w = (int)size.width;
	h = (int)size.height;
	if(live_resizing){
		screenresize(w, h, 0);
		return;
	}
	if(fullscreen_transition)
		return;
	/* Same size: never re-arm the debounce (display/layout feedback). */
	if(w == dx && h == dy)
		return;
	schedule_wm_notify();
}

- (void)resetCursorRects
{
	[super resetCursorRects];
	if(customcursor)
		[self addCursorRect:[self bounds] cursor:customcursor];
}

- (BOOL)isFlipped
{
	/* Top-left origin like Inferno softscreen rows. */
	return YES;
}

- (void)drawRect:(NSRect)dirty
{
	(void)dirty;
	/* Expose/resize: Metal present (also used by coalesced flush path). */
	present_softscreen();
}

- (void)keyDown:(NSEvent *)e
{
	int key;
	NSUInteger mods;
	NSString *chars;
	unichar ch;

	mods = [e modifierFlags];
	/* Cmd+Q etc. handled by the menu; swallow other Cmd chords */
	if(mods & NSEventModifierFlagCommand)
		return;

	chars = [e characters];
	ch = [chars length] > 0 ? [chars characterAtIndex:0] : 0;
	key = convert_key([e keyCode], ch);
	if(key != -1)
		gkbdputc(gkbdq, key);
}

- (void)flagsChanged:(NSEvent *)e
{
	NSUInteger mods = [e modifierFlags];

	switch(mods & (NSEventModifierFlagOption | NSEventModifierFlagCommand)) {
	case NSEventModifierFlagOption | NSEventModifierFlagCommand:
		altPressed = 1;
		if(mousebuttons & (1|2|4)) {
			mousebuttons |= 2|4;
			button2 = button3 = 1;
			sendbuttons(mousebuttons, mouseX, mouseY);
		}
		break;
	case NSEventModifierFlagOption:
		altPressed = 1;
		if(mousebuttons & (1|4)) {
			mousebuttons |= 2;
			button2 = 1;
			sendbuttons(mousebuttons, mouseX, mouseY);
		}
		break;
	case NSEventModifierFlagCommand:
		if(mousebuttons & (1|2)) {
			mousebuttons |= 4;
			button3 = 1;
			sendbuttons(mousebuttons, mouseX, mouseY);
		} else
			gkbdputc(gkbdq, Latin);
		break;
	default:
		if(button2 || button3) {
			if(button2) {
				mousebuttons &= ~2;
				button2 = 0;
				altPressed = 0;
			}
			if(button3) {
				mousebuttons &= ~4;
				button3 = 0;
			}
			sendbuttons(mousebuttons, mouseX, mouseY);
		}
		if(altPressed) {
			gkbdputc(gkbdq, Kalt);
			altPressed = 0;
		}
		break;
	}
}

- (void)mousePosFromEvent:(NSEvent *)e
{
	NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
	NSRect b = [self bounds];
	/* Map view coords → softscreen; isFlipped matches Inferno. */
	if(b.size.width > 0 && b.size.height > 0) {
		mouseX = (int)(p.x * dx / b.size.width);
		mouseY = (int)(p.y * dy / b.size.height);
	} else {
		mouseX = (int)p.x;
		mouseY = (int)p.y;
	}
	if(mouseX < 0) mouseX = 0;
	if(mouseY < 0) mouseY = 0;
	if(mouseX >= dx) mouseX = dx-1;
	if(mouseY >= dy) mouseY = dy-1;
}

- (void)mouseButtonsFromEvent:(NSEvent *)e down:(BOOL)down
{
	NSUInteger mods = [e modifierFlags];
	NSInteger button = [e buttonNumber];
	int bit;

	if(button == 0) {
		if(mods & NSEventModifierFlagOption)
			bit = 2;
		else if(mods & NSEventModifierFlagCommand)
			bit = 4;
		else
			bit = 1;
	} else if(button == 2)
		bit = 2;
	else if(button == 1)
		bit = 4;
	else
		bit = 1;

	if(down)
		mousebuttons |= bit;
	else
		mousebuttons &= ~bit;

	if(down && [e clickCount] > 1)
		mousebuttons |= 1<<8;
	else
		mousebuttons &= ~(1<<8);
}

- (void)mouseDown:(NSEvent *)e
{
	[self mousePosFromEvent:e];
	[self mouseButtonsFromEvent:e down:YES];
	sendbuttons(mousebuttons, mouseX, mouseY);
}

- (void)mouseUp:(NSEvent *)e
{
	[self mousePosFromEvent:e];
	[self mouseButtonsFromEvent:e down:NO];
	sendbuttons(mousebuttons, mouseX, mouseY);
}

- (void)rightMouseDown:(NSEvent *)e	{ [self mouseDown:e]; }
- (void)rightMouseUp:(NSEvent *)e	{ [self mouseUp:e]; }
- (void)otherMouseDown:(NSEvent *)e	{ [self mouseDown:e]; }
- (void)otherMouseUp:(NSEvent *)e	{ [self mouseUp:e]; }

- (void)mouseDragged:(NSEvent *)e
{
	[self mousePosFromEvent:e];
	sendbuttons(mousebuttons, mouseX, mouseY);
}

- (void)rightMouseDragged:(NSEvent *)e	{ [self mouseDragged:e]; }
- (void)otherMouseDragged:(NSEvent *)e	{ [self mouseDragged:e]; }

- (void)mouseMoved:(NSEvent *)e
{
	[self mousePosFromEvent:e];
	sendbuttons(mousebuttons, mouseX, mouseY);
}

- (void)scrollWheel:(NSEvent *)e
{
	CGFloat dyw = [e scrollingDeltaY];

	[self mousePosFromEvent:e];
	if(dyw == 0)
		return;
	sendbuttons(dyw > 0 ? 8 : 16, mouseX, mouseY);
	sendbuttons(mousebuttons, mouseX, mouseY);
}
@end

@interface InfernoAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation InfernoAppDelegate
- (void)windowWillStartLiveResize:(NSNotification *)note
{
	(void)note;
	live_resizing = 1;
	wm_notify_generation++;	/* cancel debounce; notify on end */
}

- (void)windowDidEndLiveResize:(NSNotification *)note
{
	(void)note;
	live_resizing = 0;
	flush_wm_notify();
}

- (void)windowDidResize:(NSNotification *)note
{
	NSRect r;
	int w, h;

	(void)note;
	if(view == nil || !readybit || live_resizing || miniaturized || fullscreen_transition)
		return;
	r = [view bounds];
	w = (int)r.size.width;
	h = (int)r.size.height;
	/* setFrameSize already schedules on real size changes; ignore echoes. */
	if(w == dx && h == dy)
		return;
	schedule_wm_notify();
}

- (void)windowWillMiniaturize:(NSNotification *)note
{
	(void)note;
	/*
	 * Push a fresh layer frame before the dock snapshot / animation.
	 * Otherwise AppKit often shows the window background grey.
	 */
	if(view != nil){
		present_dirty = 1;
		present_softscreen();
	}
	miniaturized = 1;
	wm_notify_generation++;	/* do not reshape to transient dock sizes */
}

- (void)windowDidDeminiaturize:(NSNotification *)note
{
	NSRect r;
	(void)note;
	miniaturized = 0;
	/*
	 * Softscreen was preserved across miniaturize.  Redisplay only when
	 * the content size is unchanged — a same-size wm reshape replaces
	 * every client window with an empty placeholder (apps "disappear").
	 */
	if(view != nil){
		present_dirty = 1;
		present_softscreen();
		r = [view bounds];
		if((int)r.size.width != dx || (int)r.size.height != dy)
			flush_wm_notify();
	}
}

- (void)windowWillEnterFullScreen:(NSNotification *)note
{
	(void)note;
	fullscreen_transition = 1;
	wm_notify_generation++;
}

- (void)windowDidEnterFullScreen:(NSNotification *)note
{
	(void)note;
	fullscreen_transition = 0;
	flush_wm_notify();
}

- (void)windowWillExitFullScreen:(NSNotification *)note
{
	(void)note;
	fullscreen_transition = 1;
	wm_notify_generation++;
}

- (void)windowDidExitFullScreen:(NSNotification *)note
{
	(void)note;
	fullscreen_transition = 0;
	flush_wm_notify();
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	(void)sender;
	return NO;	/* Inferno may still be running headless */
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
	(void)sender;
	win = nil;
	view = nil;
	/* AppKit thread: cleanexit avoids touching nil up, restores tty. */
	cleanexit(0);
	return NSTerminateNow;
}

- (void)windowWillClose:(NSNotification *)note
{
	(void)note;
	win = nil;
	view = nil;
	/*
	 * Do not call cleanexit/_exit on the AppKit thread while emu
	 * worker threads may hold locks — that can beachball instead of
	 * quitting.  Detach and exit from another thread.
	 */
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		cleanexit(0);
	});
}
@end

static void
setupmenu(void)
{
	NSMenu *menubar, *appmenu, *viewmenu;
	NSMenuItem *appitem, *viewitem, *quit, *fs;

	menubar = [[NSMenu alloc] init];
	appitem = [[NSMenuItem alloc] init];
	[menubar addItem:appitem];

	viewitem = [[NSMenuItem alloc] init];
	[menubar addItem:viewitem];
	[NSApp setMainMenu:menubar];

	appmenu = [[NSMenu alloc] init];
	quit = [[NSMenuItem alloc] initWithTitle:@"Quit Inferno"
		action:@selector(terminate:)
		keyEquivalent:@"q"];
	[appmenu addItem:quit];
	[appitem setSubmenu:appmenu];

	viewmenu = [[NSMenu alloc] initWithTitle:@"View"];
	fs = [[NSMenuItem alloc] initWithTitle:@"Enter Full Screen"
		action:@selector(toggleFullScreen:)
		keyEquivalent:@"f"];
	[fs setKeyEquivalentModifierMask:
		NSEventModifierFlagControl | NSEventModifierFlagCommand];
	[viewmenu addItem:fs];
	[viewitem setSubmenu:viewmenu];
}

static void
createwindow(void)
{
	NSRect rect;
	NSUInteger style;
	static InfernoAppDelegate *delegate;

	if(win != nil)
		return;

	if(delegate == nil) {
		delegate = [[InfernoAppDelegate alloc] init];
		[NSApp setDelegate:delegate];
	}
	setupmenu();

	style = NSWindowStyleMaskTitled
		| NSWindowStyleMaskClosable
		| NSWindowStyleMaskMiniaturizable
		| NSWindowStyleMaskResizable;
	rect = NSMakeRect(30, 60, dx, dy);
	win = [[NSWindow alloc] initWithContentRect:rect
		styleMask:style
		backing:NSBackingStoreBuffered
		defer:NO];
	[win setTitle:@"Inferno"];
	[win setAcceptsMouseMovedEvents:YES];
	[win setReleasedWhenClosed:NO];
	[win setDelegate:(id)delegate];
	[win setOpaque:YES];
	/* Match Soft Plan9 Paper so any host clear is not grey-on-paper flash. */
	[win setBackgroundColor:[NSColor colorWithCalibratedRed:PaperR/255.0
		green:PaperG/255.0 blue:PaperB/255.0 alpha:1.0]];
	[win setContentMinSize:NSMakeSize(dx/2, dy/2)];
	[win setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

	view = [[InfernoView alloc] initWithFrame:NSMakeRect(0, 0, dx, dy)];
	/*
	 * Metal CAMetalLayer presents the softscreen.  Flushoff on wmclient
	 * windows stops mid-frame presents; Flushnow coalesces onto the main
	 * queue without waiting for vsync.
	 */
	if(metal_init() < 0)
		sysfatal("metal_init: no Metal device/pipeline");
	mtl_layer = (CAMetalLayer *)view.layer;
	if(mtl_layer == nil || ![mtl_layer isKindOfClass:[CAMetalLayer class]]){
		[view setWantsLayer:YES];
		mtl_layer = [CAMetalLayer layer];
		view.layer = mtl_layer;
	}
	mtl_layer.device = mtl_device;
	mtl_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	mtl_layer.framebufferOnly = YES;
	mtl_layer.contentsScale = 1.0;	/* 1 Inferno pixel = 1 point */
	mtl_layer.opaque = YES;
	mtl_layer.drawableSize = CGSizeMake(dx, dy);
	[view setWantsLayer:YES];
	[win setContentView:view];
	[win makeFirstResponder:view];
	[win setContentSize:NSMakeSize(dx, dy)];
	[view viewDidChangeBackingProperties];
	[win center];
	[win makeKeyAndOrderFront:nil];
	[NSApp activateIgnoringOtherApps:YES];
	present_dirty = 1;
	present_softscreen();

}

void
screeninit(void)
{
	dx = Xsize;
	dy = Ysize;
	if(dx <= 0)
		dx = 1024;
	if(dy <= 0)
		dy = 768;

	gscreen = allocmemimage(Rect(0, 0, dx, dy), XBGR32);
	if(gscreen == nil)
		sysfatal("allocmemimage: %r");
	fillscreen(gscreen, PaperPix);

	/* Window must be created on the AppKit main thread */
	dispatch_sync(dispatch_get_main_queue(), ^{
		createwindow();
		readybit = 1;
		Wakeup(&rend);
	});
	Sleep(&rend, isready, nil);
}

void
flushmemscreen(Rectangle r)
{
	if(r.max.x < r.min.x || r.max.y < r.min.y)
		return;
	if(view == nil)
		return;
	if(gscreen != nil && rectclip(&r, gscreen->r)){
		if(!soft_upload_valid){
			soft_upload = r;
			soft_upload_valid = 1;
		}else
			combinerect(&soft_upload, r);
	}
	/* Coalesce onto one AppKit/Metal present. */
	mark_view_dirty();
}

uchar*
attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen)
{
	if(!triedscreen) {
		triedscreen = 1;
		screeninit();
	}
	*r = gscreen->r;
	*chan = gscreen->chan;
	*depth = gscreen->depth;
	*width = gscreen->width;
	*softscreen = 1;
	return gscreen->data->bdata;
}

void
getcolor(ulong i, ulong *r, ulong *g, ulong *b)
{
	*r = *g = *b = i;
}

void
setcolor(ulong index, ulong r, ulong g, ulong b)
{
	USED(index); USED(r); USED(g); USED(b);
}

char*
clipread(void)
{
	__block char *q = nil;

	dispatch_sync(dispatch_get_main_queue(), ^{
		NSString *s;
		char *p;
		NSUInteger n;

		@autoreleasepool {
			s = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
			if(s == nil)
				return;
			n = [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
			if(n >= sizeof snarf)
				n = sizeof snarf - 1;
			memcpy(snarf, [s UTF8String], n);
			snarf[n] = 0;
			for(p = snarf; *p; p++)
				if(*p == '\r')
					*p = '\n';
			q = strdup(snarf);
		}
	});
	return q;
}

int
clipwrite(char *buf)
{
	__block int ok = 0;

	if(buf == nil)
		return 0;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSString *s;

		@autoreleasepool {
			s = [NSString stringWithUTF8String:buf];
			if(s == nil)
				return;
			[[NSPasteboard generalPasteboard] clearContents];
			ok = [[NSPasteboard generalPasteboard] setString:s forType:NSPasteboardTypeString] ? 1 : 0;
		}
	});
	return ok;
}

void
setpointer(int x, int y)
{
	__block NSPoint sp;
	CGPoint cgp;
	CGFloat screenh;

	if(win == nil || view == nil || dx <= 0 || dy <= 0)
		return;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSRect b = [view bounds];
		NSPoint vp, wp;

		/* Inverse of mousePosFromEvent: softscreen → view. */
		vp = NSMakePoint((x + 0.5) * b.size.width / dx,
			(y + 0.5) * b.size.height / dy);
		wp = [view convertPoint:vp toView:nil];
		sp = [win convertPointToScreen:wp];
	});
	screenh = CGDisplayBounds(CGMainDisplayID()).size.height;
	cgp.x = sp.x;
	cgp.y = screenh - sp.y;
	CGWarpMouseCursorPosition(cgp);
}

void
drawcursor(Drawcursor *c)
{
	int h, bpl, w;
	uchar *bc, *bs;
	Rectangle ir;

	if(c == nil || c->data == nil){
		dispatch_async(dispatch_get_main_queue(), ^{
			customcursor = nil;
			if(view)
				[[view window] invalidateCursorRectsForView:view];
			[[NSCursor arrowCursor] set];
		});
		return;
	}

	ir.min.x = c->minx;
	ir.min.y = c->miny;
	ir.max.x = c->maxx;
	ir.max.y = c->maxy;
	bpl = bytesperline1(ir);
	h = (c->maxy - c->miny) / 2;
	if(h <= 0 || bpl <= 0)
		return;
	w = c->maxx - c->minx;
	if(w > 64)
		w = 64;
	if(h > 64)
		h = 64;

	bc = c->data;
	bs = c->data + h * bpl;

	/* Build RGBA: mask=set|clr, color from set (fg black / bg white), like X11. */
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSBitmapImageRep *rep;
		NSImage *img;
		NSCursor *nc;
		uchar *px;
		int ii, jj, b, mbit;
		int hotx, hoty;

		rep = [[NSBitmapImageRep alloc]
			initWithBitmapDataPlanes:nil
			pixelsWide:w
			pixelsHigh:h
			bitsPerSample:8
			samplesPerPixel:4
			hasAlpha:YES
			isPlanar:NO
			colorSpaceName:NSCalibratedRGBColorSpace
			bytesPerRow:w * 4
			bitsPerPixel:32];
		if(rep == nil)
			return;
		px = [rep bitmapData];
		memset(px, 0, (size_t)w * h * 4);
		for(ii = 0; ii < h; ii++){
			for(jj = 0; jj < w; jj++){
				b = jj / 8;
				mbit = 0x80 >> (jj & 7);
				if(b >= bpl)
					break;
				if((bs[ii*bpl + b] | bc[ii*bpl + b]) & mbit){
					uchar *p = px + (ii * w + jj) * 4;
					if(bs[ii*bpl + b] & mbit)
						p[0] = p[1] = p[2] = 0;	/* black */
					else
						p[0] = p[1] = p[2] = 255;	/* white */
					p[3] = 255;
				}
			}
		}
		img = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
		[img addRepresentation:rep];
		hotx = -c->hotx;
		hoty = -c->hoty;
		if(hotx < 0) hotx = 0;
		if(hoty < 0) hoty = 0;
		if(hotx >= w) hotx = w - 1;
		if(hoty >= h) hoty = h - 1;
		nc = [[NSCursor alloc] initWithImage:img hotSpot:NSMakePoint(hotx, hoty)];
		customcursor = nc;
		[nc set];
		if(view)
			[[view window] invalidateCursorRectsForView:view];
	});
}
