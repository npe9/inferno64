/*
 * mlcaps - what CoreML will actually tell us, before ml(3) is written against it.
 *
 * Not part of the build. Three questions the device's protocol depends on, and
 * guessing any of them wrong means rewriting the protocol later:
 *
 *  1. Does compileModelAtURL: accept a plain .mlmodel staged to a temporary
 *     file?  If it does, models can cross as bytes over the device and no host
 *     path ever has to be handed in - which is the whole point, since an
 *     Inferno path is not a host path.
 *  2. What does modelDescription publish about inputs and outputs?  A client
 *     cannot form a valid write without names, shapes and element types, so
 *     whatever this prints is what ml(3)'s "info" file has to carry.
 *  3. Can the compute unit that actually ran be reported, or only the one
 *     requested?  gpu(3) shipped that distinction wrong once, claiming f64 on
 *     a wire carrying f32.  MLComputePlan is the candidate.
 *
 *	clang -fobjc-arc -o mlcaps emu/MacOSX/mlcaps.m \
 *		-framework Foundation -framework CoreML
 *	./mlcaps lib/ml/linear.mlmodel
 */
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#include <stdio.h>

static const char*
dtype(MLMultiArrayDataType t)
{
	switch(t){
	case MLMultiArrayDataTypeDouble:	return "f64";
	case MLMultiArrayDataTypeFloat32:	return "f32";
	case MLMultiArrayDataTypeFloat16:	return "f16";
	case MLMultiArrayDataTypeInt32:		return "i32";
	default:				return "?";
	}
}

static void
describe(const char *what, NSDictionary<NSString*,MLFeatureDescription*> *d)
{
	for(NSString *k in d){
		MLFeatureDescription *f = d[k];
		if(f.type == MLFeatureTypeMultiArray){
			MLMultiArrayConstraint *c = f.multiArrayConstraint;
			printf("  %s %s: multiarray %s [", what, k.UTF8String, dtype(c.dataType));
			for(NSUInteger i = 0; i < c.shape.count; i++)
				printf("%s%ld", i ? " " : "", (long)c.shape[i].integerValue);
			printf("]\n");
		}else
			printf("  %s %s: type %ld (not a multiarray)\n",
				what, k.UTF8String, (long)f.type);
	}
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		if(argc < 2){ fprintf(stderr, "usage: mlcaps model.mlmodel\n"); return 1; }

		/* 1. Read the bytes and stage them, exactly as the device would
		 * after taking a model over its own file - no host path from
		 * the caller. */
		NSData *bytes = [NSData dataWithContentsOfFile:@(argv[1])];
		if(bytes == nil){ fprintf(stderr, "mlcaps: cannot read %s\n", argv[1]); return 1; }
		printf("model is %lu bytes\n", (unsigned long)bytes.length);

		NSString *tmp = [NSTemporaryDirectory()
			stringByAppendingPathComponent:@"mlcaps-staged.mlmodel"];
		if(![bytes writeToFile:tmp atomically:YES]){
			fprintf(stderr, "mlcaps: cannot stage\n"); return 1;
		}
		NSError *err = nil;
		NSURL *compiled = [MLModel compileModelAtURL:[NSURL fileURLWithPath:tmp] error:&err];
		if(compiled == nil){
			fprintf(stderr, "mlcaps: compile: %s\n",
				err.localizedDescription.UTF8String);
			return 1;
		}
		printf("compiled a staged .mlmodel: yes -> %s\n",
			compiled.lastPathComponent.UTF8String);

		/* 2. What has to go in "info". */
		MLModelConfiguration *cfg = [MLModelConfiguration new];
		cfg.computeUnits = MLComputeUnitsAll;
		MLModel *m = [MLModel modelWithContentsOfURL:compiled configuration:cfg error:&err];
		if(m == nil){
			fprintf(stderr, "mlcaps: load: %s\n", err.localizedDescription.UTF8String);
			return 1;
		}
		printf("description:\n");
		describe("in ", m.modelDescription.inputDescriptionsByName);
		describe("out", m.modelDescription.outputDescriptionsByName);

		/* Run it, so the fixture's arithmetic is checked by something
		 * that can actually run it. */
		NSArray *shape = @[@3];
		MLMultiArray *x = [[MLMultiArray alloc] initWithShape:shape
			dataType:MLMultiArrayDataTypeFloat32 error:&err];
		float *xp = (float*)x.dataPointer;
		xp[0] = 1; xp[1] = 2; xp[2] = 3;
		MLDictionaryFeatureProvider *in = [[MLDictionaryFeatureProvider alloc]
			initWithDictionary:@{@"x": x} error:&err];
		id<MLFeatureProvider> out = [m predictionFromFeatures:in error:&err];
		if(out == nil){
			fprintf(stderr, "mlcaps: predict: %s\n", err.localizedDescription.UTF8String);
			return 1;
		}
		MLMultiArray *y = [out featureValueForName:@"y"].multiArrayValue;
		printf("x=(1,2,3) gives y=(");
		for(NSUInteger i = 0; i < y.count; i++)
			printf("%s%g", i ? ", " : "", y[i].floatValue);
		printf("), expected (14.5, 139.5)\n");

		/* 3. Can what actually ran be reported? */
		if(@available(macOS 14.4, *)){
			printf("MLComputePlan: available at compile time\n");
			dispatch_semaphore_t s = dispatch_semaphore_create(0);
			__block int got = 0;
			[MLComputePlan loadContentsOfURL:compiled configuration:cfg
			    completionHandler:^(MLComputePlan *plan, NSError *e){
				if(plan == nil){
					printf("MLComputePlan: load failed: %s\n",
						e.localizedDescription.UTF8String);
				}else{
					MLModelStructure *st = plan.modelStructure;
					printf("MLComputePlan: loaded, structure %s\n",
						st ? "present" : "nil");
					if(st.neuralNetwork != nil){
						for(MLModelStructureNeuralNetworkLayer *l in st.neuralNetwork.layers){
							MLComputePlanDeviceUsage *u =
								[plan computeDeviceUsageForNeuralNetworkLayer:l];
							printf("  layer %s -> %s\n",
								l.name.UTF8String,
								u ? u.preferredComputeDevice.description.UTF8String
								  : "(no usage reported)");
						}
					}
				}
				got = 1;
				dispatch_semaphore_signal(s);
			}];
			dispatch_semaphore_wait(s,
				dispatch_time(DISPATCH_TIME_NOW, 20LL*NSEC_PER_SEC));
			if(!got)
				printf("MLComputePlan: timed out\n");
		}else
			printf("MLComputePlan: not available\n");

		printf("available compute unit requests: cpu, cpuAndGPU, cpuAndNeuralEngine, all\n");
	}
	return 0;
}
