implement Keepaway;

# TempleOS Apps/KeepAway/KeepAway.HC - two-team pseudo-3D basketball keep-away.
# Faithful rebuild: mouse-driven human + 5 AI men (teams of 3), possession,
# stealing, passing/hand-off scoring (+6/+2), fouls (-1), jumping, dribble
# physics, 3-minute clock, best-score persistence, and the original
# GrModels-generated 3D mesh sprites (icons/temple/keepaway_N.mesh) drawn
# with TempleOS's Gr3Mesh probability-dither lighting, frame interpolation
# and Sprite3YB heading rotation, on the 45-degree squashed court
# (screen y = (world y - z)/2, world y range is twice the window height).
#
# Timing: the original AnimateTask loops on real-time dt (tS deltas) with
# Refresh capping it near winmgr's 30fps; DrawIt runs each refresh.  Here
# one 16ms tick does physics with a wall-clock dt then redraws, so all the
# original per-second constants are used unchanged.
#
# GAP: no TempleOS pulldown menu bar (all Play-menu actions are on keys);
#   the PopUpOk rules dialog is an in-window overlay; Shift-Esc == Esc.
# GAP: Noise() is approximated by a single random-frequency beep in the
#   given semitone range rather than true white-ish noise.

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

include "rand.m";
	rand: Rand;

include "tone.m";
	tone: Tone;

include "scorestore.m";
	scorestore: Scorestore;

Keepaway: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# Original tuning constants (per-second / pixel units, used verbatim).
COURTBORDER: con 10;
COLLISIONDAMP: con 0.8;
AIRVISCOSITY: con 0.1;
GRAVITY: con 500.0;		# GRAVITY_ACCELERATION
SHOTVELOCITY: con 400.0;
DRIBBLET: con 0.25;
MANVELOCITY: con 150.0;
MANSQRRADIUS: con 400.0;	# 20*20
FOULVTHRESH: con 50.0;		# FOUL_VELOCITY_THRESHOLD
JUMPVELOCITY: con 250.0;
ROLLVTHRESH: con 100.0;		# ROLL_VELOCITY_THRESHOLD
RANDMANACCEL: con 30.0;		# RANDOM_MAN_ACCELERATION
HEADZOFF: con 200.0;
HANDXOFF: con 30.0;
HANDYOFF: con 20.0;
HANDSQROFF: con 1300.0;		# 30*30+20*20
HANDZOFF: con 110.0;
PERSIDE: con 3;
OBJSNUM: con PERSIDE*2+1;
GAMESECS: con 180.0;

SQRT2: con 1.4142135623730951;
PI: con Math->Pi;

# Frame table indices (Frame imgs[] in the original).
FIRSTSTANDING: con 0;
FIRSTRUNNING: con 0;	LASTRUNNING: con 3;
FIRSTSHOOTING: con 4;	LASTSHOOTING: con 8;
FIRSTDRIBBLING: con 9;	LASTDRIBBLING: con 12;
FIRSTSTOPPED: con 13;	LASTSTOPPED: con 14;

# Team-0 mesh bin per frame; team 1 uses bin+1.
framebin := array[] of {6, 2, 6, 4,  8, 10, 12, 12, 14,  20, 16, 20, 18,  20, 22};
framedt := array[] of {
	0.125, 0.125, 0.125, 0.125,		# running: 2*DRIBBLE_T/4
	0.1, 0.2, 0.2, 0.1, 0.1,		# shooting
	0.125, 0.125, 0.125, 0.125,		# dribbling: 2*DRIBBLE_T/4
	0.125, 0.125				# stopped dribbling: DRIBBLE_T/2
};

Obj: adt {
	team: int;			# -1 is ball
	x, y, z: real;			# world coords: y is doubled, z is up
	dxdt, dydt, dzdt: real;
	ang: real;			# heading
	radius: real;
	stolent0: real;
	getballdt, getballang, nearestmandd: real;
	lastt0, nextt0, foult0: real;
	lastimg, nextimg: int;
	stopped, shooting, hasball, nearestball: int;
};

Mesh: adt {
	vx, vy, vz: array of real;
	tcol, ta, tb, tc: array of int;
};

# The TempleOS 16-color palette.
TBLACK, TBLUE, TGREEN, TCYAN, TRED, TPURPLE, TBROWN, TLTGRAY,
TDKGRAY, TLTBLUE, TLTGREEN, TLTCYAN, TLTRED, TLTPURPLE, TYELLOW, TWHITE: con iota;
palrgba := array[] of {
	int 16r000000FF, int 16r0000AAFF, int 16r00AA00FF, int 16r00AAAAFF,
	int 16rAA0000FF, int 16rAA00AAFF, int 16rAA5500FF, int 16rAAAAAAFF,
	int 16r555555FF, int 16r5555FFFF, int 16r55FF55FF, int 16r55FFFFFF,
	int 16rFF5555FF, int 16rFF55FFFF, int 16rFFFF55FF, int 16rFFFFFFFF
};
# The same 16 colors as exact Plan 9 CMAP8 pixel values.
palcmap := array[] of {0, 36, 42, 44, 160, 162, 164, 170,
	85, 121, 127, 113, 245, 247, 253, 255};

# Sprite raster buffer: covers every mesh (max |xz| radius 40, y -98..10),
# origin (mesh 0,0 = feet) at (SPROX, SPROY).
SPRW: con 84;
SPRH: con 112;
SPROX: con 42;
SPROY: con 98;

win: ref Window;
font: ref Font;
ink: array of ref Image;
meshes: array of ref Mesh;
sprimg, sprmask: ref Image;
sprbuf, maskbuf, zerobuf: array of byte;
zbuf, zclear: array of real;
rvx, rvy, rvz: array of real;
lcg := 12345;
lx, ly, lz: real;			# normalized light source (10000,60000,10000)

objs: array of ref Obj;
ball, human, lastowner: ref Obj;
someoneshooting, someonehasball: int;
shotlandt: real;
gametend, foultend: real;
score0, score1: int;
best0 := 0;
best1 := 9999;
mx := 320;
my := 240;
lastbuttons := 0;
showrules := 1;
lastms: int;
have_tone := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	scorestore = load Scorestore Scorestore->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand == nil){
		sys->fprint(sys->fildes(2), "keepaway: no rand\n");
		raise "fail:load";
	}
	rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS KeepAway", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "*default*");
	ink = array[16] of ref Image;
	for(i := 0; i < 16; i++)
		ink[i] = d.color(palrgba[i]);

	meshes = array[24] of ref Mesh;
	for(i = 1; i <= 23; i++)
		meshes[i] = loadmesh(sys->sprint("/icons/temple/keepaway_%d.mesh", i));

	sprimg = d.newimage(Rect((0, 0), (SPRW, SPRH)), Draw->CMAP8, 0, Draw->Black);
	sprmask = d.newimage(Rect((0, 0), (SPRW, SPRH)), Draw->GREY8, 0, Draw->Black);
	sprbuf = array[SPRW*SPRH] of byte;
	maskbuf = array[SPRW*SPRH] of byte;
	zerobuf = array[SPRW*SPRH] of {* => byte 0};
	zbuf = array[SPRW*SPRH] of real;
	zclear = array[SPRW*SPRH] of {* => 1e30};
	rvx = array[128] of real;
	rvy = array[128] of real;
	rvz = array[128] of real;
	nn := math->sqrt(1.0*1.0 + 6.0*6.0 + 1.0*1.0);
	lx = 1.0/nn;
	ly = 6.0/nn;
	lz = 1.0/nn;

	if(scorestore != nil){
		best0 = scorestore->loadint("keepaway0", 0);
		best1 = scorestore->loadint("keepaway1", 9999);
	}

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	initgame();
	lastms = sys->millisec();

	ticks := chan of int;
	spawn timer(ticks, 16);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		doptr(p);
	k := <-win.ctxt.kbd =>
		dokey(k);
	<-ticks =>
		ms := sys->millisec();
		dt := real(ms - lastms) / 1000.0;
		lastms = ms;
		if(dt > 0.1)
			dt = 0.1;	# defensive clamp after stalls
		if(!showrules)
			step(dt);
		redraw();
	}
}

now(): real
{
	return real sys->millisec() / 1000.0;
}

newobj(): ref Obj
{
	return ref Obj(0, 0.0,0.0,0.0, 0.0,0.0,0.0, 0.0, 0.0, 0.0,
		0.0,0.0,0.0, 0.0,0.0,0.0, 0,0, 0,0,0,0);
}

courtsize(): (int, int)
{
	w := 640;
	h := 480;
	img := win.image;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	return (w, h);
}

initgame()
{
	(w, h) := courtsize();
	someoneshooting = 0;
	someonehasball = 0;
	shotlandt = 0.0;
	objs = array[OBJSNUM] of ref Obj;
	for(i := 0; i < OBJSNUM; i++)
		objs[i] = newobj();
	for(i = 0; i < PERSIDE*2; i++){
		o := objs[i];
		o.team = i & 1;
		o.x = real w / 2.0;
		o.y = real h;		# 2*pix_height/2
		o.nextimg = o.lastimg = FIRSTRUNNING;
	}
	lastowner = nil;
	human = objs[0];
	ball = objs[PERSIDE*2];
	ball.team = -1;
	ball.x = 0.5 * real w / 2.0;
	ball.y = 0.5 * 2.0 * real h / 2.0;
	ball.radius = 11.0;
	ball.z = ball.radius;
	score0 = score1 = 0;
	gametend = now() + GAMESECS;
	foultend = 0.0;
}

doptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	mx = p.xy.x - img.r.min.x;
	my = p.xy.y - img.r.min.y;
	b := p.buttons;
	if(showrules){
		if(b != 0 && lastbuttons == 0)
			dismissrules();
	}else{
		if((b & 1) && !(lastbuttons & 1))
			shoot(human);
		if((b & 6) && !(lastbuttons & 6))	# right (or middle) = jump
			human.dzdt = JUMPVELOCITY;
	}
	lastbuttons = b;
}

dokey(k: int)
{
	if(showrules){
		case k {
		'q' or 'Q' =>
			exit;
		* =>
			dismissrules();
		}
		return;
	}
	case k {
	16r1b or 'q' or 'Q' =>
		exit;
	'\n' =>
		initgame();
	' ' =>
		shoot(human);
	'j' or 'J' =>
		human.dzdt = JUMPVELOCITY;
	}
}

dismissrules()
{
	showrules = 0;
	initgame();	# the original Init()s (and starts the clock) after PopUpOk
}

shoot(o: ref Obj)
{
	if(!someoneshooting && o.hasball){
		someoneshooting = 1;
		o.stopped = 1;
		o.shooting = 1;
		o.hasball = 0;
	}
}

rnd01(): real
{
	return real rand->rand(65536) / 65536.0;
}

rnds(): real		# RandI16/I16_MAX: -1..1
{
	return (real rand->rand(65536) - 32768.0) / 32767.0;
}

onafreq(ona: int): int
{
	# TempleOS Snd(ona): freq = 440*2^((ona-49)/12)
	return int (440.0 * math->pow(2.0, real(ona-49)/12.0) + 0.5);
}

noise(ms, o1, o2: int)
{
	if(!have_tone)
		return;
	f1 := onafreq(o1);
	f2 := onafreq(o2);
	f := f1;
	if(f2 > f1)
		f = f1 + rand->rand(f2-f1+1);
	tone->beep(f, ms);
}

fanfare()
{
	# Snd(86);Sleep(100);Snd;Sleep(100); twice
	for(i := 0; i < 2; i++){
		tone->snd(onafreq(86));
		sys->sleep(100);
		tone->stop();
		sys->sleep(100);
	}
}

# AnimateTask, verbatim: real-time Euler integration, no ODE library.
step(dt: real)
{
	t0 := now();
	(w, h) := courtsize();

	if(gametend != 0.0 && gametend < t0){
		gametend = 0.0;
		if(have_tone)
			tone->beep(800, 250);	# Beep
		if(score0 - score1 > best0 - best1){
			best0 = score0;
			best1 = score1;
			if(scorestore != nil){
				scorestore->saveint("keepaway0", best0);
				scorestore->saveint("keepaway1", best1);
			}
			if(have_tone)
				spawn fanfare();
		}
	}
	if(gametend == 0.0)
		return;

	# Iterative estimate of time to reach the ball; per team only the
	# nearest man (never the last owner) chases.
	nearest := array[2] of ref Obj;
	for(i := 0; i < OBJSNUM; i++){
		o := objs[i];
		o.nearestball = 0;
		if(o == ball)
			continue;
		d := 0.0;
		for(j := 0; j < 5; j++){
			ddx := ball.dxdt*d + ball.x - o.x;
			ddy := ball.dydt*d + ball.y - o.y;
			d = math->sqrt(ddx*ddx + ddy*ddy) / MANVELOCITY;
		}
		o.getballdt = d;
		o.getballang = math->atan2(ball.dydt*d + ball.y - o.y,
			ball.dxdt*d + ball.x - o.x);
		if((o != lastowner && nearest[o.team] == nil) ||
		   (nearest[o.team] != nil && o.getballdt < nearest[o.team].getballdt))
			nearest[o.team] = o;
	}
	if(nearest[0] != nil)
		nearest[0].nearestball = 1;
	if(nearest[1] != nil)
		nearest[1].nearestball = 1;

	for(i = 0; i < OBJSNUM; i++){
		o := objs[i];
		if(o == ball){
			o.x += dt * o.dxdt;
			o.y += dt * o.dydt;
			if(!someoneshooting)
				o.z += dt * (o.dzdt - 0.5*GRAVITY*dt);
		}else{
			if(!o.hasball){
				if(t0 - o.stolent0 > 2.0 && !someoneshooting){
					dx := ball.x - o.x;
					dy := ball.y - o.y;
					if(dx*dx + dy*dy < HANDSQROFF && ball.z < o.z + HANDZOFF){
						getsball := 1;
						for(j := 0; j < PERSIDE*2; j++)
							if(j != i && objs[j].hasball){
								if(rnd01() < 2.0*dt){
									objs[j].stolent0 = t0;
									objs[j].hasball = 0;
								}else
									getsball = 0;
							}
						if(getsball){
							someonehasball = o.hasball = 1;
							if(o != lastowner){
								if(o.team){
									if(t0 < shotlandt + 0.1)
										score1 += 6;
									else
										score1 += 2;
									noise(250, 74, 74);
								}else{
									if(t0 < shotlandt + 0.1)
										score0 += 6;
									else
										score0 += 2;
									noise(250, 86, 86);
								}
								lastowner = o;
							}
						}
					}
				}
			}else if(o != human && rnd01() < 0.25*dt)
				shoot(o);
			if(!o.shooting){
				dx, dy: real;
				if(o == human){
					# the human runs toward the mouse
					dx = real mx - o.x;
					dy = real my * 2.0 - o.y;
				}else{
					if(!someonehasball && o.nearestmandd > 4.0*MANSQRRADIUS &&
					   o.nearestball){
						dx = o.dxdt = MANVELOCITY * math->cos(o.getballang);
						dy = o.dydt = MANVELOCITY * math->sin(o.getballang);
					}else{
						o.dxdt += RANDMANACCEL/SQRT2 * rnds() * dt;
						o.dydt += RANDMANACCEL/SQRT2 * rnds() * dt;
						dx = o.dxdt;
						dy = o.dydt;
					}
				}
				d := math->sqrt(dx*dx + dy*dy);
				if(d >= 1.0){
					o.ang = math->atan2(dy, dx) + PI/2.0;
					dx *= MANVELOCITY/SQRT2 * dt / d;
					dy *= MANVELOCITY/SQRT2 * dt / d;
					o.nearestmandd = 1e300;	# F64_MAX
					for(j := 0; j < PERSIDE*2; j++)
						if(j != i){
							dx2 := objs[j].x - o.x;
							dy2 := objs[j].y - o.y;
							d = dx2*dx2 + dy2*dy2;
							if(d < o.nearestmandd)
								o.nearestmandd = d;
							if(d < MANSQRRADIUS){
								if(d != 0.0){
									d = math->sqrt(d);
									dx2 /= d;
									dy2 /= d;
								}
								if(t0 > o.foult0 + 0.15){
									d = (dx - objs[j].dxdt)*dx2 + (dy - objs[j].dydt)*dy2;
									if(o == human && t0 > o.foult0 + 1.0 &&
									   dt != 0.0 && d/dt > FOULVTHRESH &&
									   objs[j].team){
										noise(250, 62, 62);
										score1 += 1;
										foultend = t0 + 1.0;
									}
									o.foult0 = t0;
								}
							}
						}
					if(t0 < o.foult0 + 0.15){
						dx = -dx;
						dy = -dy;
					}
					o.x += dx;
					o.y += dy;
					o.stopped = 0;
				}else
					o.stopped = 1;
			}
			if(o.dzdt != 0.0)
				o.z += dt * (o.dzdt - 0.5*GRAVITY*dt);
		}

		# court border bounces (world y is doubled)
		if(o.x + o.radius >= real(w - COURTBORDER)){
			o.x = real(w - COURTBORDER - 1) - o.radius;
			o.dxdt = -COLLISIONDAMP * o.dxdt;
			if(o == ball)
				noise(10, 74, 86);
		}
		if(o.x - o.radius < real COURTBORDER){
			o.x = real COURTBORDER + o.radius;
			o.dxdt = -COLLISIONDAMP * o.dxdt;
			if(o == ball)
				noise(10, 74, 86);
		}
		if(o.y + o.radius*2.0 >= real((h - COURTBORDER)*2)){
			o.y = real((h - COURTBORDER)*2 - 1) - o.radius*2.0;
			o.dydt = -COLLISIONDAMP * o.dydt;
			if(o == ball)
				noise(10, 74, 86);
		}
		if(o.y - o.radius*2.0 < real(2*COURTBORDER)){
			o.y = real(COURTBORDER*2) + o.radius*2.0;
			o.dydt = -COLLISIONDAMP * o.dydt;
			if(o == ball)
				noise(10, 74, 86);
		}

		# floor bounce and gravity
		if(o.z - o.radius*2.0 < 0.0){
			o.z = o.radius*2.0;
			o.dzdt = -COLLISIONDAMP * o.dzdt;
			if(o.dzdt > ROLLVTHRESH)
				noise(10, 74, 86);
			if(o != ball)
				o.dzdt = 0.0;
		}else if(o.z - o.radius*2.0 > 0.0)
			o.dzdt -= GRAVITY * dt;
		if(o == ball){
			d := math->exp(-AIRVISCOSITY * dt);
			o.dxdt *= d;
			o.dydt *= d;
			o.dzdt *= d;
		}
	}
}

# DrawIt's per-frame work: held-ball placement, animation frame advance,
# dribble impulse, shot release.
animframes(tt: real)
{
	for(i := 0; i < OBJSNUM; i++){
		o := objs[i];
		if(o == ball)
			continue;
		if(o.hasball){
			ball.x = o.x + HANDXOFF*math->cos(o.ang - PI/2.0) +
				HANDYOFF*math->cos(o.ang);
			# factor 2: the man is not transformed
			ball.y = o.y + HANDXOFF*math->sin(o.ang - PI/2.0)/2.0 +
				HANDYOFF*math->sin(o.ang)/2.0;
			if(ball.z + ball.radius*2.0 > o.z + HANDZOFF)
				ball.z = o.z + HANDZOFF - ball.radius*2.0;
		}else if(o.shooting){
			ball.x = o.x;
			ball.y = o.y;
			ball.z = o.z + HEADZOFF;
		}
		if(tt > o.nextt0){
			if(o.hasball && (ball.z + ball.radius*2.0 >= o.z + HANDZOFF ||
			   fabs(ball.dzdt) < 30.0)){
				# dribble impulse, synchronized to the animation
				ddown := 1.0;
				dup := 1.0 / COLLISIONDAMP;
				ball.dzdt = -((ddown+dup) *
					(o.z + HANDZOFF - ball.radius*4.0)/(1.0 - AIRVISCOSITY) +
					0.5*GRAVITY*(
					sqr(DRIBBLET*dup/(ddown+dup)) -
					sqr(DRIBBLET*ddown/(ddown+dup)) )) / DRIBBLET;
			}
			o.lastt0 = tt;
			o.lastimg = o.nextimg;
			o.nextimg++;
			if(o.stopped){
				if(o.hasball){
					if(!(FIRSTSTOPPED <= o.nextimg && o.nextimg <= LASTSTOPPED))
						o.nextimg = FIRSTSTOPPED;
				}else
					o.nextimg = FIRSTSTANDING;
				o.stopped = 0;
			}else if(o.shooting){
				if(!(FIRSTSHOOTING <= o.lastimg && o.lastimg <= LASTSHOOTING))
					o.nextimg = FIRSTSHOOTING;
				if(o.nextimg > LASTSHOOTING){
					o.nextimg = FIRSTSTANDING;
					someonehasball = someoneshooting = o.hasball = o.shooting = 0;
					ball.dxdt = o.dxdt + SHOTVELOCITY/SQRT2*math->cos(o.ang - PI/2.0);
					ball.dydt = o.dydt + SHOTVELOCITY/SQRT2*math->sin(o.ang - PI/2.0);
					ball.dzdt = o.dzdt + SHOTVELOCITY/SQRT2;
					shotlandt = tt + (ball.dzdt + math->sqrt(sqr(ball.dzdt) +
						2.0*GRAVITY*ball.z)) / GRAVITY;
				}else{
					ball.dxdt = 0.0;
					ball.dydt = 0.0;
					ball.dzdt = 0.0;
				}
			}else if(o.hasball){
				if(FIRSTRUNNING <= o.nextimg && o.nextimg <= LASTRUNNING)
					o.nextimg += FIRSTDRIBBLING - FIRSTRUNNING;
				if(!(FIRSTDRIBBLING <= o.nextimg && o.nextimg <= LASTDRIBBLING))
					o.nextimg = FIRSTDRIBBLING;
			}else{
				if(FIRSTDRIBBLING <= o.nextimg && o.nextimg <= LASTDRIBBLING)
					o.nextimg += FIRSTRUNNING - FIRSTDRIBBLING;
				if(!(FIRSTRUNNING <= o.nextimg && o.nextimg <= LASTRUNNING))
					o.nextimg = FIRSTRUNNING;
			}
			o.nextt0 += framedt[o.lastimg];
			if(o.nextt0 <= tt)
				o.nextt0 = tt + framedt[o.lastimg];
		}
	}
}

sqr(x: real): real
{
	return x*x;
}

fabs(x: real): real
{
	if(x < 0.0)
		return -x;
	return x;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	org := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	tt := now();

	# yellow page: text_attr = BLACK + YELLOW<<4 (bg nibble YELLOW)
	img.draw(img.r, ink[TYELLOW], nil, Point(0, 0));

	# GrBorder thick 2, RED, inset COURT_BORDER
	b0 := COURTBORDER;
	img.draw(Rect((org.x+b0, org.y+b0), (org.x+w-b0, org.y+b0+2)), ink[TRED], nil, Point(0,0));
	img.draw(Rect((org.x+b0, org.y+h-b0-2), (org.x+w-b0, org.y+h-b0)), ink[TRED], nil, Point(0,0));
	img.draw(Rect((org.x+b0, org.y+b0), (org.x+b0+2, org.y+h-b0)), ink[TRED], nil, Point(0,0));
	img.draw(Rect((org.x+w-b0-2, org.y+b0), (org.x+w-b0, org.y+h-b0)), ink[TRED], nil, Point(0,0));

	animframes(tt);

	# painter's order by world y (QSortI64 by y in the original)
	order := array[OBJSNUM] of int;
	for(i := 0; i < OBJSNUM; i++)
		order[i] = i;
	for(i = 1; i < OBJSNUM; i++){
		k := order[i];
		j := i - 1;
		for(; j >= 0 && objs[order[j]].y > objs[k].y; j--)
			order[j+1] = order[j];
		order[j+1] = k;
	}
	for(i = 0; i < OBJSNUM; i++)
		drawobj(img, objs[order[i]], tt);

	# HUD
	blinkon := (sys->millisec()/250) % 2;
	trem := (gametend - tt) / 60.0;
	if(trem <= 0.0){
		trem = 0.0;
		if(blinkon)
			ctext(img, (w - 8*9)/2, (h - 8)/2, TRED, "Game Over");
	}else if(tt < foultend && blinkon)
		ctext(img, (w - 8*4)/2, (h - 8)/2, TLTRED, "Foul");
	mins := int (math->floor(trem));	# int-from-real rounds; the clock truncates
	tsec := int ((trem - real mins) * 600.0);	# tenths of seconds (int rounds)
	if(tsec > 599)
		tsec = 599;
	ctext(img, 0, 0, TBLACK, sys->sprint("Time:%d:%02d.%dScore:", mins, tsec/10, tsec%10));
	ctext(img, 8*27, 0, TBLACK, "Best Score:");
	ctext(img, 8*20, 0, TLTCYAN, sys->sprint("%02d", score0));
	ctext(img, 8*23, 0, TLTPURPLE, sys->sprint("%02d", score1));
	ctext(img, 8*39, 0, TLTCYAN, sys->sprint("%02d", best0));
	ctext(img, 8*42, 0, TLTPURPLE, sys->sprint("%02d", best1));

	if(showrules)
		drawrules(img, w, h);

	img.flush(Draw->Flushnow);
}

ctext(img: ref Image, x, y, col: int, s: string)
{
	img.text(img.r.min.add(Point(x, y)), ink[col], Point(0, 0), font, s);
}

drawobj(img: ref Image, o: ref Obj, tt: real)
{
	org := img.r.min;
	# floor shadow: LTRED marks your man
	r1 := 9.0 - 0.1*o.z;
	if(r1 < 1.0)
		r1 = 1.0;
	r2 := r1 / 4.0;
	if(r2 < 1.0)
		r2 = 1.0;
	sc := TBLACK;
	if(o == human)
		sc = TLTRED;
	img.fillellipse(Point(org.x + int o.x, org.y + int (o.y/2.0)),
		int r1, int r2, ink[sc], Point(0, 0));

	dx := org.x + int o.x;
	dy := org.y + int ((o.y - o.z)/2.0);
	if(o == ball)
		rendersprite(img, dx, dy, meshes[1], nil, 0.0, 0.0);
	else{
		bin := framebin[o.lastimg] + o.team;
		bin2 := framebin[o.nextimg] + o.team;
		t := 0.0;
		den := o.nextt0 - o.lastt0;
		if(den > 0.0)
			t = (tt - o.lastt0) / den;
		if(t < 0.0)
			t = 0.0;
		if(t > 1.0)
			t = 1.0;
		rendersprite(img, dx, dy, meshes[bin], meshes[bin2], t, o.ang);
	}
}

# TempleOS Gr3Mesh + DCLighting + SpriteInterpolate + Sprite3YB:
# vertices lerped between frames, rotated about the vertical (y) axis by
# the heading, orthographically projected 1:1 (viewer at -z; smaller z
# wins the depth test), each triangle probability-dithered between two
# palette colors by illumination from light source (10000,60000,10000).
rendersprite(img: ref Image, dstx, dsty: int, m0, m1: ref Mesh, t, ang: real)
{
	if(m0 == nil)
		return;
	if(m1 == nil || len m1.vx != len m0.vx)
		m1 = m0;
	sprbuf[0:] = zerobuf;
	maskbuf[0:] = zerobuf;
	zbuf[0:] = zclear;
	c := math->cos(ang);
	s := math->sin(ang);
	nv := len m0.vx;
	for(i := 0; i < nv; i++){
		x := m0.vx[i] + t*(m1.vx[i] - m0.vx[i]);
		y := m0.vy[i] + t*(m1.vy[i] - m0.vy[i]);
		z := m0.vz[i] + t*(m1.vz[i] - m0.vz[i]);
		rvx[i] = c*x + s*z;
		rvy[i] = y;
		rvz[i] = -s*x + c*z;
	}
	nt := len m0.ta;
	for(i = 0; i < nt; i++){
		a := m0.ta[i];
		b := m0.tb[i];
		cc := m0.tc[i];
		x1 := rvx[a]; y1 := rvy[a]; z1 := rvz[a];
		x2 := rvx[b]; y2 := rvy[b]; z2 := rvz[b];
		x3 := rvx[cc]; y3 := rvy[cc]; z3 := rvz[cc];

		# DCLighting: normal of (p1-p2)x(p3-p2), dot the light source
		v1x := x1-x2; v1y := y1-y2; v1z := z1-z2;
		v2x := x3-x2; v2y := y3-y2; v2z := z3-z2;
		nx := v1y*v2z - v1z*v2y;
		ny := v1z*v2x - v1x*v2z;
		nz := v1x*v2y - v1y*v2x;
		nn := math->sqrt(nx*nx + ny*ny + nz*nz);
		if(nn == 0.0)
			continue;
		ill := (nx*lx + ny*ly + nz*lz)/nn + 1.0;
		col := m0.tcol[i] & 15;
		c0, c1: int;
		p: real;
		if(ill < 1.0){
			c0 = col;
			c1 = TBLACK;
			p = ill;
		}else{
			c0 = col ^ 8;
			c1 = col;
			p = ill - 1.0;
		}
		pthresh := int (p * 65536.0);
		b0 := byte palcmap[c0];
		b1 := byte palcmap[c1];

		det := (x2-x1)*(y3-y1) - (x3-x1)*(y2-y1);
		if(det == 0.0)
			continue;
		minx := int (fmin(fmin(x1, x2), x3)) - 1 + SPROX;
		maxx := int (fmax(fmax(x1, x2), x3)) + 1 + SPROX;
		miny := int (fmin(fmin(y1, y2), y3)) - 1 + SPROY;
		maxy := int (fmax(fmax(y1, y2), y3)) + 1 + SPROY;
		if(minx < 0) minx = 0;
		if(maxx > SPRW-1) maxx = SPRW-1;
		if(miny < 0) miny = 0;
		if(maxy > SPRH-1) maxy = SPRH-1;
		for(py := miny; py <= maxy; py++){
			fy := real(py - SPROY);
			row := py * SPRW;
			for(px := minx; px <= maxx; px++){
				fx := real(px - SPROX);
				w1 := ((x2-fx)*(y3-fy) - (x3-fx)*(y2-fy)) / det;
				w2 := ((x3-fx)*(y1-fy) - (x1-fx)*(y3-fy)) / det;
				w3 := 1.0 - w1 - w2;
				if(w1 < -1e-9 || w2 < -1e-9 || w3 < -1e-9)
					continue;
				z := w1*z1 + w2*z2 + w3*z3;
				idx := row + px;
				if(z >= zbuf[idx])
					continue;
				zbuf[idx] = z;
				lcg = lcg*1664525 + 1013904223;
				if(((lcg>>8) & 16rFFFF) < pthresh)
					sprbuf[idx] = b0;
				else
					sprbuf[idx] = b1;
				maskbuf[idx] = byte 255;
			}
		}
	}
	sprimg.writepixels(sprimg.r, sprbuf);
	sprmask.writepixels(sprmask.r, maskbuf);
	img.draw(Rect((dstx-SPROX, dsty-SPROY), (dstx-SPROX+SPRW, dsty-SPROY+SPRH)),
		sprimg, sprmask, sprimg.r.min);
}

fmin(a, b: real): real
{
	if(a < b)
		return a;
	return b;
}

fmax(a, b: real): real
{
	if(a > b)
		return a;
	return b;
}

drawrules(img: ref Image, w, h: int)
{
	# PopUpOk rules dialog as an in-window overlay
	lines := array[] of {
		"Pass or hand-off to your team to score points.",
		"",
		"    2 points for successful hand-off.",
		"    6 points for successful pass.",
		"    1 point penalty for foul.",
		"",
		"Left-Click  to pass.",
		"",
		"Right-Click to jump.",
		"",
		"                 Ok(ESC)"
	};
	bw := 48*8 + 16;
	bh := len lines * 8 + 16;
	org := img.r.min;
	x0 := org.x + (w - bw)/2;
	y0 := org.y + (h - bh)/2;
	img.draw(Rect((x0-2, y0-2), (x0+bw+2, y0+bh+2)), ink[TBLACK], nil, Point(0,0));
	img.draw(Rect((x0, y0), (x0+bw, y0+bh)), ink[TWHITE], nil, Point(0,0));
	for(i := 0; i < len lines; i++){
		col := TBLACK;
		if(i == len lines - 1)
			col = TGREEN;
		img.text(Point(x0+8, y0+8+i*8), ink[col], Point(0,0), font, lines[i]);
	}
}

loadmesh(path: string): ref Mesh
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[65536] of byte;
	n := 0;
	for(;;){
		m := sys->read(fd, buf[n:], len buf - n);
		if(m <= 0)
			break;
		n += m;
	}
	if(n <= 0)
		return nil;
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	if(lines == nil)
		return nil;
	(nil, hdr) := sys->tokenize(hd lines, " \t");
	if(len hdr != 3 || hd hdr != "mesh")
		return nil;
	nv := int hd tl hdr;
	nf := int hd tl tl hdr;
	m := ref Mesh(array[nv] of real, array[nv] of real, array[nv] of real,
		array[nf] of int, array[nf] of int, array[nf] of int, array[nf] of int);
	vi := 0;
	fi := 0;
	for(lines = tl lines; lines != nil; lines = tl lines){
		(nil, tk) := sys->tokenize(hd lines, " \t\r");
		if(tk == nil)
			continue;
		if(hd tk == "v" && len tk == 4 && vi < nv){
			tk = tl tk;
			m.vx[vi] = real int hd tk; tk = tl tk;
			m.vy[vi] = real int hd tk; tk = tl tk;
			m.vz[vi] = real int hd tk;
			vi++;
		}else if(hd tk == "f" && len tk == 5 && fi < nf){
			tk = tl tk;
			m.tcol[fi] = int hd tk; tk = tl tk;
			m.ta[fi] = int hd tk; tk = tl tk;
			m.tb[fi] = int hd tk; tk = tl tk;
			m.tc[fi] = int hd tk;
			fi++;
		}
	}
	if(vi != nv || fi != nf)
		return nil;
	return m;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
