implement Whap;

# TempleOS Demo/Games/Whap.HC — ODE base defense
# Mouse stretches ball0; protect cyan base from purple balls; q quit

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

include "ode.m";
	ode: Ode;
	ODE, Mass, Spring: import ode;

include "tone.m";
	tone: Tone;

Whap: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

BALLS: con 7;
RADIUS: con 5;
BASE: con 10;
STRETCH: con 500.0;
GRAVITY: con 50.0;

win: ref Window;
sim: ref ODE;
balls: array of ref Mass;
ink: array of ref Image;
mx, my: int;
have_tone := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	ode = load Ode Ode->PATH;
	tone = load Tone Tone->PATH;
	if(ode == nil){
		sys->fprint(sys->fildes(2), "whap: no ode: %r\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	ode->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Whap", Wmclient->Appl);
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

	reset();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	mx = 100; my = 100;

	ticks := chan of int;
	spawn timer(ticks, 16);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img != nil){
			mx = p.xy.x - img.r.min.x;
			my = p.xy.y - img.r.min.y;
		}
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q')
			exit;
		if(k == '\n')
			reset();
	<-ticks =>
		step();
		redraw();
	}
}

reset()
{
	sim = ode->new();
	sim.drag_v2 = 0.002;
	sim.drag_v3 = 0.00001;
	sim.accel_limit = 5000.0;
	sim.h = 0.01;
	balls = array[BALLS] of ref Mass;
	for(i := 0; i < BALLS; i++){
		m := ref Mass(0.0,0.0,0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 1.0, 0, i, real RADIUS, 0);
		if(i == 0){
			m.x = 100.0; m.y = 100.0;
		}else{
			m.x = real(320 + rn(400) - 200);
			m.y = real(240 + rn(400) - 200);
		}
		balls[i] = m;
		ode->addmass(sim, m);
	}
	balls[2].x = balls[1].x + 15.0;
	balls[2].y = balls[1].y;
	balls[3].x = balls[1].x;
	balls[3].y = balls[1].y + 15.0;
	addspring(balls[1], balls[2], 15.0);
	addspring(balls[1], balls[3], 15.0);
	addspring(balls[2], balls[3], 15.0*1.41421356);
}

addspring(a, b: ref Mass, rest: real)
{
	ode->addspring(sim, ref Spring(a, b, 10000.0, rest, 0.0, 0.0, 0, 0, 0));
}

step()
{
	ode->clearforces(sim);
	# mouse stretch on ball0
	dx := real mx - balls[0].x;
	dy := real my - balls[0].y;
	balls[0].fx += dx * STRETCH;
	balls[0].fy += dy * STRETCH;

	img := win.image;
	cx := 320.0; cy := 240.0;
	if(img != nil){
		cx = real(img.r.dx()/2);
		cy = real(img.r.dy()/2);
	}
	for(i := 1; i < BALLS; i++){
		px := cx - balls[i].x;
		py := cy - balls[i].y;
		d := math->sqrt(px*px + py*py);
		if(d > 0.0){
			balls[i].fx += px * (GRAVITY / d);
			balls[i].fy += py * (GRAVITY / d);
		}
	}
	# soft collisions
	rr := real(2*RADIUS);
	for(i = 0; i < BALLS; i++)
		for(j := i+1; j < BALLS; j++){
			ddx := balls[j].x - balls[i].x;
			ddy := balls[j].y - balls[i].y;
			dd := ddx*ddx + ddy*ddy;
			if(dd <= rr*rr){
				d := math->sqrt(dd) + 0.0001;
				gap := rr*rr - dd;
				g2 := gap*gap; g4 := g2*g2; force := 10.0 * g4*g4;
				s := force / d;
				balls[j].fx += ddx*s; balls[j].fy += ddy*s;
				balls[i].fx -= ddx*s; balls[i].fy -= ddy*s;
			}
		}
	# walls on ball0
	if(img != nil){
		w := real img.r.dx();
		h := real img.r.dy();
		d := balls[0].x;
		if(d - real RADIUS < 0.0){
			e := d - real RADIUS;
			balls[0].fx += e*e*e*e*e*e; # Sqr^3
		}
		if(d + real RADIUS > w){
			e := (d+real RADIUS) - w;
			balls[0].fx -= e*e*e*e*e*e;
		}
		d = balls[0].y;
		if(d - real RADIUS < 0.0){
			e := d - real RADIUS;
			balls[0].fy += e*e*e*e*e*e;
		}
		if(d + real RADIUS > h){
			e := (d+real RADIUS) - h;
			balls[0].fy -= e*e*e*e*e*e;
		}
	}
	ode->update(sim, 0.016);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, ink[15], nil, Point(0, 0));
	o := img.r.min;
	cx := img.r.dx()/2;
	cy := img.r.dy()/2;
	# base
	img.draw(Rect((o.x+cx-BASE, o.y+cy-BASE), (o.x+cx+BASE, o.y+cy+BASE)), ink[0], nil, Point(0, 0));
	img.draw(Rect((o.x+cx-BASE+2, o.y+cy-BASE+2), (o.x+cx+BASE-2, o.y+cy+BASE-2)), ink[3], nil, Point(0, 0));
	# mouse line
	img.line(Point(int balls[0].x, int balls[0].y).add(o), Point(mx, my).add(o),
		0, 0, 0, ink[14], Point(0, 0));
	for(ls := sim.springs; ls != nil; ls = tl ls){
		s := hd ls;
		img.line(Point(int s.end1.x, int s.end1.y).add(o),
			Point(int s.end2.x, int s.end2.y).add(o), 0, 0, 0, ink[14], Point(0, 0));
	}
	snd_on := 0;
	for(i := 0; i < BALLS; i++){
		col := ink[11];
		if(i != 0)
			col = ink[13];
		img.fillellipse(Point(int balls[i].x, int balls[i].y).add(o), RADIUS, RADIUS, col, Point(0, 0));
		img.ellipse(Point(int balls[i].x, int balls[i].y).add(o), RADIUS, RADIUS, 0, ink[0], Point(0, 0));
		if(i != 0 &&
		   balls[i].x >= real(cx-BASE-RADIUS) && balls[i].x <= real(cx+BASE+RADIUS) &&
		   balls[i].y >= real(cy-BASE-RADIUS) && balls[i].y <= real(cy+BASE+RADIUS))
			snd_on = 1;
	}
	if(have_tone){
		if(snd_on)
			tone->snd(74*8);
		else
			tone->stop();
	}
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
