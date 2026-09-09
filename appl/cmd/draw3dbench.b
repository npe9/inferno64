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
	sprite3s(d);
	readback(d, col, large);
	agree(d);
	gradient(d);
	fringe(d);
}

# The Sprite3 family, which until now had no caller anywhere in the tree
# and therefore no evidence.  Four things are checked, each with a metric
# that can tell the failure from the success rather than merely notice
# that something was drawn:
#
#  place	the sprite lands where project() says its world point does;
#  scale	halving the distance doubles the on-screen width, which is
#		the whole of what makes it a 3D sprite rather than a blit;
#  rotate	sprite3zb at 90 degrees turns a wide sprite into a tall one
#		- a lit-pixel count cannot tell that, a bounding box can;
#  occlude	with the z-buffer on, a sprite behind a filled triangle does
#		not appear in front of it.
#
# Both providers, because the protocol one is where a path gets silently
# dropped, and it is the one a port would want.
sprite3s(d: ref Display)
{
	sys->print("draw3dbench: Sprite3 family\n");
	for(pass := 0; pass < 2; pass++){
		path := Draw3d->PATH;
		what := "software";
		if(pass == 1){
			path = "/dis/math/draw3ddev.dis";
			what = "protocol";
		}
		d3 := load Draw3d path;
		if(d3 == nil){
			sys->print("draw3dbench:   %s: cannot load\n", what);
			continue;
		}
		d3->init();
		s3place(d, d3, what);
		s3scale(d, d3, what);
		s3rotate(d, d3, what);
		s3occlude(d, d3, what);
	}
}

# A fresh black frame with a context looking down -Z through a symmetric
# frustum, the same camera the triangle cases use.
s3frame(d3: Draw3d, zon: int): ref Draw3d->Context
{
	img := win.image;
	img.draw(img.r, img.display.black, nil, img.r.min);
	c := d3->context(img);
	d3->setzarea(c, img.r);
	d3->setz(c, zon);
	d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	d3->mode(Draw3d->PROJ); d3->identity(); d3->frustum(0.1, 0.1, 100.0);
	d3->mode(Draw3d->MODEL); d3->identity();
	d3->clearz(c);
	return c;
}

# A w by h sprite, opaque, in a colour nothing else in the frame uses.
s3sprite(d: ref Display, w, h: int): (ref Image, ref Image)
{
	img := d.newimage(Rect((0,0),(w,h)), win.image.chans, 0, Draw->Green);
	mask := d.newimage(Rect((0,0),(w,h)), Draw->GREY1, 0, int 16rFFFFFFFF);
	return (img, mask);
}

# Bounding box and count of the pixels whose green dominates - the sprite
# colour - read straight off the screen image.
s3box(d: ref Display): (int, int, int, int, int)
{
	dst := d.image;
	r := win.image.r;
	(r, nil) = r.clip(dst.r);
	bpl := (r.dx() * dst.depth + 7) / 8;
	pxb := dst.depth / 8;
	if(pxb < 3 || r.dx() < 1 || r.dy() < 1)
		return (0, 0, 0, 0, 0);
	buf := array[bpl] of byte;
	n := 0;
	x0 := 1000000; x1 := -1; y0 := 1000000; y1 := -1;
	for(y := r.min.y; y < r.max.y; y++){
		if(dst.readpixels(Rect((r.min.x, y), (r.max.x, y+1)), buf) != bpl)
			return (0, 0, 0, 0, 0);
		for(x := 0; x*pxb + 2 < bpl; x++){
			rr := int buf[x*pxb]; gg := int buf[x*pxb+1]; bb := int buf[x*pxb+2];
			if(gg > 120 && gg - rr > 60 && gg - bb > 60){
				n++;
				px := r.min.x + x;
				if(px < x0) x0 = px;
				if(px > x1) x1 = px;
				if(y < y0) y0 = y;
				if(y > y1) y1 = y;
			}
		}
	}
	if(n == 0)
		return (0, 0, 0, 0, 0);
	return (n, x0, x1, y0, y1);
}

# Does the sprite land where its world point projects to?
s3place(d: ref Display, d3: Draw3d, what: string)
{
	(img, mask) := s3sprite(d, 16, 16);
	c := s3frame(d3, 0);
	p := Draw3d->Vector(0.8, 0.0, -4.0);
	(sp, nil, ok) := d3->project(c, p);
	d3->sprite3(c, p, img, mask, 0.0);
	(n, x0, x1, y0, y1) := s3box(d);
	cx := (x0+x1)/2;
	cy := (y0+y1)/2;
	dx := cx - sp.x; if(dx < 0) dx = -dx;
	dy := cy - sp.y; if(dy < 0) dy = -dy;
	v := "ok";
	if(!ok || n == 0 || dx > 2 || dy > 2)
		v = "WRONG";
	sys->print("draw3dbench:   %s place: n=%d centre=%d,%d project=%d,%d  %s\n",
		what, n, cx, cy, sp.x, sp.y, v);
}

# Distance must set the on-screen size.  Shrinking is NOT the check to
# make: a plain draw() into a smaller rectangle crops the source, and a
# crop of a 16-wide sprite to 8 is 8 wide, exactly like a resample of it.
# Enlarging is the check that discriminates, because no amount of
# cropping makes a 16-pixel image cover 32 pixels.  The three depths are
# a 1x, a 2x and a half, and the widths must be 16, 32 and 8.
s3scale(d: ref Display, d3: Draw3d, what: string)
{
	(img, mask) := s3sprite(d, 16, 16);
	w := array[3] of int;
	z := array[] of {-4.0, -2.0, -8.0};
	for(i := 0; i < 3; i++){
		c := s3frame(d3, 0);
		d3->sprite3(c, Draw3d->Vector(0.0, 0.0, z[i]), img, mask, 4.0);
		(n, a0, a1, nil, nil) := s3box(d);
		w[i] = a1 - a0 + 1;
		if(n == 0)
			w[i] = 0;
	}
	v := "ok";
	if(near(w[0], 16, 1) == 0)
		v = "WRONG AT 1:1";
	else if(near(w[1], 32, 2) == 0)
		v = "NOT ENLARGED";
	else if(near(w[2], 8, 1) == 0)
		v = "NOT REDUCED";
	sys->print("draw3dbench:   %s scale: widths at z=-4,-2,-8 are %d,%d,%d (want 16,32,8)  %s\n",
		what, w[0], w[1], w[2], v);
}

near(got, want, slop: int): int
{
	d := got - want;
	if(d < 0)
		d = -d;
	return d <= slop;
}

# sprite3zb at 90 degrees turns a wide sprite into a tall one.  Counting
# lit pixels cannot see that; the bounding box can.
s3rotate(d: ref Display, d3: Draw3d, what: string)
{
	(img, mask) := s3sprite(d, 48, 12);
	c := s3frame(d3, 0);
	d3->sprite3zb(c, Draw3d->Vector(0.0, 0.0, -4.0), img, mask, 0.0, 0.0);
	(n0, a0, a1, c0, c1) := s3box(d);
	w0 := a1-a0+1; h0 := c1-c0+1;
	c = s3frame(d3, 0);
	d3->sprite3zb(c, Draw3d->Vector(0.0, 0.0, -4.0), img, mask, 0.0, 90.0);
	(n1, b0, b1, e0, e1) := s3box(d);
	w1 := b1-b0+1; h1 := e1-e0+1;
	v := "ok";
	if(n0 == 0 || n1 == 0 || w0 <= h0 || h1 <= w1)
		v = "NOT ROTATED";
	sys->print("draw3dbench:   %s rotate: 0deg %dx%d, 90deg %dx%d  %s\n",
		what, w0, h0, w1, h1, v);
}

# With the z-buffer on, a sprite behind a filled triangle must not paint
# over it - and a sprite in front of one must.  The second half is not
# decoration: zero green pixels is also what "the sprite was never drawn
# at all" looks like, and a provider that silently drops sprites would
# otherwise pass the occlusion check for the wrong reason.
s3occlude(d: ref Display, d3: Draw3d, what: string)
{
	behind := s3occlude1(d, d3, -6.0);
	front := s3occlude1(d, d3, -2.0);
	v := "ok";
	if(front == 0)
		v = "NO SPRITE AT ALL";
	else if(behind != 0)
		v = "NOT OCCLUDED";
	sys->print("draw3dbench:   %s occlude: %d sprite pixels behind a face, %d in front  %s\n",
		what, behind, front, v);
}

s3occlude1(d: ref Display, d3: Draw3d, z: real): int
{
	(img, mask) := s3sprite(d, 24, 24);
	c := s3frame(d3, 1);
	d3->setcolour(c, d.color(Draw->Red));
	tri := array[3] of Draw3d->Vector;
	tri[0] = Draw3d->Vector(-1.0, -1.0, -3.0);
	tri[1] = Draw3d->Vector( 1.0, -1.0, -3.0);
	tri[2] = Draw3d->Vector( 0.0,  1.2, -3.0);
	d3->fillpoly3(c, tri, Draw3d->Vector(0.0, 0.0, 1.0), 1.0);
	d3->sprite3(c, Draw3d->Vector(0.0, 0.0, z), img, mask, 0.0);
	(n, nil, nil, nil, nil) := s3box(d);
	return n;
}

# How many distinct colours does ONE face come out in?
#
# This is the whole difference the Metal fragment shader makes, in a
# single number.  fillpoly3 hands a face one colour, so the software
# rasteriser fills it with exactly that colour and no other: one.  fgmain
# lights it per pixel from the geometric normal and the view vector, and
# V varies across the face, so the specular and rim terms give a gradient
# that a flat fill cannot produce at any cost.
#
# The triangle is deliberately steep - it runs from near the eye to far
# from it - because a face-on one has almost no variation in V and would
# under-report.  Counting DISTINCT colours rather than measuring a range
# means the answer does not depend on which particular lighting model is
# in the shader, only on whether there is one.
gradient(d: ref Display)
{
	sys->print("draw3dbench: shading within one face\n");
	sw := gradient1(d, Draw3d->PATH);
	gp := gradient1(d, "/dis/math/draw3ddev.dis");
	sys->print("draw3dbench:   distinct colours in one face: software %d, GPU %d\n",
		sw, gp);
	if(gp <= sw)
		sys->print("draw3dbench:   the GPU is not shading (INFERNO_METAL_FLAT set?)\n");
}

gradient1(d: ref Display, path: string): int
{
	d3 := load Draw3d path;
	if(d3 == nil)
		return -1;
	d3->init();
	img := win.image;
	img.draw(img.r, d.black, nil, img.r.min);
	c := d3->context(img);
	d3->setzarea(c, img.r);
	d3->setz(c, 1);
	d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	d3->mode(Draw3d->PROJ); d3->identity(); d3->frustum(0.1, 0.1, 100.0);
	d3->mode(Draw3d->MODEL); d3->identity();
	d3->clearz(c);
	d3->setcolour(c, d.color(Draw->Red));
	tri := array[3] of Vector;
	# Steep: two corners close, the apex a long way back.
	tri[0] = Vector(-1.2, -0.9, -1.5);
	tri[1] = Vector( 1.2, -0.9, -1.5);
	tri[2] = Vector( 0.0,  1.1, -9.0);
	d3->fillpoly3(c, tri, Vector(0.0, 0.0, 1.0), 1.0);
	return ncolours(d.image, img.r);
}

ncolours(dst: ref Image, r: Rect): int
{
	(r, nil) = r.clip(dst.r);
	bpl := (r.dx() * dst.depth + 7) / 8;
	pxb := dst.depth / 8;
	if(pxb < 3 || r.dx() < 1 || r.dy() < 1)
		return -1;
	buf := array[bpl] of byte;
	# 18 bits of colour: fine enough to count gradient steps (at full
	# 24-bit precision the same face reads 63 colours against this
	# quantisation's 16, and the software renderer's 1 either way) and
	# small enough that the table is 256K rather than 16M.
	seen := array[262144] of byte;
	n := 0;
	for(y := r.min.y; y < r.max.y; y++){
		if(dst.readpixels(Rect((r.min.x, y), (r.max.x, y+1)), buf) != bpl)
			return -1;
		for(x := 0; x*pxb + 2 < bpl; x++){
			rr := int buf[x*pxb]; gg := int buf[x*pxb+1]; bb := int buf[x*pxb+2];
			if(rr < 8 && gg < 8 && bb < 8)
				continue;	# the black ground
			k := (rr>>2)<<12 | (gg>>2)<<6 | (bb>>2);
			if(seen[k] == byte 0){
				seen[k] = byte 1;
				n++;
			}
		}
	}
	return n;
}

# Does a GPU sprite have a dark halo where its mask ends?
#
# metal_upload_sprite_tex() sets alpha to 0 for masked-out texels but
# leaves their RGB alone, and the sprite sampler filters linearly.  Half
# way across a mask boundary the sampler therefore returns the average of
# an opaque white texel and a transparent BLACK one - rgb 0.5, a 0.5 -
# and a straight source-alpha blend paints 0.5*0.5 + 0.5*dst where the
# right answer is 0.5*1.0 + 0.5*dst.  The edge comes out dark.  This is
# the same visible signature as the sprite black border of 2026-09-06,
# with a different cause.
#
# The metric has to be one a resampler cannot fake, so: a white sprite on
# a GREEN ground.  Blending white over green can never lower the green
# channel below 255, whatever weight the filter picks - unless the colour
# being blended in is not white.  The minimum green byte over the window
# is therefore exactly 255 when the compositing is right and less when it
# is not, and it says nothing about which pixels the resampler chose.
#
# The software provider is the control: it blits through a binary mask
# and has no filter, so it must read 255.  Reachable through sprite3zb,
# which appl/wm/draw3ddemo.b calls; no appl/temple port does.
fringe(d: ref Display)
{
	sys->print("draw3dbench: sprite mask edges\n");
	sw := fringe1(d, Draw3d->PATH, Draw->Green, Draw->Black, 64);
	gp := fringe1(d, "/dis/math/draw3ddev.dis", Draw->Green, Draw->Black, 64);
	v := "ok";
	if(gp < 255)
		v = "DARK HALO";
	sys->print("draw3dbench:   halo (min green, white on green): software %d, GPU %d  %s\n",
		sw, gp, v);
	# Second case, isolating the OTHER half of the fix.  Above, the
	# sprite is black outside its mask, so premultiplying (rgb*0) changes
	# nothing and only the blend factor is under test.  Here the hidden
	# region is RED on a black ground, so a filter that averages straight
	# colours drags red into a white edge that should have none, and the
	# metric is how far red runs ahead of green - zero if the invisible
	# colour stayed invisible, ~127 if it bled.
	sw = fringe1(d, Draw3d->PATH, Draw->Black, Draw->Red, 48);
	gp = fringe1(d, "/dis/math/draw3ddev.dis", Draw->Black, Draw->Red, 48);
	v = "ok";
	if(gp > 8)
		v = "HIDDEN COLOUR BLED";
	sys->print("draw3dbench:   bleed (max r-g, white/red on black): software %d, GPU %d  %s\n",
		sw, gp, v);
}

# sz differs between the two cases on purpose: metal_upload_sprite_tex's
# texture cache is keyed on the image pointer, its data pointer and its
# size, and nothing about its contents, so two same-sized sprites made
# one after another can land on the same freed addresses and the second
# silently draws with the first one's texture.  A different size is
# enough to keep the cases independent - but see BUGS in draw3dbench(1),
# because the underlying cache is still wrong.
fringe1(d: ref Display, path: string, bg, outer, sz: int): int
{
	d3 := load Draw3d path;
	if(d3 == nil)
		return -1;
	d3->init();
	img := win.image;
	white := d.color(Draw->White);
	spr := d.newimage(Rect((0,0),(sz,sz)), img.chans, 0, outer);
	msk := d.newimage(Rect((0,0),(sz,sz)), Draw->GREY8, 0, Draw->Black);
	if(spr == nil || msk == nil)
		return -1;
	in := Rect((sz/5, sz/5), (sz - sz/5, sz - sz/5));
	# Opaque only well inside the image, so the mask edge the sampler
	# has to get right is interior to the texture and not an edge-clamp.
	# What lies OUTSIDE the mask is the point: it is invisible, and a
	# filter that mixes it into the visible edge is the defect.
	# A sprite the same colour throughout has no fringe to find.
	msk.draw(in, white, nil, (0,0));
	spr.draw(in, white, nil, (0,0));
	img.draw(img.r, d.color(bg), nil, img.r.min);
	c := d3->context(img);
	d3->setzarea(c, img.r);
	d3->setz(c, 0);
	d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	d3->mode(Draw3d->PROJ); d3->identity(); d3->frustum(0.1, 0.1, 100.0);
	d3->mode(Draw3d->MODEL); d3->identity();
	d3->sprite3zb(c, Vector(0.0, 0.0, -4.0), spr, msk, 16.0, 30.0);
	if(bg == Draw->Green)
		return chanstat(d.image, img.r, 0);
	return chanstat(d.image, img.r, 1);
}

# mode 0: the smallest green byte anywhere - 255 unless something
# darkened a white-over-green composite.
# mode 1: the largest excess of red over green - 0 unless red leaked in.
chanstat(dst: ref Image, r: Rect, mode: int): int
{
	(r, nil) = r.clip(dst.r);
	bpl := (r.dx() * dst.depth + 7) / 8;
	pxb := dst.depth / 8;
	if(pxb < 3 || r.dx() < 1 || r.dy() < 1)
		return -1;
	buf := array[bpl] of byte;
	mn := 255;
	mx := 0;
	for(y := r.min.y; y < r.max.y; y++){
		if(dst.readpixels(Rect((r.min.x, y), (r.max.x, y+1)), buf) != bpl)
			return -1;
		# XBGR32: R, G, B in memory, so red is index 0 and green is 1
		for(x := 0; x*pxb + 2 < bpl; x++){
			rr := int buf[x*pxb];
			gg := int buf[x*pxb+1];
			if(gg < mn)
				mn = gg;
			if(rr - gg > mx)
				mx = rr - gg;
		}
	}
	if(mode == 0)
		return mn;
	return mx;
}

# sprite2d is the other half of what appl/temple asks draw3d for, and
# eight ports use it and nothing else.  It is worth measuring separately
# because it is the same Limbo pixel loop in BOTH providers - neither
# sends a message - so the provider column here is a control that should
# come out flat, and the interesting comparison is against the native
# Image.draw that a rotation of zero degrees reduces to.
sprites(d: ref Display, dst: ref Image)
{
	# Two destinations, same as the triangle cases and for the same
	# reason: the GPU sprite path takes the screen or a fully-clear
	# layer of it and nothing else, so an offscreen buffer measures the
	# Limbo resampler in both providers and the window measures what a
	# port on draw3ddev actually gets.
	sys->print("draw3dbench: sprite2d into an offscreen buffer\n");
	spr(d, dst, 16, 0.0);
	spr(d, dst, 64, 0.0);
	spr(d, dst, 220, 0.0);
	spr(d, dst, 220, 30.0);
	sprsc(d, dst, 64, 220);
	sys->print("draw3dbench: sprite2d into the window\n");
	spr(d, win.image, 16, 0.0);
	spr(d, win.image, 64, 0.0);
	spr(d, win.image, 220, 0.0);
	spr(d, win.image, 220, 30.0);
	sprsc(d, win.image, 64, 220);
}

# Upright but scaled: the separable path in the Limbo resampler, and the
# one case where the answer is not obvious from the two above - there is
# no native blit that does it, but nor is there a rotation to pay for.
sprsc(d: ref Display, dst: ref Image, size, upto: int)
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
			d3->sprite2d(dst, Point(320, 240), img, mask, upto, upto, 0.0, 0);
		drain(d);
		t1 := sys->millisec();
		sys->print("draw3dbench:   %s %dx%d scaled to %d: %d us/sprite\n",
			what, size, size, upto, ((t1-t0)*1000)/n);
	}
}

# Queueing a GPU sprite is nearly free; the drawing happens when the
# frame is presented or read back.  Timing the calls alone would report
# "0 us" and mean nothing, so every batch below ends with a read of one
# row of the display's screen image, which runs the readback hook and
# waits for the GPU.  That is once per batch because it is once per
# frame in a real port, and the software rows pay the same read so the
# comparison stays like for like.
drain(d: ref Display)
{
	buf := array[(4 * d.image.depth + 7) / 8] of byte;
	d.image.readpixels(Rect(d.image.r.min, (d.image.r.min.x+4, d.image.r.min.y+1)),
		buf);
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
		drain(d);
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
	drain(d);
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

# Does the GPU path put the same thing on the screen as the software
# one?  Both providers draw a red, a green and a blue triangle at known
# world x, and the result is read back with a plain readpixels off the
# display's own screen image - which goes through devdraw's read message
# and calls gpudrawreadback(), the only way to see GPU output from
# inside emu.  Position AND colour, because the two bugs that kept this
# path from ever drawing were one of each: a clip that threw the scene
# away, and a channel order that turned red into blue.
agree(d: ref Display)
{
	sys->print("draw3dbench: software and GPU agreement\n");
	sw := frames(d, Draw3d->PATH);
	gp := frames(d, "/dis/math/draw3ddev.dis");
	bad := 0;
	names := array[] of {"red", "green", "blue"};
	for(i := 0; i < len sw; i++){
		(sx, sn, sr, sg, sb, sc) := sw[i];
		(gx, gn, gr, gg, gb, gc) := gp[i];
		off := sx - gx;
		if(off < 0)
			off = -off;
		# Coverage, not exact colour: fgmain shades per pixel, so the
		# GPU's triangle is deliberately not the same colour as the
		# software one.  What must still match is WHERE it is and how
		# much of the screen it covers - geometry - plus which
		# component dominates, which no plausible shading inverts.
		# 2% of the software count, or one pixel of an empty one.
		cov := sn - gn;
		if(cov < 0)
			cov = -cov;
		ok := sn > 0 && gn > 0 && off <= 2 && sc == gc && cov*50 <= sn;
		if(!ok)
			bad++;
		v := "ok";
		if(!ok)
			v = "DIFFER";
		sys->print("draw3dbench:   %s: software x=%d n=%d rgb=%d,%d,%d %s\n",
			names[i], sx, sn, sr, sg, sb, sc);
		sys->print("draw3dbench:        GPU x=%d n=%d rgb=%d,%d,%d %s  %s\n",
			gx, gn, gr, gg, gb, gc, v);
	}
	if(bad)
		sys->print("draw3dbench:   the GPU path does not match the software one\n");
}

frames(d: ref Display, path: string): array of (int, int, int, int, int, string)
{
	out := array[3] of (int, int, int, int, int, string);
	for(i := 0; i < 3; i++)
		out[i] = (-1, 0, 0, 0, 0, "?");
	d3 := load Draw3d path;
	if(d3 == nil)
		return out;
	d3->init();
	img := win.image;
	c := d3->context(img);
	d3->setzarea(c, img.r);
	d3->setz(c, 1);
	d3->viewport(c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	cols := array[] of {d.color(Draw->Red), d.color(Draw->Green), d.color(Draw->Blue)};
	tri := array[3] of Vector;
	for(k := 0; k < 3; k++){
		img.draw(img.r, d.black, nil, img.r.min);
		d3->mode(Draw3d->PROJ); d3->identity(); d3->frustum(0.1, 0.1, 100.0);
		d3->mode(Draw3d->MODEL); d3->identity();
		d3->clearz(c);
		d3->setcolour(c, cols[k]);
		wx := -1.5 + 1.5*real k;
		tri[0] = Vector(wx-0.4, -0.6, -4.0);
		tri[1] = Vector(wx+0.4, -0.6, -4.0);
		tri[2] = Vector(wx,      0.6, -4.0);
		d3->fillpoly3(c, tri, Vector(0.0, 0.0, 1.0), 1.0);
		# No flush: the read below is what has to see the geometry, and
		# a present would drain the GPU's queue first, leaving the
		# readback nothing to replay into the softscreen.
		out[k] = litmean(d.image, img.r);
	}
	return out;
}

# Centroid x, lit-pixel count, mean colour and dominant channel of the
# lit pixels, read straight off the image so the GPU's own output is what
# is measured.  The count is the coverage figure agree() compares: two
# renderers of the same geometry must light the same pixels even when
# they deliberately light them different colours.
litmean(dst: ref Image, r: Rect): (int, int, int, int, int, string)
{
	(r, nil) = r.clip(dst.r);
	bpl := (r.dx() * dst.depth + 7) / 8;
	pxb := dst.depth / 8;
	if(pxb < 3 || r.dx() < 1 || r.dy() < 1)
		return (-1, 0, 0, 0, 0, "?");
	buf := array[bpl] of byte;
	sx := 0; n := 0; sr := 0; sg := 0; sb := 0;
	for(y := r.min.y; y < r.max.y; y++){
		if(dst.readpixels(Rect((r.min.x, y), (r.max.x, y+1)), buf) != bpl)
			return (-1, 0, 0, 0, 0, "?");
		for(x := 0; x*pxb + 2 < bpl; x++){
			b0 := int buf[x*pxb]; b1 := int buf[x*pxb+1]; b2 := int buf[x*pxb+2];
			mx := b0; if(b1 > mx) mx = b1; if(b2 > mx) mx = b2;
			mn := b0; if(b1 < mn) mn = b1; if(b2 < mn) mn = b2;
			if(mx > 120 && mx - mn > 80){
				sx += r.min.x + x; n++;
				sr += b0; sg += b1; sb += b2;
			}
		}
	}
	if(n == 0)
		return (-1, 0, 0, 0, 0, "nothing drawn");
	sr /= n; sg /= n; sb /= n;
	# the screen image is XBGR32: R, G, B in memory
	if(sr >= sg && sr >= sb)
		return (sx/n, n, sr, sg, sb, "red");
	if(sg >= sb)
		return (sx/n, n, sr, sg, sb, "green");
	return (sx/n, n, sr, sg, sb, "blue");
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
