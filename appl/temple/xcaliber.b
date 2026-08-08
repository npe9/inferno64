implement Xcaliber;

# TempleOS Apps/X-Caliber/X-Caliber.HC — ODE mass-spring space combat
# GAP: no laser temperature HUD / solar flares / spacewalk / antimatter splats
# GAP: no ship sprites — circles + spring lines; simplified missiles
# left/right turn  up thrust  space fire  Enter restart  q quit

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

include "ode.m";
	ode: Ode;
	ODE, Mass, Spring: import ode;

include "tone.m";
	tone: Tone;

include "rand.m";
	rand: Rand;

Xcaliber: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MT_HUMAN, MT_ENEMY, MT_MISSILE, MT_SHOT: con iota;
THRUST: con 120.0;
SPIN: con 0.06;
MISSILE_SPD: con 350.0;
SHOT_SPD: con 500.0;

Ship: adt {
	m1, m2: ref Mass;
	spring: ref Spring;
	alive: int;
	reload: int;
	tag: int;
};

win: ref Window;
sim: ref ODE;
ink: array of ref Image;
human: Ship;
enemies: array of Ship;
stars_x, stars_y: array of int;
score, level, remaining: int;
kleft, kright, kup, kfire: int;
thrust_until := 0;
spin_until := 0;
fire_until := 0;
game_over := 0;
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
		sys->fprint(sys->fildes(2), "xcaliber: no ode\n");
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

	win = wmclient->window(ctxt, "TempleOS X-Caliber", Wmclient->Appl);
	d := win.display;
	ink = array[8] of ref Image;
	ink[0] = d.color(Draw->Black);
	ink[1] = d.color(Draw->Green);
	ink[2] = d.color(Draw->Cyan);
	ink[3] = d.color(Draw->Blue);
	ink[4] = d.color(Draw->Red);
	ink[5] = d.color(Draw->Yellow);
	ink[6] = d.color(Draw->White);
	ink[7] = d.color(int 16r888888FF);
	stars_x = array[80] of int;
	stars_y = array[80] of int;
	enemies = array[4] of Ship;
	reset();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 16);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	k := <-win.ctxt.kbd =>
		keydown(k);
	<-ticks =>
		if(sys->millisec() > thrust_until){
			kup = 0;
		}
		if(sys->millisec() > spin_until){
			kleft = 0; kright = 0;
		}
		if(sys->millisec() > fire_until)
			kfire = 0;
		if(!game_over)
			step();
		redraw();
	}
}

reset()
{
	i: int;
	sim = ode->new();
	sim.drag_v2 = 0.001;
	sim.drag_v3 = 0.00001;
	sim.accel_limit = 8000.0;
	sim.h = 0.01;
	score = 0;
	level = 1;
	game_over = 0;
	img := win.image;
	w := 640; h := 480;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	for(i = 0; i < 80; i++){
		stars_x[i] = rn(w);
		stars_y[i] = rn(h);
	}
	human = makeship(real(w)/2.0, real(h)/2.0, MT_HUMAN);
	for(i = 0; i < len enemies; i++)
		enemies[i].alive = 0;
	remaining = level + 1;
	spawnwave();
}

makeship(x, y: real, tag: int): Ship
{
	m1 := ref Mass(x, y, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 2.0, 1.0, 0, tag, 8.0, tag);
	m2 := ref Mass(x, y-22.0, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 1.0, 0, tag+100, 5.0, tag);
	ode->addmass(sim, m1);
	ode->addmass(sim, m2);
	sp := ref Spring(m1, m2, 8000.0, 22.0, 0.0, 0.0, 0, 0, 0);
	ode->addspring(sim, sp);
	return Ship(m1, m2, sp, 1, 0, tag);
}

spawnwave()
{
	i: int;
	img := win.image;
	w := 640; h := 480;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	n := level + 1;
	for(i = 0; i < n && i < len enemies; i++){
		x := real(80 + rn(w-160));
		y := real(40 + rn(h/3));
		enemies[i] = makeship(x, y, MT_ENEMY);
		enemies[i].alive = 1;
	}
	remaining = n;
}

keydown(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		if(have_tone) tone->stop();
		exit;
	'\n' =>
		reset();
	' ' =>
		kfire = 1; fire_until = sys->millisec() + 120;
	Keyboard->Up or 'w' or 'W' =>
		kup = 1; thrust_until = sys->millisec() + 200;
	Keyboard->Left or 'a' or 'A' =>
		kleft = 1; kright = 0; spin_until = sys->millisec() + 200;
	Keyboard->Right or 'd' or 'D' =>
		kright = 1; kleft = 0; spin_until = sys->millisec() + 200;
	}
}

shipang(sh: Ship): real
{
	return math->atan2(sh.m2.y - sh.m1.y, sh.m2.x - sh.m1.x);
}

step()
{
	i: int;
	ode->clearforces(sim);
	if(human.alive){
		ang := shipang(human);
		if(kleft){
			human.m2.fx -= SPIN * 8000.0 * math->sin(ang);
			human.m2.fy += SPIN * 8000.0 * math->cos(ang);
		}
		if(kright){
			human.m2.fx += SPIN * 8000.0 * math->sin(ang);
			human.m2.fy -= SPIN * 8000.0 * math->cos(ang);
		}
		if(kup){
			human.m1.fx += THRUST * math->cos(ang);
			human.m1.fy += THRUST * math->sin(ang);
			if(have_tone)
				tone->snd(22*12);
		}else if(have_tone)
			tone->stop();
		if(kfire && human.reload <= 0){
			fireshot(human, SHOT_SPD);
			human.reload = 12;
		}
		if(human.reload > 0)
			human.reload--;
	}
	for(i = 0; i < len enemies; i++){
		e := enemies[i];
		if(!e.alive)
			continue;
		ang := shipang(e);
		dx := human.m1.x - e.m1.x;
		dy := human.m1.y - e.m1.y;
		d := math->sqrt(dx*dx + dy*dy) + 0.001;
		e.m1.fx += THRUST * 0.4 * dx / d;
		e.m1.fy += THRUST * 0.4 * dy / d;
		want := math->atan2(dy, dx);
		da := want - ang;
		while(da > Math->Pi) da -= 2.0*Math->Pi;
		while(da < -Math->Pi) da += 2.0*Math->Pi;
		e.m2.fx += da * 4000.0 * math->sin(ang);
		e.m2.fy -= da * 4000.0 * math->cos(ang);
		if(e.reload <= 0 && d < 280.0){
			fireshot(e, MISSILE_SPD * 0.7);
			e.reload = 40 + rn(20);
		}
		if(e.reload > 0)
			e.reload--;
	}
	collideall();
	checkhits();
	wallall();
	ode->update(sim, 0.016);
	if(!human.alive){
		game_over = 1;
		if(have_tone) tone->stop();
	}
	if(remaining <= 0 && !game_over){
		level++;
		spawnwave();
	}
}

fireshot(sh: Ship, spd: real)
{
	ang := shipang(sh);
	tag := MT_SHOT;
	if(sh.tag == MT_ENEMY)
		tag = MT_MISSILE;
	m := ref Mass(
		sh.m2.x + 12.0*math->cos(ang), sh.m2.y + 12.0*math->sin(ang), 0.0,
		spd*math->cos(ang), spd*math->sin(ang), 0.0,
		0.0,0.0,0.0, 0.5, 0.1, 0, 0, 3.0, tag
	);
	ode->addmass(sim, m);
	if(have_tone)
		tone->beep(70, 15);
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
				force := 8.0 * gap * gap;
				s := force / d;
				m2.fx += dx*s; m2.fy += dy*s;
				m1.fx -= dx*s; m1.fy -= dy*s;
			}
		}
	}
}

checkhits()
{
	kill: list of ref Mass;
	for(l1 := sim.masses; l1 != nil; l1 = tl l1){
		p := hd l1;
		if(p.userdata != MT_SHOT && p.userdata != MT_MISSILE)
			continue;
		for(l2 := sim.masses; l2 != nil; l2 = tl l2){
			t := hd l2;
			if(t == p)
				continue;
			if(p.userdata == MT_SHOT && t.userdata == MT_ENEMY){
				dx := t.x - p.x; dy := t.y - p.y;
				if(dx*dx+dy*dy <= (t.radius+p.radius)*(t.radius+p.radius)){
					kill = p :: kill;
					killenemy(t);
					score += 100;
					remaining--;
				}
			}
			if(p.userdata == MT_MISSILE && t.userdata == MT_HUMAN){
				dx := t.x - p.x; dy := t.y - p.y;
				if(dx*dx+dy*dy <= (t.radius+p.radius)*(t.radius+p.radius)){
					kill = p :: kill;
					human.alive = 0;
				}
			}
		}
	}
	for(k := kill; k != nil; k = tl k)
		ode->remmass(sim, hd k);
	cleanmissiles();
}

killenemy(m: ref Mass)
{
	i: int;
	for(i = 0; i < len enemies; i++){
		e := enemies[i];
		if(!e.alive)
			continue;
		if(e.m1 == m || e.m2 == m){
			ode->remspring(sim, e.spring);
			ode->remmass(sim, e.m1);
			ode->remmass(sim, e.m2);
			e.alive = 0;
			if(have_tone)
				tone->beep(30, 60);
			return;
		}
	}
}

cleanmissiles()
{
	kill: list of ref Mass;
	img := win.image;
	w := 640.0; h := 480.0;
	if(img != nil){
		w = real img.r.dx();
		h = real img.r.dy();
	}
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		if(m.userdata != MT_SHOT && m.userdata != MT_MISSILE)
			continue;
		if(m.x < -20.0 || m.x > w+20.0 || m.y < -20.0 || m.y > h+20.0)
			kill = m :: kill;
	}
	for(k := kill; k != nil; k = tl k)
		ode->remmass(sim, hd k);
}

wallall()
{
	img := win.image;
	w := 640.0; h := 480.0;
	if(img != nil){
		w = real img.r.dx();
		h = real img.r.dy();
	}
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		if(m.userdata == MT_SHOT || m.userdata == MT_MISSILE)
			continue;
		r := m.radius;
		if(m.x - r < 8.0)
			m.fx += (8.0 - (m.x - r))*(8.0 - (m.x - r));
		if(m.x + r > w - 8.0)
			m.fx -= ((m.x + r) - (w - 8.0))*((m.x + r) - (w - 8.0));
		if(m.y - r < 8.0)
			m.fy += (8.0 - (m.y - r))*(8.0 - (m.y - r));
		if(m.y + r > h - 8.0)
			m.fy -= ((m.y + r) - (h - 8.0))*((m.y + r) - (h - 8.0));
	}
}

redraw()
{
	i: int;
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	img.draw(img.r, ink[0], nil, Point(0, 0));
	for(i = 0; i < 80; i++)
		img.draw(Rect((o.x+stars_x[i], o.y+stars_y[i]), (o.x+stars_x[i]+1, o.y+stars_y[i]+1)), ink[7], nil, Point(0, 0));
	for(ls := sim.springs; ls != nil; ls = tl ls){
		s := hd ls;
		col := ink[2];
		if(s.end1.userdata == MT_ENEMY)
			col = ink[4];
		img.line(Point(o.x+int s.end1.x, o.y+int s.end1.y),
			Point(o.x+int s.end2.x, o.y+int s.end2.y), 0, 0, 0, col, Point(0, 0));
	}
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		col := ink[6];
		case m.userdata {
		MT_HUMAN =>
			col = ink[2];
		MT_ENEMY =>
			col = ink[4];
		MT_SHOT =>
			col = ink[5];
		MT_MISSILE =>
			col = ink[4];
		}
		r := int m.radius;
		if(r < 2) r = 2;
		img.fillellipse(Point(o.x+int m.x, o.y+int m.y), r, r, col, Point(0, 0));
	}
	img.draw(Rect((o.x+8, o.y+8), (o.x+8+score/20, o.y+18)), ink[5], nil, Point(0, 0));
	if(game_over)
		img.draw(Rect((o.x+w/2-70, o.y+h/2-16), (o.x+w/2+70, o.y+h/2+16)), ink[4], nil, Point(0, 0));
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
