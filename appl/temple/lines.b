implement Lines;

# TempleOS Demo/Graphics/Lines.HC — stock Inferno Wmclient+Draw port

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "rand.m";
	rand: Rand;

Lines: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
ink: array of ref Image;
x1, y1, x2, y2: int;
vx1, vy1, vx2, vy2: int;
color := 0;
left := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Lines", Wmclient->Appl);
	d := win.display;
	ink = array[16] of ref Image;
	cols := array[] of {
		Draw->Black, Draw->Blue, Draw->Green, Draw->Cyan,
		Draw->Red, Draw->Magenta, Draw->Darkyellow, Draw->Grey,
		int 16r444444FF, Draw->Paleblue, Draw->Palegreen, Draw->Palebluegreen,
		int 16rFF8888FF, int 16rFF88FFFF, Draw->Yellow, Draw->White
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	if(win.image != nil)
		win.image.draw(win.image.r, ink[0], nil, Point(0, 0));

	x1 = y1 = x2 = y2 = 0;
	vx1 = vy1 = vx2 = vy2 = 0;
	ticks := chan of int;
	spawn timer(ticks, 10);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q')
			exit;
	<-ticks =>
		step();
	}
}

step()
{
	img := win.image;
	if(img == nil)
		return;
	if(--left <= 0){
		left = 1000;
		color = (color + 1) & 15;
	}
	img.line(Point(x1, y1), Point(x2, y2), Draw->Endsquare, Draw->Endsquare, 0, ink[color], Point(0, 0));
	vx1 = clamp(vx1 + sign(randn()), -5, 5);
	vy1 = clamp(vy1 + sign(randn()), -5, 5);
	vx2 = clamp(vx2 + sign(randn()), -5, 5);
	vy2 = clamp(vy2 + sign(randn()), -5, 5);
	x1 = clamp(x1 + vx1, 0, img.r.dx() - 1);
	y1 = clamp(y1 + vy1, 0, img.r.dy() - 1);
	x2 = clamp(x2 + vx2, 0, img.r.dx() - 1);
	y2 = clamp(y2 + vy2, 0, img.r.dy() - 1);
	img.flush(Draw->Flushnow);
}

randn(): int
{
	if(rand == nil)
		return sys->millisec();
	return rand->rand(16r7fffffff);
}

sign(v: int): int
{
	if(v & 1)
		return 1;
	return -1;
}

clamp(v, lo, hi: int): int
{
	if(v < lo)
		return lo;
	if(v > hi)
		return hi;
	return v;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
