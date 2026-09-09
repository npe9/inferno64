implement Shading;

# TempleOS Demo/Graphics/Shading.HC — flat shading from a cross product.
#
#	Lighting(dc,ls,poly,color):
#	  v1=poly[0]-poly[1]; v2=poly[2]-poly[1];
#	  vn = v1 x v2;                      //normal to the surface
#	  d=Sqrt(vn.x^2+vn.y^2+vn.z^2); d=1<<16/d; vn*=d;   //length 65536
#	  Mat4x4MulXYZ(r,&vn_x,&vn_y,&vn_z);
#	  i=(vn.x*ls->x+vn.y*ls->y+vn.z*ls->z)>>16;   //dot with the light
#	  if (i<0) { dc->color=ROPF_PROBABILITY_DITHER+BLACK<<16+color;
#	             dc->dither_probability_u16=-i; }
#	  else     { dc->color=ROPF_PROBABILITY_DITHER+(color^8)<<16+color;
#	             dc->dither_probability_u16=i; }
#
# A sphere of RINGS=8 by FACES=32 quads, each split into two triangles,
# the upper half blue and the lower red, and the light source is the
# mouse — its vector is the cursor's offset from the centre of the window
# with z fixed at GR_WIDTH/8.
#
# The shading itself is the demo, and there is no shading model in it at
# all beyond one dot product.  A face pointing away from the light gets a
# probability dither of black against its colour; one facing it gets a
# dither of the colour against its bright twin, colour^8, which in the
# TempleOS palette is the same hue with the intensity bit flipped.  Two
# palette entries and a dither give a whole ramp.
#
# SLOP=0.03 is the original's, and its comment says why: "Gaps appear
# without this."  Each quad is grown very slightly past its neighbour so
# the seams do not show.
#
# TempleOS dithers by generating a random U16 per pixel and comparing it
# with dither_probability_u16.  It has to: the ramp it wants runs between
# two palette entries and the palette has nothing between them, so the
# colour is assembled out of pixels of the two.  This port used to stand
# in for that with an ordered 4x4 tile quantised to seventeen levels -
# the same trick with the noise taken out - and now does not stand in for
# anything, because grpalette(2) can produce the colour the dither was
# aiming at.  A face is filled with its shade.  The ramp is 65 steps
# rather than 17 because nothing forces it to sixteenths any more.
# GAP: the view angles come from a CTRLT_VIEWING_ANGLES control, one of
#      TempleOS's standard widgets.  Here the arrow keys turn the sphere
#      and it starts at that control's own default snap positions.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;
	Vector: import Draw3d;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Shading: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;
RINGS: con 8;
FACES: con 32;
SLOP: con 0.03;
GR_WIDTH: con 640;
LEVELS: con 65;			# steps of the ramp between two palette entries

BLUE: con 1;
RED: con 4;

win: ref Window;
d3c: ref Draw3d->Context;
font: ref Font;
ink: array of ref Image;
shade: array of array of ref Image;	# [colour][level]
ax, ay, az: real;
ms: Point;
haveMs := 0;
t0: int;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	# Prefer the protocol-backed provider: it hands geometry to the
	# device, and thence to Metal where the host has it, instead of
	# projecting and rasterizing in Limbo.  It falls back to its own
	# software paths by itself when the probe finds no device, so the
	# load below is only for the file being absent.
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	if(draw3d == nil){
		sys->fprint(sys->fildes(2), "shading: no draw3d: %r\n");
		return;
	}
	draw3d->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS Shading", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "/fonts/temple/temple.font");
	ink = array[16] of ref Image;
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
	buildshades(d, cols);
	# the control's own defaults: sx=2, sy=7, sz=6 snaps of pi/8
	ax = 2.0*PI/8.0;
	ay = 7.0*PI/8.0;
	az = 6.0*PI/8.0;
	t0 = sys->millisec();

	win.reshape(Rect((0, 0), (GR_WIDTH, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			continue;
		case k {
		Keyboard->Left =>	az -= PI/16.0;
		Keyboard->Right =>	az += PI/16.0;
		Keyboard->Up =>		ax -= PI/16.0;
		Keyboard->Down =>	ax += PI/16.0;
		* =>			exit;
		}
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img != nil){
			ms = Point(p.xy.x - img.r.min.x, p.xy.y - img.r.min.y);
			haveMs = 1;
		}
	<-ticks =>
		redraw();
	}
}

# One image per colour per level: the ramp the original's probability
# dither approximates, made directly.  Level 0 is the far end (black, or
# the colour itself) and level LEVELS-1 the near end (the colour, or its
# bright twin colour^8), exactly as the dither's probability runs.
buildshades(d: ref Display, cols: array of int)
{
	shade = array[16] of array of ref Image;
	for(c := 0; c < 16; c++){
		shade[c] = array[2*LEVELS] of ref Image;
		for(lvl := 0; lvl < LEVELS; lvl++){
			f := real lvl / real (LEVELS-1);
			# facing away: black towards the colour
			shade[c][lvl] = d.color(grpal->mix(cols[0], cols[c], f));
			# facing the light: the colour towards colour^8
			shade[c][LEVELS+lvl] = d.color(grpal->mix(cols[c], cols[c^8], f));
		}
	}
}

now(): real
{
	return real(sys->millisec() - t0) / 1000.0;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	cx := w/2;
	cy := h/2;
	tS := now();
	tt := 0.5*(math->sin(PI*2.0*math->fmod(tS, 10.0)/10.0) + 2.0);

	if(d3c == nil)
		d3c = draw3d->context(img);
	else
		draw3d->resize(d3c, img);
	draw3d->viewport(d3c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	draw3d->setz(d3c, 1);			# DCDepthBufAlloc
	draw3d->clearz(d3c);
	draw3d->setzclip(d3c, 0);
	draw3d->mode(Draw3d->MODEL);
	draw3d->identity();
	draw3d->scale(1.0, 1.0, -1.0);
	draw3d->rotatex((ax + PI)*180.0/PI);	# the later call is the outer one
	draw3d->rotatey(ay*180.0/PI);
	draw3d->rotatez(az*180.0/PI);
	draw3d->scale(tt, tt, tt);
	m := draw3d->newmatrix();
	draw3d->storematrix(m);
	draw3d->mode(Draw3d->PROJ);
	p := draw3d->newmatrix();
	p[0][0] = 1.0 / d3c.mx;
	p[1][1] = 1.0 / d3c.my;
	p[2][2] = 1.0;
	p[3][3] = 1.0;
	draw3d->loadmatrix(p);

	# the light: the cursor's offset from the centre, z = GR_WIDTH/8
	mp := ms;
	if(!haveMs)
		mp = Point(cx + 100, cy - 80);
	lx := -real(mp.x - cx);
	ly := -real(mp.y - cy);
	lz := real GR_WIDTH/8.0;
	d := math->sqrt(lx*lx + ly*ly + lz*lz);
	if(d == 0.0)
		d = 1.0;
	lx /= d; ly /= d; lz /= d;

	img.draw(img.r, ink[15], nil, Point(0, 0));
	radius := real(cy);
	if(cx < cy)
		radius = real(cx);
	radius /= 2.0;
	poly := array[3] of Vector;
	for(i := 0; i < RINGS; i++){
		th := real i * PI/2.0/real RINGS;
		th2 := real(i+1) * PI/2.0/real RINGS + SLOP;
		for(j := 0; j < FACES; j++){
			ph := real j * 2.0*PI/real FACES;
			ph2 := real(j+1) * 2.0*PI/real FACES + SLOP;
			half := 2.0*PI/real FACES/2.0;
			# upper half, two triangles, BLUE
			set(poly, 0, radius, th, ph);
			set(poly, 1, radius, th, ph2);
			set(poly, 2, radius, th2, ph + half);
			shadefill(m, poly, BLUE, lx, ly, lz);
			set(poly, 2, radius, th2, ph + half);
			set(poly, 1, radius, th2, ph2 + half);
			set(poly, 0, radius, th, ph2);
			shadefill(m, poly, BLUE, lx, ly, lz);
			# lower half, RED
			setn(poly, 2, radius, th, ph);
			setn(poly, 1, radius, th, ph2);
			setn(poly, 0, radius, th2, ph + half);
			shadefill(m, poly, RED, lx, ly, lz);
			setn(poly, 0, radius, th2, ph + half);
			setn(poly, 1, radius, th2, ph2 + half);
			setn(poly, 2, radius, th, ph2);
			shadefill(m, poly, RED, lx, ly, lz);
		}
	}
	if(font != nil)
		img.text(Point(o.x, img.r.max.y - font.height), ink[0], Point(0, 0),
			font, "Move mouse to change light source.  Arrows turn it; any other key exits.");
	img.flush(Draw->Flushnow);
}

set(p: array of Vector, i: int, r, th, ph: real)
{
	p[i] = Vector(r*math->cos(th)*math->cos(ph), r*math->cos(th)*math->sin(ph),
		r*math->sin(th));
}

setn(p: array of Vector, i: int, r, th, ph: real)
{
	p[i] = Vector(r*math->cos(th)*math->cos(ph), r*math->cos(th)*math->sin(ph),
		-r*math->sin(th));
}

# Lighting(), then the fill
shadefill(m: Draw3d->Matrix, poly: array of Vector, colour: int, lx, ly, lz: real)
{
	v1 := Vector(poly[0].x-poly[1].x, poly[0].y-poly[1].y, poly[0].z-poly[1].z);
	v2 := Vector(poly[2].x-poly[1].x, poly[2].y-poly[1].y, poly[2].z-poly[1].z);
	n := draw3d->vcross(v1, v2);
	d := math->sqrt(n.x*n.x + n.y*n.y + n.z*n.z);
	if(d == 0.0)
		return;
	n = Vector(n.x/d, n.y/d, n.z/d);
	# the normal goes through the same matrix the vertices do
	tn := draw3d->mulpoint(m, n);
	o := draw3d->mulpoint(m, Vector(0.0, 0.0, 0.0));
	tn = Vector(tn.x-o.x, tn.y-o.y, tn.z-o.z);
	dd := math->sqrt(tn.x*tn.x + tn.y*tn.y + tn.z*tn.z);
	if(dd != 0.0)
		tn = Vector(tn.x/dd, tn.y/dd, tn.z/dd);
	il := tn.x*lx + tn.y*ly + tn.z*lz;
	lvl := int(math->fabs(il) * real(LEVELS-1) + 0.5);
	if(lvl > LEVELS-1)
		lvl = LEVELS-1;
	if(il < 0.0)
		draw3d->setcolour(d3c, shade[colour][lvl]);
	else
		draw3d->setcolour(d3c, shade[colour][LEVELS+lvl]);
	draw3d->fillpoly3(d3c, poly, Vector(0.0,0.0,0.0), 1.0);
}

