implement Spriteplot3d;

# TempleOS Demo/Graphics/SpritePlot3D.HC — a mesh sprite under a matrix.
#
#	DrawIt: dc->x=200; dc->y=200; dc->z=GR_Z_ALL;
#	        dc->flags|=DCF_TRANSFORMATION;
#	        DCDepthBufAlloc(dc);
#	        DCMat4x4Set(dc,glbl_r);
#	        DCDepthBufRst(dc);
#	        Sprite3(dc,0,0,0,$IB,"<1>",BI=1$);
#	loop:   Mat4x4IdentEqu(glbl_r);
#	        Mat4x4RotX(glbl_r,theta);
#	        Mat4x4RotZ(glbl_r,phi);
#	        Sleep(40);
#	        theta+=2*pi/100; phi+=2*pi/130;
#
# The two rates are deliberately incommensurate — 100 and 130 frames a
# turn — so the model never repeats an attitude, which is what makes a
# static mesh worth watching.  The rotations compose as Rz(phi)*Rx(theta)
# because the later call is the outer one, and Sprite3 draws with no
# perspective, so this is an orthographic pass with draw3d(2)'s z-buffer
# standing in for DCDepthBufAlloc; the scale(1,1,-1) hands it the eye
# space where a smaller sprite z is nearer, as TempleOS has it.

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

Spriteplot3d: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;
MESH: con "/icons/temple/spriteplot3d_1.mesh";

Tri: adt { col, a, b, c: int; };
Mesh: adt { v: array of Vector; f: array of Tri; };

win: ref Window;
d3c: ref Draw3d->Context;
font: ref Font;
ink: array of ref Image;
mesh: ref Mesh;
theta, phi: real;

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
		sys->fprint(sys->fildes(2), "spriteplot3d: no draw3d: %r\n");
		return;
	}
	draw3d->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS SpritePlot3D", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	ink = array[16] of ref Image;
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
	mesh = loadmesh(MESH);

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);	# 60fps: the original's Sleep(40)
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
		theta += 2.0*PI/100.0;
		phi += 2.0*PI/130.0;
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, ink[15], nil, Point(0, 0));
	setup3d(img);
	drawmesh(img);
	if(font != nil)
		img.text(Point(img.r.min.x, img.r.max.y - font.height), ink[1],
			Point(0, 0), font,
			"RotX every 100 frames, RotZ every 130 — it never repeats.  Any key.");
	img.flush(Draw->Flushnow);
}

# dc->x=200, dc->y=200, no perspective: an orthographic pass placed at
# (200,200) with one world unit to the pixel.
setup3d(img: ref Image)
{
	if(d3c == nil)
		d3c = draw3d->context(img);
	else
		draw3d->resize(d3c, img);
	draw3d->viewport(d3c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	draw3d->setz(d3c, 1);
	draw3d->clearz(d3c);
	draw3d->setzclip(d3c, 0);
	draw3d->mode(Draw3d->MODEL);
	draw3d->identity();
	draw3d->scale(1.0, 1.0, -1.0);
	draw3d->translate(200.0 - real(img.r.dx()/2), 200.0 - real(img.r.dy()/2), 0.0);
	draw3d->rotatez(phi*180.0/PI);		# the later Mat4x4 call is outermost
	draw3d->rotatex(theta*180.0/PI);
	draw3d->mode(Draw3d->PROJ);
	p := draw3d->newmatrix();
	p[0][0] = 1.0 / d3c.mx;
	p[1][1] = 1.0 / d3c.my;
	p[2][2] = 1.0;
	p[3][3] = 1.0;
	draw3d->loadmatrix(p);
}

drawmesh(nil: ref Image)
{
	if(mesh == nil)
		return;
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

