/*
 * Metal compute backend for gpu(3) (emu/port/devgpu.c).
 *
 * Fills in devgpu.c's nullable gpuhw* hooks with a real
 * MTLComputePipelineState running CSR sparse matrix-vector product on
 * the GPU - one thread per row. This is the compute sibling of the
 * GPU *render* hooks win-cocoa.m already provides (gpudrawfillpoly3d
 * and friends): same nullable-function-pointer convention, one layer
 * down from drawing into general compute.
 *
 * Deliberately includes NO Inferno headers - the hooks are declared
 * in plain C types on both sides, so this file needs neither dat.h
 * nor the Point/Rect renaming dance win-cocoa.m has to do, and
 * nothing here can accidentally depend on kernel internals.
 *
 * PRECISION: Metal Shading Language has no double. Everything below
 * is f32, converting on the way in and out. That is not a shortcut
 * taken here - it is a hard property of the hardware path, and it is
 * exactly why gpu(2) has a "precision f32|f64" verb: gpu(2) declines
 * to use this backend at all when a caller asked for f64, rather than
 * quietly giving them single precision. See gpu(2)/gpu(3).
 *
 * The matrix buffers are uploaded once per matrix (gpuhwupload) and
 * stay resident; only the x/y vectors cross per matvec, which is the
 * whole reason offloading a Krylov solve pays off - see gpu(2)'s
 * "resident" verb.
 */
#import <Foundation/Foundation.h>
#include <time.h>
#include <stdio.h>
#import <Metal/Metal.h>

/* Implemented here, declared in emu/port/devgpu.c. Plain C types by
 * design; see the note above. */
extern void*	(*gpuhwupload)(int n, int nnz, int *rowptr, int *colidx, double *val);
extern int	(*gpuhwspmv)(void *h, double *x, double *y, int n);
extern void	(*gpuhwfree)(void *h);

static NSString *const kSpmvMetalSrc = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"kernel void spmv(device const int   *rowptr [[buffer(0)]],\n"
"                 device const int   *colidx [[buffer(1)]],\n"
"                 device const float *val    [[buffer(2)]],\n"
"                 device const float *x      [[buffer(3)]],\n"
"                 device       float *y      [[buffer(4)]],\n"
"                 constant     uint  &n      [[buffer(5)]],\n"
"                 uint row [[thread_position_in_grid]])\n"
"{\n"
"	if(row >= n)\n"
"		return;\n"
"	float s = 0.0f;\n"
"	int lo = rowptr[row], hi = rowptr[row+1];\n"
"	for(int j = lo; j < hi; j++)\n"
"		s += val[j] * x[colidx[j]];\n"
"	y[row] = s;\n"
"}\n";

static id<MTLDevice>			gpu_device;
static id<MTLCommandQueue>		gpu_queue;
static id<MTLComputePipelineState>	gpu_pipe;
static int				gpu_ready;	/* 0 untried, 1 ok, -1 failed */

@interface GpuMat : NSObject
@property (nonatomic, strong) id<MTLBuffer> rowptr;
@property (nonatomic, strong) id<MTLBuffer> colidx;
@property (nonatomic, strong) id<MTLBuffer> val;
@property (nonatomic, strong) id<MTLBuffer> x;
@property (nonatomic, strong) id<MTLBuffer> y;
@property (nonatomic, assign) int n;
@property (nonatomic, assign) int nnz;
@end

@implementation GpuMat
@end

static dispatch_once_t	gpu_once;

static void
gpucompute_setup(void)
{
	NSError *err = nil;
	id<MTLLibrary> lib;
	id<MTLFunction> fn;

	gpu_ready = -1;
	/*
	 * INFERNO_NOGPUHW leaves this backend unavailable, so gpu(3) falls
	 * back to its own portable CSR loop. That makes it possible to compare
	 * the Metal path against the CPU path within one binary and one
	 * environment - which emu-g cannot do, since it has no Metal at all,
	 * and which is exactly what separating a backend bug from an
	 * environmental one needs. See doc/hpc-plan.md.
	 */
	if(getenv("INFERNO_NOGPUHW") != nil)
		return;
	gpu_device = MTLCreateSystemDefaultDevice();
	if(gpu_device == nil)
		return;
	gpu_queue = [gpu_device newCommandQueue];
	if(gpu_queue == nil)
		return;
	lib = [gpu_device newLibraryWithSource:kSpmvMetalSrc options:nil error:&err];
	if(lib == nil)
		return;
	fn = [lib newFunctionWithName:@"spmv"];
	if(fn == nil)
		return;
	gpu_pipe = [gpu_device newComputePipelineStateWithFunction:fn error:&err];
	if(gpu_pipe == nil)
		return;
	gpu_ready = 1;
}

/*
 * Lazy, and only ever attempted once: a machine without a usable Metal device
 * must not pay the setup cost on every upload, and must degrade to devgpu.c's
 * CPU path rather than failing.
 *
 * dispatch_once, NOT a plain "if(gpu_ready != 0) return" guard. gpu(3) hands
 * out one handle per open, so several Limbo processes can be in their first
 * upload at once; the hand-rolled guard would let all of them past the test
 * and run the whole body concurrently, each overwriting gpu_device, gpu_queue
 * and gpu_pipe while the others were already dispatching against them, and it
 * had no barrier between filling those globals and publishing gpu_ready = 1,
 * so a thread could observe ready with a nil pipeline.
 *
 * Honest about the evidence: that race was never observed to FIRE. The old
 * guard was instrumented with a counter of how many times the body ran and
 * tested under gputest(1) on emu-cocoa, including a variant whose first GPU
 * use is the concurrent phase - 12 runs, never more than once. Something
 * upstream evidently serialises the first upload in practice. So this is a
 * correctness fix by inspection, not the cure for any measured failure, and
 * in particular NOT the cure for the allocator corruption that gputest hits
 * under emu-cocoa (see doc/hpc-plan.md) - that reproduces without the device
 * at all.
 */
static int
gpucompute_init(void)
{
	dispatch_once(&gpu_once, ^{
		gpucompute_setup();
	});
	return gpu_ready;
}

static void*
metal_upload(int n, int nnz, int *rowptr, int *colidx, double *val)
{
	GpuMat *m;
	float *fv;
	int i;

	if(n <= 0 || nnz < 0 || gpucompute_init() != 1)
		return NULL;

	m = [[GpuMat alloc] init];
	m.n = n;
	m.nnz = nnz;
	m.rowptr = [gpu_device newBufferWithBytes:rowptr
			length:(n+1)*sizeof(int)
			options:MTLResourceStorageModeShared];
	m.colidx = [gpu_device newBufferWithBytes:colidx
			length:(nnz > 0 ? nnz : 1)*sizeof(int)
			options:MTLResourceStorageModeShared];
	m.val = [gpu_device newBufferWithLength:(nnz > 0 ? nnz : 1)*sizeof(float)
			options:MTLResourceStorageModeShared];
	m.x = [gpu_device newBufferWithLength:n*sizeof(float)
			options:MTLResourceStorageModeShared];
	m.y = [gpu_device newBufferWithLength:n*sizeof(float)
			options:MTLResourceStorageModeShared];
	if(m.rowptr == nil || m.colidx == nil || m.val == nil || m.x == nil || m.y == nil)
		return NULL;

	/* f64 -> f32: Metal has no double. See the PRECISION note above. */
	fv = (float*)[m.val contents];
	for(i = 0; i < nnz; i++)
		fv[i] = (float)val[i];

	return (void*)CFBridgingRetain(m);
}

static int gpu_nspmv;
static int gpu_stats_on = -1;
static double gpu_convin, gpu_encode, gpu_commit, gpu_convout;
static void gpu_stats(void);

static int
metal_spmv(void *h, double *x, double *y, int n)
{
	double tp0, tp1, tp2, tp3;
	GpuMat *m;
	id<MTLCommandBuffer> cb;
	id<MTLComputeCommandEncoder> enc;
	MTLSize grid, tg;
	float *fx, *fy;
	uint32_t un;
	NSUInteger w;
	int i;

	if(h == NULL || gpu_ready != 1)
		return 0;
	m = (__bridge GpuMat*)h;
	if(n != m.n)
		return 0;

	if(gpu_stats_on < 0)
		gpu_stats_on = getenv("INFERNO_METAL_STATS") != NULL;
	{ struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); tp0 = t.tv_sec*1e9 + t.tv_nsec; }
	fx = (float*)[m.x contents];
	for(i = 0; i < n; i++)
		fx[i] = (float)x[i];
	{ struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); tp1 = t.tv_sec*1e9 + t.tv_nsec; }

	un = (uint32_t)n;
	cb = [gpu_queue commandBuffer];
	enc = [cb computeCommandEncoder];
	[enc setComputePipelineState:gpu_pipe];
	[enc setBuffer:m.rowptr offset:0 atIndex:0];
	[enc setBuffer:m.colidx offset:0 atIndex:1];
	[enc setBuffer:m.val offset:0 atIndex:2];
	[enc setBuffer:m.x offset:0 atIndex:3];
	[enc setBuffer:m.y offset:0 atIndex:4];
	[enc setBytes:&un length:sizeof(un) atIndex:5];
	w = [gpu_pipe maxTotalThreadsPerThreadgroup];
	if(w > (NSUInteger)n)
		w = (NSUInteger)n;
	if(w < 1)
		w = 1;
	grid = MTLSizeMake((NSUInteger)n, 1, 1);
	tg = MTLSizeMake(w, 1, 1);
	[enc dispatchThreads:grid threadsPerThreadgroup:tg];
	[enc endEncoding];
	{ struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); tp2 = t.tv_sec*1e9 + t.tv_nsec; }
	[cb commit];
	[cb waitUntilCompleted];
	{ struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); tp3 = t.tv_sec*1e9 + t.tv_nsec; }
	if([cb status] != MTLCommandBufferStatusCompleted)
		return 0;

	fy = (float*)[m.y contents];
	for(i = 0; i < n; i++)
		y[i] = (double)fy[i];
	{
		struct timespec t; double tp4;
		clock_gettime(CLOCK_MONOTONIC, &t); tp4 = t.tv_sec*1e9 + t.tv_nsec;
		gpu_nspmv++;
		gpu_convin  += tp1-tp0;
		gpu_encode  += tp2-tp1;
		gpu_commit  += tp3-tp2;
		gpu_convout += tp4-tp3;
		if(gpu_stats_on)
			gpu_stats();
	}
	return 1;
}

/*
 * Where a GPU matvec's time actually goes, on INFERNO_METAL_STATS - the same
 * switch win-cocoa.m already uses for its own counters.
 *
 * It is worth having permanently because the answer is not what anyone
 * expects and it decides whether offloading is worth doing at all: the commit
 * and wait is about 200us and barely moves as the problem grows, while the
 * conversions and the encoding together are under 10us. The cost of this
 * interface is a command-buffer round trip, not data movement.
 *
 * Printed every 200 calls rather than at exit, so it is visible from a run
 * that is killed or hangs.
 */
static void
gpu_stats(void)
{
	if(gpu_nspmv % 200 != 0)
		return;
	fprintf(stderr,
		"metal spmv: %d calls, per call convert-in %.1fus encode %.1fus "
		"commit+wait %.1fus convert-out %.1fus\n",
		gpu_nspmv, gpu_convin/gpu_nspmv/1000.0, gpu_encode/gpu_nspmv/1000.0,
		gpu_commit/gpu_nspmv/1000.0, gpu_convout/gpu_nspmv/1000.0);
}

static void
metal_free(void *h)
{
	if(h == NULL)
		return;
	CFBridgingRelease(h);	/* ARC releases the GpuMat and its buffers */
}

/*
 * Registered at load time rather than from an init call, so devgpu.c
 * needs no knowledge of this file's existence (and no platform #ifdef)
 * - it only ever sees hooks that are either nil or ready to use.
 */
__attribute__((constructor))
static void
gpucompute_register(void)
{
	gpuhwupload = metal_upload;
	gpuhwspmv = metal_spmv;
	gpuhwfree = metal_free;
}
