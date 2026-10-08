implement Draw3dsafetest;

# A Limbo program must not be able to fault emu, whatever it passes to
# draw3d(2).  That is the whole subject of this test: it does not check
# a single pixel, and a case here "passing" says nothing about what was
# drawn.  It says the VM was still standing afterwards.
#
# The interesting provider is the DEVICE one, math/draw3ddev.dis, which
# writes protocol messages straight to /dev/draw and so reaches the C
# handlers in emu/port/devdraw.c.  math/draw3d.dis does the same work in
# Limbo, where an out-of-range index raises a bounds error instead of
# reading whatever address the arithmetic produced, so it cannot fail
# the way this test is looking for.  It is still worth running against
# both - if the software provider ever faults, that is a VM bug - so the
# provider is an argument and the default is the device.
#
# The case that motivated the file: sprite2d's width and height travel
# to devdraw.c as a raw 32-bit int with no upper bound, and the mask
# coordinate derived from them was fed to byteaddr(), which forms an
# address by arithmetic alone and never checks the rectangle - so the
# `q == nil' test that stood in d3maskset() could not ever fire, and
# nothing at all bounded that coordinate.  Push it off the end by hand
# and emu takes a segmentation violation, which is what this test then
# catches; that is the negative control the file was written against.
#
# What is NOT claimed: that a Limbo caller can drive the coordinate out
# of range on its own.  With the guard instrumented to report, no input
# here and no case in sprite2dtest(1) ever reached it, and the reason
# looks structural - d3spritez() clips its box to the destination first,
# so however large a width the caller asks for, only the middle sliver
# of the sprite is ever sampled and the index stays near the middle of
# the mask.  The check is therefore hardening over a hazard that has not
# been shown to be reachable, not the repair of a live bug, and it is
# NOT the cause of any crash reported in a game.
#
# BUGS: this exercises the arguments a Limbo caller can reach through
# the draw3d(2) module.  It does not write malformed protocol bytes to
# /dev/draw directly, so a message the Limbo encoder cannot produce -
# a truncated one, or a bad matrix selector - is not covered here.

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
	Context, Vector: import draw3d;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Draw3dsafetest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

win: ref Window;
d3: Draw3d;
disp: ref Display;
probe: ref Image;
ok := 0;
fail := 0;
phase := "startup";
finished := 0;
mypid := 0;

# Seconds the whole run is allowed.  Generous by a wide margin: both
# providers now get through the whole battery in about five seconds --
# the device one in five, the software one in three.  It used to be that
# the software provider did not finish AT ALL; see watchdog() below for
# what was wrong and why the deadline still names the family it was in.
Deadline: con 240;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	mypid = sys->pctl(0, nil);
	spawn watchdog();
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "draw3dsafetest", Wmclient->Appl);
	win.reshape(Rect((0,0),(640,480)));
	win.onscreen(nil);
	disp = win.display;

	path := "/dis/math/draw3ddev.dis";
	if(tl argv != nil)
		path = hd tl argv;
	d3 = load Draw3d path;
	if(d3 == nil){
		sys->print("draw3dsafetest: load %s: %r\n", path);
		raise "fail:load";
	}
	d3->init();

	# The liveness probe.  Reading a pixel back out of an ordinary image
	# depends on nothing outside this process, so it answers the only
	# question being asked - is the draw device still serving us - without
	# a screenshot or a window manager in the way.
	probe = disp.newimage(Rect((0,0),(4,4)), Draw->RGB24, 0, Draw->Black);
	if(probe == nil){
		sys->print("draw3dsafetest: no probe image: %r\n");
		raise "fail:probe";
	}

	sprites();
	prims();
	finished = 1;

	sys->print("draw3dsafetest: %s: %d ok, %d fail\n", path, ok, fail);
	if(fail != 0){
		sys->print("draw3dsafetest: FAIL\n");
		raise "fail:draw3d faulted or stopped serving";
	}
	sys->print("draw3dsafetest: PASS\n");
}

# Draw a known colour and read it back.  A mismatch means the draw
# connection stopped doing what it is told, which is as much a failure
# as a fault - and unlike a fault, the process survives to report it.
alive(what: string): int
{
	probe.draw(probe.r, disp.color(Draw->Red), nil, probe.r.min);
	b := array[4*4*3] of byte;
	n := probe.readpixels(probe.r, b);
	if(n != len b){
		sys->print("draw3dsafetest: after %s: readpixels %d not %d: %r\n",
			what, n, len b);
		fail++;
		return 0;
	}
	# RGB24 is b,g,r per pixel in memory order; only that it came back
	# non-black and constant matters here.
	for(i := 0; i < len b; i += 3)
		if(b[i] == byte 0 && b[i+1] == byte 0 && b[i+2] == byte 0){
			sys->print("draw3dsafetest: after %s: probe went black\n", what);
			fail++;
			return 0;
		}
	ok++;
	return 1;
}

src(iw, ih: int): ref Image
{
	img := disp.newimage(Rect((0,0),(iw,ih)), Draw->CMAP8, 0, Draw->Black);
	if(img == nil)
		return nil;
	b := array[iw*ih] of byte;
	for(y := 0; y < ih; y++)
		for(x := 0; x < iw; x++)
			b[y*iw+x] = byte (1 + (x*7 + y*13) % 200);
	img.writepixels(img.r, b);
	return img;
}

msk(iw, ih: int): ref Image
{
	m := disp.newimage(Rect((0,0),(iw,ih)), Draw->GREY1, 0, 0);
	if(m == nil)
		return nil;
	bpl := (iw+7)/8;
	b := array[bpl*ih] of byte;
	for(y := 0; y < ih; y++)
		for(x := 0; x < iw; x++)
			if(((x+y) & 3) != 0)
				b[y*bpl + (x>>3)] |= byte (16r80 >> (x&7));
	m.writepixels(m.r, b);
	return m;
}

# The sizes that matter are the ones whose arithmetic overflows or loses
# precision on the way to a pixel index, not the ones a game would ask
# for.  16r40000000 is where a float32 half-extent has an ulp of 64, so
# the guard `lx < hx' can hold while `lx+hx' rounds up to exactly the
# full width - which is how a mask index reaches one column past the end
# without any single step being wrong.
sprites()
{
	widths := 0 :: -1 :: 1 :: 2 :: 3 :: 207 :: 100000 :: 16r10000000 ::
		16r40000000 :: 16r7FFFFFFF :: nil;
	degs := 0.0 :: 45.0 :: 90.0 :: 180.0 :: -270.0 :: 1.0e30 :: -1.0e30 :: nil;
	centres := Point(320,240) :: Point(0,0) :: Point(-100000,-100000) ::
		Point(16r40000000,16r40000000) :: nil;

	img := src(16, 16);
	mask := msk(16, 16);
	if(img == nil || mask == nil){
		sys->print("draw3dsafetest: no source images: %r\n");
		fail++;
		return;
	}
	dst := disp.newimage(Rect((0,0),(320,240)), Draw->RGB24, 0, Draw->Black);
	if(dst == nil){
		sys->print("draw3dsafetest: no destination: %r\n");
		fail++;
		return;
	}
	for(wl := widths; wl != nil; wl = tl wl){
		w := hd wl;
		phase = sys->sprint("sprite2d width %d", w);
		for(dl := degs; dl != nil; dl = tl dl){
			deg := hd dl;
			for(cl := centres; cl != nil; cl = tl cl){
				c := hd cl;
				for(mi := 0; mi < 2; mi++){
					m: ref Image = nil;
					if(mi)
						m = mask;
					for(fx := 0; fx < 2; fx++){
						d3->sprite2d(dst, c, img, m, w, w, deg, fx);
						d3->sprite2d(dst, c, img, m, w, 3, deg, fx);
						d3->sprite2d(dst, c, img, m, 3, w, deg, fx);
					}
				}
			}
		}
		if(!alive(sys->sprint("sprite2d width %d", w)))
			return;
	}

	# A mask that is not the same size as the source is the case where
	# the two index computations in devdraw.c's d3spritez() disagree, so
	# it gets its own pass rather than riding along above.
	sizes := 1 :: 3 :: 7 :: 64 :: nil;
	for(sl := sizes; sl != nil; sl = tl sl){
		s := hd sl;
		mm := msk(s, s);
		if(mm == nil)
			continue;
		phase = sys->sprint("sprite2d mismatched mask %dx%d", s, s);
		for(wl2 := widths; wl2 != nil; wl2 = tl wl2)
			for(dl2 := degs; dl2 != nil; dl2 = tl dl2)
				d3->sprite2d(dst, Point(160,120), img, mm,
					hd wl2, hd wl2, hd dl2, 0);
		if(!alive(sys->sprint("sprite2d mismatched mask %dx%d", s, s)))
			return;
	}
}

# The rest of the protocol, driven with the same disregard for what the
# numbers mean.  Nothing here has been shown to be reachable-and-wrong
# the way the sprite mask index was; the point is that if one of them
# ever is, this notices on the run that introduces it rather than on the
# day a game crashes.
prims()
{
	dst := disp.newimage(Rect((0,0),(320,240)), Draw->RGB24, 0, Draw->Black);
	if(dst == nil){
		fail++;
		return;
	}
	c := d3->context(dst);
	if(c == nil){
		sys->print("draw3dsafetest: no context: %r\n");
		fail++;
		return;
	}
	huge := 1.0e30;
	tiny := 1.0e-30;
	coords := 0.0 :: 1.0 :: -1.0 :: huge :: -huge :: tiny :: nil;

	# line3: thickness is a raw int on the wire.
	phase = "line3";
	thicks := 0 :: 1 :: 2 :: 100000 :: 16r40000000 :: 16r7FFFFFFF :: nil;
	for(tl0 := thicks; tl0 != nil; tl0 = tl tl0)
		for(xl := coords; xl != nil; xl = tl xl){
			x := hd xl;
			d3->line3(c, (x, x, x), (-x, x, -x), hd tl0);
		}
	if(!alive("line3"))
		return;

	phase = "plot3";
	for(xl2 := coords; xl2 != nil; xl2 = tl xl2){
		x2 := hd xl2;
		d3->plot3(c, (x2, -x2, x2));
	}
	if(!alive("plot3"))
		return;

	# fillpoly3 with a vertex count either side of the device's own
	# limit, and with degenerate geometry at each size.
	phase = "fillpoly3";
	ns := 3 :: 4 :: 1023 :: 1024 :: 1025 :: 4096 :: nil;
	for(nl := ns; nl != nil; nl = tl nl){
		n := hd nl;
		verts := array[n] of Vector;
		for(i := 0; i < n; i++){
			f := real i;
			verts[i] = (f, -f, f*1.0e20);
		}
		d3->fillpoly3(c, verts, (0.0, 0.0, 1.0), 1.0);
		d3->fillpoly3(c, verts, (huge, huge, huge), huge);
		# every vertex identical: zero area, and a plane fit with no plane
		for(j := 0; j < n; j++)
			verts[j] = (1.0, 1.0, 1.0);
		d3->fillpoly3(c, verts, (0.0, 0.0, 0.0), 0.0);
		lits := array[n] of real;
		for(k := 0; k < n; k++)
			lits[k] = huge;
		d3->fillpoly3g(c, verts, lits);
		# a lits array SHORTER than verts is the caller error most likely
		# to be made, and must not be read past its end.
		if(n > 3)
			d3->fillpoly3g(c, verts, array[3] of { * => 1.0 });
	}
	if(!alive("fillpoly3"))
		return;

	# Matrices whose entries make the projection divide by zero or
	# overflow, then geometry pushed through them.
	phase = "matrices";
	d3->identity();
	d3->scale(0.0, 0.0, 0.0);
	d3->line3(c, (1.0, 1.0, 1.0), (2.0, 2.0, 2.0), 1);
	d3->identity();
	d3->scale(huge, huge, huge);
	d3->plot3(c, (huge, huge, huge));
	d3->identity();
	d3->translate(huge, -huge, huge);
	d3->fillpoly3(c, array[3] of { (0.0,0.0,0.0), (1.0,0.0,0.0), (0.0,1.0,0.0) },
		(0.0,0.0,1.0), 1.0);
	d3->identity();
	d3->frustum(0.0, 0.0, 0.0);
	d3->plot3(c, (0.0, 0.0, 0.0));
	d3->identity();
	d3->ortho(0.0, tiny, -tiny);
	d3->plot3(c, (1.0, 1.0, 1.0));
	alive("matrices");
}

# A hang is a worse result than a failure: it reports nothing, and the
# harness that ran it can only say the run stopped.  So the run has a
# deadline, and passing it prints which family was in progress.
#
# This is not hypothetical, and the deadline earned its keep: it is what
# found two unbounded cases in the software provider, by naming the
# family each one was in.
#
# FIXED, both.  Against math/draw3d.dis a sprite2d used not to return in
# any time worth waiting for once the width reached 100000 - well below
# the extremes here - because the Limbo resampler walked the sprite's
# OWN box and only then asked whether each pixel landed in the
# destination, where the C path in devdraw.c clips the box to the
# destination first and so does a bounded amount of work however large
# the width.  transformsprite() now clips first too.  And a mask smaller
# than its image indexed off the end of the mask buffer, which Limbo
# turns into an array bounds error out of the caller rather than the
# wild read the C path would do - safe, but it still killed the program
# drawing the sprite; outside the mask now reads as transparent, which
# is what draw(2) does.
#
# So the asymmetry this paragraph used to describe is closed: three
# seconds for the software provider against five for the device one,
# 18 ok 0 fail both ways.  The deadline stays, because it is the thing
# that would notice the next one.
watchdog()
{
	for(i := 0; i < Deadline; i++){
		sys->sleep(1000);
		if(finished)
			return;
	}
	sys->print("draw3dsafetest: TIMEOUT after %d seconds during %s\n",
		Deadline, phase);
	sys->print("draw3dsafetest: FAIL\n");
	ctl := sys->open("/prog/" + string mypid + "/ctl", Sys->OWRITE);
	if(ctl == nil){
		# Without this the watchdog would print its verdict and then
		# exit alone, leaving the hang it just reported still running.
		sys->print("draw3dsafetest: cannot open /prog/%d/ctl: %r\n", mypid);
		sys->print("draw3dsafetest: the run is still hung; kill it by hand\n");
		exit;
	}
	poison := array of byte "killgrp";
	sys->write(ctl, poison, len poison);
	exit;
}
