implement Aadrawtest;

# Antialiased drawing: a solid colour painted through an 8-bit coverage
# mask.  This is what text through a scalable font is, and libmemdraw's
# optimized text blit, chardraw, used to refuse any mask deeper than one
# bit, so it went through the general per-pixel path instead.
#
# Two things are checked.  Correctness, against the blend arithmetic
# computed here in Limbo rather than against the C's own idea of it: every
# destination byte must be MUL(a, src) + MUL(255-a, dst), for the same
# rounding libmemdraw uses.  And cost, printed rather than asserted, so a
# change to the fast path shows up as a number.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Chans, Display, Font, Image, Point, Rect: import draw;

# ttffs(4) wants a draw context, but only for its display, so this test
# can serve /fonts/ttf itself and time the antialiased path.
Ttffs: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Aadrawtest: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

ok := 0;
fail := 0;

report(good: int, what: string)
{
	if(good){
		ok++;
		sys->print("OK   %s\n", what);
	}else{
		fail++;
		sys->print("FAIL %s\n", what);
	}
}

# libmemdraw's MUL: (t = x*y+128, (t+(t>>8))>>8), the usual /255
mul(x, y: int): int
{
	t := x*y + 128;
	return (t + (t>>8)) >> 8;
}

W: con 256;			# one column per coverage value
H: con 8;

# Paint sc through a ramp mask over dc, and check every byte.
check(d: ref Display, ch: Chans, nb: int, chname: string,
	sc, dc: int): int
{
	dst := d.newimage(Rect((0,0),(W,H)), ch, 0, dc);
	src := d.newimage(Rect((0,0),(1,1)), ch, 1, sc);
	mask := d.newimage(Rect((0,0),(W,H)), Draw->GREY8, 0, Draw->Black);
	if(dst == nil || src == nil || mask == nil){
		sys->print("     %s: no image: %r\n", chname);
		return 0;
	}
	# coverage 0..255 left to right, so every value is exercised
	mb := array[W*H] of byte;
	for(y := 0; y < H; y++)
		for(x := 0; x < W; x++)
			mb[y*W + x] = byte x;
	mask.writepixels(mask.r, mb);

	# what the destination held before, byte by byte, so the oracle
	# blends against the real thing rather than against what we asked for
	before := array[W*H*nb] of byte;
	dst.readpixels(dst.r, before);

	dst.draw(dst.r, src, mask, mask.r.min);

	after := array[W*H*nb] of byte;
	dst.readpixels(dst.r, after);

	# and the source as it landed in the destination's own format
	sref := d.newimage(Rect((0,0),(1,1)), ch, 0, sc);
	sb := array[nb] of byte;
	sref.readpixels(sref.r, sb);

	bad := 0;
	firstx := -1;
	for(y = 0; y < H; y++)
		for(x = 0; x < W; x++){
			a := x;
			fd := 255 - a;
			for(i := 0; i < nb; i++){
				o := (y*W + x)*nb + i;
				want := mul(a, int sb[i]) + mul(fd, int before[o]);
				got := int after[o];
				# a byte the format does not use is not a
				# channel and must be left exactly as it was
				if(want != got && got != int before[o]){
					if(bad == 0){
						firstx = x;
						sys->print("     %s at x %d byte %d: want %d got %d (was %d, src %d, a %d)\n",
							chname, x, i, want, got,
							int before[o], int sb[i], a);
					}
					bad++;
				}
			}
		}
	report(bad == 0, sys->sprint("%s blends every coverage value (%d bytes wrong%s)",
		chname, bad, badat(firstx)));
	return bad == 0;
}

badat(x: int): string
{
	if(x < 0)
		return "";
	return sys->sprint(", first at x %d", x);
}

# Is the fast path actually being taken?  Time it.  The number alone
# cannot say, because it depends on the machine, so what is returned is
# compared against a format the fast path refuses by design.
timeit(d: ref Display, ch: Chans, chname: string): int
{
	SZ: con 512;
	dst := d.newimage(Rect((0,0),(SZ,SZ)), ch, 0, Draw->White);
	src := d.newimage(Rect((0,0),(1,1)), ch, 1, Draw->Red);
	mask := d.newimage(Rect((0,0),(SZ,SZ)), Draw->GREY8, 0, Draw->Black);
	mb := array[SZ*SZ] of byte;
	for(i := 0; i < SZ*SZ; i++)
		mb[i] = byte (i & 255);		# every coverage, no shortcuts
	mask.writepixels(mask.r, mb);
	# draw operations queue to /dev/draw, so timing the calls alone
	# measures how fast we can enqueue.  Flush inside the timed region.
	REPS: con 40;
	one := array[4] of byte;
	t0 := sys->millisec();
	for(r := 0; r < REPS; r++){
		dst.draw(dst.r, src, mask, mask.r.min);
		dst.flush(Draw->Flushnow);
	}
	dst.readpixels(Rect((0,0),(1,1)), one);
	ms := sys->millisec() - t0;
	sys->print("     %-7s %d x %dx%d masked blits in %3d ms = %4d us each, %d ns a pixel\n",
		chname, REPS, SZ, SZ, ms, (ms*1000)/REPS,
		(ms*1000000)/(REPS*SZ*SZ));
	return (ms*1000)/REPS;
}

# and the case that matters: text
timetext(d: ref Display, path: string)
{
	f := Font.open(d, path);
	if(f == nil){
		sys->print("     %s: not available\n", path);
		return;
	}
	im := d.newimage(Rect((0,0),(600,64)), Draw->RGB24, 0, Draw->White);
	black := d.color(Draw->Black);
	s := "Handgloves 123";
	im.text(im.r.min, black, Point(0,0), f, s);	# warm the glyph cache
	im.flush(Draw->Flushnow);
	REPS: con 2000;
	one := array[4] of byte;
	t0 := sys->millisec();
	for(r := 0; r < REPS; r++){
		im.text(im.r.min, black, Point(0,0), f, s);
		im.flush(Draw->Flushnow);
	}
	im.readpixels(Rect(im.r.min, im.r.min.add((1,1))), one);
	ms := sys->millisec() - t0;
	sys->print("     %-38s height %2d, %3d px: %d us a string\n",
		path, f.height, f.width(s), (ms*1000)/REPS);
}

# serve whatever is in /fonts/ttf, if anything
startttf(d: ref Display)
{
	if(sys->open("/mnt/ft/index", Sys->OREAD) != nil)
		return;
	if((fd := sys->open("/fonts/ttf", Sys->OREAD)) == nil)
		return;
	(n, nil) := sys->dirread(fd);
	if(n <= 0)
		return;
	tf := load Ttffs "/dis/ttffs.dis";
	if(tf == nil)
		return;
	sys->create("/mnt", Sys->OREAD, Sys->DMDIR|8r777);
	sys->create("/mnt/ft", Sys->OREAD, Sys->DMDIR|8r777);
	spawn tf->init(ref Draw->Context(d, nil, nil), "ttffs" :: nil);
	for(i := 0; i < 40; i++){
		if(sys->open("/mnt/ft/index", Sys->OREAD) != nil)
			return;
		sys->sleep(100);
	}
}

# the first face being served, if any
ttfname(): string
{
	fd := sys->open("/mnt/ft/index", Sys->OREAD);
	if(fd == nil)
		return "";
	b := array[8192] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "";
	s := string b[0:n];
	for(i := 0; i < len s; i++)
		if(s[i] == ' ' || s[i] == '\n')
			return s[0:i];
	return "";
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	d := Display.allocate(nil);
	if(d == nil){
		sys->print("FAIL no display: %r\n");
		raise "fail:no display";
	}
	startttf(d);
	# a destination colour that is not grey, so a channel swap shows
	dc := int 16r2040A0FF;
	sc := int 16rC08020FF;
	check(d, Draw->RGB24, 3, "RGB24", sc, dc);
	check(d, Draw->XRGB32, 4, "XRGB32", sc, dc);
	check(d, Draw->GREY8, 1, "GREY8", sc, dc);
	# RGB24 takes the coverage fast path; RGBA32 has an alpha channel,
	# which that path refuses, so it goes through the general one.  The
	# ratio between them is what says the fast path is still wired in -
	# a bare microsecond count would pass on any machine, fast path or
	# not, which is how a regression here would go unnoticed.
	fast := timeit(d, Draw->RGB24, "RGB24");
	timeit(d, Draw->XRGB32, "XRGB32");
	slow := timeit(d, Draw->RGBA32, "RGBA32");
	report(fast*3 < slow*2, sys->sprint(
		"the coverage fast path is taken (RGB24 %d us against RGBA32's %d, wanted a third off)",
		fast, slow));
	for(argv = tl argv; argv != nil; argv = tl argv)
		timetext(d, hd argv);
	if((tn := ttfname()) != "")
		for(sz := 16; sz <= 32; sz += 16)
			timetext(d, sys->sprint("/mnt/ft/%s.r.%d.font", tn, sz));
	sys->print("aadrawtest: %d ok, %d fail\n", ok, fail);
	if(fail > 0)
		raise "fail:aadrawtest";
}
