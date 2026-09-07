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
	agree(d);
	fringe(d);
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
