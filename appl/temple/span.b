implement Span;

# TempleOS Apps/Span — ODE bridge builder
# m=mass c=concrete s=steel w=wire v=move d=delete
# space=run/stop  Enter=restart  n=new  RMB=cycle mode  q=quit

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

Span: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

STRENGTH: con 1.5e7;
SPRING_SC: con 6.0e6;
COST_SC: con 375.0;
MASS_R: con 3.0;
MASS_M: con 10.0;
WIRE_PCT: con 0.99;

MD_MASS, MD_CONCRETE, MD_STEEL, MD_WIRE, MD_MOVE, MD_DELETE, MD_NUM: con iota;
modenames := array[] of {"mass", "concrete", "steel", "wire", "move", "delete"};

SMass: adt {
	m:	ref Mass;
	cost:	real;
	load_t:	real;
	color:	int;
};

SSpring: adt {
	s:	ref Spring;
	comp, tens:	real;
	base_comp, base_tens, base_const, base_cost: real;
	color:	int;
	thick:	int;
};

win: ref Window;
sim: ref ODE;
ink: array of ref Image;
smasses: list of ref SMass;
ssprings: list of ref SSpring;
mode := MD_MASS;
running := 0;
elapsed := 0.0;
run_t0 := 0;
mx, my: int;
down := 0;
sel: ref SMass;
cursor: ref SMass;
drag_line := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	ode = load Ode Ode->PATH;
	if(ode == nil){
		sys->fprint(sys->fildes(2), "span: no ode\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	ode->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Span", Wmclient->Appl);
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

	bridgeinit();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
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
		if(running){
			step();
			breaksprings();
			adjustloads();
		}
		redraw();
	}
}

title()
{
	win.settitle(sys->sprint("Span [%s] %s cost=%.0f  space=run m/c/s/w/v/d",
		modenames[mode], runstr(), cost()));
}

runstr(): string
{
	if(running)
		return "RUNNING";
	return "stopped";
}

cost(): real
{
	r := 0.0;
	for(lm := smasses; lm != nil; lm = tl lm)
		r += (hd lm).cost;
	for(ls := ssprings; ls != nil; ls = tl ls)
		r += springcost(hd ls);
	return r;
}

springcost(ss: ref SSpring): real
{
	return ss.base_cost * ss.s.restlen;
}

bridgeinit()
{
	sim = ode->new();
	sim.drag_v2 = 0.002;
	sim.drag_v3 = 0.00001;
	sim.accel_limit = 5000.0;
	sim.h = 0.005;
	ode->pause(sim, 1);
	smasses = nil;
	ssprings = nil;
	running = 0;
	elapsed = 0.0;
	sel = nil;
	cursor = nil;

	# fixed banks (approx FONT coords → pixels)
	fx1 := 32.0; fx2 := 8.0; fx3 := 320.0;
	fy1 := 200.0; fy2 := 240.0; fy3 := 400.0;
	w := 640.0;
	placemass(w-fx1, fy1, 1, 0.0, 14);	# fixed yellow
	placemass(w-fx2, fy1, 1, 0.0, 14);
	placemass(w-fx1, fy2, 1, 0.0, 14);
	placemass(fx1, fy1, 1, 0.0, 14);
	placemass(fx2, fy1, 1, 0.0, 14);
	placemass(fx1, fy2, 1, 0.0, 14);
	placemass(fx3, fy3, 1, 0.0, 14);
	for(i := 0; i < 8; i++){
		x := fx1 + real(i+1)*(w-2.0*fx1)/9.0;
		placemass(x, fy1, 0, real(i+1)/8.0, 4);	# red loads
	}
}

placemass(x, y: real, isfixed: int, load_t: real, color: int): ref SMass
{
	m := ref Mass(x, y, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, MASS_M, 1.0, 0, 0, MASS_R, 0);
	if(isfixed)
		m.flags |= Ode->MSF_FIXED;
	ode->addmass(sim, m);
	sm := ref SMass(m, 25.0*COST_SC, load_t, color);
	smasses = sm :: smasses;
	return sm;
}

nullspring(ss: ref SSpring, scale: real)
{
	d := dist(ss.s.end1, ss.s.end2);
	ss.s.restlen = d * scale;
	ss.comp = ss.base_comp / (ss.s.restlen + 1.0);
	ss.tens = ss.base_tens / (ss.s.restlen + 1.0);
	ss.s.const = ss.base_const / (ss.s.restlen + 1.0);
}

placespring(a, b: ref SMass)
{
	if(a == nil || b == nil || a == b)
		return;
	s := ref Spring(a.m, b.m, 0.0, 0.0, 0.0, 0.0, 0, 0, 0);
	ss := ref SSpring(s, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0, 1);
	case mode {
	MD_CONCRETE =>
		ss.base_const = 3.00*SPRING_SC;
		ss.base_comp = 10.00*STRENGTH;
		ss.base_tens = 0.35*STRENGTH;
		ss.base_cost = 0.30*COST_SC;
		ss.color = 7; ss.thick = 2;
		nullspring(ss, 1.0);
	MD_STEEL =>
		ss.base_const = 1.00*SPRING_SC;
		ss.base_comp = 1.00*STRENGTH;
		ss.base_tens = 1.00*STRENGTH;
		ss.base_cost = 1.00*COST_SC;
		ss.color = 8; ss.thick = 2;
		nullspring(ss, 1.0);
	MD_WIRE =>
		ss.base_const = 0.25*SPRING_SC;
		ss.base_comp = 0.0;
		ss.base_tens = 0.50*STRENGTH;
		ss.base_cost = 0.10*COST_SC;
		ss.color = 4; ss.thick = 1;
		s.flags |= Ode->SSF_NO_COMPRESSION;
		nullspring(ss, WIRE_PCT);
	* =>
		return;
	}
	ode->addspring(sim, s);
	ssprings = ss :: ssprings;
}

dist(a, b: ref Mass): real
{
	dx := a.x - b.x;
	dy := a.y - b.y;
	return math->sqrt(dx*dx + dy*dy);
}

findmass(x, y: real): ref SMass
{
	best: ref SMass;
	bestd := 1e300;
	for(l := smasses; l != nil; l = tl l){
		sm := hd l;
		if(sm.m.flags & Ode->MSF_INACTIVE)
			continue;
		d := (sm.m.x-x)*(sm.m.x-x) + (sm.m.y-y)*(sm.m.y-y);
		if(d < bestd){
			bestd = d;
			best = sm;
		}
	}
	return best;
}

delmass(sm: ref SMass)
{
	if(sm == nil)
		return;
	nl: list of ref SSpring;
	for(l := ssprings; l != nil; l = tl l){
		ss := hd l;
		if(ss.s.end1 == sm.m || ss.s.end2 == sm.m)
			ode->remspring(sim, ss.s);
		else
			nl = ss :: nl;
	}
	ssprings = nl;
	ode->remmass(sim, sm.m);
	nm: list of ref SMass;
	for(lm := smasses; lm != nil; lm = tl lm)
		if(hd lm != sm)
			nm = hd lm :: nm;
	smasses = nm;
}

delspringnear(x, y: real)
{
	best: ref SSpring;
	bestd := 40.0*40.0;
	for(l := ssprings; l != nil; l = tl l){
		ss := hd l;
		cx := (ss.s.end1.x + ss.s.end2.x)/2.0;
		cy := (ss.s.end1.y + ss.s.end2.y)/2.0;
		d := (cx-x)*(cx-x)+(cy-y)*(cy-y);
		if(d < bestd){
			bestd = d;
			best = ss;
		}
	}
	if(best == nil)
		return;
	ode->remspring(sim, best.s);
	nl: list of ref SSpring;
	for(ls := ssprings; ls != nil; ls = tl ls)
		if(hd ls != best)
			nl = hd ls :: nl;
	ssprings = nl;
}

movemass(sm: ref SMass, x, y: real)
{
	if(sm == nil || (sm.m.flags & Ode->MSF_FIXED))
		return;
	sm.m.x = x; sm.m.y = y;
	sm.m.vx = sm.m.vy = 0.0;
	for(l := ssprings; l != nil; l = tl l){
		ss := hd l;
		if(ss.s.end1 == sm.m || ss.s.end2 == sm.m){
			if(ss.s.flags & Ode->SSF_NO_COMPRESSION)
				nullspring(ss, WIRE_PCT);
			else
				nullspring(ss, 1.0);
		}
	}
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	mx = x; my = y;
	rx := real x; ry := real y;

	if(p.buttons & 2){
		# edge: cycle mode
		if(!down){
			mode = (mode + 1) % MD_NUM;
			title();
		}
		down = 1;
		return;
	}

	if(p.buttons & 1){
		if(!down){
			down = 1;
			case mode {
			MD_MASS =>
				if(!running)
					placemass(rx, ry, 0, 0.0, 14);
			MD_CONCRETE or MD_STEEL or MD_WIRE =>
				sel = findmass(rx, ry);
				drag_line = 1;
			MD_MOVE =>
				sel = findmass(rx, ry);
				if(running)
					cursor = sel;
				else
					movemass(sel, rx, ry);
			MD_DELETE =>
				if(!running){
					sm := findmass(rx, ry);
					if(sm != nil && (sm.m.flags & Ode->MSF_FIXED) == 0 && sm.load_t == 0.0)
						delmass(sm);
					else
						delspringnear(rx, ry);
				}
			}
		}else{
			case mode {
			MD_MOVE =>
				if(!running)
					movemass(sel, rx, ry);
			}
		}
	}else{
		if(down && drag_line && sel != nil &&
		   (mode == MD_CONCRETE || mode == MD_STEEL || mode == MD_WIRE)){
			sm2 := findmass(rx, ry);
			if(sm2 != nil)
				placespring(sel, sm2);
		}
		down = 0;
		drag_line = 0;
		sel = nil;
		cursor = nil;
	}
}

key(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		exit;
	' ' =>
		running = !running;
		ode->pause(sim, !running);
		if(running)
			run_t0 = sys->millisec();
		else
			elapsed += real(sys->millisec() - run_t0) / 1000.0;
		title();
	'\n' =>
		bridgeinit();
		title();
	'n' or 'N' =>
		bridgeinit();
		title();
	'm' =>
		mode = MD_MASS; title();
	'c' =>
		mode = MD_CONCRETE; title();
	's' =>
		mode = MD_STEEL; title();
	'w' =>
		mode = MD_WIRE; title();
	'v' =>
		mode = MD_MOVE; title();
	'd' =>
		mode = MD_DELETE; title();
	}
}

step()
{
	ode->clearforces(sim);
	# collisions + gravity
	for(l1 := smasses; l1 != nil; l1 = tl l1){
		m1 := (hd l1).m;
		if(m1.flags & Ode->MSF_INACTIVE)
			continue;
		if((m1.flags & Ode->MSF_FIXED) == 0)
			m1.fy += 10.0 * m1.mass;
		for(l2 := tl l1; l2 != nil; l2 = tl l2){
			m2 := (hd l2).m;
			dx := m2.x - m1.x;
			dy := m2.y - m1.y;
			dd := dx*dx + dy*dy;
			rr := m1.radius + m2.radius;
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
	if(cursor != nil){
		dx := real mx - cursor.m.x;
		dy := real my - cursor.m.y;
		d := 10.0 * (dx*dx + dy*dy);
		cursor.m.fx += dx * d;
		cursor.m.fy += dy * d;
	}
	ode->update(sim, 0.016);
}

breaksprings()
{
	for(l := ssprings; l != nil; l = tl l){
		ss := hd l;
		if(ss.s.flags & Ode->SSF_INACTIVE)
			continue;
		f := ss.s.f;
		# match TempleOS SpanMain break test
		if(f > 0.0 && f > ss.comp && (ss.s.flags & Ode->SSF_NO_COMPRESSION) == 0)
			ss.s.flags |= Ode->SSF_INACTIVE;
		if(f < 0.0 && -f > ss.tens && (ss.s.flags & Ode->SSF_NO_TENSION) == 0)
			ss.s.flags |= Ode->SSF_INACTIVE;
	}
}

adjustloads()
{
	tt := spannertime() / 10.0;
	for(l := smasses; l != nil; l = tl l){
		sm := hd l;
		if(sm.load_t == 0.0)
			continue;
		if(tt > 0.0){
			d := math->fabs(math->sin(sm.load_t * Math->Pi + tt));
			sm.m.mass = 100.0 * (d+1.0)*(d+1.0)*(d+1.0)*(d+1.0);
			sm.m.radius = 7.0*d + 2.0;
		}else{
			sm.m.mass = MASS_M;
			sm.m.radius = MASS_R;
		}
	}
}

spannertime(): real
{
	if(running)
		return elapsed + real(sys->millisec() - run_t0) / 1000.0;
	return elapsed;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	# sky / banks
	img.draw(img.r, ink[11], nil, Point(0, 0));	# cyan-ish
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	img.draw(Rect((o.x, o.y+h-80), (o.x+40, o.y+h)), ink[6], nil, Point(0, 0));
	img.draw(Rect((o.x+w-40, o.y+h-80), (o.x+w, o.y+h)), ink[6], nil, Point(0, 0));
	img.draw(Rect((o.x+40, o.y+h-40), (o.x+w-40, o.y+h)), ink[1], nil, Point(0, 0));

	for(ls := ssprings; ls != nil; ls = tl ls){
		ss := hd ls;
		if(ss.s.flags & Ode->SSF_INACTIVE)
			continue;
		img.line(Point(int ss.s.end1.x, int ss.s.end1.y).add(o),
			Point(int ss.s.end2.x, int ss.s.end2.y).add(o),
			0, 0, ss.thick, ink[ss.color], Point(0, 0));
	}
	if(drag_line && sel != nil)
		img.line(Point(int sel.m.x, int sel.m.y).add(o), Point(mx, my).add(o),
			0, 0, 1, ink[4], Point(0, 0));
	if(cursor != nil)
		img.line(Point(mx, my).add(o), Point(int cursor.m.x, int cursor.m.y).add(o),
			0, 0, 1, ink[4], Point(0, 0));

	for(lm := smasses; lm != nil; lm = tl lm){
		sm := hd lm;
		m := sm.m;
		if(m.flags & Ode->MSF_INACTIVE)
			continue;
		r := int m.radius;
		if(r < 2) r = 2;
		img.fillellipse(Point(int m.x, int m.y).add(o), r, r, ink[sm.color], Point(0, 0));
		img.ellipse(Point(int m.x, int m.y).add(o), r, r, 0, ink[0], Point(0, 0));
	}
	title();
	img.flush(Draw->Flushnow);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
