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

/*
 * AAC decode for /dev/audiodec, one coded sample at a time.
 *
 * AudioConverter rather than AVFoundation, because this must work on a
 * stream: quicktime(2) hands over the coded samples it found and each one is
 * converted on its own, so nothing is staged and no file is opened here.
 *
 * The esds payload from the container goes in as the decompression magic
 * cookie, which is how the converter learns the exact AAC profile - guessing
 * it from the sample rate and channel count works until it does not.
 */
#import <AudioToolbox/AudioToolbox.h>

extern void*	(*audiodecopen)(char*, int, int, uchar*, int);
extern int	(*audiodecsample)(void*, uchar*, int, uchar*, int);
extern void	(*audiodecclose)(void*);

typedef struct Adec Adec;
struct Adec {
	AudioConverterRef	conv;
	AudioStreamBasicDescription in, out;
	uchar			*pkt;	/* the sample being converted */
	int			npkt;
	int			done;	/* the converter has taken it */
};

/*
 * Called by the converter when it wants input. One coded sample is one packet,
 * and it is offered exactly once: returning zero packets afterwards is what
 * tells the converter to stop rather than block.
 */
static OSStatus
adec_input(AudioConverterRef conv, UInt32 *npkt, AudioBufferList *bl,
	AudioStreamPacketDescription **pdesc, void *ref)
{
	Adec *d = ref;
	static AudioStreamPacketDescription pd;

	USED(conv);
	if(d->done || d->pkt == nil || d->npkt <= 0){
		*npkt = 0;
		return noErr;
	}
	bl->mNumberBuffers = 1;
	bl->mBuffers[0].mNumberChannels = d->in.mChannelsPerFrame;
	bl->mBuffers[0].mDataByteSize = d->npkt;
	bl->mBuffers[0].mData = d->pkt;
	pd.mStartOffset = 0;
	pd.mVariableFramesInPacket = 0;
	pd.mDataByteSize = d->npkt;
	if(pdesc != NULL)
		*pdesc = &pd;
	*npkt = 1;
	d->done = 1;
	return noErr;
}

static void*
metal_audiodec_open(char *codec, int rate, int chans, uchar *extra, int nextra)
{
	Adec *d;
	OSStatus st;

	if(codec == nil || strcmp(codec, "mp4a") != 0){
		kwerrstr("audio decode: only mp4a is supported here");
		return nil;
	}
	d = mallocz(sizeof(Adec), 1);
	if(d == nil)
		return nil;

	d->in.mSampleRate = rate;
	d->in.mFormatID = kAudioFormatMPEG4AAC;
	d->in.mChannelsPerFrame = chans;
	d->in.mFramesPerPacket = 1024;		/* AAC-LC */

	d->out.mSampleRate = rate;
	d->out.mFormatID = kAudioFormatLinearPCM;
	d->out.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	d->out.mBitsPerChannel = 16;
	d->out.mChannelsPerFrame = chans;
	d->out.mFramesPerPacket = 1;
	d->out.mBytesPerFrame = 2 * chans;
	d->out.mBytesPerPacket = d->out.mBytesPerFrame;

	st = AudioConverterNew(&d->in, &d->out, &d->conv);
	if(st != noErr){
		kwerrstr("audio decode: cannot create a converter");
		free(d);
		return nil;
	}
	if(extra != nil && nextra > 0){
		/* Not fatal if refused: some streams carry no usable cookie
		 * and the format above is enough. */
		AudioConverterSetProperty(d->conv,
			kAudioConverterDecompressionMagicCookie, nextra, extra);
	}
	return d;
}

static int
metal_audiodec_sample(void *dec, uchar *in, int nin, uchar *out, int nout)
{
	Adec *d = dec;
	AudioBufferList bl;
	UInt32 frames;
	OSStatus st;

	if(d == nil || in == nil || nin <= 0){
		kwerrstr("audio decode: nothing to decode");
		return -1;
	}
	d->pkt = in;
	d->npkt = nin;
	d->done = 0;

	/*
	 * Exactly one packet's worth, not as much as the output buffer holds.
	 * Asking for more makes the converter consume this packet, ask for
	 * another, get none, and treat the stream as ended - after which it
	 * returns nothing for every later sample. That looked like a decoder
	 * that produced one buffer of silence and then stopped.
	 */
	frames = d->in.mFramesPerPacket;
	if(frames > (UInt32)(nout / d->out.mBytesPerFrame))
		frames = nout / d->out.mBytesPerFrame;
	bl.mNumberBuffers = 1;
	bl.mBuffers[0].mNumberChannels = d->out.mChannelsPerFrame;
	bl.mBuffers[0].mDataByteSize = nout;
	bl.mBuffers[0].mData = out;

	st = AudioConverterFillComplexBuffer(d->conv, adec_input, d, &frames, &bl, NULL);
	d->pkt = nil;
	d->npkt = 0;
	if(st != noErr && frames == 0){
		kwerrstr("audio decode: converter failed");
		return -1;
	}
	return (int)(frames * d->out.mBytesPerFrame);
}

static void
metal_audiodec_close(void *dec)
{
	Adec *d = dec;

	if(d == nil)
		return;
	if(d->conv != NULL)
		AudioConverterDispose(d->conv);
	free(d);
}

__attribute__((constructor))
static void
audiodec_register(void)
{
	audiodecopen = metal_audiodec_open;
	audiodecsample = metal_audiodec_sample;
	audiodecclose = metal_audiodec_close;
}
