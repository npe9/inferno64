implement Draw3dbench;

# Measures the two math/draw3d providers against each other on the same
# scene: the software rasteriser (/dis/math/draw3d.dis) and the /dev/draw
# protocol provider (/dis/math/draw3ddev.dis), which on a Metal host does
# the transform and the fill on the GPU.
#
# Two axes matter and neither is obvious from reading the code:
#
#   * destination.  emu/MacOSX/win-cocoa.m's metal_queue_fillpoly3d()
#     returns 0 unless dst is the screen image or a fully-clear layer of
#     it, so a port that composes its frame into an offscreen buffer and
#     blits gets no GPU at all - and pays the wire cost on top of the
#     software one.  Both destinations are timed here so the difference
#     is a number rather than an argument.
#
#   * triangle size.  Per-triangle overhead and per-pixel cost pull in
#     opposite directions, so a scene of many small triangles and one of
#     few large ones are separate measurements.
#
# lit= counts pixels that are not black: timing alone cannot tell a fast
# renderer from one that silently drew nothing.  worst= is the slowest
# single frame, which is what distinguishes a uniformly slower renderer
# from one stall - see BUGS in draw3dbench(1) for why that matters here.

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
	Vector: import draw3d;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "arg.m";

Draw3dbench: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
nframe := 120;	# 60 lands on the stall in draw3dbench(1)'s BUGS
paced := 0;
verbose := 0;

usage()
{
	sys->fprint(sys->fildes(2), "usage: draw3dbench [-p] [-n frames]\n");
	raise "fail:usage";
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	arg := load Arg Arg->PATH;

	arg->init(argv);
	arg->setusage("draw3dbench [-p] [-n frames]");
	while((o := arg->opt()) != 0)
		case o {
		'p' =>	paced = 1;
		'n' =>	nframe = int arg->earg();
		'v' =>	verbose = 1;
		* =>	arg->usage();
		}
	if(nframe < 1)
		usage();

	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "draw3dbench", Wmclient->Appl);
	win.reshape(Rect((0,0),(640,480)));
	win.onscreen(nil);
	d := win.display;

	col := d.color(Draw->Red);
	buf := d.newimage(Rect((0,0),(640,480)), win.image.chans, 0, Draw->Black);

	small := scene(512, 1.0);
	large := scene(64, 6.0);

	sys->print("draw3dbench: 512 small triangles\n");
	bench("  software window", Draw3d->PATH, win.image, col, small);
	bench("  software buffer", Draw3d->PATH, buf, col, small);
	bench("  protocol window", "/dis/math/draw3ddev.dis", win.image, col, small);
	bench("  protocol buffer", "/dis/math/draw3ddev.dis", buf, col, small);
	sys->print("draw3dbench: 64 large triangles\n");
	bench("  software window", Draw3d->PATH, win.image, col, large);
	bench("  software buffer", Draw3d->PATH, buf, col, large);
	bench("  protocol window", "/dis/math/draw3ddev.dis", win.image, col, large);
	bench("  protocol buffer", "/dis/math/draw3ddev.dis", buf, col, large);
	sprites(d, buf);
	readback(d, col, large);
}

# sprite2d is the other half of what appl/temple asks draw3d for, and
# eight ports use it and nothing else.  It is worth measuring separately
# because it is the same Limbo pixel loop in BOTH providers - neither
# sends a message - so the provider column here is a control that should
# come out flat, and the interesting comparison is against the native
# Image.draw that a rotation of zero degrees reduces to.
sprites(d: ref Display, dst: ref Image)
{
	sys->print("draw3dbench: sprite2d\n");
	spr(d, dst, 16, 0.0);
	spr(d, dst, 64, 0.0);
	spr(d, dst, 220, 0.0);
	spr(d, dst, 220, 30.0);
}

spr(d: ref Display, dst: ref Image, size: int, degz: real)
{
	img := d.newimage(Rect((0,0),(size,size)), dst.chans, 0, Draw->Red);
	mask := d.newimage(Rect((0,0),(size,size)), Draw->GREY1, 0, int 16rFFFFFFFF);
	if(img == nil || mask == nil)
		return;
	n := 200;
	for(pass := 0; pass < 2; pass++){
		path := Draw3d->PATH;
		what := "software";
		if(pass == 1){
			path = "/dis/math/draw3ddev.dis";
			what = "protocol";
		}
		d3 := load Draw3d path;
		if(d3 == nil)
			continue;
		d3->init();
		t0 := sys->millisec();
		for(i := 0; i < n; i++)
			d3->sprite2d(dst, Point(320, 240), img, mask,
				size, size, degz, 0);
		t1 := sys->millisec();
		sys->print("draw3dbench:   %s %dx%d at %g deg: %d us/sprite\n",
			what, size, size, degz, ((t1-t0)*1000)/n);
	}
	# The floor: what the same placement costs as a native blit, which
	# is what a zero rotation with no scaling actually reduces to.
	t0 := sys->millisec();
	for(i := 0; i < n; i++)
		dst.draw(Rect((320-size/2,240-size/2),(320+size/2,240+size/2)),
			img, mask, img.r.min);
	t1 := sys->millisec();
	sys->print("draw3dbench:   native %dx%d blit: %d us/sprite\n",
		size, size, ((t1-t0)*1000)/n);
}

# A deterministic scene: n triangles of the given world-space radius,
# scattered on a shell in front of the eye.  Deterministic so two
# providers get bit-identical geometry.
scene(n: int, size: real): array of array of Vector
{
	tri := array[n] of array of Vector;
	seed := 12345;
	for(i := 0; i < n; i++){
		v := array[3] of Vector;
		seed = (seed*1103515245 + 12345) & 16r7fffffff;
		a := real (seed % 3600) / 3600.0 * 6.283185;
		seed = (seed*1103515245 + 12345) & 16r7fffffff;
		b := real (seed % 3600) / 3600.0 * 3.14159;
		cx := 3.0*math->cos(a)*math->sin(b);
		cy := 3.0*math->sin(a)*math->sin(b);
		cz := 3.0*math->cos(b) - 9.0;
		for(j := 0; j < 3; j++){
			t := 2.094395 * real j;
			v[j] = Vector(cx + size*math->cos(t), cy + size*math->sin(t),
				cz + size*0.1*real j);
		}
		tri[i] = v;
	}
	return tri;
}

bench(what: string, path: string, dst: ref Image, col: ref Image,
	tri: array of array of Vector)
{
	d3 := load Draw3d path;
	if(d3 == nil){
		sys->print("draw3dbench: %s: load %s: %r\n", what, path);
		return;
	}
	d3->init();
	c := d3->context(dst);
	d3->setzarea(c, dst.r);
	d3->setz(c, 1);
	d3->setcolour(c, col);
	d3->viewport(c, dst.r.min.x, dst.r.min.y, dst.r.max.x, dst.r.max.y);
	normal := Vector(0.0, 0.0, 1.0);
	worst := 0;
	worstf := -1;
	t0 := sys->millisec();
	for(f := 0; f < nframe; f++){
		fs := sys->millisec();
		d3->mode(Draw3d->PROJ);
		d3->identity();
		d3->frustum(0.1, 0.1, 100.0);
		d3->mode(Draw3d->MODEL);
		d3->identity();
		d3->rotatey(real f * 6.0);
		d3->clearz(c);
		dst.draw(dst.r, dst.display.black, nil, dst.r.min);
		for(i := 0; i < len tri; i++)
			d3->fillpoly3(c, tri[i], normal, 0.5 + real (i%8)/16.0);
		dst.flush(Draw->Flushnow);
		fe := sys->millisec();
		if(fe - fs > worst){
			worst = fe - fs;
			worstf = f;
		}
		if(paced)
			sys->sleep(16);
	}
	t1 := sys->millisec();
	sys->print("draw3dbench: %s %d frames of %d tris: %d ms (%d us/frame) worst=%d ms at frame %d lit=%d\n",
		what, nframe, len tri, t1-t0, ((t1-t0)*1000)/nframe, worst, worstf, litpixels(dst));
}

# Where the pixels a pass produced can actually be read back from, for
# both providers.  The software provider is the control: if it reports
# the same count through the window layer and through the screen image,
# then a difference in the protocol column is about GPU output and not
# about layers.
readback(d: ref Display, col: ref Image, tri: array of array of Vector)
{
	rb("software", Draw3d->PATH, d, col, tri);
	rb("protocol", "/dis/math/draw3ddev.dis", d, col, tri);
}

rb(what: string, path: string, d: ref Display, col: ref Image,
	tri: array of array of Vector)
{
	d3 := load Draw3d path;
	if(d3 == nil)
		return;
	d3->init();
	c := d3->context(win.image);
	d3->setzarea(c, win.image.r);
	d3->setz(c, 1);
	d3->setcolour(c, col);
	d3->viewport(c, win.image.r.min.x, win.image.r.min.y,
		win.image.r.max.x, win.image.r.max.y);
	win.image.draw(win.image.r, d.black, nil, win.image.r.min);
	d3->mode(Draw3d->PROJ);
	d3->identity();
	d3->frustum(0.1, 0.1, 100.0);
	d3->mode(Draw3d->MODEL);
	d3->identity();
	d3->clearz(c);
	for(i := 0; i < len tri; i++)
		d3->fillpoly3(c, tri[i], Vector(0.0, 0.0, 1.0), 0.8);
	# Two ways of looking, because they exercise different code.  A
	# draw() into a scratch image copies bytes and never gives the
	# device a chance to bring GPU output back; a readpixels() straight
	# off the target goes through devdraw's read message, which calls
	# gpudrawreadback() first.  If the GPU path is working, only the
	# second can see it - which is itself worth knowing, because a port
	# that composites its window into a buffer is doing the first.
	sys->print("draw3dbench: %s readback: layer draw=%d read=%d, screen draw=%d read=%d\n",
		what, litpixels(win.image), litdirect(win.image),
		litpixels(d.image), litdirect(d.image));
}

# Bytes that are not zero, read straight off the image.  Coarser than
# litpixels - it counts bytes, and what a zero byte means depends on the
# channel layout - but it is the only one of the two that can observe a
# GPU readback, because nothing is copied before the read.
litdirect(dst: ref Image): int
{
	r := dst.r;
	bpl := (r.dx() * dst.depth + 7) / 8;
	buf := array[bpl] of byte;
	n := 0;
	for(y := r.min.y; y < r.max.y; y++){
		if(dst.readpixels(Rect((r.min.x, y), (r.max.x, y+1)), buf) != bpl)
			return -1;
		for(i := 0; i < bpl; i++)
			if(buf[i] != byte 0)
				n++;
	}
	return n;
}

# Pixels that are not black, counted through an RGB24 scratch so the
# count means the same thing whatever the destination's channels are.
litpixels(dst: ref Image): int
{
	r := dst.r;
	w := r.dx();
	h := r.dy();
	scr := dst.display.newimage(Rect((0,0),(w,h)), Draw->RGB24, 0, Draw->Black);
	if(scr == nil)
		return -1;
	scr.draw(scr.r, dst, nil, r.min);
	buf := array[w*3] of byte;
	n := 0;
	for(y := 0; y < h; y++){
		if(scr.readpixels(Rect((0,y),(w,y+1)), buf) != len buf)
			return -2;
		for(x := 0; x < w; x++)
			if(buf[x*3] != byte 0 || buf[x*3+1] != byte 0 || buf[x*3+2] != byte 0)
				n++;
	}
	return n;
}
