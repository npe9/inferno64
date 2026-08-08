implement Squirt;

# TempleOS Demo/Games/Squirt.HC — ODE hose + droplets
# GAP: no sprites / GrFillPoly3 hose mesh — thick lines + circles; no song loop
# arrows move nozzle  Enter=restart  q=quit

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

include "keyboard.m";

include "rand.m";
	rand: Rand;

include "ode.m";
	ode: Ode;
	ODE, Mass, Spring: import ode;

include "tone.m";
	tone: Tone;

Squirt: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MT_HOSE, MT_DROP: con iota;
HOSE_R: con 3.0;
LINK: con 6;
NOZZLE_LEN: con 18.0;

win: ref Window;
sim: ref ODE;
ink: array of ref Image;
faucet, nozzle: ref Mass;
nozzle_ang := 0.0;
groundy := 420;
settle_until := 0;
have_tone := 0;
droptime := 0;

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
		sys->fprint(sys->fildes(2), "squirt: no ode\n");
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

	win = wmclient->window(ctxt, "TempleOS Squirt", Wmclient->Appl);
	d := win.display;
	ink = array[8] of ref Image;
	ink[0] = d.color(Draw->Black);
	ink[1] = d.color(Draw->Green);
	ink[2] = d.color(Draw->Cyan);
	ink[3] = d.color(Draw->Blue);
	ink[4] = d.color(Draw->Red);
	ink[5] = d.color(Draw->White);
	ink[6] = d.color(int 16r87CEEBFF);
	ink[7] = d.color(Draw->Grey);

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
		key(k);
	<-ticks =>
		animate();
		step();
		redraw();
	}
}

reset()
{
	sim = ode->new();
	sim.accel_limit = 5000.0;
	sim.h = 0.02;
	sim.drag_v2 = 0.01;
	sim.drag_v3 = 0.0001;
	settle_until = sys->millisec() + 500;
	faucet = nozzle = nil;
	hosenew();
}

hosenew()
{
	prev: ref Mass;
	# FAUCET_X ≈ 15, walk right in LINK steps but place at i/2 like original
	for(i := 15; i < 640; i += LINK){
		x := real(i / 2);
		y := real(groundy) - HOSE_R;
		m := ref Mass(x, y, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 250.0, 0, 0, HOSE_R, MT_HOSE);
		ode->addmass(sim, m);
		if(prev != nil){
			s := ref Spring(m, prev, 20000.0, real LINK, 0.0, 0.0, 0, 0, 0);
			ode->addspring(sim, s);
			nozzle = m;
		}else
			faucet = m;
		prev = m;
	}
	if(faucet != nil)
		faucet.y = real(groundy - 12*16);	# approx FAUCET_Y
	if(nozzle != nil)
		nozzle.y = real(groundy - 15*16);
	# pin faucet
	if(faucet != nil)
		faucet.flags |= Ode->MSF_FIXED;
}

key(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		exit;
	'\n' =>
		reset();
	Keyboard->Left or 'a' or 'A' =>
		movenozzle(-15.0, 0.0);
	Keyboard->Right or 'd' or 'D' =>
		movenozzle(15.0, 0.0);
	Keyboard->Up or 'w' or 'W' =>
		movenozzle(0.0, -15.0);
	Keyboard->Down or 's' or 'S' =>
		movenozzle(0.0, 15.0);
	}
}

movenozzle(dx, dy: real)
{
	if(nozzle == nil)
		return;
	nozzle.x += dx;
	nozzle.y += dy;
	if(nozzle.x < HOSE_R*3.0) nozzle.x = HOSE_R*3.0;
	if(nozzle.x > 640.0 - HOSE_R*3.0) nozzle.x = 640.0 - HOSE_R*3.0;
	if(nozzle.y < HOSE_R*3.0) nozzle.y = HOSE_R*3.0;
	if(nozzle.y > real groundy) nozzle.y = real groundy;
	nozzle.vx = nozzle.vy = 0.0;
}

animate()
{
	if(sys->millisec() < settle_until)
		return;
	now := sys->millisec();
	if(now - droptime < 50)
		return;
	droptime = now;
	if(nozzle == nil)
		return;
	# angle from previous hose mass
	prev: ref Mass;
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		if(m.userdata == MT_HOSE && m != nozzle)
			prev = m;	# last hose before nozzle in list order is unreliable
	}
	# find spring partner of nozzle
	p2: ref Mass;
	for(ls := sim.springs; ls != nil; ls = tl ls){
		s := hd ls;
		if(s.end1 == nozzle) p2 = s.end2;
		if(s.end2 == nozzle) p2 = s.end1;
	}
	dx := 1.0; dy := 0.0;
	if(p2 != nil){
		dx = nozzle.x - p2.x;
		dy = nozzle.y - p2.y;
		nozzle_ang = math->atan2(dy, dx);
		d := math->sqrt(dx*dx+dy*dy);
		if(d > 0.001){ dx /= d; dy /= d; }
	}
	drop(nozzle.x + NOZZLE_LEN*dx, nozzle.y + NOZZLE_LEN*dy, 500.0*dx, 500.0*dy);
	if(rand != nil && rand->rand(100) < 5 && faucet != nil)
		drop(faucet.x, faucet.y, 0.0, 0.0);
}

drop(x, y, vx, vy: real)
{
	m := ref Mass(x, y, 0.0, vx, vy, 0.0, 0.0,0.0,0.0, 100.0, 250.0, 0, 0, HOSE_R, MT_DROP);
	ode->addmass(sim, m);
}

step()
{
	if(sys->millisec() >= settle_until){
		sim.drag_v2 = 0.0005;
		sim.drag_v3 = 0.0000025;
	}
	ode->clearforces(sim);
	# pin faucet & nozzle positions (nozzle moved by keys; still free in ODE — pin each frame)
	if(faucet != nil){
		faucet.vx = faucet.vy = 0.0;
		faucet.fx = faucet.fy = 0.0;
	}
	if(nozzle != nil){
		nozzle.vx = nozzle.vy = 0.0;
	}
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		if(m == faucet || m == nozzle)
			continue;
		if(m.userdata == MT_HOSE){
			if(m.y + m.radius > real groundy)
				m.fy -= (m.y + m.radius - real groundy) *
					(m.y + m.radius - real groundy) *
					(m.y + m.radius - real groundy) *
					(m.y + m.radius - real groundy) * m.mass;
			else
				m.fy += 500.0 * m.mass;
		}else if(m.userdata == MT_DROP)
			m.fy += 500.0 * m.mass;
	}
	ode->update(sim, 0.016);
	kill: list of ref Mass;
	for(lm := sim.masses; lm != nil; lm = tl lm){
		m := hd lm;
		if(m.userdata == MT_DROP && m.y + m.radius > real groundy)
			kill = m :: kill;
	}
	for(k := kill; k != nil; k = tl k)
		ode->remmass(sim, hd k);
	if(faucet != nil){
		faucet.vx = faucet.vy = 0.0;
		faucet.flags |= Ode->MSF_FIXED;
	}
	if(nozzle != nil){
		nozzle.vx = nozzle.vy = 0.0;
		# keep nozzle fixed while user aims
		nozzle.flags |= Ode->MSF_FIXED;
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	groundy = img.r.dy() - 48;
	img.draw(img.r, ink[6], nil, Point(0, 0));
	img.draw(Rect((o.x, o.y+groundy), (o.x+img.r.dx(), o.y+img.r.dy())), ink[1], nil, Point(0, 0));

	if(sys->millisec() < settle_until){
		# title flash
		img.fillellipse(Point(o.x+img.r.dx()/2, o.y+img.r.dy()/2), 40, 12, ink[4], Point(0, 0));
	}

	# hose springs
	for(ls := sim.springs; ls != nil; ls = tl ls){
		s := hd ls;
		p1 := Point(o.x+int s.end1.x, o.y+int s.end1.y);
		p2 := Point(o.x+int s.end2.x, o.y+int s.end2.y);
		img.line(p1, p2, 0, 0, 2, ink[1], Point(0, 0));
		img.line(p1, p2, 0, 0, 0, ink[0], Point(0, 0));
	}
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		p := Point(o.x+int m.x, o.y+int m.y);
		r := int m.radius;
		if(m.userdata == MT_DROP)
			img.fillellipse(p, r, r, ink[3], Point(0, 0));
		else
			img.fillellipse(p, r, r, ink[1], Point(0, 0));
	}
	if(faucet != nil){
		p := Point(o.x+int faucet.x, o.y+int faucet.y);
		img.draw(Rect((p.x+8, p.y), (p.x+16, o.y+groundy)), ink[0], nil, Point(0, 0));
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
