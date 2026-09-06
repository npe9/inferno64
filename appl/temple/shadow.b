implement Shadow;

# TempleOS Demo/Graphics/Shadow.HC — a shadow is the same model, sheared.
#
#	DrawShadow: Mat4x4IdentEqu(dc1->r); RotZ(a); RotX(b); RotZ(c);
#	            Mat4x4Scale(dc1->r,s);
#	            Mat4x4TranslationEqu(dc1->r,200,200,5000);
#	            MemSet(r,0,sizeof(r));
#	            r[0][0]=GR_SCALE;
#	            r[1][1]=GR_SCALE/2;   //Pick a plane for the shadow,
#	            r[1][2]=GR_SCALE/2;   //to suit your taste.  It doesn't
#	            r[2][2]=GR_SCALE;     //have to have a norm of 1.0.
#	            r[3][3]=GR_SCALE;
#	            Mat4x4TranslationEqu(r,0,-2200,1000);
#	            r2=Mat4x4MulMat4x4New(r,dc1->r,task);
#	            dc1->lighting=&GrBlackLighting;   // every face black
#	            Sprite3(dc1,0,0,0,$IB,"<1>",BI=1$);
#	DrawIt:     ... the same rotations into dc0 ... Sprite3(dc0,...)
#
# The shadow is not computed.  It is the model drawn a second time through
# one extra matrix that flattens y onto a plane — y' = (y+z)/2 — with a
# lighting function that returns black for every face, and sharing the
# first pass's depth buffer so it lands behind.  The original's own
# comment on the plane is "pick one to suit your taste; it doesn't have to
# have a norm of 1.0", and on the whole idea, "the shadow image b.s. Any
# is plausible."
#
# The three angles advance on 70, 90 and 110 frames of 20ms, which share
# no common factor, so the tumble never repeats.

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

Shadow: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;

Tri: adt { col, a, b, c: int; };
Mesh: adt { v: array of Vector; f: array of Tri; };

win: ref Window;
d3c: ref Draw3d->Context;
font: ref Font;
ink: array of ref Image;
mesh: ref Mesh;
alpha, beta, gamma: real;
scale := 1.5;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
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
	win = wmclient->window(ctxt, "TempleOS Shadow", Wmclient->Appl);
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
	mesh = loadmesh("/icons/temple/shadow_1.mesh");

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 20);		# the original's Sleep(20)
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	<-ticks =>
		redraw();
		alpha += 2.0*PI/70.0;
		beta += 2.0*PI/90.0;
		gamma += 2.0*PI/110.0;
	}
}

redraw()
{
	img := win.image;
	if(img == nil || mesh == nil)
		return;
	if(d3c == nil)
		d3c = draw3d->context(img);
	else
		draw3d->resize(d3c, img);
	draw3d->viewport(d3c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	draw3d->setz(d3c, 1);
	draw3d->clearz(d3c);		# DCDepthBufRst, once for both passes
	draw3d->setzclip(d3c, 0);
	draw3d->mode(Draw3d->PROJ);
	p := draw3d->newmatrix();
	# TempleOS divides by z and the model sits at z=5000
	p[0][0] = 5000.0 / d3c.mx;
	p[1][1] = 5000.0 / d3c.my;
	p[3][2] = -1.0;
	draw3d->loadmatrix(p);

	img.draw(img.r, ink[15], nil, Point(0, 0));
	# dc1 first, so the shadow is behind whatever the model covers;
	# both passes share one depth buffer, as the original shares it
	pass(1);
	pass(0);
	if(font != nil)
		img.text(Point(img.r.min.x, img.r.max.y - font.height), ink[1],
			Point(0, 0), font, "any key exits");
	img.flush(Draw->Flushnow);
}

# One Sprite3 through the model matrix; shadow == 1 adds the flattening
# matrix outside it and paints every face black.
pass(shadow: int)
{
	draw3d->mode(Draw3d->MODEL);
	draw3d->identity();
	draw3d->scale(1.0, 1.0, -1.0);
	if(shadow)
		shear();
	draw3d->translate(200.0, 200.0, 5000.0);
	draw3d->rotatez(gamma*180.0/PI);	# the later call is the outer one
	draw3d->rotatex(beta*180.0/PI);
	draw3d->rotatez(alpha*180.0/PI);
	draw3d->scale(scale, scale, scale);

	tri := array[3] of Vector;
	nv := len mesh.v;
	for(i := 0; i < len mesh.f; i++){
		f := mesh.f[i];
		if(f.a >= nv || f.b >= nv || f.c >= nv)
			continue;
		tri[0] = mesh.v[f.a];
		tri[1] = mesh.v[f.b];
		tri[2] = mesh.v[f.c];
		col := ink[f.col & 15];
		if(shadow)
			col = ink[0];		# GrBlackLighting
		draw3d->setcolour(d3c, col);
		draw3d->fillpoly3(d3c, tri, Vector(0.0, 0.0, 0.0), 1.0);
	}
}

# r[1][1]=r[1][2]=1/2 with the rest identity, translated (0,-2200,1000):
# y collapses to (y+z)/2, which is a plane to cast onto.
shear()
{
	m := draw3d->newmatrix();
	m[0][0] = 1.0;
	m[1][1] = 0.5;  m[1][2] = 0.5;
	m[2][2] = 1.0;
	m[3][3] = 1.0;
	m[0][3] = 0.0;  m[1][3] = -2200.0;  m[2][3] = 1000.0;
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
