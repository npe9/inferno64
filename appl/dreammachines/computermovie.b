implement Computermovie;

# Nelson's Dream Machines "Computer movies" section: some of the very
# first computer-generated animation was exactly this - a camera path
# keyframed through a synthetic scene, interpolated and played back frame
# by frame (Whitney's early work, and much of what followed before
# real-time interactivity existed, is built on this same idea).
# module/math/camerapath.m provides the actual keyframe/interpolation
# primitive - position plus yaw/pitch per keyframe, linearly blended by
# time - as a small standalone extension alongside the draw3d family
# (it needs no software/protocol split of its own, being pure math with
# no rendering in it). This file is just a demo scene: six coloured
# panels in a row, flown through by a five-keyframe, 16-second looping
# camera path built from it - the camera moves, nothing else does,
# which is the actual point being demonstrated (contrast draw3ddemo.b,
# where the object spins in place and the camera never moves at all).

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Font: import draw;

include "math.m";
	math: Math;

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;
	Vector: import draw3d;

include "math/camerapath.m";
	camerapath: Camerapath;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Computermovie: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

DURATION: con 16.0;

win: ref Window;
d3c: ref Draw3d->Context;
black, white: ref Image;
font: ref Font;
t := 0.0;

path: array of Camerapath->Keyframe;

Panel: adt {
	x, y, z: real;
	col: ref Image;
};
panels: array of ref Panel;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	if(draw3d == nil){
		sys->fprint(sys->fildes(2), "computermovie: cannot load draw3d: %r\n");
		raise "fail:load";
	}
	draw3d->init();
	camerapath = load Camerapath Camerapath->PATH;
	if(camerapath == nil){
		sys->fprint(sys->fildes(2), "computermovie: cannot load camerapath: %r\n");
		raise "fail:load";
	}
	camerapath->init();
	wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil){
		sys->fprint(sys->fildes(2), "computermovie: cannot load wmclient: %r\n");
		raise "fail:load";
	}

	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "Computer Movie", Wmclient->Appl);
	d := win.display;
	white = d.color(Draw->White);
	black = d.color(Draw->Black);
	font = Font.open(d, "/fonts/lucidasans/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "*default*");

	panels = array[] of {
		ref Panel(-4.0, 0.0, -8.0, d.color(int 16rFF4444FF)),
		ref Panel(4.0, 0.0, -8.0, d.color(int 16r4488FFFF)),
		ref Panel(0.0, 3.0, -14.0, d.color(int 16rFFDD22FF)),
		ref Panel(0.0, -3.0, -14.0, d.color(int 16r44DD44FF)),
		ref Panel(-6.0, 0.0, -20.0, d.color(int 16rFF8822FF)),
		ref Panel(6.0, 0.0, -20.0, d.color(int 16rBB55FFFF)),
	};

	Keyframe: import camerapath;
	path = array[] of {
		Keyframe(0.0, 0.0, 0.0, 4.0, 0.0, 0.0),
		Keyframe(4.0, 0.0, 0.0, -6.0, 15.0, 0.0),
		Keyframe(8.0, -2.0, 1.0, -14.0, -10.0, 6.0),
		Keyframe(12.0, 2.0, -1.0, -20.0, 10.0, -6.0),
		Keyframe(16.0, 0.0, 0.0, -26.0, 0.0, 0.0),
	};

	win.reshape(Rect((0, 0), (700, 500)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 30);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			frame();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q')
			exit;
	<-ticks =>
		t += 0.03;
		if(t > DURATION)
			t -= DURATION;
		frame();
	}
}

setup(img: ref Image)
{
	if(d3c == nil)
		d3c = draw3d->context(img);
	else
		draw3d->resize(d3c, img);
	draw3d->viewport(d3c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	draw3d->setz(d3c, 1);
	draw3d->mode(Draw3d->PROJ);
	draw3d->identity();
	# frustumoffset(), not frustum() - see [[inferno-rio-draw3d-gpu]] for why
	# the latter silently fails to render through the GPU T&L path.
	draw3d->frustumoffset(2.2, -2.2, 0.0);
	draw3d->mode(Draw3d->MODEL);
}

drawpanel(pn: ref Panel)
{
	s := 1.5;
	verts := array[] of {
		Vector(pn.x-s, pn.y-s, pn.z), Vector(pn.x+s, pn.y-s, pn.z),
		Vector(pn.x+s, pn.y+s, pn.z), Vector(pn.x-s, pn.y+s, pn.z),
	};
	draw3d->setcolour(d3c, pn.col);
	draw3d->fillpoly3(d3c, verts, Vector(0.0, 0.0, 1.0), 1.0);
}

frame()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, black, nil, Point(0, 0));
	setup(img);
	draw3d->clearz(d3c);

	(cx, cy, cz, yaw, pitch) := camerapath->at(path, t);
	draw3d->identity();
	draw3d->rotatex(-pitch);
	draw3d->rotatey(-yaw);
	draw3d->translate(-cx, -cy, -cz);

	for(i := 0; i < len panels; i++)
		drawpanel(panels[i]);

	if(font != nil)
		img.text(Point(img.r.min.x+8, img.r.min.y+16), white, Point(0, 0), font,
			sys->sprint("computer movie  t=%.1f  cam=(%.1f,%.1f,%.1f)  yaw=%.0f  pitch=%.0f",
				t, cx, cy, cz, yaw, pitch));
	img.flush(Draw->Flushnow);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
