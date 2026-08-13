implement Strut;

# TempleOS Apps/Strut — ODE ship editor / thrusters
# GAP: no mass sprites / Sprite3ZB thruster art — circles + lines
# Edit: m=mass s=spring n=connector t=thruster v=move  0-9 set action key
# space=play/edit  in play: 0-9 fire/break  c=center d=damp  q=quit

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "keyboard.m";

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

Strut: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

RADIUS: con 7;
MMD_EDIT, MMD_PLAY: con iota;
EMD_MASS, EMD_SPRING, EMD_CONNECTOR, EMD_THRUSTER, EMD_MOVE: con iota;

SSpring: adt {
	s:	ref Spring;
	typ:	int;	# EMD_*
	key:	int;	# '0'..'9'
};

win: ref Window;
sim: ref ODE;
ink: array of ref Image;
springs: list of ref SSpring;
mainmode := MMD_EDIT;
editmode := EMD_MASS;
nextkey := '1';
zoom := 1.0;
sel: ref Mass;
down := 0;
mx, my: int;
held := array[10] of { * => 0 };
have_tone := 0;

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
		sys->fprint(sys->fildes(2), "strut: no ode\n");
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

	win = wmclient->window(ctxt, "TempleOS Strut", Wmclient->Appl);
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
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);
	title();

	ticks := chan of int;
	spawn timer(ticks, 16);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p);
	k := <-win.ctxt.kbd =>
		key(k);
	<-ticks =>
		if(mainmode == MMD_PLAY){
			breakconnectors();
			step();
		}
		redraw();
	}
}

title()
{
	ms := "EDIT";
	if(mainmode == MMD_PLAY)
		ms = "PLAY";
	em := array[] of {"mass", "spring", "connector", "thruster", "move"};
	win.settitle(sys->sprint("Strut [%s/%s] key=%c  space=toggle  q=quit",
		ms, em[editmode], nextkey));
}

reset()
{
	sim = ode->new();
	sim.accel_limit = 5000.0;
	sim.drag_v2 = 0.000002;
	sim.drag_v3 = 0.0000001;
	sim.h = 0.005;
	ode->pause(sim, 1);
	springs = nil;
	sel = nil;
	zoom = 1.0;
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	# screen → world (centered on first mass when playing)
	sx := p.xy.x - img.r.min.x;
	sy := p.xy.y - img.r.min.y;
	(wx, wy) := s2w(sx, sy);
	mx = sx; my = sy;

	if(mainmode != MMD_EDIT)
		return;

	if(p.buttons & 2){
		if(!down){
			editmode = (editmode + 1) % 5;
			title();
		}
		down = 1;
		return;
	}

	if(p.buttons & 1){
		if(!down){
			down = 1;
			case editmode {
			EMD_MASS =>
				placemass(wx, wy);
			EMD_SPRING or EMD_CONNECTOR or EMD_THRUSTER or EMD_MOVE =>
				sel = ode->massfind(sim, wx, wy, 0.0);
			}
		}else if(editmode == EMD_MOVE && sel != nil){
			sel.x = wx; sel.y = wy; sel.vx = sel.vy = 0.0;
			nullsprings();
		}
	}else{
		if(down && sel != nil &&
		   (editmode == EMD_SPRING || editmode == EMD_CONNECTOR || editmode == EMD_THRUSTER)){
			m2 := ode->massfind(sim, wx, wy, 0.0);
			if(m2 != nil && m2 != sel)
				placespring(sel, m2, editmode);
		}
		down = 0;
		sel = nil;
	}
}

s2w(sx, sy: int): (real, real)
{
	img := win.image;
	cx := 320; cy := 240;
	if(img != nil){
		cx = img.r.dx()/2;
		cy = img.r.dy()/2;
	}
	# camera follow first mass
	ox := 0.0; oy := 0.0;
	if(sim.masses != nil){
		m := hd sim.masses;
		ox = m.x; oy = m.y;
	}
	return (real(sx - cx)/zoom + ox, real(sy - cy)/zoom + oy);
}

w2s(wx, wy: real): Point
{
	img := win.image;
	cx := 320; cy := 240;
	if(img != nil){
		cx = img.r.dx()/2;
		cy = img.r.dy()/2;
	}
	ox := 0.0; oy := 0.0;
	if(sim.masses != nil){
		m := hd sim.masses;
		ox = m.x; oy = m.y;
	}
	return Point(cx + int((wx - ox)*zoom), cy + int((wy - oy)*zoom));
}

placemass(x, y: real)
{
	m := ref Mass(x, y, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 100.0, 0, 0, real RADIUS, 0);
	ode->addmass(sim, m);
}

placespring(a, b: ref Mass, typ: int)
{
	d := dist(a, b);
	if(d < 1.0)
		d = 1.0;
	c := 2500000.0 / (d*d);
	if(typ == EMD_THRUSTER)
		c = 0.0;
	s := ref Spring(a, b, c, d, 0.0, 0.0, 0, 0, 0);
	ode->addspring(sim, s);
	springs = ref SSpring(s, typ, nextkey) :: springs;
}

dist(a, b: ref Mass): real
{
	dx := a.x-b.x; dy := a.y-b.y;
	return math->sqrt(dx*dx+dy*dy);
}

nullsprings()
{
	for(l := springs; l != nil; l = tl l){
		ss := hd l;
		ss.s.restlen = dist(ss.s.end1, ss.s.end2);
	}
}

key(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		exit;
	' ' =>
		mainmode ^= 1;
		ode->pause(sim, mainmode == MMD_EDIT);
		if(mainmode == MMD_PLAY){
			sim.drag_v2 = 0.000002;
			sim.drag_v3 = 0.0000001;
		}
		title();
	'\n' =>
		reset();
		title();
	'm' =>
		editmode = EMD_MASS; title();
	's' =>
		editmode = EMD_SPRING; title();
	'n' =>
		editmode = EMD_CONNECTOR; title();
	't' =>
		editmode = EMD_THRUSTER; title();
	'v' =>
		editmode = EMD_MOVE; title();
	'c' =>
		centermasses();
	'd' =>
		if(mainmode == MMD_PLAY){
			sim.drag_v2 = 0.002;
			sim.drag_v3 = 0.0001;
		}
	'z' =>
		zoom *= 1.25;
		if(zoom > 50.0) zoom = 50.0;
	'Z' =>
		zoom *= 0.8;
		if(zoom < 0.02) zoom = 0.02;
	'0' to '9' =>
		nextkey = k;
		if(mainmode == MMD_PLAY){
			held[k-'0'] = 1;
			if(have_tone)
				tone->beep(200 + (k-'0')*40, 80);
		}
		title();
	(Keyboard->Keyup | '0') to (Keyboard->Keyup | '9') =>
		held[(k & 16r7ff)-'0'] = 0;
	}
}

centermasses()
{
	if(sim.masses == nil)
		return;
	m0 := hd sim.masses;
	ox := m0.x; oy := m0.y;
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		m.x -= ox; m.y -= oy;
	}
}

breakconnectors()
{
	nl: list of ref SSpring;
	for(l := springs; l != nil; l = tl l){
		ss := hd l;
		if(ss.typ == EMD_CONNECTOR && ss.key >= '0' && ss.key <= '9' &&
		   held[ss.key-'0']){
			ode->remspring(sim, ss.s);
		}else
			nl = ss :: nl;
	}
	springs = nl;
}

step()
{
	ode->clearforces(sim);
	# soft collisions
	for(l1 := sim.masses; l1 != nil; l1 = tl l1){
		m1 := hd l1;
		for(l2 := tl l1; l2 != nil; l2 = tl l2){
			m2 := hd l2;
			dx := m2.x - m1.x;
			dy := m2.y - m1.y;
			dd := dx*dx + dy*dy;
			rr := real(2*RADIUS);
			if(dd <= rr*rr){
				d := math->sqrt(dd) + 0.0001;
				gap := rr*rr - dd;
				g2 := gap*gap; g4 := g2*g2;
				force := 10.0 * g4*g4;
				s := force / d;
				m2.fx += dx*s; m2.fy += dy*s;
				m1.fx -= dx*s; m1.fy -= dy*s;
			}
		}
	}
	# thrusters
	for(l := springs; l != nil; l = tl l){
		ss := hd l;
		if(ss.typ == EMD_THRUSTER && ss.key >= '0' && ss.key <= '9' &&
		   held[ss.key-'0']){
			dx := ss.s.end2.x - ss.s.end1.x;
			dy := ss.s.end2.y - ss.s.end1.y;
			d := math->sqrt(dx*dx + dy*dy);
			if(d > 0.0){
				ss.s.end1.fx += 2000.0 * dx / d;
				ss.s.end1.fy += 2000.0 * dy / d;
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
	bg := ink[8];
	if(mainmode == MMD_PLAY)
		bg = ink[0];
	img.draw(img.r, bg, nil, Point(0, 0));
	o := img.r.min;

	if(mainmode == MMD_PLAY){
		# stars
		for(i := 0; i < 80; i++){
			x := rn(img.r.dx());
			y := rn(img.r.dy());
			img.draw(Rect((o.x+x, o.y+y), (o.x+x+1, o.y+y+1)), ink[15], nil, Point(0, 0));
		}
	}

	for(l := springs; l != nil; l = tl l){
		ss := hd l;
		p1 := w2s(ss.s.end1.x, ss.s.end1.y).add(o);
		p2 := w2s(ss.s.end2.x, ss.s.end2.y).add(o);
		col := ink[11];
		if(ss.typ == EMD_CONNECTOR)
			col = ink[3];
		if(ss.typ == EMD_THRUSTER)
			col = ink[14];
		img.line(p1, p2, 0, 0, 0, col, Point(0, 0));
	}
	if(down && sel != nil &&
	   (editmode == EMD_SPRING || editmode == EMD_CONNECTOR || editmode == EMD_THRUSTER)){
		p1 := w2s(sel.x, sel.y).add(o);
		img.line(p1, Point(mx, my).add(o), 0, 0, 0, ink[4], Point(0, 0));
	}
	for(lm := sim.masses; lm != nil; lm = tl lm){
		m := hd lm;
		p := w2s(m.x, m.y).add(o);
		r := int(real RADIUS * zoom);
		if(r < 2) r = 2;
		img.fillellipse(p, r, r, ink[7], Point(0, 0));
		img.ellipse(p, r, r, 0, ink[15], Point(0, 0));
	}
	img.flush(Draw->Flushnow);
}

rn(n: int): int
{
	if(n <= 0) return 0;
	if(rand == nil) return sys->millisec() % n;
	return rand->rand(n);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
