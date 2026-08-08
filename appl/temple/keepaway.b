implement Keepaway;

# TempleOS Apps/KeepAway/KeepAway.HC — 2D ODE keep-away
# GAP: no 3D GrModels men/ball sprites — circles; no RegWrite best scores
# GAP: no shot arc / hand physics — space kick impulse toward ball
# player left, AI right; score in goal zones  Enter=restart  q=quit

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
	ODE, Mass: import ode;

include "tone.m";
	tone: Tone;

Keepaway: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MT_BALL, MT_HUMAN, MT_AI: con iota;
PLAYERS: con 4;
PR: con 14;
BR: con 10;
GOAL: con 36;
MOVE: con 180.0;
KICK: con 450.0;

win: ref Window;
sim: ref ODE;
ball: ref Mass;
players: array of ref Mass;
ink: array of ref Image;
score0, score1: int;
kdx, kdy: int;
move_until := 0;
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
		sys->fprint(sys->fildes(2), "keepaway: no ode\n");
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

	win = wmclient->window(ctxt, "TempleOS KeepAway", Wmclient->Appl);
	d := win.display;
	ink = array[8] of ref Image;
	ink[0] = d.color(Draw->Black);
	ink[1] = d.color(Draw->Green);
	ink[2] = d.color(Draw->Cyan);
	ink[3] = d.color(Draw->Blue);
	ink[4] = d.color(Draw->Red);
	ink[5] = d.color(Draw->Yellow);
	ink[6] = d.color(Draw->White);
	ink[7] = d.color(int 16r444444FF);

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
		keydown(k);
	<-ticks =>
		step();
		checkgoals();
		redraw();
	}
}

reset()
{
	sim = ode->new();
	sim.drag_v2 = 0.003;
	sim.drag_v3 = 0.00001;
	sim.accel_limit = 8000.0;
	sim.h = 0.01;
	score0 = score1 = 0;
	players = array[PLAYERS] of ref Mass;
	img := win.image;
	w := 640.0; h := 480.0;
	if(img != nil){
		w = real img.r.dx();
		h = real img.r.dy();
	}
	ball = addmass(w*0.5, h*0.5, real BR, 1.0, MT_BALL);
	players[0] = addmass(w*0.25, h*0.5, real PR, 2.0, MT_HUMAN);
	for(i := 1; i < PLAYERS; i++)
		players[i] = addmass(w*0.75 + real(i-1)*18.0, h*(0.35 + 0.15*real(i)), real PR, 2.0, MT_AI);
}

addmass(x, y, r, mass: real, tag: int): ref Mass
{
	m := ref Mass(x, y, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, mass, 1.0, 0, tag, r, tag);
	ode->addmass(sim, m);
	return m;
}

keydown(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		exit;
	'\n' =>
		reset();
	' ' =>
		kick();
	Keyboard->Left or 'a' or 'A' =>
		kdx = -1; kdy = 0; move_until = sys->millisec() + 150;
	Keyboard->Right or 'd' or 'D' =>
		kdx = 1; kdy = 0; move_until = sys->millisec() + 150;
	Keyboard->Up or 'w' or 'W' =>
		kdx = 0; kdy = -1; move_until = sys->millisec() + 150;
	Keyboard->Down or 's' or 'S' =>
		kdx = 0; kdy = 1; move_until = sys->millisec() + 150;
	}
}

kick()
{
	if(ball == nil || players[0] == nil)
		return;
	p := players[0];
	dx := ball.x - p.x;
	dy := ball.y - p.y;
	d := math->sqrt(dx*dx + dy*dy);
	if(d < 0.001)
		return;
	if(d > real(PR+BR+6)){
		dx = ball.x - p.x;
		dy = ball.y - p.y;
		d = math->sqrt(dx*dx + dy*dy);
	}
	if(d < 0.001)
		return;
	s := KICK / d;
	ball.fx += dx * s;
	ball.fy += dy * s;
	if(have_tone)
		tone->beep(60, 40);
}

step()
{
	ode->clearforces(sim);
	img := win.image;
	w := 640.0; h := 480.0;
	if(img != nil){
		w = real img.r.dx();
		h = real img.r.dy();
	}
	if(sys->millisec() > move_until){
		kdx = 0; kdy = 0;
	}
	p := players[0];
	if(p != nil && (kdx != 0 || kdy != 0)){
		p.fx += real kdx * MOVE;
		p.fy += real kdy * MOVE;
	}
	# AI chase ball
	for(i := 1; i < PLAYERS; i++){
		ai := players[i];
		if(ai == nil || ball == nil)
			continue;
		dx := ball.x - ai.x;
		dy := ball.y - ai.y;
		d := math->sqrt(dx*dx + dy*dy);
		if(d > 1.0){
			s := MOVE / d;
			ai.fx += dx * s;
			ai.fy += dy * s;
		}
		if(d < real(PR+BR+4)){
			s := KICK * 0.6 / (d + 0.1);
			ball.fx += dx * s;
			ball.fy += dy * s;
		}
	}
	collideall();
	wallall(w, h);
	ode->update(sim, 0.016);
}

collideall()
{
	for(l1 := sim.masses; l1 != nil; l1 = tl l1){
		m1 := hd l1;
		for(l2 := tl l1; l2 != nil; l2 = tl l2){
			m2 := hd l2;
			dx := m2.x - m1.x;
			dy := m2.y - m1.y;
			dd := dx*dx + dy*dy;
			rr := m1.radius + m2.radius;
			if(dd <= rr*rr && dd > 0.0){
				d := math->sqrt(dd) + 0.0001;
				gap := rr*rr - dd;
				force := 12.0 * gap * gap;
				s := force / d;
				m2.fx += dx*s; m2.fy += dy*s;
				m1.fx -= dx*s; m1.fy -= dy*s;
			}
		}
	}
}

wallall(w, h: real)
{
	pad := 4.0;
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		r := m.radius;
		if(m.x - r < pad){
			e := pad - (m.x - r);
			m.fx += e*e*e;
		}
		if(m.x + r > w - pad){
			e := (m.x + r) - (w - pad);
			m.fx -= e*e*e;
		}
		if(m.y - r < pad){
			e := pad - (m.y - r);
			m.fy += e*e*e;
		}
		if(m.y + r > h - pad){
			e := (m.y + r) - (h - pad);
			m.fy -= e*e*e;
		}
	}
}

checkgoals()
{
	if(ball == nil)
		return;
	img := win.image;
	w := 640;
	if(img != nil)
		w = img.r.dx();
	if(ball.x < real GOAL){
		score1++;
		respawnball();
		if(have_tone) tone->beep(30, 120);
	}else if(ball.x > real(w - GOAL)){
		score0++;
		respawnball();
		if(have_tone) tone->beep(90, 120);
	}
}

respawnball()
{
	img := win.image;
	w := 640.0; h := 480.0;
	if(img != nil){
		w = real img.r.dx();
		h = real img.r.dy();
	}
	ball.x = w * 0.5;
	ball.y = h * 0.5;
	ball.vx = ball.vy = 0.0;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	img.draw(img.r, ink[1], nil, Point(0, 0));
	# goals
	img.draw(Rect((o.x, o.y+20), (o.x+GOAL, o.y+h-20)), ink[4], nil, Point(0, 0));
	img.draw(Rect((o.x+w-GOAL, o.y+20), (o.x+w, o.y+h-20)), ink[2], nil, Point(0, 0));
	img.draw(Rect((o.x+GOAL, o.y), (o.x+w-GOAL, o.y+h)), ink[6], nil, Point(0, 0));
	# center line
	img.line(Point(o.x+w/2, o.y+10), Point(o.x+w/2, o.y+h-10), 0, 0, 0, ink[7], Point(0, 0));
	if(ball != nil){
		bp := Point(o.x+int ball.x, o.y+int ball.y);
		img.fillellipse(bp, int ball.radius, int ball.radius, ink[5], Point(0, 0));
		img.ellipse(bp, int ball.radius, int ball.radius, 0, ink[0], Point(0, 0));
	}
	for(i := 0; i < PLAYERS; i++){
		p := players[i];
		if(p == nil)
			continue;
		pt := Point(o.x+int p.x, o.y+int p.y);
		col := ink[3];
		if(i == 0)
			col = ink[2];
		else
			col = ink[4];
		img.fillellipse(pt, int p.radius, int p.radius, col, Point(0, 0));
		img.ellipse(pt, int p.radius, int p.radius, 0, ink[0], Point(0, 0));
	}
	# score bars
	img.draw(Rect((o.x+8, o.y+8), (o.x+8+score0*6, o.y+18)), ink[2], nil, Point(0, 0));
	img.draw(Rect((o.x+w-8-score1*6, o.y+8), (o.x+w-8, o.y+18)), ink[4], nil, Point(0, 0));
	img.flush(Draw->Flushnow);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
