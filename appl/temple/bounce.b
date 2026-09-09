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
include "frameclock.m";
	fclock: Frameclock;

Bounce: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 1;
# The most substeps one frame may run: enough to cover a frame of
# real time at this step, with headroom.  A fixed cap is wrong -
# four substeps covers 40ms at FCSTEP 10 and only 4ms at FCSTEP 1.
FCMAX: con 2 + 20/FCSTEP;
fcacc := 0;

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
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
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
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q')
			exit;
	dtms := <-ticks =>
		fcacc += dtms;
		if(fcacc > FCSTEP*FCMAX)
			fcacc = FCSTEP*FCMAX;
		for(fcn := 0; fcacc >= FCSTEP && fcn < FCMAX; fcn++){
			step();
			fcacc -= FCSTEP;
		}
		flushnow();
	}
}

nsteps := 0;
t0 := 0;

step()
{
	if(t0 == 0)
		t0 = sys->millisec();
	nsteps++;
	if(sys->millisec()-t0 >= 3000){
		sys->print("bounce: %d steps in %d ms\n", nsteps, sys->millisec()-t0);
		bkillgrp();
	}
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
}

flushnow()
{
	img := win.image;
	if(img != nil)
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

bkillgrp()
{
	fd := sys->open("/prog/" + string sys->pctl(0, nil) + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
	exit;
}
