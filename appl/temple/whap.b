implement Whap;

# TempleOS Demo/Games/Whap.HC — ODE base defense
# Mouse stretches ball0; protect cyan base from purple balls; any key quits
# GAP: the original's MenuPush File/Abort/Exit menu has no Inferno
# equivalent; any key (GetChar) exits, as in the original.

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

include "rand.m";
	rand: Rand;

include "ode.m";
	ode: Ode;
	ODE, Mass, Spring: import ode;

include "tone.m";
	tone: Tone;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

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
font: ref Font;
mx, my: int;
have_tone := 0;
collision_t := 0.0;	# last ball-ball collision time, seconds (debounce 0.05s)

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	ode = load Ode Ode->PATH;
	tone = load Tone Tone->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
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
	# the exact TempleOS 16-color palette, index = TempleOS color
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "/fonts/temple/temple.font");

	mx = 100; my = 100;
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	reset();

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
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
	<-win.ctxt.kbd =>
		exit;	# original: GetChar — any key exits
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
	collision_t = 0.0;
	cx := 320; cy := 240;
	img := win.image;
	if(img != nil){
		cx = img.r.dx()/2;
		cy = img.r.dy()/2;
	}
	balls = array[BALLS] of ref Mass;
	for(i := 0; i < BALLS; i++){
		m := ref Mass(0.0,0.0,0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 1.0, 0, i, real RADIUS, 0);
		if(i == 0){
			# original: balls[0] starts at the live mouse position
			m.x = real mx; m.y = real my;
		}else{
			# original: RandI16%500 (±499) around the window centre
			m.x = real(cx + rn(999) - 499);
			m.y = real(cy + rn(999) - 499);
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
				# original: Noise(50,102,105) at most every 0.05s
				t := real sys->millisec() / 1000.0;
				if(t - collision_t > 0.05){
					noise(50, 102, 105);
					collision_t = t;
				}
				d := math->sqrt(dd) + 0.0001;
				gap := rr*rr - dd;
				# original: 10.0*Sqr(Sqr(gap)) = 10*gap^4
				g2 := gap*gap; force := 10.0 * g2*g2;
				s := force / d;
				balls[j].fx += ddx*s; balls[j].fy += ddy*s;
				balls[i].fx -= ddx*s; balls[i].fy -= ddy*s;
			}
		}
	# walls on ball0
	if(img != nil){
		w := real img.r.dx();
		h := real img.r.dy();
		# original: Sqr(Sqr(Sqr(e))) = e^8
		d := balls[0].x;
		if(d - real RADIUS < 0.0){
			e := d - real RADIUS;
			balls[0].fx += p8(e);
		}
		if(d + real RADIUS > w){
			e := (d+real RADIUS) - w;
			balls[0].fx -= p8(e);
		}
		d = balls[0].y;
		if(d - real RADIUS < 0.0){
			e := d - real RADIUS;
			balls[0].fy += p8(e);
		}
		if(d + real RADIUS > h){
			e := (d+real RADIUS) - h;
			balls[0].fy -= p8(e);
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
	# original: GrPrint(dc,0,0,"Protect your base.") in BLACK
	if(font != nil)
		img.text(o, ink[0], Point(0, 0), font, "Protect your base.");
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
			tone->snd(onafreq(74));	# original: Snd(74)
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

p8(e: real): real	# Sqr(Sqr(Sqr(e))) = e^8
{
	e2 := e*e;
	e4 := e2*e2;
	return e4*e4;
}

onafreq(ona: int): int
{
	# TempleOS Snd(ona): freq = 440*2^((ona-60)/12)
	return int (440.0 * math->pow(2.0, real(ona-60)/12.0) + 0.5);
}

noise(ms, o1, o2: int)	# TempleOS Noise(ms,o1,o2): random pitch in ona range
{
	if(!have_tone)
		return;
	f1 := onafreq(o1);
	f2 := onafreq(o2);
	f := f1;
	if(f2 > f1)
		f = f1 + rn(f2-f1+1);
	tone->beep(f, ms);
}

