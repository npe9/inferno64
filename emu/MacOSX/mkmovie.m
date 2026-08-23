/*
 * mkmovie - build the test clip used by drawdecodetest(1).
 *
 * Not part of the emu build, and the same kind of thing as vtcaps.m: a
 * standalone tool kept because the fixture it produces is committed and
 * someone will eventually need to know how it was made, or want a different
 * one. Uses hardware H.264 encode, so together with the decode test it
 * exercises both halves of the media engine.
 *
 * The clip also carries an AAC audio track: a square wave whose frequency
 * steps with the video colour, so a sync test has something in the sound it
 * can point at and say which frame it belongs with.
 *
 * Flat colour per frame on purpose - frame i is rgb(20+20i, 128, 220-20i).
 * A lossy codec reproduces a flat block within a few counts, which is what
 * lets a decode test assert a colour instead of merely that something was
 * written; and because the colour differs per frame, a test can tell frame n
 * from frame 0.
 *
 *	cc -fobjc-arc -framework Foundation -framework AVFoundation \
 *		-framework CoreMedia -framework CoreVideo -o mkmovie mkmovie.m
 *	./mkmovie $ROOT/lib/movies/test.mov		# the committed fixture
 *	./mkmovie /tmp/big.mov 1920 1080 60		# a larger one, for timing
 */
// Generates a tiny test movie: N frames of flat, known colours.
// Flat blocks so lossy H.264 still reproduces the colour closely, which is
// what makes a decode test able to assert an expected value.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

int main(int argc, char **argv)
{
	@autoreleasepool {
		if(argc < 2){ fprintf(stderr, "usage: mkmovie out.mov [w h nframes]\n"); return 1; }
		NSString *path = [NSString stringWithUTF8String:argv[1]];
		[[NSFileManager defaultManager] removeItemAtPath:path error:nil];
		NSError *err = nil;
		int W = 64, H = 64, N = 10;
		if(argc >= 5){ W = atoi(argv[2]); H = atoi(argv[3]); N = atoi(argv[4]); }

		AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:path]
			fileType:AVFileTypeQuickTimeMovie error:&err];
		if(w == nil){ NSLog(@"writer: %@", err); return 1; }
		NSDictionary *set = @{ AVVideoCodecKey: AVVideoCodecTypeH264,
			AVVideoWidthKey: @(W), AVVideoHeightKey: @(H) };
		AVAssetWriterInput *in = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
			outputSettings:set];
		in.expectsMediaDataInRealTime = NO;
		AVAssetWriterInputPixelBufferAdaptor *ad =
			[AVAssetWriterInputPixelBufferAdaptor
			 assetWriterInputPixelBufferAdaptorWithAssetWriterInput:in
			 sourcePixelBufferAttributes:@{
				(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
				(id)kCVPixelBufferWidthKey: @(W),
				(id)kCVPixelBufferHeightKey: @(H) }];
		[w addInput:in];

		/* Both inputs must exist before startWriting: canAddInput
		 * refuses afterwards, and an input that was never added never
		 * becomes ready. */
		double rate = 44100;
		NSDictionary *aset = @{
			AVFormatIDKey: @(kAudioFormatMPEG4AAC),
			AVSampleRateKey: @(rate),
			AVNumberOfChannelsKey: @1,
			AVEncoderBitRateKey: @64000 };
		AVAssetWriterInput *ain = [AVAssetWriterInput
			assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:aset];
		ain.expectsMediaDataInRealTime = NO;
		if(![w canAddInput:ain]){
			fprintf(stderr, "mkmovie: cannot add an audio input\n");
			return 1;
		}
		[w addInput:ain];

		[w startWriting];
		[w startSessionAtSourceTime:kCMTimeZero];

		/*
		 * Both tracks are fed in presentation-time order, always
		 * appending to whichever input is furthest behind.
		 *
		 * Appending all the video and then all the audio is the
		 * obvious thing and it does work - until it doesn't.
		 * AVAssetWriter will not accept an unbounded backlog on one
		 * input while another is starved, so that version survived ten
		 * frames, filled the queue at eighty, and threw
		 * "cannot be appended when readyForMoreMediaData is NO".
		 * Interleaving keeps neither input starved and has no such
		 * limit.
		 *
		 * Video: frame i is a flat colour at i/10 s - red ramping up,
		 * green fixed, blue ramping down. Audio: a square wave
		 * stepping 220Hz, 440Hz, 660Hz... one second per ten frames,
		 * so the tone changes in step with the picture. Square rather
		 * than sine because AAC preserves its fundamental clearly
		 * enough that a decode test can measure the pitch back.
		 */
		int nsec = (N + 9) / 10;
		AudioStreamBasicDescription lpcm = {0};
		lpcm.mSampleRate = rate;
		lpcm.mFormatID = kAudioFormatLinearPCM;
		lpcm.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
		lpcm.mBitsPerChannel = 16;
		lpcm.mChannelsPerFrame = 1;
		lpcm.mFramesPerPacket = 1;
		lpcm.mBytesPerFrame = 2;
		lpcm.mBytesPerPacket = 2;

		int per = (int)rate;			/* one second at a time */
		CMFormatDescriptionRef afmt = NULL;
		CMAudioFormatDescriptionCreate(NULL, &lpcm, 0, NULL, 0, NULL, NULL, &afmt);

		int vi = 0, sec = 0;
		while(vi < N || sec < nsec){
			/* whichever track's next sample is earlier */
			int dovideo = vi < N && (sec >= nsec || vi/10.0 <= (double)sec);
			AVAssetWriterInput *want = dovideo ? in : ain;
			int spin;
			for(spin = 0; !want.isReadyForMoreMediaData && spin < 10000; spin++)
				usleep(1000);
			if(!want.isReadyForMoreMediaData){
				fprintf(stderr, "mkmovie: %s input never became ready\n",
					dovideo ? "video" : "audio");
				return 1;
			}
			if(dovideo){
				CVPixelBufferRef pb = NULL;
				CVPixelBufferPoolCreatePixelBuffer(NULL, ad.pixelBufferPool, &pb);
				if(pb == NULL){ NSLog(@"no pixel buffer"); return 1; }
				CVPixelBufferLockBaseAddress(pb, 0);
				uint8_t *b = CVPixelBufferGetBaseAddress(pb);
				size_t bpr = CVPixelBufferGetBytesPerRow(pb);
				uint8_t r = 20 + vi*20, g = 128, bl = 220 - vi*20;
				for(int y = 0; y < H; y++)
					for(int x = 0; x < W; x++){
						uint8_t *p = b + y*bpr + x*4;
						p[0] = bl; p[1] = g; p[2] = r; p[3] = 255;  // BGRA
					}
				CVPixelBufferUnlockBaseAddress(pb, 0);
				[ad appendPixelBuffer:pb withPresentationTime:CMTimeMake(vi, 10)];
				CVPixelBufferRelease(pb);
				vi++;
				continue;
			}
			/* The block buffer keeps this until the writer is done with
			 * it, so each second gets its own; kCFAllocatorMalloc makes
			 * the block buffer free it. A single reused buffer would be
			 * overwritten while still queued. */
			int16_t *pcm = malloc(per * 2);
			double hz = 220.0 * (sec + 1);
			int period = (int)(rate / hz);
			for(int k = 0; k < per; k++)
				pcm[k] = ((k / (period/2)) & 1) ? 8000 : -8000;
			CMBlockBufferRef bb = NULL;
			CMBlockBufferCreateWithMemoryBlock(NULL, pcm, per*2, kCFAllocatorMalloc,
				NULL, 0, per*2, 0, &bb);
			CMSampleBufferRef sb = NULL;
			CMSampleTimingInfo ti = { CMTimeMake(1, (int)rate),
				CMTimeMake(sec*(int)rate, (int)rate), kCMTimeInvalid };
			CMSampleBufferCreate(NULL, bb, TRUE, NULL, NULL, afmt, per, 1, &ti, 0, NULL, &sb);
			[ain appendSampleBuffer:sb];
			CFRelease(sb);
			CFRelease(bb);
			sec++;
		}
		[in markAsFinished];
		[ain markAsFinished];
		dispatch_semaphore_t s = dispatch_semaphore_create(0);
		[w finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(s); }];
		dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
		if(w.status != AVAssetWriterStatusCompleted){ NSLog(@"write: %@", w.error); return 1; }
		printf("wrote %s: %d frames %dx%d h264 + %d s aac (220Hz steps)\n",
			argv[1], N, W, H, nsec);
		return 0;
	}
}
