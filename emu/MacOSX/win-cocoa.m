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
#include <math.h>
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
static Lock	present_lock;

/* Metal softscreen present (CAMetalLayer) + direct draw3d GPU geom. */
static id<MTLDevice>		mtl_device;
static id<MTLCommandQueue>	mtl_queue;
static id<MTLRenderPipelineState>	mtl_pipe;		/* softscreen / under blit */
static id<MTLRenderPipelineState>	mtl_overlay_pipe;	/* softscreen where ≠ under */
static id<MTLRenderPipelineState>	mtl_geom_pipe;		/* BGRA8+depth lines+tris+points */
static id<MTLRenderPipelineState>	mtl_sprite_pipe;	/* textured quads + depth + blend */
static id<MTLDepthStencilState>	mtl_depth_on;
static id<MTLDepthStencilState>	mtl_depth_off;
static id<MTLTexture>		mtl_tex;		/* softscreen upload */
static id<MTLTexture>		mtl_under;		/* softscreen at 3D→2D flush */
static id<MTLTexture>		mtl_depth;
static id<MTLTexture>		mtl_copy_scratch;
static id<MTLBuffer>		mtl_upload_buf[3];
static id<MTLCommandBuffer>	mtl_upload_pending[3];
static int	mtl_upload_len;
static int	mtl_upload_next;
static id<MTLBuffer>		mtl_vertex_buf[3];
static id<MTLCommandBuffer>	mtl_vertex_pending[3];
static id<MTLCommandBuffer>	mtl_vertex_cmd;
static int	mtl_vertex_slot = -1;
static int	mtl_vertex_off;
static int	mtl_tex_w, mtl_tex_h;
static int	mtl_under_w, mtl_under_h;
static int	mtl_depth_w, mtl_depth_h;
static int	mtl_copy_w, mtl_copy_h;
static int	mtl_tex_fresh;	/* new soft tex: must full-upload before dirty */
static CAMetalLayer	*mtl_layer;
enum { SoftTile = 64 };
enum { MaxGPUCopies = 256 };
typedef struct GPUCopy GPUCopy;
struct GPUCopy {
	Rectangle	dst;
	Rectangle	src;
	int	armed;
	ulong	saved;
};
static uchar	*soft_dirty;
static uchar	*soft_upload_dirty;
static int	soft_ntx, soft_nty;
static Lock	soft_dirty_lock;
static GPUCopy	gpu_copies[MaxGPUCopies];
static int	ngpu_copies;
static GPUCopy	present_copies[MaxGPUCopies];
static int	npresent_copies;
static int	damage_before_copy;
static uvlong	metal_upload_bytes;
static uvlong	metal_copy_bytes;
static uvlong	metal_saved_bytes;
static uvlong	metal_copy_begins;
static uvlong	metal_precopy_dirty_bytes;
static uvlong	metal_precopy_clean_bytes;
static uvlong	metal_copy_notes;
static uvlong	metal_copy_rejected;
static uvlong	metal_copy_armed;
static uvlong	metal_copy_cancelled;
static int	metal_stat_frames;
static id<MTLBuffer>	metal_validate_buf;
static uchar	*metal_validate_cpu;
static int	metal_validate_len;
static int	metal_validate_stride;
static int	mtl_have_under;	/* snapshot taken; composite HUD over 3D */
static int	mtl_zenable;
static int	mtl_zclear;	/* clear depth on next geom pass */
static Memimage	*mtl_solidsrc;	/* 1×1 for emergency soft fill of GPU tris */

enum {
	MaxGPULines = 16384,
	MaxGPUTriVerts = 49152,	/* 16384 triangles × 3 packed verts */
	MaxGPUSprites = 512,
	MaxSpriteTexCache = 64,	/* reuse uploads across 'j' draws */
	EllipseSegs = 48,
};

typedef struct GPULine GPULine;
struct GPULine {
	float	x0, y0, z0, x1, y1, z1;
	float	r, g, b, a;
	int	thick;
};

/*
 * Packed screen-space vertex (must match Metal LIn: 7 floats, no padding).
 * z is Metal depth in [0,1] (not eye-z). Used for lines and fill tris.
 */
typedef struct GPUVert GPUVert;
struct GPUVert {
	float	x, y, z, r, g, b, a;
};

/* Textured sprite vert: must match Metal TIn (9 floats). */
typedef struct GPUTexVert GPUTexVert;
struct GPUTexVert {
	float	x, y, z, u, v, r, g, b, a;
};

typedef struct GPUSprite GPUSprite;
struct GPUSprite {
	GPUTexVert	v[6];	/* two tris */
	id<MTLTexture>	tex;
};

/* LRU cache of uploaded sprite textures (keyed by Memimage + mask + size). */
typedef struct SpriteTexCache SpriteTexCache;
struct SpriteTexCache {
	Memimage	*img;
	Memimage	*mask;
	void	*bdata;	/* img->data->bdata — catch pointer reuse */
	int	w, h;
	u32	tick;
	id<MTLTexture>	tex;
};

/* Screen-space geometry held until present (no Memimage writeback). */
static GPULine	*glines;
static int	nglines;
static int	maxglines;
static GPULine	*present_lines;
static GPUVert	*present_line_verts;
static GPUVert	*present_tri_verts;
static GPUVert	gtriverts[MaxGPUTriVerts];
static int	ngtriverts;
static GPUSprite	gsprites[MaxGPUSprites];
static int	ngsprites;
static SpriteTexCache	sprtexcache[MaxSpriteTexCache];
static int	nsprtexcache;
static u32	sprtex_tick;
static Lock	mtl_geom_lock;

/* Soft Plan9 Paper desktop (#C4C0B4); must match appl/wm/wm.b Background. */
enum {
	PaperR = 0xC4,
	PaperG = 0xC0,
	PaperB = 0xB4,
	/* XBGR32 little-endian memory: R,G,B,X */
	PaperPix = (0xFF<<24) | (PaperB<<16) | (PaperG<<8) | PaperR,
};

/*
 * Vertex layouts stay tightly packed floats (no float2/float4 in the
 * buffer structs — Metal would insert padding and break the C stride).
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
	"/* Softscreen overlay: keep pixels that differ from the under snapshot. */\n"
	"fragment float4 foverlay(VOut in [[stage_in]],\n"
	"    texture2d<float> soft [[texture(0)]],\n"
	"    texture2d<float> under [[texture(1)]],\n"
	"    sampler samp [[sampler(0)]]) {\n"
	"  float4 s = soft.sample(samp, in.uv);\n"
	"  float4 u = under.sample(samp, in.uv);\n"
	"  float3 d = abs(s.rgb - u.rgb);\n"
	"  if(d.r < 1.0/255.0 && d.g < 1.0/255.0 && d.b < 1.0/255.0)\n"
	"    discard_fragment();\n"
	"  return s;\n"
	"}\n"
	"struct LIn { float x, y, z, r, g, b, a; };\n"
	"struct LOut { float4 pos [[position]]; float4 color; float psize [[point_size]]; };\n"
	"vertex LOut vlmain(uint vid [[vertex_id]],\n"
	"    constant LIn *v [[buffer(0)]],\n"
	"    constant float2 &wh [[buffer(1)]]) {\n"
	"  LIn i = v[vid];\n"
	"  LOut o;\n"
	"  float2 ndc = float2(i.x/wh.x*2.0-1.0, 1.0-i.y/wh.y*2.0);\n"
	"  o.pos = float4(ndc, i.z, 1);\n"
	"  o.color = float4(i.r, i.g, i.b, i.a);\n"
	"  o.psize = 2.0;\n"
	"  return o;\n"
	"}\n"
	"fragment float4 flmain(LOut in [[stage_in]]) { return in.color; }\n"
	"struct TIn { float x, y, z, u, v, r, g, b, a; };\n"
	"struct TOut { float4 pos [[position]]; float2 uv; float4 color; };\n"
	"vertex TOut vtmain(uint vid [[vertex_id]],\n"
	"    constant TIn *v [[buffer(0)]],\n"
	"    constant float2 &wh [[buffer(1)]]) {\n"
	"  TIn i = v[vid];\n"
	"  TOut o;\n"
	"  float2 ndc = float2(i.x/wh.x*2.0-1.0, 1.0-i.y/wh.y*2.0);\n"
	"  o.pos = float4(ndc, i.z, 1);\n"
	"  o.uv = float2(i.u, i.v);\n"
	"  o.color = float4(i.r, i.g, i.b, i.a);\n"
	"  return o;\n"
	"}\n"
	"fragment float4 ftmain(TOut in [[stage_in]],\n"
	"    texture2d<float> tex [[texture(0)]],\n"
	"    sampler samp [[sampler(0)]]) {\n"
	"  float4 t = tex.sample(samp, in.uv);\n"
	"  float4 c = t * in.color;\n"
	"  if(c.a < 1.0/255.0) discard_fragment();\n"
	"  return c;\n"
	"}\n";

/* Assigned from metal_init; declared in emu/port/devdraw.c */
extern int	(*gpudrawline)(Memimage*, Point, Point, int, Memimage*, int, float, float);
extern int	(*gpudrawfillpoly)(Memimage*, Point*, float*, int, Memimage*, int, float);
extern int	(*gpudrawplot)(Memimage*, Point, Memimage*, int, float);
extern int	(*gpudrawsprite)(Memimage*, Point, int, int, float, Memimage*, Memimage*, float, int);
extern int	(*gpudrawellipse)(Memimage*, Point, int, int, int, int, Memimage*, int, float);
extern void	(*gpudrawflush)(void);
extern void	(*gpudrawreadback)(void);
extern void	(*gpudrawzclear)(void);
extern void	(*gpudrawzenable)(int);
extern void	(*gpudrawdamage)(Rectangle);
extern int	(*gpudrawflushdamage)(Rectangle);
extern void	(*memdrawcopy)(Memimage*, Rectangle, Memimage*, Rectangle);

static void	metal_flush_geom(void);
static void	metal_zclear(void);
static void	metal_set_zenable(int);
static int	metal_queue_line(Memimage*, Point, Point, int, Memimage*, int, float, float);
static int	metal_queue_fillpoly(Memimage*, Point*, float*, int, Memimage*, int, float);
static int	metal_queue_plot(Memimage*, Point, Memimage*, int, float);
static int	metal_queue_sprite(Memimage*, Point, int, int, float, Memimage*, Memimage*, float, int);
static int	metal_queue_ellipse(Memimage*, Point, int, int, int, int, Memimage*, int, float);
static void	metal_present_lines(id<MTLCommandBuffer>, id<MTLTexture>, id<MTLTexture>, int, int);
static void	metal_present_tris(id<MTLCommandBuffer>, id<MTLTexture>, id<MTLTexture>, int, int);
static void	metal_present_sprites(id<MTLCommandBuffer>, id<MTLTexture>, id<MTLTexture>, int, int);
static void	soft_burn_tris(GPUVert*, int);
static int	metal_tri_reserve(int);
static void	metal_readback_geom(void);
static float	eye_to_depth(float);
static void	metal_clear_sprite_tex_cache(void);
static id<MTLTexture>	metal_sprite_tex(Memimage*, Memimage*);
static void	mark_view_dirty(void);
static void	metal_damage_note(Rectangle);
static int	metal_flush_damage(Rectangle);
static void	metal_copy_note(Memimage*, Rectangle, Memimage*, Rectangle);
static void	metal_copy_begin(Memimage*, Rectangle, Memimage*, Rectangle);
static void	metal_replay_copies(id<MTLCommandBuffer>, id<MTLTexture>, int, int);

static void
invalidate_mtl_tex(void)
{
	mtl_tex = nil;
	mtl_tex_w = mtl_tex_h = 0;
	mtl_tex_fresh = 0;
	mtl_under = nil;
	mtl_under_w = mtl_under_h = 0;
	mtl_depth = nil;
	mtl_depth_w = mtl_depth_h = 0;
	mtl_have_under = 0;
	metal_clear_sprite_tex_cache();
	lock(&soft_dirty_lock);
	if(soft_dirty != nil){
		memset(soft_dirty, 0, soft_ntx * soft_nty);
		memset(soft_upload_dirty, 0, soft_ntx * soft_nty);
	}
	unlock(&soft_dirty_lock);
}

static int
metal_init(void)
{
	NSError *err;
	id<MTLLibrary> lib;
	MTLRenderPipelineDescriptor *pd;
	MTLDepthStencilDescriptor *ds;

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

	pd = [[MTLRenderPipelineDescriptor alloc] init];
	pd.vertexFunction = [lib newFunctionWithName:@"vmain"];
	pd.fragmentFunction = [lib newFunctionWithName:@"foverlay"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	pd.colorAttachments[0].blendingEnabled = NO;
	mtl_overlay_pipe = [mtl_device newRenderPipelineStateWithDescriptor:pd error:&err];
	if(mtl_overlay_pipe == nil)
		return -1;

	/* Lines + filled tris + points onto drawable with optional depth. */
	pd = [[MTLRenderPipelineDescriptor alloc] init];
	pd.vertexFunction = [lib newFunctionWithName:@"vlmain"];
	pd.fragmentFunction = [lib newFunctionWithName:@"flmain"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	pd.colorAttachments[0].blendingEnabled = NO;
	pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	mtl_geom_pipe = [mtl_device newRenderPipelineStateWithDescriptor:pd error:&err];
	if(mtl_geom_pipe == nil)
		return -1;

	/* Textured sprites: sample + alpha discard, depth tested. */
	pd = [[MTLRenderPipelineDescriptor alloc] init];
	pd.vertexFunction = [lib newFunctionWithName:@"vtmain"];
	pd.fragmentFunction = [lib newFunctionWithName:@"ftmain"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	pd.colorAttachments[0].blendingEnabled = YES;
	pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
	pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	mtl_sprite_pipe = [mtl_device newRenderPipelineStateWithDescriptor:pd error:&err];
	if(mtl_sprite_pipe == nil)
		return -1;

	ds = [[MTLDepthStencilDescriptor alloc] init];
	ds.depthCompareFunction = MTLCompareFunctionLessEqual;
	ds.depthWriteEnabled = YES;
	mtl_depth_on = [mtl_device newDepthStencilStateWithDescriptor:ds];
	ds = [[MTLDepthStencilDescriptor alloc] init];
	ds.depthCompareFunction = MTLCompareFunctionAlways;
	ds.depthWriteEnabled = NO;
	mtl_depth_off = [mtl_device newDepthStencilStateWithDescriptor:ds];
	if(mtl_depth_on == nil || mtl_depth_off == nil)
		return -1;

	gpudrawline = metal_queue_line;
	gpudrawfillpoly = metal_queue_fillpoly;
	gpudrawplot = metal_queue_plot;
	gpudrawsprite = metal_queue_sprite;
	gpudrawellipse = metal_queue_ellipse;
	gpudrawflush = metal_flush_geom;
	gpudrawreadback = metal_readback_geom;
	gpudrawzclear = metal_zclear;
	gpudrawzenable = metal_set_zenable;
	gpudrawdamage = metal_damage_note;
	gpudrawflushdamage = metal_flush_damage;
	memdrawcopybegin = metal_copy_begin;
	memdrawcopy = metal_copy_note;
	mtl_zclear = 1;
	return 0;
}

static float
eye_to_depth(float ez)
{
	float planez;

	/*
	 * Camera looks toward −Z, while the software buffer compares plane
	 * depth (-eye-z) with "smaller wins".  atan maps the complete positive
	 * and negative range monotonically into [0,1], preserving that ordering
	 * without the old 256-unit saturation collisions.
	 */
	planez = -ez;
	return 0.5f + atanf(planez) / (float)M_PI;
}

static void
metal_zclear(void)
{
	mtl_zclear = 1;
}

static void
metal_set_zenable(int on)
{
	mtl_zenable = on != 0;
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
	td.storageMode = MTLStorageModePrivate;
	mtl_tex = [mtl_device newTextureWithDescriptor:td];
	mtl_tex_w = pw;
	mtl_tex_h = ph;
	/* Virgin tex has undefined texels; dirty-only upload would half-frame. */
	mtl_tex_fresh = 1;
	return mtl_tex;
}

static id<MTLTexture>
metal_under_tex(int pw, int ph)
{
	MTLTextureDescriptor *td;

	if(mtl_under != nil && mtl_under_w == pw && mtl_under_h == ph)
		return mtl_under;
	td = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		width:pw height:ph mipmapped:NO];
	td.usage = MTLTextureUsageShaderRead;
	td.storageMode = MTLStorageModePrivate;
	mtl_under = [mtl_device newTextureWithDescriptor:td];
	mtl_under_w = pw;
	mtl_under_h = ph;
	return mtl_under;
}

static id<MTLTexture>
metal_depth_tex(int pw, int ph)
{
	MTLTextureDescriptor *td;

	if(mtl_depth != nil && mtl_depth_w == pw && mtl_depth_h == ph)
		return mtl_depth;
	td = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
		width:pw height:ph mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget;
	td.storageMode = MTLStorageModePrivate;
	mtl_depth = [mtl_device newTextureWithDescriptor:td];
	mtl_depth_w = pw;
	mtl_depth_h = ph;
	mtl_zclear = 1;
	return mtl_depth;
}

static int
metal_damage_map(int pw, int ph)
{
	int ntx, nty;
	uchar *p, *q;

	ntx = (pw + SoftTile - 1) / SoftTile;
	nty = (ph + SoftTile - 1) / SoftTile;
	lock(&soft_dirty_lock);
	if(ntx == soft_ntx && nty == soft_nty && soft_dirty != nil){
		unlock(&soft_dirty_lock);
		return 0;
	}
	p = malloc(ntx * nty);
	q = malloc(ntx * nty);
	if(p == nil || q == nil){
		free(p);
		free(q);
		unlock(&soft_dirty_lock);
		return -1;
	}
	free(soft_dirty);
	free(soft_upload_dirty);
	soft_dirty = p;
	soft_upload_dirty = q;
	soft_ntx = ntx;
	soft_nty = nty;
	memset(soft_dirty, 0, ntx * nty);
	memset(soft_upload_dirty, 0, ntx * nty);
	unlock(&soft_dirty_lock);
	return 0;
}

static int
rectsoverlap(Rectangle a, Rectangle b)
{
	return a.min.x < b.max.x && b.min.x < a.max.x
		&& a.min.y < b.max.y && b.min.y < a.max.y;
}

static int
rectcontains(Rectangle a, Rectangle b)
{
	return a.min.x <= b.min.x && a.min.y <= b.min.y
		&& a.max.x >= b.max.x && a.max.y >= b.max.y;
}

static void
metal_mark_tiles(Rectangle r, int value, int fullonly)
{
	int tx0, tx1, ty0, ty1, tx, ty;
	Rectangle tr;

	if(gscreen == nil || !rectclip(&r, gscreen->r))
		return;
	tx0 = (r.min.x - gscreen->r.min.x) / SoftTile;
	ty0 = (r.min.y - gscreen->r.min.y) / SoftTile;
	tx1 = (r.max.x - gscreen->r.min.x + SoftTile - 1) / SoftTile;
	ty1 = (r.max.y - gscreen->r.min.y + SoftTile - 1) / SoftTile;
	for(ty = ty0; ty < ty1; ty++)
		for(tx = tx0; tx < tx1; tx++){
			tr = Rect(gscreen->r.min.x + tx*SoftTile,
				gscreen->r.min.y + ty*SoftTile,
				gscreen->r.min.x + (tx+1)*SoftTile,
				gscreen->r.min.y + (ty+1)*SoftTile);
			if(fullonly && !rectcontains(r, tr))
				continue;
			soft_dirty[ty*soft_ntx + tx] = value;
		}
}

static void
metal_damage_note(Rectangle r)
{
	int i, nx, ny;

	if(ngpu_copies == 0){
		damage_before_copy = 1;
		return;
	}
	if(gscreen == nil || metal_damage_map(Dx(gscreen->r), Dy(gscreen->r)) < 0){
		mtl_tex_fresh = 1;
		return;
	}
	lock(&soft_dirty_lock);
	metal_mark_tiles(r, 1, 0);
	for(i = 0; i < ngpu_copies; i++){
		if(!gpu_copies[i].armed && rectcontains(r, gpu_copies[i].dst)){
			metal_mark_tiles(gpu_copies[i].dst, 0, 1);
			gpu_copies[i].armed = 1;
			nx = gpu_copies[i].dst.max.x/SoftTile
				- (gpu_copies[i].dst.min.x+SoftTile-1)/SoftTile;
			ny = gpu_copies[i].dst.max.y/SoftTile
				- (gpu_copies[i].dst.min.y+SoftTile-1)/SoftTile;
			gpu_copies[i].saved = nx > 0 && ny > 0
				? (ulong)nx*ny*SoftTile*SoftTile*4 : 0;
			metal_copy_armed++;
		}else if(gpu_copies[i].armed &&
		    (rectsoverlap(r, gpu_copies[i].src) || rectsoverlap(r, gpu_copies[i].dst))){
			metal_mark_tiles(gpu_copies[i].dst, 1, 0);
			gpu_copies[i].armed = -1;
			metal_copy_cancelled++;
		}
	}
	unlock(&soft_dirty_lock);
}

static void
metal_copy_begin(Memimage *dst, Rectangle dr, Memimage *src, Rectangle sr)
{
	uchar *base, *p;
	vlong off;
	int bpl, tx0, tx1, ty0, ty1, tx, ty, x, y;
	Rectangle r, tr;

	USED(dst);
	USED(dr.min.x);
	metal_copy_begins++;
	if(getenv("INFERNO_METAL_STATS") == nil)
		return;
	if(gscreen == nil || gscreen->data == nil || src == nil || src->data == nil
	|| src->data->bdata != gscreen->data->bdata || src->depth != 32
	|| metal_damage_map(Dx(gscreen->r), Dy(gscreen->r)) < 0)
		return;
	base = byteaddr(gscreen, gscreen->r.min);
	p = byteaddr(src, sr.min);
	off = p-base;
	if(off < 0)
		return;
	bpl = gscreen->width*sizeof(u32);
	y = off/bpl;
	x = (off%bpl)/4;
	r = Rect(gscreen->r.min.x+x, gscreen->r.min.y+y,
		gscreen->r.min.x+x+Dx(sr), gscreen->r.min.y+y+Dy(sr));
	if(!rectclip(&r, gscreen->r))
		return;
	tx0 = (r.min.x-gscreen->r.min.x)/SoftTile;
	ty0 = (r.min.y-gscreen->r.min.y)/SoftTile;
	tx1 = (r.max.x-gscreen->r.min.x+SoftTile-1)/SoftTile;
	ty1 = (r.max.y-gscreen->r.min.y+SoftTile-1)/SoftTile;
	lock(&soft_dirty_lock);
	for(ty = ty0; ty < ty1; ty++)
		for(tx = tx0; tx < tx1; tx++){
			tr = Rect(gscreen->r.min.x+tx*SoftTile,
				gscreen->r.min.y+ty*SoftTile,
				gscreen->r.min.x+(tx+1)*SoftTile,
				gscreen->r.min.y+(ty+1)*SoftTile);
			if(!rectclip(&tr, r))
				continue;
			if(soft_dirty[ty*soft_ntx+tx])
				metal_precopy_dirty_bytes += Dx(tr)*Dy(tr)*4;
			else
				metal_precopy_clean_bytes += Dx(tr)*Dy(tr)*4;
		}
	unlock(&soft_dirty_lock);
}

static void
metal_copy_note(Memimage *dst, Rectangle dr, Memimage *src, Rectangle sr)
{
	GPUCopy *c;
	int i;

	metal_copy_notes++;
	if(gscreen == nil || dst == nil || src == nil
	|| dst->data != gscreen->data || src->data != gscreen->data
	|| Dx(dr) != Dx(sr) || Dy(dr) != Dy(sr) || damage_before_copy){
		metal_copy_rejected++;
		return;
	}
	lock(&soft_dirty_lock);
	for(i = 0; i < ngpu_copies; i++)
		if(rectsoverlap(dr, gpu_copies[i].src) || rectsoverlap(dr, gpu_copies[i].dst)
		|| rectsoverlap(sr, gpu_copies[i].src) || rectsoverlap(sr, gpu_copies[i].dst))
		{
			metal_mark_tiles(gpu_copies[i].dst, 1, 0);
			gpu_copies[i].armed = -1;
		}
	if(ngpu_copies < MaxGPUCopies){
		c = &gpu_copies[ngpu_copies++];
		c->dst = dr;
		c->src = sr;
		c->armed = 0;
		c->saved = 0;
	}
	unlock(&soft_dirty_lock);
}

static int
metal_flush_damage(Rectangle r)
{
	(void)r;
	if(ngpu_copies == 0){
		damage_before_copy = 0;
		return 0;
	}
	mark_view_dirty();
	return 1;
}

static void
metal_replay_copies(id<MTLCommandBuffer> cmd, id<MTLTexture> tex, int pw, int ph)
{
	int i, w, h;
	id<MTLBlitCommandEncoder> blit;
	MTLTextureDescriptor *td;
	GPUCopy *c;

	if(npresent_copies == 0 || cmd == nil || tex == nil)
		return;
	if(mtl_copy_scratch == nil || mtl_copy_w != pw || mtl_copy_h != ph){
		td = [MTLTextureDescriptor
			texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
			width:pw height:ph mipmapped:NO];
		td.usage = MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
		td.storageMode = MTLStorageModePrivate;
		mtl_copy_scratch = [mtl_device newTextureWithDescriptor:td];
		mtl_copy_w = pw;
		mtl_copy_h = ph;
	}
	if(mtl_copy_scratch == nil){
		mtl_tex_fresh = 1;
		mark_view_dirty();
		return;
	}
	blit = [cmd blitCommandEncoder];
	if(blit == nil){
		mtl_tex_fresh = 1;
		mark_view_dirty();
		return;
	}
	for(i = 0; i < npresent_copies; i++){
		c = &present_copies[i];
		w = Dx(c->src);
		h = Dy(c->src);
		metal_copy_bytes += (uvlong)w*h*4;
		metal_saved_bytes += c->saved;
		[blit copyFromTexture:tex sourceSlice:0 sourceLevel:0
			sourceOrigin:MTLOriginMake(c->src.min.x, c->src.min.y, 0)
			sourceSize:MTLSizeMake(w, h, 1)
			toTexture:mtl_copy_scratch destinationSlice:0 destinationLevel:0
			destinationOrigin:MTLOriginMake(c->src.min.x, c->src.min.y, 0)];
		[blit copyFromTexture:mtl_copy_scratch sourceSlice:0 sourceLevel:0
			sourceOrigin:MTLOriginMake(c->src.min.x, c->src.min.y, 0)
			sourceSize:MTLSizeMake(w, h, 1)
			toTexture:tex destinationSlice:0 destinationLevel:0
			destinationOrigin:MTLOriginMake(c->dst.min.x, c->dst.min.y, 0)];
	}
	[blit endEncoding];
	npresent_copies = 0;
}

/* Upload dirty tile runs with screen-relative offsets.  SoftTile*4 and the
 * staging stride are 256-byte aligned, so no rectangle repacking is needed. */
static int
metal_upload_damage(id<MTLTexture> tex, int full)
{
	int bpl, pw, ph, sbpl, need, slot, tx, tx1, ty, x, y, w, h, ry, any, i;
	uchar *base, *dst, *damage, *swap;
	id<MTLBuffer> buf;
	id<MTLCommandBuffer> cmd;
	id<MTLBlitCommandEncoder> blit;

	if(tex == nil || gscreen == nil || gscreen->data == nil || gscreen->data->bdata == nil)
		return -1;
	pw = Dx(gscreen->r);
	ph = Dy(gscreen->r);
	if(metal_damage_map(pw, ph) < 0)
		return -1;
	/* Snapshot damage before touching pixels.  New flushes land in the other
	 * map and therefore cannot be erased when this upload completes. */
	lock(&soft_dirty_lock);
	swap = soft_upload_dirty;
	soft_upload_dirty = soft_dirty;
	soft_dirty = swap;
	memset(soft_dirty, 0, soft_ntx * soft_nty);
	damage = soft_upload_dirty;
	npresent_copies = 0;
	for(i = 0; !full && i < ngpu_copies; i++)
		if(gpu_copies[i].armed == 1)
			present_copies[npresent_copies++] = gpu_copies[i];
	ngpu_copies = 0;
	damage_before_copy = 0;
	unlock(&soft_dirty_lock);
	bpl = gscreen->width * (int)sizeof(u32);
	sbpl = (pw * 4 + 255) & ~255;
	need = sbpl * ph;
	base = gscreen->data->bdata;
	slot = mtl_upload_next++ % nelem(mtl_upload_buf);
	if(mtl_upload_pending[slot] != nil){
		[mtl_upload_pending[slot] waitUntilCompleted];
		mtl_upload_pending[slot] = nil;
	}
	if(mtl_upload_buf[slot] == nil || mtl_upload_len < need){
		mtl_upload_len = need;
		for(y = 0; y < nelem(mtl_upload_buf); y++){
			mtl_upload_buf[y] = [mtl_device newBufferWithLength:mtl_upload_len
				options:MTLResourceStorageModeShared];
			mtl_upload_pending[y] = nil;
		}
	}
	buf = mtl_upload_buf[slot];
	if(buf == nil)
		return -1;
	dst = [buf contents];
	cmd = [mtl_queue commandBuffer];
	if(cmd == nil)
		return -1;
	blit = [cmd blitCommandEncoder];
	if(blit == nil)
		return -1;
	any = 0;
	for(ty = 0; ty < soft_nty; ty++){
		for(tx = 0; tx < soft_ntx; ){
			if(!full && !damage[ty * soft_ntx + tx]){
				tx++;
				continue;
			}
			for(tx1 = tx + 1; tx1 < soft_ntx; tx1++)
				if(!full && !damage[ty * soft_ntx + tx1])
					break;
			x = tx * SoftTile;
			y = ty * SoftTile;
			w = tx1 * SoftTile;
			if(w > pw)
				w = pw;
			w -= x;
			h = SoftTile;
			if(y + h > ph)
				h = ph - y;
			for(ry = 0; ry < h; ry++)
				memmove(dst + (y + ry) * sbpl + x * 4,
					base + (y + ry) * bpl + x * 4, w * 4);
			[blit copyFromBuffer:buf sourceOffset:y * sbpl + x * 4
				sourceBytesPerRow:sbpl sourceBytesPerImage:sbpl * h
				sourceSize:MTLSizeMake(w, h, 1)
				toTexture:tex destinationSlice:0 destinationLevel:0
				destinationOrigin:MTLOriginMake(x, y, 0)];
			any = 1;
			metal_upload_bytes += (uvlong)w*h*4;
			tx = tx1;
		}
	}
	[blit endEncoding];
	if(!any)
		return 0;
	[cmd commit];
	mtl_upload_pending[slot] = cmd;
	return 0;
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
 * Obscured layers stay on the software memline/memfillpoly path.
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

static Memimage*
poly_pixdst(Memimage *dst, Point *pp, int n)
{
	Memlayer *l;
	int i;

	if(dst == nil || pp == nil || n < 3)
		return nil;
	l = dst->layer;
	if(l == nil)
		return dst;
	if(!l->clear)
		return nil;
	for(i = 0; i < n; i++)
		pp[i] = addpt(pp[i], l->delta);
	return l->screen->image;
}

static Memimage*
metal_solid(float r, float g, float b, float a)
{
	u32 pix;

	if(mtl_solidsrc == nil){
		mtl_solidsrc = allocmemimage(Rect(0, 0, 1, 1), XBGR32);
		if(mtl_solidsrc == nil)
			return nil;
	}
	pix = ((u32)(a * 255) << 24) | ((u32)(b * 255) << 16)
		| ((u32)(g * 255) << 8) | (u32)(r * 255);
	*(u32*)byteaddr(mtl_solidsrc, mtl_solidsrc->r.min) = pix;
	return mtl_solidsrc;
}

static void
soft_burn_tris(GPUVert *verts, int nverts)
{
	int i;
	Point pp[4];
	Memimage *src;
	GPUVert *v0, *v1, *v2;

	if(gscreen == nil)
		return;
	for(i = 0; i + 2 < nverts; i += 3){
		v0 = &verts[i];
		v1 = &verts[i+1];
		v2 = &verts[i+2];
		src = metal_solid(v0->r, v0->g, v0->b, v0->a);
		if(src == nil)
			continue;
		pp[0].x = (int)v0->x;
		pp[0].y = (int)v0->y;
		pp[1].x = (int)v1->x;
		pp[1].y = (int)v1->y;
		pp[2].x = (int)v2->x;
		pp[2].y = (int)v2->y;
		pp[3] = pp[0];
		memfillpoly(gscreen, pp, 4, ~0, src, pp[0], S);
	}
}

/* Return with the geometry lock held and room reserved for one atomic append. */
static int
metal_tri_reserve(int need)
{
	if(need < 1 || need > MaxGPUTriVerts)
		return 0;
retry:
	lock(&mtl_geom_lock);
	if(ngtriverts + need <= MaxGPUTriVerts)
		return 1;
	unlock(&mtl_geom_lock);
	mark_view_dirty();
	osyield();
	goto retry;
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
 * Direct path: GPU geom stays queued until present (no Memimage writeback).
 * On the first 2D draw after geometry, snapshot the softscreen so present can
 * put subsequent HUD over the Metal 3D layer (j/q are GPU; overlay is leftover 2D).
 */
static void
metal_flush_geom(void)
{
	int pw, ph;
	id<MTLTexture> tex, under;
	id<MTLCommandBuffer> cmd;
	id<MTLBlitCommandEncoder> blit;

	if(nglines == 0 && ngtriverts == 0 && ngsprites == 0)
		return;
	if(mtl_have_under)
		return;
	if(gscreen == nil || gscreen->data == nil || gscreen->data->bdata == nil)
		return;
	pw = Dx(gscreen->r);
	ph = Dy(gscreen->r);
	if(pw < 1 || ph < 1)
		return;
	under = metal_under_tex(pw, ph);
	tex = metal_soft_tex(pw, ph);
	if(under == nil || tex == nil)
		return;
	/* Bring the persistent soft texture current, then snapshot it entirely on
	 * the GPU.  Uploading gscreen straight into under forced a full CPU texture
	 * conversion every time 2D drawing followed queued geometry. */
	metal_upload_damage(tex, mtl_tex_fresh);
	mtl_tex_fresh = 0;
	cmd = [mtl_queue commandBuffer];
	if(cmd == nil)
		return;
	blit = [cmd blitCommandEncoder];
	if(blit == nil)
		return;
	[blit copyFromTexture:tex sourceSlice:0 sourceLevel:0
		sourceOrigin:MTLOriginMake(0, 0, 0)
		sourceSize:MTLSizeMake(pw, ph, 1)
		toTexture:under destinationSlice:0 destinationLevel:0
		destinationOrigin:MTLOriginMake(0, 0, 0)];
	[blit endEncoding];
	[cmd commit];
	mtl_have_under = 1;
}

static int
metal_vertex_data(id<MTLCommandBuffer> cmd, void *data, int n,
	id<MTLBuffer> *buf, int *off)
{
	int aligned;

	if(cmd == nil || data == nil || n <= 0)
		return -1;
	if(cmd != mtl_vertex_cmd){
		mtl_vertex_slot = (mtl_vertex_slot + 1) % nelem(mtl_vertex_buf);
		if(mtl_vertex_pending[mtl_vertex_slot] != nil){
			[mtl_vertex_pending[mtl_vertex_slot] waitUntilCompleted];
			mtl_vertex_pending[mtl_vertex_slot] = nil;
		}
		if(mtl_vertex_buf[mtl_vertex_slot] == nil)
			mtl_vertex_buf[mtl_vertex_slot] = [mtl_device
				newBufferWithLength:8*1024*1024 options:MTLResourceStorageModeShared];
		mtl_vertex_cmd = cmd;
		mtl_vertex_off = 0;
		mtl_vertex_pending[mtl_vertex_slot] = cmd;
	}
	aligned = (mtl_vertex_off + 255) & ~255;
	if(mtl_vertex_buf[mtl_vertex_slot] == nil || aligned + n > 8*1024*1024)
		return -1;
	memmove((uchar*)[mtl_vertex_buf[mtl_vertex_slot] contents] + aligned, data, n);
	*buf = mtl_vertex_buf[mtl_vertex_slot];
	*off = aligned;
	mtl_vertex_off = aligned + n;
	return 0;
}

static int
metal_present_geom(id<MTLCommandBuffer> cmd, id<MTLTexture> drawabletex,
	id<MTLTexture> depthtex, int pw, int ph, GPUVert *verts, int nv,
	MTLPrimitiveType prim)
{
	float wh[2];
	id<MTLBuffer> vbuf;
	int voff;
	id<MTLRenderCommandEncoder> enc;
	MTLRenderPassDescriptor *rp;
	MTLLoadAction zload;

	if(nv == 0 || cmd == nil || drawabletex == nil || mtl_geom_pipe == nil)
		return -1;
	if(depthtex == nil)
		return -1;
	if(metal_vertex_data(cmd, verts, sizeof(GPUVert) * nv, &vbuf, &voff) < 0)
		return -1;
	wh[0] = (float)pw;
	wh[1] = (float)ph;

	zload = mtl_zclear ? MTLLoadActionClear : MTLLoadActionLoad;
	mtl_zclear = 0;

	rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = drawabletex;
	rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.depthAttachment.texture = depthtex;
	rp.depthAttachment.loadAction = zload;
	rp.depthAttachment.storeAction = MTLStoreActionStore;
	rp.depthAttachment.clearDepth = 1.0;

	enc = [cmd renderCommandEncoderWithDescriptor:rp];
	[enc setRenderPipelineState:mtl_geom_pipe];
	[enc setDepthStencilState:mtl_zenable ? mtl_depth_on : mtl_depth_off];
	[enc setVertexBuffer:vbuf offset:voff atIndex:0];
	[enc setVertexBytes:wh length:sizeof(wh) atIndex:1];
	[enc drawPrimitives:prim vertexStart:0 vertexCount:nv];
	[enc endEncoding];
	return 0;
}

static void
metal_present_tris(id<MTLCommandBuffer> cmd, id<MTLTexture> drawabletex,
	id<MTLTexture> depthtex, int pw, int ph)
{
	int n;
	GPUVert *verts;

	lock(&mtl_geom_lock);
	n = ngtriverts;
	if(n == 0){
		unlock(&mtl_geom_lock);
		return;
	}
	if(n % 3 != 0)
		n -= n % 3;
	if(present_tri_verts == nil)
		present_tri_verts = malloc(sizeof(GPUVert) * MaxGPUTriVerts);
	verts = present_tri_verts;
	if(verts == nil){
		unlock(&mtl_geom_lock);
		return;
	}
	memmove(verts, gtriverts, sizeof(GPUVert) * n);
	ngtriverts = 0;
	unlock(&mtl_geom_lock);
	if(metal_present_geom(cmd, drawabletex, depthtex, pw, ph, verts, n,
	    MTLPrimitiveTypeTriangle) < 0)
		soft_burn_tris(verts, n);
}

static void
metal_present_lines(id<MTLCommandBuffer> cmd, id<MTLTexture> drawabletex,
	id<MTLTexture> depthtex, int pw, int ph)
{
	int i, n, nv, nthin, nthick;
	GPUVert *verts, *tv;
	GPULine *L, *lines;
	float dx, dy, len, px, py, hw;

	lock(&mtl_geom_lock);
	n = nglines;
	if(n == 0){
		unlock(&mtl_geom_lock);
		return;
	}
	if(present_lines == nil)
		present_lines = malloc(sizeof(GPULine) * MaxGPULines);
	lines = present_lines;
	if(lines == nil){
		unlock(&mtl_geom_lock);
		return;
	}
	memmove(lines, glines, sizeof(GPULine) * n);
	nglines = 0;
	unlock(&mtl_geom_lock);

	nthin = 0;
	nthick = 0;
	for(i = 0; i < n; i++){
		if(lines[i].thick > 0)
			nthick++;
		else
			nthin++;
	}

	/* Thin: 2 verts/line; thick: 6 verts (two tris) each. */
	nv = nthin * 2 + nthick * 6;
	if(present_line_verts == nil)
		present_line_verts = malloc(sizeof(GPUVert) * MaxGPULines * 6);
	verts = present_line_verts;
	if(verts == nil){
		for(i = 0; i < n; i++)
			soft_bresenham(gscreen, &lines[i]);
		return;
	}
	/* Pack thin endpoints first, then thick quads (stable offsets for draws). */
	tv = verts;
	for(i = 0; i < n; i++){
		L = &lines[i];
		if(L->thick > 0)
			continue;
		tv[0].x = L->x0; tv[0].y = L->y0; tv[0].z = L->z0;
		tv[0].r = L->r; tv[0].g = L->g; tv[0].b = L->b; tv[0].a = L->a;
		tv[1].x = L->x1; tv[1].y = L->y1; tv[1].z = L->z1;
		tv[1].r = L->r; tv[1].g = L->g; tv[1].b = L->b; tv[1].a = L->a;
		tv += 2;
	}
	for(i = 0; i < n; i++){
		L = &lines[i];
		if(L->thick <= 0)
			continue;
		/* Plan 9 width = 1+2*thick → half-width thick+0.5 in screen pixels. */
		dx = L->x1 - L->x0;
		dy = L->y1 - L->y0;
		len = sqrtf(dx*dx + dy*dy);
		if(len < 1e-4f){
			px = 1.0f;
			py = 0.0f;
		}else{
			px = -dy / len;
			py = dx / len;
		}
		hw = (float)L->thick + 0.5f;
		px *= hw;
		py *= hw;
		tv[0].x = L->x0 - px; tv[0].y = L->y0 - py; tv[0].z = L->z0;
		tv[1].x = L->x0 + px; tv[1].y = L->y0 + py; tv[1].z = L->z0;
		tv[2].x = L->x1 + px; tv[2].y = L->y1 + py; tv[2].z = L->z1;
		tv[3].x = L->x0 - px; tv[3].y = L->y0 - py; tv[3].z = L->z0;
		tv[4].x = L->x1 + px; tv[4].y = L->y1 + py; tv[4].z = L->z1;
		tv[5].x = L->x1 - px; tv[5].y = L->y1 - py; tv[5].z = L->z1;
		tv[0].r = tv[1].r = tv[2].r = tv[3].r = tv[4].r = tv[5].r = L->r;
		tv[0].g = tv[1].g = tv[2].g = tv[3].g = tv[4].g = tv[5].g = L->g;
		tv[0].b = tv[1].b = tv[2].b = tv[3].b = tv[4].b = tv[5].b = L->b;
		tv[0].a = tv[1].a = tv[2].a = tv[3].a = tv[4].a = tv[5].a = L->a;
		tv += 6;
	}

	/* Thick quads first (triangles), then thin lines — same depth buffer. */
	if(nthick > 0){
		if(metal_present_geom(cmd, drawabletex, depthtex, pw, ph,
		    verts + nthin * 2, nthick * 6, MTLPrimitiveTypeTriangle) < 0){
			for(i = 0; i < n; i++)
				if(lines[i].thick > 0)
					soft_bresenham(gscreen, &lines[i]);
		}
	}
	if(nthin > 0){
		/* Rebuild thin verts at the front — already there. */
		if(metal_present_geom(cmd, drawabletex, depthtex, pw, ph,
		    verts, nthin * 2, MTLPrimitiveTypeLine) < 0){
			for(i = 0; i < n; i++)
				if(lines[i].thick <= 0)
					soft_bresenham(gscreen, &lines[i]);
		}
	}
}

static int
metal_queue_line(Memimage *dst, Point p0, Point p1, int thick, Memimage *src, int op,
	float ez0, float ez1)
{
	Memimage *pix;
	Point a, b;
	float r, g, bl, al;
	GPULine *L, *p;

	if(op != SoverD && op != S)
		return 0;
	if(thick < 0)
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

retry:
	lock(&mtl_geom_lock);
	if(nglines >= maxglines){
		if(maxglines != 0){
			unlock(&mtl_geom_lock);
			mark_view_dirty();
			osyield();
			goto retry;
		}
		p = malloc(sizeof(GPULine) * MaxGPULines);
		if(p == nil){
			unlock(&mtl_geom_lock);
			return 0;
		}
		glines = p;
		maxglines = MaxGPULines;
	}
	L = &glines[nglines++];
	L->x0 = (float)a.x;
	L->y0 = (float)a.y;
	L->z0 = eye_to_depth(ez0);
	L->x1 = (float)b.x;
	L->y1 = (float)b.y;
	L->z1 = eye_to_depth(ez1);
	L->r = r;
	L->g = g;
	L->b = bl;
	L->a = al;
	L->thick = thick;
	unlock(&mtl_geom_lock);
	return 1;
}

/*
 * fillpoly3 ('g'/'k'): fan-triangulate screen-space verts and queue for Metal.
 * Convex faces (typical draw3d / Temple) are correct as a fan from vertex 0.
 * Concave ear-clip is intentionally skipped — not needed for current callers.
 * lit scales solid colour (same as soft d3applylit / Limbo litcolour).
 * Returns 0 ⇒ caller uses memfillpoly / d3fillpolyz (obscured, bad op, colour).
 */
static int
metal_queue_fillpoly(Memimage *dst, Point *pp, float *ez, int n, Memimage *src, int op, float lit)
{
	Memimage *pix;
	float r, g, bl, al;
	int i, ntri, need;
	GPUVert *v;

	if(pp == nil || ez == nil || n < 3)
		return 0;
	if(op != SoverD && op != S)
		return 0;
	pix = poly_pixdst(dst, pp, n);
	if(pix == nil)
		return 0;
	if(pix != gscreen && pix != screenimage)
		return 0;
	if(src_rgba(src, &r, &g, &bl, &al) < 0)
		return 0;
	if(lit < 0.0f)
		lit = 0.0f;
	r *= lit;
	g *= lit;
	bl *= lit;
	if(r > 1.0f) r = 1.0f;
	if(g > 1.0f) g = 1.0f;
	if(bl > 1.0f) bl = 1.0f;
	ntri = n - 2;
	need = ntri * 3;
	if(need > MaxGPUTriVerts)
		return 0;
	if(!metal_tri_reserve(need))
		return 0;
	for(i = 1; i < n - 1; i++){
		v = &gtriverts[ngtriverts];
		v[0].x = (float)pp[0].x;
		v[0].y = (float)pp[0].y;
		v[0].z = eye_to_depth(ez[0]);
		v[0].r = r;
		v[0].g = g;
		v[0].b = bl;
		v[0].a = al;
		v[1].x = (float)pp[i].x;
		v[1].y = (float)pp[i].y;
		v[1].z = eye_to_depth(ez[i]);
		v[1].r = r;
		v[1].g = g;
		v[1].b = bl;
		v[1].a = al;
		v[2].x = (float)pp[i+1].x;
		v[2].y = (float)pp[i+1].y;
		v[2].z = eye_to_depth(ez[i+1]);
		v[2].r = r;
		v[2].g = g;
		v[2].b = bl;
		v[2].a = al;
		ngtriverts += 3;
	}
	unlock(&mtl_geom_lock);
	return 1;
}

/* plot3 ('h'): Metal filled 1.5px quad (real triangles), not softscreen 1×1. */
static int
metal_queue_plot(Memimage *dst, Point p, Memimage *src, int op, float ez)
{
	Memimage *pix;
	Point a;
	float r, g, bl, al, z, hx;
	GPUVert *v;

	if(op != SoverD && op != S)
		return 0;
	a = p;
	pix = line_pixdst(dst, &a, &a);
	if(pix == nil)
		return 0;
	if(pix != gscreen && pix != screenimage)
		return 0;
	if(src_rgba(src, &r, &g, &bl, &al) < 0)
		return 0;
	if(!metal_tri_reserve(6))
		return 0;
	z = eye_to_depth(ez);
	hx = 0.75f;	/* ~1.5px square so the point is visible */
	v = &gtriverts[ngtriverts];
	/* tri 0: (−,+),(+,+),(+,−) ; tri 1: (−,+),(+,−),(−,−) */
	v[0].x = (float)a.x - hx; v[0].y = (float)a.y - hx; v[0].z = z;
	v[1].x = (float)a.x + hx; v[1].y = (float)a.y - hx; v[1].z = z;
	v[2].x = (float)a.x + hx; v[2].y = (float)a.y + hx; v[2].z = z;
	v[3].x = (float)a.x - hx; v[3].y = (float)a.y - hx; v[3].z = z;
	v[4].x = (float)a.x + hx; v[4].y = (float)a.y + hx; v[4].z = z;
	v[5].x = (float)a.x - hx; v[5].y = (float)a.y + hx; v[5].z = z;
	v[0].r = v[1].r = v[2].r = v[3].r = v[4].r = v[5].r = r;
	v[0].g = v[1].g = v[2].g = v[3].g = v[4].g = v[5].g = g;
	v[0].b = v[1].b = v[2].b = v[3].b = v[4].b = v[5].b = bl;
	v[0].a = v[1].a = v[2].a = v[3].a = v[4].a = v[5].a = al;
	ngtriverts += 6;
	unlock(&mtl_geom_lock);
	return 1;
}

/*
 * Upload Memimage (+ optional GREY1/8 mask → alpha) to an RGBA8 Metal texture.
 * XBGR32 softscreen-style sources are common for Temple icons.
 */
static id<MTLTexture>
metal_upload_sprite_tex(Memimage *img, Memimage *mask)
{
	MTLTextureDescriptor *td;
	id<MTLTexture> tex;
	int w, h, x, y;
	uchar *rgba, *p, *mp;
	u32 pix;
	MTLRegion region;

	if(img == nil || img->data == nil || img->data->bdata == nil)
		return nil;
	w = Dx(img->r);
	h = Dy(img->r);
	if(w < 1 || h < 1 || w > 2048 || h > 2048)
		return nil;
	rgba = malloc((size_t)w * h * 4);
	if(rgba == nil)
		return nil;
	for(y = 0; y < h; y++){
		for(x = 0; x < w; x++){
			p = byteaddr(img, Pt(img->r.min.x + x, img->r.min.y + y));
			if(p == nil){
				rgba[(y*w+x)*4+0] = 0;
				rgba[(y*w+x)*4+1] = 0;
				rgba[(y*w+x)*4+2] = 0;
				rgba[(y*w+x)*4+3] = 0;
				continue;
			}
			if(img->depth == 32){
				rgba[(y*w+x)*4+0] = p[0];
				rgba[(y*w+x)*4+1] = p[1];
				rgba[(y*w+x)*4+2] = p[2];
				rgba[(y*w+x)*4+3] = 255;
			}else if(img->depth == 8){
				rgba[(y*w+x)*4+0] = p[0];
				rgba[(y*w+x)*4+1] = p[0];
				rgba[(y*w+x)*4+2] = p[0];
				rgba[(y*w+x)*4+3] = 255;
			}else{
				pix = 0;
				memmove(&pix, p, img->depth > 32 ? 4 : (img->depth+7)/8);
				rgba[(y*w+x)*4+0] = (uchar)(pix & 0xff);
				rgba[(y*w+x)*4+1] = (uchar)((pix>>8) & 0xff);
				rgba[(y*w+x)*4+2] = (uchar)((pix>>16) & 0xff);
				rgba[(y*w+x)*4+3] = 255;
			}
			if(mask != nil){
				mp = byteaddr(mask, Pt(mask->r.min.x + x, mask->r.min.y + y));
				if(mp == nil || (mask->depth >= 8 && mp[0] == 0))
					rgba[(y*w+x)*4+3] = 0;
				else if(mask->depth == 1){
					/* GREY1: bit 7 is leftmost in the byte from byteaddr. */
					if((mp[0] & 0x80) == 0)
						rgba[(y*w+x)*4+3] = 0;
				}
			}
		}
	}
	td = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		width:w height:h mipmapped:NO];
	td.usage = MTLTextureUsageShaderRead;
	td.storageMode = MTLStorageModeShared;
	tex = [mtl_device newTextureWithDescriptor:td];
	if(tex != nil){
		region = MTLRegionMake2D(0, 0, w, h);
		[tex replaceRegion:region mipmapLevel:0 withBytes:rgba bytesPerRow:w*4];
	}
	free(rgba);
	return tex;
}

static void
metal_clear_sprite_tex_cache(void)
{
	int i;

	for(i = 0; i < nsprtexcache; i++){
		sprtexcache[i].tex = nil;
		sprtexcache[i].img = nil;
		sprtexcache[i].mask = nil;
		sprtexcache[i].bdata = nil;
		sprtexcache[i].w = sprtexcache[i].h = 0;
		sprtexcache[i].tick = 0;
	}
	nsprtexcache = 0;
	sprtex_tick = 0;
}

/*
 * Cache uploaded sprite textures across 'j' draws. Temple/Castle reuse the
 * same Memimage icons every frame; avoiding re-upload is the big win.
 * Not a packed atlas — one Metal texture per distinct (img,mask) pair.
 */
static id<MTLTexture>
metal_sprite_tex(Memimage *img, Memimage *mask)
{
	int i, w, h, victim;
	u32 oldest;
	void *bdata;
	id<MTLTexture> tex;
	SpriteTexCache *e;

	if(img == nil || img->data == nil || img->data->bdata == nil)
		return nil;
	w = Dx(img->r);
	h = Dy(img->r);
	bdata = img->data->bdata;
	sprtex_tick++;
	if(sprtex_tick == 0)
		sprtex_tick = 1;
	for(i = 0; i < nsprtexcache; i++){
		e = &sprtexcache[i];
		if(e->img == img && e->mask == mask && e->bdata == bdata
		&& e->w == w && e->h == h && e->tex != nil){
			e->tick = sprtex_tick;
			return e->tex;
		}
	}
	tex = metal_upload_sprite_tex(img, mask);
	if(tex == nil)
		return nil;
	if(nsprtexcache < MaxSpriteTexCache){
		e = &sprtexcache[nsprtexcache++];
	}else{
		victim = 0;
		oldest = sprtexcache[0].tick;
		for(i = 1; i < MaxSpriteTexCache; i++){
			if(sprtexcache[i].tick < oldest){
				oldest = sprtexcache[i].tick;
				victim = i;
			}
		}
		e = &sprtexcache[victim];
		e->tex = nil;	/* release previous */
	}
	e->img = img;
	e->mask = mask;
	e->bdata = bdata;
	e->w = w;
	e->h = h;
	e->tick = sprtex_tick;
	e->tex = tex;
	return tex;
}

/* sprite3 ('j'): textured Metal quad with depth; degz rotates in screen space. */
static int
metal_queue_sprite(Memimage *dst, Point sp, int sw, int sh, float ez,
	Memimage *img, Memimage *mask, float degz, int op)
{
	Memimage *pix;
	Point a;
	float z, hx, hy, cs, sn, rad, lx, ly, rx, ry;
	GPUSprite *spr;
	id<MTLTexture> tex;
	int i;
	static const float uv[6][2] = {
		{0,0},{1,0},{1,1},
		{0,0},{1,1},{0,1},
	};
	static const float corner[6][2] = {
		{-1,-1},{1,-1},{1,1},
		{-1,-1},{1,1},{-1,1},
	};

	if(op != SoverD && op != S)
		return 0;
	if(sw < 1 || sh < 1 || img == nil)
		return 0;
	a = sp;
	pix = line_pixdst(dst, &a, &a);
	if(pix == nil)
		return 0;
	if(pix != gscreen && pix != screenimage)
		return 0;
	tex = metal_sprite_tex(img, mask);
	if(tex == nil)
		return 0;
	while(degz >= 360.0f) degz -= 360.0f;
	while(degz < 0.0f) degz += 360.0f;
	rad = degz * (float)M_PI / 180.0f;
	cs = cosf(rad);
	sn = sinf(rad);
	hx = (float)sw * 0.5f;
	hy = (float)sh * 0.5f;
	z = eye_to_depth(ez);
	retry:
	lock(&mtl_geom_lock);
	if(ngsprites >= MaxGPUSprites){
		unlock(&mtl_geom_lock);
		mark_view_dirty();
		osyield();
		goto retry;
	}
	spr = &gsprites[ngsprites];
	spr->tex = tex;
	for(i = 0; i < 6; i++){
		lx = corner[i][0] * hx;
		ly = corner[i][1] * hy;
		rx = lx * cs - ly * sn;
		ry = lx * sn + ly * cs;
		spr->v[i].x = (float)a.x + rx;
		spr->v[i].y = (float)a.y + ry;
		spr->v[i].z = z;
		spr->v[i].u = uv[i][0];
		spr->v[i].v = uv[i][1];
		spr->v[i].r = 1.0f;
		spr->v[i].g = 1.0f;
		spr->v[i].b = 1.0f;
		spr->v[i].a = 1.0f;
	}
	ngsprites++;
	unlock(&mtl_geom_lock);
	return 1;
}

/* circle/ellipse ('q'): tessellate into Metal triangles or line loop. */
static int
metal_queue_ellipse(Memimage *dst, Point c, int a, int b, int thick, int fill,
	Memimage *src, int op, float ez)
{
	Memimage *pix;
	Point p0, p1;
	float r, g, bl, al, z, ang, ca, sa, x0, y0, x1, y1;
	int i, n, need;
	GPUVert *v;

	USED(thick);
	if(op != SoverD && op != S)
		return 0;
	if(a < 1) a = 1;
	if(b < 1) b = 1;
	p0 = c;
	p1 = c;
	pix = line_pixdst(dst, &p0, &p1);
	if(pix == nil)
		return 0;
	if(pix != gscreen && pix != screenimage)
		return 0;
	if(src_rgba(src, &r, &g, &bl, &al) < 0)
		return 0;
	z = eye_to_depth(ez);
	n = EllipseSegs;
	if(fill){
		need = n * 3;
		if(!metal_tri_reserve(need))
			return 0;
		for(i = 0; i < n; i++){
			ang = (float)(2.0 * M_PI * i / n);
			ca = cosf(ang);
			sa = sinf(ang);
			x0 = (float)p0.x + (float)a * ca;
			y0 = (float)p0.y + (float)b * sa;
			ang = (float)(2.0 * M_PI * (i+1) / n);
			ca = cosf(ang);
			sa = sinf(ang);
			x1 = (float)p0.x + (float)a * ca;
			y1 = (float)p0.y + (float)b * sa;
			v = &gtriverts[ngtriverts];
			v[0].x = (float)p0.x; v[0].y = (float)p0.y; v[0].z = z;
			v[1].x = x0; v[1].y = y0; v[1].z = z;
			v[2].x = x1; v[2].y = y1; v[2].z = z;
			v[0].r = v[1].r = v[2].r = r;
			v[0].g = v[1].g = v[2].g = g;
			v[0].b = v[1].b = v[2].b = bl;
			v[0].a = v[1].a = v[2].a = al;
			ngtriverts += 3;
		}
		unlock(&mtl_geom_lock);
		return 1;
	}
	/* Stroke: queue line segments (thick via existing line path). */
	for(i = 0; i < n; i++){
		Point qa, qb;
		ang = (float)(2.0 * M_PI * i / n);
		qa.x = p0.x + (int)((float)a * cosf(ang));
		qa.y = p0.y + (int)((float)b * sinf(ang));
		ang = (float)(2.0 * M_PI * (i+1) / n);
		qb.x = p0.x + (int)((float)a * cosf(ang));
		qb.y = p0.y + (int)((float)b * sinf(ang));
		if(!metal_queue_line(dst, qa, qb, thick, src, op, ez, ez))
			return 0;
	}
	return 1;
}

static void
metal_present_sprites(id<MTLCommandBuffer> cmd, id<MTLTexture> drawabletex,
	id<MTLTexture> depthtex, int pw, int ph)
{
	int i, voff;
	float wh[2];
	id<MTLBuffer> vbuf;
	id<MTLRenderCommandEncoder> enc;
	MTLRenderPassDescriptor *rp;
	MTLLoadAction zload;
	MTLSamplerDescriptor *sd;
	static id<MTLSamplerState> sprsamp;

	lock(&mtl_geom_lock);
	if(ngsprites == 0 || cmd == nil || drawabletex == nil || mtl_sprite_pipe == nil){
		unlock(&mtl_geom_lock);
		return;
	}
	if(depthtex == nil){
		for(i = 0; i < ngsprites; i++)
			gsprites[i].tex = nil;
		ngsprites = 0;
		unlock(&mtl_geom_lock);
		return;
	}
	if(sprsamp == nil){
		sd = [[MTLSamplerDescriptor alloc] init];
		sd.minFilter = MTLSamplerMinMagFilterLinear;
		sd.magFilter = MTLSamplerMinMagFilterLinear;
		sprsamp = [mtl_device newSamplerStateWithDescriptor:sd];
	}
	wh[0] = (float)pw;
	wh[1] = (float)ph;
	zload = mtl_zclear ? MTLLoadActionClear : MTLLoadActionLoad;
	mtl_zclear = 0;

	for(i = 0; i < ngsprites; i++){
		if(gsprites[i].tex == nil || metal_vertex_data(cmd, gsprites[i].v,
		    sizeof(GPUTexVert) * 6, &vbuf, &voff) < 0)
			continue;
		rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = drawabletex;
		rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		rp.depthAttachment.texture = depthtex;
		rp.depthAttachment.loadAction = zload;
		rp.depthAttachment.storeAction = MTLStoreActionStore;
		rp.depthAttachment.clearDepth = 1.0;
		zload = MTLLoadActionLoad;
		enc = [cmd renderCommandEncoderWithDescriptor:rp];
		[enc setRenderPipelineState:mtl_sprite_pipe];
		[enc setDepthStencilState:mtl_zenable ? mtl_depth_on : mtl_depth_off];
		[enc setVertexBuffer:vbuf offset:voff atIndex:0];
		[enc setVertexBytes:wh length:sizeof(wh) atIndex:1];
		[enc setFragmentTexture:gsprites[i].tex atIndex:0];
		[enc setFragmentSamplerState:sprsamp atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
		[enc endEncoding];
		gsprites[i].tex = nil;
	}
	ngsprites = 0;
	unlock(&mtl_geom_lock);
}

/*
 * Materialise queued presentation-only geometry into the Inferno softscreen.
 * draw(3) reads are ordered after writes, so readpixels must not observe the
 * pre-Metal image.  Render into a shared off-screen target with the same
 * pipelines/depth state, wait for completion, and copy its bytes back.
 */
static void
metal_readback_geom(void)
{
	int pw, ph, bpl;
	id<MTLTexture> tex, depthtex;
	id<MTLCommandBuffer> cmd;
	MTLTextureDescriptor *td;
	MTLRegion region;
	uchar *p;

	if(nglines == 0 && ngtriverts == 0 && ngsprites == 0)
		return;
	if(gscreen == nil || gscreen->data == nil || gscreen->data->bdata == nil)
		return;
	pw = Dx(gscreen->r);
	ph = Dy(gscreen->r);
	if(pw < 1 || ph < 1)
		return;
	td = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		width:pw height:ph mipmapped:NO];
	td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
	td.storageMode = MTLStorageModeShared;
	tex = [mtl_device newTextureWithDescriptor:td];
	depthtex = metal_depth_tex(pw, ph);
	if(tex == nil || depthtex == nil)
		return;
	metal_upload_damage(tex, 1);
	cmd = [mtl_queue commandBuffer];
	if(cmd == nil)
		return;
	metal_present_tris(cmd, tex, depthtex, pw, ph);
	metal_present_lines(cmd, tex, depthtex, pw, ph);
	metal_present_sprites(cmd, tex, depthtex, pw, ph);
	[cmd commit];
	[cmd waitUntilCompleted];
	p = byteaddr(gscreen, gscreen->r.min);
	bpl = gscreen->width * sizeof(u32);
	region = MTLRegionMake2D(0, 0, pw, ph);
	[tex getBytes:p bytesPerRow:bpl fromRegion:region mipmapLevel:0];
	/* The CPU image is authoritative again; force the next present to upload it. */
	mtl_tex_fresh = 1;
	lock(&soft_dirty_lock);
	if(soft_dirty != nil){
		memset(soft_dirty, 0, soft_ntx * soft_nty);
		memset(soft_upload_dirty, 0, soft_ntx * soft_nty);
	}
	unlock(&soft_dirty_lock);
	mtl_have_under = 0;
}

static void
metal_blit_tex(id<MTLCommandBuffer> cmd, id<MTLTexture> drawabletex,
	id<MTLRenderPipelineState> pipe, id<MTLTexture> t0, id<MTLTexture> t1,
	id<MTLSamplerState> samp)
{
	id<MTLRenderCommandEncoder> enc;
	MTLRenderPassDescriptor *rp;

	rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = drawabletex;
	rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	enc = [cmd renderCommandEncoderWithDescriptor:rp];
	[enc setRenderPipelineState:pipe];
	[enc setFragmentTexture:t0 atIndex:0];
	if(t1 != nil)
		[enc setFragmentTexture:t1 atIndex:1];
	[enc setFragmentSamplerState:samp atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[enc endEncoding];
}

static void
metal_overlay_soft(id<MTLCommandBuffer> cmd, id<MTLTexture> drawabletex,
	id<MTLTexture> soft, id<MTLTexture> under, id<MTLSamplerState> samp)
{
	id<MTLRenderCommandEncoder> enc;
	MTLRenderPassDescriptor *rp;

	rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = drawabletex;
	rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	enc = [cmd renderCommandEncoderWithDescriptor:rp];
	[enc setRenderPipelineState:mtl_overlay_pipe];
	[enc setFragmentTexture:soft atIndex:0];
	[enc setFragmentTexture:under atIndex:1];
	[enc setFragmentSamplerState:samp atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[enc endEncoding];
}

/*
 * Present: softscreen + optional Metal 3D.
 * If a flush snapshot exists (2D after 3D), draw under → 3D → softscreen overlay
 * so sprites/minimap/HUD win over the wireframe.  Otherwise softscreen then 3D.
 */
static void
present_softscreen(void)
{
	int pw, ph, have_geom, overlay, validate, bpl, sbpl, need, x, y;
	uchar *vp, *cp;
	id<MTLTexture> tex, depthtex, under;
	id<CAMetalDrawable> drawable;
	id<MTLCommandBuffer> cmd;
	id<MTLBlitCommandEncoder> vblit;
	MTLSamplerDescriptor *sd;
	static id<MTLSamplerState> samp;

	if(view == nil || mtl_layer == nil || mtl_device == nil || mtl_pipe == nil)
		return;
	if(gscreen == nil || gscreen->data == nil || gscreen->data->bdata == nil)
		return;
	pw = Dx(gscreen->r);
	ph = Dy(gscreen->r);
	if(pw < 1 || ph < 1)
		return;

	mtl_layer.drawableSize = CGSizeMake(pw, ph);
	tex = metal_soft_tex(pw, ph);
	if(tex == nil)
		return;
	depthtex = metal_depth_tex(pw, ph);
	validate = getenv("INFERNO_METAL_VALIDATE") != nil;
	if(validate){
		bpl = gscreen->width * (int)sizeof(u32);
		sbpl = (pw*4 + 255) & ~255;
		need = sbpl*ph;
		if(metal_validate_len < need){
			free(metal_validate_cpu);
			metal_validate_cpu = malloc(need);
			metal_validate_buf = [mtl_device newBufferWithLength:need
				options:MTLResourceStorageModeShared];
			metal_validate_len = need;
		}
		if(metal_validate_cpu == nil || metal_validate_buf == nil)
			sysfatal("Metal validation buffer: %r");
		metal_validate_stride = sbpl;
		for(y = 0; y < ph; y++)
			memmove(metal_validate_cpu+y*sbpl,
				gscreen->data->bdata+y*bpl, pw*4);
	}

	metal_upload_damage(tex, mtl_tex_fresh);
	mtl_tex_fresh = 0;

	if(samp == nil){
		sd = [[MTLSamplerDescriptor alloc] init];
		sd.minFilter = MTLSamplerMinMagFilterNearest;
		sd.magFilter = MTLSamplerMinMagFilterNearest;
		samp = [mtl_device newSamplerStateWithDescriptor:sd];
	}

	have_geom = nglines > 0 || ngtriverts > 0 || ngsprites > 0;
	overlay = have_geom && mtl_have_under && mtl_under != nil;
	under = mtl_under;
	/* Do CPU staging and enqueue texture uploads before acquiring a scarce
	 * drawable; this shortens drawable ownership and avoids frame-pacing stalls. */
	drawable = [mtl_layer nextDrawable];
	if(drawable == nil){
		if(npresent_copies != 0)
			mtl_tex_fresh = 1;
		return;
	}
	cmd = [mtl_queue commandBuffer];
	if(cmd == nil){
		if(npresent_copies != 0)
			mtl_tex_fresh = 1;
		return;
	}
	metal_replay_copies(cmd, tex, pw, ph);
	if(validate){
		vblit = [cmd blitCommandEncoder];
		if(vblit == nil)
			sysfatal("Metal validation encoder");
		[vblit copyFromTexture:tex sourceSlice:0 sourceLevel:0
			sourceOrigin:MTLOriginMake(0, 0, 0)
			sourceSize:MTLSizeMake(pw, ph, 1)
			toBuffer:metal_validate_buf destinationOffset:0
			destinationBytesPerRow:metal_validate_stride
			destinationBytesPerImage:metal_validate_stride*ph];
		[vblit endEncoding];
	}

	if(overlay){
		/* under (pre-3D softscreen) → Metal 3D+sprites → softscreen where changed */
		metal_blit_tex(cmd, drawable.texture, mtl_pipe, under, nil, samp);
		metal_present_tris(cmd, drawable.texture, depthtex, pw, ph);
		metal_present_lines(cmd, drawable.texture, depthtex, pw, ph);
		metal_present_sprites(cmd, drawable.texture, depthtex, pw, ph);
		metal_overlay_soft(cmd, drawable.texture, tex, under, samp);
	}else{
		metal_blit_tex(cmd, drawable.texture, mtl_pipe, tex, nil, samp);
		if(have_geom){
			metal_present_tris(cmd, drawable.texture, depthtex, pw, ph);
			metal_present_lines(cmd, drawable.texture, depthtex, pw, ph);
			metal_present_sprites(cmd, drawable.texture, depthtex, pw, ph);
		}
	}
	mtl_have_under = 0;

	[cmd presentDrawable:drawable];
	[cmd commit];
	if(validate){
		[cmd waitUntilCompleted];
		vp = [metal_validate_buf contents];
		cp = metal_validate_cpu;
		for(y = 0; y < ph; y++)
			if(memcmp(vp+y*metal_validate_stride,
			    cp+y*metal_validate_stride, pw*4) != 0){
				for(x = 0; x < pw; x++)
					if(((u32*)(vp+y*metal_validate_stride))[x]
					!= ((u32*)(cp+y*metal_validate_stride))[x])
						sysfatal("Metal softscreen coherence mismatch at %d,%d gpu=%#ux cpu=%#ux",
							x, y, ((u32*)(vp+y*metal_validate_stride))[x],
							((u32*)(cp+y*metal_validate_stride))[x]);
			}
	}
	if(getenv("INFERNO_METAL_STATS") != nil && ++metal_stat_frames >= 30){
		fprint(2, "METALSTATS frames=%d upload_bytes=%llud copy_bytes=%llud saved_upload_bytes=%llud copy_begins=%llud precopy_dirty_bytes=%llud precopy_clean_bytes=%llud copy_notes=%llud rejected=%llud armed=%llud cancelled=%llud\n",
			metal_stat_frames, metal_upload_bytes, metal_copy_bytes, metal_saved_bytes,
			metal_copy_begins, metal_precopy_dirty_bytes, metal_precopy_clean_bytes,
			metal_copy_notes, metal_copy_rejected,
			metal_copy_armed, metal_copy_cancelled);
		metal_stat_frames = 0;
		metal_upload_bytes = metal_copy_bytes = metal_saved_bytes = 0;
		metal_copy_begins = metal_copy_notes = metal_copy_rejected = 0;
		metal_precopy_dirty_bytes = metal_precopy_clean_bytes = 0;
		metal_copy_armed = metal_copy_cancelled = 0;
	}
}

static void
present_on_main(void)
{
	lock(&present_lock);
	present_queued = 0;
	if(!present_dirty){
		unlock(&present_lock);
		return;
	}
	present_dirty = 0;
	unlock(&present_lock);
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
	int queue;

	if(view == nil)
		return;
	lock(&present_lock);
	present_dirty = 1;
	if([NSThread isMainThread]){
		present_queued = 0;
		unlock(&present_lock);
		present_on_main();
		return;
	}
	queue = !present_queued;
	if(queue)
		present_queued = 1;
	unlock(&present_lock);
	if(!queue)
		return;
	if(getenv("INFERNO_METAL_VALIDATE") != nil){
		dispatch_sync(dispatch_get_main_queue(), ^{
			present_on_main();
		});
		return;
	}
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
	int tx0, tx1, ty0, ty1, tx, ty;

	if(r.max.x < r.min.x || r.max.y < r.min.y)
		return;
	if(view == nil)
		return;
	if(gscreen != nil && rectclip(&r, gscreen->r)){
		if(metal_damage_map(Dx(gscreen->r), Dy(gscreen->r)) < 0)
			mtl_tex_fresh = 1;
		else{
			tx0 = (r.min.x - gscreen->r.min.x) / SoftTile;
			ty0 = (r.min.y - gscreen->r.min.y) / SoftTile;
			tx1 = (r.max.x - gscreen->r.min.x + SoftTile - 1) / SoftTile;
			ty1 = (r.max.y - gscreen->r.min.y + SoftTile - 1) / SoftTile;
			lock(&soft_dirty_lock);
			for(ty = ty0; ty < ty1; ty++)
				for(tx = tx0; tx < tx1; tx++)
					soft_dirty[ty * soft_ntx + tx] = 1;
			unlock(&soft_dirty_lock);
		}
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
