/*
 * win-ml.m - CoreML behind ml(3)'s nullable hooks.
 *
 * devml.c owns the protocol and the handle lifecycle and knows nothing about
 * CoreML; this file knows nothing about Inferno. The only thing crossing
 * between them is plain C - no Inferno headers here, no Objective-C there -
 * which is the same arrangement win-gpu.m and win-cocoa.m already use, and is
 * what lets a platform without CoreML simply not link this file rather than
 * having the device #ifdef'd out from under it.
 *
 * Three things here are decided by what CoreML actually does rather than by
 * what would be convenient, all of them checked with mlcaps.m before this was
 * written:
 *
 *  - A model arrives as bytes and is staged to a temporary file, because
 *    compileModelAtURL: wants a URL. It accepts a plain single-file .mlmodel
 *    and produces the compiled .mlmodelc directory itself, so nothing but the
 *    bytes ever has to cross - no host path from the caller, no namespace
 *    puncture.
 *  - Input element type is whatever the model declares and is NOT assumed to
 *    be f32. The fixture model declares f64. A client that guessed would
 *    write half or twice the bytes needed, so the expected size is computed
 *    from the model's own constraint and a mismatch is an error naming both
 *    numbers.
 *  - The compute unit reported is the one MLComputePlan says ran, not the one
 *    requested. computeUnits is a request CoreML may not honour, and
 *    reporting a request as a result is exactly the bug gpu(3) shipped once.
 */
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

@interface Inferno_MLState : NSObject
@property (nonatomic, strong) MLModel *model;
@property (nonatomic, strong) MLModelConfiguration *cfg;
@property (nonatomic, strong) NSMutableDictionary<NSString*,MLMultiArray*> *inputs;
@property (nonatomic, strong) id<MLFeatureProvider> result;
@property (nonatomic, strong) NSString *device;
@property (nonatomic, strong) NSURL *compiled;
@end

@implementation Inferno_MLState
@end

static void
seterr(char *err, int nerr, NSString *s)
{
	if(err == NULL || nerr <= 0)
		return;
	snprintf(err, nerr, "%s", s.UTF8String ? s.UTF8String : "unknown error");
}

static const char*
typename(MLMultiArrayDataType t)
{
	switch(t){
	case MLMultiArrayDataTypeDouble:	return "f64";
	case MLMultiArrayDataTypeFloat32:	return "f32";
	case MLMultiArrayDataTypeFloat16:	return "f16";
	case MLMultiArrayDataTypeInt32:		return "i32";
	default:				return "?";
	}
}

/*
 * The wire is big-endian, matching devgpu's and what Limbo's
 * math->export_real/export_real32 already produce - so a caller marshals with
 * what it has rather than hand-rolling, and a model reached across a Styx
 * mount from a different-endian machine still gets the bytes it meant. The
 * host framework wants native order, so the swap happens here, at the edge
 * that knows the element type. Element sizes are 2, 4 or 8.
 */
static void
swapbytes(unsigned char *d, const unsigned char *s, long n, int esz)
{
	long i;
	int j;

	if(esz <= 1){
		memcpy(d, s, (size_t)n);
		return;
	}
	for(i = 0; i + esz <= n; i += esz)
		for(j = 0; j < esz; j++)
			d[i+j] = s[i + esz-1 - j];
}

static int
bigendian(void)
{
	unsigned short x = 1;

	return *(unsigned char*)&x == 0;
}

static int
elemsize(MLMultiArrayDataType t)
{
	switch(t){
	case MLMultiArrayDataTypeDouble:	return 8;
	case MLMultiArrayDataTypeFloat32:	return 4;
	case MLMultiArrayDataTypeFloat16:	return 2;
	case MLMultiArrayDataTypeInt32:		return 4;
	default:				return 0;
	}
}

/*
 * What actually ran. MLComputePlan reports a device per operation; a model
 * can be split across units, so the honest summary names every distinct one.
 * If it cannot be determined the string says so rather than echoing the
 * request back as though it were an answer.
 */
static NSString*
observedevice(NSURL *compiled, MLModelConfiguration *cfg)
{
	__block NSString *out = nil;

	if(@available(macOS 14.4, *)){
		dispatch_semaphore_t sem = dispatch_semaphore_create(0);
		[MLComputePlan loadContentsOfURL:compiled configuration:cfg
		    completionHandler:^(MLComputePlan *plan, NSError *e){
			if(plan != nil && plan.modelStructure.neuralNetwork != nil){
				NSMutableArray *seen = [NSMutableArray array];
				for(MLModelStructureNeuralNetworkLayer *l in
				    plan.modelStructure.neuralNetwork.layers){
					MLComputePlanDeviceUsage *u =
					    [plan computeDeviceUsageForNeuralNetworkLayer:l];
					if(u == nil)
						continue;
					id d = u.preferredComputeDevice;
					NSString *nm = @"cpu";
					if([d isKindOfClass:[MLNeuralEngineComputeDevice class]])
						nm = @"ane";
					else if([d isKindOfClass:[MLGPUComputeDevice class]])
						nm = @"gpu";
					if(![seen containsObject:nm])
						[seen addObject:nm];
				}
				if(seen.count > 0)
					out = [seen componentsJoinedByString:@"+"];
			}
			dispatch_semaphore_signal(sem);
		}];
		dispatch_semaphore_wait(sem,
			dispatch_time(DISPATCH_TIME_NOW, 20LL*NSEC_PER_SEC));
	}
	if(out == nil)
		out = @"unknown (not reported by this OS)";
	return out;
}

void*
ml_open_model(unsigned char *spec, int nspec, char *units, char *err, int nerr)
{
	@autoreleasepool {
		NSError *e = nil;

		if(spec == NULL || nspec <= 0){
			seterr(err, nerr, @"empty model");
			return NULL;
		}
		NSData *bytes = [NSData dataWithBytes:spec length:(NSUInteger)nspec];
		NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
			[NSString stringWithFormat:@"inferno-ml-%d-%p.mlmodel", getpid(), spec]];
		if(![bytes writeToFile:tmp atomically:YES]){
			seterr(err, nerr, @"cannot stage the model");
			return NULL;
		}
		NSURL *compiled = [MLModel compileModelAtURL:[NSURL fileURLWithPath:tmp] error:&e];
		/* The staged copy is only needed for the compile. */
		[[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
		if(compiled == nil){
			seterr(err, nerr, e ? e.localizedDescription : @"cannot compile the model");
			return NULL;
		}

		MLModelConfiguration *cfg = [MLModelConfiguration new];
		if(units == NULL || strcmp(units, "all") == 0)
			cfg.computeUnits = MLComputeUnitsAll;
		else if(strcmp(units, "cpu") == 0)
			cfg.computeUnits = MLComputeUnitsCPUOnly;
		else if(strcmp(units, "gpu") == 0)
			cfg.computeUnits = MLComputeUnitsCPUAndGPU;
		else if(strcmp(units, "ane") == 0)
			cfg.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
		else
			cfg.computeUnits = MLComputeUnitsAll;

		MLModel *m = [MLModel modelWithContentsOfURL:compiled configuration:cfg error:&e];
		if(m == nil){
			seterr(err, nerr, e ? e.localizedDescription : @"cannot load the model");
			return NULL;
		}

		Inferno_MLState *st = [Inferno_MLState new];
		st.model = m;
		st.cfg = cfg;
		st.compiled = compiled;
		st.inputs = [NSMutableDictionary dictionary];
		st.device = observedevice(compiled, cfg);
		return (__bridge_retained void*)st;
	}
}

void
ml_close_model(void *h)
{
	@autoreleasepool {
		if(h == NULL)
			return;
		Inferno_MLState *st = (__bridge_transfer Inferno_MLState*)h;
		/* Compiling writes a .mlmodelc into the temporary directory;
		 * nothing else will remove it, so a program that loads many
		 * models would otherwise leave one behind for each. */
		if(st.compiled != nil)
			[[NSFileManager defaultManager] removeItemAtURL:st.compiled error:NULL];
		st.model = nil;
	}
}

int
ml_model_info(void *h, char *buf, int nbuf)
{
	@autoreleasepool {
		if(h == NULL || buf == NULL || nbuf <= 0)
			return -1;
		Inferno_MLState *st = (__bridge Inferno_MLState*)h;
		NSMutableString *s = [NSMutableString string];
		MLModelDescription *d = st.model.modelDescription;

		void (^emit)(NSString*, NSDictionary<NSString*,MLFeatureDescription*>*) =
		^(NSString *what, NSDictionary<NSString*,MLFeatureDescription*> *dict){
			for(NSString *k in dict){
				MLFeatureDescription *f = dict[k];
				if(f.type != MLFeatureTypeMultiArray){
					[s appendFormat:@"%@ %@ opaque\n", what, k];
					continue;
				}
				MLMultiArrayConstraint *c = f.multiArrayConstraint;
				[s appendFormat:@"%@ %@ %s", what, k, typename(c.dataType)];
				for(NSNumber *n in c.shape)
					[s appendFormat:@" %ld", (long)n.integerValue];
				[s appendString:@"\n"];
			}
		};
		emit(@"in", d.inputDescriptionsByName);
		emit(@"out", d.outputDescriptionsByName);
		[s appendFormat:@"device %@\n", st.device];

		snprintf(buf, nbuf, "%s", s.UTF8String);
		return (int)strlen(buf);
	}
}

/* The named input, or the only one if no name was selected. */
static MLFeatureDescription*
pickfeature(NSDictionary<NSString*,MLFeatureDescription*> *d, char *name,
	NSString **outname, char *err, int nerr)
{
	if(name != NULL && name[0] != '\0'){
		NSString *k = @(name);
		MLFeatureDescription *f = d[k];
		if(f == nil){
			seterr(err, nerr, [NSString stringWithFormat:
				@"no feature named %s", name]);
			return nil;
		}
		*outname = k;
		return f;
	}
	if(d.count != 1){
		seterr(err, nerr, [NSString stringWithFormat:
			@"model has %lu features: name one", (unsigned long)d.count]);
		return nil;
	}
	*outname = d.allKeys[0];
	return d[*outname];
}

int
ml_set_input(void *h, char *name, unsigned char *b, int n, char *err, int nerr)
{
	@autoreleasepool {
		if(h == NULL)
			return -1;
		Inferno_MLState *st = (__bridge Inferno_MLState*)h;
		NSString *key = nil;
		MLFeatureDescription *f = pickfeature(
			st.model.modelDescription.inputDescriptionsByName,
			name, &key, err, nerr);
		if(f == nil)
			return -1;
		if(f.type != MLFeatureTypeMultiArray){
			seterr(err, nerr, @"input is not a multiarray");
			return -1;
		}
		MLMultiArrayConstraint *c = f.multiArrayConstraint;
		int esz = elemsize(c.dataType);
		if(esz == 0){
			seterr(err, nerr, @"input has an element type this does not handle");
			return -1;
		}
		long count = 1;
		for(NSNumber *d in c.shape)
			count *= (long)d.integerValue;
		long want = count * esz;
		/*
		 * Size is checked against the model's own declared shape and
		 * type. A client that assumed f32 for an f64 input would write
		 * exactly half of this and otherwise get a plausible-looking
		 * wrong answer, so the error names both numbers.
		 */
		if((long)n != want){
			seterr(err, nerr, [NSString stringWithFormat:
				@"input %@ wants %ld bytes (%ld %s values), got %d",
				key, want, count, typename(c.dataType), n]);
			return -1;
		}
		NSError *e = nil;
		MLMultiArray *a = [[MLMultiArray alloc] initWithShape:c.shape
			dataType:c.dataType error:&e];
		if(a == nil){
			seterr(err, nerr, e ? e.localizedDescription : @"cannot make an array");
			return -1;
		}
		if(bigendian())
			memcpy(a.dataPointer, b, (size_t)want);
		else
			swapbytes(a.dataPointer, b, want, esz);
		st.inputs[key] = a;
		return 0;
	}
}

int
ml_run_model(void *h, char *err, int nerr)
{
	@autoreleasepool {
		if(h == NULL)
			return -1;
		Inferno_MLState *st = (__bridge Inferno_MLState*)h;
		NSDictionary *want = st.model.modelDescription.inputDescriptionsByName;
		if(st.inputs.count != want.count){
			seterr(err, nerr, [NSString stringWithFormat:
				@"model needs %lu inputs, %lu were given",
				(unsigned long)want.count, (unsigned long)st.inputs.count]);
			return -1;
		}
		NSError *e = nil;
		MLDictionaryFeatureProvider *in = [[MLDictionaryFeatureProvider alloc]
			initWithDictionary:st.inputs error:&e];
		if(in == nil){
			seterr(err, nerr, e ? e.localizedDescription : @"bad inputs");
			return -1;
		}
		id<MLFeatureProvider> out = [st.model predictionFromFeatures:in error:&e];
		if(out == nil){
			seterr(err, nerr, e ? e.localizedDescription : @"prediction failed");
			return -1;
		}
		st.result = out;
		return 0;
	}
}

int
ml_get_output(void *h, char *name, unsigned char *b, int nbuf, char *err, int nerr)
{
	@autoreleasepool {
		if(h == NULL)
			return -1;
		Inferno_MLState *st = (__bridge Inferno_MLState*)h;
		if(st.result == nil){
			seterr(err, nerr, @"nothing has been run");
			return -1;
		}
		NSString *key = nil;
		MLFeatureDescription *f = pickfeature(
			st.model.modelDescription.outputDescriptionsByName,
			name, &key, err, nerr);
		if(f == nil)
			return -1;
		MLMultiArray *a = [st.result featureValueForName:key].multiArrayValue;
		if(a == nil){
			seterr(err, nerr, @"output is not a multiarray");
			return -1;
		}
		int esz = elemsize(a.dataType);
		if(esz == 0){
			seterr(err, nerr, @"output has an element type this does not handle");
			return -1;
		}
		long want = (long)a.count * esz;
		if(b == NULL || nbuf == 0)
			return (int)want;	/* a size enquiry */
		if(nbuf < want){
			seterr(err, nerr, [NSString stringWithFormat:
				@"output needs %ld bytes, buffer is %d", want, nbuf]);
			return -1;
		}
		/*
		 * getBytesWithHandler rather than dataPointer: a MLMultiArray
		 * need not be contiguous, and copying from dataPointer assumes
		 * it is.
		 */
		__block int ok = 0;
		[a getBytesWithHandler:^(const void *bytes, NSInteger len){
			if(len >= want){
				if(bigendian())
					memcpy(b, bytes, (size_t)want);
				else
					swapbytes(b, bytes, want, esz);
				ok = 1;
			}
		}];
		if(!ok){
			seterr(err, nerr, @"output was shorter than its own shape");
			return -1;
		}
		return (int)want;
	}
}

/*
 * Installed into devml.c's nullable hooks at load time, the same way
 * win-gpu.m installs the Metal ones. Where this file is not linked they stay
 * nil and ml(3) reports that it has no backend, rather than the device being
 * conditionally compiled away.
 */
extern void*	(*mlopenmodel)(unsigned char*, int, char*, char*, int);
extern void	(*mlclosemodel)(void*);
extern int	(*mlmodelinfo)(void*, char*, int);
extern int	(*mlsetinput)(void*, char*, unsigned char*, int, char*, int);
extern int	(*mlrunmodel)(void*, char*, int);
extern int	(*mlgetoutput)(void*, char*, unsigned char*, int, char*, int);

__attribute__((constructor))
static void
mlhwinit(void)
{
	mlopenmodel = ml_open_model;
	mlclosemodel = ml_close_model;
	mlmodelinfo = ml_model_info;
	mlsetinput = ml_set_input;
	mlrunmodel = ml_run_model;
	mlgetoutput = ml_get_output;
}
