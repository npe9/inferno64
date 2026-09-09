implement Rotatetank;

# TempleOS Demo/Graphics/RotateTank.HC — a mesh under four matrices.
#
#	DCDepthBufAlloc(dc); dc->flags|=DCF_TRANSFORMATION;
#	WinHorz(TEXT_COLS/2-12,TEXT_COLS/2+12);
#	WinVert(TEXT_ROWS/2-12,TEXT_ROWS/2+12);
#	while (!ScanChar) {
#	  DCDepthBufRst(dc);
#	  Mat4x4IdentEqu(dc->r);
#	  Mat4x4RotY(dc->r,0.25*Sin(tS/10*2*pi)+pi/2);
#	  Mat4x4RotX(dc->r,0.4*Sin(tS/5*2*pi));
#	  Mat4x4RotZ(dc->r,0.25*Sin(tS/10*2*pi)-pi/2);
#	  Mat4x4Scale(dc->r,0.25+Saw(tS,5));
#	  dc->x=pix_width/2; dc->y=pix_height/2; dc->z=GR_Z_ALL;
#	  Sprite3(dc,0,0,0,$IB,"<1>",BI=1$);
#	  Refresh; DCFill;
#	}
#
# Nothing but a mesh sprite and four matrix calls a frame.  The angles are
# sines of the wall clock rather than counters, so the motion is a slow
# rock rather than a spin: yaw and roll on a ten-second period a quarter
# radian either side of their pi/2 offsets, pitch on five seconds and
# nearly half a radian.  The scale is a sawtooth of period five, so the
# tank swells from a quarter size to one and a quarter and snaps back.
#
# dc->z=GR_Z_ALL is the original's note: it offsets the image in z so that
# no part is clipped by the plane of the screen.  The window is squared off
# to 24 by 24 character cells.

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

Rotatetank: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;
FW: con 8;
FH: con 8;
CELLS: con 24;			# WinHorz/WinVert: 24 cells square

Tri: adt { col, a, b, c: int; };
Mesh: adt { v: array of Vector; f: array of Tri; };

win: ref Window;
d3c: ref Draw3d->Context;
font: ref Font;
ink: array of ref Image;
mesh: ref Mesh;
t0: int;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	# Prefer the protocol-backed provider: it hands geometry to the
	# device, and thence to Metal where the host has it, instead of
	# projecting and rasterizing in Limbo.  It falls back to its own
	# software paths by itself when the probe finds no device, so the
	# load below is only for the file being absent.
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	if(draw3d == nil){
		sys->fprint(sys->fildes(2), "rotatetank: no draw3d: %r\n");
		return;
	}
	draw3d->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS RotateTank", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	ink = array[16] of ref Image;
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
	mesh = loadmesh("/icons/temple/rotatetank_1.mesh");
	t0 = sys->millisec();

	win.reshape(Rect((0, 0), (CELLS*FW, CELLS*FH)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 33);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	pointerev := <-win.ctxt.ptr =>
		# The titlebar is drawn by this window and only sees a click
		# if the program hands it one: without this arm the move,
		# resize and menu buttons on the window do nothing at all.
		win.pointer(*pointerev);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	<-ticks =>
		redraw();
	}
}

now(): real
{
	return real(sys->millisec() - t0) / 1000.0;
}

# Saw(t,period): a sawtooth rising 0 to 1 over each period
saw(t, period: real): real
{
	return math->fmod(t, period) / period;
}

redraw()
{
	img := win.image;
	if(img == nil || mesh == nil)
		return;
	tS := now();
	if(d3c == nil)
		d3c = draw3d->context(img);
	else
		draw3d->resize(d3c, img);
	draw3d->viewport(d3c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	draw3d->setz(d3c, 1);			# DCDepthBufAlloc
	draw3d->clearz(d3c);			# DCDepthBufRst
	draw3d->setzclip(d3c, 0);		# dc->z=GR_Z_ALL: nothing clipped

	draw3d->mode(Draw3d->MODEL);
	draw3d->identity();
	draw3d->scale(1.0, 1.0, -1.0);
	# the later Mat4x4 call is the outer one, so Scale is innermost
	draw3d->rotatez((0.25*math->sin(tS/10.0*2.0*PI) - PI/2.0)*180.0/PI);
	draw3d->rotatex((0.4*math->sin(tS/5.0*2.0*PI))*180.0/PI);
	draw3d->rotatey((0.25*math->sin(tS/10.0*2.0*PI) + PI/2.0)*180.0/PI);
	sc := 0.25 + saw(tS, 5.0);
	draw3d->scale(sc, sc, sc);
	draw3d->mode(Draw3d->PROJ);
	p := draw3d->newmatrix();
	p[0][0] = 1.0 / d3c.mx;
	p[1][1] = 1.0 / d3c.my;
	p[2][2] = 1.0;
	p[3][3] = 1.0;
	draw3d->loadmatrix(p);

	img.draw(img.r, ink[15], nil, Point(0, 0));	# DCFill
	tri := array[3] of Vector;
	nv := len mesh.v;
	for(i := 0; i < len mesh.f; i++){
		f := mesh.f[i];
		if(f.a >= nv || f.b >= nv || f.c >= nv)
			continue;
		tri[0] = mesh.v[f.a];
		tri[1] = mesh.v[f.b];
		tri[2] = mesh.v[f.c];
		draw3d->setcolour(d3c, ink[f.col & 15]);
		draw3d->fillpoly3(d3c, tri, Vector(0.0, 0.0, 0.0), 1.0);
	}
	img.flush(Draw->Flushnow);
}

loadmesh(path: string): ref Mesh
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[65536] of byte;
	n := 0;
	for(;;){
		r := sys->read(fd, buf[n:], len buf - n);
		if(r <= 0)
			break;
		n += r;
		if(n == len buf)
			break;
	}
	if(n <= 0)
		return nil;
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	if(lines == nil)
		return nil;
	(nil, h) := sys->tokenize(hd lines, " \t");
	if(len h != 3 || hd h != "mesh")
		return nil;
	nv := int hd tl h;
	nf := int hd tl tl h;
	m := ref Mesh(array[nv] of Vector, array[nf] of Tri);
	vi := 0;
	fi := 0;
	for(lines = tl lines; lines != nil; lines = tl lines){
		(nil, t) := sys->tokenize(hd lines, " \t\r");
		if(t == nil)
			continue;
		if(hd t == "v" && len t == 4 && vi < nv){
			t = tl t;
			x := real int hd t; t = tl t;
			y := real int hd t; t = tl t;
			m.v[vi++] = Vector(x, y, real int hd t);
		}else if(hd t == "f" && len t == 5 && fi < nf){
			t = tl t;
			c := int hd t; t = tl t;
			a := int hd t; t = tl t;
			b := int hd t; t = tl t;
			m.f[fi++] = Tri(c, a, b, int hd t);
		}
	}
	if(vi != nv || fi != nf)
		return nil;
	return m;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
