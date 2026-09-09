implement Box;

# TempleOS Demo/Graphics/Box.HC — software 3D wireframe (Limbo math)
#
# Faithful to the original: an orthographic ±100 cube (no perspective —
# GrLine3 under DCF_TRANSFORMATION is a pure matrix transform) anchored at
# dc->x,y = (200,200), drawn RED with thick=2 over the white DocClear page,
# tumbling with three independent ZXZ Euler angles and a breathing scale
# pulse, exiting on any key (while (!ScanChar)).
#
# DCF_TRANSFORMATION and GrLine3 are draw3d(2)'s matrix stack and line3,
# so that is what this draws through rather than transforming the eight
# vertices by hand.  The correspondence is exact and worth writing down,
# because it is the same one every other hand-rolled port will need:
#
#	Mat4x4RotZ/RotX/Scale  ->  rotatez/rotatex/scale on MODEL
#	orthographic, drop z   ->  ortho(200.0, ...) on PROJ, which is
#				   x/200 and y/200 and no divide by w
#	dc->x,y = (200,200)    ->  viewport() over the 400x400 box whose
#				   centre is that point, so NDC ±1 lands
#				   at ±200 pixels and a ±100 vertex at
#				   ±100 pixels, as before
#	GrLine3(...,thick)     ->  line3(c, a, b, thick)
#
# The matrix stack post-multiplies, as OpenGL's does, so the calls read
# left to right in the order the original applies them: the scale is
# outermost and Rz(θ1) innermost.
#
# The depth buffer stays OFF.  The original draws all twelve edges with
# no hidden-line removal, and switching depth on here would start hiding
# the back of the cube - a different picture, not a better one.

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
	Vector: import Draw3d;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Box: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 20;
fcacc := 0;

# exact TempleOS palette entries used by the original

win: ref Window;
red, white: ref Image;
d3c: ref Draw3d->Context;

# original: F64 θ1=0,θ2=0,θ3=0, s=1, s1=1.05, advanced once per Sleep(20) frame
th1 := 0.0;
th2 := 0.0;
th3 := 0.0;
s := 1.0;
s1 := 1.05;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	# The protocol provider puts the transform and the lines on the GPU;
	# the software one is the same interface in Limbo, so a host without
	# a device loses nothing but speed.
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	if(draw3d != nil)
		draw3d->init();
	wmclient = load Wmclient Wmclient->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Box", Wmclient->Appl);
	d := win.display;
	red = d.color(grpal->value(Grpalette->RED));
	white = d.color(grpal->value(Grpalette->WHITE));
	win.reshape(Rect((0, 0), (400, 400)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	# original loops Sleep(20) ≈ 50 fps with per-frame angle/scale steps;
	# we tick at the same 20 ms so the per-frame constants carry over 1:1
	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			drawbox();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	<-win.ctxt.kbd =>
		exit;		# original exits on ANY key
	dtms := <-ticks =>
		fcacc += dtms;
		for(fcn := 0; fcacc >= FCSTEP && fcn < 4; fcn++){
			Pi: con Math->Pi;
			th1 += 2.0*Pi/70.0;
			th2 += 2.0*Pi/90.0;
			th3 += 2.0*Pi/110.0;
			s *= s1;
			if(!(s > 0.2 && s < 1.4))
				s1 = 1.0/s1;
			fcacc -= FCSTEP;
		}
		drawbox();
	}
}

drawbox()
{
	img := win.image;
	if(img == nil || draw3d == nil)
		return;
	# DocClear: white page background
	img.draw(img.r, white, nil, Point(0, 0));
	o := img.r.min;

	if(d3c == nil)
		d3c = draw3d->context(img);
	else
		draw3d->resize(d3c, img);
	draw3d->setz(d3c, 0);
	draw3d->setzclip(d3c, 0);		# orthographic: nothing is "behind"
	draw3d->setcolour(d3c, red);
	# dc->x,y = (200,200): a fixed anchor, not the window centre
	draw3d->viewport(d3c, o.x, o.y, o.x + 400, o.y + 400);
	draw3d->mode(Draw3d->PROJ);
	draw3d->identity();
	draw3d->ortho(200.0, 0.0, 0.0);
	draw3d->mode(Draw3d->MODEL);
	draw3d->identity();
	# Mat4x4Scale(s); Mat4x4RotZ(θ3); Mat4x4RotX(θ2); Mat4x4RotZ(θ1)
	draw3d->scale(s, s, s);
	draw3d->rotatez(th3*180.0/Math->Pi);
	draw3d->rotatex(th2*180.0/Math->Pi);
	draw3d->rotatez(th1*180.0/Math->Pi);

	v := array[8] of Vector;
	i := 0;
	for(zz := -1; zz <= 1; zz += 2)
		for(yy := -1; yy <= 1; yy += 2)
			for(xx := -1; xx <= 1; xx += 2)
				v[i++] = Vector(100.0*real xx, 100.0*real yy,
					100.0*real zz);
	edges := array[] of {
		(0,1),(1,3),(3,2),(2,0),
		(4,5),(5,7),(7,6),(6,4),
		(0,4),(1,5),(2,6),(3,7)
	};
	# dc->thick=2: Plan 9 line widths are odd (2r+1); radius 1 (3 px)
	# is the nearest that keeps the original's fat pen
	for(j := 0; j < len edges; j++){
		(a, b) := edges[j];
		draw3d->line3(d3c, v[a], v[b], 1);
	}
	img.flush(Draw->Flushnow);
}

