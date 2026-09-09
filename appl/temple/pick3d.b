implement Pick3d;

# TempleOS Demo/Graphics/Pick3D.HC — "a whimsical program which
# demonstrates some techniques".
#
#	class PCircle { PObj *p; I64 radius; };
#	class PLine   { PObj *p1,*p2; };
#	class PCSprite{ PObj *p; U8 *img; I64 *r,*dr; };
#	Init: 50 points at random; 20 circles of radius 6 on random points;
#	      20 lines between random pairs of points; 10 sprites on points,
#	      each with its own rotation matrix r and increment dr.
#	DrawIt, per sprite:
#	      r=Mat4x4MulMat4x4New(tmpo->g.dr,tmpo->g.r,task);
#	      Free(tmpo->g.r); tmpo->g.r=r;
#	      //Updated each refresh, not guarenteed to be uniform.
#	      //Rounding error might corrupt, as well.
#
# The technique is that nothing holds a coordinate except a point.  A
# circle is a pointer to a point and a radius; a line is two pointers; a
# sprite is a pointer, a picture and a matrix.  Drag one point and every
# circle, line and sprite hanging off it moves, with no update pass and
# no dependency list — the drawing simply reads through the pointer.
#
# The sprites turn because each keeps its own matrix and multiplies it by
# its own increment once per frame.  The original is candid that this is
# not a good idea: the step is whatever the refresh rate happened to be,
# and the rounding error accumulates in the matrix.  It is reproduced as
# written, increment and all.
#
# Picking is PPtFind: the nearest point by squared distance, no geometry.

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

include "rand.m";
	rand: Rand;

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;
	Vector: import Draw3d;
include "grpalette.m";
	grpal: Grpalette;

Pick3d: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;
BORDER: con 20;
PTS: con 50;
CIRCLES: con 20;
LINES: con 20;
SPRITES: con 10;
IMGS_NUM: con 3;

BLACK: con 0;
GREEN: con 2;
RED: con 4;
LTRED: con 12;

Tri: adt { col, a, b, c: int; };
Mesh: adt { v: array of Vector; f: array of Tri; };

win: ref Window;
d3c: ref Draw3d->Context;
font: ref Font;
ink: array of ref Image;
meshes: array of ref Mesh;

# every coordinate in the program lives here and nowhere else
ptx, pty: array of int;
circp: array of int;
circr: array of int;
linea, lineb: array of int;
sprp, sprimg: array of int;
sprr, sprdr: array of Draw3d->Matrix;
dragging := -1;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	# Prefer the protocol-backed provider: it hands geometry to the
	# device, and thence to Metal where the host has it, instead of
	# projecting and rasterizing in Limbo.  It falls back to its own
	# software paths by itself when the probe finds no device, so the
	# load below is only for the file being absent.
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	if(draw3d == nil){
		sys->fprint(sys->fildes(2), "pick3d: no draw3d: %r\n");
		return;
	}
	draw3d->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS Pick3D", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	ink = array[16] of ref Image;
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
	meshes = array[IMGS_NUM] of ref Mesh;
	for(i = 0; i < IMGS_NUM; i++)
		meshes[i] = loadmesh(sys->sprint("/icons/temple/pick3d_%d.mesh", i+1));

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	build();

	ticks := chan of int;
	spawn timer(ticks, 33);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img == nil)
			continue;
		cx := img.r.dx()/2;
		cy := img.r.dy()/2;
		x := p.xy.x - img.r.min.x - cx;
		y := p.xy.y - img.r.min.y - cy;
		if(p.buttons & 1){
			if(dragging < 0)
				dragging = ptfind(x, y);
			if(dragging >= 0){
				ptx[dragging] = x;
				pty[dragging] = y;
			}
		}else
			dragging = -1;
	<-ticks =>
		redraw();
	}
}

build()
{
	img := win.image;
	cx := 320;
	cy := 240;
	if(img != nil){
		cx = img.r.dx()/2;
		cy = img.r.dy()/2;
	}
	ptx = array[PTS] of int;
	pty = array[PTS] of int;
	for(i := 0; i < PTS; i++){
		ptx[i] = rn(2*(cx-BORDER)) - (cx-BORDER);
		pty[i] = rn(2*(cy-BORDER)) - (cy-BORDER);
	}
	circp = array[CIRCLES] of int;
	circr = array[CIRCLES] of int;
	for(i = 0; i < CIRCLES; i++){
		circp[i] = rn(PTS);
		circr[i] = 6;
	}
	linea = array[LINES] of int;
	lineb = array[LINES] of int;
	for(i = 0; i < LINES; i++){
		linea[i] = rn(PTS);
		lineb[i] = rn(PTS);
	}
	sprp = array[SPRITES] of int;
	sprimg = array[SPRITES] of int;
	sprr = array[SPRITES] of Draw3d->Matrix;
	sprdr = array[SPRITES] of Draw3d->Matrix;
	for(i = 0; i < SPRITES; i++){
		sprp[i] = rn(PTS);
		sprimg[i] = rn(IMGS_NUM);
		sprr[i] = ident();
		sprdr[i] = rotz(0.01 + rnreal()*0.06);
	}
}

ident(): Draw3d->Matrix
{
	m := draw3d->newmatrix();
	for(i := 0; i < 4; i++)
		m[i][i] = 1.0;
	return m;
}

rotz(a: real): Draw3d->Matrix
{
	m := ident();
	c := math->cos(a);
	s := math->sin(a);
	m[0][0] = c;  m[0][1] = -s;
	m[1][0] = s;  m[1][1] = c;
	return m;
}

mul(a, b: Draw3d->Matrix): Draw3d->Matrix
{
	r := draw3d->newmatrix();
	for(i := 0; i < 4; i++)
		for(j := 0; j < 4; j++){
			v := 0.0;
			for(k := 0; k < 4; k++)
				v += a[i][k]*b[k][j];
			r[i][j] = v;
		}
	return r;
}

# PPtFind: nearest point, squared distance, nothing else
ptfind(x, y: int): int
{
	best := 16r7FFFFFFF;
	res := -1;
	for(i := 0; i < PTS; i++){
		dd := (ptx[i]-x)*(ptx[i]-x) + (pty[i]-y)*(pty[i]-y);
		if(dd < best){
			best = dd;
			res = i;
		}
	}
	return res;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	cx := img.r.dx()/2;
	cy := img.r.dy()/2;
	img.draw(img.r, ink[15], nil, Point(0, 0));

	if(d3c == nil)
		d3c = draw3d->context(img);
	else
		draw3d->resize(d3c, img);
	draw3d->viewport(d3c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	draw3d->setz(d3c, 1);			# DCDepthBufAlloc
	draw3d->clearz(d3c);
	draw3d->setzclip(d3c, 0);
	draw3d->mode(Draw3d->PROJ);
	p := draw3d->newmatrix();
	p[0][0] = 1.0 / d3c.mx;
	p[1][1] = 1.0 / d3c.my;
	p[2][2] = 1.0;
	p[3][3] = 1.0;
	draw3d->loadmatrix(p);

	# GrBorder, thick 3
	for(t := 0; t < 3; t++)
		border(img, Rect((o.x+BORDER+t, o.y+BORDER+t),
			(o.x+2*cx-BORDER-t, o.y+2*cy-BORDER-t)), ink[LTRED]);

	# points: two crossed strokes
	for(i := 0; i < PTS; i++){
		x := o.x + cx + ptx[i];
		y := o.y + cy + pty[i];
		seg(img, x+2, y+2, x-2, y-2, ink[BLACK]);
		seg(img, x-2, y+2, x+2, y-2, ink[BLACK]);
	}
	# circles and lines, reading their points through the reference
	for(i = 0; i < CIRCLES; i++)
		img.ellipse(Point(o.x+cx+ptx[circp[i]], o.y+cy+pty[circp[i]]),
			circr[i], circr[i], 0, ink[RED], Point(0, 0));
	for(i = 0; i < LINES; i++)
		seg(img, o.x+cx+ptx[linea[i]], o.y+cy+pty[linea[i]],
			o.x+cx+ptx[lineb[i]], o.y+cy+pty[lineb[i]], ink[GREEN]);

	# sprites, each under its own accumulating matrix
	for(i = 0; i < SPRITES; i++){
		m := meshes[sprimg[i]];
		if(m == nil)
			continue;
		drawmesh(m, sprr[i], real(ptx[sprp[i]]), real(pty[sprp[i]]));
		# r = dr * r, once per refresh, as the original does it
		sprr[i] = mul(sprdr[i], sprr[i]);
	}

	if(font != nil)
		img.text(Point(o.x, img.r.max.y - font.height), ink[BLACK],
			Point(0, 0), font,
			"drag the nearest point; everything hanging off it follows.  Any key exits.");
	img.flush(Draw->Flushnow);
}

drawmesh(m: ref Mesh, r: Draw3d->Matrix, px, py: real)
{
	draw3d->mode(Draw3d->MODEL);
	draw3d->identity();
	draw3d->scale(1.0, 1.0, -1.0);
	draw3d->translate(px, py, 0.0);
	cur := draw3d->newmatrix();
	draw3d->storematrix(cur);
	draw3d->loadmatrix(mul(cur, r));
	tri := array[3] of Vector;
	nv := len m.v;
	for(i := 0; i < len m.f; i++){
		f := m.f[i];
		if(f.a >= nv || f.b >= nv || f.c >= nv)
			continue;
		tri[0] = m.v[f.a];
		tri[1] = m.v[f.b];
		tri[2] = m.v[f.c];
		draw3d->setcolour(d3c, ink[f.col & 15]);
		draw3d->fillpoly3(d3c, tri, Vector(0.0, 0.0, 0.0), 1.0);
	}
}

border(img: ref Image, r: Rect, col: ref Image)
{
	img.line(r.min, Point(r.max.x, r.min.y), Draw->Endsquare, Draw->Endsquare,
		0, col, Point(0,0));
	img.line(r.min, Point(r.min.x, r.max.y), Draw->Endsquare, Draw->Endsquare,
		0, col, Point(0,0));
	img.line(r.max, Point(r.max.x, r.min.y), Draw->Endsquare, Draw->Endsquare,
		0, col, Point(0,0));
	img.line(r.max, Point(r.min.x, r.max.y), Draw->Endsquare, Draw->Endsquare,
		0, col, Point(0,0));
}

seg(img: ref Image, x1, y1, x2, y2: int, col: ref Image)
{
	img.line(Point(x1, y1), Point(x2, y2), Draw->Endsquare, Draw->Endsquare,
		0, col, Point(0, 0));
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

rn(n: int): int
{
	if(n <= 0)
		return 0;
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

rnreal(): real
{
	if(rand == nil)
		return real(sys->millisec() & 1023) / 1023.0;
	return real(rand->rand(1000000)) / 1000000.0;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
