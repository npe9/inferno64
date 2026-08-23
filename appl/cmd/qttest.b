implement Command;

#
# Tests quicktime(2)'s sample tables against a movie whose contents are known
# exactly: lib/movies/test.mov, built by emu/MacOSX/mkmovie.m as ten 64x64
# H.264 frames.
#
# The point of checking against a known fixture rather than any movie is that
# the counts and dimensions can be asserted. A parser that returns plausible
# rubbish - one track, some samples - would pass a smoke test and fail this.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "quicktime.m";
	qt: QuickTime;
	Track, Sample: import qt;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Mov:	con "/lib/movies/test.mov";
Nframe:	con 10;
W:	con 64;
H:	con 64;

fail := 0;

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

# Holds for any track in any file: samples inside the file, non-empty, with a
# positive duration, and something to start decoding from.
checktrack(t: ref Track, mov: string)
{
	(ok, d) := sys->stat(mov);
	if(ok < 0){
		bad(sprint("stat: %r"));
		return;
	}
	if(t.timescale <= 0)
		bad(sprint("track %d: timescale %d", t.id, t.timescale));
	nsync := 0;
	for(i := 0; i < len t.samples; i++){
		s := t.samples[i];
		if(s.size <= 0)
			bad(sprint("track %d sample %d is empty", t.id, i));
		if(s.off < big 0 || s.off + big s.size > d.length)
			bad(sprint("track %d sample %d at %bd+%d lies outside a %bd-byte file",
				t.id, i, s.off, s.size, d.length));
		if(s.delta <= 0)
			bad(sprint("track %d sample %d has duration %d", t.id, i, s.delta));
		if(s.sync)
			nsync++;
	}
	if(len t.samples > 0 && nsync == 0)
		bad(sprint("track %d has no sync samples", t.id));
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	qt = load QuickTime QuickTime->PATH;
	if(qt == nil){
		print("qttest: load QuickTime: %r\n");
		raise "fail:load";
	}
	qt->init();

	mov := Mov;
	if(tl argv != nil)
		mov = hd tl argv;

	(ts, err) := qt->tracks(mov);
	if(err != nil){
		print("qttest: %s\n", err);
		raise "fail:parse";
	}
	if(mov == Mov && len ts != 1){
		bad(sprint("%d tracks, expected 1", len ts));
		raise "fail:test";
	}

	# Whatever the file, every track must be self-consistent. The video
	# track is then checked in detail below.
	for(j := 0; j < len ts; j++)
		checktrack(ts[j], mov);

	t: ref Track;
	for(j = 0; j < len ts; j++)
		if(ts[j].kind == "vide")
			t = ts[j];
	if(t == nil){
		bad("no video track");
		raise "fail:test";
	}
	if(t.kind != "vide")
		bad(sprint("track kind %#q, expected \"vide\"", t.kind));
	if(t.codec != "avc1")
		bad(sprint("codec %#q, expected \"avc1\"", t.codec));
	if(mov == Mov && (t.width != W || t.height != H))
		bad(sprint("%dx%d, expected %dx%d", t.width, t.height, W, H));
	if(t.timescale <= 0)
		bad(sprint("timescale %d", t.timescale));

	# avcC carries the SPS and PPS a hardware decoder must be configured
	# with. Without it the samples are useless, so its absence is a
	# failure and not a detail.
	if(t.extra == nil || len t.extra < 7)
		bad("no avcC setup data: a decoder could not be configured");
	else if(int t.extra[0] != 1)
		bad(sprint("avcC configurationVersion %d, expected 1", int t.extra[0]));

	if(mov == Mov && len t.samples != Nframe)
		bad(sprint("%d samples, expected %d", len t.samples, Nframe));

	# Every sample must lie inside the file and be non-empty, and the
	# first must be a sync sample or nothing can start decoding.
	(ok, d) := sys->stat(mov);
	if(ok < 0){
		bad(sprint("stat: %r"));
		raise "fail:test";
	}
	nsync := 0;
	total := big 0;
	for(i := 0; i < len t.samples; i++){
		s := t.samples[i];
		if(s.size <= 0)
			bad(sprint("sample %d is empty", i));
		if(s.off < big 0 || s.off + big s.size > d.length)
			bad(sprint("sample %d at %bd+%d lies outside a %bd-byte file",
				i, s.off, s.size, d.length));
		if(s.delta <= 0)
			bad(sprint("sample %d has duration %d", i, s.delta));
		if(s.sync)
			nsync++;
		total += big s.size;
	}
	if(len t.samples > 0 && !t.samples[0].sync)
		bad("first sample is not a sync sample: decoding could not start");
	if(nsync == 0)
		bad("no sync samples at all");

	if(fail)
		raise "fail:test";

	for(j = 0; j < len ts; j++)
		print("  track %d: %s/%s timescale %d, %d samples, %d bytes of setup\n",
			ts[j].id, ts[j].kind, ts[j].codec, ts[j].timescale,
			len ts[j].samples, len ts[j].extra);

	print("  %s: %s/%s %dx%d, timescale %d, %d bytes of setup data\n",
		mov, t.kind, t.codec, t.width, t.height, t.timescale, len t.extra);
	print("  %d samples, %bd bytes total, %d sync\n",
		len t.samples, total, nsync);
	print("PASS\n");
}
