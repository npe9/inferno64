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
#import <ImageIO/ImageIO.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
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
static id<MTLRenderPipelineState>	mtl_geom3d_pipe;	/* raw-vertex tris: GPU does model*proj+viewport */
/*
 * fgmain's per-pixel shading switch (see the comment on fgmain).  On by
 * default; INFERNO_METAL_FLAT turns it off, restoring the flat per-face
 * colour the software rasteriser produces.  That is the control the
 * software-vs-GPU agreement check in draw3dbench(1) runs against, and the
 * way to get a like-for-like A/B of any port's look.
 */
static float				mtl_shade = 1.0f;
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
enum { SoftTile = 32 };
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
/*
 * Snapshot of gscreen's own pixel bytes (same layout/stride, full size),
 * frozen at each flushmemscreen() call - see the comment there for why.
 */
static uchar	*soft_shadow;
static int	soft_shadow_len;
static GPUCopy	gpu_copies[MaxGPUCopies];
static int	ngpu_copies;
static GPUCopy	present_copies[MaxGPUCopies];
static int	npresent_copies;
static int	damage_before_copy;
static uvlong	metal_damage_calls;
static uvlong	metal_damage_bytes;
static uvlong	metal_full_uploads;
static uvlong	metal_readbacks;
static uvlong	metal_upload_bytes;
static uvlong	metal_copy_bytes;
static uvlong	metal_saved_bytes;
static uvlong	metal_copy_begins;
static uvlong	metal_precopy_dirty_bytes;
static uvlong	metal_precopy_clean_bytes;
static uvlong	metal_precopy_largest_bytes;
static uvlong	metal_precopy_largest_dirty;
static uvlong	metal_copy_notes;
static uvlong	metal_copy_rejected;
static uvlong	metal_copy_reject_storage;
static uvlong	metal_copy_reject_damage;
static uvlong	metal_copy_reject_geometry;
static uvlong	metal_copy_alias_storage;
static uvlong	metal_copy_armed;
static uvlong	metal_copy_cancelled;
static uvlong	metal_g3_calls;	/* gpudrawfillpoly3d successes: real GPU T&L, not CPU d3project */
static uvlong	metal_spr_calls;	/* gpudrawsprite successes: a textured Metal quad, not d3spritez */
static uvlong	metal_fill_calls;	/* gpudrawfillpoly successes: the 2-D queue, CPU-projected verts */
static uvlong	metal_blank_uploads;	/* full uploads of a screen of one colour */
static int	metal_countblank = -1;	/* gated on INFERNO_METAL_STATS, read once */
static uvlong	metal_torn_uploads;	/* presented uploads whose live bytes != the snapshot */
/*
 * Does each frame the program finishes get shown exactly once?  soft_seq
 * counts frames flushed by the program; present records how many have
 * arrived since the last one it showed.  0 means the display repeated a
 * frame, 2 or more means it skipped one - both are visible as judder and
 * neither shows up in an average present interval.
 */
static uvlong	metal_rbwait_us;	/* interpreter time blocked on the readback's GPU round trip */
static uvlong	soft_seq;
static uvlong	presented_seq;
static uvlong	present_dup, present_once, present_skip2, present_skip3;
/* Interval between presents.  A 1:1 frame count is still choppy if the
 * gaps alternate 8ms and 25ms, and an average cannot tell the two apart. */
static vlong	present_last_us;
static int	present_gap[256];
static int	npresent_gap;
/* And the same for the program's own frames, to say which end the
 * irregularity starts at. */
static vlong	flush_last_us;
static int	flush_gap[256];
static int	nflush_gap;
static int	mtl_materialising;	/* inside flush/readback: live bytes are the point */
static id	mtl_dlink;		/* CADisplayLink: the display asks for frames */
extern void	drawvsync(void);	/* devdraw.c: wake /dev/draw/vsync readers */
static id<MTLTexture>	mtl_rbtex;	/* readback target, kept like the others */
static int	mtl_rbtex_w, mtl_rbtex_h;
static uvlong	metal_torn_pixels;
static uvlong	metal_g3_tris;
static int	metal_stat_frames;
/*
 * Wall-clock for the present path.  Every other counter here is BYTES,
 * which says how much was moved and nothing about how long it took - and
 * "how long" is the half of the frame that tkbench(1) explicitly does
 * not measure.
 */
extern vlong	osusectime(void);
static uvlong	metal_presents;		/* calls to present_softscreen */
static uvlong	metal_present_us;	/* total time inside it */
static uvlong	metal_uploads;		/* calls to metal_upload_damage */
static uvlong	metal_upload_us;	/* total time inside that */
static uvlong	metal_drawable_us;	/* blocked in nextDrawable, i.e. vsync */
static uvlong	metal_slotwait_us;	/* blocked on the staging-buffer ring */
static uvlong	metal_uploadwork_us;	/* the tile copy and encode: actual work */
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
	/*
	 * A per-frame ceiling, not a soft limit: past it metal_queue_sprite
	 * spins on osyield() until a present drains the queue, so a port
	 * that draws more sprites in a frame than this holds does not
	 * degrade, it stalls.  draw3dbench(1) measured the cliff at the old
	 * 512 - 256 sprites cost 3ms a frame and 512 cost 14 - and varoom
	 * alone projects 512 bushes plus seven cars, landing exactly on it.
	 */
	MaxGPUSprites = 8192,
	MaxSpriteTexCache = 64,	/* reuse uploads across 'j' draws */
	MaxG3Batches = 64,	/* distinct model/proj xforms per frame, GPU-T&L path */
	MaxGPURuns = 256,	/* distinct clip rectangles per frame, 2D tri path */
	EllipseSegs = 48,
};

/*
 * Where a queued primitive is allowed to put pixels, in render-target
 * (== gscreen) coordinates, max exclusive.
 *
 * memdraw's contract is that a draw touches nothing outside dst->clipr, and
 * the software rasterisers honour it: memfillpoly takes the destination and
 * clips to its clipr, so a polygon drawn into a window stops at the window.
 * The GPU paths had no equivalent.  poly_pixdst() and line_pixdst() redirect
 * a fully-visible layer onto the physical screen by adding the layer's delta
 * to the coordinates - and then handed the screen to Metal with nothing left
 * to say where the window had been.  Geometry that reached past its window
 * was drawn anyway, over the window's own title bar and, under a window
 * manager, over whatever else was on the screen.  Measured: a quad offset off
 * one side of a 320x240 window put 190 pixels outside it on the device
 * provider and 0 on the software one.
 *
 * So every queued primitive carries the rectangle it was given, and each
 * Metal pass sets it as the scissor rect.  That is the same clip, done by
 * the hardware the mechanism exists for.
 */
typedef struct GPUClip GPUClip;
struct GPUClip {
	int	x0, y0, x1, y1;
};

/* A contiguous span of vertices sharing one clip: one scissor, one draw. */
typedef struct GPURun GPURun;
struct GPURun {
	GPUClip	clip;
	int	start;
	int	count;
};

typedef struct GPULine GPULine;
struct GPULine {
	float	x0, y0, z0, x1, y1, z1;
	float	r, g, b, a;
	int	thick;
	GPUClip	clip;
};

/*
 * Packed screen-space vertex (must match Metal LIn: 7 floats, no padding).
 * z is Metal depth in [0,1] (not eye-z). Used for lines and fill tris.
 */
typedef struct GPUVert GPUVert;
struct GPUVert {
	float	x, y, z, r, g, b, a;
};

/*
 * Raw (untransformed) vertex for the GPU-T&L path: model-space position,
 * post near-clip (near-clipping stays in C - d3clipnear - since it needs
 * the vertex count anyway for buffer sizing; everything past that - the
 * model*proj multiply, a *real* hardware perspective divide, and depth -
 * runs in vgmain/fgmain instead of devdraw.c's d3project() C loop).
 * Must match Metal G3In (7 floats, no padding).
 */
typedef struct GPUVert3D GPUVert3D;
struct GPUVert3D {
	float	x, y, z, r, g, b, a;
};

/*
 * Per-batch uniform for the GPU-T&L path: must match Metal G3Xform layout,
 * which is a pair of float4x4 - so both matrices are stored COLUMN-major
 * here, transposed out of draw3d's row-major order by g3xform_load(), and
 * are not in draw3d's order any more. proj is *not* the raw draw3d
 * projection matrix - metal_queue_fillpoly3d folds the viewport scale
 * (mx/cx/my/cy) and the screen-pixel→Metal-NDC map (wh) into it once per
 * batch (d3combineproj), so the vertex shader can emit a genuine clip.xyzw
 * and let the GPU do one real perspective divide, instead of the manual
 * "divide then treat w=1" trick that only supports linear-in-screen-space
 * depth (wrong for a triangle at a steep angle or spanning a lot of depth -
 * this is what actually broke fills: some of a mesh's own triangles failed
 * the depth test against others whenever the crude linear approximation
 * disagreed with which one was really closer).
 */
typedef struct GPUXform GPUXform;
struct GPUXform {
	float	model[16];
	float	proj[16];
};

typedef struct G3Batch G3Batch;
struct G3Batch {
	GPUXform	xform;
	GPUClip	clip;	/* also a batch key: see metal_queue_fillpoly3d */
	int	start;	/* first vertex in g3triverts */
	int	count;
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
	int		nearest;	/* point-sample: see metal_present_sprites */
	GPUClip		clip;
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
static GPURun	gtriruns[MaxGPURuns];
static int	ngtriruns;
static GPUVert3D	*present_tri3d_verts;
static GPUVert3D	g3triverts[MaxGPUTriVerts];
static int	ng3triverts;
static G3Batch	g3batches[MaxG3Batches];
static int	ng3batches;
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
	"struct G3In { float x, y, z, r, g, b, a; };\n"
	/*
	 * draw3d's Matrix is ROW-major: putmat() in appl/math/draw3ddev.b
	 * writes m[i][j] at i*4+j and d3loadmat() reads it back in that
	 * order.  Metal's float4x4 is COLUMN-major - M[j] is column j - so
	 * the two disagree, and until 2026-09-07 this shader papered over it
	 * by spelling all sixteen products out by hand.  That put the burden
	 * on every reader of the shader for ever.  g3xform_load() now
	 * transposes once, in C, where the matrix is packed; the uniform the
	 * GPU sees is genuinely column-major, so float4x4 means what it says
	 * and `M * v` is the correct spelling here exactly as it is in every
	 * other Metal program.  (`v * M` is now the broken one - it draws
	 * nothing, since the transpose puts every vertex outside the clip
	 * volume.  Measured both ways with draw3dbench's software-vs-GPU
	 * agreement check.)
	 */
	"struct G3Xform { float4x4 model; float4x4 proj; };\n"
	"struct G3Out { float4 pos [[position]]; float4 color; float3 eye; };\n"
	"/* GPU-T&L: raw model-space vertex in. model then proj (proj already has\n"
	"   the viewport scale and screen→Metal-NDC map folded in by\n"
	"   d3combineproj, so this outputs a genuine clip.xyzw) - a real hardware\n"
	"   perspective divide, not a manual one, so ez below gets true\n"
	"   perspective-correct interpolation across the triangle. clip.z is a\n"
	"   dummy (0 <= 0.5*clip.w <= clip.w always passes hardware near/far\n"
	"   clipping) - fgmain writes the real depth from the interpolated ez. */\n"
	"vertex G3Out vgmain(uint vid [[vertex_id]],\n"
	"    constant G3In *v [[buffer(0)]],\n"
	"    constant G3Xform &x [[buffer(1)]]) {\n"
	"  G3In i = v[vid];\n"
	"  float4 e = x.model * float4(i.x, i.y, i.z, 1.0);\n"
	"  if(e.w != 0.0 && e.w != 1.0) e.xyz /= e.w;\n"
	"  float4 c = x.proj * float4(e.xyz, 1.0);\n"
	"  /* draw3d's own projection leaves w as the eye z and the camera\n"
	"     looks down -Z, so c.w is NEGATIVE for everything in FRONT of the\n"
	"     eye.  Metal clips to 0 <= z <= w and -w <= x,y <= w, which throws\n"
	"     away every vertex with w < 0 - silently, and that was the whole\n"
	"     scene: this path drew nothing at all until 2026-09-06.  Negating\n"
	"     the clip vector leaves x/w and y/w exactly as they were and puts\n"
	"     w on the side the hardware expects. */\n"
	"  if(c.w < 0.0) c = -c;\n"
	"  G3Out o;\n"
	"  o.pos = c;\n"
	"  o.color = float4(i.r, i.g, i.b, i.a);\n"
	"  o.eye = e.xyz;\n"
	"  return o;\n"
	"}\n"
	"struct G3FragOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };\n"
	/*
	 * Per-pixel shading.  The software rasteriser gives a fillpoly3 face
	 * one flat colour - whatever `lit` the caller passed - because
	 * anything per-pixel in an interpreted inner loop is unaffordable
	 * (measured: polyfill->fillpoly is 7.18ms a frame where the native
	 * Image.fillpoly is 0.07ms).  A GPU is running a fragment for every
	 * covered pixel regardless, so here the per-pixel version is free.
	 *
	 * The face normal comes from the screen-space derivatives of the
	 * interpolated eye-space position, so it needs no per-vertex normal -
	 * there is none on the wire, and adding one would be a draw3d(2)
	 * interface change every port would have to adopt.  dfdx/dfdy are a
	 * fragment-shader primitive with no CPU equivalent that is not a
	 * whole extra pass, which is rather the point.
	 *
	 * Lighting is in EYE space: a three-quarter key, a weak opposite
	 * fill, a Blinn-Phong lobe and a Fresnel rim.  Eye space means no
	 * scene knowledge is needed and no port has to place a light, and it
	 * is what makes the result read as a lit solid rather than a set of
	 * flat facets: diffuse is constant across a flat triangle, but the
	 * specular and rim terms are not, since V varies per pixel.
	 *
	 * shade.x = 0 reproduces the old flat output exactly - that is what
	 * INFERNO_METAL_FLAT selects, and it is the control for the
	 * software-vs-GPU agreement check in draw3dbench(1).
	 */
	"fragment G3FragOut fgmain(G3Out in [[stage_in]],\n"
	"    constant float4 &shade [[buffer(0)]]) {\n"
	"  G3FragOut o;\n"
	"  float4 c = in.color;\n"
	"  if(shade.x > 0.0) {\n"
	"    /* Locals, not file-scope constants: an MSL `constant` needs a\n"
	"       constant initialiser, and normalize() is not one - a global\n"
	"       one makes the whole library fail to compile with \"cannot have\n"
	"       global constructors\", which silently drops the entire GUI to\n"
	"       the CPU rasteriser. */\n"
	"    float3 KEY = normalize(float3(-0.35, 0.55, 0.75));\n"
	"    float3 FILL = normalize(float3(0.5, -0.25, 0.4));\n"
	"    float3 p = in.eye;\n"
	"    float3 v = normalize(-p);\n"
	"    float3 g = cross(dfdx(p), dfdy(p));\n"
	"    float gl = length(g);\n"
	"    /* A triangle that rasterises to a sliver has parallel\n"
	"       derivatives and no usable normal; face the eye instead of\n"
	"       dividing by zero and shading it NaN. */\n"
	"    float3 n = gl > 1e-20 ? g/gl : v;\n"
	"    if(dot(n, v) < 0.0) n = -n;\n"
	"    float nv = saturate(dot(n, v));\n"
	"    float diff = 0.55 + 0.40*saturate(dot(n, KEY))\n"
	"                      + 0.15*saturate(dot(n, FILL));\n"
	"    float spec = pow(saturate(dot(n, normalize(KEY + v))), 28.0) * 0.35;\n"
	"    float rim = pow(1.0 - nv, 3.0) * 0.20;\n"
	"    c.rgb = saturate(c.rgb*diff + spec + rim);\n"
	"  }\n"
	"  o.color = c;\n"
	"  o.depth = 0.5 + atan(-in.eye.z) / M_PI_F;\n"
	"  return o;\n"
	"}\n"
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
	"  /* t is PREMULTIPLIED (metal_upload_sprite_tex).  in.color is a\n"
	"     straight tint, so its alpha has to scale the colour as well as\n"
	"     the alpha to keep the result premultiplied for the One /\n"
	"     OneMinusSourceAlpha blend the pipeline is set up for. */\n"
	"  float4 c = float4(t.rgb * in.color.rgb * in.color.a,\n"
	"                    t.a * in.color.a);\n"
	"  if(c.a < 1.0/255.0) discard_fragment();\n"
	"  return c;\n"
	"}\n";

/* Assigned from metal_init; declared in emu/port/devdraw.c */
extern int	(*gpudrawline)(Memimage*, Point, Point, int, Memimage*, int, float, float);
extern int	(*gpudrawfillpoly)(Memimage*, Point*, float*, int, Memimage*, int, float);
extern int	(*gpudrawfillpoly3d)(Memimage*, float*, float*, float*, int, Memimage*, int,
	float, float*, float*, float, float, float, float);
extern int	(*gpudrawfillpoly3g)(Memimage*, float*, float*, float*, float*, int, Memimage*,
	int, float*, float*, float, float, float, float);
extern int	(*gpudrawplot)(Memimage*, Point, Memimage*, int, float);
extern int	(*gpudrawsprite)(Memimage*, Point, int, int, float, Memimage*, Memimage*, float, int);
extern int	(*gpudrawsprite2d)(Memimage*, Point, int, int, Memimage*, Memimage*, float, int, int);
extern Memimage* (*gpuimagealloc)(Rectangle, u32);
extern int	(*gpuimagefree)(Memimage*);
extern int	(*gpuimagedecode)(Memimage*, uchar*, int, int);
extern void*	(*gpudecopen)(char*, uchar*, int);
extern int	(*gpudecsample)(void*, uchar*, int, Memimage*);
extern void	(*gpudecclose)(void*);
extern void*	(*gpuvideoopen)(void);
extern int	(*gpuvideowrite)(void*, uchar*, int);
extern int	(*gpuvideostart)(void*);
extern int	(*gpuvideonext)(void*, Memimage*);
extern void	(*gpuvideoclose)(void*);
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
static int	metal_queue_fillpoly3d(Memimage*, float*, float*, float*, int, Memimage*, int,
	float, float*, float*, float, float, float, float);
static int	metal_queue_fillpoly3g(Memimage*, float*, float*, float*, float*, int, Memimage*,
	int, float*, float*, float, float, float, float);
static void	metal_present_tris3d(id<MTLCommandBuffer>, id<MTLTexture>, id<MTLTexture>, int, int);
static int	metal_queue_plot(Memimage*, Point, Memimage*, int, float);
static int	metal_queue_sprite(Memimage*, Point, int, int, float, Memimage*, Memimage*, float, int);
static Memimage* metal_image_alloc(Rectangle, u32);
static int	metal_image_free(Memimage*);
static int	metal_image_decode(Memimage*, uchar*, int, int);
static int	metal_movie_frame(Memimage*, uchar*, int, int);
static void*	metal_dec_open(char*, uchar*, int);
static int	metal_dec_sample(void*, uchar*, int, Memimage*);
static void	metal_dec_close(void*);
static void*	metal_video_open(void);
static int	metal_video_write(void*, uchar*, int);
static int	metal_video_start(void*);
static int	metal_video_next(void*, Memimage*);
static void	metal_video_close(void*);
static int	metal_queue_ellipse(Memimage*, Point, int, int, int, int, Memimage*, int, float);
static void	metal_present_lines(id<MTLCommandBuffer>, id<MTLTexture>, id<MTLTexture>, int, int);
static void	metal_present_tris(id<MTLCommandBuffer>, id<MTLTexture>, id<MTLTexture>, int, int);
static void	metal_present_sprites(id<MTLCommandBuffer>, id<MTLTexture>, id<MTLTexture>, int, int);
static void	soft_burn_tris(GPUVert*, int, GPUClip*);
static void	soft_bresenham(Memimage*, GPULine*);
static int	metal_tri_reserve(int);
static void	metal_readback_geom(void);
static float	eye_to_depth(float);
static void	metal_clear_sprite_tex_cache(void);
static void	metal_forget_sprite_tex(Memimage*);
static id<MTLTexture>	metal_sprite_tex(Memimage*, Memimage*);
static int	metal_queue_sprite2d(Memimage*, Point, int, int, Memimage*, Memimage*, float, int, int);
static void	mark_view_dirty(void);
static void	metal_damage_note(Rectangle);
static int	metal_flush_damage(Rectangle);
static int	metal_screen_rect(Memimage*, Rectangle, Rectangle*);
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
	if(lib == nil){
		/*
		 * Without this the whole GUI silently drops to the CPU
		 * rasteriser on a one-character shader typo, reporting only
		 * "no Metal device/pipeline" - which reads as "this machine
		 * has no GPU".  Say what the compiler actually said.
		 */
		fprint(2, "emu: Metal shader compile failed: %s\n",
			err == nil ? "(no error given)" :
			[[err localizedDescription] UTF8String]);
		return -1;
	}
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

	/* Raw model-space verts in; a real hardware perspective divide (not the
	 * manual-divide-then-w=1 trick mtl_geom_pipe uses) gives true
	 * perspective-correct interpolation of ez, and fgmain writes the
	 * nonlinear atan depth from that per fragment instead of per vertex. */
	pd = [[MTLRenderPipelineDescriptor alloc] init];
	pd.vertexFunction = [lib newFunctionWithName:@"vgmain"];
	pd.fragmentFunction = [lib newFunctionWithName:@"fgmain"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	pd.colorAttachments[0].blendingEnabled = NO;
	pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	mtl_geom3d_pipe = [mtl_device newRenderPipelineStateWithDescriptor:pd error:&err];
	if(mtl_geom3d_pipe == nil)
		return -1;
	mtl_shade = getenv("INFERNO_METAL_FLAT") != nil ? 0.0f : 1.0f;

	/* Textured sprites: sample + alpha discard, depth tested. */
	pd = [[MTLRenderPipelineDescriptor alloc] init];
	pd.vertexFunction = [lib newFunctionWithName:@"vtmain"];
	pd.fragmentFunction = [lib newFunctionWithName:@"ftmain"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	pd.colorAttachments[0].blendingEnabled = YES;
	/* Source factor One, not SourceAlpha: the texture and ftmain's
	 * output are premultiplied - see metal_upload_sprite_tex. */
	pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
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

	/*
	 * INFERNO_NOGPU leaves the geometry hooks unset.  devdraw then
	 * takes its own C rasteriser for every 3D primitive - see the
	 * `gpudrawfillpoly3d != nil &&` conditions in devdraw.c - while
	 * the softscreen is still uploaded and presented by Metal.
	 *
	 * That is a third path, and it is not a debugging curiosity: the
	 * Limbo software provider subdivides a Gouraud triangle four ways
	 * to depth four and fills up to 256 sub-triangles for it, and the
	 * Metal one draws the wrong picture (doc/draw3d-adoption-plan.md,
	 * Phase 2b).  The C rasteriser in the middle is neither.  Without
	 * a switch there was no way to ask for it or to measure it.
	 */
	if(getenv("INFERNO_NOGPU") == nil){
		gpudrawline = metal_queue_line;
		gpudrawfillpoly = metal_queue_fillpoly;
		/*
		 * INFERNO_METAL_NOTL takes away the transform-and-light entry
		 * points and leaves the rest of the GPU hooked.  What that
		 * does depends on the message, and it is worth being exact
		 * about which, because the obvious reading is wrong:
		 *
		 * 'k' (fillpoly3) projects each vertex in C and then falls
		 * through to gpudrawfillpoly, so the face still reaches the
		 * GPU - by the 2-D triangle queue instead of the T&L one.
		 * That is a real control: both routes end on the same Metal
		 * pipeline, so a picture that changes between them is the
		 * GPU's own vertex stage.  It is also how that queue gets
		 * exercised from a 3-D program at all.
		 *
		 * 'K' (fillpoly3g) does NOT: devdraw's Gouraud case is a
		 * parallel block with its own d3project + memfillpoly
		 * fallback, and does not try gpudrawfillpoly.  With NOTL set
		 * it is rasterised on the CPU, so measuring it under NOTL
		 * measures the CPU, not the GPU by another road.
		 *
		 * Measured, one run of g3probe(1): fill_calls 0 by default
		 * and 6 with NOTL, g3_calls 2752 by default and 0 with NOTL.
		 */
		if(getenv("INFERNO_METAL_NOTL") == nil){
			gpudrawfillpoly3d = metal_queue_fillpoly3d;
			gpudrawfillpoly3g = metal_queue_fillpoly3g;
		}
		gpudrawplot = metal_queue_plot;
		gpudrawsprite = metal_queue_sprite;
		gpudrawsprite2d = metal_queue_sprite2d;
		/*
		 * Inside the guard, where it always belonged: circles and
		 * ellipses went to the GPU even with INFERNO_NOGPU set, so the
		 * one switch this tree has for "draw it on the CPU instead"
		 * did not turn all of it off.  A control that leaves one
		 * primitive running is worse than no control, because the
		 * difference it fails to explain looks like evidence.
		 */
		gpudrawellipse = metal_queue_ellipse;
	}
	gpuimagealloc = metal_image_alloc;
	gpuimagefree = metal_image_free;
	gpuimagedecode = metal_image_decode;
	gpudecopen = metal_dec_open;
	gpudecsample = metal_dec_sample;
	gpudecclose = metal_dec_close;
	gpuvideoopen = metal_video_open;
	gpuvideowrite = metal_video_write;
	gpuvideostart = metal_video_start;
	gpuvideonext = metal_video_next;
	gpuvideoclose = metal_video_close;
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

/*
 * Ensure soft_shadow (a full mirror of the softscreen's own pixel buffer,
 * same stride) is at least `need` bytes. Caller holds soft_dirty_lock.
 */
static void
ensure_soft_shadow(int need)
{
	uchar *p;

	if(soft_shadow != nil && soft_shadow_len >= need)
		return;
	p = realloc(soft_shadow, need);
	if(p == nil)
		return;
	soft_shadow = p;
	soft_shadow_len = need;
}

/*
 * Freeze scr's pixels for tile range [tx0,tx1)x[ty0,ty1) into soft_shadow.
 * Caller holds soft_dirty_lock and has already confirmed scr/scr->data/
 * scr->data->bdata are non-nil and that this tile range is valid for scr
 * (i.e. derived from scr->r, not some other, possibly stale, screen).
 */
static void
snapshot_tiles(Memimage *scr, int tx0, int ty0, int tx1, int ty1)
{
	int bpl, pw, ph, x0, y0, x1, y1, y, w;
	uchar *base;

	pw = Dx(scr->r);
	ph = Dy(scr->r);
	bpl = scr->width * (int)sizeof(u32);
	ensure_soft_shadow(bpl * ph);
	if(soft_shadow == nil)
		return;
	base = scr->data->bdata;
	x0 = tx0 * SoftTile;
	y0 = ty0 * SoftTile;
	x1 = tx1 * SoftTile;
	if(x1 > pw)
		x1 = pw;
	y1 = ty1 * SoftTile;
	if(y1 > ph)
		y1 = ph;
	w = x1 - x0;
	if(w <= 0)
		return;
	for(y = y0; y < y1; y++)
		memmove(soft_shadow + y * bpl + x0 * 4, base + y * bpl + x0 * 4, w * 4);
}

/*
 * Mark tiles dirty (or, for the gpu-copy bookkeeping, explicitly clean -
 * value 0, meaning "a GPU-side texture copy will present this region, no
 * CPU upload needed"). Every value-1 call also freezes those tiles' pixels
 * into soft_shadow right here, synchronously - this is the *only* place
 * that marks tiles dirty (flushmemscreen() and metal_damage_note() both
 * route through it), so soft_dirty and soft_shadow can never drift apart:
 * metal_upload_damage() later trusts that any tile it finds marked dirty
 * has correspondingly fresh bytes waiting in soft_shadow. Splitting those
 * two updates across separate call sites (as an earlier version of this
 * fix did, only in flushmemscreen()) let tiles get marked dirty here via
 * the gpu-copy-cancelled path without ever getting a shadow refresh -
 * metal_upload_damage() would then upload whatever soft_shadow last held
 * for that tile, from a previous, unrelated flush - visible as ghost
 * "snapshot remnants" of old content while dragging a window.
 *
 * Takes an explicit `scr` (the caller's own single, consistent read of the
 * gscreen global) rather than reading gscreen itself: gscreen is reassigned
 * with no lock at all on a host resize (screenresize(), main thread) - a
 * function that reads the global more than once risks tearing a maximize
 * (a full screen resize, so the two reads can land on very differently-
 * sized screens) into an out-of-bounds copy.
 */
static void
metal_mark_tiles(Memimage *scr, Rectangle r, int value, int fullonly)
{
	int tx0, tx1, ty0, ty1, tx, ty;
	Rectangle tr;

	if(scr == nil || !rectclip(&r, scr->r))
		return;
	tx0 = (r.min.x - scr->r.min.x) / SoftTile;
	ty0 = (r.min.y - scr->r.min.y) / SoftTile;
	tx1 = (r.max.x - scr->r.min.x + SoftTile - 1) / SoftTile;
	ty1 = (r.max.y - scr->r.min.y + SoftTile - 1) / SoftTile;
	if(value && scr->data != nil && scr->data->bdata != nil)
		snapshot_tiles(scr, tx0, ty0, tx1, ty1);
	for(ty = ty0; ty < ty1; ty++)
		for(tx = tx0; tx < tx1; tx++){
			tr = Rect(scr->r.min.x + tx*SoftTile,
				scr->r.min.y + ty*SoftTile,
				scr->r.min.x + (tx+1)*SoftTile,
				scr->r.min.y + (ty+1)*SoftTile);
			if(fullonly && !rectcontains(r, tr))
				continue;
			soft_dirty[ty*soft_ntx + tx] = value;
		}
}

static void
metal_damage_note(Rectangle r)
{
	int i, nx, ny;
	Rectangle dr;
	Memimage *scr;

	scr = gscreen;
	dr = r;
	if(scr != nil && rectclip(&dr, scr->r)){
		metal_damage_calls++;
		metal_damage_bytes += (uvlong)Dx(dr)*Dy(dr)*4;
	}

	if(ngpu_copies == 0){
		damage_before_copy = 1;
		return;
	}
	if(scr == nil || metal_damage_map(Dx(scr->r), Dy(scr->r)) < 0){
		mtl_tex_fresh = 1;
		return;
	}
	lock(&soft_dirty_lock);
	metal_mark_tiles(scr, r, 1, 0);
	for(i = 0; i < ngpu_copies; i++){
		if(!gpu_copies[i].armed && rectcontains(r, gpu_copies[i].dst)){
			metal_mark_tiles(scr, gpu_copies[i].dst, 0, 1);
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
			metal_mark_tiles(scr, gpu_copies[i].dst, 1, 0);
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
	uvlong dirty, clean;
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
	dirty = clean = 0;
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
				dirty += Dx(tr)*Dy(tr)*4;
			else
				clean += Dx(tr)*Dy(tr)*4;
		}
	unlock(&soft_dirty_lock);
	metal_precopy_dirty_bytes += dirty;
	metal_precopy_clean_bytes += clean;
	if(dirty+clean > metal_precopy_largest_bytes){
		metal_precopy_largest_bytes = dirty+clean;
		metal_precopy_largest_dirty = dirty;
	}
}

static int
metal_screen_rect(Memimage *i, Rectangle r, Rectangle *sp)
{
	uchar *base, *p;
	vlong off;
	int bpl, x, y;

	/* Layers may have distinct Memdata wrappers over the screen.  Matching
	 * backing bytes, pixel format, and stride makes their coordinates safely
	 * convertible without accepting save images or other aliases. */
	if(gscreen == nil || gscreen->data == nil || i == nil || i->data == nil
	|| i->data->bdata != gscreen->data->bdata || i->depth != 32
	|| i->chan != gscreen->chan || i->width != gscreen->width)
		return 0;
	base = byteaddr(gscreen, gscreen->r.min);
	p = byteaddr(i, r.min);
	off = p-base;
	bpl = gscreen->width*sizeof(u32);
	if(off < 0 || (off%bpl)%4 != 0)
		return 0;
	y = off/bpl;
	x = (off%bpl)/4;
	*sp = Rect(gscreen->r.min.x+x, gscreen->r.min.y+y,
		gscreen->r.min.x+x+Dx(r), gscreen->r.min.y+y+Dy(r));
	return rectinrect(*sp, gscreen->r);
}

static void
metal_copy_note(Memimage *dst, Rectangle dr, Memimage *src, Rectangle sr)
{
	GPUCopy *c;
	int i;
	Rectangle ds, ss;
	Memimage *scr;

	metal_copy_notes++;
	scr = gscreen;
	if(scr == nil || dst == nil || src == nil || Dx(dr) != Dx(sr) || Dy(dr) != Dy(sr)){
		metal_copy_reject_geometry++;
		metal_copy_rejected++;
		return;
	}
	if(!metal_screen_rect(dst, dr, &ds) || !metal_screen_rect(src, sr, &ss)){
		if(dst->data != nil && src->data != nil && scr->data != nil
		&& dst->data->bdata == scr->data->bdata
		&& src->data->bdata == scr->data->bdata)
			metal_copy_alias_storage++;
		metal_copy_reject_storage++;
		metal_copy_rejected++;
		return;
	}
	if(damage_before_copy){
		metal_copy_reject_damage++;
		metal_copy_rejected++;
		return;
	}
	lock(&soft_dirty_lock);
	for(i = 0; i < ngpu_copies; i++)
		if(rectsoverlap(ds, gpu_copies[i].src) || rectsoverlap(ds, gpu_copies[i].dst)
		|| rectsoverlap(ss, gpu_copies[i].src) || rectsoverlap(ss, gpu_copies[i].dst))
		{
			metal_mark_tiles(scr, gpu_copies[i].dst, 1, 0);
			gpu_copies[i].armed = -1;
		}
	if(ngpu_copies < MaxGPUCopies){
		c = &gpu_copies[ngpu_copies++];
		c->dst = ds;
		c->src = ss;
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

/* Upload dirty tile runs with screen-relative offsets.  The staging stride
 * is 256-byte aligned and tile offsets retain native pixel alignment, so no
 * rectangle repacking is needed. */
static int	metal_upload_damage_body(id<MTLTexture>, int);

/*
 * A shim rather than a timer at each return: metal_upload_damage_body()
 * leaves by several paths and an added clock read at each is a place for
 * one to be missed.
 */
static int
metal_upload_damage(id<MTLTexture> tex, int full)
{
	vlong t0;
	int r;

	t0 = osusectime();
	r = metal_upload_damage_body(tex, full);
	metal_upload_us += osusectime() - t0;
	metal_uploads++;
	return r;
}

static int
metal_upload_damage_body(id<MTLTexture> tex, int full)
{
	int bpl, pw, ph, sbpl, need, slot, tx, tx1, ty, x, y, w, h, ry, any, i, hadcopies;
	vlong t0work;
	uchar *base, *dst, *damage, *swap;
	id<MTLBuffer> buf;
	id<MTLCommandBuffer> cmd;
	id<MTLBlitCommandEncoder> blit;

	if(tex == nil || gscreen == nil || gscreen->data == nil || gscreen->data->bdata == nil)
		return -1;
	if(full)
		metal_full_uploads++;
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
	/*
	 * Read from the frozen per-flush snapshot (see flushmemscreen()), not
	 * gscreen's live bytes directly - by the time this runs (async, on
	 * the AppKit main thread, well after the interpreter thread that
	 * requested this present has moved on), the live buffer may already
	 * be mid-way through a *later* frame's clear+redraw. A `full` upload
	 * covers the whole screen regardless of per-tile damage, including
	 * regions flushmemscreen() may never have snapshotted (e.g. right
	 * after a resize creates a fresh texture) - read live there, exactly
	 * as before this fix, rather than risk uploading stale/never-written
	 * shadow bytes.
	 */
	base = (!full && soft_shadow != nil) ? soft_shadow : gscreen->data->bdata;
	/*
	 * Is what we are about to upload a screen of one single colour?
	 * That is what a frame caught between a program's clear and its
	 * redraw looks like, and counting it is the only way to see from
	 * inside the process what the display is actually being shown.
	 */
	if(full && metal_countblank != 0){
		u32 *q, *sh, first;
		int nq, nd;

		if(metal_countblank < 0)
			metal_countblank = getenv("INFERNO_METAL_STATS") != nil;
		if(metal_countblank > 0){
			nq = (gscreen->width * (int)sizeof(u32) / 4) * ph;
			q = (u32*)base;
			first = q[0];
			for(i = 1; i < nq; i++)
				if(q[i] != first)
					break;
			if(i == nq)
				metal_blank_uploads++;
			/*
			 * And how far the live buffer has drifted from the last
			 * coherent snapshot.  A full upload reads gscreen live,
			 * from the AppKit thread, while the interpreter may be
			 * part way through a frame - so this is the number of
			 * pixels being shown that no flush ever agreed to.
			 */
			if(soft_shadow != nil && base == gscreen->data->bdata
			&& !mtl_materialising){
				sh = (u32*)soft_shadow;
				nd = 0;
				for(i = 0; i < nq; i++)
					if(q[i] != sh[i])
						nd++;
				if(nd > 0){
					metal_torn_uploads++;
					metal_torn_pixels += nd;
				}
			}
		}
	}
	slot = mtl_upload_next++ % nelem(mtl_upload_buf);
	if(mtl_upload_pending[slot] != nil){
		/*
		 * Waiting for the blit that last used this staging slot, which
		 * is paced by the display.  Timed apart from the copy below
		 * because the two answer different questions: this one is the
		 * frame interval, that one is what the CPU actually does.
		 */
		vlong t0s = osusectime();
		[mtl_upload_pending[slot] waitUntilCompleted];
		metal_slotwait_us += osusectime() - t0s;
		mtl_upload_pending[slot] = nil;
	}
	t0work = osusectime();
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
	/* Preserve the old GPU source before current CPU damage is uploaded.
	 * Boundary and cleanup uploads then win over the replayed layer copy. */
	hadcopies = npresent_copies != 0;
	metal_replay_copies(cmd, tex, pw, ph);
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
	metal_uploadwork_us += osusectime() - t0work;
	if(!any && !hadcopies)
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
	/*
	 * A Plan 9 channel descriptor names its components from the most
	 * significant byte down, so on a little-endian host the LAST named
	 * component is byte 0.  RGB24 is R<<16|G<<8|B and therefore B,G,R in
	 * memory; XBGR32 is X<<24|B<<16|G<<8|R and therefore R,G,B,X.  This
	 * used to read p[0],p[1],p[2] as r,g,b for every channel, which is
	 * right only for XBGR32 - so a red source came out blue on every GPU
	 * primitive.  Nobody saw it because the geometry path drew nothing
	 * at all until the clip fix in vgmain.
	 */
	*a = 1.0f;
	switch(src->chan){
	case RGB24:
		*b = p[0] / 255.0f;
		*g = p[1] / 255.0f;
		*r = p[2] / 255.0f;
		return 0;
	case RGBA32:
		*a = p[0] / 255.0f;
		*b = p[1] / 255.0f;
		*g = p[2] / 255.0f;
		*r = p[3] / 255.0f;
		return 0;
	case XBGR32:
		*r = p[0] / 255.0f;
		*g = p[1] / 255.0f;
		*b = p[2] / 255.0f;
		return 0;
	case XRGB32:
		*b = p[0] / 255.0f;
		*g = p[1] / 255.0f;
		*r = p[2] / 255.0f;
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
 * Resolve a destination to the image the GPU can actually draw into, the
 * pixel offset to add to its coordinates to get there, and the clip
 * rectangle the result must stay inside.
 *
 * A window is a layer over a screen's image - but that image can itself be
 * a layer.  wmclient(2) allocates a Screen of its own over whatever image
 * it was handed, so a program run under wm(1) draws into a layer over a
 * layer over the physical screen, where the same program run on its own
 * draws into a layer over the screen directly.  Following one level and
 * requiring the result to BE the screen therefore worked without a window
 * manager and silently declined with one: every 3-D port fell back to the
 * CPU rasteriser the moment it was started from wm, which is how most of
 * them are started.  Measured on castlefrankenstein(1): 22957 GPU calls in
 * thirty frames on its own, 0 under wm.  So follow the chain to the end.
 *
 * Any obscured layer on the way stops it: part of that window is covered,
 * so there is no single place on the screen its pixels belong, and the
 * software memlayer machinery has to composite it instead.
 */
enum { MaxLayerDepth = 8 };

static Memimage*
geom_target(Memimage *dst, Point *delta, GPUClip *clip)
{
	Rectangle r;
	Memlayer *l;
	Point d;
	int n;

	clip->x0 = clip->y0 = clip->x1 = clip->y1 = 0;
	d.x = d.y = 0;
	*delta = d;
	if(dst == nil)
		return nil;
	r = dst->clipr;
	for(n = 0; (l = dst->layer) != nil; n++){
		if(n >= MaxLayerDepth || !l->clear)
			return nil;
		/* image coords → the parent's coords, and no wider than the
		 * window is on it */
		d = addpt(d, l->delta);
		r = rectaddpt(r, l->delta);
		if(!rectclip(&r, l->screenr))
			return nil;
		dst = l->screen->image;
		if(dst == nil)
			return nil;
	}
	if(r.max.x <= r.min.x || r.max.y <= r.min.y)
		return nil;
	clip->x0 = r.min.x;
	clip->y0 = r.min.y;
	clip->x1 = r.max.x;
	clip->y1 = r.max.y;
	*delta = d;
	return dst;
}

static int
clip_eq(GPUClip *a, GPUClip *b)
{
	return a->x0 == b->x0 && a->y0 == b->y0
		&& a->x1 == b->x1 && a->y1 == b->y1;
}

/* The clip as a Rectangle, for the software paths, which speak memdraw. */
static Rectangle
clip_rect(GPUClip *c)
{
	return Rect(c->x0, c->y0, c->x1, c->y1);
}

/*
 * Set a render pass's scissor.  Metal rejects a scissor rectangle that leaves
 * the attachment - a validation failure that kills the process, not a clamp -
 * so clamp it here.  Both the present path and the readback path render into
 * a target the size of gscreen, so one set of coordinates serves both.
 * Returns 0 if there is nothing left to draw.
 */
static int
clip_scissor(id<MTLRenderCommandEncoder> enc, GPUClip *c, int pw, int ph)
{
	MTLScissorRect sr;
	int x0, y0, x1, y1;

	x0 = c->x0;
	y0 = c->y0;
	x1 = c->x1;
	y1 = c->y1;
	if(x0 < 0) x0 = 0;
	if(y0 < 0) y0 = 0;
	if(x1 > pw) x1 = pw;
	if(y1 > ph) y1 = ph;
	if(x1 <= x0 || y1 <= y0)
		return 0;
	sr.x = x0;
	sr.y = y0;
	sr.width = x1 - x0;
	sr.height = y1 - y0;
	[enc setScissorRect:sr];
	return 1;
}

/*
 * Extend or open a clip run over the next `count` vertices of gtriverts.
 * Called with the geometry lock held and before the vertices are written, so
 * a caller that cannot get a run can still back out.  Returns 0 when the run
 * table is full, which sends the caller to the CPU rasteriser rather than
 * drawing the geometry under the wrong scissor.
 */
static int
gtri_run(GPUClip *c, int count)
{
	GPURun *r;

	if(ngtriruns > 0){
		r = &gtriruns[ngtriruns-1];
		if(clip_eq(&r->clip, c) && r->start + r->count == ngtriverts){
			r->count += count;
			return 1;
		}
	}
	if(ngtriruns >= MaxGPURuns)
		return 0;
	r = &gtriruns[ngtriruns++];
	r->clip = *c;
	r->start = ngtriverts;
	r->count = count;
	return 1;
}

/*
 * Resolve clear layered windows to softscreen (screen coords).
 * Obscured layers stay on the software memline/memfillpoly path.
 */
static Memimage*
line_pixdst(Memimage *dst, Point *p0, Point *p1, GPUClip *clip)
{
	Memimage *pix;
	Point d;

	pix = geom_target(dst, &d, clip);
	if(pix == nil)
		return nil;
	*p0 = addpt(*p0, d);
	*p1 = addpt(*p1, d);
	return pix;
}

static Memimage*
poly_pixdst(Memimage *dst, Point *pp, int n, GPUClip *clip)
{
	Memimage *pix;
	Point d;
	int i;

	if(pp == nil || n < 3)
		return nil;
	pix = geom_target(dst, &d, clip);
	if(pix == nil)
		return nil;
	for(i = 0; i < n; i++)
		pp[i] = addpt(pp[i], d);
	return pix;
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

/*
 * Deferred software fallback.
 *
 * When a Metal geometry pass cannot run (pipeline not built yet on the
 * first frame, vertex staging failure, no encoder), the present
 * routines fall back to drawing the primitives into gscreen with the
 * CPU rasterisers below.  That is right for the on-screen present
 * path, but metal_readback_geom() renders into an offscreen texture
 * and then copies that texture *over* gscreen, which silently threw
 * away everything the fallback had just drawn.  A whole batch of line3
 * segments vanished whenever a pass failed - most visibly on the first
 * frame after start-up, before the pipeline is built.
 *
 * During a readback the fallback is therefore recorded instead of
 * drawn, and replayed into gscreen once the texture has been copied.
 */
static int	mtl_soft_defer;
/*
 * Counts geometry primitives the GPU could not draw, so a rare failure
 * reports itself instead of being silent.  A fallback means a Metal
 * pass could not run at all; it is always worth knowing about, so the
 * first one warns even without INFERNO_METAL_STATS, once per process.
 */
static uvlong	metal_soft_fallbacks;
static int	metal_soft_warned;

static void
note_soft_fallback(void)
{
	metal_soft_fallbacks++;
	if(!metal_soft_warned){
		metal_soft_warned = 1;
		fprint(2, "inferno: metal geometry pass failed; "
			"drawing on the CPU instead (set INFERNO_METAL_STATS for counts)\n");
	}
}
static GPULine	*defer_lines;
static int	ndefer_lines, maxdefer_lines;
static GPUVert	*defer_tverts;
static GPUClip	*defer_tclips;	/* one per deferred triangle */
static int	ndefer_tverts, maxdefer_tverts;

static void
defer_line(GPULine *L)
{
	GPULine *p;
	int nmax;

	if(ndefer_lines >= maxdefer_lines){
		nmax = maxdefer_lines ? maxdefer_lines * 2 : 256;
		p = realloc(defer_lines, sizeof(GPULine) * nmax);
		if(p == nil)
			return;
		defer_lines = p;
		maxdefer_lines = nmax;
	}
	defer_lines[ndefer_lines++] = *L;
}

static void
defer_tris(GPUVert *v, int nv, GPUClip *clip)
{
	GPUVert *p;
	GPUClip *q;
	int nmax, i;

	nv -= nv % 3;
	if(nv <= 0)
		return;
	if(ndefer_tverts + nv > maxdefer_tverts){
		nmax = maxdefer_tverts ? maxdefer_tverts * 2 : 1024;
		while(nmax < ndefer_tverts + nv)
			nmax *= 2;
		p = realloc(defer_tverts, sizeof(GPUVert) * nmax);
		if(p == nil)
			return;
		defer_tverts = p;
		q = realloc(defer_tclips, sizeof(GPUClip) * (nmax/3 + 1));
		if(q == nil)
			return;
		defer_tclips = q;
		maxdefer_tverts = nmax;
	}
	memmove(defer_tverts + ndefer_tverts, v, sizeof(GPUVert) * nv);
	for(i = 0; i < nv/3; i++)
		defer_tclips[ndefer_tverts/3 + i] = *clip;
	ndefer_tverts += nv;
}

static void
soft_line_or_defer(GPULine *L)
{
	note_soft_fallback();
	if(mtl_soft_defer)
		defer_line(L);
	else
		soft_bresenham(gscreen, L);
}

static void
soft_tris_or_defer(GPUVert *v, int nv, GPUClip *clip)
{
	note_soft_fallback();
	if(mtl_soft_defer)
		defer_tris(v, nv, clip);
	else
		soft_burn_tris(v, nv, clip);
}

static void
metal_soft_replay(void)
{
	int i;

	for(i = 0; i < ndefer_lines; i++)
		soft_bresenham(gscreen, &defer_lines[i]);
	ndefer_lines = 0;
	for(i = 0; i + 2 < ndefer_tverts; i += 3)
		soft_burn_tris(defer_tverts + i, 3, &defer_tclips[i/3]);
	ndefer_tverts = 0;
}

static void
soft_burn_tris(GPUVert *verts, int nverts, GPUClip *clip)
{
	int i;
	Point pp[4];
	Memimage *src;
	GPUVert *v0, *v1, *v2;
	Rectangle saved, r;

	if(gscreen == nil)
		return;
	/*
	 * memfillpoly clips to the destination's clipr and to nothing else,
	 * and gscreen's clipr is the whole screen - so narrow it, for the
	 * length of this call, to the window the geometry was drawn into.
	 * That is the same rectangle the Metal pass would have scissored to;
	 * without it this fallback escapes its window exactly as the GPU path
	 * used to.
	 */
	saved = gscreen->clipr;
	if(clip != nil){
		r = clip_rect(clip);
		if(!rectclip(&r, saved))
			return;
		gscreen->clipr = r;
	}
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
	gscreen->clipr = saved;
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
	/* and no further than the window the line was drawn into */
	if(!rectclip(&clip, clip_rect(&L->clip)))
		return;
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
static void	metal_readback_geom(void);

static void
metal_flush_geom(void)
{
	int pw, ph;
	id<MTLTexture> tex, under;
	id<MTLCommandBuffer> cmd;
	id<MTLBlitCommandEncoder> blit;

	if(nglines == 0 && ngtriverts == 0 && ng3triverts == 0 && ngsprites == 0)
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
	/* Uploads from here to the end of the readback are feeding the
	 * compositor, not the display, and they want the softscreen as it
	 * stands rather than as it was last flushed. */
	mtl_materialising = 1;
	/*
	 * Bring the persistent soft texture current, then snapshot it entirely
	 * on the GPU.  Uploading gscreen straight into under forced a full CPU
	 * texture conversion every time 2D drawing followed queued geometry.
	 *
	 * Full, not incremental, and that is load-bearing.  An incremental
	 * upload reads from soft_shadow - flushmemscreen()'s frozen per-flush
	 * snapshot - because it runs asynchronously on the AppKit thread where
	 * the live buffer may already be into a later frame.  This runs on the
	 * interpreter thread at a defined point in the frame, and what it needs
	 * is the softscreen as it stands NOW: the overlay pass is a comparison
	 * against this snapshot, so a snapshot that predates the program's own
	 * drawing makes that comparison meaningless and the drawing disappears.
	 * With the incremental upload, ports that clear their window to a colour
	 * of their own came back with emu's desktop through the middle of them -
	 * pick3d(1) read 266482 pixels of the Paper desktop colour across 227
	 * rows where the software provider has white, and reads 270586 white
	 * and no Paper with this.  It costs one texture conversion per frame in
	 * which 2-D follows 3-D, which mtl_have_under already limits it to.
	 */
	metal_upload_damage(tex, 1);
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
	/*
	 * And put the geometry down, here, now.
	 *
	 * This is called on the first message after queued geometry that is
	 * not itself a draw3d letter - so the 3D for this frame is complete
	 * and the 2D that belongs on top of it has not been drawn yet.
	 * That is the one well-defined point in a frame at which the
	 * softscreen can be made whole, and making it whole here is what
	 * stops presentation being the only thing that ever consumes the
	 * geometry queue.
	 *
	 * Before this, whether a frame's 3D reached the image everything
	 * else reads was a race between the present and the next readback:
	 * g3probe(1) drew one frame and read it back, and got nothing at
	 * all in about half of eight runs.  The same scene over eight
	 * frames came out right because by then a readback had won once.
	 *
	 * The snapshot above is still taken first, because the readback
	 * composes with it.  At this instant it equals the current
	 * softscreen, so the overlay in there is a no-op and the result is
	 * simply softscreen + geometry - which the 2D about to be drawn
	 * then lands on top of, in the right order, with no present
	 * involved.
	 */
	metal_readback_geom();
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
	MTLPrimitiveType prim, GPUClip *clip)
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

	/* Do NOT clear mtl_zclear yet - see the note at the encoder below. */
	zload = mtl_zclear ? MTLLoadActionClear : MTLLoadActionLoad;

	rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = drawabletex;
	rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.depthAttachment.texture = depthtex;
	rp.depthAttachment.loadAction = zload;
	rp.depthAttachment.storeAction = MTLStoreActionStore;
	rp.depthAttachment.clearDepth = 1.0;

	enc = [cmd renderCommandEncoderWithDescriptor:rp];
	if(enc == nil)
		return -1;	/* pass never happened: leave the clear pending */
	/* The pass is now certain to run, so the pending clear is genuinely
	 * consumed. Clearing the flag before this point threw the clear away
	 * whenever the encoder could not be created, and the next geom pass
	 * then loaded a stale depth buffer instead of a cleared one. */
	mtl_zclear = 0;
	if(clip != nil && !clip_scissor(enc, clip, pw, ph)){
		/* the window has no visible pixels left: nothing to draw, and
		 * nothing for the caller to rasterise on the CPU either */
		[enc endEncoding];
		return 0;
	}
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
	int i, n, nr, cnt;
	GPUVert *verts;
	GPURun runs[MaxGPURuns], *r;

	lock(&mtl_geom_lock);
	n = ngtriverts;
	nr = ngtriruns;
	if(n == 0 || nr == 0){
		ngtriverts = 0;
		ngtriruns = 0;
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
	memmove(runs, gtriruns, sizeof(GPURun) * nr);
	ngtriverts = 0;
	ngtriruns = 0;
	unlock(&mtl_geom_lock);
	/* One pass per clip rectangle.  In the ordinary case - a frame drawn
	 * into one window - that is one run and one pass, as before. */
	for(i = 0; i < nr; i++){
		r = &runs[i];
		if(r->start < 0 || r->start >= n)
			continue;
		cnt = r->count;
		if(r->start + cnt > n)
			cnt = n - r->start;
		cnt -= cnt % 3;
		if(cnt < 3)
			continue;
		if(metal_present_geom(cmd, drawabletex, depthtex, pw, ph,
		    verts + r->start, cnt, MTLPrimitiveTypeTriangle, &r->clip) < 0)
			soft_tris_or_defer(verts + r->start, cnt, &r->clip);
	}
}

/*
 * GPU-T&L triangles: one drawPrimitives per distinct (model,proj,viewport)
 * batch, each with its own xform bound at buffer(1) - vgmain does the
 * model*proj multiply, divide, and viewport scale that metal_present_geom's
 * vertex shader (vlmain) assumes is already done. metal_queue_fillpoly3d
 * already checked every eligibility gate (op/dst/src) before queuing, so
 * the only failure left here is allocation - drop the frame's queued
 * batches rather than software-raster them (there's no projected
 * screen-space triangle to hand soft_burn_tris; the whole point of this
 * path is that one was never computed on the CPU).
 */
static void
metal_present_tris3d(id<MTLCommandBuffer> cmd, id<MTLTexture> drawabletex,
	id<MTLTexture> depthtex, int pw, int ph)
{
	int i, n, nb;
	id<MTLBuffer> vbuf;
	int voff;
	id<MTLRenderCommandEncoder> enc;
	MTLRenderPassDescriptor *rp;
	MTLLoadAction zload;
	G3Batch *batches;
	float shade[4];

	lock(&mtl_geom_lock);
	n = ng3triverts;
	nb = ng3batches;
	if(n == 0 || nb == 0){
		ng3triverts = 0;
		ng3batches = 0;
		unlock(&mtl_geom_lock);
		return;
	}
	if(present_tri3d_verts == nil)
		present_tri3d_verts = malloc(sizeof(GPUVert3D) * MaxGPUTriVerts);
	if(present_tri3d_verts == nil){
		ng3triverts = 0;
		ng3batches = 0;
		unlock(&mtl_geom_lock);
		return;
	}
	memmove(present_tri3d_verts, g3triverts, sizeof(GPUVert3D) * n);
	batches = malloc(sizeof(G3Batch) * nb);
	if(batches != nil)
		memmove(batches, g3batches, sizeof(G3Batch) * nb);
	ng3triverts = 0;
	ng3batches = 0;
	unlock(&mtl_geom_lock);
	if(batches == nil || cmd == nil || drawabletex == nil || depthtex == nil
	|| mtl_geom3d_pipe == nil){
		free(batches);
		return;
	}
	if(metal_vertex_data(cmd, present_tri3d_verts, sizeof(GPUVert3D) * n, &vbuf, &voff) < 0){
		free(batches);
		return;
	}

	/* Do NOT clear mtl_zclear yet - see the note at the encoder below. */
	zload = mtl_zclear ? MTLLoadActionClear : MTLLoadActionLoad;

	rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = drawabletex;
	rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.depthAttachment.texture = depthtex;
	rp.depthAttachment.loadAction = zload;
	rp.depthAttachment.storeAction = MTLStoreActionStore;
	rp.depthAttachment.clearDepth = 1.0;

	enc = [cmd renderCommandEncoderWithDescriptor:rp];
	if(enc == nil){
		free(batches);
		return;		/* pass never happened: leave the clear pending */
	}
	mtl_zclear = 0;		/* the pass will run, so the clear is consumed */
	[enc setRenderPipelineState:mtl_geom3d_pipe];
	[enc setDepthStencilState:mtl_zenable ? mtl_depth_on : mtl_depth_off];
	[enc setVertexBuffer:vbuf offset:voff atIndex:0];
	shade[0] = mtl_shade;
	shade[1] = shade[2] = shade[3] = 0.0f;
	[enc setFragmentBytes:shade length:sizeof shade atIndex:0];
	for(i = 0; i < nb; i++){
		if(batches[i].count == 0)
			continue;
		if(!clip_scissor(enc, &batches[i].clip, pw, ph))
			continue;
		[enc setVertexBufferOffset:voff + batches[i].start * sizeof(GPUVert3D) atIndex:0];
		[enc setVertexBytes:&batches[i].xform length:sizeof(GPUXform) atIndex:1];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle
			vertexStart:0 vertexCount:batches[i].count];
	}
	[enc endEncoding];
	free(batches);
}

static void
metal_present_lines(id<MTLCommandBuffer> cmd, id<MTLTexture> drawabletex,
	id<MTLTexture> depthtex, int pw, int ph)
{
	int i, n, nv, nthin, nthick, st, en;
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

	if(present_line_verts == nil)
		present_line_verts = malloc(sizeof(GPUVert) * MaxGPULines * 6);
	verts = present_line_verts;
	if(verts == nil){
		for(i = 0; i < n; i++)
			soft_line_or_defer(&lines[i]);
		return;
	}

	/*
	 * A maximal run of lines sharing one clip rectangle is one scissor and
	 * so one pair of passes.  Queue order is run order: a frame of lines
	 * drawn into one window is a single run, exactly as it was before the
	 * clip existed, and it costs the same two draws.
	 */
	for(st = 0; st < n; st = en){
		for(en = st + 1; en < n && clip_eq(&lines[en].clip, &lines[st].clip); en++)
			;
		nthin = 0;
		nthick = 0;
		for(i = st; i < en; i++){
			if(lines[i].thick > 0)
				nthick++;
			else
				nthin++;
		}
		/* Thin: 2 verts/line; thick: 6 verts (two tris) each. */
		nv = nthin * 2 + nthick * 6;
		if(nv == 0)
			continue;
		/* Pack thin endpoints first, then thick quads (stable offsets for draws). */
		tv = verts;
		for(i = st; i < en; i++){
			L = &lines[i];
			if(L->thick > 0)
				continue;
			tv[0].x = L->x0; tv[0].y = L->y0; tv[0].z = L->z0;
			tv[0].r = L->r; tv[0].g = L->g; tv[0].b = L->b; tv[0].a = L->a;
			tv[1].x = L->x1; tv[1].y = L->y1; tv[1].z = L->z1;
			tv[1].r = L->r; tv[1].g = L->g; tv[1].b = L->b; tv[1].a = L->a;
			tv += 2;
		}
		for(i = st; i < en; i++){
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
			    verts + nthin * 2, nthick * 6, MTLPrimitiveTypeTriangle,
			    &lines[st].clip) < 0){
				for(i = st; i < en; i++)
					if(lines[i].thick > 0)
						soft_line_or_defer(&lines[i]);
			}
		}
		if(nthin > 0){
			/* Rebuild thin verts at the front — already there. */
			if(metal_present_geom(cmd, drawabletex, depthtex, pw, ph,
			    verts, nthin * 2, MTLPrimitiveTypeLine,
			    &lines[st].clip) < 0){
				for(i = st; i < en; i++)
					if(lines[i].thick <= 0)
						soft_line_or_defer(&lines[i]);
			}
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
	GPUClip clip;

	if(op != SoverD && op != S)
		return 0;
	if(thick < 0)
		return 0;
	a = p0;
	b = p1;
	pix = line_pixdst(dst, &a, &b, &clip);
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
	L->clip = clip;
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
	GPUClip clip;

	if(pp == nil || ez == nil || n < 3)
		return 0;
	if(op != SoverD && op != S)
		return 0;
	pix = poly_pixdst(dst, pp, n, &clip);
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
	if(!gtri_run(&clip, need)){
		unlock(&mtl_geom_lock);
		return 0;
	}
	metal_fill_calls++;
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

/* Return with the geometry lock held and room reserved in g3triverts. */
static int
metal_tri3d_reserve(int need)
{
	if(need < 1 || need > MaxGPUTriVerts)
		return 0;
retry:
	lock(&mtl_geom_lock);
	if(ng3triverts + need <= MaxGPUTriVerts)
		return 1;
	unlock(&mtl_geom_lock);
	mark_view_dirty();
	osyield();
	goto retry;
}

static int
g3xform_eq(GPUXform *a, GPUXform *b)
{
	return memcmp(a->model, b->model, sizeof a->model) == 0
		&& memcmp(a->proj, b->proj, sizeof a->proj) == 0;
}

/*
 * Fold the viewport scale (mx/cx/my/cy: NDC → screen pixels) and the
 * screen-pixel → Metal-NDC map (wh, same convention as vlmain/vtmain) into
 * the draw3d projection matrix, so vgmain can emit real clip.xyzw and let
 * the GPU do one genuine perspective divide instead of a manual one.
 * Derivation: with clip.w = cw (proj's own w-row, unchanged),
 *   clip.x/cw must equal screen_x/wh.x*2-1, where screen_x = mx*(ndcx/cw)+cx
 *   and ndcx/cw is proj's own (pre-viewport) NDC x. Multiplying through by
 *   cw gives clip.x as a linear combination of proj's row0 and row3 - see
 *   the y equivalent below (with the same sign flip vlmain's "1.0-y" uses).
 * clip.z is left as a dummy 0.5*cw (always inside [0,cw] for cw>0, which
 * d3clipnear guarantees) - fgmain supplies the real depth per fragment.
 */
static void
d3combineproj(float *proj, float mx, float cx, float my, float cy,
	float pw, float ph, float *out)
{
	float a, b;
	int i;

	a = 2.0f*mx/pw;
	b = 2.0f*cx/pw - 1.0f;
	for(i = 0; i < 4; i++)
		out[i] = a*proj[i] + b*proj[12+i];
	a = -2.0f*my/ph;
	b = 1.0f - 2.0f*cy/ph;
	for(i = 0; i < 4; i++)
		out[4+i] = a*proj[4+i] + b*proj[12+i];
	for(i = 0; i < 4; i++)
		out[8+i] = 0.5f*proj[12+i];
	for(i = 0; i < 4; i++)
		out[12+i] = proj[12+i];
}

/*
 * Pack the per-batch uniform the GPU-T&L shaders read.  draw3d's matrices
 * are row-major (m[i][j] at i*4+j); Metal's float4x4 is column-major.  The
 * transpose belongs HERE, once per batch on the CPU, and not in the shader
 * as sixteen hand-written products - see the G3Xform comment in
 * kSoftscreenMetalSrc.  g3xform_eq compares the packed bytes, and
 * transposition is a bijection, so batching is unaffected.
 */
static void
xpose4(float *m, float *out)
{
	int i, j;

	for(i = 0; i < 4; i++)
		for(j = 0; j < 4; j++)
			out[j*4 + i] = m[i*4 + j];
}

static void
g3xform_load(GPUXform *xf, float *model, float *proj, float mx, float cx,
	float my, float cy, float pw, float ph)
{
	float cp[16];

	xpose4(model, xf->model);
	d3combineproj(proj, mx, cx, my, cy, pw, ph, cp);
	xpose4(cp, xf->proj);
}

/*
 * fillpoly3 ('g'/'k'), GPU-T&L variant: vertices are raw model-space (post
 * d3clipnear), untransformed. The model/proj multiply and viewport scale
 * that metal_queue_fillpoly's caller (d3project) does once per vertex in C
 * happen instead in the vgmain/fgmain shaders, once per vertex/fragment on
 * the GPU. Batches by (model,proj) so devdraw.c doesn't need to flush on
 * every draw call - in practice a whole frame of a fixed camera (the
 * common case: setup3d() sets model/proj once, every wall/floor/mesh
 * triangle for that frame shares them) is one batch.
 * Returns 0 ⇒ caller falls back to the CPU d3project + memfillpoly/gpudrawfillpoly path.
 */
static int
metal_queue_fillpoly3d(Memimage *dst, float *vx, float *vy, float *vz, int n,
	Memimage *src, int op, float lit, float *model, float *proj,
	float mx, float cx, float my, float cy)
{
	float r, g, bl, al;
	int i, ntri, need, bi, pw, ph;
	GPUXform xf;
	GPUVert3D *v;
	GPUClip clip;
	Point delta;

	if(vx == nil || vy == nil || vz == nil || n < 3)
		return 0;
	if(op != SoverD && op != S)
		return 0;
	if(dst == nil)
		return 0;
	/*
	 * Same redirect poly_pixdst does for the 2D path: a fully-visible
	 * (clear) layer can draw straight onto the physical screen with a
	 * fixed pixel offset (delta) added; an obscured one has no single
	 * screen position to draw into (parts of it are covered) and has to
	 * go through the CPU path, which composites via the ordinary
	 * softscreen/memlayer machinery. Raw model-space verts have no screen
	 * position yet to add delta to directly, so fold it into the viewport
	 * constant term instead (cx/cy already mean "add this many pixels
	 * after the NDC scale" - delta is exactly that, one more pixel-space
	 * offset) rather than needing the vertices themselves in screen space.
	 */
	dst = geom_target(dst, &delta, &clip);
	if(dst == nil)
		return 0;
	cx += (float)delta.x;
	cy += (float)delta.y;
	if(dst != gscreen && dst != screenimage)
		return 0;
	if(gscreen == nil || gscreen->data == nil || gscreen->data->bdata == nil)
		return 0;
	pw = Dx(gscreen->r);
	ph = Dy(gscreen->r);
	if(pw < 1 || ph < 1)
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

	g3xform_load(&xf, model, proj, mx, cx, my, cy, (float)pw, (float)ph);

	if(!metal_tri3d_reserve(need))
		return 0;
	/*
	 * The clip is a batch key as much as the transform is: a batch carries
	 * one scissor rectangle, so geometry for a different window must start
	 * a new one.  Leaving it out of the test drew a window's geometry under
	 * its neighbour's scissor, which is worse than no scissor at all - it
	 * is intermittent, and it depends on draw order.
	 */
	if(ng3batches == 0 || !g3xform_eq(&g3batches[ng3batches-1].xform, &xf)
	|| !clip_eq(&g3batches[ng3batches-1].clip, &clip)){
		if(ng3batches >= MaxG3Batches){
			unlock(&mtl_geom_lock);
			return 0;
		}
		bi = ng3batches++;
		g3batches[bi].xform = xf;
		g3batches[bi].clip = clip;
		g3batches[bi].start = ng3triverts;
		g3batches[bi].count = 0;
	}else
		bi = ng3batches - 1;
	for(i = 1; i < n - 1; i++){
		v = &g3triverts[ng3triverts];
		v[0].x = vx[0]; v[0].y = vy[0]; v[0].z = vz[0];
		v[0].r = r; v[0].g = g; v[0].b = bl; v[0].a = al;
		v[1].x = vx[i]; v[1].y = vy[i]; v[1].z = vz[i];
		v[1].r = r; v[1].g = g; v[1].b = bl; v[1].a = al;
		v[2].x = vx[i+1]; v[2].y = vy[i+1]; v[2].z = vz[i+1];
		v[2].r = r; v[2].g = g; v[2].b = bl; v[2].a = al;
		ng3triverts += 3;
		g3batches[bi].count += 3;
	}
	metal_g3_calls++;
	metal_g3_tris += ntri;
	unlock(&mtl_geom_lock);
	return 1;
}

/*
 * fillpoly3 gouraud ('K'): same raw-model-space GPU-T&L path as
 * metal_queue_fillpoly3d, but one lit per vertex instead of one shared lit
 * for the whole face. vgmain/fgmain already interpolate whatever colour
 * each vertex carries in G3In.{r,g,b,a} - real hardware perspective-correct
 * interpolation, the actual definition of Gouraud shading - so the only
 * change needed here versus the flat version is computing a per-vertex
 * colour instead of one shared one; no shader or present-path changes.
 * Returns 0 ⇒ caller degrades to a single flat fill at the average lit.
 */
static void
gouraud_colour(float r0, float g0, float bl0, float al, float lit, GPUVert3D *v)
{
	if(lit < 0.0f)
		lit = 0.0f;
	v->r = r0*lit > 1.0f ? 1.0f : r0*lit;
	v->g = g0*lit > 1.0f ? 1.0f : g0*lit;
	v->b = bl0*lit > 1.0f ? 1.0f : bl0*lit;
	v->a = al;
}

static int
metal_queue_fillpoly3g(Memimage *dst, float *vx, float *vy, float *vz, float *lits, int n,
	Memimage *src, int op, float *model, float *proj,
	float mx, float cx, float my, float cy)
{
	float r0, g0, bl0, al;
	int i, ntri, need, bi, pw, ph;
	GPUXform xf;
	GPUVert3D *v;
	GPUClip clip;
	Point delta;

	if(vx == nil || vy == nil || vz == nil || lits == nil || n < 3)
		return 0;
	if(op != SoverD && op != S)
		return 0;
	if(dst == nil)
		return 0;
	dst = geom_target(dst, &delta, &clip);
	if(dst == nil)
		return 0;
	cx += (float)delta.x;
	cy += (float)delta.y;
	if(dst != gscreen && dst != screenimage)
		return 0;
	if(gscreen == nil || gscreen->data == nil || gscreen->data->bdata == nil)
		return 0;
	pw = Dx(gscreen->r);
	ph = Dy(gscreen->r);
	if(pw < 1 || ph < 1)
		return 0;
	if(src_rgba(src, &r0, &g0, &bl0, &al) < 0)
		return 0;
	ntri = n - 2;
	need = ntri * 3;
	if(need > MaxGPUTriVerts)
		return 0;

	g3xform_load(&xf, model, proj, mx, cx, my, cy, (float)pw, (float)ph);

	if(!metal_tri3d_reserve(need))
		return 0;
	/*
	 * The clip is a batch key as much as the transform is: a batch carries
	 * one scissor rectangle, so geometry for a different window must start
	 * a new one.  Leaving it out of the test drew a window's geometry under
	 * its neighbour's scissor, which is worse than no scissor at all - it
	 * is intermittent, and it depends on draw order.
	 */
	if(ng3batches == 0 || !g3xform_eq(&g3batches[ng3batches-1].xform, &xf)
	|| !clip_eq(&g3batches[ng3batches-1].clip, &clip)){
		if(ng3batches >= MaxG3Batches){
			unlock(&mtl_geom_lock);
			return 0;
		}
		bi = ng3batches++;
		g3batches[bi].xform = xf;
		g3batches[bi].clip = clip;
		g3batches[bi].start = ng3triverts;
		g3batches[bi].count = 0;
	}else
		bi = ng3batches - 1;
	for(i = 1; i < n - 1; i++){
		v = &g3triverts[ng3triverts];

		v[0].x = vx[0]; v[0].y = vy[0]; v[0].z = vz[0];
		gouraud_colour(r0, g0, bl0, al, lits[0], &v[0]);

		v[1].x = vx[i]; v[1].y = vy[i]; v[1].z = vz[i];
		gouraud_colour(r0, g0, bl0, al, lits[i], &v[1]);

		v[2].x = vx[i+1]; v[2].y = vy[i+1]; v[2].z = vz[i+1];
		gouraud_colour(r0, g0, bl0, al, lits[i+1], &v[2]);

		ng3triverts += 3;
		g3batches[bi].count += 3;
	}
	metal_g3_calls++;
	metal_g3_tris += ntri;
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
	GPUClip clip;

	if(op != SoverD && op != S)
		return 0;
	a = p;
	pix = line_pixdst(dst, &a, &a, &clip);
	if(pix == nil)
		return 0;
	if(pix != gscreen && pix != screenimage)
		return 0;
	if(src_rgba(src, &r, &g, &bl, &al) < 0)
		return 0;
	if(!metal_tri_reserve(6))
		return 0;
	if(!gtri_run(&clip, 6)){
		unlock(&mtl_geom_lock);
		return 0;
	}
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
	Memimage *col, *alp;
	int w, h, x, y;
	uchar *rgba, *p, *mp;
	MTLRegion region;

	if(img == nil || img->data == nil || img->data->bdata == nil)
		return nil;
	w = Dx(img->r);
	h = Dy(img->r);
	if(w < 1 || h < 1 || w > 2048 || h > 2048)
		return nil;
	/*
	 * Convert through memdraw rather than reading the sprite's own
	 * pixels and guessing at their layout.  This used to take depth 8
	 * to mean grey and replicate the byte into r, g and b - so every
	 * CMAP8 sprite, which is every .bit file in icons/temple, drew on
	 * the GPU in greyscale - and to take any depth 32 to be XBGR32.
	 * memdraw already knows every channel this tree has, including the
	 * palette, and gets sub-byte greys right as well; one scratch image
	 * for colour and one for coverage costs an allocation on a path
	 * whose result is cached anyway.
	 */
	col = allocmemimage(Rect(0, 0, w, h), XBGR32);
	if(col == nil)
		return nil;
	memfillcolor(col, DTransparent);
	memdraw(col, col->r, img, img->r.min, memopaque, ZP, S);
	alp = nil;
	if(mask != nil){
		alp = allocmemimage(Rect(0, 0, w, h), GREY8);
		if(alp == nil){
			freememimage(col);
			return nil;
		}
		memfillcolor(alp, DBlack);
		memdraw(alp, alp->r, mask, mask->r.min, memopaque, ZP, S);
	}
	rgba = malloc((size_t)w * h * 4);
	if(rgba == nil){
		freememimage(col);
		freememimage(alp);
		return nil;
	}
	for(y = 0; y < h; y++){
		p = byteaddr(col, Pt(0, y));
		mp = alp != nil ? byteaddr(alp, Pt(0, y)) : nil;
		for(x = 0; x < w; x++){
			/* XBGR32 lays a pixel out as R, G, B, X in memory. */
			rgba[(y*w+x)*4+0] = p[x*4+0];
			rgba[(y*w+x)*4+1] = p[x*4+1];
			rgba[(y*w+x)*4+2] = p[x*4+2];
			rgba[(y*w+x)*4+3] = 255;
			if(mp != nil && mp[x] == 0){
				/*
				 * PREMULTIPLIED alpha, and the reason is not
				 * tidiness.  The sampler filters, so at a mask
				 * edge it returns the average of a covered texel
				 * and an uncovered one.  Averaging straight
				 * colours mixes in whatever the invisible texel
				 * held - black, in every .bit sprite here, since
				 * that is what surrounds the shape - and the
				 * visible edge comes out dark.  Measured before
				 * this existed, white sprite on a green ground:
				 * the minimum green byte in the frame was 191
				 * where the software blit gives 255.  Zeroing a
				 * fully transparent texel's colour IS the
				 * premultiplied form for a binary mask (rgb*0).
				 * The pipeline's source RGB factor is One to
				 * match and ftmain keeps the product
				 * premultiplied; the three go together.
				 */
				rgba[(y*w+x)*4+0] = 0;
				rgba[(y*w+x)*4+1] = 0;
				rgba[(y*w+x)*4+2] = 0;
				rgba[(y*w+x)*4+3] = 0;
			}
		}
	}
	freememimage(col);
	freememimage(alp);
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


/*
 * Texture-backed draw images.
 *
 * An ordinary draw image's pixels come from the imagmem pool, so getting them
 * onto the GPU means a copy. Here the pixels are allocated from Metal instead
 * and the Memimage's bdata points straight at the buffer's contents, so on
 * unified memory bdata and the texture are the same bytes: memdraw writes are
 * visible to the GPU with no upload, and a hardware decoder can be pointed at
 * the same memory to write frames into an ordinary draw image.
 *
 * The construction is the one devdraw.c already uses for the screen -
 * allocmemimaged() over a caller-supplied Memdata, then override i->width with
 * the real stride. It is only valid when i->zero works out to 0, which is why
 * this restricts itself to images whose rectangle starts at the origin: zero
 * is derived from r.min inside allocmemimaged and is not recomputed here.
 *
 * Metal needs the row stride aligned, which memdraw does not otherwise
 * require, so the image is wider in memory than in pixels. memdraw handles
 * that natively - it is exactly what Memimage.width is for.
 *
 * Off unless INFERNO_TEXIMAGE is set: this changes where every draw image's
 * pixels live, which is not a default to take on quietly.
 */
enum { MaxTexImage = 64 };

static struct {
	Memimage	*img;
	Memdata		*md;
	id<MTLBuffer>	buf;
	id<MTLTexture>	tex;
} teximg[MaxTexImage];
static int	nteximg;
static int	teximg_on = -1;	/* -1 = not yet looked up */
static Lock	teximg_lock;
u32		teximg_alloced;	/* diagnostic counters */
u32		teximg_declined;
u32		teximg_nchan;	/* declined: not 32-bit */
u32		teximg_nsmall;	/* declined: too small to bother */
u32		teximg_freed;	/* returned through gpuimagefree */

static int
teximg_enabled(void)
{
	if(teximg_on < 0)
		teximg_on = getenv("INFERNO_TEXIMAGE") != nil;
	return teximg_on;
}

static Memimage*
metal_image_alloc(Rectangle r, u32 chan)
{
	Memimage *i;
	Memdata *md;
	id<MTLBuffer> buf;
	id<MTLTexture> tex;
	MTLTextureDescriptor *td;
	NSUInteger align;
	int w, h, bpr, slot, d;
	uintptr z;

	if(!teximg_enabled() || mtl_device == nil)
		return nil;
	w = Dx(r);
	h = Dy(r);
	if(w <= 0 || h <= 0){
		teximg_declined++;
		return nil;
	}
	if((d = chantodepth(chan)) != 32){
		teximg_nchan++;
		teximg_declined++;
		return nil;
	}
	if((vlong)w*h < 16*16){
		teximg_nsmall++;
		teximg_declined++;
		return nil;
	}

	lock(&teximg_lock);
	if(nteximg >= MaxTexImage){
		unlock(&teximg_lock);
		teximg_declined++;
		return nil;
	}
	unlock(&teximg_lock);

	align = [mtl_device minimumLinearTextureAlignmentForPixelFormat:
		MTLPixelFormatBGRA8Unorm];
	if(align < 4)
		align = 4;
	bpr = (w*4 + (int)align - 1) & ~((int)align - 1);

	buf = [mtl_device newBufferWithLength:(NSUInteger)bpr*h
		options:MTLResourceStorageModeShared];
	if(buf == nil){
		teximg_declined++;
		return nil;
	}
	td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
		MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
	td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	td.storageMode = MTLStorageModeShared;
	tex = [buf newTextureWithDescriptor:td offset:0 bytesPerRow:bpr];
	if(tex == nil){
		teximg_declined++;
		return nil;
	}

	md = mallocz(sizeof(Memdata), 1);
	if(md == nil){
		teximg_declined++;
		return nil;
	}
	md->ref = 1;
	md->base = nil;
	md->bdata = (uchar*)[buf contents];
	md->allocd = 0;	/* freememimage must not touch it; we own this */

	i = allocmemimaged(r, chan, md);
	if(i == nil){
		free(md);
		teximg_declined++;
		return nil;
	}
	/*
	 * Override the stride, and recompute zero to match it. allocmemimaged
	 * derived zero from the NATURAL stride, so leaving it would put every
	 * row at the wrong offset for any image not at the origin - devdraw
	 * gets away with assigning width alone for the screen only because the
	 * screen starts at (0,0), where zero is 0 either way. Same formula as
	 * allocmemimaged, with our stride.
	 */
	i->width = bpr/sizeof(u32);
	z = sizeof(u32)*(uintptr)i->width*r.min.y;
	if(r.min.x >= 0)
		z += (r.min.x*d)/8;
	else
		z -= (-r.min.x*d+7)/8;
	i->zero = -z;
	i->clipr = r;

	lock(&teximg_lock);
	slot = nteximg++;
	teximg[slot].img = i;
	teximg[slot].md = md;
	teximg[slot].buf = buf;
	teximg[slot].tex = tex;
	unlock(&teximg_lock);
	teximg_alloced++;
	return i;
}

static int
metal_image_free(Memimage *i)
{
	Memdata *md;
	int k;

	if(i == nil)
		return 0;
	/*
	 * Before anything else, and whether or not this image is one of
	 * ours: it is about to stop existing, so nothing may go on holding
	 * a texture under its address.  gpuimagefree is called for every
	 * non-screen image free, which makes this the one place that sees
	 * them all.
	 */
	lock(&mtl_geom_lock);
	metal_forget_sprite_tex(i);
	unlock(&mtl_geom_lock);
	lock(&teximg_lock);
	for(k = 0; k < nteximg; k++)
		if(teximg[k].img == i)
			break;
	if(k >= nteximg){
		unlock(&teximg_lock);
		return 0;	/* not ours: caller frees it the ordinary way */
	}
	md = teximg[k].md;
	teximg[k].buf = nil;	/* ARC releases the buffer and its texture */
	teximg[k].tex = nil;
	teximg[k] = teximg[--nteximg];
	unlock(&teximg_lock);

	freememimage(i);	/* allocd == 0, so this leaves md and the bytes */
	free(md);
	teximg_freed++;
	return 1;
}





/*
 * A decoder fed one coded sample at a time.
 *
 * This is the half that has to be here: configuring the media engine and
 * handing it frames. Locating those frames in a container is done in Limbo by
 * quicktime(2), so nothing about MP4 or QuickTime structure appears below -
 * only H.264 parameter sets and coded samples.
 *
 * Unlike the file-based session there is no staging and no read-ahead:
 * decoding starts on the first sample, and memory does not grow with the
 * length of the movie. That is what the staged path could not do.
 */
typedef struct Dec Dec;
struct Dec {
	CMVideoFormatDescriptionRef	fmt;
	VTDecompressionSessionRef	sess;
	int				nalsize;	/* length prefix bytes */
	CVPixelBufferRef		out;		/* newest frame */
};

static void
dec_output(void *ref, void *unused_frame, OSStatus st, VTDecodeInfoFlags unused_flags,
	CVImageBufferRef img, CMTime unused_pts, CMTime unused_dur)
{
	Dec *d = ref;

	USED(unused_frame); USED(unused_flags);	/* CMTime args are structs: USED() cannot take them */
	if(st != noErr || img == NULL)
		return;
	if(d->out != NULL)
		CVPixelBufferRelease(d->out);
	d->out = (CVPixelBufferRef)CVPixelBufferRetain((CVPixelBufferRef)img);
}

/*
 * avcC: version(1) profile(1) compat(1) level(1), then a byte whose low two
 * bits are lengthSizeMinusOne, a byte whose low five bits are the SPS count,
 * then each SPS as a 16-bit length and its bytes, then a PPS count and the
 * PPS entries the same way. VideoToolbox wants the parameter sets themselves,
 * so they are pulled out here rather than passed as an opaque blob.
 */
static void*
metal_dec_open(char *codec, uchar *extra, int nextra)
{
	Dec *d;
	const uint8_t *ps[8];
	size_t pssz[8];
	int nps, i, o, n, nsps, npps;
	OSStatus st;
	NSDictionary *attrs;
	VTDecompressionOutputCallbackRecord cb;

	if(codec == nil || strcmp(codec, "avc1") != 0){
		kwerrstr("draw video: only avc1 is supported here");
		return nil;
	}
	if(extra == nil || nextra < 7 || extra[0] != 1){
		kwerrstr("draw video: avc1 needs avcC parameter sets");
		return nil;
	}

	d = mallocz(sizeof(Dec), 1);
	if(d == nil)
		return nil;
	d->nalsize = (extra[4] & 3) + 1;

	nps = 0;
	o = 5;
	nsps = extra[o++] & 0x1f;
	for(i = 0; i < nsps && nps < nelem(ps); i++){
		if(o + 2 > nextra)
			goto bad;
		n = (extra[o]<<8) | extra[o+1];
		o += 2;
		if(o + n > nextra)
			goto bad;
		ps[nps] = extra + o;
		pssz[nps] = n;
		nps++;
		o += n;
	}
	if(o >= nextra)
		goto bad;
	npps = extra[o++];
	for(i = 0; i < npps && nps < nelem(ps); i++){
		if(o + 2 > nextra)
			goto bad;
		n = (extra[o]<<8) | extra[o+1];
		o += 2;
		if(o + n > nextra)
			goto bad;
		ps[nps] = extra + o;
		pssz[nps] = n;
		nps++;
		o += n;
	}
	if(nps < 2)
		goto bad;

	st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
		nps, ps, pssz, d->nalsize, &d->fmt);
	if(st != noErr){
		kwerrstr("draw video: bad H.264 parameter sets");
		free(d);
		return nil;
	}

	/* BGRA out, matching Inferno's x8r8g8b8 byte order. */
	attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
	memset(&cb, 0, sizeof(cb));
	cb.decompressionOutputCallback = dec_output;
	cb.decompressionOutputRefCon = d;
	st = VTDecompressionSessionCreate(kCFAllocatorDefault, d->fmt, NULL,
		(__bridge CFDictionaryRef)attrs, &cb, &d->sess);
	if(st != noErr){
		CFRelease(d->fmt);
		free(d);
		kwerrstr("draw video: cannot create a decompression session");
		return nil;
	}
	return d;
bad:
	kwerrstr("draw video: malformed avcC");
	free(d);
	return nil;
}

static int
metal_dec_sample(void *dec, uchar *buf, int n, Memimage *dst)
{
	Dec *d = dec;
	CMBlockBufferRef bb = NULL;
	CMSampleBufferRef sb = NULL;
	CVPixelBufferRef pb;
	OSStatus st;
	size_t sz;
	uchar *base, *sp;
	size_t sbpr;
	int w, h, dbpr, y, sw, sh, cw, ch, rc;

	if(d == nil || buf == nil || n <= 0){
		kwerrstr("draw video: nothing to decode");
		return -1;
	}
	if(chantodepth(dst->chan) != 32){
		kwerrstr("draw video: destination must be a 32-bit image");
		return -1;
	}

	/* The sample is already length-prefixed NAL units, which is what the
	 * format description says to expect, so it goes in as it stands. */
	sz = n;
	st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, buf, sz,
		kCFAllocatorNull, NULL, 0, sz, 0, &bb);
	if(st != noErr){
		kwerrstr("draw video: cannot wrap sample");
		return -1;
	}
	st = CMSampleBufferCreateReady(kCFAllocatorDefault, bb, d->fmt, 1, 0, NULL,
		1, &sz, &sb);
	if(st != noErr){
		CFRelease(bb);
		kwerrstr("draw video: cannot build sample buffer");
		return -1;
	}

	if(d->out != NULL){
		CVPixelBufferRelease(d->out);
		d->out = NULL;
	}
	/*
	 * Flags 0: decode synchronously, in decode order, one picture out per
	 * sample in. With temporal processing enabled the decoder is free to
	 * emit on its own schedule, and since only the newest picture is kept
	 * here, feeding sample 1 could hand back frame 4 - which is exactly
	 * what happened. A caller that wants presentation order can reorder
	 * using the timestamps quicktime(2) already provides.
	 */
	st = VTDecompressionSessionDecodeFrame(d->sess, sb, 0, NULL, NULL);
	if(st == noErr)
		VTDecompressionSessionWaitForAsynchronousFrames(d->sess);
	CFRelease(sb);
	CFRelease(bb);
	if(st != noErr){
		kwerrstr("draw video: decode failed");
		return -1;
	}

	pb = d->out;
	if(pb == NULL)
		return 0;	/* accepted, no picture yet: normal while reordering */

	rc = -1;
	CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	sp = CVPixelBufferGetBaseAddress(pb);
	if(sp != nil){
		w = Dx(dst->r);
		h = Dy(dst->r);
		base = byteaddr(dst, dst->r.min);
		dbpr = dst->width * sizeof(u32);
		sbpr = CVPixelBufferGetBytesPerRow(pb);
		sw = (int)CVPixelBufferGetWidth(pb);
		sh = (int)CVPixelBufferGetHeight(pb);
		cw = sw < w? sw: w;
		ch = sh < h? sh: h;
		for(y = 0; y < ch; y++)
			memmove(base + (size_t)y*dbpr, sp + (size_t)y*sbpr, (size_t)cw*4);
		rc = 0;
	}else
		kwerrstr("draw video: frame has no pixels");
	CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	return rc;
}

static void
metal_dec_close(void *dec)
{
	Dec *d = dec;

	if(d == nil)
		return;
	if(d->sess != NULL){
		VTDecompressionSessionInvalidate(d->sess);
		CFRelease(d->sess);
	}
	if(d->fmt != NULL)
		CFRelease(d->fmt);
	if(d->out != NULL)
		CVPixelBufferRelease(d->out);
	free(d);
}

/*
 * A streaming decode session.
 *
 * The encoded stream is pushed in from devdraw in chunks and appended to a
 * staged file, then read back by AVAssetReader, which does demux and hardware
 * decode together. Frames come out sequentially, so playing a movie costs one
 * pass rather than re-reading it per frame.
 *
 * The staging is the honest limitation: AVFoundation wants an asset URL, and
 * the bytes arrive through Inferno's namespace rather than from a host path.
 * Chunking means memory stays bounded whatever the size of the movie, but the
 * file is still copied to local disk before the first frame, so a session
 * cannot start decoding until the stream ends. Removing that needs the demux
 * done on this side - feeding VTDecompressionSession from a container parser
 * rather than handing AVFoundation a file - and this tree already has a
 * QuickTime container reader in module/quicktime.m that could do it.
 */
typedef struct Vsess Vsess;
struct Vsess {
	NSString		*path;
	NSFileHandle		*w;
	AVAssetReader		*rd;
	AVAssetReaderTrackOutput *out;
	int			started;
};

static void*
metal_video_open(void)
{
	Vsess *v;
	static int seq;

	v = mallocz(sizeof(Vsess), 1);
	if(v == nil)
		return nil;
	v->path = [NSTemporaryDirectory() stringByAppendingPathComponent:
		[NSString stringWithFormat:@"inferno-vid-%d-%d.mov",
			(int)getpid(), seq++]];
	[[NSFileManager defaultManager] createFileAtPath:v->path contents:nil attributes:nil];
	v->w = [NSFileHandle fileHandleForWritingAtPath:v->path];
	if(v->w == nil){
		free(v);
		return nil;
	}
	/* ARC will not keep these alive through a void* the kernel holds. */
	CFBridgingRetain(v->path);
	CFBridgingRetain(v->w);
	return v;
}

static int
metal_video_write(void *sess, uchar *buf, int n)
{
	Vsess *v = sess;

	if(v == nil || v->started){
		kwerrstr("draw video: session already started");
		return -1;
	}
	@try {
		[v->w writeData:[NSData dataWithBytesNoCopy:buf length:n freeWhenDone:NO]];
	} @catch(NSException *e){
		kwerrstr("draw video: cannot stage stream");
		return -1;
	}
	return 0;
}

static int
metal_video_start(void *sess)
{
	Vsess *v = sess;
	AVURLAsset *asset;
	AVAssetTrack *track;
	NSError *err = nil;

	if(v == nil || v->started){
		kwerrstr("draw video: session already started");
		return -1;
	}
	[v->w closeFile];
	v->w = nil;

	asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:v->path] options:nil];
	track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
	if(track == nil){
		kwerrstr("draw video: no video track");
		return -1;
	}
	v->rd = [AVAssetReader assetReaderWithAsset:asset error:&err];
	if(v->rd == nil){
		kwerrstr("draw video: cannot read movie");
		return -1;
	}
	v->out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
		outputSettings:@{ (id)kCVPixelBufferPixelFormatTypeKey:
			@(kCVPixelFormatType_32BGRA) }];
	[v->rd addOutput:v->out];
	if(![v->rd startReading]){
		kwerrstr("draw video: cannot start reading");
		return -1;
	}
	CFBridgingRetain(v->rd);
	CFBridgingRetain(v->out);
	v->started = 1;
	return 0;
}

static int
metal_video_next(void *sess, Memimage *dst)
{
	Vsess *v = sess;
	CMSampleBufferRef sb;
	CVPixelBufferRef pb;
	uchar *base, *sp;
	size_t sbpr;
	int w, h, dbpr, y, sw, sh, cw, ch, rc;

	if(v == nil || !v->started){
		kwerrstr("draw video: session not started");
		return -1;
	}
	if(chantodepth(dst->chan) != 32){
		kwerrstr("draw video: destination must be a 32-bit image");
		return -1;
	}
	sb = [v->out copyNextSampleBuffer];
	if(sb == NULL){
		kwerrstr("draw video: end of stream");
		return -1;
	}
	pb = CMSampleBufferGetImageBuffer(sb);
	if(pb == NULL){
		CFRelease(sb);
		kwerrstr("draw video: frame carries no image");
		return -1;
	}
	rc = -1;
	CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	sp = CVPixelBufferGetBaseAddress(pb);
	if(sp != nil){
		w = Dx(dst->r);
		h = Dy(dst->r);
		base = byteaddr(dst, dst->r.min);
		dbpr = dst->width * sizeof(u32);
		sbpr = CVPixelBufferGetBytesPerRow(pb);
		sw = (int)CVPixelBufferGetWidth(pb);
		sh = (int)CVPixelBufferGetHeight(pb);
		cw = sw < w? sw: w;
		ch = sh < h? sh: h;
		for(y = 0; y < ch; y++)
			memmove(base + (size_t)y*dbpr, sp + (size_t)y*sbpr, (size_t)cw*4);
		rc = 0;
	}else
		kwerrstr("draw video: frame has no pixels");
	CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	CFRelease(sb);
	return rc;
}

static void
metal_video_close(void *sess)
{
	Vsess *v = sess;

	if(v == nil)
		return;
	if(v->rd != nil){
		[v->rd cancelReading];
		CFBridgingRelease((__bridge CFTypeRef)v->rd);
		CFBridgingRelease((__bridge CFTypeRef)v->out);
	}
	if(v->w != nil){
		[v->w closeFile];
		CFBridgingRelease((__bridge CFTypeRef)v->w);
	}
	[[NSFileManager defaultManager] removeItemAtPath:v->path error:nil];
	CFBridgingRelease((__bridge CFTypeRef)v->path);
	free(v);
}

/*
 * One frame of a movie, decoded by the platform's media engine.
 *
 * AVAssetReader does demux and hardware decode together and hands back
 * CVPixelBuffers, which is far less machinery than driving
 * VTDecompressionSession directly and uses the same fixed-function decoder.
 *
 * INTERIM, and the limitation is real: the encoded bytes arrive whole and are
 * staged to a temporary file, because AVFoundation wants an asset URL and the
 * bytes came through Inferno's namespace rather than from a host path. That is
 * fine for a short clip and wrong for a real film - a feature-length movie
 * must be streamed into the device, not handed over entire. Streaming is the
 * next piece of work; see doc/hpc-plan.md item 6. What this does establish is
 * the decode path itself and that frames land in an ordinary draw image.
 */
static int
metal_movie_frame(Memimage *dst, uchar *enc, int nenc, int frame)
{
	NSString *tmp;
	NSData *data;
	AVURLAsset *asset;
	AVAssetTrack *track;
	AVAssetReader *rd;
	AVAssetReaderTrackOutput *out;
	CMSampleBufferRef sb;
	CVPixelBufferRef pb;
	NSError *err = nil;
	uchar *base, *sp;
	size_t sbpr;
	int w, h, dbpr, y, i, rc;

	w = Dx(dst->r);
	h = Dy(dst->r);
	tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
		[NSString stringWithFormat:@"inferno-frame-%d.mov", (int)getpid()]];
	data = [NSData dataWithBytesNoCopy:enc length:nenc freeWhenDone:NO];
	if(![data writeToFile:tmp atomically:NO]){
		kwerrstr("draw video: cannot stage movie data");
		return -1;
	}

	rc = -1;
	asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:tmp] options:nil];
	track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
	if(track == nil){
		kwerrstr("draw video: no video track");
		goto out;
	}
	rd = [AVAssetReader assetReaderWithAsset:asset error:&err];
	if(rd == nil){
		kwerrstr("draw video: cannot read movie");
		goto out;
	}
	/* BGRA out, so it matches Inferno's x8r8g8b8 byte order with no
	 * conversion of our own. */
	out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track
		outputSettings:@{ (id)kCVPixelBufferPixelFormatTypeKey:
			@(kCVPixelFormatType_32BGRA) }];
	[rd addOutput:out];
	if(![rd startReading]){
		kwerrstr("draw video: cannot start reading");
		goto out;
	}

	pb = NULL;
	for(i = 0; i <= frame; i++){
		sb = [out copyNextSampleBuffer];
		if(sb == NULL){
			kwerrstr("draw video: movie has no frame %d", frame);
			goto out;
		}
		if(i < frame){
			CFRelease(sb);
			continue;
		}
		pb = CMSampleBufferGetImageBuffer(sb);
		if(pb == NULL){
			CFRelease(sb);
			kwerrstr("draw video: frame %d has no image", frame);
			goto out;
		}
		CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
		sp = CVPixelBufferGetBaseAddress(pb);
		sbpr = CVPixelBufferGetBytesPerRow(pb);
		base = byteaddr(dst, dst->r.min);
		dbpr = dst->width * sizeof(u32);
		if(sp != nil){
			int sw = (int)CVPixelBufferGetWidth(pb);
			int sh = (int)CVPixelBufferGetHeight(pb);
			int cw = sw < w? sw: w;
			int ch = sh < h? sh: h;
			for(y = 0; y < ch; y++)
				memmove(base + (size_t)y*dbpr, sp + (size_t)y*sbpr, (size_t)cw*4);
			rc = 0;
		}
		CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
		CFRelease(sb);
		break;
	}
	if(rc != 0 && pb == NULL)
		kwerrstr("draw video: no frame decoded");
out:
	[[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
	return rc;
}

/*
 * Hardware image decode straight into a draw image's pixels.
 *
 * ImageIO uses the platform's JPEG hardware, which this machine has (see
 * emu/MacOSX/vtcaps.m). CoreGraphics is pointed at the Memimage's own bdata,
 * so the decoded pixels land directly in the destination - and when that
 * destination is texture-backed (INFERNO_TEXIMAGE) they land in GPU-visible
 * memory, never passing through the Limbo heap.
 *
 * Honest about the copy count: this is decode-then-convert-into-place, one
 * CoreGraphics pass, not zero copies. Zero would need the decoder to produce a
 * CVPixelBuffer and that buffer to be the image's backing, which is the shape
 * video wants (VTDecompressionSession plus CVMetalTextureCache) and is why
 * this is written as a hook rather than inline.
 *
 * Only 32-bit destinations: a mask or an 8-bit image has no sensible bitmap
 * context here, and refusing is better than quietly producing wrong pixels.
 */
static int
metal_image_decode(Memimage *dst, uchar *enc, int nenc, int frame)
{
	CFDataRef cfdata;
	CGImageSourceRef src;
	CGImageRef img;
	CGColorSpaceRef cs;
	CGContextRef ctx;
	uchar *base;
	int w, h, bpr;

	if(dst == nil || enc == nil || nenc <= 0){
		kwerrstr("draw video: nothing to decode");
		return -1;
	}
	if(chantodepth(dst->chan) != 32){
		kwerrstr("draw video: destination must be a 32-bit image");
		return -1;
	}
	w = Dx(dst->r);
	h = Dy(dst->r);
	if(w <= 0 || h <= 0){
		kwerrstr("draw video: empty destination");
		return -1;
	}

	if(frame >= 0)
		return metal_movie_frame(dst, enc, nenc, frame);

	/* The bytes came through Inferno's namespace; CoreGraphics never sees
	 * a path and so cannot reach anything this process could not. */
	cfdata = CFDataCreateWithBytesNoCopy(nil, enc, nenc, kCFAllocatorNull);
	if(cfdata == nil){
		kwerrstr("draw video: out of memory");
		return -1;
	}
	src = CGImageSourceCreateWithData(cfdata, nil);
	CFRelease(cfdata);
	if(src == nil){
		kwerrstr("draw video: unrecognised image format");
		return -1;
	}
	img = CGImageSourceCreateImageAtIndex(src, 0, nil);
	CFRelease(src);
	if(img == nil){
		kwerrstr("draw video: cannot decode image");
		return -1;
	}

	/* byteaddr gives the first pixel of r; width is in u32 words. */
	base = byteaddr(dst, dst->r.min);
	bpr = dst->width * sizeof(u32);
	cs = CGColorSpaceCreateDeviceRGB();
	/* Inferno's x8r8g8b8 is b,g,r,x in memory order, which is what
	 * little-endian BGRA8 means to CoreGraphics. */
	ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
		kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
	CGColorSpaceRelease(cs);
	if(ctx == nil){
		CGImageRelease(img);
		kwerrstr("draw video: cannot address destination pixels");
		return -1;
	}
	/* Scales to fit, so a caller may size the image as it likes rather
	 * than having to know the file's dimensions first. */
	CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
	CGContextFlush(ctx);
	CGContextRelease(ctx);
	CGImageRelease(img);
	return 0;
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
 * Drop any cached sprite texture that names this image, as sprite or as
 * mask.  Without it the cache is keyed on the Memimage pointer, its data
 * pointer and its size and NOTHING about its contents, so a freed sprite
 * and a differently-coloured one allocated straight afterwards land on
 * the same addresses, hit the cache, and the second draws with the
 * first's pixels.  Found by measurement, not by reading: draw3dbench(1)'s
 * two mask-edge cases were both 64x64 and the second silently reused the
 * first's texture, which made a real defect read as "no defect".
 */
static void
metal_forget_sprite_tex(Memimage *i)
{
	int k;

	for(k = 0; k < nsprtexcache; k++){
		if(sprtexcache[k].img != i && sprtexcache[k].mask != i)
			continue;
		sprtexcache[k].tex = nil;
		sprtexcache[k] = sprtexcache[--nsprtexcache];
		k--;
	}
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

/*
 * Textured Metal quad, screen space, optionally mirrored, at a given
 * depth.  Both sprite entry points end up here: sprite3 ('j') arrives
 * with an eye z it wants turned into depth, sprite2d ('J') with no depth
 * of its own at all.
 */
static int
metal_queue_sprite_at(Memimage *dst, Point sp, int sw, int sh, float z,
	Memimage *img, Memimage *mask, float degz, int flipx, int nearest, int op)
{
	Memimage *pix;
	Point a;
	float hx, hy, cs, sn, rad, lx, ly, rx, ry, cxf, cyf;
	GPUSprite *spr;
	id<MTLTexture> tex;
	int i, bw, bh;
	GPUClip clip;
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
	pix = line_pixdst(dst, &a, &a, &clip);
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
	/*
	 * The same half pixel devdraw.c's d3spritez() has to allow for, and
	 * for the same reason: transformsprite() in appl/math/draw3ddev.b
	 * puts its box at centre - bw/2 with INTEGER division and then
	 * samples about the box's real centre bw/2.0, so the effective
	 * centre is half a pixel right and down whenever the box is odd -
	 * which is whenever the sprite has an odd dimension.  Centring the
	 * quad on the requested point instead left every odd-sized sprite
	 * sampling a texel out: sprite2dtest(1)'s on-screen family passed
	 * at 8, 16 and 64 and failed at 7 and 33, every rotation, with the
	 * right coverage and the wrong content.
	 */
	bw = (int)((fabsf(cs)*hx + fabsf(sn)*hy)*2.0f) + 2;
	bh = (int)((fabsf(sn)*hx + fabsf(cs)*hy)*2.0f) + 2;
	cxf = (float)(a.x - bw/2) + bw*0.5f;
	cyf = (float)(a.y - bh/2) + bh*0.5f;
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
	spr->nearest = nearest;
	spr->clip = clip;
	for(i = 0; i < 6; i++){
		lx = corner[i][0] * hx;
		ly = corner[i][1] * hy;
		rx = lx * cs - ly * sn;
		ry = lx * sn + ly * cs;
		spr->v[i].x = cxf + rx;
		spr->v[i].y = cyf + ry;
		spr->v[i].z = z;
		/* Mirroring is a u flip, not a negative width: the quad's
		 * corners and its rotation stay exactly as they are, so the
		 * sprite turns about the same point either way. */
		spr->v[i].u = flipx ? 1.0f - uv[i][0] : uv[i][0];
		spr->v[i].v = uv[i][1];
		spr->v[i].r = 1.0f;
		spr->v[i].g = 1.0f;
		spr->v[i].b = 1.0f;
		spr->v[i].a = 1.0f;
	}
	ngsprites++;
	metal_spr_calls++;
	unlock(&mtl_geom_lock);
	return 1;
}

/* sprite3 ('j'): placed by a projected world point, depth-tested. */
static int
metal_queue_sprite(Memimage *dst, Point sp, int sw, int sh, float ez,
	Memimage *img, Memimage *mask, float degz, int op)
{
	return metal_queue_sprite_at(dst, sp, sw, sh, eye_to_depth(ez),
		img, mask, degz, 0, 0, op);
}

/*
 * sprite2d ('J'): screen space, no projection, no depth of its own.
 * Depth 0 is nearer than anything eye_to_depth can produce, so it passes
 * a LessEqual test whatever is already there - which is the 2D
 * behaviour, painter order, that the Limbo resampler this replaces has.
 */
static int
metal_queue_sprite2d(Memimage *dst, Point sp, int sw, int sh,
	Memimage *img, Memimage *mask, float degz, int flipx, int op)
{
	return metal_queue_sprite_at(dst, sp, sw, sh, 0.0f,
		img, mask, degz, flipx, 1, op);
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
	GPUClip clip;

	USED(thick);
	if(op != SoverD && op != S)
		return 0;
	if(a < 1) a = 1;
	if(b < 1) b = 1;
	p0 = c;
	p1 = c;
	pix = line_pixdst(dst, &p0, &p1, &clip);
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
		if(!gtri_run(&clip, need)){
			unlock(&mtl_geom_lock);
			return 0;
		}
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
	int i, voff, curnearest;
	GPUClip curclip;
	float wh[2];
	id<MTLBuffer> vbuf;
	id<MTLRenderCommandEncoder> enc;
	id<MTLTexture> curtex;
	MTLRenderPassDescriptor *rp;
	MTLLoadAction zload;
	MTLSamplerDescriptor *sd;
	static id<MTLSamplerState> sprsamp, sprsampn;

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
		/*
		 * A second, point-sampling one for sprite2d.  Two reasons, and
		 * the second is the binding one.  The art is 8x8-grid pixel
		 * art from TempleOS, and magnifying it bilinearly blurs it -
		 * not what a GPU is for here.  And the same sprite2d call
		 * reaches this path or the Limbo resampler depending only on
		 * whether the destination is a GPU target, so anything but
		 * point sampling would make a sprite change appearance the
		 * moment it moved from a window into an offscreen buffer.
		 * Point sampling is what lets sprite2dtest(1) check GPU output
		 * for exact equality against a plain draw(2).
		 * sprite3, which places a billboard by projection and has no
		 * such exact oracle, keeps the smooth filter.
		 */
		sd = [[MTLSamplerDescriptor alloc] init];
		sd.minFilter = MTLSamplerMinMagFilterNearest;
		sd.magFilter = MTLSamplerMinMagFilterNearest;
		sprsampn = [mtl_device newSamplerStateWithDescriptor:sd];
	}
	wh[0] = (float)pw;
	wh[1] = (float)ph;
	/* Not consumed yet: if every sprite below fails to encode, the clear
	 * must stay pending rather than being dropped on the floor. */
	zload = mtl_zclear ? MTLLoadActionClear : MTLLoadActionLoad;

	/*
	 * One render pass per RUN of sprites sharing a texture and sampler,
	 * not one per sprite.  A render command encoder is a whole pass -
	 * the attachments are loaded and stored around it - so a field of
	 * five hundred identical bushes used to be five hundred passes over
	 * the drawable, which is what made a GPU sprite cost many times a
	 * GPU triangle even though both arrive as one draw(3) message.
	 * Order is preserved: the sprites are drawn in the order queued,
	 * and within a pass fragments rasterise in draw order, so depth and
	 * SoverD blending behave exactly as they did.
	 */
	enc = nil;
	curtex = nil;
	curnearest = -1;
	curclip.x0 = curclip.y0 = curclip.x1 = curclip.y1 = -1;
	for(i = 0; i < ngsprites; i++){
		if(gsprites[i].tex == nil || metal_vertex_data(cmd, gsprites[i].v,
		    sizeof(GPUTexVert) * 6, &vbuf, &voff) < 0)
			continue;
		/* the clip is encoder state like the texture is: a sprite for a
		 * different window needs its own pass, and its own scissor */
		if(enc != nil && (gsprites[i].tex != curtex
		    || gsprites[i].nearest != curnearest
		    || !clip_eq(&gsprites[i].clip, &curclip))){
			[enc endEncoding];
			enc = nil;
		}
		if(enc == nil){
			rp = [MTLRenderPassDescriptor renderPassDescriptor];
			rp.colorAttachments[0].texture = drawabletex;
			rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
			rp.colorAttachments[0].storeAction = MTLStoreActionStore;
			rp.depthAttachment.texture = depthtex;
			rp.depthAttachment.loadAction = zload;
			rp.depthAttachment.storeAction = MTLStoreActionStore;
			rp.depthAttachment.clearDepth = 1.0;
			enc = [cmd renderCommandEncoderWithDescriptor:rp];
			if(enc == nil)
				continue;	/* clear still pending for the next sprite */
			zload = MTLLoadActionLoad;
			mtl_zclear = 0;	/* this pass will run and carries the clear */
			curtex = gsprites[i].tex;
			curnearest = gsprites[i].nearest;
			curclip = gsprites[i].clip;
			if(!clip_scissor(enc, &curclip, pw, ph)){
				[enc endEncoding];
				enc = nil;
				gsprites[i].tex = nil;
				continue;
			}
			[enc setRenderPipelineState:mtl_sprite_pipe];
			[enc setDepthStencilState:mtl_zenable ? mtl_depth_on : mtl_depth_off];
			[enc setVertexBytes:wh length:sizeof(wh) atIndex:1];
			[enc setFragmentTexture:curtex atIndex:0];
			[enc setFragmentSamplerState:curnearest ? sprsampn : sprsamp
				atIndex:0];
		}
		[enc setVertexBuffer:vbuf offset:voff atIndex:0];
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
		gsprites[i].tex = nil;
	}
	if(enc != nil)
		[enc endEncoding];
	ngsprites = 0;
	unlock(&mtl_geom_lock);
}

/*
 * Materialise queued presentation-only geometry into the Inferno softscreen.
 * draw(3) reads are ordered after writes, so readpixels must not observe the
 * pre-Metal image.  Render into a shared off-screen target with the same
 * pipelines/depth state, wait for completion, and copy its bytes back.
 */
static void	metal_blit_tex(id<MTLCommandBuffer>, id<MTLTexture>,
			id<MTLRenderPipelineState>, id<MTLTexture>, id<MTLTexture>,
			id<MTLSamplerState>);
static void	metal_overlay_soft(id<MTLCommandBuffer>, id<MTLTexture>,
			id<MTLTexture>, id<MTLTexture>, id<MTLSamplerState>);

/* Nearest, and shared: present built its own and the readback needs the
 * same one now that both composite the frame the same way. */
static id<MTLSamplerState>
metal_nearest_samp(void)
{
	static id<MTLSamplerState> s;
	MTLSamplerDescriptor *sd;

	if(s == nil){
		sd = [[MTLSamplerDescriptor alloc] init];
		sd.minFilter = MTLSamplerMinMagFilterNearest;
		sd.magFilter = MTLSamplerMinMagFilterNearest;
		s = [mtl_device newSamplerStateWithDescriptor:sd];
	}
	return s;
}

static void
metal_readback_geom(void)
{
	int pw, ph, bpl;
	id<MTLTexture> tex, depthtex, soft, under;
	id<MTLCommandBuffer> cmd;
	MTLTextureDescriptor *td;
	MTLRegion region;
	uchar *p;

	if(nglines == 0 && ngtriverts == 0 && ng3triverts == 0 && ngsprites == 0)
		return;
	metal_readbacks++;
	if(gscreen == nil || gscreen->data == nil || gscreen->data->bdata == nil)
		return;
	pw = Dx(gscreen->r);
	ph = Dy(gscreen->r);
	if(pw < 1 || ph < 1)
		return;
	/*
	 * Kept, like every other target in this file.  This function runs
	 * once a frame now, and it was allocating a fresh full-screen
	 * texture each time - a megabyte and a half of driver churn per
	 * frame for a surface whose size only changes when the window does.
	 */
	if(mtl_rbtex != nil && mtl_rbtex_w == pw && mtl_rbtex_h == ph)
		tex = mtl_rbtex;
	else{
		td = [MTLTextureDescriptor
			texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
			width:pw height:ph mipmapped:NO];
		td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
		td.storageMode = MTLStorageModeShared;
		mtl_rbtex = [mtl_device newTextureWithDescriptor:td];
		mtl_rbtex_w = pw;
		mtl_rbtex_h = ph;
		tex = mtl_rbtex;
	}
	depthtex = metal_depth_tex(pw, ph);
	if(tex == nil || depthtex == nil)
		return;
	/* Reached directly from a draw(3) read as well as from the flush;
	 * either way these uploads feed the compositor, not the display. */
	mtl_materialising = 1;
	/*
	 * Compose the frame the way present does, and for the same reason.
	 *
	 * This used to upload the CURRENT softscreen and draw the geometry
	 * on top of it.  The current softscreen already contains everything
	 * the program drew after its 3D - its head-up display, its reticle,
	 * its score - so the geometry went over the top of all of it and
	 * every one of those was lost.  gorge(1) read back with no HUD at
	 * all: 0 white pixels against the software provider's 1277.
	 *
	 * present_softscreen_body() has always had this right.  metal_flush_geom()
	 * snapshots the softscreen as it was BEFORE the 3D - mtl_under - on
	 * the first 2D draw after geometry is queued, and present then draws
	 * under, then the geometry, then metal_overlay_soft() puts back the
	 * pixels that changed afterwards.  The readback simply did not use
	 * any of it.  Now it does, and the two paths agree by construction
	 * rather than by coincidence.
	 */
	soft = nil;
	under = nil;
	if(mtl_have_under && mtl_under != nil){
		soft = metal_soft_tex(pw, ph);
		under = mtl_under;
	}
	if(soft != nil){
		/* the softscreen texture is the post-3D CPU state */
		metal_upload_damage(soft, mtl_tex_fresh);
		mtl_tex_fresh = 0;
	}else
		metal_upload_damage(tex, 1);
	cmd = [mtl_queue commandBuffer];
	if(cmd == nil)
		return;
	if(soft != nil)
		metal_blit_tex(cmd, tex, mtl_pipe, under, nil, metal_nearest_samp());
	mtl_soft_defer = 1;
	metal_present_tris(cmd, tex, depthtex, pw, ph);
	metal_present_tris3d(cmd, tex, depthtex, pw, ph);
	metal_present_lines(cmd, tex, depthtex, pw, ph);
	metal_present_sprites(cmd, tex, depthtex, pw, ph);
	mtl_soft_defer = 0;
	if(soft != nil)
		metal_overlay_soft(cmd, tex, soft, under, metal_nearest_samp());
	[cmd commit];
	{
		vlong t0rb = osusectime();
		[cmd waitUntilCompleted];
		metal_rbwait_us += osusectime() - t0rb;
	}
	p = byteaddr(gscreen, gscreen->r.min);
	bpl = gscreen->width * sizeof(u32);
	region = MTLRegionMake2D(0, 0, pw, ph);
	[tex getBytes:p bytesPerRow:bpl fromRegion:region mipmapLevel:0];
	/* Now the texture has landed, draw whatever the GPU passes could
	 * not; doing it earlier would have been overwritten just above. */
	metal_soft_replay();
	/*
	 * The composite is in gscreen and the texture does not have it, so
	 * the next upload has to carry the whole screen.  Say that by marking
	 * every tile dirty through metal_mark_tiles(), which freezes those
	 * pixels into soft_shadow as it goes - NOT by clearing the damage map
	 * and setting mtl_tex_fresh, which is what this did.
	 *
	 * That distinction is the whole of it.  A tile-by-tile upload reads
	 * soft_shadow, the frozen image that flushmemscreen() agreed to; a
	 * `full` upload reads gscreen's live bytes instead, because it has to
	 * cover regions no flush ever snapshotted.  Since this function runs
	 * once a frame it made every present a full upload, and every present
	 * therefore drew the softscreen as it stood at some arbitrary instant
	 * of the interpreter's next frame - often just after that frame's
	 * clear and before anything had been drawn into it.  Measured with a
	 * counter comparing the live bytes against the snapshot at upload
	 * time: 30 torn uploads per 30 frames, about 91500 pixels each on a
	 * 640x480 screen, which is the whole of castlefrankenstein(1)'s view.
	 * On the screen that is a window that flickers between the frame and
	 * the bare clear.
	 *
	 * The shadow now gets the composite, so the upload can come from it
	 * and every presented frame is one the program actually finished.
	 */
	lock(&soft_dirty_lock);
	if(soft_dirty != nil)
		memset(soft_upload_dirty, 0, soft_ntx * soft_nty);
	metal_mark_tiles(gscreen, gscreen->r, 1, 0);
	unlock(&soft_dirty_lock);
	mtl_have_under = 0;
	mtl_materialising = 0;
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
static void	present_softscreen_body(void);

/* Same shim, same reason: present_softscreen_body() has several early
 * returns and a timer at each is one to forget. */
static void
present_softscreen(void)
{
	vlong t0;

	uvlong d;

	t0 = osusectime();
	present_softscreen_body();
	metal_present_us += osusectime() - t0;
	metal_presents++;
	if(present_last_us != 0 && npresent_gap < nelem(present_gap))
		present_gap[npresent_gap++] = (int)(t0 - present_last_us);
	present_last_us = t0;
	d = soft_seq - presented_seq;
	presented_seq = soft_seq;
	if(d == 0)
		present_dup++;
	else if(d == 1)
		present_once++;
	else if(d == 2)
		present_skip2++;
	else
		present_skip3++;
}

static void
present_softscreen_body(void)
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

	have_geom = nglines > 0 || ngtriverts > 0 || ng3triverts > 0 || ngsprites > 0;
	overlay = have_geom && mtl_have_under && mtl_under != nil;
	under = mtl_under;
	/* Do CPU staging and enqueue texture uploads before acquiring a scarce
	 * drawable; this shortens drawable ownership and avoids frame-pacing stalls. */
	/*
	 * nextDrawable BLOCKS until the display hands one back, so the time
	 * spent here is the frame interval, not work.  Timed apart from the
	 * rest for exactly that reason: without the split, present time
	 * looks like a 25ms cost and it is mostly waiting.
	 */
	{
		vlong t0d = osusectime();
		drawable = [mtl_layer nextDrawable];
		metal_drawable_us += osusectime() - t0d;
	}
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
		metal_present_tris3d(cmd, drawable.texture, depthtex, pw, ph);
		metal_present_lines(cmd, drawable.texture, depthtex, pw, ph);
		metal_present_sprites(cmd, drawable.texture, depthtex, pw, ph);
		metal_overlay_soft(cmd, drawable.texture, tex, under, samp);
	}else{
		metal_blit_tex(cmd, drawable.texture, mtl_pipe, tex, nil, samp);
		if(have_geom){
			metal_present_tris(cmd, drawable.texture, depthtex, pw, ph);
			metal_present_tris3d(cmd, drawable.texture, depthtex, pw, ph);
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
		fprint(2, "METALTIME presents=%llud each_us=%llud waiting_us=%llud working_us=%llud | uploads=%llud each_us=%llud\n",
			metal_presents,
			metal_presents ? metal_present_us/metal_presents : 0,
			metal_presents ? metal_drawable_us/metal_presents : 0,
			metal_presents ? (metal_present_us-metal_drawable_us)/metal_presents : 0,
			metal_uploads,
			metal_uploads ? metal_upload_us/metal_uploads : 0);
		fprint(2, "METALSPLIT per present: vsync_wait=%llud slot_wait=%llud real_work=%llud (us)\n",
			metal_presents ? metal_drawable_us/metal_presents : 0,
			metal_presents ? metal_slotwait_us/metal_presents : 0,
			metal_presents ? (metal_present_us - metal_drawable_us - metal_slotwait_us)/metal_presents : 0);
		fprint(2, "METALSTATS frames=%d damage_calls=%llud damage_bytes=%llud full_uploads=%llud readbacks=%llud upload_bytes=%llud copy_bytes=%llud saved_upload_bytes=%llud copy_begins=%llud precopy_dirty_bytes=%llud precopy_clean_bytes=%llud largest_copy_bytes=%llud largest_dirty_bytes=%llud copy_notes=%llud rejected=%llud reject_storage=%llud reject_damage=%llud reject_geometry=%llud alias_storage=%llud armed=%llud cancelled=%llud g3_calls=%llud g3_tris=%llud fill_calls=%llud blank_uploads=%llud torn_uploads=%llud torn_pixels=%llud spr_calls=%llud soft_fallbacks=%llud teximg_alloced=%ud teximg_declined=%ud(chan=%ud small=%ud) teximg_freed=%ud live=%d\n",
			metal_stat_frames, metal_damage_calls, metal_damage_bytes,
			metal_full_uploads, metal_readbacks, metal_upload_bytes,
			metal_copy_bytes, metal_saved_bytes,
			metal_copy_begins, metal_precopy_dirty_bytes, metal_precopy_clean_bytes,
			metal_precopy_largest_bytes, metal_precopy_largest_dirty,
			metal_copy_notes, metal_copy_rejected, metal_copy_reject_storage,
			metal_copy_reject_damage, metal_copy_reject_geometry, metal_copy_alias_storage,
			metal_copy_armed, metal_copy_cancelled, metal_g3_calls, metal_g3_tris,
			metal_fill_calls, metal_blank_uploads,
			metal_torn_uploads, metal_torn_pixels, metal_spr_calls,
			metal_soft_fallbacks, teximg_alloced, teximg_declined,
			teximg_nchan, teximg_nsmall, teximg_freed, nteximg);
		metal_g3_calls = metal_g3_tris = metal_spr_calls = 0;
		metal_fill_calls = 0;
		metal_blank_uploads = 0;
		metal_torn_uploads = metal_torn_pixels = 0;
		{
			int gi, gj, gt, gn;

			gn = npresent_gap;
			for(gi = 1; gi < gn; gi++){	/* small n, insertion sort */
				gt = present_gap[gi];
				for(gj = gi; gj > 0 && present_gap[gj-1] > gt; gj--)
					present_gap[gj] = present_gap[gj-1];
				present_gap[gj] = gt;
			}
			for(gi = 1; gi < nflush_gap; gi++){
				gt = flush_gap[gi];
				for(gj = gi; gj > 0 && flush_gap[gj-1] > gt; gj--)
					flush_gap[gj] = flush_gap[gj-1];
				flush_gap[gj] = gt;
			}
			fprint(2, "METALFRAMEGAP n=%d min %d median %d p90 %d max %d us\n",
				nflush_gap,
				nflush_gap ? flush_gap[0] : 0,
				nflush_gap ? flush_gap[nflush_gap/2] : 0,
				nflush_gap ? flush_gap[(nflush_gap*9)/10] : 0,
				nflush_gap ? flush_gap[nflush_gap-1] : 0);
			nflush_gap = 0;
			fprint(2, "METALCADENCE frames=%llud presents=%llud repeated=%llud once=%llud skipped1=%llud skipped2+=%llud rbwait=%llud us | gap min %d median %d p90 %d max %d us\n",
				soft_seq, metal_presents, present_dup, present_once,
				present_skip2, present_skip3,
				metal_readbacks ? metal_rbwait_us/metal_readbacks : 0,
				gn ? present_gap[0] : 0,
				gn ? present_gap[gn/2] : 0,
				gn ? present_gap[(gn*9)/10] : 0,
				gn ? present_gap[gn-1] : 0);
			npresent_gap = 0;
		}
		metal_rbwait_us = 0;
		present_dup = present_once = present_skip2 = present_skip3 = 0;
		metal_soft_fallbacks = 0;
		metal_stat_frames = 0;
		metal_damage_calls = metal_damage_bytes = 0;
		metal_full_uploads = metal_readbacks = 0;
		metal_upload_bytes = metal_copy_bytes = metal_saved_bytes = 0;
		metal_copy_begins = metal_copy_notes = metal_copy_rejected = 0;
		metal_copy_reject_storage = metal_copy_reject_damage = 0;
		metal_copy_reject_geometry = metal_copy_alias_storage = 0;
		metal_precopy_dirty_bytes = metal_precopy_clean_bytes = 0;
		metal_precopy_largest_bytes = metal_precopy_largest_dirty = 0;
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
	if(mtl_dlink != nil){
		/* The display will ask.  Just say there is something to show. */
		lock(&present_lock);
		present_dirty = 1;
		unlock(&present_lock);
		return;
	}
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
 * Retired softscreen buffers, kept alive briefly instead of freed
 * immediately: a Draw layer created just before a resize can still
 * hold a pointer into the *previous* generation's pixel memory for a
 * little while (see the comment in screenresize() below), so freeing
 * `old` the instant a new buffer replaces it risks a use-after-free.
 * But never freeing it (the original approach here) leaks a full
 * screen-sized buffer on every single resize callback - and a live
 * drag fires many of these per second, so that exhausts the image
 * pool (and blanks the display) within seconds of resizing.
 * Bound it instead: once more than RETIRED generations have piled up,
 * free the oldest. Anything that still needed it has had many more
 * resize cycles to catch up than the single "next event" the original
 * comment was worried about.
 */
enum { Retired = 4 };
static Memimage *retired[Retired];
static int retiredn;

static void
retirescreen(Memimage *old)
{
	if(old == nil)
		return;
	if(retiredn == Retired){
		freememimage(retired[0]);
		memmove(retired, retired+1, (Retired-1)*sizeof(retired[0]));
		retiredn--;
	}
	retired[retiredn++] = old;
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
	 * the window system processes its resize notification - retire it
	 * (freed after Retired more generations) rather than freeing it out
	 * from under those clients immediately. See retirescreen(). */
	retirescreen(old);
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
 * Tried and did NOT fix a resize-triggered bug (icons replaced by a white
 * block): forcing an extra, delayed full re-upload/present here on the
 * theory that a present was racing wm's own Tk redraw and sampling
 * gscreen too early. If that were the whole story, this retry - run well
 * after the redraw should have landed - would have picked up correct
 * data. It didn't, which means gscreen's own memory is genuinely wrong
 * at the affected coordinates by then, not just a stale GPU snapshot of
 * otherwise-correct memory. See memory inferno-rio-wm-resize-fixes item 7
 * for the full diagnosis; the actual mechanism is still unresolved.
 */

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

/*
 * Hand a key event's characters to Inferno.
 *
 * NSString is UTF-16, so anything above the basic multilingual plane -
 * an emoji, or most of what an input method produces - arrives as a
 * surrogate PAIR.  Taking [chars characterAtIndex:0] and calling that
 * the key, which is what this did, delivers half a rune: the value is a
 * lone high surrogate, which is not a character at all.  And an event
 * carrying more than one character lost everything after the first.
 *
 * The first character still goes through convert_key(), because that is
 * what turns a keyCode into Return, an arrow, or a function key.  The
 * rest are text and are delivered as themselves - a composed string is
 * not a key press, and there is no keyCode that means anything for it.
 *
 * This is one half of what an input method needs.  The other half is
 * NSTextInputClient, so that composition is shown while it happens
 * rather than arriving all at once; that is not done here.
 */
static void
deliverchars(NSString *chars, unsigned short keyCode)
{
	NSUInteger i, n;
	unichar c, lo;
	long r;
	int key, first;

	n = chars == nil ? 0 : [chars length];
	if(n == 0){
		key = convert_key(keyCode, 0);
		if(key != -1)
			gkbdputc(gkbdq, key);
		return;
	}
	first = 1;
	for(i = 0; i < n; i++){
		c = [chars characterAtIndex:i];
		r = c;
		if(c >= 0xD800 && c <= 0xDBFF && i+1 < n){
			lo = [chars characterAtIndex:i+1];
			if(lo >= 0xDC00 && lo <= 0xDFFF){
				r = 0x10000 + (((long)c - 0xD800) << 10)
					+ ((long)lo - 0xDC00);
				i++;
			}
		}
		if(first && r < 0x10000){
			key = convert_key(keyCode, (unichar)r);
			if(key == -1){
				first = 0;
				continue;
			}
		}else
			key = (int)r;
		first = 0;
		gkbdputc(gkbdq, key);
	}
}

@interface InfernoView : NSView
@end

@implementation InfernoView
+ (Class)layerClass
{
	return [CAMetalLayer class];
}

/*
 * One present per display refresh, asked for by the display.
 *
 * The alternative, and what this did, is to present whenever a program
 * flushes.  That gives a present interval of whatever the program's own
 * clock happens to be - measured at 13 to 21ms against a 16.67ms refresh -
 * so some refreshes get a new frame and some get none, unevenly, which is
 * what choppy is.  Asking the display when it wants a frame makes the
 * interval the refresh interval by construction.
 *
 * A note here used to say a CVDisplayLink "added up to a refresh of
 * latency and felt sluggish", and it would have: paired with a program
 * drawing at 60Hz off a timer, the link can only ever wait.  It costs
 * nothing when the program draws FASTER than the display, because then a
 * fresh frame is always already there - which is the other half of this,
 * and why the two have to go together.
 */
- (void)vsynctick:(id)link
{
	USED(link);
	present_on_main();
	/* and let any program waiting on /dev/draw/vsync draw the next one */
	drawvsync();
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

	deliverchars([e characters], [e keyCode]);
}

- (void)keyUp:(NSEvent *)e
{
	int key;
	NSUInteger mods;
	NSString *chars;
	unichar ch;

	mods = [e modifierFlags];
	if(mods & NSEventModifierFlagCommand)
		return;
	chars = [e characters];
	ch = [chars length] > 0 ? [chars characterAtIndex:0] : 0;
	key = convert_key([e keyCode], ch);
	if(key != -1)
		gkbdputc(gkbdq, Keyup | (key & 0x7ff));
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

/*
 * One wheel click per scroll EVENT was wrong for every device that sends
 * precise deltas - a trackpad, a Magic Mouse - and wrong in a way that
 * feels like acceleration going astray rather than like a bug.
 *
 * Those devices do not send detents.  They send a dense stream of pixel
 * deltas while the fingers move, and then, after the fingers LIFT, a
 * momentum tail of further events that decays over about a second.  With
 * one click per event the number of clicks tracked how many events the
 * system chose to send rather than how far the finger went: a quick flick
 * under-scrolled while it was happening, and then the momentum tail
 * arrived as a burst with nothing touching the mouse.  That is the jump.
 *
 * So accumulate the pixels and spend them a click at a time.  The click
 * count is then proportional to distance travelled, which is the thing
 * the person is actually controlling, and the momentum tail becomes a
 * decelerating series instead of a lump.  The accumulator is reset when a
 * new gesture begins so that a scroll cannot inherit a fraction left over
 * from the last one.
 *
 * A classic wheel is left exactly as it was: it reports in lines, one or
 * a few per detent, and one click per event is right there.
 *
 * INFERNO_SCROLLSTEP is the pixels per click, for anyone whose hands
 * disagree with 16.
 */
- (void)scrollWheel:(NSEvent *)e
{
	CGFloat dyw = [e scrollingDeltaY];
	static CGFloat acc;
	static CGFloat step;
	int clicks, i, isup;	/* not `up': emu defines that as the current process */

	[self mousePosFromEvent:e];
	if(dyw == 0)
		return;

	if([e hasPreciseScrollingDeltas]){
		if(step == 0){
			char *p = getenv("INFERNO_SCROLLSTEP");
			step = p != nil ? atof(p) : 16.0;
			if(step < 1.0)
				step = 16.0;
		}
		if([e phase] == NSEventPhaseBegan || [e momentumPhase] == NSEventPhaseBegan)
			acc = 0;
		acc += dyw;
		clicks = (int)(acc / step);
		if(clicks == 0)
			return;
		acc -= clicks * step;
	}else{
		/*
		 * A classic wheel reports lines, and this stays exactly what it
		 * has always been: one click per event.  Honouring the line
		 * count would make a wheel with the system's acceleration
		 * applied scroll several times faster than it does today, and
		 * that is a change nobody asked for - the complaint that
		 * prompted this is about precise devices, where the old code
		 * genuinely could not track the finger.
		 */
		clicks = dyw > 0 ? 1 : -1;
	}

	if(getenv("INFERNO_SCROLLDEBUG") != nil)
		print("scroll: precise=%d phase=%d momentum=%d dy=%d clicks=%d\n",
			(int)[e hasPreciseScrollingDeltas], (int)[e phase],
			(int)[e momentumPhase], (int)dyw, clicks);
	isup = clicks > 0;
	if(clicks < 0)
		clicks = -clicks;
	/*
	 * A guard, not a policy: a single event carrying an absurd delta
	 * should not lock the VM up delivering hundreds of clicks.
	 */
	if(clicks > 32)
		clicks = 32;
	for(i = 0; i < clicks; i++){
		sendbuttons(isup ? 8 : 16, mouseX, mouseY);
		sendbuttons(mousebuttons, mouseX, mouseY);
	}
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

/*
 * A test hook: resize the window over and over, from outside.
 *
 * doc/hpc-plan.md bug 2 - Screen.newwindow() returning nil - is reported after
 * a resize, and nothing inside Inferno can cause one. screenresize() is
 * reachable only from this thread, there is no control file, and session(2)'s
 * resize verb deliberately refuses. So the bug could not be provoked at all,
 * and wmtest(1) can only show that creating windows without resizing is clean.
 *
 * This drives the real path rather than an imitation of it: it sets the
 * window's content size and lets Cocoa's own callbacks run, which is the
 * sequence a person dragging the corner produces - setFrameSize, screenresize,
 * drawscreenresize, mouseresize. That is the point of doing it here instead of
 * calling screenresize directly, which would be a different event and would
 * have to be reported as one.
 *
 *	INFERNO_RESIZE_TEST=ms  emu ...
 *
 * Guarded by an environment variable and doing nothing without one, the same
 * shape as the hook that forced bug 4's signal-handler path to run. It is for
 * provoking a fault, not a feature: an operating system resizing its own
 * display behind the user's back is not something to leave switched on.
 */
static int resizetest_ms;
static int resizetest_which;

static void resizetest_tick(void);

static void
resizetest_once(void)
{
	static const int sizes[][2] = { {1024,768}, {800,600}, {1024,768}, {640,480} };
	int n;

	if(win == nil)
		return;
	n = resizetest_which++ % (int)(sizeof sizes / sizeof sizes[0]);
	[win setContentSize:NSMakeSize(sizes[n][0], sizes[n][1])];
}

static void
resizetest_tick(void)
{
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
			(int64_t)resizetest_ms * NSEC_PER_MSEC),
		dispatch_get_main_queue(), ^{
			resizetest_once();
			resizetest_tick();
		});
}

static void
resizetest_start(void)
{
	char *p;

	p = getenv("INFERNO_RESIZE_TEST");
	if(p == nil || *p == '\0')
		return;
	resizetest_ms = atoi(p);
	if(resizetest_ms < 50)
		resizetest_ms = 50;
	print("resizetest: resizing the window every %dms\n", resizetest_ms);
	resizetest_tick();
}

/*
 * Feed a string through the same path a key event takes, so that the
 * decoding above can be tested at all.
 *
 *	INFERNO_KEY_TEST='h\u00e9llo \U0001f600'  emu ...
 *
 * Nothing else in this system can produce a surrogate pair on demand: a
 * person has to type one, and writing to /dev/keyboard goes in below the
 * platform and tests nothing. Same shape and same rationale as
 * INFERNO_RESIZE_TEST above - guarded by an environment variable, doing
 * nothing without one, and for provoking a path rather than for use.
 */
static void
keytest_start(void)
{
	char *p;
	NSString *s;

	p = getenv("INFERNO_KEY_TEST");
	if(p == nil || *p == '\0')
		return;
	s = [NSString stringWithUTF8String:p];
	if(s == nil)
		return;
	/* Plan 9 print(2), not C printf: %lu is not a verb here. */
	print("keytest: delivering %d UTF-16 units\n", (int)[s length]);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)500 * NSEC_PER_MSEC),
		dispatch_get_main_queue(), ^{
			deliverchars(s, 0);
		});
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

	/*
	 * Drive presents off the display from here on.  INFERNO_NOVSYNC
	 * keeps the old behaviour - present on the flush that marked the
	 * screen dirty - because this is the sort of change that wants a
	 * control sitting next to it.
	 */
	if(getenv("INFERNO_NOVSYNC") == nil && [view respondsToSelector:@selector(displayLinkWithTarget:selector:)]){
		mtl_dlink = [view displayLinkWithTarget:view
			selector:@selector(vsynctick:)];
		if(mtl_dlink != nil)
			[mtl_dlink addToRunLoop:[NSRunLoop currentRunLoop]
				forMode:NSRunLoopCommonModes];
	}

	resizetest_start();
	keytest_start();
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

/*
 * Marks the flushed rect's tiles dirty (metal_mark_tiles(), which also
 * freezes their pixels into soft_shadow synchronously - before this
 * returns to whatever Limbo code queued the flush, which may immediately
 * start drawing the *next* frame into gscreen. mark_view_dirty()'s actual
 * upload (metal_upload_damage()) runs later, asynchronously, on the
 * AppKit main thread; without this snapshot it would read gscreen's live
 * bytes at whatever later moment it happens to run, which can already be
 * mid-way through the next frame's clear+redraw - a torn frame, seen as
 * blinking on every draw. See metal_mark_tiles()'s own comment for why
 * that snapshot lives there and not inline here, and for why this reads
 * gscreen into a local exactly once rather than letting metal_mark_tiles
 * (or this function, in an earlier version of this fix) re-read the
 * global - a dispatch_sync to force the main thread to catch up instead
 * would risk deadlock: this runs while devdraw.c's drawwrite() holds
 * sdraw.q, which a concurrent resize on the main thread also takes.
 */
void
flushmemscreen(Rectangle r)
{
	Memimage *scr;

	if(r.max.x < r.min.x || r.max.y < r.min.y)
		return;
	if(view == nil)
		return;
	scr = gscreen;
	if(scr != nil && rectclip(&r, scr->r)){
		if(metal_damage_map(Dx(scr->r), Dy(scr->r)) < 0)
			mtl_tex_fresh = 1;
		else{
			lock(&soft_dirty_lock);
			metal_mark_tiles(scr, r, 1, 0);
			unlock(&soft_dirty_lock);
		}
	}
	soft_seq++;
	{
		vlong tf = osusectime();
		if(flush_last_us != 0 && nflush_gap < nelem(flush_gap))
			flush_gap[nflush_gap++] = (int)(tf - flush_last_us);
		flush_last_us = tf;
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
