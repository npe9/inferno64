implement Sprite2dtest;

# draw3d(2)'s sprite2d is a resample, and two of its cases have an
# answer that does not depend on the resampler at all: at 1:1 with no
# rotation it must reproduce the source exactly, and a quarter turn must
# reproduce the source turned by hand.  Both are checked here against a
# plain masked draw(), which is the oracle.
#
# Both used to fail, every case.  The sample point was the pixel corner
# rather than its centre and Limbo's int() rounds a half away from zero,
# so a 1:1 sprite came out one column right with its leftmost column
# lost; and the bounding box took the larger half-extent for both axes,
# so a sprite with an odd short side could not sit at the box's centre.
#
# Takes an optional provider path, so an older or altered
# math/draw3d.dis can be run through the same cases as a control.

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
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Sprite2dtest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

win: ref Window;
d3: Draw3d;
bad := 0;
tot := 0;
failed := 0;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "sprite2dtest", Wmclient->Appl);
	win.reshape(Rect((0,0),(640,480)));
	win.onscreen(nil);
	d := win.display;
	path := "/dis/math/draw3d.dis";
	if(tl argv != nil)
		path = hd tl argv;
	d3 = load Draw3d path;
	if(d3 == nil){
		sys->print("sprite2dtest: load %s: %r\n", path);
		raise "fail:load";
	}
	d3->init();
	for(mi := 0; mi < 2; mi++){
		sz := 7 :: 8 :: 16 :: 33 :: 64 :: 207 :: nil;
		for(l := sz; l != nil; l = tl l){
			w := hd l;
			one(d, w, w, mi);
			one(d, w, w/2+1, mi);
		}
	}
	sys->print("sprite2dtest: %s: %d cases, %d differ from a plain draw\n",
		path, tot, bad);
	failed = bad;
	tot = bad = 0;
	for(mi = 0; mi < 2; mi++){
		sz2 := 8 :: 16 :: 33 :: 64 :: nil;
		for(l2 := sz2; l2 != nil; l2 = tl l2)
			for(q := 1; q <= 3; q++)
				quarter(d, hd l2, q, mi);
	}
	sys->print("sprite2dtest: %s: %d quarter turns, %d differ from a rotated source\n",
		path, tot, bad);
	failed += bad;
	tot = bad = 0;
	for(mi = 0; mi < 2; mi++){
		sz3 := 7 :: 8 :: 16 :: 33 :: 64 :: nil;
		for(l3 := sz3; l3 != nil; l3 = tl l3)
			twice(d, hd l3, mi);
	}
	sys->print("sprite2dtest: %s: %d doublings, %d differ from a doubled source\n",
		path, tot, bad);
	if(bad != 0 || failed){
		sys->print("sprite2dtest: FAIL\n");
		raise "fail:sprite2d is not exact";
	}
	sys->print("sprite2dtest: PASS\n");
}

# Doubling is exact too: every source pixel must come out as a 2x2
# block.  This is the only case here that goes through the separable
# unrotated path with a scale, which the 1:1 cases skip - they take the
# identity blit - and the quarter turns never reach.
twice(d: ref Display, n, withmask: int)
{
	img := d.newimage(Rect((0,0),(n,n)), Draw->CMAP8, 0, Draw->Black);
	dbl := d.newimage(Rect((0,0),(2*n,2*n)), Draw->CMAP8, 0, Draw->Black);
	if(img == nil || dbl == nil)
		return;
	b := array[n*n] of byte;
	bb := array[4*n*n] of byte;
	for(y := 0; y < n; y++)
		for(x := 0; x < n; x++){
			v := byte (1 + (x*7 + y*13) % 200);
			b[y*n+x] = v;
			bb[(2*y)*2*n + 2*x] = v;
			bb[(2*y)*2*n + 2*x+1] = v;
			bb[(2*y+1)*2*n + 2*x] = v;
			bb[(2*y+1)*2*n + 2*x+1] = v;
		}
	img.writepixels(img.r, b);
	dbl.writepixels(dbl.r, bb);
	mask: ref Image = nil;
	bmask: ref Image = nil;
	if(withmask){
		mbpl := (n+7)/8;
		bbpl := (2*n+7)/8;
		mb := array[mbpl*n] of byte;
		bm := array[bbpl*2*n] of byte;
		for(y = 0; y < n; y++)
			for(x = 0; x < n; x++)
				if(((x+y) & 3) != 0){
					mb[y*mbpl + (x>>3)] |= byte (16r80 >> (x&7));
					for(dy := 0; dy < 2; dy++)
						for(dx := 0; dx < 2; dx++){
							px := 2*x+dx;
							bm[(2*y+dy)*bbpl + (px>>3)] |= byte (16r80 >> (px&7));
						}
				}
		mask = d.newimage(Rect((0,0),(n,n)), Draw->GREY1, 0, 0);
		bmask = d.newimage(Rect((0,0),(2*n,2*n)), Draw->GREY1, 0, 0);
		mask.writepixels(mask.r, mb);
		bmask.writepixels(bmask.r, bm);
	}
	a := d.newimage(Rect((0,0),(640,480)), Draw->RGB24, 0, Draw->Black);
	c := d.newimage(Rect((0,0),(640,480)), Draw->RGB24, 0, Draw->Black);
	if(a == nil || c == nil)
		return;
	d3->sprite2d(a, Point(320,240), img, mask, 2*n, 2*n, 0.0, 0);
	c.draw(Rect((320-n, 240-n), (320+n, 240+n)), dbl, bmask, dbl.r.min);
	tot++;
	if(!same(a, c)){
		bad++;
		sys->print("sprite2dtest: DOUBLE DIFFER %dx%d mask=%d\n", n, n, withmask);
	}
}

# A quarter turn is exact whatever the resampler does, so it can be
# checked against a source rotated by hand.  This is the only test here
# that exercises the rotated path at all.
quarter(d: ref Display, n, q, withmask: int)
{
	img := d.newimage(Rect((0,0),(n,n)), Draw->CMAP8, 0, Draw->Black);
	rot := d.newimage(Rect((0,0),(n,n)), Draw->CMAP8, 0, Draw->Black);
	if(img == nil || rot == nil)
		return;
	b := array[n*n] of byte;
	rb := array[n*n] of byte;
	for(y := 0; y < n; y++)
		for(x := 0; x < n; x++)
			b[y*n+x] = byte (1 + (x*7 + y*13) % 200);
	img.writepixels(img.r, b);
	# degz turns the sprite clockwise on a y-down screen, so source
	# pixel (x,y) lands at (n-1-y, x) for q=1.
	for(y = 0; y < n; y++)
		for(x = 0; x < n; x++){
			dx := x; dy := y;
			for(k := 0; k < q; k++){
				t := dx;
				dx = n-1-dy;
				dy = t;
			}
			rb[dy*n+dx] = b[y*n+x];
		}
	rot.writepixels(rot.r, rb);
	mask: ref Image = nil;
	rmask: ref Image = nil;
	if(withmask){
		mbpl := (n+7)/8;
		mb := array[mbpl*n] of byte;
		rm := array[mbpl*n] of byte;
		for(y = 0; y < n; y++)
			for(x = 0; x < n; x++)
				if(((x+y) & 3) != 0){
					mb[y*mbpl + (x>>3)] |= byte (16r80 >> (x&7));
					dx := x; dy := y;
					for(k := 0; k < q; k++){
						t := dx;
						dx = n-1-dy;
						dy = t;
					}
					rm[dy*mbpl + (dx>>3)] |= byte (16r80 >> (dx&7));
				}
		mask = d.newimage(Rect((0,0),(n,n)), Draw->GREY1, 0, 0);
		rmask = d.newimage(Rect((0,0),(n,n)), Draw->GREY1, 0, 0);
		mask.writepixels(mask.r, mb);
		rmask.writepixels(rmask.r, rm);
	}
	a := d.newimage(Rect((0,0),(640,480)), Draw->RGB24, 0, Draw->Black);
	c := d.newimage(Rect((0,0),(640,480)), Draw->RGB24, 0, Draw->Black);
	if(a == nil || c == nil)
		return;
	d3->sprite2d(a, Point(320,240), img, mask, n, n, real (q*90), 0);
	c.draw(Rect((320-n/2, 240-n/2), (320-n/2+n, 240-n/2+n)),
		rot, rmask, rot.r.min);
	tot++;
	if(!same(a, c)){
		bad++;
		sys->print("sprite2dtest: QUARTER DIFFER %dx%d q=%d mask=%d\n", n, n, q, withmask);
	}
}

one(d: ref Display, iw, ih, withmask: int)
{
	img := d.newimage(Rect((0,0),(iw,ih)), Draw->CMAP8, 0, Draw->Black);
	if(img == nil)
		return;
	b := array[iw*ih] of byte;
	for(y := 0; y < ih; y++)
		for(x := 0; x < iw; x++)
			b[y*iw+x] = byte (1 + (x*7 + y*13) % 200);
	img.writepixels(img.r, b);
	mask: ref Image = nil;
	if(withmask){
		mask = d.newimage(Rect((0,0),(iw,ih)), Draw->GREY1, 0, 0);
		mbpl := (iw+7)/8;
		mb := array[mbpl*ih] of byte;
		for(y = 0; y < ih; y++)
			for(x = 0; x < iw; x++)
				if(((x+y) & 3) != 0)
					mb[y*mbpl + (x>>3)] |= byte (16r80 >> (x&7));
		mask.writepixels(mask.r, mb);
	}
	a := d.newimage(Rect((0,0),(640,480)), Draw->RGB24, 0, Draw->Black);
	c := d.newimage(Rect((0,0),(640,480)), Draw->RGB24, 0, Draw->Black);
	if(a == nil || c == nil)
		return;
	d3->sprite2d(a, Point(320,240), img, mask, iw, ih, 0.0, 0);
	c.draw(Rect((320-iw/2, 240-ih/2), (320-iw/2+iw, 240-ih/2+ih)),
		img, mask, img.r.min);
	tot++;
	if(!same(a, c)){
		bad++;
		sys->print("sprite2dtest: DIFFER %dx%d mask=%d\n", iw, ih, withmask);
	}
}

same(a, c: ref Image): int
{
	bpl := 640*3;
	ba := array[bpl] of byte;
	bc := array[bpl] of byte;
	for(y := 0; y < 480; y++){
		if(a.readpixels(Rect((0,y),(640,y+1)), ba) != bpl)
			return 0;
		if(c.readpixels(Rect((0,y),(640,y+1)), bc) != bpl)
			return 0;
		for(i := 0; i < bpl; i++)
			if(ba[i] != bc[i])
				return 0;
	}
	return 1;
}
