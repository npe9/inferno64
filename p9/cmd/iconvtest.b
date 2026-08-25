implement Iconvtest;

# Regression test for p9/cmd/iconv.b, following this tree's *test.b
# convention. iconv's whole job is real image files, so this test
# drives it entirely with real files (writes a real input .bit image
# via Image.writepixels()+Display.writeimage(), calls iconv.dis's
# run(display, args, inpath, outpath) seam, reads the resulting output
# back via Display.open()/Image.readpixels()) - same "real files
# throughout" shape as join.b/split.b.
#
# This test does NOT re-verify Inferno's own pixel-channel conversion
# math (Image.draw()'s Porter-Duff compositing, chantostr/strtochan/
# chantodepth) - those are pre-existing, already-shipped Inferno
# functionality iconv.b wires together rather than reimplements (see
# iconv.b's header comment). What's checked here is that the wiring
# itself is correct: identity round-trips are checked byte-for-byte
# (a real golden value, not dependent on any conversion math since
# there's no conversion happening); an actual channel conversion is
# checked only for the shape it should produce (descriptor string,
# depth, rectangle) - not exact pixel values, which would just be
# re-testing Image.draw() itself.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	draw: Draw;
	Context, Display, Image, Chans, Point, Rect: import draw;

Iconvtest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Iconv: module
{
	PATH:	con "/p9/dis/iconv.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(display: ref Display, args: list of string, inpath: string, outpath: string): int;
};

stderr: ref FD;
iv: Iconv;
display: ref Display;
npass, nfail: int;
madefiles: list of string;

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	draw = load Draw Draw->PATH;

	iv = load Iconv Iconv->PATH;
	if(iv == nil){
		sys->fprint(stderr, "iconvtest: cannot load %s: %r\n", Iconv->PATH);
		raise "fail:bad module";
	}

	if(ctxt == nil)
		display = Display.allocate(nil);
	else
		display = ctxt.display;
	if(display == nil){
		sys->fprint(stderr, "iconvtest: cannot open a display\n");
		raise "fail:bad display";
	}

	# a small, fully hand-specified 2x2 GREY8 image - exact byte
	# values, not drawn from anything, so the identity checks below
	# have a real, controlled expected value.
	r := Rect(Point(0, 0), Point(2, 2));
	src := display.newimage(r, Draw->GREY8, 0, Draw->Nofill);
	if(src == nil){
		sys->fprint(stderr, "iconvtest: cannot allocate source image\n");
		raise "fail:bad display";
	}
	px := array[4] of byte;
	px[0] = byte 16r10;
	px[1] = byte 16r20;
	px[2] = byte 16r30;
	px[3] = byte 16r40;
	if(src.writepixels(r, px) != 4){
		sys->fprint(stderr, "iconvtest: writepixels failed\n");
		raise "fail:bad display";
	}
	inpath := "/iconvtest-in.bit";
	fd := sys->create(inpath, Sys->OWRITE, 8r666);
	if(fd == nil || display.writeimage(fd, src) < 0){
		sys->fprint(stderr, "iconvtest: cannot write test input image\n");
		raise "fail:bad display";
	}
	madefiles = inpath :: madefiles;

	checkidentity("identity conversion (no -c) round-trips pixel bytes exactly, compressed",
		inpath, nil, "/iconvtest-out1.bit", px);

	checkidentity("-c with the SAME descriptor as the source is still an identity round-trip",
		inpath, "-c" :: "k8" :: nil, "/iconvtest-out2.bit", px);

	checkuncompressed("-u writes the documented \"%11s %11d %11d %11d %11d \" header, then raw scanline bytes",
		inpath, "-u" :: nil, "/iconvtest-out3.raw", "k8", r, px);

	checkshape("-c with a different descriptor performs a real conversion (checked by shape, not exact pixels - see header comment)",
		inpath, "-c" :: "r8g8b8" :: nil, "/iconvtest-out4.bit", "r8g8b8", 24, r);

	checkfail("an unrecognised option is a usage error",
		inpath, "-z" :: nil, "/iconvtest-out5.bit");

	checkfail("a bad channel descriptor is a real error, not silently ignored",
		inpath, "-c" :: "not a channel" :: nil, "/iconvtest-out6.bit");

	sys->print("%d passed, %d failed\n", npass, nfail);
	for(fl := madefiles; fl != nil; fl = tl fl)
		sys->remove(hd fl);
	if(nfail > 0)
		raise "fail:test failure";
}

checkidentity(desc: string, inpath: string, args: list of string, outpath: string, want: array of byte)
{
	madefiles = outpath :: madefiles;
	{
		iv->run(display, args, inpath, outpath);
	} exception e {
	"fail:*" =>
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  unexpected failure: %s\n", desc, e);
		return;
	}
	m := display.open(outpath);
	if(m == nil){
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  could not reopen %s\n", desc, outpath);
		return;
	}
	got := array[len want] of byte;
	n := m.readpixels(m.r, got);
	if(n != len want || !byteseq(got, want)){
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want: %d bytes %s\n  got:  %d bytes\n",
			desc, len want, bytestr(want), n);
		return;
	}
	npass++;
}

checkuncompressed(desc: string, inpath: string, args: list of string, outpath: string,
	wantchan: string, wantr: Rect, wantpx: array of byte)
{
	madefiles = outpath :: madefiles;
	{
		iv->run(display, args, inpath, outpath);
	} exception e {
	"fail:*" =>
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  unexpected failure: %s\n", desc, e);
		return;
	}
	fd := sys->open(outpath, Sys->OREAD);
	if(fd == nil){
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  could not reopen %s\n", desc, outpath);
		return;
	}
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	wanthdr := sys->sprint("%11s %11d %11d %11d %11d ",
		wantchan, wantr.min.x, wantr.min.y, wantr.max.x, wantr.max.y);
	hdrbuf := array of byte wanthdr;
	if(n != len hdrbuf + len wantpx || !byteseq(buf[0:len hdrbuf], hdrbuf)){
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want header: %q\n  got %d bytes total\n",
			desc, wanthdr, n);
		return;
	}
	gotpx := buf[len hdrbuf : n];
	if(!byteseq(gotpx, wantpx)){
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  header ok, pixel bytes did not match\n", desc);
		return;
	}
	npass++;
}

checkshape(desc: string, inpath: string, args: list of string, outpath: string,
	wantchan: string, wantdepth: int, wantr: Rect)
{
	madefiles = outpath :: madefiles;
	{
		iv->run(display, args, inpath, outpath);
	} exception e {
	"fail:*" =>
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  unexpected failure: %s\n", desc, e);
		return;
	}
	m := display.open(outpath);
	if(m == nil){
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  could not reopen %s\n", desc, outpath);
		return;
	}
	gotchan := m.chans.text();
	if(gotchan != wantchan || m.depth != wantdepth ||
	   m.r.min.x != wantr.min.x || m.r.min.y != wantr.min.y ||
	   m.r.max.x != wantr.max.x || m.r.max.y != wantr.max.y){
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want chan=%s depth=%d\n  got  chan=%s depth=%d\n",
			desc, wantchan, wantdepth, gotchan, m.depth);
		return;
	}
	npass++;
}

checkfail(desc: string, inpath: string, args: list of string, outpath: string)
{
	{
		iv->run(display, args, inpath, outpath);
	} exception e {
	"fail:*" =>
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: a failure\n  got:  no failure\n", desc);
}

bytestr(b: array of byte): string
{
	s := "";
	for(i := 0; i < len b; i++)
		s += sys->sprint("%02x ", int b[i]);
	return s;
}

# `array of byte` compares by reference with ==/!=, not content - a
# manual element-wise check is needed (bit us once already in this file
# before this helper existed: both identity checks below "n==len want"
# yet still failed, because the array itself, not its bytes, was being
# compared).
byteseq(a: array of byte, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}
