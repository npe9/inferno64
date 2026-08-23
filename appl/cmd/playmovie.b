implement Command;

#
# Play a movie: decode both tracks and pace the video against the audio.
#
# The audio is the clock, and it has to be. A sound card consumes samples at
# its own fixed rate and a write to /dev/audio blocks when the buffer is full,
# so feeding it paces the loop for free and gives a position to fit the video
# to. Driving the other way - showing frames on a timer and playing audio to
# match - means resampling audio whenever the timer drifts, which is audible.
#
# quicktime(2) locates the coded samples of both tracks; audio(3) and draw(3)
# decode them. Nothing here knows how AAC or H.264 work, and nothing in the
# kernel knows what an MP4 is.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "string.m";
	str: String;
include "quicktime.m";
	qt: QuickTime;
	Track, Sample: import qt;
include "draw.m";
	draw: Draw;
	Chans: import draw;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Ctl:	con "/dev/audioctl";
Adec:	con "/dev/audiodec";
Audio:	con "/dev/audio";
Id:	con 1;		# first of Nbuf image ids
Nbuf:	con 4;		# decoded frames held while reordering

fail := 0;
quiet := 0;

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

p32(b: array of byte, o: int, v: int)
{
	b[o] = byte v; b[o+1] = byte (v>>8); b[o+2] = byte (v>>16); b[o+3] = byte (v>>24);
}

prect(b: array of byte, o, x0, y0, x1, y1: int)
{
	p32(b, o, x0); p32(b, o+4, y0); p32(b, o+8, x1); p32(b, o+12, y1);
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: playmovie [-s] file.mov\n");
	raise "fail:usage";
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	qt = load QuickTime QuickTime->PATH;
	draw = load Draw Draw->PATH;
	if(qt == nil || draw == nil || str == nil){
		print("playmovie: load: %r\n");
		raise "fail:load";
	}
	qt->init();

	argv = tl argv;
	while(argv != nil && len hd argv > 1 && (hd argv)[0] == '-'){
		case hd argv {
		"-s" =>	quiet = 1;	# report drift only; do not open /dev/audio
		* =>	usage();
		}
		argv = tl argv;
	}
	if(argv == nil)
		usage();
	mov := hd argv;

	(ts, err) := qt->tracks(mov);
	if(err != nil){
		print("playmovie: %s\n", err);
		raise "fail:parse";
	}
	vt, at: ref Track;
	for(i := 0; i < len ts; i++){
		if(ts[i].kind == "vide" && vt == nil)
			vt = ts[i];
		if(ts[i].kind == "soun" && at == nil)
			at = ts[i];
	}
	if(vt == nil && at == nil){
		print("playmovie: %s has nothing to play\n", mov);
		raise "fail:parse";
	}

	mfd := sys->open(mov, Sys->OREAD);
	if(mfd == nil){
		print("playmovie: open %s: %r\n", mov);
		raise "fail:open";
	}

	# Audio decoder and output.
	adec: ref Sys->FD;
	aout: ref Sys->FD;
	bps := 0;
	if(at != nil && at.extra != nil){
		ctl := sys->open(Ctl, Sys->OWRITE);
		adec = sys->open(Adec, Sys->ORDWR);
		if(ctl == nil || adec == nil){
			print("playmovie: no audio device: %r\n");
			raise "fail:no audio";
		}
		if(sys->fprint(ctl, "decoder %s %d %d %s",
		    at.codec, at.rate, at.chans, hex(at.extra)) < 0){
			print("playmovie: audio decoder: %r\n");
			raise "fail:config";
		}
		bps = at.rate * at.chans * 2;
		if(!quiet){
			if(sys->fprint(ctl, "rate %d\nchans %d\nbits 16\nenc pcm\n",
			    at.rate, at.chans) < 0)
				print("playmovie: audioctl: %r\n");
			aout = sys->open(Audio, Sys->OWRITE);
			if(aout == nil)
				print("playmovie: %s: %r (continuing without sound)\n", Audio);
		}
	}

	# Video decoder, into an image the size of the track.
	vdata, vvideo, vdraw: ref Sys->FD;
	if(vt != nil && vt.extra != nil){
		if(sys->bind("#i", "/dev", Sys->MBEFORE) < 0){
			print("playmovie: bind #i: %r\n");
			raise "fail:no draw";
		}
		dctl := sys->open("/dev/draw/new", Sys->ORDWR);
		if(dctl == nil){
			print("playmovie: no /dev/draw: %r\n");
			raise "fail:no draw";
		}
		cbuf := array[12*12] of byte;
		n := sys->read(dctl, cbuf, len cbuf);
		if(n < 12){
			print("playmovie: short draw ctl read\n");
			raise "fail:ctl";
		}
		(cid, nil) := str->toint(str->drop(string cbuf[0:n], " "), 10);
		vdraw = sys->open(sprint("/dev/draw/%d/data", cid), Sys->ORDWR);
		vvideo = sys->open(sprint("/dev/draw/%d/video", cid), Sys->OWRITE);
		vdata = sys->open(sprint("/dev/draw/%d/videodata", cid), Sys->OWRITE);
		if(vdraw == nil || vvideo == nil || vdata == nil){
			print("playmovie: open draw client: %r\n");
			raise "fail:open";
		}
		# A ring of images, not one: the decoder emits frames in decode
		# order and they must be shown in presentation order, so
		# several decoded frames have to exist at once.
		cd := Chans.mk("x8r8g8b8");
		for(k := 0; k < Nbuf; k++){
			m := array[1+4+4+1+4+1+16+16+4] of byte;
			m[0] = byte 'b';
			p32(m, 1, Id+k);
			p32(m, 5, 0);
			m[9] = byte 0;
			p32(m, 10, cd.desc);
			m[14] = byte 0;
			prect(m, 15, 0, 0, vt.width, vt.height);
			prect(m, 31, 0, 0, vt.width, vt.height);
			p32(m, 47, 0);
			if(sys->write(vdraw, m, len m) != len m){
				print("playmovie: allocate image %d: %r\n", k);
				raise "fail:image";
			}
		}
		if(sys->fprint(vvideo, "decoder %s %s", vt.codec, hex(vt.extra)) < 0){
			print("playmovie: video decoder: %r\n");
			raise "fail:config";
		}
	}

	play(mfd, vt, at, adec, aout, vdata, vvideo, bps);

	if(fail)
		raise "fail:play";
}

sample(mfd: ref Sys->FD, s: Sample): array of byte
{
	if(sys->seek(mfd, s.off, Sys->SEEKSTART) != s.off)
		return nil;
	b := array[s.size] of byte;
	if(sys->readn(mfd, b, s.size) != s.size)
		return nil;
	return b;
}

# Feed audio, and show each video frame when the audio has reached it.
#
# Audio time is what has been handed to the device, which runs ahead of what
# has been heard by however deep its buffer is. That offset is constant, so it
# does not accumulate: it shifts the whole picture a fixed amount rather than
# letting video and audio drift apart, which is the thing that matters.
play(mfd: ref Sys->FD, vt, at: ref Track, adec, aout, vdata, vvideo: ref Sys->FD, bps: int)
{
	bufpts := array[Nbuf] of int;		# presentation time held in each
	buffull := array[Nbuf] of { * => 0 };
	nheld := 0;
	shown := -1;			# presentation time of the last frame shown
	k := 0;
	pcm := array[512*1024] of byte;
	ai := 0;			# next audio sample
	vi := 0;			# next video sample
	abytes := 0;			# PCM handed to the device
	worst := 0;			# worst |video - audio| seen, in ms
	nv := 0;
	na := 0;

	if(vt == nil && at == nil)
		return;
	nasamp := 0;
	if(at != nil)
		nasamp = len at.samples;
	nvsamp := 0;
	if(vt != nil)
		nvsamp = len vt.samples;

	for(;;){
		# Not done when both tracks have been fed: the ring still holds
		# frames that have been decoded and not yet shown. Breaking here
		# drops them, which the fixtures hide because mkmovie rounds the
		# audio up to a whole second so it always outlasts the video.
		if(ai >= nasamp && vi >= nvsamp && nheld == 0)
			break;

		# Where the audio has got to, in milliseconds.
		ams := 0;
		if(bps > 0)
			ams = abytes * 1000 / bps;

		# Show the earliest held frame the audio has reached. This is
		# where the frame would go to the screen; the gap between its
		# presentation time and the audio clock is the sync error.
		best := -1;
		for(k = 0; k < Nbuf; k++)
			if(buffull[k] && (best < 0 || bufpts[k] < bufpts[best]))
				best = k;
		if(best >= 0 && (nasamp == 0 || ai >= nasamp || bufpts[best] <= ams)){
			d := bufpts[best] - ams;
			if(d < 0)
				d = -d;
			if(bps > 0 && d > worst)
				worst = d;
			# Reordering is only correct if what comes out is
			# monotonic. With a finite ring it need not be: a
			# frame can be shown before one still undecoded that
			# belongs earlier, and this is where that shows up.
			if(bufpts[best] < shown)
				bad(sprint("frame at %dms shown after %dms: reorder buffer too small",
					bufpts[best], shown));
			shown = bufpts[best];
			buffull[best] = 0;
			nheld--;
			nv++;
			continue;
		}

		# Decode ahead while there is room. Frames arrive in decode
		# order; holding several is what makes showing them in
		# presentation order possible at all.
		if(vi < nvsamp && nheld < Nbuf){
			slot := -1;
			for(k = 0; k < Nbuf; k++)
				if(!buffull[k]){
					slot = k;
					break;
				}
			s := vt.samples[vi];
			pts := (vi*s.delta + s.coff) * 1000 / vt.timescale;
			sb := sample(mfd, s);
			if(sb == nil){
				bad(sprint("read video sample %d: %r", vi));
				return;
			}
			if(sys->fprint(vvideo, "target %d", Id+slot) < 0){
				bad(sprint("target %d: %r", Id+slot));
				return;
			}
			if(sys->write(vdata, sb, len sb) != len sb){
				bad(sprint("decode video sample %d: %r", vi));
				return;
			}
			bufpts[slot] = pts;
			buffull[slot] = 1;
			nheld++;
			vi++;
			continue;
		}

		if(ai < nasamp){
			sb := sample(mfd, at.samples[ai]);
			if(sb == nil){
				bad(sprint("read audio sample %d: %r", ai));
				return;
			}
			if(sys->write(adec, sb, len sb) != len sb){
				bad(sprint("decode audio sample %d: %r", ai));
				return;
			}
			for(;;){
				n := sys->read(adec, pcm, len pcm);
				if(n <= 0)
					break;
				# The write blocks when the device's buffer is
				# full, which is what paces this loop.
				if(aout != nil && sys->write(aout, pcm[0:n], n) != n){
					bad(sprint("write audio: %r"));
					return;
				}
				abytes += n;
			}
			ai++;
			na++;
			continue;
		}
	}

	print("  %d video frames, %d audio samples", nv, na);
	if(bps > 0)
		print(", worst video-audio gap %dms", worst);
	print("\n");
}
