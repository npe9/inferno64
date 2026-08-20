implement Draw3dDemo;

# Showcase for math/draw3d: perspective mesh, billboard sprite, HUD without Z.

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

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Draw3dDemo: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
d3c: ref Draw3d->Context;
black, white, yellow, cyan, grey, face: ref Image;
sprite, sprmask: ref Image;
ang := 0.0;
font: ref Font;

# Dynamic per-face flat shading (Nelson's "halftone image synthesis" - a
# shaded solid, not just a wireframe): each face's own object-space normal
# is rotated into the same stationary frame the light lives in (the current
# spin, with translation stripped out - there's no separate camera/view
# matrix in this demo) and dotted against a fixed light direction, so
# brightness genuinely changes as the cube turns rather than each face
# just keeping a hardcoded colour.
AMBIENT: con 0.15;
lightdir: Draw3d->Vector;
rotm: Draw3d->Matrix;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	# Prefer protocol module; fall back to software draw3d.dis.
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	if(draw3d == nil){
		sys->fprint(sys->fildes(2), "draw3ddemo: cannot load draw3d: %r\n");
		raise "fail:load";
	}
	draw3d->init();
	lightdir = draw3d->vnorm(Vector(0.35, 0.6, 0.7));

	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "Draw3d Demo", Wmclient->Appl);
	d := win.display;
	black = d.color(Draw->Black);
	white = d.color(Draw->White);
	yellow = d.color(Draw->Yellow);
	cyan = d.color(Draw->Cyan);
	grey = d.color(Draw->Grey);
	face = d.color(Draw->Palegreen);
	font = Font.open(d, "/fonts/lucidasans/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "*default*");
	sprite = d.open("/icons/temple/rocket_1.bit");
	sprmask = d.open("/icons/temple/rocket_1.mask");

	win.reshape(Rect((0, 0), (480, 400)));
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
		ang += 2.0;
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
	draw3d->mode(Draw3d->PROJ);
	draw3d->identity();
	# frustum()'s matrix (row 2 == row 3) is fine for the CPU toclip() path
	# but the GPU T&L path (metal_queue_fillpoly3d/d3combineproj) was only
	# ever exercised against frustumoffset()'s shifted-w-row convention
	# (castlefrankenstein's camera) - frustum() sent filled faces to the
	# GPU queue (metal_g3_calls counted them) with valid colours yet
	# nothing rasterized, a real gap this demo is the first to hit. Same
	# n/l = 4.0/1.5 scale as the old frustum() call; zoff=0 is an ordinary
	# perspective camera truly at the origin, no raycaster offset needed.
	draw3d->frustumoffset(2.6667, -2.6667, 0.0);
	draw3d->mode(Draw3d->MODEL);
}

frame()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, black, nil, Point(0, 0));
	setup(img);
	draw3d->clearz(d3c);
	draw3d->setz(d3c, 1);

	draw3d->identity();
	draw3d->translate(0.0, 0.0, -6.0);
	draw3d->rotatey(ang);
	draw3d->rotatex(ang * 0.6);

	# Capture the current spin as a rotation-only matrix (strip the
	# translate() column) so drawface() can carry each face's normal into
	# the same stationary frame lightdir lives in, without re-deriving the
	# rotation math by hand.
	rotm = draw3d->newmatrix();
	draw3d->storematrix(rotm);
	rotm[0][3] = 0.0;
	rotm[1][3] = 0.0;
	rotm[2][3] = 0.0;

	# Filled cube faces (painter's order: back then front-ish).
	drawface(array[] of {
		Vector(-1.0, -1.0, -1.0), Vector(1.0, -1.0, -1.0),
		Vector(1.0, 1.0, -1.0), Vector(-1.0, 1.0, -1.0)
	}, grey);
	drawface(array[] of {
		Vector(-1.0, -1.0, 1.0), Vector(-1.0, 1.0, 1.0),
		Vector(1.0, 1.0, 1.0), Vector(1.0, -1.0, 1.0)
	}, face);
	drawface(array[] of {
		Vector(-1.0, -1.0, -1.0), Vector(-1.0, -1.0, 1.0),
		Vector(1.0, -1.0, 1.0), Vector(1.0, -1.0, -1.0)
	}, cyan);
	drawface(array[] of {
		Vector(-1.0, 1.0, -1.0), Vector(1.0, 1.0, -1.0),
		Vector(1.0, 1.0, 1.0), Vector(-1.0, 1.0, 1.0)
	}, yellow);

	# Wire edges
	draw3d->setcolour(d3c, white);
	edges := array[] of {
		(Vector(-1.0,-1.0,-1.0), Vector(1.0,-1.0,-1.0)),
		(Vector(1.0,-1.0,-1.0), Vector(1.0,1.0,-1.0)),
		(Vector(1.0,1.0,-1.0), Vector(-1.0,1.0,-1.0)),
		(Vector(-1.0,1.0,-1.0), Vector(-1.0,-1.0,-1.0)),
		(Vector(-1.0,-1.0,1.0), Vector(1.0,-1.0,1.0)),
		(Vector(1.0,-1.0,1.0), Vector(1.0,1.0,1.0)),
		(Vector(1.0,1.0,1.0), Vector(-1.0,1.0,1.0)),
		(Vector(-1.0,1.0,1.0), Vector(-1.0,-1.0,1.0)),
		(Vector(-1.0,-1.0,-1.0), Vector(-1.0,-1.0,1.0)),
		(Vector(1.0,-1.0,-1.0), Vector(1.0,-1.0,1.0)),
		(Vector(1.0,1.0,-1.0), Vector(1.0,1.0,1.0)),
		(Vector(-1.0,1.0,-1.0), Vector(-1.0,1.0,1.0)),
	};
	for(i := 0; i < len edges; i++){
		(a, b) := edges[i];
		draw3d->line3(d3c, a, b, 0);
	}

	# Billboard + Z-rotated sprite (Sprite3ZB) beside the cube
	if(sprite != nil){
		draw3d->sprite3(d3c, Vector(2.2, 0.8, 0.0), sprite, sprmask, 1.0);
		draw3d->sprite3zb(d3c, Vector(2.2, -0.8, 0.0), sprite, sprmask, 1.0, ang * 3.0);
	}

	# HUD (no depth)
	draw3d->setz(d3c, 0);
	if(font != nil)
		img.text(Point(img.r.min.x+8, img.r.min.y+16), white, Point(0, 0), font,
			"draw3ddev: protocol mesh + sprite3/zb + HUD");
	img.flush(Draw->Flushnow);
}

drawface(v: array of Vector, col: ref Image)
{
	# Real per-vertex Gouraud, not just flat-per-face: each corner gets its
	# own smoothed normal instead of the face's single flat one, so
	# fillpoly3g's shading gradient is genuine, not a fake average. For a
	# cube centred on the local origin, the vertex-averaged normal at
	# corner (sx,sy,sz) - the average of the three unit-axis face normals
	# that meet there - is exactly the normalized diagonal vnorm(corner)
	# itself, no separate per-vertex bookkeeping needed.
	lits := array[len v] of real;
	for(i := 0; i < len v; i++){
		localn := draw3d->vnorm(v[i]);
		worldn := draw3d->mulpoint(rotm, localn);
		lit := draw3d->vdot(worldn, lightdir);
		if(lit < AMBIENT)
			lit = AMBIENT;
		lits[i] = lit;
	}
	draw3d->setcolour(d3c, col);
	draw3d->fillpoly3g(d3c, v, lits);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
