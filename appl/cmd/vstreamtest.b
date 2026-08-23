implement Command;

#
# Tests the streaming decode path end to end: quicktime(2) locates the coded
# samples in Limbo, and draw(3)'s decoder turns them into frames.
#
# Nothing is staged and no path is handed to the host. Limbo reads the
# container - which may be on a mount from another machine - and writes the
# parameter sets and then each coded sample to the device. That split is the
# point: finding samples is a data-format job, decoding them needs hardware.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "string.m";
	str: String;
include "quicktime.m";
	qt: QuickTime;
	Track: import qt;
include "draw.m";
	draw: Draw;
	Chans: import draw;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Mov:	con "/lib/movies/test.mov";
Id:	con 1;

# Taken from the track rather than assumed, so this can be pointed at any
# clip. The colour checks only apply to the known fixture.
mov := Mov;
W, H: int;

fail := 0;

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

p32(b: array of byte, o: int, v: int)
{
	b[o]   = byte v;
	b[o+1] = byte (v>>8);
	b[o+2] = byte (v>>16);
	b[o+3] = byte (v>>24);
}

prect(b: array of byte, o, x0, y0, x1, y1: int)
{
	p32(b, o, x0); p32(b, o+4, y0); p32(b, o+8, x1); p32(b, o+12, y1);
}

allocimage(data: ref Sys->FD, id, cdesc: int): string
{
	m := array[1+4+4+1+4+1+16+16+4] of byte;
	m[0] = byte 'b';
	p32(m, 1, id);
	p32(m, 5, 0);
	m[9] = byte 0;
	p32(m, 10, cdesc);
	m[14] = byte 0;
	prect(m, 15, 0, 0, W, H);
	prect(m, 31, 0, 0, W, H);
	p32(m, 47, 0);
	if(sys->write(data, m, len m) != len m)
		return sprint("alloc image: %r");
	return nil;
}

readpixels(data: ref Sys->FD, id: int): (array of byte, string)
{
	m := array[1+4+16] of byte;
	m[0] = byte 'r';
	p32(m, 1, id);
	prect(m, 5, 0, 0, W, H);
	if(sys->write(data, m, len m) != len m)
		return (nil, sprint("read request: %r"));
	want := W*H*4;
	buf := array[want] of byte;
	off := 0;
	while(off < want){
		n := sys->read(data, buf[off:], want - off);
		if(n <= 0)
			return (nil, sprint("read pixels at %d: %r", off));
		off += n;
	}
	return (buf, nil);
}

hex(b: array of byte): string
{
	d := "0123456789abcdef";
	s := "";
	for(i := 0; i < len b; i++){
		# Parenthesised: + binds tighter than >>, so "x >> 4 + 1" is a
		# shift by five, which is how the first version indexed off the
		# end of the digit string.
		hi := (int b[i] >> 4) & 16rf;
		lo := int b[i] & 16rf;
		s += d[hi:hi+1] + d[lo:lo+1];
	}
	return s;
}

abs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	qt = load QuickTime QuickTime->PATH;
	draw = load Draw Draw->PATH;
	if(qt == nil || draw == nil || str == nil){
		print("vstreamtest: load: %r\n");
		raise "fail:load";
	}
	qt->init();

	if(tl argv != nil)
		mov = hd tl argv;

	# 1. Find the samples, in Limbo.
	(ts, err) := qt->tracks(mov);
	if(err != nil){
		print("vstreamtest: %s\n", err);
		raise "fail:parse";
	}
	t: ref Track;
	for(i := 0; i < len ts; i++)
		if(ts[i].kind == "vide")
			t = ts[i];
	if(t == nil || t.extra == nil || len t.samples == 0){
		print("vstreamtest: no usable video track\n");
		raise "fail:parse";
	}

	W = t.width;
	H = t.height;
	if(W <= 0 || H <= 0){
		print("vstreamtest: track has no size\n");
		raise "fail:parse";
	}

	mfd := sys->open(mov, Sys->OREAD);
	if(mfd == nil){
		print("vstreamtest: open %s: %r\n", mov);
		raise "fail:open";
	}

	# 2. Set up a draw client and an image to decode into.
	if(sys->bind("#i", "/dev", Sys->MBEFORE) < 0){
		print("vstreamtest: bind #i: %r\n");
		raise "fail:no draw";
	}
	ctl := sys->open("/dev/draw/new", Sys->ORDWR);
	if(ctl == nil){
		print("vstreamtest: no /dev/draw: %r\n");
		raise "fail:no draw";
	}
	cbuf := array[12*12] of byte;
	n := sys->read(ctl, cbuf, len cbuf);
	if(n < 12){
		print("vstreamtest: short ctl read\n");
		raise "fail:ctl";
	}
	(cid, nil) := str->toint(str->drop(string cbuf[0:n], " "), 10);
	data := sys->open(sprint("/dev/draw/%d/data", cid), Sys->ORDWR);
	video := sys->open(sprint("/dev/draw/%d/video", cid), Sys->OWRITE);
	vdata := sys->open(sprint("/dev/draw/%d/videodata", cid), Sys->OWRITE);
	if(data == nil || video == nil || vdata == nil){
		print("vstreamtest: open client %d: %r\n", cid);
		raise "fail:open";
	}
	cd := Chans.mk("x8r8g8b8");
	if((e := allocimage(data, Id, cd.desc)) != nil){
		bad(e);
		raise "fail:test";
	}

	# 3. Configure the decoder from the container's parameter sets, and
	#    say where frames go.
	cfg := array of byte sprint("decoder %s %s", t.codec, hex(t.extra));
	if(sys->write(video, cfg, len cfg) != len cfg){
		bad(sprint("decoder: %r"));
		raise "fail:test";
	}
	tg := array of byte sprint("target %d", Id);
	if(sys->write(video, tg, len tg) != len tg){
		bad(sprint("target: %r"));
		raise "fail:test";
	}

	# 4. Feed the coded samples, one write each, checking the picture.
	t0 := sys->millisec();
	ndec := 0;
	dts := 0;
	seen := array[len t.samples] of { * => 0 };
	for(f := 0; f < len t.samples; f++){
		s := t.samples[f];
		if(sys->seek(mfd, s.off, Sys->SEEKSTART) != s.off){
			bad(sprint("seek to sample %d: %r", f));
			break;
		}
		sb := array[s.size] of byte;
		if(sys->readn(mfd, sb, s.size) != s.size){
			bad(sprint("read sample %d: %r", f));
			break;
		}
		if(sys->write(vdata, sb, s.size) != s.size){
			bad(sprint("decode sample %d: %r", f));
			break;
		}
		# Only the known fixture is checked pixel by pixel. Reading a
		# 1080p image back through the draw protocol costs as much as
		# decoding it, so on any other clip that would be measuring the
		# test rather than the decoder.
		px: array of byte;
		if(mov == Mov){
			e2: string;
			(px, e2) = readpixels(data, Id);
			if(e2 != nil){
				bad(e2);
				break;
			}
		}
		# Samples are in DECODE order; the picture a sample produces is
		# the one at its presentation time. This stream has B-frames -
		# its ctts offsets are non-zero - so the two differ, and
		# expecting sample f to be frame f is simply wrong. The display
		# index is the presentation time divided by the frame duration.
		disp := 0;
		if(s.delta > 0)
			disp = (dts + s.coff) / s.delta;
		dts += s.delta;

		b := 0;
		r := 0;
		if(px != nil){
			o := ((H/2)*W + W/2) * 4;
			b = int px[o];
			r = int px[o+2];
		}
		wr := 20 + disp*20;
		wb := 220 - disp*20;
		if(mov == Mov && (abs(r-wr) > 12 || abs(b-wb) > 12)){
			bad(sprint("sample %d (display %d): got rgb(%d,-,%d) want about rgb(%d,-,%d)",
				f, disp, r, b, wr, wb));
			break;
		}
		seen[disp] = 1;
		ndec++;
	}
	ms := sys->millisec() - t0;

	cl := array of byte "close";
	sys->write(video, cl, len cl);

	if(ndec != len t.samples)
		bad(sprint("decoded %d of %d samples", ndec, len t.samples));
	# Every display position exactly once: catches a decoder that returns
	# the same picture twice, which reordering makes easy to miss.
	if(mov == Mov)
		for(k := 0; k < len seen; k++)
			if(seen[k] == 0)
				bad(sprint("no sample produced display frame %d", k));
	if(fail)
		raise "fail:test";
	if(mov == Mov)
		print("  %d samples parsed in Limbo, decoded in %dms, every frame the expected colour\n",
			ndec, ms);
	else
		print("  %s: %dx%d, %d frames decoded in %dms (%d us/frame)\n",
			mov, W, H, ndec, ms, ms*1000/ndec);
	print("PASS\n");
}
