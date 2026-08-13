implement Collision;

# TempleOS Demo/Games/Collision.HC — elastic ball collisions (float approx of fixed-point)

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

Collision: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

N: con 64;
R: con 5;

win: ref Window;
red, white: ref Image;
bx, by, vx, vy: array of real;

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

	win = wmclient->window(ctxt, "TempleOS Collision", Wmclient->Appl);
	d := win.display;
	red = d.color(Draw->Red);
	white = d.color(Draw->White);
	bx = array[N] of real;
	by = array[N] of real;
	vx = array[N] of real;
	vy = array[N] of real;
	for(i := 0; i < N; i++){
		bx[i] = real(40 + rn(560));
		by[i] = real(40 + rn(400));
		vx[i] = real(rn(11) - 5);
		vy[i] = real(rn(11) - 5);
		if(vx[i] == 0.0) vx[i] = 1.0;
		if(vy[i] == 0.0) vy[i] = 1.0;
	}
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 16);
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
		redraw();
	}
}

step()
{
	img := win.image;
	if(img == nil)
		return;
	w := real img.r.dx();
	h := real img.r.dy();
	rr := real(2*R);
	for(i := 0; i < N; i++){
		bx[i] += vx[i];
		by[i] += vy[i];
		if(bx[i] < real R){ bx[i] = real R; vx[i] = -vx[i]; }
		if(bx[i] >= w - real R){ bx[i] = w - real R; vx[i] = -vx[i]; }
		if(by[i] < real R){ by[i] = real R; vy[i] = -vy[i]; }
		if(by[i] >= h - real R){ by[i] = h - real R; vy[i] = -vy[i]; }
	}
	for(i = 0; i < N; i++)
		for(j := i+1; j < N; j++){
			dx := bx[i] - bx[j];
			dy := by[i] - by[j];
			dist2 := dx*dx + dy*dy;
			if(dist2 > 0.0 && dist2 <= rr*rr){
				dist := math->sqrt(dist2);
				nx := dx / dist;
				ny := dy / dist;
				# relative velocity along normal
				dvx := vx[i] - vx[j];
				dvy := vy[i] - vy[j];
				vn := dvx*nx + dvy*ny;
				if(vn < 0.0){
					# exchange normal components (equal mass)
					vx[i] -= vn * nx;
					vy[i] -= vn * ny;
					vx[j] += vn * nx;
					vy[j] += vn * ny;
				}
				# separate overlap
				overlap := (rr - dist) / 2.0;
				bx[i] += overlap * nx;
				by[i] += overlap * ny;
				bx[j] -= overlap * nx;
				by[j] -= overlap * ny;
			}
		}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, white, nil, Point(0, 0));
	o := img.r.min;
	for(i := 0; i < N; i++)
		img.ellipse(Point(int bx[i], int by[i]).add(o), R, R, 0, red, Point(0, 0));
	img.flush(Draw->Flushnow);
}

rn(n: int): int
{
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
