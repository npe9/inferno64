implement Massspring;

# TempleOS Demo/Games/MassSpring.HC — uses /dis/lib/ode.dis
# LMB place mass; RMB-drag connect spring; Enter restart; q quit

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

Massspring: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
sim: ref ODE;
red, black, white: ref Image;
drag1: ref Mass;
lastl := 0;
lastr := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	ode = load Ode Ode->PATH;
	if(ode == nil){
		sys->fprint(sys->fildes(2), "massspring: cannot load %s: %r\n", Ode->PATH);
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	ode->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS MassSpring", Wmclient->Appl);
	d := win.display;
	red = d.color(Draw->Red);
	black = d.color(Draw->Black);
	white = d.color(Draw->White);

	reset();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 16);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			exit;
		'\n' =>
			reset();
		}
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
	drag1 = nil;
	lastl = 0;
	lastr = 0;
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	x := real(p.xy.x - img.r.min.x);
	y := real(p.xy.y - img.r.min.y);
	left := (p.buttons & 1) != 0;
	right := (p.buttons & 2) != 0;

	if(left && !lastl)
		place_mass(x, y);
	if(right && !lastr)
		drag1 = ode->massfind(sim, x, y, 0.0);
	if(!right && lastr){
		if(drag1 != nil){
			m2 := ode->massfind(sim, x, y, 0.0);
			if(m2 != nil && m2 != drag1)
				place_spring(drag1, m2);
		}
		drag1 = nil;
	}
	lastl = left;
	lastr = right;
}

place_mass(x, y: real)
{
	m := ref Mass(
		x, y, 0.0,
		0.0, 0.0, 0.0,
		0.0, 0.0, 0.0,
		1.0,
		100.0,
		0,
		0,
		10.0 * (rnreal() + 0.25),
		0
	);
	ode->addmass(sim, m);
}

place_spring(a, b: ref Mass)
{
	s := ref Spring(a, b, 10000.0, 100.0, 0.0, 0.0, 0, 0, 0);
	ode->addspring(sim, s);
}

step()
{
	ode->clearforces(sim);
	for(l1 := sim.masses; l1 != nil; l1 = tl l1){
		m1 := hd l1;
		for(l2 := tl l1; l2 != nil; l2 = tl l2){
			m2 := hd l2;
			dx := m2.x - m1.x;
			dy := m2.y - m1.y;
			dz := m2.z - m1.z;
			dd := dx*dx + dy*dy + dz*dz;
			rr := m1.radius + m2.radius;
			if(dd <= rr*rr){
				d := math->sqrt(dd) + 0.0001;
				gap := rr*rr - dd;
				g2 := gap*gap;
				g4 := g2*g2;
				g8 := g4*g4;
				force := 10.0 * g8;
				scale := force / d;
				fx := dx * scale;
				fy := dy * scale;
				fz := dz * scale;
				m2.fx += fx; m2.fy += fy; m2.fz += fz;
				m1.fx -= fx; m1.fy -= fy; m1.fz -= fz;
			}
		}
	}
	ode->update(sim, 0.016);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, white, nil, Point(0, 0));
	o := img.r.min;
	for(ls := sim.springs; ls != nil; ls = tl ls){
		s := hd ls;
		if(s.end1 == nil || s.end2 == nil)
			continue;
		img.line(
			Point(int s.end1.x, int s.end1.y).add(o),
			Point(int s.end2.x, int s.end2.y).add(o),
			Draw->Endsquare, Draw->Endsquare, 0, red, Point(0, 0));
	}
	for(lm := sim.masses; lm != nil; lm = tl lm){
		m := hd lm;
		r := int m.radius;
		if(r < 2)
			r = 2;
		img.ellipse(Point(int m.x, int m.y).add(o), r, r, 0, black, Point(0, 0));
	}
	img.flush(Draw->Flushnow);
}

rnreal(): real
{
	if(rand == nil)
		return real(sys->millisec() & 255) / 255.0;
	return real(rand->rand(1000)) / 1000.0;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
