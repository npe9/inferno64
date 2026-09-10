implement Strider;

# Strider - a walking-machine combat sim, first person, in the shape
# that genre took: a throttle rather than a speed, legs that turn slower
# than the torso they carry, a torso that aims independently of them,
# three weapon groups that trade damage against heat and ammunition, a
# heat scale that will shut the machine down if it is ignored, and
# armour that is lost a section at a time rather than a hit point at a
# time.
#
# It stands on gorge(1)'s findings rather than rediscovering them: the
# provider is chosen by whether a window manager handed us a context,
# pens are replicated 32-bit images so draw3d(2) will actually shade
# them, and the fill scratch is allocated once.  What is new here is the
# amount of geometry - a heightfield under a machine that walks over it,
# rather than a corridor that slides past - and a head-up display that
# has to be drawn over 3-D without the depth buffer eating it.

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

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;
	Vector: import draw3d;

include "keyhold.m";
	keyhold: Keyhold;
	Binding: import keyhold;

include "tone.m";
	tone: Tone;

include "frameclock.m";
	fclock: Frameclock;

include "scorestore.m";
	scorestore: Scorestore;

Strider: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# What this game's keys do.  The bits are its own and so is the table:
# keyhold(2) names no buttons, because what a button means is the
# program's business - the same bit is jump in one of these games and
# fire in another.
KLEFT, KRIGHT, KUP, KDOWN, KA, KB, KSEL, KSTART: con 1 << iota;

BINDS := array[] of {
	(Keyboard->Left, KLEFT), ('a', KLEFT), ('A', KLEFT),
	(Keyboard->Right, KRIGHT), ('d', KRIGHT), ('D', KRIGHT),
	(Keyboard->Up, KUP), ('w', KUP), ('W', KUP),
	(Keyboard->Down, KDOWN), ('s', KDOWN), ('S', KDOWN),
	('z', KB), ('Z', KB), (',', KB),
	('x', KA), ('X', KA), ('.', KA), (' ', KA),
	('\n', KSTART), ('\t', KSEL),
};

kb: ref Binding;

# Playing, as against running a self test or writing a screenshot.  Only
# a playing program asks tone(2) for audio.
playing(): int
{
	return mode == 0;
}

WIDE:	con 640;
HIGH:	con 480;

DEG:	con 3.14159265358979/180.0;

# terrain
GRID:	con 8.0;		# world units between height samples
NEAR:	con 11;			# samples each way from the machine, drawn
FARV:	con real NEAR * GRID;

EYEY:	con 9.0;		# cockpit height above the machine's feet

# sections, in the order the damage diagram shows them
LARM, LTORSO, CTORSO, RTORSO, RARM, LEGS, NSECT: con iota;

# weapon groups
LASER, CANNON, MISSILE, NGROUP: con iota;

# what each group costs and does
HEAT := array[NGROUP] of {19.0, 5.0, 12.0};
DMG := array[NGROUP] of {14.0, 22.0, 9.0};
COOL := array[NGROUP] of {26, 40, 70};		# frames between shots
SALVO := array[NGROUP] of {1, 1, 6};
GNAME := array[NGROUP] of {"LASER", "CANNON", "MISSILE"};

MAXHEAT:	con 100.0;
COOLRATE:	con 0.42;	# heat shed a frame
SHUTDOWN:	con 200;	# frames a machine is down for after overheat
BOOMFRAMES:	con 70;		# frames a destroyed machine takes to fall

# Degrees of stride per world unit walked.  A full cycle is two steps,
# so at the closing speed above that is a step every half second or so -
# a big machine's pace, not a person's.
STRIDERATE:	con 26.0;
STRIDE:	con 1.6;		# how far a foot swings, world units
LIFT:	con 0.9;		# how far the leading foot leaves the ground
BOB:	con 0.55;		# how far the hips drop at mid stride
ARMSW:	con 1.0;		# arms swing against the legs

Mech: adt {
	x, z:	real;
	face:	real;		# where the legs point, degrees
	twist:	real;		# where the torso points, relative
	throt:	real;		# -1 .. 1
	spd:	real;
	armour:	array of real;
	heat:	real;
	down:	int;		# frames of shutdown left
	cool:	array of int;	# per group
	ammo:	array of int;
	alive:	int;
	fire:	int;		# ai: frames until it shoots
	boom:	int;
	phase:	real;		# stride, degrees; advanced by distance walked
	fall:	real;		# 0 upright, 1 flat, once it is destroyed
};

Shot: adt {
	x, y, z:	real;
	vx, vy, vz:	real;
	dmg:	real;
	mine:	int;
	t:	int;
	live:	int;
};

Beam: adt {
	ax, ay, az:	real;
	bx, by, bz:	real;
	t:	int;
	mine:	int;
};

NFOE:	con 4;
NSHOT:	con 48;
NBEAM:	con 8;

WALK:	con 0.36;		# world units a frame at full throttle
TURN:	con 1.05;		# degrees a frame, legs
TWIST:	con 2.2;		# degrees a frame, torso
TWISTMAX:	con 70.0;

win: ref Window;
disp: ref Display;
d3: Draw3d;
ctx: ref Draw3d->Context;
font: ref Font;
target: ref Image;

cgrnd, cgrnd2, chill, csky, cmech, cmech2, cfoe, cfoe2, cbeam, cshell,
	cwhite, cred, camber, cgreen, cdark: ref Image;

qv := array[4] of Vector;
ql := array[4] of real;
vr: Rect;			# the viewport, for the cull

me: ref Mech;
foes: array of ref Mech;
shots: array of ref Shot;
beams: array of ref Beam;
group := LASER;
lock := -1;			# which foe is targeted
score := 0;
best := 0;
frames := 0;
over := 0;
pad := 0;
prevpad := 0;
audio := 0;
mode := 0;
provider := "/dis/math/draw3ddev.dis";
forced: string;
underwm := 0;
nbench := 120;
nnear := NEAR;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	keyhold = load Keyhold Keyhold->PATH;
	tone = load Tone Tone->PATH;
	kb = keyhold->mk(BINDS);
	fclock = load Frameclock Frameclock->PATH;
	scorestore = load Scorestore Scorestore->PATH;
	for(a := tl argv; a != nil; a = tl a){
		case hd a {
		"-t" =>	mode = 1;
		"-b" =>	mode = 2;
		"-s" =>	mode = 3;
		"-q" =>	audio = -1;
		"-S" =>	forced = Draw3d->PATH;
		"-D" =>	forced = "/dis/math/draw3ddev.dis";
		"-n" =>	if(tl a != nil){
				a = tl a;
				nbench = int hd a;
			}
		}
	}
	if(mode == 1 || mode == 3)
		provider = Draw3d->PATH;
	# See gorge(1) BUGS.  The device provider reaches the GPU and is
	# far faster, and it composes the frame wrongly - the geometry
	# queue is drained after everything the CPU drew, so it paints over
	# the head-up display.  A cockpit sim is the worst possible case
	# for that.  Software by default; -D asks for the other one.
	provider = Draw3d->PATH;
	if((mode == 0 || mode == 2) && ctxt != nil)
		underwm = 1;
	if(forced != nil)
		provider = forced;
	d3 = load Draw3d provider;
	if(d3 == nil && provider != Draw3d->PATH){
		provider = Draw3d->PATH;
		d3 = load Draw3d provider;
	}
	if(d3 == nil){
		sys->fprint(sys->fildes(2), "strider: cannot load draw3d: %r\n");
		raise "fail:load";
	}
	d3->init();
	if(fclock != nil)
		fclock->init();
	if(mode == 1 || mode == 3){
		if(mode == 1)
			nnear = 5;	# see gorge(1): the software provider is slow
		disp = Display.allocate(nil);
		if(disp == nil){
			sys->fprint(sys->fildes(2), "strider: no display: %r\n");
			raise "fail:display";
		}
		target = disp.newimage(Rect((0,0),(WIDE,HIGH)),
			disp.image.chans, 0, Draw->Black);
	}else{
		wmclient = load Wmclient Wmclient->PATH;
		sys->pctl(Sys->NEWPGRP, nil);
		wmclient->init();
		if(ctxt == nil)
			ctxt = wmclient->makedrawcontext();
		win = wmclient->window(ctxt, "Strider", Wmclient->Appl);
		disp = win.display;
	}
	colours();
	font = Font.open(disp, "/fonts/lucidasans/unicode.8.font");
	if(font == nil)
		font = Font.open(disp, "*default*");
	if(scorestore != nil)
		best = scorestore->loadint("strider", 0);
	# Only when actually playing.  tone(2)'s sfx() is silent until
	# init() has succeeded, so the self test and the screenshot modes
	# make no sound and spawn nothing by simply not asking for any.
	if(audio == 0 && playing() && tone != nil && tone->init() == nil)
		audio = 1;
	newgame();
	case mode {
	1 =>	selftest();
		return;
	3 =>	shot();
		return;
	}
	if(mode == 2){
		bench();
		return;
	}
	win.reshape(Rect((0,0),(WIDE,HIGH)));
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);
	target = win.image;
	ctx = d3->context(target);
	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q'){
			if(tone != nil)
				tone->stop();
			if(score > best && scorestore != nil)
				scorestore->saveint("strider", score);
			if(fclock != nil)
				fclock->report("strider");
			exit;
		}
		key(k);
	<-ticks =>
		step();
		target = win.image;
		frame();
		target.flush(Draw->Flushnow);
	}
}

# Pens are replicated one-pixel images in the display's own channels, not
# Display.rgb: rgb() gives depth 24 and draw3d's litcolour() shades only
# depth 32, returning anything else unchanged, so an rgb() scene comes
# out flat with no error at all.  See gorge(1).
rgb32(r, g, b: int): ref Image
{
	return disp.newimage(Rect((0,0),(1,1)), disp.image.chans, 1,
		(r<<24) | (g<<16) | (b<<8) | 16rFF);
}

colours()
{
	cgrnd = rgb32(122, 148, 92);
	cgrnd2 = rgb32(152, 140, 98);
	chill = rgb32(182, 170, 142);
	csky = rgb32(58, 74, 116);
	cmech = rgb32(150, 165, 180);
	cmech2 = rgb32(90, 105, 125);
	cfoe = rgb32(246, 138, 96);
	cfoe2 = rgb32(186, 96, 72);
	cbeam = rgb32(255, 90, 90);
	cshell = rgb32(255, 220, 120);
	cwhite = rgb32(235, 240, 245);
	cred = rgb32(230, 70, 60);
	camber = rgb32(240, 180, 60);
	cgreen = rgb32(90, 220, 120);
	cdark = rgb32(20, 24, 34);
}

# ---------------------------------------------------------------- world

# The ground.  Three sines that do not share a period, so the field is
# rolling rather than tiled, and it is a pure function of position so
# nothing has to be stored or streamed.
height(x, z: real): real
{
	return 6.0*math->sin(x*0.031) + 4.5*math->sin(z*0.027)
		+ 3.0*math->sin((x+z)*0.017);
}

newgame()
{
	score = 0;
	me = ref Mech;
	me.x = 0.0;
	me.z = 0.0;
	me.face = 0.0;
	me.twist = 0.0;
	me.throt = 0.0;
	me.spd = 0.0;
	me.armour = array[NSECT] of {60.0, 80.0, 130.0, 80.0, 60.0, 90.0};
	me.heat = 0.0;
	me.down = 0;
	me.cool = array[NGROUP] of {0, 0, 0};
	me.ammo = array[NGROUP] of {-1, 40, 24};	# -1 = unlimited
	me.alive = 1;
	me.boom = 0;
	me.phase = 0.0;
	me.fall = 0.0;
	foes = array[NFOE] of ref Mech;
	for(i := 0; i < NFOE; i++)
		foes[i] = spawnfoe(i);
	shots = array[NSHOT] of ref Shot;
	beams = array[NBEAM] of ref Beam;
	group = LASER;
	lock = -1;
	frames = 0;
	over = 0;
	pad = 0;
	prevpad = 0;
}

spawnfoe(i: int): ref Mech
{
	f := ref Mech;
	a := real i * 90.0 + 25.0;
	r := 150.0 + real (i%3) * 60.0;
	f.x = r * math->cos(a*DEG);
	f.z = r * math->sin(a*DEG);
	f.face = a + 180.0;
	f.twist = 0.0;
	f.throt = 0.0;
	f.spd = 0.0;
	f.armour = array[NSECT] of {40.0, 55.0, 90.0, 55.0, 40.0, 60.0};
	f.heat = 0.0;
	f.down = 0;
	f.cool = array[NGROUP] of {0, 0, 0};
	f.ammo = array[NGROUP] of {-1, -1, -1};
	f.alive = 1;
	f.fire = 90 + i*30;
	f.boom = 0;
	# Start them out of step with each other.  A lance walking in
	# lockstep looks like one machine drawn four times.
	f.phase = real (i * 90);
	f.fall = 0.0;
	return f;
}

# ---------------------------------------------------------------- input

key(k: int)
{
	case k {
	'1' =>	group = LASER;
	'2' =>	group = CANNON;
	'3' =>	group = MISSILE;
	# NOT Tab: this program's own binding table gives Tab to KSEL,
	# which is what twists the torso right, and intercepting it here
	# left that with no key at all.  A binding taken twice is a binding
	# taken once - and it is a table this program writes now, so it is
	# a table this program can read.
	'e' or 'E' =>	nexttarget();
	'c' or 'C' =>	me.twist = 0.0;		# centre the torso
	'=' or '+' =>	me.throt += 0.25;
	'-' or '_' =>	me.throt -= 0.25;
	'0' =>	me.throt = 0.0;
	* =>
		pad = kb.key(pad, k);
		return;
	}
	if(me.throt > 1.0)
		me.throt = 1.0;
	if(me.throt < -0.5)
		me.throt = -0.5;
}

nexttarget()
{
	for(i := 1; i <= NFOE; i++){
		j := (lock + i) % NFOE;
		if(foes[j] != nil && foes[j].alive){
			lock = j;
			if(tone != nil)
				tone->sfx(1, 1400, 40);
			return;
		}
	}
	lock = -1;
}

# ----------------------------------------------------------------- step

step()
{
	frames++;
	tone->sfxtick();
	if(over > 0){
		over--;
		stepshots();
		if(over == 0)
			newgame();
		return;
	}
	stepme();
	for(i := 0; i < NFOE; i++)
		if(foes[i] != nil)
			stepfoe(foes[i], i);
	stepshots();
	for(i = 0; i < NBEAM; i++)
		if(beams[i] != nil && beams[i].t > 0)
			beams[i].t--;
	if(me.armour[CTORSO] <= 0.0 && over == 0){
		over = 180;
		me.alive = 0;
		bigboom(me.x, me.z);
	}
	n := 0;
	for(i = 0; i < NFOE; i++)
		if(foes[i] != nil && foes[i].alive)
			n++;
	if(n == 0 && over == 0){
		over = 180;
		score += 2000;
	}
	prevpad = pad;
}

stepme()
{
	# The heat scale runs whether or not anything is firing, and a
	# shutdown is not a pause: shots already in the air still arrive.
	me.heat -= COOLRATE;
	if(me.heat < 0.0)
		me.heat = 0.0;
	if(me.down > 0){
		me.down--;
		if(me.down == 0)
			me.heat = MAXHEAT * 0.5;
		return;
	}
	if(me.heat >= MAXHEAT){
		me.down = SHUTDOWN;
		me.throt = 0.0;
		me.spd = 0.0;
		if(tone != nil)
			tone->sfx(4, 140, 700);
		return;
	}
	# legs
	if((pad & KLEFT) && !(pad & KRIGHT))
		me.face -= TURN;
	else if((pad & KRIGHT) && !(pad & KLEFT))
		me.face += TURN;
	# torso, independent of them, and this is the whole of the genre
	if((pad & KB))
		me.twist -= TWIST;
	if((pad & KSEL))
		me.twist += TWIST;
	if(me.twist > TWISTMAX)
		me.twist = TWISTMAX;
	if(me.twist < -TWISTMAX)
		me.twist = -TWISTMAX;
	if(pad & KUP)
		me.throt += 0.02;
	if(pad & KDOWN)
		me.throt -= 0.02;
	if(me.throt > 1.0)
		me.throt = 1.0;
	if(me.throt < -0.5)
		me.throt = -0.5;
	# a machine this size does not change speed at once
	# Ramp towards the throttle setting, and STOP there.  Stepping
	# towards it without clamping overshoots by up to a step and then
	# steps back, so the machine sat oscillating a little above its own
	# top speed for ever - not visible, but the number was wrong.
	want := me.throt * WALK;
	if(me.spd < want){
		me.spd += 0.006;
		if(me.spd > want)
			me.spd = want;
	}else if(me.spd > want){
		me.spd -= 0.010;
		if(me.spd < want)
			me.spd = want;
	}
	me.x += me.spd * math->cos(me.face*DEG);
	me.z += me.spd * math->sin(me.face*DEG);
	for(g := 0; g < NGROUP; g++)
		if(me.cool[g] > 0)
			me.cool[g]--;
	# Held, not edged: a weapon group fires again as soon as it has
	# cycled, for as long as the trigger is down.  shoot() is what
	# gates on the cooldown, the heat and the ammunition.
	if(pad & KA)
		shoot(me, group, 1);
}

# Where a machine's guns point: the legs plus the torso twist.
aim(m: ref Mech): real
{
	return m.face + m.twist;
}

shoot(m: ref Mech, g, mine: int)
{
	if(m.down > 0 || m.cool[g] > 0)
		return;
	if(m.ammo[g] == 0)
		return;
	if(m.heat + HEAT[g] > MAXHEAT + 20.0)
		return;			# would not survive its own shot
	m.cool[g] = COOL[g];
	m.heat += HEAT[g];
	if(m.ammo[g] > 0)
		m.ammo[g]--;
	a := aim(m) * DEG;
	ey := height(m.x, m.z) + EYEY;
	if(g == LASER){
		# hitscan: the beam arrives this frame
		(hit, hx, hy, hz) := trace(m, a, ey, mine);
		addbeam(m.x, ey, m.z, hx, hy, hz, mine);
		if(hit != nil)
			damage(hit, DMG[LASER], mine);
		if(tone != nil)
			tone->sfx(3, 1500, 90);
		return;
	}
	n := SALVO[g];
	for(i := 0; i < n; i++){
		sp := 3.2;
		spread := 0.0;
		if(g == MISSILE)
			spread = (real i - real n/2.0) * 1.6 * DEG;
		aa := a + spread;
		fire(m.x, ey, m.z, math->cos(aa)*sp, 0.0, math->sin(aa)*sp,
			DMG[g], mine);
	}
	if(tone != nil){
		if(g == CANNON)
			tone->sfx(3, 320, 110);
		else
			tone->sfx(2, 700, 140);
	}
}

# A laser shot, along the aim, out to FARV.  Returns what it met.
trace(m: ref Mech, a, ey: real, mine: int): (ref Mech, real, real, real)
{
	dx := math->cos(a);
	dz := math->sin(a);
	best: ref Mech = nil;
	bestt := FARV * 1.6;
	if(mine){
		for(i := 0; i < NFOE; i++){
			f := foes[i];
			if(f == nil || !f.alive)
				continue;
			t := hitdist(m.x, m.z, dx, dz, f.x, f.z, 5.0);
			if(t > 0.0 && t < bestt){
				bestt = t;
				best = f;
			}
		}
	}else{
		t := hitdist(m.x, m.z, dx, dz, me.x, me.z, 5.0);
		if(t > 0.0 && t < bestt){
			bestt = t;
			best = me;
		}
	}
	hx := m.x + dx*bestt;
	hz := m.z + dz*bestt;
	hy := ey;
	if(best == nil){
		hy = height(hx, hz) + 2.0;
		return (nil, hx, hy, hz);
	}
	return (best, hx, height(best.x, best.z) + EYEY*0.7, hz);
}

# How far along a ray a circle of radius r about (cx, cz) is first met,
# or -1.  The machines are upright and taller than the ground rolls, so
# a circle in plan is the right shape for this and a sphere is not.
hitdist(ox, oz, dx, dz, cx, cz, r: real): real
{
	ex := cx - ox;
	ez := cz - oz;
	t := ex*dx + ez*dz;
	if(t <= 0.0)
		return -1.0;
	px := ox + dx*t - cx;
	pz := oz + dz*t - cz;
	if(px*px + pz*pz > r*r)
		return -1.0;
	return t;
}

addbeam(ax, ay, az, bx, by, bz: real, mine: int)
{
	for(i := 0; i < NBEAM; i++){
		if(beams[i] != nil && beams[i].t > 0)
			continue;
		beams[i] = ref Beam(ax, ay, az, bx, by, bz, 8, mine);
		return;
	}
}

fire(x, y, z, vx, vy, vz, dmg: real, mine: int)
{
	for(i := 0; i < NSHOT; i++){
		if(shots[i] != nil && shots[i].live)
			continue;
		shots[i] = ref Shot(x, y, z, vx, vy, vz, dmg, mine, 0, 1);
		return;
	}
}

stepshots()
{
	for(i := 0; i < NSHOT; i++){
		s := shots[i];
		if(s == nil || !s.live)
			continue;
		s.t++;
		s.x += s.vx;
		s.y += s.vy;
		s.z += s.vz;
		s.vy -= 0.012;			# they do drop
		if(s.y < height(s.x, s.z)){
			s.live = 0;
			continue;
		}
		if(s.t > 260){
			s.live = 0;
			continue;
		}
		if(s.mine){
			for(j := 0; j < NFOE; j++){
				f := foes[j];
				if(f == nil || !f.alive)
					continue;
				if(!close(s, f))
					continue;
				damage(f, s.dmg, 1);
				s.live = 0;
				break;
			}
		}else if(me.alive && close(s, me)){
			damage(me, s.dmg, 0);
			s.live = 0;
		}
	}
}

close(s: ref Shot, m: ref Mech): int
{
	dx := s.x - m.x;
	dz := s.z - m.z;
	if(dx*dx + dz*dz > 30.0)
		return 0;
	base := height(m.x, m.z);
	return s.y > base && s.y < base + 16.0;
}

# Damage lands on a section, not on a total.  Which one is arbitrary
# here and in the genre it is where the shot struck; what matters is
# that armour is spent unevenly and that the centre torso is what
# actually kills.
damage(m: ref Mech, d: real, mine: int)
{
	sect := (frames * 7 + int (m.x + m.z)) % NSECT;
	m.armour[sect] -= d;
	if(m.armour[sect] < 0.0){
		spill := -m.armour[sect];
		m.armour[sect] = 0.0;
		m.armour[CTORSO] -= spill * 0.5;
	}
	if(m.armour[CTORSO] <= 0.0 && m != me && m.alive){
		m.alive = 0;
		m.boom = BOOMFRAMES;
		m.fall = 0.0;
		score += 500;
		bigboom(m.x, m.z);
		if(lock >= 0 && foes[lock] == m)
			nexttarget();
	}
	if(tone != nil && mine)
		tone->sfx(2, 260, 60);
}

bigboom(x, z: real)
{
	if(tone != nil)
		tone->sfx(5, 120, 600);
}

# The other machines: close to a stand-off range, face you, and shoot.
stepfoe(f: ref Mech, idx: int)
{
	if(!f.alive){
		# Going down: legs fold, the torso pitches forward over them.
		if(f.boom > 0){
			f.boom--;
			f.fall = 1.0 - real f.boom / real BOOMFRAMES;
			if(f.fall > 1.0)
				f.fall = 1.0;
		}
		return;
	}
	f.heat -= COOLRATE;
	if(f.heat < 0.0)
		f.heat = 0.0;
	for(g := 0; g < NGROUP; g++)
		if(f.cool[g] > 0)
			f.cool[g]--;
	dx := me.x - f.x;
	dz := me.z - f.z;
	d := math->sqrt(dx*dx + dz*dz);
	want := math->atan2(dz, dx) / DEG;
	da := want - f.face;
	while(da > 180.0)
		da -= 360.0;
	while(da < -180.0)
		da += 360.0;
	if(da > TURN)
		f.face += TURN;
	else if(da < -TURN)
		f.face -= TURN;
	else
		f.face = want;
	# The torso covers what the legs have not turned yet.  Legs turn at
	# TURN a frame and this does not, so a machine that has just been
	# flanked twists to face you long before it has walked round - which
	# is the whole point of a torso that turns on its own, and it is
	# only visible on the machines, never on your own.
	tw := want - f.face;
	while(tw > 180.0)
		tw -= 360.0;
	while(tw < -180.0)
		tw += 360.0;
	if(tw > TWISTMAX)
		tw = TWISTMAX;
	if(tw < -TWISTMAX)
		tw = -TWISTMAX;
	f.twist += (tw - f.twist) * 0.25;
	# Stand off: close if far, back away if very close.  Expressed
	# against the range they will actually shoot at rather than as two
	# bare numbers, so the band cannot end up outside it.
	if(d > FARV*0.75)
		f.spd = WALK * 0.7;
	else if(d < FARV*0.4)
		f.spd = -WALK * 0.4;
	else
		f.spd = 0.0;
	f.x += f.spd * math->cos(f.face*DEG);
	f.z += f.spd * math->sin(f.face*DEG);
	# The stride is driven by ground covered, not by the clock, so a
	# machine that is standing still does not march on the spot and one
	# backing away steps backwards.
	f.phase += f.spd * STRIDERATE;
	while(f.phase >= 360.0)
		f.phase -= 360.0;
	while(f.phase < 0.0)
		f.phase += 360.0;
	if(--f.fire <= 0){
		f.fire = 70 + (idx * 13 + frames/7) % 60;
		if(d < FARV && absr(da) < 12.0){
			wg := LASER;
			if((frames/29 + idx) % 2 == 0)
				wg = CANNON;
			shoot(f, wg, 0);
		}
	}
}

absr(v: real): real
{
	if(v < 0.0)
		return -v;
	return v;
}

# --------------------------------------------------------------- render

fog(d: real): real
{
	t := 1.0 - d / FARV;
	if(t < 0.0)
		t = 0.0;
	if(t > 1.0)
		t = 1.0;
	return 0.5 + 0.5*t;
}

frame()
{
	if(ctx == nil || ctx.dst != target)
		ctx = d3->context(target);
	r := target.r;
	d3->resize(ctx, target);
	d3->viewport(ctx, r.min.x, r.min.y, r.max.x, r.max.y);
	d3->setzarea(ctx, r);
	vr = r;
	target.draw(r, csky, nil, (0,0));
	d3->clearz(ctx);
	d3->setz(ctx, 1);
	d3->mode(Draw3d->PROJ);
	d3->identity();
	w := real r.dx();
	h := real r.dy();
	sxs := 1.5;
	d3->frustumoffset(sxs, -sxs*w/h, 0.0);
	d3->mode(Draw3d->MODEL);
	d3->identity();
	# The camera is the cockpit: look where the torso points, from the
	# machine's own eye height.  Rotations first, so a vertex is moved
	# into the machine's frame and then turned into the eye's.
	d3->rotatey(aim(me) + 90.0);
	ey := height(me.x, me.z) + EYEY;
	d3->translate(-me.x, -ey, -me.z);
	ground();
	for(i := 0; i < NFOE; i++)
		if(foes[i] != nil && (foes[i].alive || foes[i].boom > 0))
			mech(foes[i], cfoe, cfoe2);
	drawshots();
	drawbeams();
	hud();
}

# The heightfield, as quads around the machine.  Only the samples near
# it are drawn; the rest is behind the fog anyway.
ground()
{
	gx := math->floor(me.x / GRID);
	gz := math->floor(me.z / GRID);
	# Cells the cockpit cannot see are dropped, and the test is
	# draw3d's own project() rather than trigonometry of this file's
	# own - which is the point.  A cull written from a separate idea of
	# where the camera points is a cull that can disagree with the
	# camera, and the first one here did: it kept exactly the cells the
	# camera was not looking at and the world came out empty.
	#
	# It is not only a saving.  A cell far off the view axis projects to
	# enormous screen coordinates, and that is what drives polyfill's
	# rational-z accumulator out of range - thousands of "bad ratzerr1"
	# lines a frame, a diagnostic that has been in fillpoly since Plan
	# 9.  gorge(1) never hit it because its corridor is always close to
	# the axis.  With this cull the count is zero.
	for(i := -nnear; i < nnear; i++){
		for(j := -nnear; j < nnear; j++){
			x0 := (gx + real i) * GRID;
			z0 := (gz + real j) * GRID;
			x1 := x0 + GRID;
			z1 := z0 + GRID;
			dx := x0 + GRID/2.0 - me.x;
			dz := z0 + GRID/2.0 - me.z;
			d := math->sqrt(dx*dx + dz*dz);
			if(d > FARV)
				continue;
			(sp, ez, ok) := d3->project(ctx,
				Vector(x0 + GRID/2.0,
					height(x0+GRID/2.0, z0+GRID/2.0),
					z0 + GRID/2.0));
			if(!ok || ez > -GRID)
				continue;
			# A cell one screen's width off is a cell whose corners
			# are already past the edge; the margin is generous
			# because a cell is wide and its centre is not its
			# nearest point.
			if(sp.x < vr.min.x - vr.dx() || sp.x > vr.max.x + vr.dx())
				continue;
			if(sp.y < vr.min.y - vr.dy() || sp.y > vr.max.y + vr.dy())
				continue;
			y00 := height(x0, z0);
			y10 := height(x1, z0);
			y11 := height(x1, z1);
			y01 := height(x0, z1);
			# a checker, so the ground has scale to it
			c := cgrnd;
			if(((int (gx + real i) + int (gz + real j)) & 1) != 0)
				c = cgrnd2;
			if((y00 + y11) * 0.5 > 7.0)
				c = chill;
			d3->setcolour(ctx, c);
			qv[0] = Vector(x0, y00, z0);
			qv[1] = Vector(x1, y10, z0);
			qv[2] = Vector(x1, y11, z1);
			qv[3] = Vector(x0, y01, z1);
			f := fog(d);
			# a cheap slope shade: higher corners catch more light
			ql[0] = f * lightof(y00);
			ql[1] = f * lightof(y10);
			ql[2] = f * lightof(y11);
			ql[3] = f * lightof(y01);
			d3->fillpoly3g(ctx, qv, ql);
		}
	}
}

lightof(y: real): real
{
	l := 0.8 + y * 0.03;
	if(l < 0.55)
		l = 0.55;
	if(l > 1.0)
		l = 1.0;
	return l;
}

# A machine: legs, a torso, two arms.  Boxes, because that is what these
# things look like from the outside and because a box is four quads.
mech(m: ref Mech, c1, c2: ref Image)
{
	base := height(m.x, m.z);
	dx := m.x - me.x;
	dz := m.z - me.z;
	(nil, ez, ok) := d3->project(ctx, Vector(m.x, base + 6.0, m.z));
	if(!ok || ez > -3.0)
		return;			# behind the cockpit
	f := fog(math->sqrt(dx*dx + dz*dz));
	# Two frames, not one: the legs stand in the machine's own heading
	# and everything above the hips stands in the heading plus the
	# torso twist.  That is what makes a machine walking one way and
	# aiming another look like one, and it costs two more cosines.
	ca := math->cos(m.face*DEG);
	sa := math->sin(m.face*DEG);
	tb := (m.face + m.twist) * DEG;
	cb := math->cos(tb);
	sb := math->sin(tb);

	# The stride.  One sine drives the whole gait: the legs swing
	# against each other, the leading foot lifts, the hips drop at mid
	# stride when both feet are down, and the arms swing against the
	# legs.  Nothing here is a keyframe.
	ph := m.phase * DEG;
	sw := math->sin(ph);
	lfoot := 0.0;
	rfoot := 0.0;
	if(sw > 0.0)
		lfoot = LIFT * sw;
	else
		rfoot = -LIFT * sw;
	bob := -BOB * absr(sw);

	# And the topple, once it is dead: the legs fold under it and the
	# torso pitches forward over them.
	fl := m.fall;
	legh := 7.0 * (1.0 - fl*0.85);
	hip := base + legh + bob*(1.0 - fl);
	pitch := 7.0 * fl;			# how far forward the torso goes
	drop := 3.4 * fl;

	d3->setcolour(ctx, c2);
	box(m.x, base + lfoot, m.z, ca, sa, 1.3, legh, 1.5,
		-2.0, STRIDE*sw*(1.0-fl), f*0.85);
	box(m.x, base + rfoot, m.z, ca, sa, 1.3, legh, 1.5,
		2.0, -STRIDE*sw*(1.0-fl), f*0.85);
	d3->setcolour(ctx, c1);
	box(m.x, hip - drop, m.z, cb, sb, 3.0, 4.6, 2.2, 0.0, pitch, f);
	d3->setcolour(ctx, c2);
	box(m.x, hip + 0.4 - drop, m.z, cb, sb, 1.0, 3.8, 1.0,
		-3.8, pitch - ARMSW*sw*(1.0-fl), f*0.9);
	box(m.x, hip + 0.4 - drop, m.z, cb, sb, 1.0, 3.8, 1.0,
		3.8, pitch + ARMSW*sw*(1.0-fl), f*0.9);
	d3->setcolour(ctx, c1);
	box(m.x, hip + 4.6 - drop*1.6, m.z, cb, sb, 1.6, 1.5, 1.4,
		0.0, 0.5 + pitch*1.25, f*1.15);
}

# One box, in the machine's own frame: hw/hh/hd are half extents, ox is
# across it and oz along it.
box(x, y, z, ca, sa, hw, hh, hdp, ox, oz, lv: real)
{
	# the four corners in plan, rotated into the world
	cx := x + (ox*(-sa) + oz*ca);
	cz := z + (ox*ca + oz*sa);
	ux := -sa*hw;
	uz := ca*hw;
	vx := ca*hdp;
	vz := sa*hdp;
	y0 := y;
	y1 := y + hh;
	# front, back, left, right - the top is only visible from a hill
	quadface(cx-ux-vx, cz-uz-vz, cx+ux-vx, cz+uz-vz, y0, y1, lv*1.0);
	quadface(cx+ux+vx, cz+uz+vz, cx-ux+vx, cz-uz+vz, y0, y1, lv*0.7);
	quadface(cx-ux+vx, cz-uz+vz, cx-ux-vx, cz-uz-vz, y0, y1, lv*0.88);
	quadface(cx+ux-vx, cz+uz-vz, cx+ux+vx, cz+uz+vz, y0, y1, lv*0.8);
}

quadface(ax, az, bx, bz, y0, y1, lv: real)
{
	qv[0] = Vector(ax, y0, az);
	qv[1] = Vector(bx, y0, bz);
	qv[2] = Vector(bx, y1, bz);
	qv[3] = Vector(ax, y1, az);
	ql[0] = lv*0.78;
	ql[1] = lv*0.78;
	ql[2] = lv;
	ql[3] = lv;
	d3->fillpoly3g(ctx, qv, ql);
}

drawshots()
{
	for(i := 0; i < NSHOT; i++){
		s := shots[i];
		if(s == nil || !s.live)
			continue;
		if(s.mine)
			d3->setcolour(ctx, cshell);
		else
			d3->setcolour(ctx, cbeam);
		streak(s.x, s.y, s.z, s.x - s.vx*0.9, s.y - s.vy*0.9,
			s.z - s.vz*0.9, 0.35);
	}
}

drawbeams()
{
	for(i := 0; i < NBEAM; i++){
		b := beams[i];
		if(b == nil || b.t <= 0)
			continue;
		if(b.mine)
			d3->setcolour(ctx, cgreen);
		else
			d3->setcolour(ctx, cbeam);
		streak(b.ax, b.ay, b.az, b.bx, b.by, b.bz, 0.22);
	}
}

# A shot or a beam, as a thin upright quad rather than line3.  line3
# with the depth buffer on drives polyfill's rational-z accumulator out
# of range on this scene and it says so, thousands of times a frame -
# "bad ratzerr1", a diagnostic that has been in fillpoly since Plan 9.
# The geometry path does not do it, so the geometry path is what these
# use.  The underlying fault is not fixed here and is not this game's.
streak(ax, ay, az, bx, by, bz, w: real)
{
	qv[0] = Vector(ax, ay - w, az);
	qv[1] = Vector(bx, by - w, bz);
	qv[2] = Vector(bx, by + w, bz);
	qv[3] = Vector(ax, ay + w, az);
	ql[0] = 1.0;
	ql[1] = 0.55;
	ql[2] = 0.55;
	ql[3] = 1.0;
	d3->fillpoly3g(ctx, qv, ql);
}

# ------------------------------------------------------------------ hud
#
# Everything here is 2-D over the 3-D, with the depth test off: a head-up
# display that the terrain could occlude would be no use at all.

hud()
{
	d3->setz(ctx, 0);
	r := target.r;
	x0 := r.min.x;
	y0 := r.min.y;
	w := r.dx();
	h := r.dy();
	if(font == nil)
		return;
	fh := font.height;

	# heat: the scale that decides whether the machine keeps working
	bar(x0+12, y0+h-30, 160, 12, me.heat/MAXHEAT, heatcolour());
	target.text(Point(x0+12, y0+h-30-fh), cwhite, (0,0), font,
		sys->sprint("HEAT %3d", int me.heat));
	if(me.down > 0)
		target.text(Point(x0+w/2-56, y0+h/2-fh), cred, (0,0), font,
			"SHUTDOWN - OVERHEAT");

	# throttle
	bar(x0+12, y0+h-52, 160, 8, (me.throt+0.5)/1.5, cgreen);
	target.text(Point(x0+180, y0+h-54), cwhite, (0,0), font,
		sys->sprint("THROTTLE %3d%%", int (me.throt*100.0)));

	# the weapon groups, with the selected one named
	gx := x0 + 12;
	gy := y0 + 12;
	for(g := 0; g < NGROUP; g++){
		c := cwhite;
		if(g == group)
			c = camber;
		s := GNAME[g];
		if(me.ammo[g] >= 0)
			s += sys->sprint(" %d", me.ammo[g]);
		if(me.cool[g] > 0)
			c = cmech2;
		target.text(Point(gx, gy + g*fh), c, (0,0), font, s);
	}

	# armour, as the machine's own outline rather than a number
	diagram(x0 + w - 96, y0 + 12);

	# what is being aimed at
	if(lock >= 0 && foes[lock] != nil && foes[lock].alive){
		f := foes[lock];
		dx := f.x - me.x;
		dz := f.z - me.z;
		d := math->sqrt(dx*dx + dz*dz);
		target.text(Point(x0+w/2-70, y0+12), camber, (0,0), font,
			sys->sprint("TARGET %d   %4d M   CT %3d",
				lock+1, int d, int f.armour[CTORSO]));
		reticle(f);
	}
	radar(x0 + w - 60, y0 + h - 60, 48);
	target.text(Point(x0+12, y0+h-70), cwhite, (0,0), font,
		sys->sprint("SCORE %d", score));
	why := "gpu (mis-composed, see gorge(1) BUGS)";
	if(provider == Draw3d->PATH)
		why = "software";
	target.text(Point(x0+12, y0+h-14), cmech2, (0,0), font, why);
	if(over > 0){
		msg := "DESTROYED";
		c := cred;
		if(me.armour[CTORSO] > 0.0){
			msg = "ALL TARGETS DOWN";
			c = cgreen;
		}
		target.text(Point(x0+w/2-60, y0+h/2), c, (0,0), font, msg);
	}
}

heatcolour(): ref Image
{
	if(me.heat > MAXHEAT*0.8)
		return cred;
	if(me.heat > MAXHEAT*0.5)
		return camber;
	return cgreen;
}

bar(x, y, w, h: int, v: real, c: ref Image)
{
	if(v < 0.0)
		v = 0.0;
	if(v > 1.0)
		v = 1.0;
	target.draw(Rect((x-1,y-1),(x+w+1,y+h+1)), cdark, nil, (0,0));
	n := int (real w * v);
	if(n > 0)
		target.draw(Rect((x,y),(x+n,y+h)), c, nil, (0,0));
}

# The armour diagram: six boxes in the shape of the machine, each shaded
# by how much of that section is left.  A number would say the same
# thing and would not be readable at a glance, which is the point.
SECTW := array[NSECT] of {14, 18, 22, 18, 14, 40};
SECTH := array[NSECT] of {26, 30, 34, 30, 26, 20};
FULL := array[NSECT] of {60.0, 80.0, 130.0, 80.0, 60.0, 90.0};

diagram(x, y: int)
{
	xs := array[NSECT] of {0, 16, 36, 60, 80, 24};
	ys := array[NSECT] of {6, 2, 0, 2, 6, 36};
	for(i := 0; i < NSECT; i++){
		f := me.armour[i] / FULL[i];
		c := cgreen;
		if(f < 0.55)
			c = camber;
		if(f < 0.25)
			c = cred;
		if(f <= 0.0)
			c = cdark;
		target.draw(Rect((x+xs[i], y+ys[i]),
			(x+xs[i]+SECTW[i], y+ys[i]+SECTH[i])), cdark, nil, (0,0));
		hh := int (real SECTH[i] * f);
		if(hh > 0)
			target.draw(Rect((x+xs[i]+1, y+ys[i]+SECTH[i]-hh),
				(x+xs[i]+SECTW[i]-1, y+ys[i]+SECTH[i])),
				c, nil, (0,0));
	}
}

# A box round the target, put where the 3-D says it is rather than
# guessed: project() is the same transform the geometry went through.
reticle(f: ref Mech)
{
	(p, ez, ok) := d3->project(ctx, Vector(f.x, height(f.x, f.z) + 7.0, f.z));
	if(!ok || ez >= 0.0)
		return;
	s := int (260.0 / -ez);
	if(s < 6)
		s = 6;
	if(s > 90)
		s = 90;
	corner(p.x - s, p.y - s, 1, 1);
	corner(p.x + s, p.y - s, -1, 1);
	corner(p.x - s, p.y + s, 1, -1);
	corner(p.x + s, p.y + s, -1, -1);
}

corner(x, y, dx, dy: int)
{
	n := 7;
	target.draw(Rect((x, y), (x + dx*n, y+1)), camber, nil, (0,0));
	target.draw(Rect((x, y), (x+1, y + dy*n)), camber, nil, (0,0));
}

# Contacts in plan, turned so that up on the display is where the torso
# points - which is what a pilot needs and is not the same as north.
radar(cx, cy, rad: int)
{
	target.draw(Rect((cx-rad, cy-rad), (cx+rad, cy+rad)), cdark, nil, (0,0));
	a := aim(me) * DEG;
	ca := math->cos(a);
	sa := math->sin(a);
	for(i := 0; i < NFOE; i++){
		f := foes[i];
		if(f == nil || !f.alive)
			continue;
		dx := f.x - me.x;
		dz := f.z - me.z;
		# into the torso's frame
		fx := dx*ca + dz*sa;
		fz := -dx*sa + dz*ca;
		sc := real rad / 260.0;
		px := cx + int (fz*sc);
		py := cy - int (fx*sc);
		if(px < cx-rad || px > cx+rad || py < cy-rad || py > cy+rad)
			continue;
		c := cred;
		if(i == lock)
			c = camber;
		target.draw(Rect((px-2, py-2), (px+3, py+3)), c, nil, (0,0));
	}
	target.draw(Rect((cx-1, cy-1), (cx+2, cy+2)), cgreen, nil, (0,0));
}

# ---------------------------------------------------------------- bench

bench()
{
			audio = 0;
	win.reshape(Rect((0,0),(WIDE,HIGH)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	target = win.image;
	ctx = d3->context(target);
	newgame();
	benchrun(20);
	newgame();
	us := benchrun(nbench);
	fd := sys->fildes(2);
	f2 := sys->create("/strider.bench", Sys->OWRITE, 8r666);
	msg := sys->sprint("strider: %s\n%d frames, %d ground quads: %d us a frame\n",
		provider, nbench, nnear*nnear*4, us);
	if(f2 != nil)
		sys->fprint(f2, "%s", msg);
	sys->fprint(fd, "%s", msg);
	if(us > 16666)
		sys->fprint(fd, "strider: SLOWER THAN 60Hz\n");
}

benchrun(n: int): int
{
	t0 := sys->millisec();
	for(i := 0; i < n; i++){
		pad = KUP;
		step();
		target = win.image;
		frame();
		target.flush(Draw->Flushnow);
	}
	return (sys->millisec() - t0) * 1000 / n;
}

shot()
{
			audio = 0;
	newgame();
	ctx = d3->context(target);
	lock = 0;
	me.throt = 0.6;
	# The other machines start a long way out, further than the terrain
	# is drawn, so a screenshot of the opening shows an empty valley.
	# Bring two of them to where a pilot would first see them.
	a := me.face * DEG;
	foes[0].x = me.x + 30.0 * math->cos(a);
	foes[0].z = me.z + 30.0 * math->sin(a);
	foes[1].x = me.x + 72.0 * math->cos(a) - 22.0 * math->sin(a);
	foes[1].z = me.z + 72.0 * math->sin(a) + 22.0 * math->cos(a);
	# Twist the torso out and back, so the run exercises it and the
	# frame that gets written is still looking at the target.  There is
	# no auto-centre: the twist stays where it was left.
	for(i := 0; i < 56; i++){
		pad = 0;
		if(i > 8 && i < 24)
			pad = KB;
		else if(i >= 28 && i < 44)
			pad = KSEL;
		step();
		if((i % 10) == 0 || i == 119)
			frame();
	}
	shoot(me, LASER, 1);
	frame();
	w := target.r.dx();
	h := target.r.dy();
	bpp := target.depth / 8;
	b := array[w*h*bpp] of byte;
	if(target.readpixels(target.r, b) < 0){
		sys->print("readpixels: %r\n");
		return;
	}
	fd := sys->create("strider.raw", Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->print("create: %r\n");
		return;
	}
	sys->write(fd, b, len b);
	sys->print("wrote strider.raw %dx%d %d bytes a pixel\n", w, h, bpp);
}

# ----------------------------------------------------------------- test

nfail := 0;
DRAWEVERY:	con 10;

ck(what: string, got, want: int)
{
	if(got == want){
		sys->print("ok   %s = %d\n", what, got);
		return;
	}
	sys->print("FAIL %s = %d, want %d\n", what, got, want);
	nfail++;
}

cktrue(what: string, v: int)
{
	if(v){
		sys->print("ok   %s\n", what);
		return;
	}
	sys->print("FAIL %s\n", what);
	nfail++;
}

run(n: int, held: int)
{
	for(i := 0; i < n; i++){
		pad = held;
		step();
		if((i % DRAWEVERY) == 0)
			frame();
	}
}

selftest()
{
	sys->print("strider: self test\n");
			audio = 0;
	ctx = d3->context(target);
	newgame();

	# The ground is a function, so it can be checked without drawing it.
	rough := 0;
	for(i := 0; i < 3000; i++){
		x := real i * 3.7;
		z := real i * -2.3;
		if(absr(height(x, z) - height(x + 1.0, z)) > 1.0)
			rough++;
	}
	ck("the ground never steps", rough, 0);

	# Throttle, not speed: a machine this size takes time to get going
	# and time to stop, and that is the point of having a throttle.
	newgame();
	me.throt = 1.0;
	run(3, 0);
	v3 := me.spd;
	run(60, 0);
	cktrue("it takes time to get up to speed", me.spd > v3);
	cktrue("and stops at the throttle setting", me.spd <= WALK + 0.001);
	x0 := me.x;
	run(60, 0);
	cktrue("walking moves it", absr(me.x - x0) + absr(me.z) > 5.0);
	me.throt = 0.0;
	run(200, 0);
	cktrue("throttle zero stops it", absr(me.spd) < 0.01);

	# The torso turns independently of the legs, and only so far.
	newgame();
	f0 := me.face;
	run(20, KB);
	cktrue("the torso twists", me.twist < 0.0);
	ck("and the legs do not follow", int me.face, int f0);
	cktrue("aim is legs plus twist",
		int (aim(me)*10.0) == int ((me.face + me.twist)*10.0));
	run(200, KB);
	cktrue("the twist stops at its limit", me.twist >= -TWISTMAX - 0.001);
	run(400, KSEL);
	cktrue("and at the other one", me.twist <= TWISTMAX + 0.001);
	newgame();
	run(30, KRIGHT);
	cktrue("the legs turn", me.face > 0.0);
	ck("and the torso stays put", int (me.twist*100.0), 0);

	# Heat: firing builds it, it sheds on its own, and enough of it
	# shuts the machine down.
	newgame();
	h0 := me.heat;
	prevpad = 0;
	run(1, KA);
	cktrue("firing makes heat", me.heat > h0);
	hh := me.heat;
	run(60, 0);
	cktrue("and heat sheds", me.heat < hh);
	# Heat is shed at the top of the step, so a machine set to exactly
	# full heat is under it again by the time anything looks - set it
	# above what one frame sheds.
	newgame();
	me.heat = MAXHEAT + COOLRATE + 1.0;
	run(1, 0);
	cktrue("full heat shuts it down", me.down > 0);
	d0 := me.down;
	run(5, KUP);
	ck("a shut down machine ignores the throttle", int (me.spd*100.0), 0);
	cktrue("and the shutdown counts down", me.down < d0);
	run(SHUTDOWN + 5, 0);
	ck("then it comes back", me.down, 0);
	cktrue("at half heat", me.heat < MAXHEAT*0.6);

	# Weapon groups: their own cooldowns and their own ammunition.
	newgame();
	group = CANNON;
	a0 := me.ammo[CANNON];
	prevpad = 0;
	run(1, KA);
	ck("firing spends a round", me.ammo[CANNON], a0-1);
	run(2, KA);
	ck("and the cooldown holds it", me.ammo[CANNON], a0-1);
	run(COOL[CANNON] + 2, KA);
	cktrue("until it expires", me.ammo[CANNON] < a0-1);
	ck("a laser has no ammunition to spend", me.ammo[LASER], -1);
	newgame();
	group = MISSILE;
	me.ammo[MISSILE] = 0;
	prevpad = 0;
	run(1, KA);
	n := 0;
	for(i = 0; i < NSHOT; i++)
		if(shots[i] != nil && shots[i].live)
			n++;
	ck("an empty group fires nothing", n, 0);

	# A salvo is a salvo.
	newgame();
	group = MISSILE;
	prevpad = 0;
	run(1, KA);
	n = 0;
	for(i = 0; i < NSHOT; i++)
		if(shots[i] != nil && shots[i].live)
			n++;
	ck("a missile group fires a salvo", n, SALVO[MISSILE]);

	# The laser arrives the frame it is fired, and takes armour off
	# whatever it meets.
	newgame();
	f := foes[0];
	f.x = me.x + 40.0;
	f.z = me.z;
	me.face = 0.0;
	me.twist = 0.0;
	tot0 := armourof(f);
	shoot(me, LASER, 1);
	cktrue("a laser takes armour off the target", armourof(f) < tot0);
	nb := 0;
	for(i = 0; i < NBEAM; i++)
		if(beams[i] != nil && beams[i].t > 0)
			nb++;
	cktrue("and leaves a beam to draw", nb > 0);
	# and misses what it is not pointed at
	newgame();
	f = foes[0];
	f.x = me.x + 40.0;
	f.z = me.z;
	me.face = 180.0;
	tot0 = armourof(f);
	shoot(me, LASER, 1);
	ck("and misses when it is pointed away",
		int armourof(f), int tot0);

	# Destroying the centre torso destroys the machine, and nothing else
	# does.
	newgame();
	f = foes[0];
	f.armour[LARM] = 0.0;
	f.armour[RARM] = 0.0;
	f.armour[LEGS] = 0.0;
	run(1, 0);
	cktrue("a machine with no arms or legs is still up", f.alive);
	s0 := score;
	f.armour[CTORSO] = 1.0;
	damage(f, 50.0, 1);
	# damage picks a section, so hit it until the centre is gone
	for(i = 0; i < 40 && f.alive; i++)
		damage(f, 40.0, 1);
	cktrue("a destroyed centre torso destroys it", !f.alive);
	cktrue("and it scores", score > s0);

	# Targeting cycles only the ones still standing.
	newgame();
	nexttarget();
	l0 := lock;
	cktrue("a target is picked", l0 >= 0);
	nexttarget();
	cktrue("and cycles", lock != l0);
	for(i = 0; i < NFOE; i++)
		foes[i].alive = 0;
	nexttarget();
	ck("with none left there is no target", lock, -1);

	# The other machines close, turn to face, and shoot back.
	newgame();
	f = foes[0];
	d0 = int dist(f);
	run(300, 0);
	cktrue("they close the range", int dist(f) < d0);
	# Enough centre torso to survive being shot at for a while, then
	# watch for the total dropping AT ALL rather than by a made-up
	# amount: how much they hit for in a given number of frames is not
	# the thing being checked.
	newgame();
	me.armour[CTORSO] = 4000.0;
	atot := armourof(me);
	hit := 0;
	for(i = 0; i < 2000 && !hit; i++){
		run(1, 0);
		if(armourof(me) < atot)
			hit = 1;
	}
	if(!hit){
		f2 := foes[0];
		dx2 := me.x - f2.x;
		dz2 := me.z - f2.z;
		sys->print("  trace: d=%d face=%d alive=%d fire=%d heat=%d down=%d\n",
			int math->sqrt(dx2*dx2+dz2*dz2), int f2.face, f2.alive,
			f2.fire, int f2.heat, f2.down);
	}
	cktrue("and they shoot back", hit);

	# Losing the centre torso ends it.
	newgame();
	me.armour[CTORSO] = 0.0;
	run(1, 0);
	cktrue("no centre torso ends the sortie", over > 0);

	frame();
	cktrue("a frame draws something", lit() > 20000);

	# And an enemy in front must actually put pixels on the screen.
	# Nothing above this line does: every other check asks about state,
	# and an `if(0)` left in front of the loop that draws the other
	# machines hid all of them for a whole commit while all 38 passed.
	# A game's test that never looks at the picture cannot see that.
	newgame();
	me.face = 0.0;
	me.twist = 0.0;
	for(i = 0; i < NFOE; i++)
		foes[i].alive = 0;
	frame();
	bare := lit();
	foes[0].alive = 1;
	foes[0].x = me.x + 40.0;
	foes[0].z = me.z;
	frame();
	withfoe := lit();
	cktrue("an enemy in front is drawn", withfoe > bare + 2000);
	# and one behind the cockpit is not
	foes[0].x = me.x - 40.0;
	frame();
	cktrue("and one behind the cockpit is not", lit() <= bare + 200);

	# The gait.  Two things to establish and they are different: that
	# the stride advances with ground covered, and that it reaches the
	# SCREEN.  The second is the one a state check cannot make.
	# Setting spd to zero does not make a machine stand still: stepfoe
	# sets it every frame from the stand-off logic.  Put it in the band
	# where that logic holds instead, which is the machine deciding to
	# stand still rather than the test pretending it has.
	newgame();
	fo := foes[0];
	fo.x = me.x + FARV*0.55;
	fo.z = me.z;
	fo.face = 180.0;
	run(5, 0);
	p0 := fo.phase;
	run(30, 0);
	ck("standing still does not march on the spot",
		int (fo.phase*10.0), int (p0*10.0));
	fo.x = me.x + FARV*1.5;
	run(30, 0);
	cktrue("walking advances the stride", fo.phase != p0);
	moved := 0;
	for(i = 0; i < 400; i++){
		run(1, 0);
		if(fo.phase < 0.0 || fo.phase >= 360.0)
			moved++;
	}
	ck("and the stride stays in range", moved, 0);

	newgame();
	me.face = 0.0;
	me.twist = 0.0;
	for(i = 0; i < NFOE; i++)
		foes[i].alive = 0;
	foes[0].alive = 1;
	foes[0].x = me.x + 34.0;
	foes[0].z = me.z;
	foes[0].spd = 0.0;
	foes[0].phase = 0.0;
	frame();
	a := framesum();
	foes[0].phase = 90.0;
	frame();
	b := framesum();
	foes[0].phase = 270.0;
	frame();
	c := framesum();
	cktrue("the stride changes the picture", a != b && b != c && a != c);

	# And a machine that is destroyed goes down over several frames
	# rather than vanishing, and is still drawn while it does.
	# One kept alive a long way off, or destroying the last machine ends
	# the sortie and step() takes its early return - so nothing would
	# advance the fall being measured.
	newgame();
	me.face = 0.0;
	me.twist = 0.0;
	for(i = 2; i < NFOE; i++)
		foes[i].alive = 0;
	foes[1].x = me.x + 4000.0;
	foes[1].z = me.z;
	fo = foes[0];
	fo.alive = 1;
	fo.x = me.x + 34.0;
	fo.z = me.z;
	for(i = 0; i < 60 && fo.alive; i++)
		damage(fo, 40.0, 1);
	cktrue("it is destroyed", !fo.alive);
	ck("and starts upright", int (fo.fall*100.0), 0);
	frame();
	falling := lit();
	run(BOOMFRAMES/2, 0);
	cktrue("the fall progresses", fo.fall > 0.3 && fo.fall < 0.9);
	frame();
	cktrue("and it is still on the screen while it falls",
		lit() > bare + 1000);
	run(BOOMFRAMES, 0);
	cktrue("then it is flat", fo.fall >= 0.99);
	if(falling < 0)
		nfail++;

	if(nfail == 0)
		sys->print("strider: PASSED\n");
	else{
		sys->print("strider: FAILED (%d)\n", nfail);
		raise "fail:test";
	}
}

dist(f: ref Mech): real
{
	dx := f.x - me.x;
	dz := f.z - me.z;
	return math->sqrt(dx*dx + dz*dz);
}

armourof(m: ref Mech): real
{
	t := 0.0;
	for(i := 0; i < NSECT; i++)
		t += m.armour[i];
	return t;
}

# A cheap hash of the whole frame, for asking whether two frames differ
# at all.  Counting lit pixels cannot answer that: a leg that has swung
# forward lights exactly as many pixels as one that has not.
framesum(): int
{
	w := target.r.dx();
	h := target.r.dy();
	bpp := target.depth / 8;
	b := array[w*h*bpp] of byte;
	if(target.readpixels(target.r, b) < 0)
		return -1;
	sum := 0;
	for(i := 0; i < w*h*bpp; i += 7)
		sum = (sum * 31 + int b[i]) & 16r3FFFFFFF;
	return sum;
}

lit(): int
{
	w := target.r.dx();
	h := target.r.dy();
	bpp := target.depth / 8;
	b := array[w*h*bpp] of byte;
	if(target.readpixels(target.r, b) < 0)
		return -1;
	# The sky is whatever the frame was cleared to, read from a corner,
	# NOT a colour written down here.  It was written down here, and
	# when the sky colour changed this silently began counting every
	# pixel in the window - so "a frame draws something" was true of a
	# frame that drew nothing.
	sk0 := b[0];
	sk1 := b[1];
	sk2 := b[2];
	n := 0;
	for(i := 0; i < w*h; i++)
		if(b[i*bpp] != sk0 || b[i*bpp+1] != sk1 || b[i*bpp+2] != sk2)
			n++;
	return n;
}
