implement Poly3d;

# TempleOS Demo/Graphics/3DPoly.HC — filled polygons, a depth buffer and
# a mirror.
#
#	dc->flags|=DCF_TRANSFORMATION|DCF_SYMMETRY;
#	DCSymmetrySet(dc,pix_width/2,pix_height/2,ms.pos.x,ms.pos.y);
#	dc->color=LTBLUE;
#	GrLine(dc,pix_width/2,pix_height/2,ms.pos.x,ms.pos.y);
#	Mat4x4IdentEqu(dc->r); RotX(a); RotY(b); RotZ(c);
#	dc->x=pix_width/2; dc->y=pix_height/2; dc->z=500;
#	... five GrFillPoly3 quads ...
#	a+=2.1*pi/180; b+=1.1*pi/180; c+=0.5*pi/180;
#
# Three parallel quadrilaterals at z=0, z=50 and z=-50, in GREEN, RED and
# BLUE, plus two more joining them, dithered RED/GREEN and BLUE/GREEN so
# the connecting faces read as blends of the faces they join.  The whole
# thing tumbles on three rates — 2.1, 1.1 and 0.5 degrees a frame — which
# share no common factor, so it never repeats.
#
# The other half of the demo is DCF_SYMMETRY.  DCSymmetrySet takes two
# points — the centre of the window and the cursor — and everything drawn
# afterwards is also drawn reflected in the line through them, which the
# light blue line marks.  Move the mouse and the mirror swings.

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

Poly3d: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;

BLACK, BLUE, GREEN, CYAN, RED, PURPLE, BROWN, LTGRAY: con iota;
DKGRAY, LTBLUE, LTGREEN, LTCYAN, LTRED, LTPURPLE, YELLOW, WHITE: con iota + 8;

win: ref Window;
d3c: ref Draw3d->Context;
font: ref Font;
ink: array of ref Image;
dith: array of ref Image;	# the two dithered pens
a, b, c: real;
ms: Point;
haveMs := 0;

# the five quads, in the order and colours the original sets them
quads := array[] of {
	array[] of {50, 150, 0,  275, 100, 0,   155, 200, 0,   100, 200, 0},
	array[] of {50, 150, 50, 275, 100, 50,  155, 200, 50,  100, 200, 50},
	array[] of {50, 150,-50, 275, 100,-50,  155, 200,-50,  100, 200,-50},
	array[] of {50, 150, 50, 275, 100, 50,  275, 100, 0,    50, 150, 0},
	array[] of {100,200,-50, 155, 200,-50,  155, 200, 0,   100, 200, 0},
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	draw3d = load Draw3d Draw3d->PATH;
	if(draw3d == nil){
		sys->fprint(sys->fildes(2), "3dpoly: no draw3d: %r\n");
		return;
	}
	draw3d->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS 3DPoly", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	ink = array[16] of ref Image;
	cols := array[] of {
		int 16r000000FF, int 16r0000AAFF, int 16r00AA00FF, int 16r00AAAAFF,
		int 16rAA0000FF, int 16rAA00AAFF, int 16rAA5500FF, int 16rAAAAAAFF,
		int 16r555555FF, int 16r5555FFFF, int 16r55FF55FF, int 16r55FFFFFF,
		int 16rFF5555FF, int 16rFF55FFFF, int 16rFFFF55FF, int 16rFFFFFFFF
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
	# ROPF_DITHER of two palette entries: a 2x2 checkerboard, replicated
	dith = array[2] of ref Image;
	dith[0] = checker(d, cols[RED], cols[GREEN]);
	dith[1] = checker(d, cols[BLUE], cols[GREEN]);

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

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
		if(img != nil){
			ms = Point(p.xy.x - img.r.min.x, p.xy.y - img.r.min.y);
			haveMs = 1;
		}
	<-ticks =>
		redraw();
		a += 2.1*PI/180.0;
		b += 1.1*PI/180.0;
		c += 0.5*PI/180.0;
	}
}

checker(d: ref Display, c1, c2: int): ref Image
{
	im := d.newimage(Rect((0,0),(2,2)), Draw->RGB24, 1, c1);
	if(im == nil)
		return d.color(c1);
	a1 := d.color(c1);
	a2 := d.color(c2);
	im.draw(Rect((0,0),(1,1)), a1, nil, Point(0,0));
	im.draw(Rect((1,1),(2,2)), a1, nil, Point(0,0));
	im.draw(Rect((1,0),(2,1)), a2, nil, Point(0,0));
	im.draw(Rect((0,1),(1,2)), a2, nil, Point(0,0));
	return im;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, ink[WHITE], nil, Point(0, 0));
	cx := img.r.dx()/2;
	cy := img.r.dy()/2;
	mp := ms;
	if(!haveMs)
		mp = Point(cx + 120, cy - 60);

	# the mirror line DCSymmetrySet was given
	img.line(Point(o.x+cx, o.y+cy), Point(o.x+mp.x, o.y+mp.y),
		Draw->Endsquare, Draw->Endsquare, 0, ink[LTBLUE], Point(0, 0));

	setz(img);
	# DCF_SYMMETRY draws everything twice, the second time reflected in
	# the line through the two points.  Reflecting the model about the
	# plane that contains that line and the view axis gives the same
	# picture and keeps the depth buffer meaningful, which reflecting
	# finished pixels would not.
	for(pass := 0; pass < 2; pass++){
		setup3d(cx, cy, mp, pass);
		for(q := 0; q < len quads; q++){
			pen := ink[GREEN];
			if(q == 1) pen = ink[RED];
			else if(q == 2) pen = ink[BLUE];
			else if(q == 3) pen = dith[0];
			else if(q == 4) pen = dith[1];
			draw3d->setcolour(d3c, pen);
			verts := array[4] of Vector;
			for(i := 0; i < 4; i++)
				verts[i] = Vector(real quads[q][i*3] - real cx,
					real quads[q][i*3+1] - real cy,
					real quads[q][i*3+2]);
			draw3d->fillpoly3(d3c, verts, Vector(0.0,0.0,0.0), 1.0);
		}
	}
	if(font != nil)
		img.text(Point(o.x, img.r.max.y - font.height), ink[BLACK],
			Point(0, 0), font,
			"the mouse swings the mirror; any key exits");
	img.flush(Draw->Flushnow);
}

setz(img: ref Image)
{
	if(d3c == nil)
		d3c = draw3d->context(img);
	else
		draw3d->resize(d3c, img);
	draw3d->viewport(d3c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	draw3d->setz(d3c, 1);		# DCDepthBufAlloc
	draw3d->clearz(d3c);		# DCDepthBufRst, once a frame
	draw3d->setzclip(d3c, 0);
}

# dc->z=500 is the eye distance and TempleOS divides by it, so the
# projection is w = z + 500; the scale(1,1,-1) hands draw3d the eye space
# where a smaller model z is nearer, as TempleOS has it.
setup3d(cx, cy: int, mp: Point, mirror: int)
{
	draw3d->mode(Draw3d->MODEL);
	draw3d->identity();
	draw3d->scale(1.0, 1.0, -1.0);
	if(mirror)
		reflectmodel(cx, cy, mp);
	draw3d->rotatez(c*180.0/PI);	# the later Mat4x4 call is the outer one
	draw3d->rotatey(b*180.0/PI);
	draw3d->rotatex(a*180.0/PI);
	draw3d->mode(Draw3d->PROJ);
	draw3d->identity();
	draw3d->frustumoffset(500.0 / d3c.mx, 500.0 / d3c.my, 500.0);
}

# Reflect in the plane through the view axis and the line from the window
# centre to the cursor: I - 2nn^T with n the in-plane normal of that line.
reflectmodel(cx, cy: int, mp: Point)
{
	vx := real(mp.x - cx);
	vy := real(mp.y - cy);
	l := math->sqrt(vx*vx + vy*vy);
	if(l == 0.0)
		return;
	nx := -vy/l;
	ny := vx/l;
	m := draw3d->newmatrix();
	m[0][0] = 1.0 - 2.0*nx*nx;  m[0][1] = -2.0*nx*ny;
	m[1][0] = -2.0*nx*ny;       m[1][1] = 1.0 - 2.0*ny*ny;
	m[2][2] = 1.0;
	m[3][3] = 1.0;
	cur := draw3d->newmatrix();
	draw3d->storematrix(cur);
	draw3d->loadmatrix(mul(cur, m));
}

mul(a1, b1: Draw3d->Matrix): Draw3d->Matrix
{
	r := draw3d->newmatrix();
	for(i := 0; i < 4; i++)
		for(j := 0; j < 4; j++){
			v := 0.0;
			for(k := 0; k < 4; k++)
				v += a1[i][k]*b1[k][j];
			r[i][j] = v;
		}
	return r;
}

timer(ch: chan of int, ms1: int)
{
	for(;;){
		sys->sleep(ms1);
		ch <-= 1;
	}
}
