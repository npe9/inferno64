implement Command;

# Checks the icons/temple sprite corpus against the two things that have
# gone wrong with it, on the files and in the code that reads them.
#
# A Plan 9 image row is laid out from a byte boundary, not from the
# rectangle's left edge: an image whose r.min.x is not a multiple of
# 8/depth carries an extra unit per row and starts its first pixel part
# way into the first one.  Both halves of that have been got wrong here
# before.  The sprite extractors wrote (width+7)/8 bytes with the first
# pixel at bit 0, so 85 of the 230 .mask files were too short to open at
# all and 146 were misaligned by up to seven pixels; the files were
# repacked.  Then draw3d's own resample loop computed the same wrong
# length for the buffer it read a mask into, so readpixels failed and
# transformsprite returned without drawing - 84 of the 229 masks, blank
# whenever the sprite was rotated or z-tested.
#
# So there are three checks, in the order the data flows:
#
#	open	every .bit and .mask opens at all
#	draw	a 1:1 masked draw changes exactly the pixels the mask
#		marks, and nothing else
#	loop	draw3d's pixel-by-pixel resample - the path that reads
#		the mask's bytes itself - agrees with that masked draw
#		exactly, which is the check the misalignment fails
#
# and a negative control that needs no edit to run: for every sprite the
# test also asks readpixels for the mask with the OLD, naive row length.
# If that never fails, the corpus no longer contains the shape that broke
# and "loop" is no longer testing anything - so the test says so and
# fails.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;
include "math.m";
	math: Math;
include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

DIR: con "/icons/temple";

d: ref Display;
verbose := 0;
nopen, nopenfail, ndraw, ndrawfail, nloop, nloopfail, nnaive: int;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	draw3d = load Draw3d Draw3d->PATH;
	if(draw3d == nil){
		sys->fprint(sys->fildes(2), "masktest: cannot load draw3d: %r\n");
		raise "fail:load";
	}
	draw3d->init();
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;
	d = Display.allocate(nil);
	if(d == nil){
		sys->fprint(sys->fildes(2), "masktest: no display: %r\n");
		raise "fail:display";
	}
	fd := sys->open(DIR, Sys->OREAD);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "masktest: cannot open %s: %r\n", DIR);
		raise "fail:dir";
	}
	for(;;){
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			nm := dirs[i].name;
			l := len nm;
			if(l > 4 && nm[l-4:] == ".bit")
				one(nm[0:l-4]);
		}
	}
	sys->print("masktest: open %d/%d, draw %d/%d, loop %d/%d\n",
		nopen-nopenfail, nopen, ndraw-ndrawfail, ndraw,
		nloop-nloopfail, nloop);
	bad := nopenfail + ndrawfail + nloopfail;
	if(nnaive == 0){
		sys->print("masktest: FAIL: no mask in %s still needs a row longer than (width+7)/8, so the loop check no longer covers the bug it was written for\n", DIR);
		bad++;
	}else
		sys->print("masktest: control: %d masks would be unreadable at the old row length\n", nnaive);
	if(bad != 0){
		sys->print("masktest: FAILED (%d)\n", bad);
		raise "fail:masktest";
	}
	sys->print("masktest: PASSED\n");
}

one(base: string)
{
	nopen++;
	img := d.open(DIR + "/" + base + ".bit");
	msk := d.open(DIR + "/" + base + ".mask");
	if(img == nil){
		sys->print("%s: .bit will not open: %r\n", base);
		nopenfail++;
		return;
	}
	if(msk == nil){
		sys->print("%s: .mask will not open: %r\n", base);
		nopenfail++;
		return;
	}
	if(!img.r.eq(msk.r)){
		sys->print("%s: .bit is %s but .mask is %s\n", base,
			rstr(img.r), rstr(msk.r));
		nopenfail++;
		return;
	}
	w := img.r.dx();
	h := img.r.dy();

	# The old row length, kept only as the control: this is what the
	# reader used to allocate, and readpixels rejects it as too small
	# for any mask whose rectangle is not byte-aligned.
	if(msk.readpixels(msk.r, array[((w * msk.depth + 7) / 8) * h] of byte) < 0)
		nnaive++;

	# draw: the pixels a masked draw changes, against the pixels the
	# mask marks.  Neither side is computed by this program - the
	# coverage comes back from painting white through the mask - so a
	# row-length mistake here cannot cancel one in the thing tested.
	ndraw++;
	ground := d.rgb(255, 0, 255);	# not in the 16-colour palette
	dst := d.newimage(Rect((0,0),(w,h)), Draw->RGB24, 0, Draw->Black);
	cov := d.newimage(Rect((0,0),(w,h)), Draw->RGB24, 0, Draw->Black);
	if(dst == nil || cov == nil){
		sys->print("%s: no scratch image: %r\n", base);
		ndrawfail++;
		return;
	}
	dst.draw(dst.r, ground, nil, Point(0,0));
	dst.draw(dst.r, img, msk, img.r.min);
	cov.draw(cov.r, d.rgb(255,255,255), msk, msk.r.min);
	pd := array[w*h*3] of byte;
	pc := array[w*h*3] of byte;
	if(dst.readpixels(dst.r, pd) < 0 || cov.readpixels(cov.r, pc) < 0){
		sys->print("%s: readpixels: %r\n", base);
		ndrawfail++;
		return;
	}
	extra := 0; missing := 0;
	for(i := 0; i < w*h; i++){
		# RGB24 reads back b, g, r
		changed := !(int pd[i*3] == 255 && int pd[i*3+1] == 0
			&& int pd[i*3+2] == 255);
		set := pc[i*3] != byte 0;
		if(changed && !set)
			extra++;
		else if(!changed && set)
			missing++;
	}
	if(extra != 0 || missing != 0){
		sys->print("%s: %dx%d at %s: %d painted outside the mask, %d marked but not painted\n", base, w, h, rstr(img.r), extra, missing);
		ndrawfail++;
		return;
	}

	# loop: the same sprite through draw3d's general resample, which
	# reads the mask's bytes itself.  A full turn is an identity
	# rotation but is not literally zero, so it misses the native-blit
	# shortcut and takes that loop.
	nloop++;
	gen := d.newimage(Rect((0,0),(w,h)), Draw->RGB24, 0, Draw->Black);
	if(gen == nil){
		sys->print("%s: no scratch image: %r\n", base);
		nloopfail++;
		return;
	}
	draw3d->sprite2d(gen, Point(w/2, h/2), img, msk, w, h, 360.0, 0);
	# The oracle is the same masked draw as above, on black.
	ref2 := d.newimage(Rect((0,0),(w,h)), Draw->RGB24, 0, Draw->Black);
	ref2.draw(ref2.r, img, msk, img.r.min);
	pg := array[w*h*3] of byte;
	pr := array[w*h*3] of byte;
	if(gen.readpixels(gen.r, pg) < 0 || ref2.readpixels(ref2.r, pr) < 0){
		sys->print("%s: readpixels: %r\n", base);
		nloopfail++;
		return;
	}
	diff := 0; nlit := 0;
	for(i = 0; i < w*h; i++){
		if(pr[i*3] != byte 0 || pr[i*3+1] != byte 0 || pr[i*3+2] != byte 0)
			nlit++;
		if(pg[i*3] != pr[i*3] || pg[i*3+1] != pr[i*3+1]
		|| pg[i*3+2] != pr[i*3+2])
			diff++;
	}
	if(diff != 0){
		sys->print("%s: %dx%d at %s: resample differs from masked draw in %d of %d pixels (%d lit)\n", base, w, h, rstr(img.r), diff, w*h, nlit);
		nloopfail++;
		return;
	}
	if(verbose)
		sys->print("%s: %dx%d at %s ok, %d lit\n", base, w, h,
			rstr(img.r), nlit);
}

rstr(r: Rect): string
{
	return sys->sprint("(%d,%d)-(%d,%d)", r.min.x, r.min.y, r.max.x, r.max.y);
}
