/*
 * vtcaps - report which video codecs this machine accelerates in hardware.
 *
 * Not part of the emu build: a standalone probe, because the answer varies by
 * chip tier and guessing it has already misdirected planning once. Base
 * M-series parts have no ProRes hardware; AV1 decode arrived with M3. Build
 * and run it on any machine before assuming what the media engines can do:
 *
 *	cc -fobjc-arc -framework Foundation -framework VideoToolbox \
 *		-framework CoreMedia -o vtcaps vtcaps.m && ./vtcaps
 *
 * The media engines are fixed-function blocks distinct from both the GPU and
 * the Neural Engine, so what they do runs concurrently with Metal compute and
 * CoreML rather than contending with either. See doc/hpc-plan.md item 6.
 */
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

static void dec(const char *name, CMVideoCodecType c)
{
	printf("  decode  %-12s %s\n", name, VTIsHardwareDecodeSupported(c) ? "HARDWARE" : "no");
}

int main(void)
{
	@autoreleasepool {
		printf("hardware DECODE (VTIsHardwareDecodeSupported):\n");
		dec("H.264",       kCMVideoCodecType_H264);
		dec("HEVC",        kCMVideoCodecType_HEVC);
		dec("AV1",         kCMVideoCodecType_AV1);
		dec("VP9",         kCMVideoCodecType_VP9);
		dec("ProRes422",   kCMVideoCodecType_AppleProRes422);
		dec("ProRes4444",  kCMVideoCodecType_AppleProRes4444);
		dec("ProResRAW",   kCMVideoCodecType_AppleProResRAW);
		dec("MPEG4",       kCMVideoCodecType_MPEG4Video);
		dec("JPEG",        kCMVideoCodecType_JPEG);

		printf("\nhardware ENCODERS (VTCopyVideoEncoderList):\n");
		CFArrayRef list = NULL;
		if(VTCopyVideoEncoderList(NULL, &list) == noErr && list){
			for(CFIndex i = 0; i < CFArrayGetCount(list); i++){
				CFDictionaryRef d = CFArrayGetValueAtIndex(list, i);
				CFStringRef nm = CFDictionaryGetValue(d, kVTVideoEncoderList_DisplayName);
				CFBooleanRef hw = CFDictionaryGetValue(d, kVTVideoEncoderList_IsHardwareAccelerated);
				if(hw && CFBooleanGetValue(hw))
					printf("  encode  %s\n", [(__bridge NSString*)nm UTF8String]);
			}
			CFRelease(list);
		}
	}
	return 0;
}
