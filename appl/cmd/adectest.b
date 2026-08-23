implement Command;

#
# Tests audio(3)'s decode filter: quicktime(2) finds the coded audio samples
# in Limbo, /dev/audiodec turns each into PCM, and the PCM's pitch is measured
# and compared against what the clip was built with.
#
# Measuring the pitch is the point. "Some bytes came back" would pass against a
# decoder producing noise, silence or the wrong rate; a square wave of a known
# frequency will not.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "quicktime.m";
	qt: QuickTime;
	Track: import qt;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Mov:	con "/lib/movies/av.mov";
Ctl:	con "/dev/audioctl";
Dec:	con "/dev/audiodec";

fail := 0;

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

hex(b: array of byte): string
{
	d := "0123456789abcdef";
	s := "";
	for(i := 0; i < len b; i++){
		hi := (int b[i] >> 4) & 16rf;
		lo := int b[i] & 16rf;
		s += d[hi:hi+1] + d[lo:lo+1];
	}
	return s;
}

# Count sign changes in 16-bit little-endian mono PCM. For a square wave the
# zero crossings are exactly two per period, so the fundamental follows
# directly - no need for anything cleverer, and unlike a peak or an energy
# measure it cannot be fooled by silence or a DC offset.
pitch(pcm: array of byte, n, rate: int): int
{
	if(n < 4)
		return 0;
	cross := 0;
	prev := 0;
	nsamp := n/2;
	for(i := 0; i < nsamp; i++){
		v := (int pcm[2*i] | (int pcm[2*i+1] << 8)) & 16rffff;
		if(v >= 16r8000)
			v -= 16r10000;
		sgn := 0;
		if(v > 200)
			sgn = 1;
		else if(v < -200)
			sgn = -1;
		if(sgn != 0){
			if(prev != 0 && sgn != prev)
				cross++;
			prev = sgn;
		}
	}
	if(nsamp == 0)
		return 0;
	return cross * rate / (2 * nsamp);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	qt = load QuickTime QuickTime->PATH;
	if(qt == nil){
		print("adectest: load QuickTime: %r\n");
		raise "fail:load";
	}
	qt->init();

	(ts, err) := qt->tracks(Mov);
	if(err != nil){
		print("adectest: %s\n", err);
		raise "fail:parse";
	}
	t: ref Track;
	for(i := 0; i < len ts; i++)
		if(ts[i].kind == "soun")
			t = ts[i];
	if(t == nil || len t.samples == 0){
		print("adectest: %s has no audio track\n", Mov);
		raise "fail:parse";
	}
	if(t.extra == nil)
		bad("audio track has no setup data: a decoder cannot be configured");

	ctl := sys->open(Ctl, Sys->OWRITE);
	dec := sys->open(Dec, Sys->ORDWR);
	if(ctl == nil || dec == nil){
		print("adectest: no audio device: %r\n");
		raise "fail:no device";
	}

	cfg := sprint("decoder %s %d %d %s", t.codec, t.rate, t.chans, hex(t.extra));
	if(sys->fprint(ctl, "%s", cfg) < 0){
		print("adectest: decoder: %r\n");
		raise "fail:config";
	}

	mfd := sys->open(Mov, Sys->OREAD);
	if(mfd == nil){
		print("adectest: open %s: %r\n", Mov);
		raise "fail:open";
	}

	# One second of tone per ten video frames, so the whole track is one
	# 220Hz second here. Decode it all and measure the pitch across it.
	total := 0;
	pcm := array[4*1024*1024] of byte;
	nfilled := 0;
	for(k := 0; k < len t.samples; k++){
		s := t.samples[k];
		if(sys->seek(mfd, s.off, Sys->SEEKSTART) != s.off){
			bad(sprint("seek to sample %d: %r", k));
			break;
		}
		sb := array[s.size] of byte;
		if(sys->readn(mfd, sb, s.size) != s.size){
			bad(sprint("read sample %d: %r", k));
			break;
		}
		if(sys->write(dec, sb, s.size) != s.size){
			bad(sprint("decode sample %d: %r", k));
			break;
		}
		for(;;){
			n := sys->read(dec, pcm[nfilled:], len pcm - nfilled);
			if(n <= 0)
				break;
			nfilled += n;
			total += n;
		}
	}

	if(total == 0){
		bad("no PCM came back at all");
		raise "fail:test";
	}

	# AAC needs a couple of packets before it produces output, and the
	# first one it does produce carries the encoder's priming, so measure
	# past the start.
	skip := nfilled/4;
	hz := pitch(pcm[skip:], nfilled-skip, t.rate);
	want := 220;
	if(hz < want*9/10 || hz > want*11/10)
		bad(sprint("decoded tone is %dHz, expected about %dHz", hz, want));

	if(fail)
		raise "fail:test";
	print("  %d coded samples -> %d bytes of PCM at %dHz %d ch\n",
		len t.samples, total, t.rate, t.chans);
	print("  measured pitch %dHz, expected %dHz\n", hz, want);
	print("PASS\n");
}
