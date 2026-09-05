implement Box;

# TempleOS Demo/Graphics/Box.HC — software 3D wireframe (Limbo math)
#
# Faithful to the original: an orthographic ±100 cube (no perspective —
# GrLine3 under DCF_TRANSFORMATION is a pure matrix transform) anchored at
# dc->x,y = (200,200), drawn RED with thick=2 over the white DocClear page,
# tumbling with three independent ZXZ Euler angles and a breathing scale
# pulse, exiting on any key (while (!ScanChar)).

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Box: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# exact TempleOS palette entries used by the original
RED:	con int 16rAA0000FF;
WHITE:	con int 16rFFFFFFFF;

win: ref Window;
red, white: ref Image;

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
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Box", Wmclient->Appl);
	d := win.display;
	red = d.color(RED);
	white = d.color(WHITE);
	win.reshape(Rect((0, 0), (400, 400)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	# original loops Sleep(20) ≈ 50 fps with per-frame angle/scale steps;
	# we tick at the same 20 ms so the per-frame constants carry over 1:1
	ticks := chan of int;
	spawn timer(ticks, 20);
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
	<-ticks =>
		Pi: con Math->Pi;
		th1 += 2.0*Pi/70.0;
		th2 += 2.0*Pi/90.0;
		th3 += 2.0*Pi/110.0;
		s *= s1;
		if(!(s > 0.2 && s < 1.4))
			s1 = 1.0/s1;
		drawbox();
	}
}

drawbox()
{
	img := win.image;
	if(img == nil)
		return;
	# DocClear: white page background
	img.draw(img.r, white, nil, Point(0, 0));
	# dc->x,y = (200,200): fixed anchor, not window-centred
	cx := img.r.min.x + 200;
	cy := img.r.min.y + 200;

	c1 := math->cos(th1);	sn1 := math->sin(th1);
	c2 := math->cos(th2);	sn2 := math->sin(th2);
	c3 := math->cos(th3);	sn3 := math->sin(th3);

	# Mat4x4RotZ(θ1); Mat4x4RotX(θ2); Mat4x4RotZ(θ3); Mat4x4Scale(s):
	# orthographic — transform each ±100 vertex, keep x,y, no divide
	pts := array[8] of Point;
	i := 0;
	for(zz := -1; zz <= 1; zz += 2)
		for(yy := -1; yy <= 1; yy += 2)
			for(xx := -1; xx <= 1; xx += 2){
				x := 100.0 * real xx;
				y := 100.0 * real yy;
				z := 100.0 * real zz;
				# Rz(θ1)
				x1 := x*c1 - y*sn1;
				y1 := x*sn1 + y*c1;
				# Rx(θ2) — z' unused: orthographic drops z
				y2 := y1*c2 - z*sn2;
				# Rz(θ3)
				x3 := x1*c3 - y2*sn3;
				y3 := x1*sn3 + y2*c3;
				pts[i] = Point(cx+int(x3*s), cy+int(y3*s));
				i++;
			}
	edges := array[] of {
		(0,1),(1,3),(3,2),(2,0),
		(4,5),(5,7),(7,6),(6,4),
		(0,4),(1,5),(2,6),(3,7)
	};
	# dc->thick=2: Plan 9 line widths are odd (2r+1); radius 1 (3 px)
	# is the nearest that keeps the original's fat pen
	for(j := 0; j < len edges; j++){
		(a, b) := edges[j];
		img.line(pts[a], pts[b], Draw->Enddisc, Draw->Enddisc, 1, red, Point(0, 0));
	}
	img.flush(Draw->Flushnow);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
