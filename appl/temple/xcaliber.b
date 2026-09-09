implement Xcaliber;

# TempleOS Apps/X-Caliber (X-Caliber.HC + XCCtrls.HC) — soft-body space combat.
#
# Ships are breakable mass-spring trusses integrated by ode(2):
# human = 5 masses / 7 springs with differential wing engines, ST_ENEMY1 =
# 3-mass triangle, ST_ENEMY2 = 5-mass ship with purple pods.  Every spring
# has a strength; springs whose |force| exceeds it snap (SSF_INACTIVE), so
# ships take progressive damage.  Weapons ladder by level: 1 gun, 3 guns,
# 5 guns, then the laser.  Antimatter-ball shots with player-tunable radius
# and fuse burst into splats that home on ships and heat them; two guided
# wing missiles with cone lock; solar storms with ion showers (face away
# from the sun); spacewalk wing repair; XCCtrls control panel with mouse
# sliders and the laser temperature bar; best score persisted.
#
# Timing: the original ran game logic per winmgr Refresh (~30fps) with a
# continuous adaptive ODE (tolerance 1e-9).  Here: 16ms ticks, physics each
# tick (RK4 substeps, h=0.004 for the k=10000/m=0.1 wing springs), game
# logic every other tick (~31Hz) so the original's per-frame constants
# (temperatures, laser heat, flare probability) keep their real-time rates.
# The original's derivative adds ACCELERATIONS; ode(2) accumulates forces,
# so every custom term is multiplied by the mass it acts on.  Fixed-step
# stand-ins for the adaptive integrator: wall penetration capped at 4px and
# contact acceleration at 1e5 before the accel_limit clip.
#
# The laser is two separate things and they do not agree.  What it damages
# is chosen geometrically, in the derivative, by taking the nearest mass
# whose perpendicular offset from the beam is inside its own radius:
#
#	if (Abs(D3Dot(&p1,&p2))<tmpm->radius && D3Dot(&p1,&p)<0.0)
#
# but what is *drawn* is a pixel walk.  Line() is given &LaserPlot as its
# plot callback,
#
#	c=GrPeek(dc,x,y);
#	if (c!=BLACK && c!=WHITE) return FALSE; else { GrPlot(dc,x,y); return TRUE; }
#
# and returning FALSE ends the line, so the beam stops at the first pixel
# already occupied by anything that is not the background or white text.
# A shot in flight, an explosion ring, a missile marker or an enemy's
# drawn body all stop it, and none of them is a mass, so the beam
# regularly ends short of what it is actually burning.  Both are here:
# the geometric test picks the target, and the drawn beam is walked
# against the frame, which is why the frame is composed offscreen.
# GAP: Noise()/Sweep() are approximated with stepped tones (one voice).
# GAP: no pull-down menu tree; keys are on the man page.  One-time popups
#      are drawn in-window, not as system popups.
# GAP: shift/ctrl cursor chords work only if the platform delivers shifter
#      keydowns; plain-key equivalents are provided (see man page).

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;

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

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;

include "tone.m";
	tone: Tone;

include "scorestore.m";
	scorestore: Scorestore;

include "rand.m";
	rand: Rand;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Xcaliber: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# TempleOS 16-color palette (index = TempleOS color)
BLACK, BLUE, GREEN, CYAN, RED, PURPLE, BROWN, LTGRAY,
DKGRAY, LTBLUE, LTGREEN, LTCYAN, LTRED, LTPURPLE, YELLOW, WHITE: con iota;

# mass types (Mass.userdata)
MT_HUMAN_SHIP, MT_ENEMY_SHIP, MT_SOLAR_FLARE, MT_ION,
MT_ANTIMATTER_BALL, MT_ANTIMATTER_SPLAT, MT_MISSILE: con iota;

ST_HUMAN1, ST_ENEMY1, ST_ENEMY2: con iota;

SPIN_GAIN:	con 0.25;
THRUST_MAX:	con 200.0;
ANTISPIN_MAX:	con 25.0;
SPACEWALK_TIME:	con 7.5;
MISSILE_LEN:	con 5;
STARS_NUM:	con 100;

LASER_TEMP_MAX:		con 30.0;
LASER_THRESHOLD_TEMP:	con 10.0;
MASS_TEMP_MAX:		con 5.0;

# XCCtrls control panel
PSPACING:	con 33;
PRANGE:		con 30;
PBORDER:	con 2;
PBTTN:		con 12;

FONTW:	con 8;
FONTH:	con 8;

# extra Mass.flags bit (ode(2) only tests MSF_INACTIVE|MSF_FIXED)
MYF_NO_OVERLAP:	con 4;

# sprite bin numbers
SPRTHRUSTER, SPRGUNREADY, SPRGUNBUSY, SPRWALK,
SPRSIDE, SPRLASER, SPRMISSILE, SPRLAUNCHED: con 1+iota;

# game states
SPOPUP, SLEVEL, SPLAY, SGAMEOVER: con iota;

# one-time popup flag bits (persisted)
XMSGF_ANTISPIN:		con 1;
XMSGF_SOLAR_STORM:	con 2;

Ship: adt {
	stype:		int;
	nm, ns:		int;
	p:		array of ref Mass;
	s:		array of ref Spring;	# strength in .num, color in .userdata
	temp:		array of real;
	fire_rate:	real;
	reload_timeout:	real;
	spacewalk_timeout: real;
	die_time, die_timeout: real;
	spacewalk_side:	int;
	laser_temperature: real;
	missiles:	array of ref Missile;
	lasering, exploding, laser_overheat: int;
	dead:		int;
};

Missile: adt {
	owner:		cyclic ref Ship;
	target:		cyclic ref Ship;
	front, back:	ref Mass;
	s:		array of ref Spring;
	tons:		real;
	fuse_time, die_timeout: real;
	active, launched, exploding: int;
	label:		string;
};

Shot: adt {
	m:		ref Mass;
	radius:		real;
	fuse_time:	real;
	splats:		int;
};

Part: adt {
	x, y, vx, vy:	real;
	ptype:		int;
	die_timeout:	real;
};

win: ref Window;
display: ref Display;
sim: ref ODE;
pal: array of ref Image;
tfont: ref Font;
sprites: array of ref Image;
smasks: array of ref Image;

ships: list of ref Ship;
human: ref Ship;
shots: list of ref Shot;
parts: list of ref Part;

stars_x := array[STARS_NUM] of int;
stars_y := array[STARS_NUM] of int;

level, score, remaining: int;
best_score := 0;
msg_flags := 0;
game_over := 0;
state := SLEVEL;
popupq: list of string;

human_t_left := 0.0;
human_t_right := 0.0;
human_antispin := 0.0;

# XCCtrls panel state
cp_shot_radius := 0;
cp_fuse_time := 0;
cp_spacewalk := 0;

t_solar_storm := 0.0;
alarm := 0;

tS := 0.0;			# game seconds (frozen while paused)
tickn := 0;
kleft, kright, kup, kdown, kfire: int;
shiftheld, ctrlheld: int;
btnwas := 0;

have_tone := 0;
noise_until := 0.0;
curdrone := 0;
sweepgen := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	i: int;
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	ode = load Ode Ode->PATH;
	tone = load Tone Tone->PATH;
	# The device provider, for sprite2d: it sends the rotation or the
	# scale to the GPU as a textured quad instead of resampling it in
	# interpreted Limbo, and falls back to the same C resampler in
	# devdraw.c when the destination is not one the GPU can draw into.
	# 220x220 at 30 degrees measured 2725us a sprite through the Limbo
	# path and 65us through this one, end to end.  It degrades on its
	# own when there is no device, so the second load is only for the
	# .dis file being absent.
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	scorestore = load Scorestore Scorestore->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	if(ode == nil){
		sys->fprint(sys->fildes(2), "xcaliber: no ode\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	ode->init();
	if(draw3d != nil)
		draw3d->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(scorestore != nil){
		best_score = scorestore->loadint("xcaliber.best", 0);
		msg_flags = scorestore->loadint("xcaliber.msgflags", 0);
	}
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS X-Caliber", Wmclient->Appl);
	display = win.display;
	cols := grpal->values();
	pal = array[16] of ref Image;
	for(i = 0; i < 16; i++)
		pal[i] = display.color(cols[i]);
	tfont = Font.open(display, "/fonts/lucida/unicode.8.font");
	sprites = array[9] of ref Image;
	smasks = array[9] of ref Image;
	for(i = 1; i <= 8; i++){
		sprites[i] = display.open(sys->sprint("/icons/temple/xcaliber_%d.bit", i));
		smasks[i] = display.open(sys->sprint("/icons/temple/xcaliber_%d.mask", i));
	}

	newgame();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		pointer(p);
	k := <-win.ctxt.kbd =>
		keydown(k);
	<-ticks =>
		tickn++;
		if(state == SPLAY || state == SGAMEOVER){
			tS += 0.016;
			stepphysics();
			if(tickn % 2 == 0)
				logic();
		}
		drone();
		drawit();
	}
}

quit()
{
	if(scorestore != nil){
		scorestore->saveint("xcaliber.best", best_score);
		scorestore->saveint("xcaliber.msgflags", msg_flags);
	}
	if(have_tone)
		tone->stop();
	exit;
}

# ---------------------------------------------------------------- input

keydown(k: int)
{
	if(k == 16r1b || k == 'q' || k == 'Q'){
		quit();
		return;
	}
	case k {
	Keyboard->LShift or Keyboard->RShift =>
		shiftheld = 1;
		return;
	Keyboard->LCtrl or Keyboard->RCtrl =>
		ctrlheld = 1;
		return;
	Keyboard->Keyup | (Keyboard->LShift & 16r7ff) or
	Keyboard->Keyup | (Keyboard->RShift & 16r7ff) =>
		shiftheld = 0;
		return;
	Keyboard->Keyup | (Keyboard->LCtrl & 16r7ff) or
	Keyboard->Keyup | (Keyboard->RCtrl & 16r7ff) =>
		ctrlheld = 0;
		return;
	}
	# releases are honored in every state so held keys can't stick
	# across a wave/game-over transition
	if(iskeyup(k)){
		case k {
		Keyboard->Keyup | ' ' =>
			kfire = 0;
			humanlaserend();
		Keyboard->Keyup | (Keyboard->Right & 16r7ff) =>
			kright = 0;
		Keyboard->Keyup | (Keyboard->Left & 16r7ff) =>
			kleft = 0;
		Keyboard->Keyup | (Keyboard->Up & 16r7ff) =>
			kup = 0;
		Keyboard->Keyup | (Keyboard->Down & 16r7ff) =>
			kdown = 0;
		}
		return;
	}
	case state {
	SPOPUP =>
		popupq = tl popupq;
		if(popupq == nil)
			state = SLEVEL;
		return;
	SLEVEL =>
		# any key resumes; Enter is consumed harmlessly (original GetKey)
		state = SPLAY;
		return;
	SGAMEOVER =>
		if(k == '\n')
			newgame();
		return;
	}

	# SPLAY
	case k {
	'\n' =>
		newgame();		# Enter during play restarts (original loop exit)
	' ' =>
		kfire = 1;
		firepress();
	Keyboard->Right =>
		if(ctrlheld)
			humanfiremissile(0);
		else if(shiftheld)
			cp_fuse_time = clampi(cp_fuse_time+2, 0, PRANGE-1);
		else
			kright = 1;
	Keyboard->Left =>
		if(ctrlheld)
			humanfiremissile(1);
		else if(shiftheld)
			cp_fuse_time = clampi(cp_fuse_time-2, 0, PRANGE-1);
		else
			kleft = 1;
	Keyboard->Up =>
		if(shiftheld)
			cp_shot_radius = clampi(cp_shot_radius+2, 0, PRANGE-1);
		else
			kup = 1;
	Keyboard->Down =>
		if(shiftheld)
			cp_shot_radius = clampi(cp_shot_radius-2, 0, PRANGE-1);
		else
			kdown = 1;
	'w' or 'W' =>
		cp_spacewalk = 1;
	'+' =>
		level++;
	'-' =>
		level--;
	'z' or 'Z' =>
		humanfiremissile(1);	# left missile (= ctrl-left)
	'x' or 'X' =>
		humanfiremissile(0);	# right missile (= ctrl-right)
	'[' =>
		cp_fuse_time = clampi(cp_fuse_time-2, 0, PRANGE-1);
	']' =>
		cp_fuse_time = clampi(cp_fuse_time+2, 0, PRANGE-1);
	'o' or 'O' =>
		cp_shot_radius = clampi(cp_shot_radius-2, 0, PRANGE-1);
	'p' or 'P' =>
		cp_shot_radius = clampi(cp_shot_radius+2, 0, PRANGE-1);
	}
}

iskeyup(k: int): int
{
	return (k & Keyboard->Keyup) == Keyboard->Keyup;
}

pointer(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	click := (p.buttons & 1) && !btnwas;
	btnwas = p.buttons & 1;
	if(!click)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	w := img.r.dx();
	h := img.r.dy();
	# XCCtrls LeftClickCtrlPanel
	pl := w - (PSPACING*3+2);
	pt := h - (PSPACING*2 + PRANGE + PBTTN);
	pr := pl + PSPACING*3+2;
	pb := pt + PSPACING*2 + PRANGE + PBTTN;
	if(x < pl || x >= pr || y < pt || y >= pb)
		return;
	if(y < pt + PBORDER + (PSPACING-FONTH)/2 + FONTH + 6)
		cp_spacewalk = 1;
	else if(x < (pr+pl)/2)
		cp_shot_radius = clampi(PRANGE-1 - (y - (pt + PSPACING + PBTTN)), 0, PRANGE-1);
	else
		cp_fuse_time = clampi(PRANGE-1 - (y - (pt + PSPACING + PBTTN)), 0, PRANGE-1);
}

clampi(v, lo, hi: int): int
{
	if(v < lo) return lo;
	if(v > hi) return hi;
	return v;
}

clampr(v, lo, hi: real): real
{
	if(v < lo) return lo;
	if(v > hi) return hi;
	return v;
}

# ---------------------------------------------------------------- ships

checkoverlap(): int
{
	for(l1 := sim.masses; l1 != nil; l1 = tl l1){
		m1 := hd l1;
		if(m1.flags & MYF_NO_OVERLAP)
			continue;
		for(l2 := tl l1; l2 != nil; l2 = tl l2){
			m2 := hd l2;
			if(m2.flags & MYF_NO_OVERLAP)
				continue;
			dx := m1.x - m2.x;
			dy := m1.y - m2.y;
			rr := m1.radius + m2.radius;
			if(dx*dx + dy*dy <= rr*rr)
				return 1;
		}
	}
	return 0;
}

newmass(x, y, mass, radius: real, drag: real, mtype: int): ref Mass
{
	m := ref Mass(x, y, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
		mass, drag, 0, 0, radius, mtype);
	ode->addmass(sim, m);
	return m;
}

newspring(m1, m2: ref Mass, konst, strength: real, color: int): ref Spring
{
	dx := m2.x - m1.x;
	dy := m2.y - m1.y;
	s := ref Spring(m1, m2, konst, math->sqrt(dx*dx + dy*dy), 0.0, 0.0,
		0, int strength, color);
	ode->addspring(sim, s);
	return s;
}

missilenew(sp: ref Ship, n: int)
{
	mi := ref Missile(sp, nil, nil, nil, array[5] of ref Spring,
		0.5, 0.0, 0.0, 0, 0, 0, "R");
	if(n & 1)
		mi.label = "L";
	# mount midpoint between p[n+1] and p[n+3], nose axis forward
	mx := (sp.p[n+1].x + sp.p[n+3].x) / 2.0;
	my := (sp.p[n+1].y + sp.p[n+3].y) / 2.0;
	(fx, fy) := fwdaxis(sp);
	fl := real (MISSILE_LEN/2 + 1);	# 3
	bl := real (MISSILE_LEN/2 - 1);	# 1
	mi.front = newmass(mx + fl*fx, my + fl*fy, 0.1, 2.0, 0.0, MT_MISSILE);
	mi.back = newmass(mx - bl*fx, my - bl*fy, 0.1, 2.0, 0.0, MT_MISSILE);
	mi.front.flags |= MYF_NO_OVERLAP;
	mi.back.flags |= MYF_NO_OVERLAP;
	mi.front.vx = sp.p[n].vx; mi.front.vy = sp.p[n].vy;
	mi.back.vx = sp.p[n].vx; mi.back.vy = sp.p[n].vy;
	mi.s[0] = newspring(mi.front, mi.back, 10000.0, 20000.0, BLACK);
	mi.s[1] = newspring(mi.front, sp.p[n+1], 10000.0, 20000.0, BLACK);
	mi.s[2] = newspring(mi.back, sp.p[n+1], 10000.0, 20000.0, BLACK);
	mi.s[3] = newspring(mi.front, sp.p[n+3], 10000.0, 20000.0, BLACK);
	mi.s[4] = newspring(mi.back, sp.p[n+3], 10000.0, 20000.0, BLACK);
	mi.active = 1;
	sp.missiles[n] = mi;
}

shipnew(x, y: real, stype: int): ref Ship
{
	sp := ref Ship(stype, 0, 0, nil, nil, nil, 0.0, 0.0, 0.0, 0.0, 0.0,
		0, 0.0, array[2] of ref Missile, 0, 0, 0, 0);
	case stype {
	ST_HUMAN1 =>
		sp.fire_rate = 25.0;
		sp.nm = 5;
		sp.p = array[5] of ref Mass;
		sp.p[0] = newmass(x, y, 1.0, 2.5, 3.0, MT_HUMAN_SHIP);
		sp.p[1] = newmass(x+3.0, y+10.0, 1.0, 2.5, 3.0, MT_HUMAN_SHIP);
		sp.p[2] = newmass(x-3.0, y+10.0, 1.0, 2.5, 3.0, MT_HUMAN_SHIP);
		sp.p[3] = newmass(x+20.0, y+20.0, 0.1, 4.0, 3.0, MT_HUMAN_SHIP);
		sp.p[4] = newmass(x-20.0, y+20.0, 0.1, 4.0, 3.0, MT_HUMAN_SHIP);
		sp.ns = 7;
		sp.s = array[7] of ref Spring;
		sp.s[0] = newspring(sp.p[0], sp.p[1], 10000.0, 30000.0, LTCYAN);
		sp.s[1] = newspring(sp.p[2], sp.p[0], 10000.0, 30000.0, LTCYAN);
		sp.s[2] = newspring(sp.p[1], sp.p[2], 10000.0, 30000.0, LTCYAN);
		sp.s[3] = newspring(sp.p[1], sp.p[3], 10000.0, 30000.0, LTGRAY);
		sp.s[4] = newspring(sp.p[0], sp.p[3], 10000.0, 30000.0, LTGRAY);
		sp.s[5] = newspring(sp.p[2], sp.p[4], 10000.0, 30000.0, LTGRAY);
		sp.s[6] = newspring(sp.p[0], sp.p[4], 10000.0, 30000.0, LTGRAY);
		missilenew(sp, 0);
		missilenew(sp, 1);
	ST_ENEMY1 =>
		sp.fire_rate = 2.5;
		sp.nm = 3;
		sp.p = array[3] of ref Mass;
		sp.p[0] = newmass(x, y, 1.0, 7.0, 3.0, MT_ENEMY_SHIP);
		sp.p[1] = newmass(x+15.0, y, 1.0, 7.0, 3.0, MT_ENEMY_SHIP);
		sp.p[2] = newmass(x, y+15.0, 1.0, 7.0, 3.0, MT_ENEMY_SHIP);
		sp.ns = 3;
		sp.s = array[3] of ref Spring;
		sp.s[0] = newspring(sp.p[0], sp.p[1], 10000.0, 20000.0, BLACK);
		sp.s[1] = newspring(sp.p[1], sp.p[2], 10000.0, 20000.0, BLACK);
		sp.s[2] = newspring(sp.p[2], sp.p[0], 10000.0, 20000.0, BLACK);
		remaining++;
	ST_ENEMY2 =>
		sp.fire_rate = 5.0;
		sp.nm = 5;
		sp.p = array[5] of ref Mass;
		sp.p[0] = newmass(x, y, 1.0, 6.0, 5.0, MT_ENEMY_SHIP);
		sp.p[1] = newmass(x-7.0, y+10.0, 1.0, 6.0, 5.0, MT_ENEMY_SHIP);
		sp.p[2] = newmass(x+7.0, y+10.0, 1.0, 6.0, 5.0, MT_ENEMY_SHIP);
		sp.p[3] = newmass(x-14.0, y+20.0, 1.0, 6.0, 5.0, MT_ENEMY_SHIP);
		sp.p[4] = newmass(x+14.0, y+20.0, 1.0, 6.0, 5.0, MT_ENEMY_SHIP);
		sp.ns = 7;
		sp.s = array[7] of ref Spring;
		sp.s[0] = newspring(sp.p[0], sp.p[1], 40000.0, 75000.0, BLACK);
		sp.s[1] = newspring(sp.p[0], sp.p[2], 40000.0, 75000.0, BLACK);
		sp.s[2] = newspring(sp.p[1], sp.p[2], 40000.0, 75000.0, BLACK);
		sp.s[3] = newspring(sp.p[1], sp.p[3], 40000.0, 75000.0, LTPURPLE);
		sp.s[4] = newspring(sp.p[2], sp.p[4], 40000.0, 75000.0, LTPURPLE);
		sp.s[5] = newspring(sp.p[2], sp.p[3], 40000.0, 75000.0, LTPURPLE);
		sp.s[6] = newspring(sp.p[1], sp.p[4], 40000.0, 75000.0, LTPURPLE);
		remaining++;
	}
	sp.temp = array[sp.nm] of { * => 0.0 };
	ships = sp :: ships;
	return sp;
}

missiledel(mi: ref Missile)
{
	if(mi == nil || !mi.active)
		return;
	for(i := 0; i < 5; i++)
		ode->remspring(sim, mi.s[i]);
	ode->remmass(sim, mi.front);
	ode->remmass(sim, mi.back);
	mi.active = 0;
	mi.target = nil;
}

shipdel(sp: ref Ship)
{
	i: int;
	if(sp == nil)
		return;
	for(i = 0; i < sp.nm; i++)
		ode->remmass(sim, sp.p[i]);
	for(i = 0; i < sp.ns; i++)
		ode->remspring(sim, sp.s[i]);
	missiledel(sp.missiles[0]);
	missiledel(sp.missiles[1]);
	sp.dead = 1;
	nl: list of ref Ship;
	for(l := ships; l != nil; l = tl l)
		if(hd l != sp)
			nl = hd l :: nl;
	ships = nl;
	if(sp.stype != ST_HUMAN1)
		remaining--;
	# original left dangling target pointers; clear them
	if(human != nil && human != sp)
		for(i = 0; i < 2; i++){
			mi := human.missiles[i];
			if(mi != nil && mi.target == sp)
				mi.target = nil;
		}
	if(sp == human)
		human = nil;
}

placeship(stype: int)
{
	(w, h) := dims();
	if(checkoverlap())
		return;
	for(try := 0; try < 200; try++){
		sp := shipnew(real(rn(w-20)+10), real(rn(h-20)+10), stype);
		if(!checkoverlap())
			return;
		shipdel(sp);
	}
	shipnew(real(rn(w-20)+10), real(rn(h-20)+10), stype);
}

# unit vector from mid masses toward the nose (original (p0-p1)+(p0-p2))
fwdaxis(sp: ref Ship): (real, real)
{
	x := (sp.p[0].x - sp.p[1].x) + (sp.p[0].x - sp.p[2].x);
	y := (sp.p[0].y - sp.p[1].y) + (sp.p[0].y - sp.p[2].y);
	d := math->sqrt(x*x + y*y);
	if(d == 0.0)
		return (0.0, -1.0);
	return (x/d, y/d);
}

# original Tweaked(): which wing (3 or 4) is folded within 20 deg of the axis
tweaked(): int
{
	if(human == nil)
		return 0;
	(px, py) := fwdaxis(human);
	c20 := math->cos(20.0 * Math->Pi / 180.0);
	x := human.p[0].x - human.p[3].x;
	y := human.p[0].y - human.p[3].y;
	d := math->sqrt(x*x + y*y);
	if(d > 0.0 && !(human.s[3].flags & Ode->SSF_INACTIVE) &&
			(px*x + py*y)/d > c20)
		return 3;
	x = human.p[0].x - human.p[4].x;
	y = human.p[0].y - human.p[4].y;
	d = math->sqrt(x*x + y*y);
	if(d > 0.0 && !(human.s[5].flags & Ode->SSF_INACTIVE) &&
			(px*x + py*y)/d > c20)
		return 4;
	return 0;
}

alldel()
{
	while(ships != nil)
		shipdel(hd ships);
	human = nil;
	for(l := shots; l != nil; l = tl l)
		ode->remmass(sim, (hd l).m);
	shots = nil;
	parts = nil;
}

# ---------------------------------------------------------------- shots

shotnew(mtype: int, px, py, vx, vy, r, fuse: real, offx, offy: real): ref Shot
{
	m := newmass(px + offx, py + offy, 0.3*r*r*r, r, 0.0, mtype);
	m.vx = vx;
	m.vy = vy;
	sh := ref Shot(m, r, tS + fuse, int (20.0*r));
	shots = sh :: shots;
	return sh;
}

fireonegun(sp: ref Ship, n: int, r, fuse: real)
{
	(px, py) := fwdaxis(sp);
	off := r + sp.p[0].radius + 5.0;
	spd := 1000.0 / (r + 1.0);
	sh := shotnew(MT_ANTIMATTER_BALL, sp.p[n].x, sp.p[n].y,
		px*spd + sp.p[n].vx, py*spd + sp.p[n].vy, r, fuse, px*off, py*off);
	rec := sh.m.mass / sp.p[n].mass / 100.0;
	sp.p[n].vx -= px * rec;
	sp.p[n].vy -= py * rec;
	sp.reload_timeout = tS + r/sp.fire_rate;
	ona := freq2ona(500.0/r);
	noise(100, ona, ona+12.0);
}

humanfiregun()
{
	r := 3.0 * real cp_shot_radius / real PRANGE + 0.5;
	fuse := real (cp_fuse_time + 1) / real PRANGE;
	if(human == nil || human.exploding || human.spacewalk_side ||
			tS <= human.reload_timeout)
		return;
	# weapons ladder (original fallthrough switch)
	if(level == 3){
		if(!(human.s[3].flags & Ode->SSF_INACTIVE))
			fireonegun(human, 3, r, fuse);
		if(!(human.s[5].flags & Ode->SSF_INACTIVE))
			fireonegun(human, 4, r, fuse);
	}
	if(level == 3 || level == 2){
		if(!(human.s[1].flags & Ode->SSF_INACTIVE))
			fireonegun(human, 1, r, fuse);
		if(!(human.s[2].flags & Ode->SSF_INACTIVE))
			fireonegun(human, 2, r, fuse);
	}
	if(level >= 1 && level <= 3)
		fireonegun(human, 0, r, fuse);
}

humanfiremissile(n: int)
{
	if(human == nil || human.exploding || human.spacewalk_side ||
			tS <= human.reload_timeout)
		return;
	mi := human.missiles[n];
	if(mi == nil || !mi.active || mi.launched || mi.target == nil)
		return;
	mi.fuse_time = tS + 1.0;
	mi.die_timeout = mi.fuse_time + 0.125;
	for(i := 1; i < 5; i++)
		mi.s[i].flags |= Ode->SSF_INACTIVE;
	mi.launched = 1;
	sweep(250, 53.0, 56.0);
}

firepress()
{
	if(level >= 4 || level <= 0){
		if(human != nil && !human.exploding && !human.spacewalk_side &&
				tS > human.reload_timeout)
			human.lasering = 1;
	}else
		humanfiregun();
}

humanlaserend()
{
	if(human != nil && !human.exploding)
		human.lasering = 0;
}

splatnew(sh: ref Shot, die_time, start, end: real)
{
	heading := math->atan2(sh.m.vy, sh.m.vx);
	n := sh.splats;
	for(i := 0; i < n; i++){
		th := heading + start + (end-start) * real i / real n;
		a := 50.0 * sh.radius * sh.radius;
		pt := ref Part(sh.m.x, sh.m.y,
			sh.m.vx + a*frand()*math->sin(th),
			sh.m.vy + a*frand()*math->cos(th),
			MT_ANTIMATTER_SPLAT, tS + die_time);
		if(sh.m.userdata == MT_SOLAR_FLARE)
			pt.ptype = MT_ION;
		parts = pt :: parts;
	}
}

expireshots()
{
	nl: list of ref Shot;
	for(l := shots; l != nil; l = tl l){
		sh := hd l;
		if(tS > sh.fuse_time){
			if(sh.m.userdata == MT_SOLAR_FLARE)
				splatnew(sh, 1.0, 3.0*Math->Pi/8.0, 5.0*Math->Pi/8.0);
			else
				splatnew(sh, 0.2, 0.0, 2.0*Math->Pi);
			ode->remmass(sim, sh.m);
		}else
			nl = sh :: nl;
	}
	shots = nl;
}

expiresplats()
{
	nl: list of ref Part;
	for(l := parts; l != nil; l = tl l){
		pt := hd l;
		if(tS <= pt.die_timeout)
			nl = pt :: nl;
	}
	parts = nl;
}

expiremissiles()
{
	if(human == nil)
		return;
	for(n := 0; n < 2; n++){
		mi := human.missiles[n];
		if(mi == nil || !mi.active || !mi.launched)
			continue;
		best := 1.0e30;
		if(mi.target != nil && !mi.target.dead)
			for(i := 0; i < mi.target.nm; i++){
				dx := mi.front.x - mi.target.p[i].x;
				dy := mi.front.y - mi.target.p[i].y;
				dd := dx*dx + dy*dy;
				if(dd < best)
					best = dd;
			}
		if(!mi.exploding && (best < 30.0*30.0 || tS > mi.fuse_time)){
			mi.front.mass = 10.0;	# they go flying, if too light
			mi.back.mass = 10.0;
			mi.exploding = 1;
			noise(50, 93.0, 105.0);
		}else if(mi.exploding && tS > mi.die_timeout)
			missiledel(mi);
	}
}

# cone lock: nearest ship mass within ~asin(pi/16) of the missile axis
targetget(mi: ref Missile): ref Ship
{
	res: ref Ship;
	best := 1.0e30;
	ax := mi.front.x - mi.back.x;
	ay := mi.front.y - mi.back.y;
	d := math->sqrt(ax*ax + ay*ay);
	if(d == 0.0)
		return nil;
	ax /= d; ay /= d;
	for(l := ships; l != nil; l = tl l){
		sp := hd l;
		if(sp.exploding || sp == mi.owner)
			continue;
		for(i := 0; i < sp.nm; i++){
			px := sp.p[i].x - mi.front.x;
			py := sp.p[i].y - mi.front.y;
			pd := math->sqrt(px*px + py*py);
			if(pd == 0.0)
				continue;
			px /= pd; py /= pd;
			cr := ax*py - ay*px;	# z of cross(axis, dir)
			if(ax*px + ay*py > 0.0 && cr < Math->Pi/16.0 &&
					-cr < Math->Pi/16.0){
				dd := cr*cr;
				if(dd < best){
					best = dd;
					res = sp;
				}
			}
		}
	}
	return res;
}

# ---------------------------------------------------------------- physics

dims(): (int, int)
{
	img := win.image;
	if(img == nil)
		return (640, 480);
	return (img.r.dx(), img.r.dy());
}

# original MyDerivative: every term below is an acceleration there,
# so it enters ode(2)'s force accumulator multiplied by the mass.
derivforces()
{
	i: int;
	(wi, hi) := dims();
	w := real wi;
	h := real hi;

	# wall softness: (penetration)^8, capped at 4px penetration
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		if(m.userdata == MT_SOLAR_FLARE)
			continue;
		m.fx += m.mass * (wallf(m.radius - m.x) - wallf((m.x + m.radius) - w));
		m.fy += m.mass * (wallf(m.radius - m.y) - wallf((m.y + m.radius) - h));
	}

	# pairwise soft contact (dd2-dd)^4; original visits each ordered
	# pair, applying the force twice — folded into the factor 2 here
	for(l1 := sim.masses; l1 != nil; l1 = tl l1){
		m1 := hd l1;
		for(l2 := tl l1; l2 != nil; l2 = tl l2){
			m2 := hd l2;
			dx := m1.x - m2.x;
			dy := m1.y - m2.y;
			dd := dx*dx + dy*dy;
			rr := m1.radius + m2.radius;
			dd2 := rr*rr;
			if(dd <= dd2){
				d := math->sqrt(dd) + 0.0001;
				g := dd2 - dd;
				a := g*g*g*g;
				if(a > 100000.0)
					a = 100000.0;
				# original scales the raw offset vector by a/d,
				# so |accel| = a (with |offset| = d)
				s := 2.0 * a / d;
				m1.fx += m1.mass * dx * s;
				m1.fy += m1.mass * dy * s;
				m2.fx -= m2.mass * dx * s;
				m2.fy -= m2.mass * dy * s;
			}
		}
	}

	# splats accelerate toward ship masses (antimatter homing)
	for(pl := parts; pl != nil; pl = tl pl){
		pt := hd pl;
		if(pt.ptype != MT_ANTIMATTER_SPLAT)
			continue;
		for(sl := ships; sl != nil; sl = tl sl){
			sp := hd sl;
			for(i = 0; i < sp.nm; i++){
				dx := sp.p[i].x - pt.x;
				dy := sp.p[i].y - pt.y;
				dd := dx*dx + dy*dy + 1.0;
				if(dd < 100000.0){
					pt.vx += dx * (100000.0/dd) * 0.016;
					pt.vy += dy * (100000.0/dd) * 0.016;
				}
			}
		}
	}

	for(sl := ships; sl != nil; sl = tl sl){
		sp := hd sl;
		if(sp.exploding && sp.die_time <= tS && tS <= sp.die_timeout)
			for(i = 0; i < sp.nm; i++)
				explosionat(sp.p[i].x, sp.p[i].y, sp.p[i], nil,
					sp.p[i].radius/250.0);
		if(sp.stype != ST_HUMAN1 || sp.exploding)
			continue;
		if(sp.spacewalk_side){
			# repair impulse at the midpoint of the walk
			d := 1.0 - (sp.spacewalk_timeout - tS)/SPACEWALK_TIME;
			if(d > 0.485 && d < 0.515){
				ux := sp.p[2].x - sp.p[1].x;
				uy := sp.p[2].y - sp.p[1].y;
				ud := math->sqrt(ux*ux + uy*uy);
				if(ud > 0.0){
					ux /= ud; uy /= ud;
					f := 10.0 * THRUST_MAX;
					if(sp.spacewalk_side == 3){
						sp.p[3].fx -= sp.p[3].mass * f * ux;
						sp.p[3].fy -= sp.p[3].mass * f * uy;
						sp.p[1].fx += sp.p[1].mass * f * ux;
						sp.p[1].fy += sp.p[1].mass * f * uy;
					}else{
						sp.p[4].fx += sp.p[4].mass * f * ux;
						sp.p[4].fy += sp.p[4].mass * f * uy;
						sp.p[2].fx -= sp.p[2].mass * f * ux;
						sp.p[2].fy -= sp.p[2].mass * f * uy;
					}
				}
			}
		}else{
			(tl_, tr_) := enginethrust(sp);
			(px, py) := fwdaxis(sp);
			if(!(sp.s[3].flags & Ode->SSF_INACTIVE)){
				sp.p[3].fx += sp.p[3].mass * tl_ * px;
				sp.p[3].fy += sp.p[3].mass * tl_ * py;
			}
			if(!(sp.s[5].flags & Ode->SSF_INACTIVE)){
				sp.p[4].fx += sp.p[4].mass * tr_ * px;
				sp.p[4].fy += sp.p[4].mass * tr_ * py;
			}
		}
	}

	# missile guidance / detonation
	if(human != nil)
		for(n := 0; n < 2; n++){
			mi := human.missiles[n];
			if(mi == nil || !mi.active || !mi.launched)
				continue;
			if(mi.exploding){
				explosionat(mi.front.x, mi.front.y, mi.front, mi.back, mi.tons);
				continue;
			}
			tgt := mi.target;
			if(tgt == nil || tgt.dead)
				continue;
			ax := mi.front.x - mi.back.x;
			ay := mi.front.y - mi.back.y;
			ad := math->sqrt(ax*ax + ay*ay);
			if(ad == 0.0)
				continue;
			ax /= ad; ay /= ad;
			px := tgt.p[0].x - mi.front.x;
			py := tgt.p[0].y - mi.front.y;
			d := math->sqrt(px*px + py*py);
			if(d == 0.0)
				continue;
			px /= d; py /= d;
			err := ax*px + ay*py;
			rvx := mi.front.vx - mi.back.vx;
			rvy := mi.front.vy - mi.back.vy;
			ddt := ax*rvy - ay*rvx;	# z of cross(axis, dv), signed
			th := clampr(200.0*(err + 2.0*ddt)/(d + 200.0),
				-Math->Pi/8.0, Math->Pi/8.0);
			cs := math->cos(th);
			sn := math->sin(th);
			dx := ax*cs - ay*sn;
			dy := ay*cs + ax*sn;
			mi.back.fx += mi.back.mass * THRUST_MAX * dx;
			mi.back.fy += mi.back.mass * THRUST_MAX * dy;
		}
}

wallf(pen: real): real
{
	if(pen <= 0.0)
		return 0.0;
	if(pen > 4.0)
		pen = 4.0;	# fixed-step guard (adaptive ODE in the original)
	p2 := pen*pen;
	p4 := p2*p2;
	return p4*p4;
}

# spin-damped engine thrusts (original recomputes this in DrawIt too)
enginethrust(sp: ref Ship): (real, real)
{
	if(sp.spacewalk_side)
		return (0.0, 0.0);
	spin := 0.0;
	dx := sp.p[0].x - sp.p[1].x;
	dy := sp.p[0].y - sp.p[1].y;
	d := math->sqrt(dx*dx + dy*dy);
	if(d > 0.0){
		vx := sp.p[0].vx - sp.p[1].vx;
		vy := sp.p[0].vy - sp.p[1].vy;
		spin = (dx*vy - dy*vx) / d;
	}
	tl_ := clampr(human_t_left + SPIN_GAIN*spin*human_antispin, 0.0, THRUST_MAX);
	spin = 0.0;
	dx = sp.p[0].x - sp.p[2].x;
	dy = sp.p[0].y - sp.p[2].y;
	d = math->sqrt(dx*dx + dy*dy);
	if(d > 0.0){
		vx := sp.p[0].vx - sp.p[2].vx;
		vy := sp.p[0].vy - sp.p[2].vy;
		spin = (dx*vy - dy*vx) / d;
	}
	tr_ := clampr(human_t_right - SPIN_GAIN*spin*human_antispin, 0.0, THRUST_MAX);
	return (tl_, tr_);
}

# original Explosion(): impulse blast on everything within 100px
explosionat(x, y: real, ex1, ex2: ref Mass, tons: real)
{
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		if(m == ex1 || m == ex2)
			continue;
		px := m.x - x;
		py := m.y - y;
		d := px*px + py*py - m.radius*m.radius;
		if(d < 100.0*100.0){
			if(d < 1.0)
				d = 1.0;
			a := 250000.0*tons/d;
			m.fx += m.mass * px * a;
			m.fy += m.mass * py * a;
		}
	}
	for(pl := parts; pl != nil; pl = tl pl){
		pt := hd pl;
		px := pt.x - x;
		py := pt.y - y;
		d := px*px + py*py - 1.0;
		if(d < 100.0*100.0){
			if(d < 1.0)
				d = 1.0;
			a := 250000.0*tons/d;
			pt.vx += px * a * 0.016;
			pt.vy += py * a * 0.016;
		}
	}
}

stepphysics()
{
	ode->clearforces(sim);
	# held keys drive the engines (original KEY_DOWN/KEY_UP messages)
	if(kup){
		human_t_left = THRUST_MAX;
		human_t_right = THRUST_MAX;
	}else{
		if(kleft)
			human_t_left = THRUST_MAX;
		else
			human_t_left = 0.0;
		if(kright)
			human_t_right = THRUST_MAX;
		else
			human_t_right = 0.0;
	}
	if(kdown)
		human_antispin = ANTISPIN_MAX;
	else
		human_antispin = 0.0;
	derivforces();
	ode->update(sim, 0.016);
	# ballistic particles (no drag in the original: profile factor 0)
	for(pl := parts; pl != nil; pl = tl pl){
		pt := hd pl;
		pt.x += pt.vx * 0.016;
		pt.y += pt.vy * 0.016;
	}
}

# ---------------------------------------------------------------- damage

checkdamage()
{
	i: int;
	facing_sun := 0;
	if(human != nil){
		# rearward axis x-component > 0 means the nose faces the sun (left)
		rx := (human.p[1].x - human.p[0].x) + (human.p[2].x - human.p[0].x);
		if(rx > 0.0)
			facing_sun = 1;
	}

	# cooling, then splat/ion heating (per ~30Hz frame in the original)
	for(sl := ships; sl != nil; sl = tl sl){
		sp := hd sl;
		for(i = 0; i < sp.nm; i++)
			sp.temp[i] *= 0.9;
	}
	for(pl := parts; pl != nil; pl = tl pl){
		pt := hd pl;
		for(sl = ships; sl != nil; sl = tl sl){
			sp := hd sl;
			if(pt.ptype == MT_ION && (sp.stype != ST_HUMAN1 || !facing_sun))
				continue;
			heat := 0.4;
			if(pt.ptype == MT_ION)
				heat = 3.0;
			for(i = 0; i < sp.nm; i++){
				dx := sp.p[i].x - pt.x;
				dy := sp.p[i].y - pt.y;
				if(dx*dx + dy*dy < sp.p[i].radius*sp.p[i].radius)
					sp.temp[i] += heat;
			}
		}
	}

	# laser
	if(human != nil){
		human.laser_temperature *= 0.975;
		if(human.laser_overheat && human.laser_temperature < LASER_THRESHOLD_TEMP)
			human.laser_overheat = 0;
		if(!human.laser_overheat && human.lasering && (level >= 4 || level <= 0)){
			if(human.laser_temperature >= LASER_TEMP_MAX){
				human.laser_overheat = 1;
				stopsound();
			}else{
				human.laser_temperature += 1.0;
				(sp, mline) := laserhit();
				if(sp != nil)
					sp.temp[mline] += 1.0;
			}
		}
	}

	# spacewalk state (original drives this from DrawIt)
	if(human != nil && !human.exploding){
		if(human.spacewalk_side){
			d := 1.0 - (human.spacewalk_timeout - tS)/SPACEWALK_TIME;
			if(d > 1.0){
				human.spacewalk_side = 0;
				cp_spacewalk = 0;
			}
		}else if(cp_spacewalk){
			human.spacewalk_side = tweaked();
			if(human.spacewalk_side)
				human.spacewalk_timeout = tS + SPACEWALK_TIME;
			else
				cp_spacewalk = 0;
		}
	}

	# spring breakage and death
	dead: list of ref Ship;
	for(sl = ships; sl != nil; sl = tl sl){
		sp := hd sl;
		death := 0;
		if(sp.stype == ST_HUMAN1){
			if(sp.exploding){
				if(tS > sp.die_timeout)
					dead = sp :: dead;
				continue;
			}
			for(i = 0; i < sp.ns; i++){
				if(!(sp.s[i].flags & Ode->SSF_INACTIVE) &&
						absr(sp.s[i].f) > real sp.s[i].num){
					sp.s[i].flags |= Ode->SSF_INACTIVE;
					if(i == 4)
						missiledel(sp.missiles[0]);
					else if(i == 5)
						missiledel(sp.missiles[1]);
				}
				if((sp.s[i].flags & Ode->SSF_INACTIVE) && i < 3)
					death++;
			}
		}else{
			if(sp.exploding){
				if(tS > sp.die_timeout){
					dead = sp :: dead;
					score += level;
					if(score > best_score)
						best_score = score;
				}
				continue;
			}
			j := 0;
			for(i = 0; i < sp.ns; i++){
				if(sp.s[i].flags & Ode->SSF_INACTIVE)
					j++;
				else if(absr(sp.s[i].f) > real sp.s[i].num){
					sp.s[i].flags |= Ode->SSF_INACTIVE;
					j++;
				}
			}
			if(j > 1)
				death++;
		}
		for(i = 0; i < sp.nm; i++)
			if(sp.temp[i] > MASS_TEMP_MAX)
				death++;
		if(death){
			sp.exploding = 1;
			sp.die_time = tS;
			sp.die_timeout = tS + 0.75;
			noise(750, 74.0, 93.0);
			if(sp.stype == ST_HUMAN1){
				game_over = 1;
				state = SGAMEOVER;
			}
		}
	}
	for(; dead != nil; dead = tl dead)
		shipdel(hd dead);
}

absr(x: real): real
{
	if(x < 0.0)
		return -x;
	return x;
}

# nearest mass on the human's forward laser ray → (owning ship, mass index).
# GAP: original guards the beam per-pixel with GrPeek; this is geometric.
laserhit(): (ref Ship, int)
{
	bsp: ref Ship;
	bi := 0;
	best := 1.0e30;
	(px, py) := fwdaxis(human);
	qx := py;	# perpendicular
	qy := -px;
	for(sl := ships; sl != nil; sl = tl sl){
		sp := hd sl;
		for(i := 0; i < sp.nm; i++){
			if(sp == human && i < 3)
				continue;	# behind/at the emitter
			dx := human.p[0].x - sp.p[i].x;
			dy := human.p[0].y - sp.p[i].y;
			if(absr(dx*qx + dy*qy) < sp.p[i].radius &&
					dx*px + dy*py < 0.0){
				d := dx*dx + dy*dy;
				if(d < best){
					best = d;
					bsp = sp;
					bi = i;
				}
			}
		}
	}
	return (bsp, bi);
}

# ---------------------------------------------------------------- AI, storms

ai()
{
	if(human == nil || human.exploding)
		return;
	for(sl := ships; sl != nil; sl = tl sl){
		sp := hd sl;
		if(sp.stype == ST_HUMAN1)
			continue;
		(px, py) := fwdaxis(sp);
		hx := human.p[0].x - sp.p[0].x;
		hy := human.p[0].y - sp.p[0].y;
		d := math->sqrt(hx*hx + hy*hy);
		if(d == 0.0)
			continue;
		if((px*hx + py*hy)/d > 0.995 && tS > sp.reload_timeout)
			fireonegun(sp, 0, 2.0, 0.4);
	}
}

solarflares()
{
	(nil, hi) := dims();
	if(!alarm && tS > t_solar_storm - 2.0 && tS < t_solar_storm + 1.0){
		sweep(2000, 74.0, 93.0);
		alarm = 1;
	}
	if(t_solar_storm < tS){
		if(tS < t_solar_storm + 5.0){
			if(frand() < 0.1)
				shotnew(MT_SOLAR_FLARE, -300.0, frand() * real hi,
					200.0, 0.0, 25.0, 0.1, 0.0, 0.0);
		}else{
			t_solar_storm = tS + 25.0*frand();
			alarm = 0;
		}
	}
}

logic()
{
	if(kfire && human != nil && level >= 1 && level <= 3)
		humanfiregun();		# held space refires as reload allows
	# unlaunched missiles track a cone-lock target continuously
	if(human != nil)
		for(n := 0; n < 2; n++){
			mi := human.missiles[n];
			if(mi != nil && mi.active && !mi.launched)
				mi.target = targetget(mi);
		}
	ai();
	solarflares();
	expireshots();
	expiresplats();
	expiremissiles();
	checkdamage();
	if(state == SPLAY && remaining <= 0){
		level++;
		shipdel(human);
		initlevel();
	}
}

# ---------------------------------------------------------------- levels

initlevel()
{
	parts = nil;
	popupq = nil;
	if(level == 1 && !(msg_flags & XMSGF_SOLAR_STORM)){
		msg_flags |= XMSGF_SOLAR_STORM;
		popupq = "Face away from Sun in solar storm." :: popupq;
	}
	if(level == 4 && !(msg_flags & XMSGF_ANTISPIN)){
		msg_flags |= XMSGF_ANTISPIN;
		popupq = "Press <CURSOR-DOWN> for anti-spin stabilizer." :: popupq;
	}
	(w, h) := dims();
	remaining = 0;
	human = shipnew(real w/2.0, real h/2.0, ST_HUMAN1);
	for(i := 0; i < level+2; i++)
		placeship(ST_ENEMY1);
	placeship(ST_ENEMY2);
	t_solar_storm = tS + 25.0*frand();
	alarm = 0;
	if(popupq != nil)
		state = SPOPUP;
	else
		state = SLEVEL;
}

newgame()
{
	if(sim != nil)
		alldel();
	sim = ode->new();
	sim.drag_v = 0.0;
	sim.drag_v2 = 0.0;
	sim.drag_v3 = 0.00001;
	sim.accel_limit = 200000.0;
	sim.h = 0.004;
	game_over = 0;
	score = 0;
	level = 1;
	kleft = kright = kup = kdown = kfire = 0;
	human_t_left = human_t_right = human_antispin = 0.0;
	cp_spacewalk = 0;
	(w, h) := dims();
	for(i := 0; i < STARS_NUM; i++){
		stars_x[i] = rn(w);
		stars_y[i] = rn(h);
	}
	stopsound();
	initlevel();
}

# ---------------------------------------------------------------- drawing

org: Point;
cimg: ref Image;
buf: ref Image;			# the frame, composed offscreen so the
				# laser can read it back

pt2(x, y: real): Point
{
	return Point(org.x + int x, org.y + int y);
}

gtext(x, y: int, s: string, ci: int)
{
	if(tfont == nil)
		return;
	cimg.text(Point(org.x+x, org.y+y), pal[ci], (0, 0), tfont, s);
}

gline(x1, y1, x2, y2: real, ci: int)
{
	cimg.line(pt2(x1, y1), pt2(x2, y2), Draw->Endsquare, Draw->Endsquare,
		0, pal[ci], (0, 0));
}

gcircle(x, y: real, r: int, ci: int)
{
	cimg.ellipse(pt2(x, y), r, r, 0, pal[ci], (0, 0));
}

gfillcircle(x, y: real, r: int, ci: int)
{
	cimg.fillellipse(pt2(x, y), r, r, pal[ci], (0, 0));
}

gplot(x, y: real, ci: int)
{
	p := pt2(x, y);
	cimg.draw(Rect(p, p.add((1, 1))), pal[ci], nil, (0, 0));
}

gfillrect(x, y, w, h: int, ci: int)
{
	cimg.draw(Rect((org.x+x, org.y+y), (org.x+x+w, org.y+y+h)),
		pal[ci], nil, (0, 0));
}

# rotate the sprite about its own origin (rect min offsets encode it),
# TempleOS Sprite3ZB convention: sprite +x maps to angle ang
gsprite(x, y: real, n: int, ang: real)
{
	if(draw3d == nil || n < 1 || n > 8)
		return;
	spr := sprites[n];
	msk := smasks[n];
	if(spr == nil)
		return;
	ccx := real spr.r.min.x + real spr.r.dx() / 2.0;
	ccy := real spr.r.min.y + real spr.r.dy() / 2.0;
	cs := math->cos(ang);
	sn := math->sin(ang);
	px := x + ccx*cs - ccy*sn;
	py := y + ccx*sn + ccy*cs;
	draw3d->sprite2d(cimg, pt2(px, py), spr, msk, 0, 0,
		ang*180.0/Math->Pi, 0);
}

blink(): int
{
	return (tickn >> 4) & 1;
}

drawit()
{
	i, j: int;
	img := win.image;
	if(img == nil)
		return;
	if(buf == nil || buf.r.dx() != img.r.dx() || buf.r.dy() != img.r.dy())
		buf = img.display.newimage(Rect((0, 0),
			(img.r.dx(), img.r.dy())), Draw->RGB24, 0, Draw->Black);
	if(buf == nil)
		return;
	cimg = buf;
	org = buf.r.min;
	(w, h) := dims();
	cimg.draw(cimg.r, pal[BLACK], nil, (0, 0));

	gtext(0, 0, sys->sprint("Level:%d Score:%d High Score:%d",
		level, score, best_score), WHITE);
	if(state == SGAMEOVER){
		if(blink())
			gtext((w-9*FONTW)/2, (h-FONTH)/2, "Game Over", WHITE);
	}else if(state == SLEVEL){
		if(blink())
			gtext((w-8*FONTW)/2, (h-FONTH)/2+50,
				sys->sprint("Level %d", level), WHITE);
	}

	for(i = 0; i < STARS_NUM; i++)
		gplot(real stars_x[i], real stars_y[i], WHITE);

	# splats and ions
	for(pl := parts; pl != nil; pl = tl pl){
		pt := hd pl;
		if(pt.ptype == MT_ION)
			gplot(pt.x, pt.y, YELLOW);
		else
			gplot(pt.x, pt.y, LTGREEN);
	}

	# springs (BLACK ones are deliberately invisible)
	for(spl := sim.springs; spl != nil; spl = tl spl){
		s := hd spl;
		if(!(s.flags & Ode->SSF_INACTIVE) && s.userdata != BLACK)
			gline(s.end1.x, s.end1.y, s.end2.x, s.end2.y, s.userdata);
	}

	# missiles
	if(human != nil)
		for(n := 0; n < 2; n++){
			mi := human.missiles[n];
			if(mi == nil || !mi.active)
				continue;
			if(mi.launched && mi.exploding){
				d := (tS - mi.fuse_time)/(mi.die_timeout - mi.fuse_time);
				d = 70.0*math->sin(Math->Pi*d)*mi.tons + 1.0;
				for(i = 1; i < int d; i++){
					ci := LTRED;
					if(i & 1)
						ci = YELLOW;
					gcircle(mi.front.x, mi.front.y, i, ci);
				}
			}else{
				spr := SPRMISSILE;
				if(mi.launched)
					spr = SPRLAUNCHED;
				gsprite((mi.front.x+mi.back.x)/2.0,
					(mi.front.y+mi.back.y)/2.0, spr,
					math->atan2(mi.front.y-mi.back.y,
						mi.front.x-mi.back.x));
			}
		}

	# ships
	for(sl := ships; sl != nil; sl = tl sl){
		sp := hd sl;
		if(sp.exploding){
			if(sp.die_time <= tS && tS <= sp.die_timeout)
				for(j = 0; j < sp.nm; j++){
					d := (tS - sp.die_time)/(sp.die_timeout - sp.die_time);
					d = 7.0*math->sin(Math->Pi*d)*real(6+j) + 1.0;
					for(i = 1; i < int d; i++){
						ci := LTRED;
						if(i & 1)
							ci = YELLOW;
						gcircle(sp.p[j].x, sp.p[j].y, i, ci);
					}
				}
			continue;
		}
		case sp.stype {
		ST_HUMAN1 =>
			drawhuman(sp);
		ST_ENEMY1 or ST_ENEMY2 =>
			if(sp.stype == ST_ENEMY2)
				for(i = 3; i < sp.nm; i++){
					gfillcircle(sp.p[i].x, sp.p[i].y,
						int sp.p[i].radius, PURPLE);
					gcircle(sp.p[i].x, sp.p[i].y,
						int sp.p[i].radius, WHITE);
				}
			p1x := (sp.p[1].x - sp.p[0].x)/2.0;
			p1y := (sp.p[1].y - sp.p[0].y)/2.0;
			p2x := (sp.p[2].x - sp.p[0].x)/2.0;
			p2y := (sp.p[2].y - sp.p[0].y)/2.0;
			spr := SPRGUNREADY;
			if(tS <= sp.reload_timeout)
				spr = SPRGUNBUSY;
			gsprite(sp.p[0].x, sp.p[0].y, spr,
				math->atan2(p1y+p2y, p1x+p2x));
			gsprite(sp.p[0].x+p1x, sp.p[0].y+p1y, SPRSIDE,
				math->atan2(p1y, p1x));
			gsprite(sp.p[0].x+p2x, sp.p[0].y+p2y, SPRSIDE,
				math->atan2(p2y, p2x));
		}
		for(i = 0; i < sp.nm; i++)
			if(sp.temp[i] >= 1.0)
				gcircle(sp.p[i].x, sp.p[i].y, int sp.temp[i], YELLOW);
	}

	# shots (and flares)
	for(shl := shots; shl != nil; shl = tl shl){
		sh := hd shl;
		if(sh.radius < 1.0)
			gplot(sh.m.x, sh.m.y, LTGREEN);
		else{
			if(sh.radius >= 2.0)
				gfillcircle(sh.m.x, sh.m.y, int sh.radius, YELLOW);
			else
				gcircle(sh.m.x, sh.m.y, int sh.radius, YELLOW);
			gcircle(sh.m.x, sh.m.y, int sh.radius, LTGREEN);
		}
	}

	# laser beam, walked pixel by pixel against the frame as LaserPlot
	# does — not shortened to whatever the geometric test picked
	if(human != nil && human.lasering && !human.laser_overheat &&
			!human.exploding && (level >= 4 || level <= 0)){
		(px, py) := fwdaxis(human);
		x1 := human.p[0].x + 10.0*px;
		y1 := human.p[0].y + 10.0*py;
		reach := laserreach(x1, y1, px, py, 790.0);
		if(reach > 0.0)
			gline(x1, y1, x1 + reach*px, y1 + reach*py, LTBLUE);
	}

	# missile target markers
	if(human != nil)
		for(n = 0; n < 2; n++){
			mi := human.missiles[n];
			if(mi == nil || !mi.active || mi.target == nil || mi.target.dead)
				continue;
			gcircle(mi.target.p[0].x, mi.target.p[0].y, 10, LTRED);
			gtext(int mi.target.p[0].x + 12, int mi.target.p[0].y - 4,
				mi.label, LTRED);
		}

	drawpanel(w, h);

	if(state == SPOPUP && popupq != nil)
		drawpopup(w, h, hd popupq);

	img.draw(img.r, buf, nil, buf.r.min);
	img.flush(Draw->Flushnow);
}

drawhuman(sp: ref Ship)
{
	# rearward axis for sprites and thrust vectors (DrawIt convention)
	rx := (sp.p[1].x - sp.p[0].x) + (sp.p[2].x - sp.p[0].x);
	ry := (sp.p[1].y - sp.p[0].y) + (sp.p[2].y - sp.p[0].y);
	rd := math->sqrt(rx*rx + ry*ry);
	if(rd == 0.0){
		rx = 0.0; ry = 1.0;
	}else{
		rx /= rd; ry /= rd;
	}
	arg := math->atan2(ry, rx);
	(tl_, tr_) := enginethrust(sp);
	if(!(sp.s[3].flags & Ode->SSF_INACTIVE)){
		gline(sp.p[1].x, sp.p[1].y,
			sp.p[3].x + tl_/25.0*rx, sp.p[3].y + tl_/25.0*ry, YELLOW);
		gsprite(sp.p[3].x, sp.p[3].y, SPRTHRUSTER, arg);
	}
	if(!(sp.s[5].flags & Ode->SSF_INACTIVE)){
		gline(sp.p[2].x, sp.p[2].y,
			sp.p[4].x + tr_/25.0*rx, sp.p[4].y + tr_/25.0*ry, YELLOW);
		gsprite(sp.p[4].x, sp.p[4].y, SPRTHRUSTER, arg);
	}
	gun := SPRGUNREADY;
	if(tS <= sp.reload_timeout)
		gun = SPRGUNBUSY;
	if(level == 3){
		if(!(sp.s[3].flags & Ode->SSF_INACTIVE))
			gsprite(sp.p[3].x, sp.p[3].y, gun, arg);
		if(!(sp.s[5].flags & Ode->SSF_INACTIVE))
			gsprite(sp.p[4].x, sp.p[4].y, gun, arg);
	}
	if(level == 2 || level == 3){
		if(!(sp.s[1].flags & Ode->SSF_INACTIVE))
			gsprite(sp.p[1].x, sp.p[1].y, gun, arg);
		if(!(sp.s[2].flags & Ode->SSF_INACTIVE))
			gsprite(sp.p[2].x, sp.p[2].y, gun, arg);
	}
	if(level >= 1 && level <= 3)
		gsprite(sp.p[0].x, sp.p[0].y, gun, arg);
	else
		gsprite(sp.p[0].x, sp.p[0].y, SPRLASER, arg);

	if(sp.spacewalk_side){
		d := 1.0 - (sp.spacewalk_timeout - tS)/SPACEWALK_TIME;
		if(d >= 0.0 && d <= 1.0){
			x, y: real;
			if(d < 0.5){
				d = d*2.0;
				x = sp.p[0].x*(1.0-d) + sp.p[sp.spacewalk_side].x*d;
				y = sp.p[0].y*(1.0-d) + sp.p[sp.spacewalk_side].y*d;
			}else{
				d = (d-0.5)*2.0;
				x = sp.p[sp.spacewalk_side].x*(1.0-d) + sp.p[0].x*d;
				y = sp.p[sp.spacewalk_side].y*(1.0-d) + sp.p[0].y*d;
			}
			gsprite(x, y, SPRWALK, arg + 0.75*math->sin(tS*2.0));
		}
	}
}

# XCCtrls DrawCtrlPanelCtrl: bottom-right panel + laser temperature bar
drawpanel(w, h: int)
{
	pl := w - (PSPACING*3+2);
	pt := h - (PSPACING*2 + PRANGE + PBTTN);
	pr := pl + PSPACING*3+2;
	pb := pt + PSPACING*2 + PRANGE;

	gfillrect(pl, pt, PSPACING*3+2, PSPACING*2+PRANGE+PBTTN, LTRED);
	gfillrect(pl+PBORDER, pt+PBORDER, PSPACING*3+2-2*PBORDER,
		PSPACING*2+PRANGE+PBTTN-2*PBORDER, DKGRAY);
	# slider tracks
	gfillrect(pl+PSPACING, pt+PBTTN+PSPACING, 1, PRANGE-1, BLACK);
	gfillrect(pl+2*PSPACING+1, pt+PBTTN+PSPACING, 1, PRANGE-1, BLACK);
	# SpaceWalk button
	cx := (pl+pr+1)/2;
	by := pt + PBORDER + (PSPACING-FONTH)/2;
	gfillrect(cx-9*FONTW/2-3, by, 9*FONTW+6, FONTH+6, BLACK);
	bci := DKGRAY;
	if(cp_spacewalk)
		bci = YELLOW;
	gfillrect(cx-9*FONTW/2-2, by+1, 9*FONTW+4, FONTH+4, bci);
	gtext(cx-9*FONTW/2, by+3, "SpaceWalk", RED);
	gtext(pl+PSPACING-4*FONTW/2, pt+PBTTN+PSPACING-FONTH-2, "Size", RED);
	gtext(pl+2*PSPACING+1-4*FONTW/2, pt+PBTTN+PSPACING-FONTH-2, "Fuse", RED);
	gtext(pl+PSPACING-FONTW/2, pt+PBTTN+PSPACING+PRANGE+3,
		sys->sprint("%d", cp_shot_radius*10/PRANGE), LTRED);
	gtext(pl+2*PSPACING+1-FONTW/2, pt+PBTTN+PSPACING+PRANGE+3,
		sys->sprint("%d", cp_fuse_time*10/PRANGE), LTRED);
	# knobs
	gfillrect(pl+PSPACING-3, pt+PBTTN+PSPACING+PRANGE-1-cp_shot_radius-2,
		7, 5, LTRED);
	gfillrect(pl+2*PSPACING+1-3, pt+PBTTN+PSPACING+PRANGE-1-cp_fuse_time-2,
		7, 5, LTRED);
	gfillrect(pl+PSPACING-2, pt+PBTTN+PSPACING+PRANGE-1-cp_shot_radius-1,
		5, 3, YELLOW);
	gfillrect(pl+2*PSPACING+1-2, pt+PBTTN+PSPACING+PRANGE-1-cp_fuse_time-1,
		5, 3, YELLOW);
	# laser temperature bar
	lt := 0.0;
	if(human != nil)
		lt = human.laser_temperature;
	drange := pr - pl - 10;
	d := int (lt * real drange / LASER_TEMP_MAX);
	gfillrect(pl+4, pb, drange+2, 4, BLACK);
	if(d > 1){
		g := d;
		if(g > drange/3)
			g = drange/3;
		gfillrect(pl+5, pb+1, g, 2, GREEN);
		if(d >= drange/3){
			y := d;
			if(y > 2*drange/3)
				y = 2*drange/3;
			gfillrect(pl+5+drange/3, pb+1, y-drange/3, 2, YELLOW);
			if(d >= 2*drange/3)
				gfillrect(pl+5+2*drange/3, pb+1, d-2*drange/3, 2, RED);
		}
	}
}

drawpopup(w, h: int, msg: string)
{
	tw := len msg * FONTW;
	x := (w - tw)/2;
	y := h/2 - 40;
	gfillrect(x-10, y-10, tw+20, FONTH+20, LTGRAY);
	gfillrect(x-8, y-8, tw+16, FONTH+16, BLACK);
	gtext(x, y, msg, WHITE);
}

# ---------------------------------------------------------------- sound

# TempleOS semitone (ona) to Hz: 440*2^((ona-49)/12)
onafreq(ona: real): int
{
	return int (440.0 * math->pow(2.0, (ona-60.0)/12.0));
}

freq2ona(f: real): real
{
	return 49.0 + 12.0 * math->log(f/440.0) / math->log(2.0);
}

# Noise(ms,o1,o2): random tone in the band (one-voice approximation)
noise(ms: int, o1, o2: real)
{
	if(!have_tone)
		return;
	sweepgen++;
	tone->beep(onafreq(o1 + frand()*(o2-o1)), ms);
	noise_until = tS + real ms/1000.0;
	curdrone = -1;
}

# Sweep(ms,o1,o2): stepped frequency sweep
sweep(ms: int, o1, o2: real)
{
	if(!have_tone)
		return;
	sweepgen++;
	spawn sweeper(sweepgen, ms, o1, o2);
	noise_until = tS + real ms/1000.0;
	curdrone = -1;
}

sweeper(gen, ms: int, o1, o2: real)
{
	steps := 8;
	for(i := 0; i < steps; i++){
		if(gen != sweepgen)
			return;
		tone->snd(onafreq(o1 + (o2-o1)*real i/real steps));
		sys->sleep(ms/steps);
	}
	if(gen == sweepgen)
		tone->stop();
}

stopsound()
{
	if(!have_tone)
		return;
	sweepgen++;
	tone->stop();
	curdrone = 0;
}

# laser drone: original Snd(74) while lasering (no thrust sound exists)
drone()
{
	if(!have_tone || tS < noise_until)
		return;
	want := 0;
	if(state == SPLAY && human != nil && human.lasering &&
			!human.laser_overheat && !human.exploding &&
			(level >= 4 || level <= 0))
		want = onafreq(74.0);
	if(want != curdrone){
		sweepgen++;
		if(want == 0)
			tone->stop();
		else
			tone->snd(want);
		curdrone = want;
	}
}

# ---------------------------------------------------------------- misc

rn(n: int): int
{
	if(n <= 0)
		return 0;
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

frand(): real
{
	return real rn(1000000) / 1000000.0;
}


# LaserPlot: walk the beam a pixel at a time and stop at the first pixel
# that is neither BLACK nor WHITE.  The frame is already composed in buf,
# so this is one readpixels of the beam's bounding box and then a march;
# the run of accepted pixels is contiguous, so the caller draws it as one
# line rather than plotting each.  Returns how far the beam gets.
laserreach(x1, y1, dx, dy: real, maxd: real): real
{
	x2 := x1 + maxd*dx;
	y2 := y1 + maxd*dy;
	# bounding box of the segment, clipped to the frame
	r := Rect((int x1, int y1), (int x1 + 1, int y1 + 1));
	if(int x2 < r.min.x) r.min.x = int x2;
	if(int y2 < r.min.y) r.min.y = int y2;
	if(int x2 + 1 > r.max.x) r.max.x = int x2 + 1;
	if(int y2 + 1 > r.max.y) r.max.y = int y2 + 1;
	if(r.min.x < 0) r.min.x = 0;
	if(r.min.y < 0) r.min.y = 0;
	if(r.max.x > buf.r.max.x) r.max.x = buf.r.max.x;
	if(r.max.y > buf.r.max.y) r.max.y = buf.r.max.y;
	if(r.dx() <= 0 || r.dy() <= 0)
		return 0.0;
	b := array[r.dx()*r.dy()*3] of byte;
	if(buf.readpixels(r, b) < 0)
		return maxd;		# no readback: the whole beam
	n := int maxd;
	step := 1.0;
	if(n < 1)
		return 0.0;
	last := 0.0;
	for(i := 0; i <= n; i++){
		t := real i * step;
		ix := int (x1 + t*dx);
		iy := int (y1 + t*dy);
		if(ix < r.min.x || ix >= r.max.x || iy < r.min.y || iy >= r.max.y)
			break;
		o := ((iy - r.min.y)*r.dx() + (ix - r.min.x))*3;
		c0 := int b[o];
		c1 := int b[o+1];
		c2 := int b[o+2];
		black := c0 == 0 && c1 == 0 && c2 == 0;
		white := c0 == 255 && c1 == 255 && c2 == 255;
		if(!black && !white)
			break;
		last = t;
	}
	return last;
}
