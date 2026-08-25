/*
 * CoreAudio (AudioQueue) backend for Inferno /dev/audio on MacOSX.
 * Implements emu/port/audio.h — PCM playback and capture.
 *
 * Ring buffers use Lock (not QLock): AudioQueue callbacks run on
 * host threads without an Inferno Proc.
 */
#import <AudioToolbox/AudioToolbox.h>

#include "dat.h"
#include "fns.h"
#include "error.h"
#include "audio.h"

#define Audio_Mic_Val		1
#define Audio_Linein_Val	2
#define Audio_Speaker_Val	1
#define Audio_Headphone_Val	2
#define Audio_Lineout_Val	3
#define Audio_Pcm_Val		1
#define Audio_Ulaw_Val		2
#define Audio_Alaw_Val		3

#include "audio-tbls.c"

enum {
	NBuffers	= 4,
	BufFrames	= 1024,
	RingBytes	= 64*1024,
};

typedef struct Ring Ring;
struct Ring
{
	uchar	*data;
	int	size;
	int	r;
	int	w;
	int	n;
	Lock	lk;
};

static Audio_t av;
static QLock inlock;
static QLock outlock;
static int in_refcnt;
static int out_refcnt;

static AudioQueueRef outq;
static AudioQueueRef inq;
static Ring outring;
static Ring inring;
static int out_running;
static int in_running;

static int
ringinit(Ring *rg, int size)
{
	rg->data = malloc(size);
	if(rg->data == nil)
		return -1;
	memset(rg->data, 0, size);
	rg->size = size;
	rg->r = rg->w = rg->n = 0;
	return 0;
}

static void
ringfree(Ring *rg)
{
	free(rg->data);
	rg->data = nil;
	rg->size = rg->r = rg->w = rg->n = 0;
}

/* Non-blocking; returns bytes transferred. Safe from AudioQueue threads. */
static int
ringput(Ring *rg, uchar *p, int n)
{
	int m, tot;

	tot = 0;
	lock(&rg->lk);
	while(n > 0 && rg->data != nil && rg->n < rg->size) {
		m = rg->size - rg->n;
		if(m > n)
			m = n;
		if(m > rg->size - rg->w)
			m = rg->size - rg->w;
		memmove(rg->data + rg->w, p, m);
		rg->w = (rg->w + m) % rg->size;
		rg->n += m;
		p += m;
		n -= m;
		tot += m;
	}
	unlock(&rg->lk);
	return tot;
}

static int
ringget(Ring *rg, uchar *p, int n)
{
	int m, tot;

	tot = 0;
	lock(&rg->lk);
	while(n > 0 && rg->data != nil && rg->n > 0) {
		m = rg->n;
		if(m > n)
			m = n;
		if(m > rg->size - rg->r)
			m = rg->size - rg->r;
		memmove(p, rg->data + rg->r, m);
		rg->r = (rg->r + m) % rg->size;
		rg->n -= m;
		p += m;
		n -= m;
		tot += m;
	}
	unlock(&rg->lk);
	return tot;
}

static void
fillasbd(AudioStreamBasicDescription *asbd, Audio_d *fmt)
{
	memset(asbd, 0, sizeof *asbd);
	asbd->mSampleRate = (Float64)fmt->rate;
	asbd->mFormatID = kAudioFormatLinearPCM;
	asbd->mFormatFlags = kLinearPCMFormatFlagIsSignedInteger
		| kLinearPCMFormatFlagIsPacked;
	asbd->mChannelsPerFrame = (UInt32)fmt->chan;
	asbd->mBitsPerChannel = (UInt32)fmt->bits;
	asbd->mBytesPerFrame = (fmt->bits/8) * fmt->chan;
	asbd->mFramesPerPacket = 1;
	asbd->mBytesPerPacket = asbd->mBytesPerFrame;
}

static void
outcallback(void *u, AudioQueueRef q, AudioQueueBufferRef b)
{
	int n;

	USED(u);
	n = ringget(&outring, b->mAudioData, (int)b->mAudioDataBytesCapacity);
	if(n < (int)b->mAudioDataBytesCapacity)
		memset((uchar*)b->mAudioData + n, 0,
			b->mAudioDataBytesCapacity - n);
	b->mAudioDataByteSize = b->mAudioDataBytesCapacity;
	AudioQueueEnqueueBuffer(q, b, 0, nil);
}

static void
incallback(void *u, AudioQueueRef q, AudioQueueBufferRef b,
	const AudioTimeStamp *t, UInt32 npack,
	const AudioStreamPacketDescription *pack)
{
	USED(u); USED(t); USED(npack); USED(pack);
	if(b->mAudioDataByteSize > 0)
		ringput(&inring, b->mAudioData, (int)b->mAudioDataByteSize);
	AudioQueueEnqueueBuffer(q, b, 0, nil);
}

static void
stop_out(void)
{
	if(outq) {
		AudioQueueStop(outq, true);
		AudioQueueDispose(outq, true);
		outq = nil;
	}
	out_running = 0;
	lock(&outring.lk);
	ringfree(&outring);
	unlock(&outring.lk);
}

static void
stop_in(void)
{
	if(inq) {
		AudioQueueStop(inq, true);
		AudioQueueDispose(inq, true);
		inq = nil;
	}
	in_running = 0;
	lock(&inring.lk);
	ringfree(&inring);
	unlock(&inring.lk);
}

static int
start_out(void)
{
	AudioStreamBasicDescription asbd;
	AudioQueueBufferRef b;
	OSStatus st;
	int i, bytes;

	if(out_running)
		return 0;
	if(ringinit(&outring, RingBytes) < 0)
		return -1;
	fillasbd(&asbd, &av.out);
	st = AudioQueueNewOutput(&asbd, outcallback, nil, nil, nil, 0, &outq);
	if(st != noErr) {
		ringfree(&outring);
		return -1;
	}
	bytes = BufFrames * (int)asbd.mBytesPerFrame;
	for(i = 0; i < NBuffers; i++) {
		st = AudioQueueAllocateBuffer(outq, bytes, &b);
		if(st != noErr) {
			stop_out();
			return -1;
		}
		memset(b->mAudioData, 0, bytes);
		b->mAudioDataByteSize = bytes;
		AudioQueueEnqueueBuffer(outq, b, 0, nil);
	}
	st = AudioQueueStart(outq, nil);
	if(st != noErr) {
		stop_out();
		return -1;
	}
	out_running = 1;
	return 0;
}

static int
start_in(void)
{
	AudioStreamBasicDescription asbd;
	AudioQueueBufferRef b;
	OSStatus st;
	int i, bytes;

	if(in_running)
		return 0;
	if(ringinit(&inring, RingBytes) < 0)
		return -1;
	fillasbd(&asbd, &av.in);
	st = AudioQueueNewInput(&asbd, incallback, nil, nil, nil, 0, &inq);
	if(st != noErr) {
		ringfree(&inring);
		return -1;
	}
	bytes = BufFrames * (int)asbd.mBytesPerFrame;
	for(i = 0; i < NBuffers; i++) {
		st = AudioQueueAllocateBuffer(inq, bytes, &b);
		if(st != noErr) {
			stop_in();
			return -1;
		}
		AudioQueueEnqueueBuffer(inq, b, 0, nil);
	}
	st = AudioQueueStart(inq, nil);
	if(st != noErr) {
		stop_in();
		return -1;
	}
	in_running = 1;
	return 0;
}

void
audio_file_init(void)
{
	audio_info_init(&av);
}

void
audio_ctl_init(void)
{
}

Audio_t*
getaudiodev(void)
{
	return &av;
}

void
audio_file_open(Chan *c, int omode)
{
	if(omode == OREAD || omode == ORDWR) {
		qlock(&inlock);
		if(in_refcnt == 0 && start_in() < 0) {
			qunlock(&inlock);
			error("audio in unavailable");
		}
		in_refcnt++;
		qunlock(&inlock);
	}
	if(omode == OWRITE || omode == ORDWR) {
		qlock(&outlock);
		if(out_refcnt == 0 && start_out() < 0) {
			qunlock(&outlock);
			if(omode == ORDWR) {
				qlock(&inlock);
				if(--in_refcnt <= 0) {
					in_refcnt = 0;
					stop_in();
				}
				qunlock(&inlock);
			}
			error("audio out unavailable");
		}
		out_refcnt++;
		qunlock(&outlock);
	}
	USED(c);
}

long
audio_file_read(Chan *c, void *va, long n, vlong off)
{
	long tot, m;

	USED(c); USED(off);
	if(n <= 0)
		return 0;
	tot = 0;
	while(tot < n) {
		m = ringget(&inring, (uchar*)va + tot, (int)(n - tot));
		if(m > 0) {
			tot += m;
			continue;
		}
		if(tot > 0 || !in_running)
			break;
		osmillisleep(5);
	}
	return tot;
}

long
audio_file_write(Chan *c, void *va, long n, vlong off)
{
	long tot, m;

	USED(c); USED(off);
	if(n <= 0)
		return 0;
	tot = 0;
	while(tot < n) {
		m = ringput(&outring, (uchar*)va + tot, (int)(n - tot));
		if(m > 0) {
			tot += m;
			continue;
		}
		if(!out_running)
			break;
		osmillisleep(5);
	}
	return tot;
}

long
audio_ctl_write(Chan *c, void *va, long n, vlong off)
{
	Audio_t tmp;
	int r;

	USED(c); USED(off);
	tmp = av;
	r = audioparse((char*)va, (int)n, &tmp);
	if(r < 0)
		error("audio ctl: bad verb");
	if(in_refcnt == 0)
		av.in = tmp.in;
	if(out_refcnt == 0)
		av.out = tmp.out;
	if(in_refcnt == 0 && out_refcnt == 0)
		av = tmp;
	return n;
}

void
audio_file_close(Chan *c)
{
	if(c->mode == OREAD || c->mode == ORDWR) {
		qlock(&inlock);
		if(--in_refcnt <= 0) {
			in_refcnt = 0;
			stop_in();
		}
		qunlock(&inlock);
	}
	if(c->mode == OWRITE || c->mode == ORDWR) {
		qlock(&outlock);
		if(--out_refcnt <= 0) {
			out_refcnt = 0;
			/* Let queued samples drain briefly. */
			osmillisleep(100);
			stop_out();
		}
		qunlock(&outlock);
	}
}
