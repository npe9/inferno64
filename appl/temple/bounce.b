implement Bounce;

# TempleOS Demo/Graphics/Bounce.HC — Wmclient+Draw
# 16 fixed-point-style bouncing dots; q/Esc quit

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

include "rand.m";
	rand: Rand;

Bounce: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

N: con 16;
# position/velocity in 16.16 fixed point
x, y, dx, dy: array of int;
win: ref Window;
ink: array of ref Image;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Bounce", Wmclient->Appl);
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

	x = array[N] of int;
	y = array[N] of int;
	dx = array[N] of int;
	dy = array[N] of int;
	for(i = 0; i < N; i++){
		x[i] = y[i] = 0;
		ang := (real rn(360)) * Math->Pi / 180.0;
		# ~I32_MAX scale like TempleOS; use smaller so motion is visible
		spd := 1<<16;
		dx[i] = int(math->cos(ang) * real spd);
		dy[i] = int(math->sin(ang) * real spd);
	}

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	if(win.image != nil)
		win.image.draw(win.image.r, ink[0], nil, Point(0, 0));

	ticks := chan of int;
	spawn timer(ticks, 1);
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
	w := img.r.dx() << 16;
	h := img.r.dy() << 16;
	o := img.r.min;
	for(i := 0; i < N; i++){
		px := x[i] >> 16;
		py := y[i] >> 16;
		img.draw(Rect((o.x+px, o.y+py), (o.x+px+1, o.y+py+1)), ink[i], nil, Point(0, 0));
		x[i] += dx[i];
		y[i] += dy[i];
		if(x[i] < 0 || x[i] >= w){
			x[i] -= dx[i];
			dx[i] = -dx[i];
		}
		if(y[i] < 0 || y[i] >= h){
			y[i] -= dy[i];
			dy[i] = -dy[i];
		}
	}
	img.flush(Draw->Flushnow);
}

rn(n: int): int
{
	if(n <= 0)
		return 0;
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
