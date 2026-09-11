implement Gorge;

# Gorge - fly a canyon, dodge what stands in it, shoot what you can.
#
# The four games beside this one are 8-bit in shape: tiles(2) composites
# tiles once at the destination's scale and every frame is blits.  That
# is deliberate, and it is also the thing doc/draw3d-adoption-plan.md
# names as getting no GPU at all, because it composes into an offscreen
# surface and blits the result.
#
# This one is the other half of the argument.  It has no tiles and no
# palette: the canyon is real geometry, lit per vertex, handed to
# draw3d(2)'s fillpoly3g STRAIGHT INTO THE WINDOW IMAGE through the
# /dev/draw provider, which is the only arrangement emu's Metal backend
# will take.  Colour is whatever Display.rgb gives.
#
# What that buys, and what it costs, is measured rather than asserted:
# see -b, and DIAGNOSTICS in gorge(1).  The short version is that it
# reaches the GPU only when there is no window manager between the
# program and the screen - see BUGS, because that is a finding about the
# tree and not about this game.

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

Gorge: module
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

NSEG:	con 44;			# corridor segments drawn ahead, playing
SEGLEN:	con 6.0;		# world units between them
FLOORY:	con -3.5;
ROOFY:	con 4.5;
FAR:	con real NSEG * SEGLEN;

# How many are actually drawn.  Playing draws them all.  The headless
# modes draw a short canyon, because they render with the software
# provider and that provider subdivides every Gouraud face four ways to
# a fixed depth and asks Display.rgb for a fresh colour image at each
# leaf's average brightness - thousands of image allocations a frame,
# which exhausts the pool long before the test finishes.  Shortening the
# canyon is the difference between a test that runs and one that does
# not; it changes nothing about the rules being checked.
nseg := NSEG;

SHIPZ:	con -7.0;		# where the ship sits ahead of the eye
SHIPVX:	con 0.34;
SHIPVY:	con 0.26;

NPYL:	con 14;
NBOLT:	con 12;
NBOOM:	con 8;

Pylon: adt {
	k:	int;		# spine index it stands at
	off:	real;		# across the corridor, -1..1
	h:	real;		# height above the floor
	live:	int;
};

Bolt: adt {
	x, y, z:	real;
	live:	int;
};

Boom: adt {
	x, y, z:	real;
	t:	int;
	live:	int;
};

# Scratch for the fills.  A frame draws about three hundred faces and
# every one of them used to allocate its own vertex and lighting arrays;
# at sixty frames a second that is enough garbage to exhaust the heap in
# a long run, which is how the self test found it.  fillpoly3g reads
# these and keeps nothing, so one set is enough.
qv := array[4] of Vector;
ql := array[4] of real;
tv := array[3] of Vector;
tlit := array[3] of real;

win: ref Window;
disp: ref Display;
d3: Draw3d;
ctx: ref Draw3d->Context;
font: ref Font;
target: ref Image;		# what the 3D goes into: the window, or memory

cfloor, cwallL, cwallR, cpylon, cpyltop, cship, cshipfin, cbolt, cwhite,
	cred, csky: ref Image;
boomimg, boommask: ref Image;

# The ship, and the world sliding past it.
sx, sy: real;
speed: real;
base := 0;			# spine index at the eye
frac := 0.0;			# how far into that segment
dist := 0.0;			# total flown, for the score
lives := 3;
score := 0;
best := 0;
frames := 0;
dead := 0;
firecool := 0;
pylons: array of ref Pylon;
bolts: array of ref Bolt;
booms: array of ref Boom;
pad := 0;
prevpad := 0;
audio := 0;
mode := 0;			# 0 play, 1 selftest, 2 bench
provider := "/dis/math/draw3ddev.dis";
forced: string;
underwm := 0;
wantdev := 0;

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
		"-g" =>	mode = 4;
		"-q" =>	audio = -1;
		"-S" =>	forced = Draw3d->PATH;
		"-D" =>	wantdev = 1;
			forced = "/dis/math/draw3ddev.dis";
		"-n" =>	if(tl a != nil){
				a = tl a;
				nbench = int hd a;
			}
		}
	}
	# -t and -s render with the SOFTWARE provider, and they need a
	# bigger heap than emu's default to do it - see DIAGNOSTICS in
	# gorge(1).  That provider approximates a per-vertex fill by
	# subdividing each triangle four ways to a fixed depth and
	# flat-filling the leaves, allocating as it goes; this canyon is a
	# fog ramp across every face, so nothing terminates early and a
	# frame becomes tens of thousands of small allocations.  Playing
	# does not pay that: the /dev/draw provider hands the face to
	# devdraw, which interpolates it in C.  -D asks for that provider
	# headless anyway.
	if((mode == 1 || mode == 3) && !wantdev)
		provider = Draw3d->PATH;
	# Which provider.
	#
	# The /dev/draw one reaches the GPU and is about seventeen times
	# faster on this scene: 3433 us a frame against 58225.  It also used
	# to draw the wrong picture, and no longer does - three faults, all
	# in emu and none in this file:
	#
	#	a polygon straddling the eye plane was handed to the GPU,
	#	  where w <= 0 wraps and it paints an enormous wrong face.
	#	  gorge flies a canyon THROUGH the eye every frame, so this
	#	  was most of the picture.  devdraw declines those now and
	#	  the CPU takes them, as the software provider does.
	#	the geometry queue was consumed by presentation, which does
	#	  not write the softscreen back, so whether a frame's 3D
	#	  reached the image anything else reads was a race.
	#	the readback composed geometry OVER the 2-D instead of under
	#	  it, which is where the head-up display went.
	#
	# It is still not the default here, because what has been checked is
	# headless: under a window manager this provider used to panic emu
	# ("pushrun addrun"), that panic was an unbalanced error stack in
	# devdraw's own fallback and is fixed, but nobody has run it under
	# wm since.  -D asks for it; see gorge(1).
	#
	provider = Draw3d->PATH;
	if(mode == 0 || mode == 2)
		underwm = ctxt != nil;
	if(forced != nil)
		provider = forced;
	d3 = load Draw3d provider;
	if(d3 == nil && provider != Draw3d->PATH){
		provider = Draw3d->PATH;
		d3 = load Draw3d provider;
	}
	if(d3 == nil){
		sys->fprint(sys->fildes(2), "gorge: cannot load draw3d: %r\n");
		raise "fail:load";
	}
	d3->init();
	if(fclock != nil)
		fclock->init();

	if(mode == 1 || mode == 3){
		nseg = 10;
		disp = Display.allocate(nil);
		if(disp == nil){
			sys->fprint(sys->fildes(2), "gorge: no display: %r\n");
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
		win = wmclient->window(ctxt, "Gorge", Wmclient->Appl);
		disp = win.display;
	}
	colours();
	makeboom();
	font = Font.open(disp, "/fonts/lucidasans/unicode.8.font");
	if(font == nil)
		font = Font.open(disp, "*default*");
	if(scorestore != nil)
		best = scorestore->loadint("gorge", 0);
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
	4 =>	gpushot();
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
				scorestore->saveint("gorge", score);
			if(fclock != nil)
				fclock->report("gorge");
			exit;
		}
		pad = kb.key(pad, k);
	<-ticks =>
		step();
		target = win.image;
		frame();
		target.flush(Draw->Flushnow);
	}
}

# Full 24-bit colour, no palette and nothing quantised: this is the
# point of the file.
#
# NOT Display.rgb, though, and that is worth writing down.  rgb() hands
# back a depth-24 r8g8b8 image, and draw3d's litcolour() - the thing
# that turns a per-vertex lit into an actual shade on the software path
# - tints only a depth-32 colour and returns anything else UNCHANGED.
# So a scene lit with rgb() colours comes out completely flat, with no
# error and no clue: the first version of this file did, and the fog
# ramp down the canyon simply was not there.  A replicated one-pixel
# image in the display's own channels is depth 32 and does get shaded.
# chprobe(1) is the two-line demonstration.
rgb32(r, g, b: int): ref Image
{
	return disp.newimage(Rect((0,0),(1,1)), disp.image.chans, 1,
		(r<<24) | (g<<16) | (b<<8) | 16rFF);
}

colours()
{
	cfloor = rgb32(96, 74, 58);
	cwallL = rgb32(140, 96, 70);
	cwallR = rgb32(112, 78, 58);
	cpylon = rgb32(70, 150, 190);
	cpyltop = rgb32(150, 220, 245);
	cship = rgb32(210, 225, 240);
	cshipfin = rgb32(90, 160, 230);
	cbolt = rgb32(255, 240, 120);
	cwhite = rgb32(255, 255, 255);
	cred = rgb32(240, 90, 60);
	csky = rgb32(16, 18, 34);
}

# The explosion is built here rather than opened: a radial burst and its
# coverage mask, so sprite3zb has something to composite into the depth
# buffer without this game carrying an asset file.
makeboom()
{
	S: con 32;
	boomimg = disp.newimage(Rect((0,0),(S,S)), Draw->RGB24, 0, Draw->Black);
	boommask = disp.newimage(Rect((0,0),(S,S)), Draw->GREY1, 0, Draw->Black);
	if(boomimg == nil || boommask == nil)
		return;
	pix := array[S*S*3] of { * => byte 0 };
	mpl := (S + 7) / 8;
	msk := array[mpl*S] of { * => byte 0 };
	for(y := 0; y < S; y++){
		dy := real y - real S/2.0 + 0.5;
		for(x := 0; x < S; x++){
			dx := real x - real S/2.0 + 0.5;
			r := math->sqrt(dx*dx + dy*dy) / (real S/2.0);
			if(r > 1.0)
				continue;
			# a hot core fading to red, with a ragged edge so it
			# does not read as a disc
			t := 1.0 - r;
			t *= 0.75 + 0.25*math->sin(math->atan2(dy, dx)*7.0);
			if(t <= 0.05)
				continue;
			rr := int (255.0 * t);
			gg := int (200.0 * t * t);
			bb := int (90.0 * t * t * t);
			o := (y*S + x)*3;
			pix[o] = byte bb;	# RGB24 is b, g, r in memory
			pix[o+1] = byte gg;
			pix[o+2] = byte rr;
			msk[y*mpl + (x>>3)] |= byte (16r80 >> (x & 7));
		}
	}
	boomimg.writepixels(boomimg.r, pix);
	boommask.writepixels(boommask.r, msk);
}

# The canyon's shape, as a function of how far along it you are.  Two
# sines that do not share a period, so it never repeats within a run.
spine(k: int): real
{
	kk := real k;
	return 7.0*math->sin(kk*0.061) + 3.5*math->sin(kk*0.0173);
}

halfwidth(k: int): real
{
	return 5.6 + 1.8*math->sin(real k * 0.043);
}

newgame()
{
	lives = 3;
	score = 0;
	base = 0;
	restart();
}

restart()
{
	sx = spine(base);
	sy = 0.0;
	speed = 0.34;
	frac = 0.0;
	dist = 0.0;
	dead = 0;
	firecool = 0;
	pad = 0;
	prevpad = 0;
	pylons = array[NPYL] of ref Pylon;
	bolts = array[NBOLT] of ref Bolt;
	booms = array[NBOOM] of ref Boom;
	for(i := 0; i < NPYL; i++)
		pylons[i] = ref Pylon(base + 12 + i*3, pyloff(base + 12 + i*3),
			2.0 + 2.5*absr(math->sin(real (base+i) * 0.7)), 1);
}

# Where a pylon stands across the corridor: deterministic in its own
# index, so the course is the same course every run and -t sees the same
# one the player does.
pyloff(k: int): real
{
	return math->sin(real k * 1.7) * 0.72;
}

absr(v: real): real
{
	if(v < 0.0)
		return -v;
	return v;
}

# --------------------------------------------------------------- update

step()
{
	frames++;
	tone->sfxtick();
	if(dead > 0){
		dead--;
		stepbooms();
		if(dead == 0){
			if(lives <= 0)
				newgame();
			else
				restart();
		}
		return;
	}
	# forward
	speed += 0.00018;
	if(speed > 1.05)
		speed = 1.05;
	frac += speed;
	dist += speed;
	while(frac >= SEGLEN){
		frac -= SEGLEN;
		base++;
		recycle();
	}
	# steering, in the corridor's own frame
	if((pad & KLEFT) && !(pad & KRIGHT))
		sx -= SHIPVX;
	else if((pad & KRIGHT) && !(pad & KLEFT))
		sx += SHIPVX;
	if((pad & KUP) && !(pad & KDOWN))
		sy += SHIPVY;
	else if((pad & KDOWN) && !(pad & KUP))
		sy -= SHIPVY;
	if(sy < FLOORY + 0.6)
		sy = FLOORY + 0.6;
	if(sy > ROOFY - 0.6)
		sy = ROOFY - 0.6;
	# the walls are solid
	kk := shipseg();
	c := spine(kk);
	w := halfwidth(kk) - 0.7;
	if(sx < c - w){
		sx = c - w;
		graze();
	}
	if(sx > c + w){
		sx = c + w;
		graze();
	}
	if(firecool > 0)
		firecool--;
	if((keyhold->edge(pad, prevpad) & KA) && firecool == 0){
		fire();
		firecool = 9;
	}
	stepbolts();
	steppylons();
	stepbooms();
	prevpad = pad;
}

# The spine index the ship is at: it sits SHIPZ ahead of the eye.
shipseg(): int
{
	return base + int ((-SHIPZ + frac) / SEGLEN);
}

# Where segment index k sits in z, this frame.
segz(k: int): real
{
	return -(real (k - base) * SEGLEN - frac);
}

recycle()
{
	# a pylon the eye has passed comes back further down the canyon
	for(i := 0; i < NPYL; i++){
		p := pylons[i];
		if(p == nil)
			continue;
		if(segz(p.k) > 2.0){
			if(p.live)
				score += 25;		# flown past
			p.k = base + NSEG - 2;
			p.off = pyloff(p.k);
			p.h = 2.0 + 2.5*absr(math->sin(real p.k * 0.7));
			p.live = 1;
		}
	}
}

fire()
{
	for(i := 0; i < NBOLT; i++){
		if(bolts[i] != nil && bolts[i].live)
			continue;
		bolts[i] = ref Bolt(sx, sy, SHIPZ, 1);
		if(tone != nil)
			tone->sfx(2, 900, 50);
		return;
	}
}

BOLTV:	con 3.4;

stepbolts()
{
	for(i := 0; i < NBOLT; i++){
		b := bolts[i];
		if(b == nil || !b.live)
			continue;
		oz := b.z;
		b.z -= BOLTV;
		if(b.z < -FAR){
			b.live = 0;
			continue;
		}
		for(j := 0; j < NPYL; j++){
			p := pylons[j];
			if(p == nil || !p.live)
				continue;
			pz := segz(p.k);
			# The SWEPT segment, not the position.  A bolt covers
			# 3.4 units a frame and a pylon is under two deep, so
			# testing where the bolt ended up let it step clean
			# over one and carry on: the shot passed through and
			# nothing said why.
			if(pz > oz + 0.9 || pz < b.z - 0.9)
				continue;
			px := pylonx(p);
			if(absr(b.x - px) > 1.4)
				continue;
			if(b.y > FLOORY + p.h)
				continue;
			p.live = 0;
			b.live = 0;
			score += 150;
			boom(px, FLOORY + p.h*0.5, pz);
			if(tone != nil)
				tone->sfx(3, 420, 130);
			break;
		}
	}
}

pylonx(p: ref Pylon): real
{
	return spine(p.k) + p.off * (halfwidth(p.k) - 1.2);
}

steppylons()
{
	for(i := 0; i < NPYL; i++){
		p := pylons[i];
		if(p == nil || !p.live)
			continue;
		pz := segz(p.k);
		if(pz < SHIPZ - 1.2 || pz > SHIPZ + 1.2)
			continue;
		if(absr(sx - pylonx(p)) > 1.3)
			continue;
		if(sy > FLOORY + p.h)
			continue;
		p.live = 0;
		crash(pylonx(p), sy, pz);
	}
}

graze()
{
	if(dead > 0)
		return;
	if((frames & 7) != 0)
		return;
	if(tone != nil)
		tone->sfx(1, 220, 60);
}

crash(x, y, z: real)
{
	lives--;
	dead = 110;
	boom(x, y, z);
	boom(x + 0.8, y - 0.5, z - 1.0);
	if(tone != nil)
		tone->sfx(5, 150, 600);
}

boom(x, y, z: real)
{
	for(i := 0; i < NBOOM; i++){
		if(booms[i] != nil && booms[i].live)
			continue;
		booms[i] = ref Boom(x, y, z, 0, 1);
		return;
	}
}

BOOMT:	con 34;

stepbooms()
{
	for(i := 0; i < NBOOM; i++){
		b := booms[i];
		if(b == nil || !b.live)
			continue;
		b.z += speed;
		if(++b.t >= BOOMT || b.z > 1.0)
			b.live = 0;
	}
}

# --------------------------------------------------------------- render

# Distance shading.  A vertex's brightness is its facing times how much
# of the canyon's light reaches it, and the second term is what makes a
# Gouraud fill look like anything: a flat fill per quad would band, and
# this is a smooth ramp down the corridor.
fog(z: real): real
{
	t := 1.0 + z / FAR;		# z is negative ahead
	if(t < 0.0)
		t = 0.0;
	if(t > 1.0)
		t = 1.0;
	return t * t;
}

frame()
{
	if(ctx == nil || ctx.dst != target)
		ctx = d3->context(target);
	r := target.r;
	d3->resize(ctx, target);
	d3->viewport(ctx, r.min.x, r.min.y, r.max.x, r.max.y);
	d3->setzarea(ctx, r);
	target.draw(r, csky, nil, (0,0));
	d3->clearz(ctx);
	d3->setz(ctx, 1);
	d3->mode(Draw3d->PROJ);
	d3->identity();
	# Square pixels: the NDC scales must be in the window's own ratio,
	# because viewport() maps NDC to half the width and half the height
	# independently.  sy is negative because screen y runs down.
	w := real r.dx();
	h := real r.dy();
	sxs := 1.55;
	d3->frustumoffset(sxs, -sxs*w/h, 0.0);
	d3->mode(Draw3d->MODEL);
	d3->identity();
	# The eye rides the canyon rather than the world moving under a
	# fixed eye: one transform a frame instead of moving every vertex.
	#
	# It also rides ABOVE it, looking slightly down.  With the eye level
	# with the ship the ship is a flat delta seen exactly edge on, and
	# it renders as a couple of white lines - which is what the first
	# version did, and it looks like a drawing fault rather than a
	# camera one.
	d3->rotatex(7.0);
	d3->translate(-spine(base), -1.7, 0.0);

	canyon();
	drawpylons();
	drawbolts();
	if(dead == 0)
		ship();
	drawbooms();
	hud();
}

canyon()
{
	# floors first, then each wall: one colour per group, and the GPU
	# batches consecutive calls that share a transform.
	d3->setcolour(ctx, cfloor);
	for(i := 0; i < nseg-1; i++)
		quad(i, 0);
	d3->setcolour(ctx, cwallL);
	for(i = 0; i < nseg-1; i++)
		quad(i, 1);
	d3->setcolour(ctx, cwallR);
	for(i = 0; i < nseg-1; i++)
		quad(i, 2);
}

# One face of segment i.  kind 0 floor, 1 left wall, 2 right wall.
quad(i, kind: int)
{
	k0 := base + i;
	k1 := k0 + 1;
	z0 := segz(k0);
	z1 := segz(k1);
	c0 := spine(k0);
	c1 := spine(k1);
	w0 := halfwidth(k0);
	w1 := halfwidth(k1);
	f0 := fog(z0);
	f1 := fog(z1);
	case kind {
	0 =>
		qv[0] = Vector(c0-w0, FLOORY, z0);
		qv[1] = Vector(c0+w0, FLOORY, z0);
		qv[2] = Vector(c1+w1, FLOORY, z1);
		qv[3] = Vector(c1-w1, FLOORY, z1);
		ql[0] = f0*0.95; ql[1] = f0*0.95;
		ql[2] = f1*0.95; ql[3] = f1*0.95;
	1 =>
		qv[0] = Vector(c0-w0, FLOORY, z0);
		qv[1] = Vector(c0-w0, ROOFY, z0);
		qv[2] = Vector(c1-w1, ROOFY, z1);
		qv[3] = Vector(c1-w1, FLOORY, z1);
		ql[0] = f0*0.55; ql[1] = f0*1.0;
		ql[2] = f1*1.0; ql[3] = f1*0.55;
	* =>
		qv[0] = Vector(c0+w0, FLOORY, z0);
		qv[1] = Vector(c0+w0, ROOFY, z0);
		qv[2] = Vector(c1+w1, ROOFY, z1);
		qv[3] = Vector(c1+w1, FLOORY, z1);
		ql[0] = f0*0.5; ql[1] = f0*0.85;
		ql[2] = f1*0.85; ql[3] = f1*0.5;
	}
	d3->fillpoly3g(ctx, qv, ql);
}

drawpylons()
{
	for(i := 0; i < NPYL; i++){
		p := pylons[i];
		if(p == nil || !p.live)
			continue;
		z := segz(p.k);
		if(z > 1.0 || z < -FAR)
			continue;
		x := pylonx(p);
		f := fog(z);
		top := FLOORY + p.h;
		hw := 0.85;
		hz := 0.85;
		d3->setcolour(ctx, cpylon);
		# four sides, each lit a little differently so the box reads
		# as a box and not as a silhouette
		side(x-hw, x-hw, z-hz, z+hz, top, f*0.85);
		side(x+hw, x+hw, z-hz, z+hz, top, f*0.6);
		side(x-hw, x+hw, z-hz, z-hz, top, f*1.0);
		side(x-hw, x+hw, z+hz, z+hz, top, f*0.45);
		d3->setcolour(ctx, cpyltop);
		qv[0] = Vector(x-hw, top, z-hz);
		qv[1] = Vector(x+hw, top, z-hz);
		qv[2] = Vector(x+hw, top, z+hz);
		qv[3] = Vector(x-hw, top, z+hz);
		ql[0] = f; ql[1] = f; ql[2] = f*0.8; ql[3] = f*0.8;
		d3->fillpoly3g(ctx, qv, ql);
	}
}

side(x0, x1, z0, z1, top, lit: real)
{
	qv[0] = Vector(x0, FLOORY, z0);
	qv[1] = Vector(x1, FLOORY, z1);
	qv[2] = Vector(x1, top, z1);
	qv[3] = Vector(x0, top, z0);
	ql[0] = lit*0.45; ql[1] = lit*0.45; ql[2] = lit; ql[3] = lit;
	d3->fillpoly3g(ctx, qv, ql);
}

ship()
{
	# A delta, drawn in the corridor's frame.  Banking with the turn is
	# two extra multiplies and makes the whole thing read as flying.
	bank := 0.0;
	if(pad & KLEFT)
		bank = 0.45;
	if(pad & KRIGHT)
		bank = -0.45;
	cb := math->cos(bank);
	sb := math->sin(bank);
	d3->setcolour(ctx, cship);
	nose := wing(0.0, 0.0, -1.5, cb, sb);
	lt := wing(-1.25, 0.28, 0.7, cb, sb);
	rt := wing(1.25, 0.28, 0.7, cb, sb);
	tail := wing(0.0, 0.0, 0.45, cb, sb);
	tri(nose, lt, tail, 1.0, 0.55, 0.8);
	tri(nose, tail, rt, 1.0, 0.8, 0.5);
	d3->setcolour(ctx, cshipfin);
	fin := wing(0.0, 0.85, 0.6, cb, sb);
	tri(nose, fin, tail, 0.9, 1.0, 0.6);
}

tri(a, b, c: Vector, la, lb, lc: real)
{
	tv[0] = a; tv[1] = b; tv[2] = c;
	tlit[0] = la; tlit[1] = lb; tlit[2] = lc;
	d3->fillpoly3g(ctx, tv, tlit);
}

wing(lx, ly, lz, cb, sb: real): Vector
{
	return Vector(sx + lx*cb - ly*sb, sy + lx*sb + ly*cb, SHIPZ + lz);
}

drawbolts()
{
	d3->setcolour(ctx, cbolt);
	for(i := 0; i < NBOLT; i++){
		b := bolts[i];
		if(b == nil || !b.live)
			continue;
		f := fog(b.z);
		qv[0] = Vector(b.x-0.12, b.y, b.z);
		qv[1] = Vector(b.x+0.12, b.y, b.z);
		qv[2] = Vector(b.x+0.12, b.y, b.z-1.8);
		qv[3] = Vector(b.x-0.12, b.y, b.z-1.8);
		ql[0] = 1.0; ql[1] = 1.0; ql[2] = f*0.3; ql[3] = f*0.3;
		d3->fillpoly3g(ctx, qv, ql);
	}
}

# The one thing here that is a sprite rather than geometry, and it is a
# sprite on purpose: sprite3zb spins a flat image to face the eye and
# depth-tests it against everything already drawn, so an explosion
# behind a pylon is hidden by it.
drawbooms()
{
	if(boomimg == nil)
		return;
	for(i := 0; i < NBOOM; i++){
		b := booms[i];
		if(b == nil || !b.live)
			continue;
		t := real b.t / real BOOMT;
		sc := 3.0 + 9.0*t;
		d3->sprite3zb(ctx, Vector(b.x, b.y, b.z), boomimg, boommask,
			sc, real b.t * 11.0);
	}
}

hud()
{
	if(font == nil)
		return;
	d3->setz(ctx, 0);
	r := target.r;
	target.text(Point(r.min.x+10, r.min.y+8), cwhite, (0,0), font,
		sys->sprint("SCORE %6d    BEST %6d", score, best));
	target.text(Point(r.min.x+10, r.min.y+8+font.height), cwhite, (0,0),
		font, sys->sprint("SHIPS %d    SPEED %3d    %5d M",
			lives, int (speed*300.0), int dist));
	why := "gpu";
	if(provider == Draw3d->PATH)
		why = "software";
	target.text(Point(r.min.x+10, r.min.y+8+2*font.height), cwhite, (0,0),
		font, why);
	if(dead > 0 && lives <= 0)
		target.text(Point(r.min.x + r.dx()/2 - 40, r.min.y + r.dy()/2),
			cred, (0,0), font, "GAME OVER");
}

# -g: does what is on the SCREEN come from the GPU?
#
# g3_calls counts submissions to the geometry queue, and this tree has a
# case on record where submissions were counted, the colours were valid,
# and nothing rasterized (draw3ddemo(1), frustum()).  So the counter is
# not the answer.
#
# devdraw.c settles the other half: a successful gpudrawfillpoly3d does
# `goto gdone`, so the CPU never fills a polygon the GPU accepted.  A
# face is therefore drawn by one or the other and never both.  If the
# picture is on the screen while g3_calls is high and soft_fallbacks is
# zero, the GPU drew it; if the queue were being filled and dropped, the
# canyon would be missing and the sky and the text would remain.
#
# So: draw into the window, read the window back, and count what is not
# sky.  draw3dbench(1) shows the readback is broken for a LAYER and not
# for the screen itself, which is what this gets with no window manager.
gpushot()
{
			audio = 0;
	win.reshape(Rect((0,0),(WIDE,HIGH)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	target = win.image;
	ctx = d3->context(target);
	newgame();
	for(i := 0; i < 90; i++){
		pad = KRIGHT;
		if((i % 34) < 12)
			pad |= KA;
		step();
		target = win.image;
		frame();
		target.flush(Draw->Flushnow);
	}
	w := target.r.dx();
	h := target.r.dy();
	bpp := target.depth / 8;
	b := array[w*h*bpp] of byte;
	fd := sys->fildes(2);
	sys->fprint(fd, "gorge -g: %d frames drawn, reading back %dx%d depth %d\n",
		90, w, h, target.depth);
	n := target.readpixels(target.r, b);
	if(n < 0){
		sys->fprint(fd, "gorge -g: readpixels failed: %r\n");
		return;
	}
	# the sky it was cleared to
	sk0 := b[0];
	sk1 := b[1];
	sk2 := b[2];
	lit := 0;
	for(i = 0; i < w*h; i++)
		if(b[i*bpp] != sk0 || b[i*bpp+1] != sk1 || b[i*bpp+2] != sk2)
			lit++;
	# The head-up display is white text, and it is the part that goes
	# missing when the GPU path composes the frame in the wrong order:
	# geometry drained at present time paints over everything the CPU
	# drew into the same image.  Counting near-white pixels turns "the
	# HUD is gone" from something you have to see into a number, and
	# makes the two providers comparable without a camera.
	white := 0;
	for(i = 0; i < w*h; i++)
		if(int b[i*bpp] > 200 && int b[i*bpp+1] > 200 && int b[i*bpp+2] > 200)
			white++;
	sys->fprint(fd, "gorge -g: provider %s, non-sky pixels %d of %d, HUD pixels %d\n",
		provider, lit, w*h, white);
	rd := sys->create("gorge.gpu.raw", Sys->OWRITE, 8r666);
	if(rd == nil)
		sys->fprint(fd, "gorge -g: create: %r\n");
	else
		sys->write(rd, b, len b);
}

# ---------------------------------------------------------------- bench

# What the two providers cost on the same scene, drawn into the window,
# which is the only destination emu's GPU hook will take.  No frame
# pacing: the number is the work.
nbench := 240;

bench()
{
			audio = 0;
	win.reshape(Rect((0,0),(WIDE,HIGH)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	target = win.image;
	ctx = d3->context(target);
	newgame();
	benchrun(20);			# warm up: first frames build caches
	newgame();
	us := benchrun(nbench);
	# Under wm(1) a print goes to the Log window and not to whatever
	# started emu, so the numbers go to a file as well.
	fd := sys->fildes(2);
	f2 := sys->create("/gorge.bench", Sys->OWRITE, 8r666);
	if(f2 != nil)
		sys->fprint(f2, "gorge: %s\n%d frames of about %d faces: %d us a frame\n",
			provider, nbench, nseg*3 + NPYL*5, us);
	sys->fprint(fd, "gorge: %s\n", provider);
	sys->fprint(fd, "gorge: %d frames of about %d faces into the window: %d us a frame",
		nbench, nseg*3 + NPYL*5, us);
	if(us > 0)
		sys->fprint(fd, ", %d a second", 1000000 / us);
	sys->fprint(fd, "\n");
	if(us > 16666)
		sys->fprint(fd, "gorge: SLOWER THAN 60Hz\n");
}

benchrun(nframes: int): int
{
	t0 := sys->millisec();
	for(i := 0; i < nframes; i++){
		pad = KRIGHT;
		step();
		target = win.image;
		frame();
		target.flush(Draw->Flushnow);
	}
	return (sys->millisec() - t0) * 1000 / nframes;
}

shot()
{
			audio = 0;
	newgame();
	ctx = d3->context(target);
	# Short, because -s renders with the software provider and that
	# costs about 70ms a frame here; see DIAGNOSTICS.
	for(i := 0; i < 90; i++){
		pad = 0;
		if((i / 25 & 1) != 0)
			pad = KRIGHT;
		else
			pad = KLEFT;
		if(i % 18 == 0)
			pad |= KA;
		step();
		frame();
	}
	w := target.r.dx();
	h := target.r.dy();
	bpp := target.depth / 8;
	b := array[w*h*bpp] of byte;
	if(target.readpixels(target.r, b) < 0){
		sys->print("readpixels: %r\n");
		return;
	}
	fd := sys->create("gorge.raw", Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->print("create: %r\n");
		return;
	}
	sys->write(fd, b, len b);
	sys->print("wrote gorge.raw %dx%d %d bytes a pixel\n", w, h, bpp);
}

# ----------------------------------------------------------------- test

nfail := 0;

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

# The test steps every frame and DRAWS one in ten.
#
# Drawing here is a crash check - a fault in the geometry is a fault
# whether it happens once or three hundred times - and the software
# provider costs about 70ms and a great deal of allocation per frame on
# this scene, enough that a full test run does not finish.  Stepping is
# what the assertions are about and it still happens every frame, so
# nothing being checked is sampled.
DRAWEVERY:	con 10;

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
	sys->print("gorge: self test\n");
			audio = 0;
	ctx = d3->context(target);
	newgame();

	# The canyon is a function, so it is checkable without drawing it.
	nw := 0;
	for(k := 0; k < 4000; k++){
		w := halfwidth(k);
		if(w < 3.0 || w > 8.0)
			nw++;
	}
	ck("the corridor never pinches shut or opens out", nw, 0);
	nz := 0;
	for(k = 0; k < 4000; k++){
		a := spine(k);
		b := spine(k+1);
		if(absr(b - a) > 1.0)
			nz++;
	}
	ck("and never kinks between segments", nz, 0);
	cktrue("fog is dark far away and bright near",
		fog(-FAR) < 0.01 && fog(0.0) > 0.99);

	# Flying forward advances the course and the score.
	d0 := int dist;
	b0 := base;
	run(120, 0);
	cktrue("flying covers ground", int dist > d0 + 30);
	cktrue("and moves the eye down the canyon", base > b0);
	ck("no lives lost flying straight", lives, 3);

	# Steering moves the ship and the walls stop it.
	restart();
	x0 := sx;
	run(10, KRIGHT);
	cktrue("steering right moves right", sx > x0);
	run(10, KLEFT);
	cktrue("and left moves left", sx < x0 + 10.0*SHIPVX);
	restart();
	run(300, KRIGHT);
	kk := shipseg();
	cktrue("the right wall stops it",
		sx <= spine(kk) + halfwidth(kk) - 0.7 + 0.001);
	restart();
	run(300, KLEFT);
	kk = shipseg();
	cktrue("and the left wall stops it",
		sx >= spine(kk) - halfwidth(kk) + 0.7 - 0.001);
	restart();
	run(300, KUP);
	cktrue("the roof stops it", sy <= ROOFY - 0.6 + 0.001);
	run(300, KDOWN);
	cktrue("and the floor stops it", sy >= FLOORY + 0.6 - 0.001);

	# Firing is rate limited and a bolt travels away from the eye.
	restart();
	prevpad = 0;
	run(1, KA);
	n := 0;
	for(i := 0; i < NBOLT; i++)
		if(bolts[i] != nil && bolts[i].live)
			n++;
	ck("one press makes one bolt", n, 1);
	bz := bolts[0].z;
	run(3, 0);
	cktrue("a bolt flies away from the eye", bolts[0].z < bz);
	run(1, KA);
	n = 0;
	for(i = 0; i < NBOLT; i++)
		if(bolts[i] != nil && bolts[i].live)
			n++;
	ck("holding fire does not stream them", n, 1);

	# A bolt destroys a pylon, scores, and leaves an explosion.
	restart();
	p := firstpylon();
	cktrue("the course has pylons", p != nil);
	if(p != nil){
		s0 := score;
		bolts[0] = ref Bolt(pylonx(p), FLOORY + 0.5, segz(p.k) + 2.0, 1);
		run(1, 0);
		cktrue("a hit kills the pylon", !p.live);
		cktrue("and scores", score > s0);
		nb := 0;
		for(i = 0; i < NBOOM; i++)
			if(booms[i] != nil && booms[i].live)
				nb++;
		cktrue("and leaves an explosion", nb > 0);
	}

	# Running into one costs a ship.  Forced, because it does not
	# happen on demand.
	restart();
	lives = 3;
	p = firstpylon();
	if(p != nil){
		# Two segments ahead of the ship, not on top of it: step()
		# advances the world BEFORE it tests, so a pylon placed level
		# with the ship has already been carried past the window by
		# the time anything looks at it.
		p.k = base + int ((-SHIPZ + frac) / SEGLEN) + 2;
		p.off = 0.0;
		p.h = 4.0;
		for(i = 0; i < 80 && dead == 0; i++){
			sx = pylonx(p);
			sy = FLOORY + 1.0;
			run(1, 0);
		}
		ck("hitting a pylon costs a ship", lives, 2);
	}

	# A pylon the eye passes is recycled ahead rather than lost.
	restart();
	live0 := countpylons();
	run(900, 0);
	ck("the pylons keep coming", countpylons(), live0);
	cktrue("and are all ahead of the eye", allahead());

	# It gets faster.
	restart();
	v0 := speed;
	run(600, 0);
	cktrue("the flight speeds up", speed > v0);

	# Drawing a frame is checked by doing it: every run() above called
	# frame(), so a fault in the geometry is a crash here.  What can be
	# asserted about the picture is that it is not blank.
	restart();
	run(1, 0);
	frame();
	cktrue("a frame draws something", lit() > 20000);

	if(nfail == 0)
		sys->print("gorge: PASSED\n");
	else{
		sys->print("gorge: FAILED (%d)\n", nfail);
		raise "fail:test";
	}
}

lit(): int
{
	w := target.r.dx();
	h := target.r.dy();
	bpp := target.depth / 8;
	b := array[w*h*bpp] of byte;
	if(target.readpixels(target.r, b) < 0)
		return -1;
	# Anything that is not the sky it was cleared to.
	n := 0;
	for(i := 0; i < w*h; i++)
		if(b[i*bpp] != byte 16r22 || b[i*bpp+1] != byte 16r12
		|| b[i*bpp+2] != byte 16r10)
			n++;
	return n;
}

firstpylon(): ref Pylon
{
	for(i := 0; i < NPYL; i++)
		if(pylons[i] != nil && pylons[i].live)
			return pylons[i];
	return nil;
}

countpylons(): int
{
	n := 0;
	for(i := 0; i < NPYL; i++)
		if(pylons[i] != nil && pylons[i].live)
			n++;
	return n;
}

allahead(): int
{
	for(i := 0; i < NPYL; i++){
		p := pylons[i];
		if(p == nil || !p.live)
			continue;
		if(segz(p.k) > 3.0)
			return 0;
	}
	return 1;
}
