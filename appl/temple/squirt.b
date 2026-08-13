implement Squirt;

# TempleOS Demo/Games/Squirt.HC — ODE hose + droplets
# arrows move nozzle  Enter=restart  q=quit

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;

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
HOSE_N: con 105;
MOVE_STEPS: con 5;
MOVE: con 15.0;

win: ref Window;
font: ref Font;
sim: ref ODE;
ink: array of ref Image;
sprites, masks: array of ref Image;
hoses: array of ref Mass;
faucet, nozzle: ref Mass;
nozzle_ang := 0.0;
groundy := 432;
settle_until := 0;
have_tone := 0;
move_x, move_y, move_steps: int;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	draw3d = load Draw3d Draw3d->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	ode = load Ode Ode->PATH;
	tone = load Tone Tone->PATH;
	if(ode == nil || draw3d == nil){
		sys->fprint(sys->fildes(2), "squirt: no ode\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	ode->init();
	draw3d->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Squirt", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	ink = array[8] of ref Image;
	ink[0] = d.color(Draw->Black);
	ink[1] = d.color(Draw->Green);
	ink[2] = d.color(Draw->Cyan);
	ink[3] = d.color(Draw->Blue);
	ink[4] = d.color(Draw->Red);
	ink[5] = d.color(Draw->White);
	ink[6] = d.color(int 16r87CEEBFF);
	ink[7] = d.color(Draw->Grey);
	sprites = array[5] of ref Image;
	masks = array[5] of ref Image;
	for(i := 1; i <= 4; i++){
		sprites[i] = d.open(sys->sprint("/icons/temple/squirt_%d.bit", i));
		masks[i] = d.open(sys->sprint("/icons/temple/squirt_%d.mask", i));
	}
	hoses = array[HOSE_N] of ref Mass;

	reset();
	if(have_tone)
		spawn songloop();
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
	sim.h = 0.05;
	sim.drag_v2 = 0.01;
	sim.drag_v3 = 0.0001;
	settle_until = sys->millisec() + 500;
	faucet = nozzle = nil;
	move_x = move_y = move_steps = 0;
	hosenew();
}

hosenew()
{
	prev: ref Mass;
	# TempleOS HoseNew: FAUCET_X=15, but each link is placed at i/2.
	n := 0;
	for(i := 15; i < 640; i += LINK){
		x := real(i / 2);
		y := real(groundy) - HOSE_R;
		m := ref Mass(x, y, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 250.0, 0, 0, HOSE_R, MT_HOSE);
		ode->addmass(sim, m);
		hoses[n++] = m;
		if(prev != nil){
			s := ref Spring(m, prev, 20000.0, real LINK, 0.0, 0.0, 0, 0, 0);
			ode->addspring(sim, s);
			nozzle = m;
		}else
			faucet = m;
		prev = m;
	}
	if(faucet != nil)
		faucet.y = real(groundy - 12*16);
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
		startmove(-1, 0);
	Keyboard->Right or 'd' or 'D' =>
		startmove(1, 0);
	Keyboard->Up or 'w' or 'W' =>
		startmove(0, -1);
	Keyboard->Down or 's' or 'S' =>
		startmove(0, 1);
	}
}

startmove(dx, dy: int)
{
	move_x = dx;
	move_y = dy;
	move_steps = MOVE_STEPS;
}

movenozzle()
{
	if(nozzle == nil || move_steps <= 0)
		return;
	nozzle.x += real move_x * MOVE / real MOVE_STEPS;
	nozzle.y += real move_y * MOVE / real MOVE_STEPS;
	move_steps--;
	if(nozzle.x < HOSE_R*3.0) nozzle.x = HOSE_R*3.0;
	if(nozzle.x > 640.0 - HOSE_R*3.0) nozzle.x = 640.0 - HOSE_R*3.0;
	if(nozzle.y < HOSE_R*3.0) nozzle.y = HOSE_R*3.0;
	if(nozzle.y > real groundy) nozzle.y = real groundy;
	nozzle.vx = nozzle.vy = 0.0;
}

animate()
{
	movenozzle();
	if(sys->millisec() < settle_until)
		return;
	if(nozzle == nil)
		return;
	# angle from previous hose mass
	p2 := hoses[HOSE_N-2];
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
	img.draw(img.r, ink[2], nil, Point(0, 0));
	if(sprites[4] != nil)
		img.draw(Rect((o.x, o.y+groundy-70), (o.x+640, o.y+groundy+48)),
			sprites[4], masks[4], Point(0, 0));
	else
		img.draw(Rect((o.x, o.y+groundy), (o.x+img.r.dx(), o.y+img.r.dy())), ink[1], nil, Point(0, 0));

	if(sys->millisec() < settle_until){
		img.text(Point(o.x+(img.r.dx()-6*8)/2, o.y+img.r.dy()/2), ink[4], Point(0, 0), font, "Squirt");
		img.flush(Draw->Flushnow);
		return;
	}

	# Draw an explicitly opaque ribbon.  The black under-stroke supplies the
	# two HolyC spring edges; the green over-stroke is the GrFillPoly3 body.
	# Using strokes here also closes the sub-pixel gaps between adjacent quads.
	for(i := 1; i < HOSE_N; i++){
		a := hoses[i-1]; b := hoses[i];
		p1 := Point(o.x+int a.x, o.y+int a.y);
		p2 := Point(o.x+int b.x, o.y+int b.y);
		img.line(p1, p2, Draw->Enddisc, Draw->Enddisc, int HOSE_R+1,
			ink[0], Point(0, 0));
	}
	# Paint all cores after all outlines so no segment boundary can overwrite
	# the continuous green interior.
	for(i = 1; i < HOSE_N; i++){
		a := hoses[i-1]; b := hoses[i];
		p1 := Point(o.x+int a.x, o.y+int a.y);
		p2 := Point(o.x+int b.x, o.y+int b.y);
		img.line(p1, p2, Draw->Enddisc, Draw->Enddisc, int HOSE_R-1,
			ink[1], Point(0, 0));
	}
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		p := Point(o.x+int m.x, o.y+int m.y);
		r := int m.radius;
		if(m.userdata == MT_DROP){
			if(sprites[3] != nil)
				img.draw(Rect((p.x-3, p.y-3), (p.x+4, p.y+4)), sprites[3], masks[3], Point(0, 0));
			else
				img.fillellipse(p, r, r, ink[3], Point(0, 0));
		}
	}
	if(faucet != nil){
		p := Point(o.x+int faucet.x, o.y+int faucet.y);
		img.draw(Rect((p.x+8, p.y), (p.x+16, o.y+groundy)), ink[0], nil, Point(0, 0));
		if(sprites[1] != nil)
			img.draw(Rect((p.x-14, p.y-13), (p.x+15, p.y+13)), sprites[1], masks[1], Point(0, 0));
	}
	if(nozzle != nil && sprites[2] != nil){
		p := Point(o.x+int nozzle.x, o.y+int nozzle.y);
		draw3d->sprite2d(img, p, sprites[2], masks[2], 25, 9,
			nozzle_ang*180.0/3.141592653589793, 0);
	}
	img.flush(Draw->Flushnow);
}

songloop()
{
	for(;;){
		tone->play("5sDCDC4qA5DetDFFeDG4etA5EF4qG5eFC");
		tone->play("5sDCDC4qA5DetDFFeDG4etA5EF4qG5eFC");
		tone->play("5DCsG4A5G4AqBeBA5qEE4B5eC4B");
		tone->play("5DCsG4A5G4AqBeBA5qEE4B5eC4B");
	}
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
