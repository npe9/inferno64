implement Rocketscience;

# TempleOS Demo/Games/RocketScience.HC — guided ODE rocket vs plane
# GAP: no Sprite3ZB / PopUp antispin — fixed coeff; shapes as lines/ellipses
# space=launch  Enter=restart  q=quit

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

include "ode.m";
	ode: Ode;
	ODE, Mass, Spring: import ode;

include "tone.m";
	tone: Tone;

include "rand.m";
	rand: Rand;

Rocketscience: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

THRUST: con 1000.0;
RH: con 40.0;
PI: con 3.141592653589793;

win: ref Window;
sim: ref ODE;
ink: array of ref Image;
m1, m2, m3: ref Mass;	# bottom, top, plane
blastoff := 0;
planehit := 0;
nozzle := 0.0;
nozzle_v := 0.0;
antispin := 1.0;
dbg := 0.0;
tx, ty: real;
have_tone := 0;
groundy := 400;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	ode = load Ode Ode->PATH;
	tone = load Tone Tone->PATH;
	rand = load Rand Rand->PATH;
	if(ode == nil){
		sys->fprint(sys->fildes(2), "rocketscience: no ode\n");
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

	win = wmclient->window(ctxt, "TempleOS RocketScience", Wmclient->Appl);
	d := win.display;
	ink = array[8] of ref Image;
	ink[0] = d.color(Draw->Black);
	ink[1] = d.color(Draw->Red);
	ink[2] = d.color(Draw->Blue);
	ink[3] = d.color(Draw->Yellow);
	ink[4] = d.color(Draw->Cyan);
	ink[5] = d.color(Draw->White);
	ink[6] = d.color(Draw->Green);
	ink[7] = d.color(int 16r87CEEBFF);

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
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			exit;
		' ' =>
			blastoff = 1;
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
	sim.h = 0.002;
	blastoff = 0;
	planehit = 0;
	nozzle = 0.0;
	nozzle_v = 0.0;
	antispin = 1.0;
	# TempleOS y-up; we use y-down screen, so invert gravity/thrust signs carefully.
	# Keep physics in screen coords: +y down. Rocket points "up" = -y.
	m1 = ref Mass(0.0, 0.0, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 1.0, 0, 0, 4.0, 0);
	m2 = ref Mass(0.0, -RH, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 1.0, 0, 0, 4.0, 0);
	m3 = ref Mass(-300.0, -400.0, 0.0, 50.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 1.0, 0, 0, 8.0, 0);
	ode->addmass(sim, m1);
	ode->addmass(sim, m2);
	ode->addmass(sim, m3);
	s := ref Spring(m1, m2, 10000.0, RH, 0.0, 0.0, 0, 0, 0);
	ode->addspring(sim, s);
}

wrapang(a: real): real
{
	while(a >= PI) a -= 2.0*PI;
	while(a < -PI) a += 2.0*PI;
	return a;
}

clamp(v, lo, hi: real): real
{
	if(v < lo) return lo;
	if(v > hi) return hi;
	return v;
}

step()
{
	ode->clearforces(sim);
	# heading from bottom to top
	dx := m2.x - m1.x;
	dy := m2.y - m1.y;
	th := math->atan2(dy, dx);
	# body unit
	blen := math->sqrt(dx*dx + dy*dy);
	if(blen < 0.001) blen = 0.001;
	bx := dx / blen;
	by := dy / blen;
	# antispin damping of angular rate
	dth := antispin * (m2.vy*bx - m2.vx*by - m1.vy*bx + m1.vx*by) / RH;
	# aim at plane projected impact
	ptx := m3.x - m2.x;
	pty := m3.y - m2.y;
	d := math->sqrt(ptx*ptx + pty*pty);
	if(d < 0.001) d = 0.001;
	ux := ptx / d;
	uy := pty / d;
	v := (m2.vx*ux + m2.vy*uy) - (m3.vx*ux + m3.vy*uy);
	a := THRUST / (m1.mass + m2.mass);
	disc := v*v + 2.0*a*d;
	tcol := 0.0;
	if(disc > 0.0)
		tcol = (-v + math->sqrt(disc)) / a;
	dbg = tcol;
	# predicted plane pos
	predx := m3.x + m3.vx * tcol;
	predy := m3.y + m3.vy * tcol;
	aimx := predx - m2.x;
	aimy := predy - m2.y;
	tx = predx; ty = predy;
	thead := math->atan2(aimy, aimx);
	terr := wrapang(th - thead);
	want := clamp(50.0*dth + 750.0*terr, -PI/8.0, PI/8.0);
	# nozzle dynamics
	accn := clamp(10000.0*(want - nozzle), -1000.0, 1000.0) - 10.0*nozzle_v;
	nozzle_v += accn * 0.016;
	nozzle += nozzle_v * 0.016;

	if(blastoff){
		ang := th + nozzle;
		m1.fx += THRUST * math->cos(ang);
		m1.fy += THRUST * math->sin(ang);
		# gravity (+y down): in TempleOS was -25 on DyDt with y-up → +25 here
		m1.fy += 25.0 * m1.mass;
		m2.fy += 25.0 * m2.mass;
	}
	ode->update(sim, 0.016);

	# hit test rocket mid vs plane
	if(blastoff && !planehit){
		mx := (m1.x + m2.x)/2.0;
		my := (m1.y + m2.y)/2.0;
		dd := (mx-m3.x)*(mx-m3.x) + (my-m3.y)*(my-m3.y);
		if(dd < 25.0*25.0){
			planehit = 1;
			if(have_tone)
				tone->beep(80, 200);
		}else if(have_tone)
			tone->beep(22, 30);
	}
}

w2s(x, y: real): Point
{
	img := win.image;
	cx := 320;
	cy := groundy;
	if(img != nil){
		cx = img.r.dx()/2;
		cy = img.r.dy() - 60;
		groundy = cy;
	}
	return Point(cx + int x, cy + int y);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, ink[7], nil, Point(0, 0));
	# ground
	gy := groundy;
	img.draw(Rect((o.x, o.y+gy), (o.x+img.r.dx(), o.y+img.r.dy())), ink[6], nil, Point(0, 0));

	p1 := w2s(m1.x, m1.y).add(o);
	p2 := w2s(m2.x, m2.y).add(o);
	p3 := w2s(m3.x, m3.y).add(o);
	pt := w2s(tx, ty).add(o);

	if(blastoff){
		th := math->atan2(m2.y-m1.y, m2.x-m1.x);
		nx := m1.x - 10.0*math->cos(th+nozzle);
		ny := m1.y - 10.0*math->sin(th+nozzle);
		pn := w2s(nx, ny).add(o);
		img.line(p1, pn, 0, 0, 1, ink[3], Point(0, 0));
		img.line(p1, pn, 0, 0, 0, ink[1], Point(0, 0));
	}
	# rocket body
	img.line(p1, p2, 0, 0, 2, ink[0], Point(0, 0));
	img.fillellipse(p1, 3, 3, ink[0], Point(0, 0));
	img.fillellipse(p2, 3, 3, ink[1], Point(0, 0));
	# plane
	col := ink[2];
	if(planehit)
		col = ink[1];
	img.fillellipse(p3, 10, 4, col, Point(0, 0));
	img.ellipse(pt, 5, 5, 0, ink[1], Point(0, 0));
	img.ellipse(p3, 5, 5, 0, ink[2], Point(0, 0));
	img.flush(Draw->Flushnow);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
