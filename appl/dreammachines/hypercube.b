implement Hypercube;

# Nelson's Dream Machines "Mind's Eye" chapter on n-dimensional
# visualization: the classic tesseract (4D hypercube) tumble. 16 vertices
# rotate simultaneously in two 4D planes (zw and xw - a single plane looks
# like an ordinary 3D spin; two together is what actually reads as
# tumbling in 4D), then get perspective-divided by (distance - w) down to
# ordinary 3D - the same trick used to go from 3D world space to a 2D
# screen, just one dimension up - before being handed to draw3d's usual
# line3()/matrix-stack pipeline for the final 3D->2D display. Each of the
# 4 axes gets its own edge colour (a standard convention in 4D wireframe
# visualizations), so a viewer can actually track which edges are "the
# ones you can't see" in an ordinary 3D object - yellow (the w axis) marks
# the 8 edges that only exist because there's a 4th dimension at all.
#
# An earlier version of this file also filled each half's 6 faces as a
# translucent solid (the "two nested cubes" look many tesseract demos
# use) - dropped after live testing: with all 12 faces filled, the two
# still-overlapping cubes near the start of a rotation read as one solid,
# oddly-coloured blob rather than a legible tesseract, and chasing the
# exact colour behaviour further wasn't worth it for what a plain
# multi-colour wireframe already shows clearly on its own.

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

Hypercube: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

DIST: con 6.5;
SCALE: con 8.0;

Pi: con Math->Pi;

win: ref Window;
d3c: ref Draw3d->Context;
black, white: ref Image;
axiscolour: array of ref Image;	# x, y, z, w edge colours, in that order
font: ref Font;
ang1 := 0.0;
ang2 := 0.0;

# 16 vertices of a 4D hypercube: bit i of the index selects -1/+1 for
# coordinate i (x,y,z,w).
v4: array of array of real;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	# Plain software provider, not draw3ddev.dis/GPU: this is 32 line3()
	# calls a frame, trivial CPU work, and the GPU-accelerated line3 path
	# was dropping most segments here for reasons not worth chasing when
	# nothing in this demo needs the acceleration in the first place.
	draw3d = load Draw3d Draw3d->PATH;
	if(draw3d == nil){
		sys->fprint(sys->fildes(2), "hypercube: cannot load draw3d: %r\n");
		raise "fail:load";
	}
	draw3d->init();
	wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil){
		sys->fprint(sys->fildes(2), "hypercube: cannot load wmclient: %r\n");
		raise "fail:load";
	}

	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "Hypercube", Wmclient->Appl);
	d := win.display;
	white = d.color(Draw->White);
	black = d.color(Draw->Black);
	axiscolour = array[] of {
		d.color(int 16rFF4444FF),	# x: red
		d.color(int 16r44DD44FF),	# y: green
		d.color(int 16r44AAFFFF),	# z: cyan-blue
		d.color(int 16rFFDD22FF),	# w: yellow - the "extra" axis
	};
	font = Font.open(d, "/fonts/lucidasans/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "*default*");

	v4 = array[16] of array of real;
	for(i := 0; i < 16; i++){
		v := array[4] of real;
		for(b := 0; b < 4; b++)
			if(i & (1<<b))
				v[b] = 1.0;
			else
				v[b] = -1.0;
		v4[i] = v;
	}

	win.reshape(Rect((0, 0), (560, 560)));
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
		ang1 += 1.3;
		ang2 += 0.7;
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
	# frustumoffset(), not frustum() - the latter's matrix silently fails
	# to render through the GPU T&L path (see [[inferno-rio-draw3d-gpu]]).
	draw3d->frustumoffset(2.2, -2.2, 0.0);
	draw3d->mode(Draw3d->MODEL);
}

project4d(): array of Vector
{
	s1 := math->sin(ang1*Pi/180.0);
	c1 := math->cos(ang1*Pi/180.0);
	s2 := math->sin(ang2*Pi/180.0);
	c2 := math->cos(ang2*Pi/180.0);
	out := array[16] of Vector;
	for(i := 0; i < 16; i++){
		x := v4[i][0]; y := v4[i][1]; z := v4[i][2]; w := v4[i][3];
		# rotate in the zw-plane
		z1 := z*c1 - w*s1;
		w1 := z*s1 + w*c1;
		# rotate in the xw-plane
		x1 := x*c2 - w1*s2;
		w2 := x*s2 + w1*c2;
		# perspective divide by (distance - w): the near "cube" of the
		# tesseract grows larger and the far one shrinks, same trick as
		# an ordinary 3D perspective camera, one dimension up. w2 can
		# reach +-3 in the worst case (two chained rotations of a unit
		# +-1 corner, triangle-inequality bound |x*s2|+|w1*c2| with
		# |w1|<=2), so a distance of 3 lets the denominator hit zero -
		# that's what was blowing one face up to cover the whole window.
		# DIST=6.5 keeps a safe margin (worst-case denom ~3.5); the clamp
		# is a second line of defence in case that bound is still loose.
		denom := DIST-w2;
		if(denom < 1.0)
			denom = 1.0;
		d := 1.0/denom;
		out[i] = Vector(x1*d*SCALE, y*d*SCALE, z1*d*SCALE);
	}
	return out;
}

frame()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, black, nil, Point(0, 0));
	setup(img);
	draw3d->identity();
	draw3d->translate(0.0, 0.0, -5.0);

	verts := project4d();

	for(i := 0; i < 16; i++){
		for(b := 0; b < 4; b++){
			j := i ^ (1<<b);
			if(j <= i)
				continue;
			draw3d->setcolour(d3c, axiscolour[b]);
			draw3d->line3(d3c, verts[i], verts[j], 1);
		}
	}
	if(font != nil)
		img.text(Point(img.r.min.x+8, img.r.min.y+16), white, Point(0, 0), font,
			"tesseract: red=x  green=y  blue=z  yellow=w (the 4th axis)");
	img.flush(Draw->Flushnow);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
