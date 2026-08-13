implement Rocket;

# TempleOS Demo/Games/Rocket.HC — ODE rocket + extracted sprites (coffee-style)
# arrows / wasd thrust; Enter restart; space/any to blast off; q quit

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Context, Display, Point, Rect, Image: import draw;

include "math.m";
	math: Math;

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "tkclient.m";
	tkclient: Tkclient;

include "keyboard.m";

include "ode.m";
	ode: Ode;
	ODE, Mass, Spring: import ode;

include "tone.m";
	tone: Tone;

include "rand.m";
	rand: Rand;

Rocket: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

THRUST: con 100.0;
RH: con 40.0;

display: ref Display;
top: ref Toplevel;
buffer: ref Image;
ground, ship, smask: ref Image;
sim: ref ODE;
m1, m2: ref Mass;	# bottom, top
blastoff := 0;
kup := 0;
kleft := 0;
kright := 0;
have_tone := 0;
gy: int;

cfg := array[] of {
	"frame .f",
	"label .f.help -text {space=blast off · arrows thrust · Enter restart · q quit}",
	"panel .f.p -bd 1 -relief sunken",
	"pack .f.help -side top -fill x",
	"pack .f.p -side top -fill both -expand 1",
	"pack .f -fill both -expand 1",
};

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	draw3d = load Draw3d Draw3d->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	ode = load Ode Ode->PATH;
	tone = load Tone Tone->PATH;
	rand = load Rand Rand->PATH;
	if(ode == nil){
		sys->fprint(sys->fildes(2), "rocket: no ode\n");
		raise "fail:load";
	}
	if(draw3d == nil){
		sys->fprint(sys->fildes(2), "rocket: no draw3d\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	ode->init();
	draw3d->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	display = ctxt.display;

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS Rocket", 0);
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);

	ground = display.open("/icons/temple/rocket_2.bit");
	ship = display.open("/icons/temple/rocket_1.bit");
	smask = display.open("/icons/temple/rocket_1.mask");
	cmd(top, "update");
	tkclient->startinput(top, "ptr" :: "kbd" :: "keyup" :: nil);
	tkclient->onscreen(top, nil);
	# Match coffee.b: panel buffer must use toplevel image chans after onscreen.
	chans := display.image.chans;
	if(top.image != nil)
		chans = top.image.chans;
	r := Rect((0, 0), (640, 400));
	buffer = display.newimage(r, chans, 0, Draw->Cyan);
	if(buffer == nil){
		sys->fprint(sys->fildes(2), "rocket: no buffer\n");
		raise "fail:buffer";
	}
	tk->putimage(top, ".f.p", buffer, nil);
	cmd(top, "update");
	gy = r.dy() - 60;
	reset();

	ticks := chan of int;
	spawn timer(ticks, 16);
	for(;;) alt{
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		case s {
		16r1b or 'q' or 'Q' =>
			if(have_tone) tone->stop();
			exit;
		' ' =>
			blastoff = 1;
		'\n' =>
			reset();
		Keyboard->Up or 'w' or 'W' =>
			kup = 1; kleft = 0; kright = 0;
		Keyboard->Left or 'a' or 'A' =>
			kleft = 1; kup = 0; kright = 0;
		Keyboard->Right or 'd' or 'D' =>
			kright = 1; kup = 0; kleft = 0;
		Keyboard->Keyup | (Keyboard->Up & 16r7ff) or
		Keyboard->Keyup | 'w' or Keyboard->Keyup | 'W' =>
			kup = 0;
		Keyboard->Keyup | (Keyboard->Left & 16r7ff) or
		Keyboard->Keyup | 'a' or Keyboard->Keyup | 'A' =>
			kleft = 0;
		Keyboard->Keyup | (Keyboard->Right & 16r7ff) or
		Keyboard->Keyup | 'd' or Keyboard->Keyup | 'D' =>
			kright = 0;
		}
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	<-ticks =>
		step();
		paint();
	}
}

reset()
{
	sim = ode->new();
	sim.drag_v2 = 0.002;
	sim.drag_v3 = 0.00001;
	sim.accel_limit = 5000.0;
	sim.h = 0.01;
	blastoff = 0;
	m1 = ref Mass(0.0, 0.0, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 1.0, 0, 0, 4.0, 0);
	m2 = ref Mass(0.0, RH, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 1.0, 0, 1, 4.0, 0);
	ode->addmass(sim, m1);
	ode->addmass(sim, m2);
	ode->addspring(sim, ref Spring(m1, m2, 10000.0, RH, 0.0, 0.0, 0, 0, 0));
}

step()
{
	ode->clearforces(sim);
	ang := math->atan2(m2.y - m1.y, m2.x - m1.x);
	engine := 0;
	nozzle := 0.0;
	if(kup){ engine = 1; nozzle = 0.0; }
	else if(kleft){ engine = 1; nozzle = Math->Pi/8.0; }
	else if(kright){ engine = 1; nozzle = -Math->Pi/8.0; }
	if(engine){
		m1.fx += THRUST * math->cos(ang + nozzle);
		m1.fy += THRUST * math->sin(ang + nozzle);
		if(have_tone)
			tone->snd(22*16);
	}else if(have_tone)
		tone->stop();
	if(blastoff){
		m1.fy -= 25.0;
		m2.fy -= 25.0;
	}
	ode->update(sim, 0.016);
}

paint()
{
	if(buffer == nil || top == nil)
		return;
	buffer.draw(buffer.r, display.color(Draw->Cyan), nil, Point(0, 0));
	cx := buffer.r.dx()/2;
	if(ground != nil){
		p0 := Point(0, gy - ground.r.dy()/2);
		buffer.draw(ground.r.addpt(p0), ground, nil, ground.r.min);
	}else
		buffer.draw(Rect((0, gy), (buffer.r.dx(), buffer.r.dy())),
			display.color(Draw->Darkgreen), nil, Point(0, 0));

	rx := cx + int((m1.x + m2.x)/2.0);
	ry := gy - int((m1.y + m2.y)/2.0);
	if(ship != nil && smask != nil){
		ang := math->atan2(m2.y-m1.y, m2.x-m1.x);
		deg := 90.0-ang*180.0/Math->Pi;
		draw3d->sprite2d(buffer, Point(rx, ry), ship, smask,
			ship.r.dx(), ship.r.dy(), deg, 0);
	}else{
		yel := display.color(Draw->Yellow);
		buffer.line(Point(cx+int m1.x, gy-int m1.y), Point(cx+int m2.x, gy-int m2.y),
			Draw->Endsquare, Draw->Enddisc, 2, yel, Point(0, 0));
	}
	tk->cmd(top, ".f.p dirty; update");
}

cmd(win: ref Toplevel, s: string): string
{
	e := tk->cmd(win, s);
	if(len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "rocket tk: %s\n", e);
	return e;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
