implement Span;

# TempleOS Apps/Span — ODE bridge builder
# m=mass c=concrete s=steel w=wire v=move d=delete
# space=run/stop  Enter=restart  Ctrl-N=new  Ctrl-O=open  Ctrl-A=save-as
# Esc=save+exit  q=abort (no save)  RMB=cycle mode
# On-screen run/mode buttons at top-left, HUD cost/time at (90,0)/(90,8).
#
# Original: Apps/Span/* (Span.HH, SpanMain.HC, SpanBridge.HC, SpanDerive.HC,
# SpanNew.HC).  The original AnimateTask snapshots the design (SpanSave) the
# moment run starts and Init() restores it (SpanLoad), so Enter brings back
# your pre-run bridge; Ctrl-N resets to the default bridge; Ctrl-O/Ctrl-A do
# file open/save-as under ~/Span.  All of that is mirrored here: an in-memory
# snapshot plus a text-format save file under $home/span, with in-window
# overlays standing in for PopUpFileName/PopUpPickFile/PopUpOk.
#
# GAP: TempleOS's pulldown menu bar (File/Play) is not rendered; every menu
#   action is on a key or button.  Shift-Esc (abort) is 'q' here, since the
#   kbd channel cannot distinguish Shift-Esc from Esc.
# GAP: the CtrlBttns are drawn as simple bevelled buttons, not pixel-exact
#   TempleOS chrome.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;

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

include "env.m";
	env: Env;

include "readdir.m";
	readdir: Readdir;
include "grpalette.m";
	grpal: Grpalette;

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

# TempleOS palette indices
BLACK, BLUE, GREEN, CYAN, RED, PURPLE, BROWN, LTGRAY,
DKGRAY, LTBLUE, LTGREEN, LTCYAN, LTRED, LTPURPLE, YELLOW, WHITE: con iota;

MD_MASS, MD_CONCRETE, MD_STEEL, MD_WIRE, MD_MOVE, MD_DELETE, MD_NUM: con iota;
modenames := array[] of {"Mass", "Concrete", "Steel", "Wire", "Move", "Delete"};
# CtrlBttn text colors, straight from Span.HH
modecolors := array[] of {BROWN, LTGRAY, DKGRAY, RED, PURPLE, RED};
runcolors := array[] of {RED, GREEN};	# Stopped, Running

# fixed anchors — SpanBridge.HC, FONT 8x8, TEXT_COLS 80, TEXT_ROWS 60:
# FIXED_X1=(5-1)*8=32  FIXED_X2=(5-4)*8=8  FIXED_X3=40*8=320
# FIXED_Y1=(40+1)*8=328  FIXED_Y2=(40+5)*8=360  FIXED_Y3=(60-8)*8=416
FX1: con 32.0;
FX2: con 8.0;
FX3: con 320.0;
FY1: con 328.0;
FY2: con 360.0;
FY3: con 416.0;
GRW: con 640.0;

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

# in-memory SpanSave/SpanLoad image of the design
SnapMass: adt {
	x, y:	real;
	flags:	int;
	cost, load_t:	real;
	color:	int;
};

SnapSpring: adt {
	i1, i2:	int;
	konst, restlen:	real;
	flags, color, thick:	int;
	comp, tens, base_comp, base_tens, base_const, base_cost:	real;
};

# popup (overlay) states
P_NONE, P_INSTR, P_SAVE, P_OPEN: con iota;

win: ref Window;
sim: ref ODE;
ink: array of ref Image;
font: ref Font;
smasses: list of ref SMass;
ssprings: list of ref SSpring;
mode := MD_MASS;
running := 0;
elapsed := 0.0;
run_t0 := 0;
lastms := 0;
mx, my: int;
down := 0;
sel: ref SMass;
cursor: ref SMass;
drag_line := 0;

snapm: array of SnapMass;
snaps: array of SnapSpring;
have_snap := 0;

popup := P_NONE;
pending_exit := 0;
savename := "";
openents: array of string;
opensel := 0;

have_tone := 0;
song_stop := 0;

# CtrlBttnNew(0,0,80,...) and (0,3*FONT_HEIGHT,80,...)
runbtn := Rect((0, 0), (80, 20));
modebtn := Rect((0, 24), (80, 44));

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	ode = load Ode Ode->PATH;
	if(ode == nil){
		sys->fprint(sys->fildes(2), "span: no ode\n");
		raise "fail:load";
	}
	env = load Env Env->PATH;
	readdir = load Readdir Readdir->PATH;
	tone = load Tone Tone->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	ode->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Span", Wmclient->Appl);
	d := win.display;
	ink = array[16] of ref Image;
	# the exact TempleOS 16 colors, index = TempleOS color number
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "*default*");

	bridgeinit();
	popup = P_INSTR;	# the original's startup PopUpOk
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	title();

	if(have_tone)
		spawn songloop();

	lastms = sys->millisec();
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
		now := sys->millisec();
		if(running){
			# original ODE integrates continuously in real time
			# (ODENew(0,1e-4), stepped once per ~30fps Refresh);
			# here: elapsed wall dt per 16ms tick, clamped.
			dt := real(now - lastms) / 1000.0;
			if(dt > 0.05)
				dt = 0.05;
			if(dt > 0.0)
				step(dt);
		}
		lastms = now;
		# AnimateTask runs break test + AdjustLoads every frame
		breaksprings();
		adjustloads();
		redraw();
	}
}

quit()
{
	song_stop = 1;
	if(have_tone)
		tone->stop();
	exit;
}

title()
{
	win.settitle(sys->sprint("Span [%s] %s cost=%.0f",
		modenames[mode], runstr(), cost()));
}

runstr(): string
{
	if(running)
		return "Running";
	return "Stopped";
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

siminit()
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
	down = 0;
	drag_line = 0;
}

# SpanBridge1Init: default 7 anchors + 8 red loads
bridgeinit()
{
	siminit();
	placemass(GRW-FX1, FY1, 1, 0.0, YELLOW);
	placemass(GRW-FX2, FY1, 1, 0.0, YELLOW);
	placemass(GRW-FX1, FY2, 1, 0.0, YELLOW);
	placemass(FX1, FY1, 1, 0.0, YELLOW);
	placemass(FX2, FY1, 1, 0.0, YELLOW);
	placemass(FX1, FY2, 1, 0.0, YELLOW);
	placemass(FX3, FY3, 1, 0.0, YELLOW);
	for(i := 0; i < 8; i++){
		x := FX1 + real(i+1)*(GRW-2.0*FX1)/9.0;
		placemass(x, FY1, 0, real(i+1)/8.0, RED);	# red loads
	}
}

# Init(&a): restore the saved design if there is one, else default bridge
reinit()
{
	if(have_snap)
		restoresnap();
	else
		bridgeinit();
	title();
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
		ss.color = LTGRAY; ss.thick = 2;
		nullspring(ss, 1.0);
	MD_STEEL =>
		ss.base_const = 1.00*SPRING_SC;
		ss.base_comp = 1.00*STRENGTH;
		ss.base_tens = 1.00*STRENGTH;
		ss.base_cost = 1.00*COST_SC;
		ss.color = DKGRAY; ss.thick = 2;
		nullspring(ss, 1.0);
	MD_WIRE =>
		ss.base_const = 0.25*SPRING_SC;
		ss.base_comp = 0.0;
		ss.base_tens = 0.50*STRENGTH;
		ss.base_cost = 0.10*COST_SC;
		ss.color = RED; ss.thick = 1;
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

delspring(ss: ref SSpring)
{
	if(ss == nil)
		return;
	ode->remspring(sim, ss.s);
	nl: list of ref SSpring;
	for(ls := ssprings; ls != nil; ls = tl ls)
		if(hd ls != ss)
			nl = hd ls :: nl;
	ssprings = nl;
}

# squared distance from point to segment
seg2(px, py, x1, y1, x2, y2: real): real
{
	dx := x2 - x1;
	dy := y2 - y1;
	dd := dx*dx + dy*dy;
	t := 0.0;
	if(dd > 0.0){
		t = ((px-x1)*dx + (py-y1)*dy) / dd;
		if(t < 0.0)
			t = 0.0;
		if(t > 1.0)
			t = 1.0;
	}
	cx := x1 + t*dx - px;
	cy := y1 + t*dy - py;
	return cx*cx + cy*cy;
}

# MassOrSpringFind → DelMass/DelSpring: mass or spring, whichever is nearer;
# works while running and on fixed anchors and load masses too.
deleteat(x, y: real)
{
	sm := findmass(x, y);
	dm := 1e300;
	if(sm != nil)
		dm = (sm.m.x-x)*(sm.m.x-x) + (sm.m.y-y)*(sm.m.y-y);
	bs: ref SSpring;
	ds := 1e300;
	for(l := ssprings; l != nil; l = tl l){
		ss := hd l;
		d := seg2(x, y, ss.s.end1.x, ss.s.end1.y, ss.s.end2.x, ss.s.end2.y);
		if(d < ds){
			ds = d;
			bs = ss;
		}
	}
	cap := 32.0*32.0;
	if(dm > cap && ds > cap)
		return;
	if(dm <= ds)
		delmass(sm);
	else
		delspring(bs);
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

# run start snapshots the design (AnimateTask: SpanSave when
# !elapsed_t || !saved_ode), so restart can restore it
togglerun()
{
	running = !running;
	ode->pause(sim, !running);
	if(running){
		if(elapsed == 0.0 || !have_snap)
			snapshot();
		run_t0 = sys->millisec();
	}else
		elapsed += real(sys->millisec() - run_t0) / 1000.0;
	title();
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

	if(popup != P_NONE){
		if((p.buttons & 1) && !down){
			down = 1;
			popupclick(x, y);
		}else if(!(p.buttons & 1))
			down = 0;
		return;
	}

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
			pt := Point(x, y);
			if(pt.in(runbtn)){
				togglerun();
				return;
			}
			if(pt.in(modebtn)){
				mode = (mode + 1) % MD_NUM;
				title();
				return;
			}
			case mode {
			MD_MASS =>
				placemass(rx, ry, 0, 0.0, YELLOW);
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
				deleteat(rx, ry);
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
	if(popup != P_NONE){
		popupkey(k);
		return;
	}
	case k {
	16r1b =>
		# CH_ESC: save the design, offer SaveAs, then exit
		if(spantime() == 0.0 || !have_snap)
			snapshot();
		reinit();
		pending_exit = 1;
		startsave();
	'q' or 'Q' =>
		# CH_SHIFT_ESC: abort without saving
		quit();
	' ' =>
		togglerun();
	'\n' =>
		# Restart: original saves the design first if it never ran
		if(spantime() == 0.0 || !have_snap)
			snapshot();
		reinit();
	14 or 'n' or 'N' =>
		# CH_CTRLN: forget the save, back to the default bridge
		have_snap = 0;
		snapm = nil;
		snaps = nil;
		reinit();
	15 or 'o' or 'O' =>
		# CH_CTRLO: open a saved game
		startopen();
	1 or 'a' or 'A' =>
		# CH_CTRLA: SaveAs
		if(spantime() == 0.0 || !have_snap)
			snapshot();
		reinit();
		startsave();
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

step(dt: real)
{
	ode->clearforces(sim);
	# collisions + gravity (MyDerivative)
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
				# 10*Sqr(Sqr(Sqr(r1+r2)-dd)) = 10*((rr^2-dd)^2)^2
				gap := rr*rr - dd;
				g2 := gap*gap;
				force := 10.0 * g2*g2;
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
	ode->update(sim, dt);
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
	tt := spantime() / 10.0;
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

spantime(): real
{
	if(running)
		return elapsed + real(sys->millisec() - run_t0) / 1000.0;
	return elapsed;
}

# ---------- SpanSave/SpanLoad: in-memory snapshot ----------

# creation order: smasses/ssprings lists are newest-first
massarray(): array of ref SMass
{
	n := 0;
	for(l := smasses; l != nil; l = tl l)
		n++;
	a := array[n] of ref SMass;
	i := n;
	for(l = smasses; l != nil; l = tl l)
		a[--i] = hd l;
	return a;
}

springarray(): array of ref SSpring
{
	n := 0;
	for(l := ssprings; l != nil; l = tl l)
		n++;
	a := array[n] of ref SSpring;
	i := n;
	for(l = ssprings; l != nil; l = tl l)
		a[--i] = hd l;
	return a;
}

snapshot()
{
	ma := massarray();
	sa := springarray();
	snapm = array[len ma] of SnapMass;
	for(i := 0; i < len ma; i++){
		sm := ma[i];
		snapm[i] = SnapMass(sm.m.x, sm.m.y, sm.m.flags & ~Ode->MSF_INACTIVE,
			sm.cost, sm.load_t, sm.color);
	}
	snaps = array[len sa] of SnapSpring;
	for(i = 0; i < len sa; i++){
		ss := sa[i];
		i1 := -1;
		i2 := -1;
		for(j := 0; j < len ma; j++){
			if(ma[j].m == ss.s.end1)
				i1 = j;
			if(ma[j].m == ss.s.end2)
				i2 = j;
		}
		snaps[i] = SnapSpring(i1, i2, ss.s.const, ss.s.restlen,
			ss.s.flags & ~Ode->SSF_INACTIVE, ss.color, ss.thick,
			ss.comp, ss.tens,
			ss.base_comp, ss.base_tens, ss.base_const, ss.base_cost);
	}
	have_snap = 1;
}

restoresnap()
{
	siminit();
	ma := array[len snapm] of ref SMass;
	for(i := 0; i < len snapm; i++){
		nm := snapm[i];
		sm := placemass(nm.x, nm.y, nm.flags & Ode->MSF_FIXED, nm.load_t, nm.color);
		sm.cost = nm.cost;
		ma[i] = sm;
	}
	for(i = 0; i < len snaps; i++){
		ns := snaps[i];
		if(ns.i1 < 0 || ns.i1 >= len ma || ns.i2 < 0 || ns.i2 >= len ma)
			continue;
		s := ref Spring(ma[ns.i1].m, ma[ns.i2].m,
			ns.konst, ns.restlen, 0.0, 0.0, ns.flags, 0, 0);
		ss := ref SSpring(s, ns.comp, ns.tens,
			ns.base_comp, ns.base_tens, ns.base_const, ns.base_cost,
			ns.color, ns.thick);
		ode->addspring(sim, s);
		ssprings = ss :: ssprings;
	}
}

# ---------- SpanWrite/SpanRead: files under $home/span ----------

spandir(): string
{
	home := "";
	if(env != nil)
		home = env->getenv("home");
	if(home == nil || home == "")
		home = "/tmp";
	dir := home + "/span";
	if(sys->open(dir, Sys->OREAD) == nil)
		sys->create(dir, Sys->OREAD, Sys->DMDIR|8r775);
	return dir;
}

writesave(name: string): string
{
	if(!have_snap)
		return "nothing to save";
	if(name == "")
		return "no name";
	path := name;
	if(path[0] != '/')
		path = spandir() + "/" + path;
	fd := sys->create(path, Sys->OWRITE|Sys->OTRUNC, 8r666);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", path);
	sys->fprint(fd, "span 1\n%d %d\n", len snapm, len snaps);
	for(i := 0; i < len snapm; i++){
		m := snapm[i];
		sys->fprint(fd, "m %g %g %d %g %g %d\n",
			m.x, m.y, m.flags, m.cost, m.load_t, m.color);
	}
	for(i = 0; i < len snaps; i++){
		s := snaps[i];
		sys->fprint(fd, "s %d %d %g %g %d %d %d %g %g %g %g %g %g\n",
			s.i1, s.i2, s.konst, s.restlen, s.flags, s.color, s.thick,
			s.comp, s.tens, s.base_comp, s.base_tens, s.base_const, s.base_cost);
	}
	return nil;
}

readsave(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("cannot open %s: %r", path);
	buf := array[262144] of byte;
	n := 0;
	for(;;){
		m := sys->read(fd, buf[n:], len buf - n);
		if(m <= 0)
			break;
		n += m;
	}
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	if(lines == nil || len hd lines < 4 || (hd lines)[0:4] != "span")
		return "not a span save file";
	lines = tl lines;
	if(lines == nil)
		return "truncated save file";
	(nc, cnt) := sys->tokenize(hd lines, " ");
	if(nc != 2)
		return "bad save header";
	nm := int hd cnt;
	ns := int hd tl cnt;
	if(nm < 0 || ns < 0 || nm > 10000 || ns > 10000)
		return "bad save counts";
	lines = tl lines;
	newm := array[nm] of SnapMass;
	news := array[ns] of SnapSpring;
	mi := 0;
	si := 0;
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " ");
		if(nf < 1)
			continue;
		fa := array[nf] of string;
		for(i := 0; i < nf; i++){
			fa[i] = hd f;
			f = tl f;
		}
		if(fa[0] == "m" && nf >= 7 && mi < nm){
			newm[mi++] = SnapMass(real fa[1], real fa[2], int fa[3],
				real fa[4], real fa[5], int fa[6]);
		}else if(fa[0] == "s" && nf >= 14 && si < ns){
			news[si++] = SnapSpring(int fa[1], int fa[2],
				real fa[3], real fa[4], int fa[5], int fa[6], int fa[7],
				real fa[8], real fa[9], real fa[10], real fa[11],
				real fa[12], real fa[13]);
		}
	}
	if(mi != nm || si != ns)
		return "truncated save file";
	snapm = newm;
	snaps = news;
	have_snap = 1;
	return nil;
}

# ---------- popups (PopUpOk / PopUpFileName / PopUpPickFile) ----------

startsave()
{
	if(savename == "")
		savename = "game.data";
	popup = P_SAVE;
}

startopen()
{
	dir := spandir();
	ents: list of string;
	n := 0;
	if(readdir != nil){
		(d, nil) := readdir->init(dir, Readdir->NAME);
		for(i := 0; i < len d && n < 40; i++){
			if((d[i].mode & Sys->DMDIR) == 0){
				ents = d[i].name :: ents;
				n++;
			}
		}
	}
	openents = array[n] of string;
	for(i := n; ents != nil; ents = tl ents)
		openents[--i] = hd ents;
	opensel = 0;
	popup = P_OPEN;
}

popupkey(k: int)
{
	case popup {
	P_INSTR =>
		if(k == 16r1b || k == '\n' || k == ' ')
			popup = P_NONE;
	P_SAVE =>
		case k {
		16r1b =>
			popup = P_NONE;
			if(pending_exit)
				quit();
		'\n' =>
			writesave(savename);
			popup = P_NONE;
			if(pending_exit)
				quit();
		8 or 127 =>
			if(len savename > 0)
				savename = savename[0:len savename - 1];
		* =>
			if(k >= ' ' && k < 127 && k != '/' && len savename < 40)
				savename[len savename] = k;
		}
	P_OPEN =>
		case k {
		16r1b =>
			popup = P_NONE;
		'\n' =>
			openpick(opensel);
		* =>
			if((k == 'j' || k == Keyboard->Down) && opensel < len openents - 1)
				opensel++;
			if((k == 'k' || k == Keyboard->Up) && opensel > 0)
				opensel--;
		}
	}
}

openpick(i: int)
{
	if(i < 0 || i >= len openents){
		popup = P_NONE;
		return;
	}
	e := readsave(spandir() + "/" + openents[i]);
	popup = P_NONE;
	if(e == nil){
		savename = openents[i];
		reinit();
	}
}

popupclick(nil: int, y: int)
{
	case popup {
	P_INSTR =>
		popup = P_NONE;
	P_OPEN =>
		# rows are laid out by drawopen(); recompute the same geometry
		nl := len openents;
		if(nl == 0)
			nl = 1;
		bh := (nl+4)*8 + 16;
		y0 := (480 - bh)/2 + 8 + 2*8;
		row := (y - y0) / 8;
		if(row >= 0 && row < len openents){
			opensel = row;
			openpick(row);
		}else
			popup = P_NONE;
	}
}

# ---------- drawing ----------

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;

	drawbackground(img, o);

	for(ls := ssprings; ls != nil; ls = tl ls){
		ss := hd ls;
		if(ss.s.flags & Ode->SSF_INACTIVE)
			continue;
		img.line(Point(int ss.s.end1.x, int ss.s.end1.y).add(o),
			Point(int ss.s.end2.x, int ss.s.end2.y).add(o),
			0, 0, ss.thick, ink[ss.color], Point(0, 0));
	}
	# DrawSpring: preview in the material's color and thickness
	if(drag_line && sel != nil){
		pc := RED;
		pt := 1;
		case mode {
		MD_CONCRETE =>
			pc = LTGRAY; pt = 2;
		MD_STEEL =>
			pc = DKGRAY; pt = 2;
		}
		img.line(Point(int sel.m.x, int sel.m.y).add(o), Point(mx, my).add(o),
			0, 0, pt, ink[pc], Point(0, 0));
	}
	# cursor drag: RED thick 2
	if(cursor != nil)
		img.line(Point(mx, my).add(o), Point(int cursor.m.x, int cursor.m.y).add(o),
			0, 0, 2, ink[RED], Point(0, 0));

	for(lm := smasses; lm != nil; lm = tl lm){
		sm := hd lm;
		m := sm.m;
		if(m.flags & Ode->MSF_INACTIVE)
			continue;
		r := int m.radius;
		if(r < 2) r = 2;
		img.fillellipse(Point(int m.x, int m.y).add(o), r, r, ink[sm.color], Point(0, 0));
		img.ellipse(Point(int m.x, int m.y).add(o), r, r, 0, ink[BLACK], Point(0, 0));
	}

	drawbutton(img, o, runbtn, runstr(), runcolors[running]);
	drawbutton(img, o, modebtn, modenames[mode], modecolors[mode]);
	drawhud(img, o);

	case popup {
	P_INSTR =>
		drawinstr(img, o);
	P_SAVE =>
		drawsave(img, o);
	P_OPEN =>
		drawopen(img, o);
	}

	title();
	img.flush(Draw->Flushnow);
}

# SpanBridge1Init's colored-text background: 40 LTCYAN sky lines, 10 rows of
# BROWN banks 5 cols wide, 5 stepped rows widening by i with a center BROWN
# pier 2i wide splitting the BLUE river, brown below (doc bg is BROWN).
drawbackground(img: ref Image, o: Point)
{
	img.draw(Rect((o.x, o.y), (o.x+640, o.y+400)), ink[LTCYAN], nil, Point(0, 0));
	img.draw(Rect((o.x, o.y+320), (o.x+40, o.y+400)), ink[BROWN], nil, Point(0, 0));
	img.draw(Rect((o.x+600, o.y+320), (o.x+640, o.y+400)), ink[BROWN], nil, Point(0, 0));
	for(i := 0; i < 5; i++){
		y0 := o.y + 400 + 8*i;
		y1 := y0 + 8;
		lb := 8*(5+i);		# left bank cols
		p0 := 8*(40-i);		# pier start
		p1 := 8*(40+i);		# pier end
		rb := 8*(75-i);		# right bank start
		img.draw(Rect((o.x, y0), (o.x+lb, y1)), ink[BROWN], nil, Point(0, 0));
		img.draw(Rect((o.x+lb, y0), (o.x+p0, y1)), ink[BLUE], nil, Point(0, 0));
		if(p1 > p0)
			img.draw(Rect((o.x+p0, y0), (o.x+p1, y1)), ink[BROWN], nil, Point(0, 0));
		img.draw(Rect((o.x+p1, y0), (o.x+rb, y1)), ink[BLUE], nil, Point(0, 0));
		img.draw(Rect((o.x+rb, y0), (o.x+640, y1)), ink[BROWN], nil, Point(0, 0));
	}
	img.draw(Rect((o.x, o.y+440), (o.x+640, o.y+480)), ink[BROWN], nil, Point(0, 0));
}

# CtrlBttn: LTGRAY face, bevel, label in the state color
drawbutton(img: ref Image, o: Point, r: Rect, label: string, color: int)
{
	rr := r.addpt(o);
	img.draw(rr, ink[LTGRAY], nil, Point(0, 0));
	img.line(rr.min, Point(rr.max.x-1, rr.min.y), 0, 0, 0, ink[WHITE], Point(0, 0));
	img.line(rr.min, Point(rr.min.x, rr.max.y-1), 0, 0, 0, ink[WHITE], Point(0, 0));
	img.line(Point(rr.min.x, rr.max.y-1), Point(rr.max.x-1, rr.max.y-1),
		0, 0, 0, ink[DKGRAY], Point(0, 0));
	img.line(Point(rr.max.x-1, rr.min.y), Point(rr.max.x-1, rr.max.y-1),
		0, 0, 0, ink[DKGRAY], Point(0, 0));
	if(font != nil){
		w := font.width(label);
		img.text(Point(rr.min.x + (r.dx()-w)/2, rr.min.y + (r.dy()-font.height)/2),
			ink[color], Point(0, 0), font, label);
	}
}

# DrawIt HUD: BLACK at x=90, y=0/FONT_HEIGHT — Cost comma-grouped
drawhud(img: ref Image, o: Point)
{
	if(font == nil)
		return;
	img.text(o.add(Point(90, 0)), ink[BLACK], Point(0, 0), font,
		sys->sprint("Cost:%12s", commafmt(cost())));
	img.text(o.add(Point(90, 8)), ink[BLACK], Point(0, 0), font,
		sys->sprint("Time:%12.2f", spantime()));
}

# %12.2,f — thousands separated with commas
commafmt(r: real): string
{
	s := sys->sprint("%.2f", r);
	neg := "";
	if(len s > 0 && s[0] == '-'){
		neg = "-";
		s = s[1:];
	}
	dot := len s;
	for(i := 0; i < len s; i++)
		if(s[i] == '.'){
			dot = i;
			break;
		}
	ip := s[0:dot];
	rest := s[dot:];
	out := "";
	for(i = 0; i < len ip; i++){
		if(i > 0 && (len ip - i) % 3 == 0)
			out += ",";
		out[len out] = ip[i];
	}
	return neg + out + rest;
}

popupbox(img: ref Image, o: Point, bw, bh: int): Point
{
	x0 := o.x + (640 - bw)/2;
	y0 := o.y + (480 - bh)/2;
	img.draw(Rect((x0-2, y0-2), (x0+bw+2, y0+bh+2)), ink[BLACK], nil, Point(0, 0));
	img.draw(Rect((x0, y0), (x0+bw, y0+bh)), ink[WHITE], nil, Point(0, 0));
	return Point(x0, y0);
}

# the original's startup PopUpOk instructions
drawinstr(img: ref Image, o: Point)
{
	if(font == nil)
		return;
	lines := array[] of {
		"Build a bridge to hold-up the",
		"red masses. Test your design",
		"by pressing run/stop.",
		"",
		"The lowest cost bridge that",
		"stays standing wins.",
		"",
		"For a variation, try without",
		"using the center base point.",
		"",
		"Use",
		"        'm'ass",
		"        'c'oncrete",
		"        's'teel",
		"        'w'ire",
		"",
		"to sel materials.",
		"",
		"            Ok(ESC)"
	};
	bw := 30*8 + 16;
	bh := len lines * 8 + 16;
	p := popupbox(img, o, bw, bh);
	for(i := 0; i < len lines; i++){
		col := BLACK;
		if(i == len lines - 1)
			col = GREEN;
		img.text(Point(p.x+8, p.y+8+i*8), ink[col], Point(0, 0), font, lines[i]);
		# the material letters are $$GREEN$$ in the original
		if(len lines[i] > 10 && lines[i][8] == '\'')
			img.text(Point(p.x+8+8*8, p.y+8+i*8), ink[GREEN], Point(0, 0),
				font, lines[i][8:11]);
	}
}

drawsave(img: ref Image, o: Point)
{
	if(font == nil)
		return;
	bw := 44*8 + 16;
	bh := 5*8 + 16;
	p := popupbox(img, o, bw, bh);
	img.text(Point(p.x+8, p.y+8), ink[BLACK], Point(0, 0), font,
		"SaveAs (in " + spandir() + "):");
	img.text(Point(p.x+8, p.y+8+2*8), ink[BLUE], Point(0, 0), font, savename + "_");
	img.text(Point(p.x+8, p.y+8+4*8), ink[GREEN], Point(0, 0), font,
		"Enter=save  ESC=cancel");
}

drawopen(img: ref Image, o: Point)
{
	if(font == nil)
		return;
	nl := len openents;
	if(nl == 0)
		nl = 1;
	bw := 44*8 + 16;
	bh := (nl+4)*8 + 16;
	p := popupbox(img, o, bw, bh);
	img.text(Point(p.x+8, p.y+8), ink[BLACK], Point(0, 0), font,
		"Open (from " + spandir() + "):");
	if(len openents == 0)
		img.text(Point(p.x+8, p.y+8+2*8), ink[DKGRAY], Point(0, 0), font,
			"(no saved games)");
	for(i := 0; i < len openents; i++){
		col := BLACK;
		if(i == opensel){
			img.draw(Rect((p.x+4, p.y+8+(2+i)*8), (p.x+bw-4, p.y+8+(3+i)*8)),
				ink[LTGRAY], nil, Point(0, 0));
			col = BLUE;
		}
		img.text(Point(p.x+8, p.y+8+(2+i)*8), ink[col], Point(0, 0), font, openents[i]);
	}
	img.text(Point(p.x+8, p.y+8+(2+nl+1)*8), ink[GREEN], Point(0, 0), font,
		"Enter/click=open  j/k=move  ESC=cancel");
}

# ---------- song ----------

# SongTask, by Terry A. Davis: tempo 3.636 notes/sec, stacatto_factor 0.902.
# tone->play has a fixed tempo, so the score is played by hand here with
# snd/stop at the original's rate.
songloop()
{
	parts := array[] of {
		"5q.EeDqED4G5DhE",
		"5q.EeDqED4G5DhE",
		"5q.FeEFEqF4G5EhF",
		"5q.FeEFEqF4G5EhF"
	};
	while(!song_stop)
		for(i := 0; i < len parts && !song_stop; i++)
			playscore(parts[i]);
}

QUARTER_MS: con 275;	# music.tempo is quarter-notes/sec: 1000/3.636
STACATTO: con 902;	# music.stacatto_factor 0.902, per 1000

# Note lengths follow Adam/ASnd.HC MusicSetNoteLen: w=4 h=2 q=1 e=.5 s=.25
# quarters, 't' = 2/3 of the current length (triplet), '.' = 1.5x; the length
# persists until changed.  Pitch follows Note2Ona + Ona2Freq, where
# note_map[A..G]={0,2,3,5,7,8,10}, ona=(octave+1)*12+note for note<3 else
# octave*12+note, and freq=440*2^((ona-60)/12) ("Ona=60 is 440.0Hz").  Since
# TempleOS octaves break at C exactly as scientific pitch does, that chain is
# identical to the MIDI form used below: A in octave 4 is ona 60 = 440Hz =
# MIDI 69, and E in octave 5 is ona 67 = 659.26Hz, both ways.
playscore(score: string)
{
	octave := 4;
	dur := QUARTER_MS;
	i := 0;
	n := len score;
	while(i < n && !song_stop){
		c := score[i++];
		case c {
		'0' to '9' =>
			octave = c - '0';
		'w' =>
			dur = 4*QUARTER_MS;
		'h' =>
			dur = 2*QUARTER_MS;
		'q' =>
			dur = QUARTER_MS;
		'e' =>
			dur = QUARTER_MS/2;
		's' =>
			dur = QUARTER_MS/4;
		't' =>
			dur = 2*dur/3;
		'.' =>
			dur = dur * 3 / 2;
		'R' or 'r' =>
			sys->sleep(dur);
		'A' to 'G' =>
			semi := 0;
			case c {
			'C' => semi = 0;
			'D' => semi = 2;
			'E' => semi = 4;
			'F' => semi = 5;
			'G' => semi = 7;
			'A' => semi = 9;
			'B' => semi = 11;
			}
			if(i < n){
				if(score[i] == '#'){
					semi++;
					i++;
				}else if(score[i] == 'b'){
					semi--;
					i++;
				}
			}
			f := 440.0 * math->pow(2.0, real((octave+1)*12 + semi - 69) / 12.0);
			on := dur * STACATTO / 1000;
			tone->snd(int f);
			sys->sleep(on);
			tone->stop();
			if(dur > on)
				sys->sleep(dur - on);
		}
	}
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
