implement Camber;

# Camber - a side-view racer, in the shape that genre took on the early
# consoles: four lanes you move between, ramps that throw you into the
# air, an attitude up there that decides whether the landing is clean,
# rivals to get past, and a temperature gauge that punishes holding the
# fast button.  And, because that genre is remembered for it as much as
# for the racing, a mode in which you lay the course out yourself and
# save it.
#
# That design mode is why this game is in the tree.  Every other game
# here compiles its art and its levels in as arrays of strings in the
# source, which works and which is also the complaint: tiles(2) grew a
# command language - "sheet", "surface", "palette" - precisely so that a
# game's content could be data it reads rather than source it is built
# from, and until now nothing used it.  Camber does.  The art is
# /lib/tiles/camber.chr and /lib/tiles/camber16.chr; the course is
# /lib/tiles/ridge.trk, which camber -e writes and which a shell script
# could just as well generate, because it is text.  There is not one
# tile and not one feature of the course in this file.
#
# What is in this file is the rules, which is the part that has to run
# at sixty frames a second.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "keyhold.m";
	keyhold: Keyhold;
	Binding: import keyhold;

include "tone.m";
	tone: Tone;

include "tiles.m";
	tiles: Tiles;
	Chr, Pal, Surface, Screen: import tiles;

include "frameclock.m";
	fclock: Frameclock;

include "scorestore.m";
	scorestore: Scorestore;

Camber: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# What this game's keys do.  keyhold(2) names no buttons: what a button
# means is the program's business.
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

SCALE:	con 2;
W:	con Tiles->W;
H:	con Tiles->H;
NTH:	con Tiles->NTH;

# The screen, top to bottom: a panel of instruments, then the lanes.
HUDH:	con 48;			# instrument panel, in logical pixels
LTOP:	con HUDH;		# first lane starts here
LANEH:	con 48;			# a lane band
LGROUND: con 32;		# where in a band the road surface is
MAXLANE: con 4;			# bands that fit below the panel

# The tiles in camber.chr, in the order they are written there.
TNONE, TROAD, TRAIL, TRAMPA, TRAMPB, TBUMP, TMUD, TSTRIP, TCHEQ, TPOST: con iota;
# The machines in camber16.chr.  sheet16 cuts each into four 8x8 tiles,
# so the k-th is tile 4*k.
MLEVEL:	con 0;
MUP:	con 4;
MDOWN:	con 8;
MOUT:	con 12;

# What a course is made of.  These names are the words in a track file.
FRAMP, FBUMP, FMUD, FSTRIP, FRIDER: con iota;
NKIND:	con 5;

featname := array[] of {"ramp", "bump", "mud", "strip", "rider"};
featwide := array[] of {2, 1, 4, 3, 1};		# in tiles

Feat: adt {
	x:	int;		# tiles from the start line
	lane:	int;
	kind:	int;
	arg:	int;		# a rider's pace, in hundredths of a pixel
};

Track: adt {
	title:	string;
	length:	int;		# tiles
	lanes:	int;
	f:	array of ref Feat;
	n:	int;
};

Rival: adt {
	x:	real;
	lane:	int;
	spd:	real;
	live:	int;
};

# --- the machine ---
px:	real;			# logical pixels along the course
lane:	int;
lanep:	real;			# where it is drawn, easing toward lane
spd:	real;
heat:	real;
z, vz:	real;			# height above the road
pitch:	real;			# degrees, nose up positive
air:	int;
crash:	int;			# frames left on the ground
stall:	int;			# frames left seized
frames:	int;
done:	int;
timems:	int;
best:	int;
newbest: int;
cam:	int;

pad, prevpad: int;
norider: int;			# the self test's negative control

trk:	ref Track;
riv:	array of ref Rival;
nriv:	int;

scn:	ref Screen;
scr, bg: ref Surface;
road, bike: ref Chr;
proad, prail, pramp, pbump, pmud, pstrip, pcheq, ppost,
	pbike, prival, phud, pwarn: ref Pal;
verge, panel, barlo, barhi: int;

win:	ref Window;
testmode: int;
shotframes: int;
audio:	int;
trackfile: string;

# Playing, as against running a self test or writing a screenshot.  Only
# a playing program asks tone(2) for audio.
playing(): int
{
	return testmode == 0;
}

# ------------------------------------------------------------ constants

SPDCRUISE: con 3.2;		# what the ordinary throttle reaches
SPDTURBO: con 5.2;		# what the hot one reaches
ACC:	con 0.05;
ACCT:	con 0.09;
DRAG:	con 0.04;
BRAKE:	con 0.12;

HEATUP:	con 1.2;		# a frame on the hot throttle
HEATDN:	con 0.9;		# a frame off it
HEATMAX: con 100.0;
STALL:	con 100;		# frames seized when it boils

GRAV:	con 0.30;
RAMPBASE: con 2.2;
RAMPGAIN: con 0.55;
BUMPV:	con 1.3;
PITCHLAUNCH: con 26.0;		# a ramp throws the nose up this far
PITCHRATE: con 2.0;		# and this is how fast it can be brought back
PITCHOK: con 18.0;		# land outside this and it goes down
CRASHF:	con 80;			# frames spent picking it up again

MUDCAP:	con 1.4;
MUDDRAG: con 0.35;
STRIPACC: con 0.18;

LANEEASE: con 0.35;
HITX:	con 12.0;		# how close is a collision
HITZ:	con 10.0;		# and how far above one is clear

# ---------------------------------------------------------------- setup

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	keyhold = load Keyhold Keyhold->PATH;
	tone = load Tone Tone->PATH;
	kb = keyhold->mk(BINDS);
	tiles = load Tiles Tiles->PATH;
	fclock = load Frameclock Frameclock->PATH;
	scorestore = load Scorestore Scorestore->PATH;
	if(tiles == nil){
		sys->fprint(sys->fildes(2), "camber: cannot load tiles: %r\n");
		raise "fail:load";
	}
	e := tiles->init();
	if(e != nil){
		sys->fprint(sys->fildes(2), "camber: %s\n", e);
		raise "fail:init";
	}
	if(fclock != nil)
		fclock->init();
	trackfile = "/lib/tiles/ridge.trk";
	edit := 0;
	args := tl argv;
	for(a := args; a != nil; a = tl a){
		case hd a {
		"-t" =>	testmode = 1;
		"-s" =>	testmode = 2;
		"-q" =>	audio = -1;
		"-e" =>	edit = 1;
		"-n" =>
			if(tl a == nil){
				sys->fprint(sys->fildes(2), "camber: -n wants a number\n");
				raise "fail:usage";
			}
			a = tl a;
			shotframes = int hd a;
		* =>
			if(len hd a > 0 && (hd a)[0] == '-'){
				sys->fprint(sys->fildes(2),
					"usage: camber [-e] [-t] [-s [-n frames]] [-q] [track]\n");
				raise "fail:usage";
			}
			trackfile = hd a;
		}
	}

	(t, err) := readtrack(trackfile);
	if(t == nil){
		sys->fprint(sys->fildes(2), "camber: %s\n", err);
		raise "fail:track";
	}
	trk = t;

	d: ref Display;
	if(testmode){
		d = Display.allocate(nil);
		if(d == nil){
			sys->fprint(sys->fildes(2), "camber: no display: %r\n");
			raise "fail:display";
		}
	}else{
		wmclient = load Wmclient Wmclient->PATH;
		sys->pctl(Sys->NEWPGRP, nil);
		wmclient->init();
		if(ctxt == nil)
			ctxt = wmclient->makedrawcontext();
		title := "Camber";
		if(edit)
			title = "Camber - design";
		win = wmclient->window(ctxt, title, Wmclient->Appl);
		d = win.display;
	}
	setup(d);
	if(scorestore != nil)
		best = scorestore->loadint("camber", 0);
	if(audio == 0 && playing() && tone != nil && tone->init() == nil)
		audio = 1;
	restart();
	if(testmode == 1){
		selftest();
		return;
	}
	if(testmode == 2){
		shot();
		return;
	}
	win.reshape(Rect((0,0),(W*SCALE, H*SCALE)));
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);
	if(edit)
		editloop();
	else
		raceloop();
}

# A command that fails is a bug in this program, not something a player
# can do anything about, so it stops here rather than drawing a wrong
# picture quietly.
docmd(c: string)
{
	r := scn.cmd(c);
	if(len r > 0 && r[0] == '!'){
		sys->fprint(sys->fildes(2), "camber: %s\n", r);
		raise "fail:cmd";
	}
}

setup(d: ref Display)
{
	scn = tiles->screen(d, Draw->RGB24, SCALE);
	if(scn == nil){
		sys->fprint(sys->fildes(2), "camber: no screen\n");
		raise "fail:screen";
	}
	# All of the art, by name, out of files.  This is the whole of the
	# difference between this game and the other four.
	docmd("sheet road /lib/tiles/camber.chr");
	docmd("sheet16 bike /lib/tiles/camber16.chr");
	docmd("font text");

	verge = tiles->entry(Tiles->DARK, Tiles->GREEN);
	panel = tiles->entry(Tiles->DARK, Tiles->BLACK);
	barlo = tiles->entry(Tiles->MID, Tiles->LIME);
	barhi = tiles->entry(Tiles->LIGHT, Tiles->RED);

	docmd("palette proad dark.green dark.grey mid.grey light.grey");
	docmd("palette prail dark.green dark.grey pale.grey mid.grey");
	docmd("palette pramp dark.green mid.yellow light.yellow pale.yellow");
	docmd("palette pbump dark.green dark.grey mid.orange light.orange");
	docmd("palette pmud dark.green dark.orange dark.red mid.orange");
	docmd("palette pstrip dark.green dark.grey mid.cyan pale.cyan");
	docmd("palette pcheq dark.green dark.grey pale.grey dark.black");
	docmd("palette ppost dark.green dark.grey pale.grey pale.grey");
	docmd("palette pbike dark.green dark.black mid.red pale.grey");
	docmd("palette prival dark.green dark.black mid.violet light.cyan");
	docmd("palette phud dark.black pale.grey pale.grey pale.grey");
	docmd("palette pwarn dark.black light.red light.red light.red");

	docmd(sys->sprint("surface scr %d %d %d", W, H, verge));
	docmd(sys->sprint("surface bg %d %d %d", trk.length*8, H, verge));

	scr = scn.named("scr");
	bg = scn.named("bg");
	road = scn.sheet("road");
	bike = scn.sheet("bike");
	proad = scn.pal("proad");
	prail = scn.pal("prail");
	pramp = scn.pal("pramp");
	pbump = scn.pal("pbump");
	pmud = scn.pal("pmud");
	pstrip = scn.pal("pstrip");
	pcheq = scn.pal("pcheq");
	ppost = scn.pal("ppost");
	pbike = scn.pal("pbike");
	prival = scn.pal("prival");
	phud = scn.pal("phud");
	pwarn = scn.pal("pwarn");
	if(scr == nil || bg == nil || road == nil || bike == nil){
		sys->fprint(sys->fildes(2), "camber: the screen made nothing\n");
		raise "fail:screen";
	}
	buildtrack();
}

# A surface holds one sheet at a time.  Drawing from the other one is a
# swap either side of the call, which is what tiles(2)'s own command
# language does internally for exactly this reason.
sput16(s: ref Surface, x, y, t: int, p: ref Pal, flags: int)
{
	old := s.chr;
	s.chr = bike;
	s.put16(x, y, t, p, flags);
	s.chr = old;
}

# The row of tiles a lane's road surface occupies.
groundrow(l: int): int
{
	return (LTOP + l*LANEH + LGROUND) / 8;
}

# Where a machine's wheels sit, as a real so a lane change can be eased.
groundy(l: real): real
{
	return real LTOP + l * real LANEH + real LGROUND;
}

# Paint the whole course once.  Every frame is then a window of this
# plus whatever is moving, which is what makes the scroll cost one blit.
buildtrack()
{
	lw := trk.length;
	bg.fill(Rect((0,0),(lw*8, H)), verge);
	for(l := 0; l < trk.lanes; l++){
		gr := groundrow(l);
		tr := (LTOP + l*LANEH) / 8;
		for(tx := 0; tx < lw; tx++){
			bg.tile(tx, gr, TROAD, proad);
			bg.tile(tx, gr+1, TROAD, proad);
			bg.tile(tx, tr, TRAIL, prail);
			# The posts went on the row above the rail, which for
			# every lane but the first is the road of the lane
			# before it: they were painted over that lane's surface.
			if(tx % 8 == 0)
				bg.tile(tx, tr, TPOST, ppost);
		}
	}
	for(i := 0; i < trk.n; i++){
		f := trk.f[i];
		if(f.kind == FRIDER)
			continue;
		gr := groundrow(f.lane);
		case f.kind {
		FRAMP =>
			bg.tile(f.x, gr, TRAMPA, pramp);
			bg.tile(f.x+1, gr, TRAMPB, pramp);
		FBUMP =>
			bg.tile(f.x, gr, TBUMP, pbump);
		FMUD =>
			for(k := 0; k < featwide[FMUD]; k++)
				bg.tile(f.x+k, gr, TMUD, pmud);
		FSTRIP =>
			for(k := 0; k < featwide[FSTRIP]; k++)
				bg.tile(f.x+k, gr, TSTRIP, pstrip);
		}
	}
	# The finish, across every lane.
	for(l = 0; l < trk.lanes; l++){
		gr := groundrow(l);
		bg.tile(lw-2, gr, TCHEQ, pcheq);
		bg.tile(lw-1, gr, TCHEQ, pcheq);
	}
}

restart()
{
	px = 8.0;
	lane = 1;
	lanep = real lane;
	spd = 0.0;
	heat = 0.0;
	z = vz = pitch = 0.0;
	air = crash = stall = 0;
	frames = 0;
	done = 0;
	timems = 0;
	newbest = 0;
	pad = prevpad = 0;
	cam = 0;
	spawnrivals();
}

spawnrivals()
{
	n := 0;
	for(i := 0; i < trk.n; i++)
		if(trk.f[i].kind == FRIDER)
			n++;
	riv = array[n] of ref Rival;
	nriv = 0;
	for(i = 0; i < trk.n; i++){
		f := trk.f[i];
		if(f.kind != FRIDER)
			continue;
		s := real f.arg / 100.0;
		if(s <= 0.0)
			s = 1.8;
		riv[nriv++] = ref Rival(real (f.x*8), f.lane, s, 1);
	}
}

# ----------------------------------------------------------- the rules

# The feature under a point, if any.  x is in logical pixels.
featat(x, l: int): ref Feat
{
	tx := x / 8;
	for(i := 0; i < trk.n; i++){
		f := trk.f[i];
		if(f.kind == FRIDER || f.lane != l)
			continue;
		if(tx >= f.x && tx < f.x + featwide[f.kind])
			return f;
	}
	return nil;
}

step()
{
	if(done)
		return;
	frames++;
	edge := pad & ~prevpad;
	prevpad = pad;

	if(crash > 0){
		crash--;
		spd = 0.0;
		z = vz = pitch = 0.0;
		air = 0;
		cool();
		steprivals();
		follow();
		return;
	}
	if(stall > 0){
		# Seized: it coasts, it cannot be driven, and the gauge
		# empties over exactly as long as the stall lasts.
		stall--;
		spd -= DRAG * 2.0;
		if(spd < 0.0)
			spd = 0.0;
		heat -= HEATMAX / real STALL;
		if(heat < 0.0)
			heat = 0.0;
		px += spd;
		steprivals();
		hitrivals();
		finish();
		follow();
		return;
	}

	if(air)
		stepair(pad);
	else
		stepground(pad, edge);

	px += spd;
	lanep += (real lane - lanep) * LANEEASE;
	steprivals();
	hitrivals();
	finish();
	follow();
}

cool()
{
	heat -= HEATDN;
	if(heat < 0.0)
		heat = 0.0;
}

stepair(p: int)
{
	# Up there the machine does not steer; it rotates.  Getting the
	# nose back down before the wheels arrive is the whole of it.
	if(p & KLEFT)
		pitch += PITCHRATE;
	if(p & KRIGHT)
		pitch -= PITCHRATE;
	if(pitch > 90.0)
		pitch = 90.0;
	if(pitch < -90.0)
		pitch = -90.0;
	cool();
	vz -= GRAV;
	z += vz;
	if(z <= 0.0){
		z = 0.0;
		vz = 0.0;
		air = 0;
		land();
	}
}

land()
{
	if(pitch > PITCHOK || pitch < -PITCHOK){
		crash = CRASHF;
		spd = 0.0;
		sfx(2, 90, 260);
	}else{
		spd += 0.12;
		if(spd > SPDTURBO)
			spd = SPDTURBO;
		sfx(1, 420, 40);
	}
	pitch = 0.0;
}

stepground(p, edge: int)
{
	if((edge & KUP) && lane > 0)
		lane--;
	if((edge & KDOWN) && lane < trk.lanes - 1)
		lane++;

	if(p & KB){
		spd += ACCT;
		if(spd > SPDTURBO)
			spd = SPDTURBO;
		heat += HEATUP;
	}else if(p & KA){
		spd += ACC;
		if(spd > SPDCRUISE)
			spd = SPDCRUISE;
		cool();
	}else{
		spd -= DRAG;
		cool();
	}
	if(p & KLEFT)
		spd -= BRAKE;
	if(spd < 0.0)
		spd = 0.0;
	if(heat >= HEATMAX){
		heat = HEATMAX;
		stall = STALL;
		sfx(2, 70, 400);
		return;
	}

	# What is underneath.  The point sampled is the middle of the
	# machine, not its leading edge: sampling the edge put it on a ramp
	# a whole tile before the picture said it was.
	f := featat(int px + 8, lane);
	if(f == nil)
		return;
	case f.kind {
	FRAMP =>
		if(spd > 0.8){
			air = 1;
			vz = RAMPBASE + spd * RAMPGAIN;
			pitch = PITCHLAUNCH;
			sfx(1, 300, 60);
		}
	FBUMP =>
		if(spd > 0.5){
			air = 1;
			vz = BUMPV;
			pitch = 0.0;
			spd -= 0.15;
		}
	FMUD =>
		# Mud limits the speed; it does not keep taking speed away.
		# Subtracting without a floor stopped the machine dead in the
		# four-lane band at 122 and it never got out again - which
		# read, from outside, as a course that could not be finished.
		if(spd > MUDCAP){
			spd -= MUDDRAG;
			if(spd < MUDCAP)
				spd = MUDCAP;
		}
	FSTRIP =>
		spd += STRIPACC;
		if(spd > SPDTURBO)
			spd = SPDTURBO;
	}
}

steprivals()
{
	end := real (trk.length * 8);
	for(i := 0; i < nriv; i++){
		r := riv[i];
		if(!r.live)
			continue;
		r.x += r.spd;
		if(r.x > end)
			r.live = 0;
	}
}

hitrivals()
{
	if(crash > 0)
		return;
	if(air && z > HITZ)
		return;
	for(i := 0; i < nriv; i++){
		r := riv[i];
		if(!r.live || r.lane != lane)
			continue;
		dx := px - r.x;
		if(dx < 0.0)
			dx = -dx;
		if(dx < HITX){
			crash = CRASHF;
			spd = 0.0;
			air = 0;
			z = vz = pitch = 0.0;
			sfx(2, 110, 300);
			return;
		}
	}
}

finish()
{
	line := real ((trk.length - 2) * 8);
	if(px < line)
		return;
	px = line;
	done = 1;
	timems = frames * 1000 / 60;
	if(best == 0 || timems < best){
		best = timems;
		newbest = 1;
		if(scorestore != nil)
			scorestore->saveint("camber", best);
	}
}

follow()
{
	cam = int px - 64;
	if(cam < 0)
		cam = 0;
	m := trk.length*8 - W;
	if(cam > m)
		cam = m;
}

sfx(pri, freq, ms: int)
{
	if(audio == 1 && tone != nil)
		tone->sfx(pri, freq, ms);
}

# ---------------------------------------------------------------- draw

machine(): int
{
	if(crash > 0)
		return MOUT;
	if(stall > 0)
		return MDOWN;
	if(pitch > 6.0)
		return MUP;
	if(pitch < -6.0)
		return MDOWN;
	return MLEVEL;
}

draw1()
{
	bg.view(scr, cam, 0);
	for(i := 0; i < nriv; i++){
		r := riv[i];
		if(!r.live)
			continue;
		x := int r.x - cam - 8;
		if(x < -16 || x > W)
			continue;
		sput16(scr, x, int groundy(real r.lane) - 16, MLEVEL, prival, 0);
	}
	if(!norider)
		sput16(scr, int px - cam - 8,
			int (groundy(lanep) - z) - 16, machine(), pbike, 0);
	hud();
}

hud()
{
	scr.fill(Rect((0,0),(W, HUDH)), panel);
	scr.text(4, 4, trk.title, phud);
	scr.text(4, 16, "time " + clock(frames), phud);
	scr.text(4, 28, "best " + bestat(), phud);

	scr.text(128, 4, "speed", phud);
	bar(174, 4, int (spd * 100.0 / SPDTURBO), barlo);
	scr.text(128, 16, "heat", phud);
	hc := barlo;
	if(heat > 70.0)
		hc = barhi;
	bar(174, 16, int heat, hc);

	if(stall > 0)
		scr.text(128, 28, "seized", pwarn);
	else if(crash > 0)
		scr.text(128, 28, "down", pwarn);
	else if(done)
		scr.text(128, 28, finishword(), phud);
	else
		scr.text(128, 28, "lane " + string (lane+1), phud);
}

finishword(): string
{
	if(newbest)
		return "best!";
	return "finish";
}

# A gauge a hundred logical pixels wide, drawn as two fills rather than
# as tiles: it is not made of eight-pixel things and pretending it is
# would cost resolution the reading needs.
bar(x, y, v, c: int)
{
	if(v < 0)
		v = 0;
	if(v > 100)
		v = 100;
	scr.fill(Rect((x, y+1), (x+100, y+7)), tiles->entry(Tiles->DARK, Tiles->GREY));
	if(v > 0)
		scr.fill(Rect((x, y+1), (x+v, y+7)), c);
}

bestat(): string
{
	if(best == 0)
		return "--";
	return clock(best * 60 / 1000);
}

pad0(v, n: int): string
{
	if(v < 0)
		v = 0;
	s := string v;
	while(len s < n)
		s = "0" + s;
	return s;
}

clock(f: int): string
{
	ms := f * 1000 / 60;
	s := ms / 1000;
	return string (s/60) + ":" + pad0(s%60, 2) + "." + string ((ms%1000)/100);
}

# ------------------------------------------------------------ the race

raceloop()
{
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
			exit;
		}
		if(k == '\n' && done){
			restart();
			continue;
		}
		pad = kb.key(pad, k);
	<-ticks =>
		step();
		draw1();
		win.image.draw(win.image.r, scr.img, nil, scr.img.r.min);
		win.image.flush(Draw->Flushnow);
	}
}

# ----------------------------------------------------------- the design

curx, curlane, curkind, dirty: int;
msg: string;
REPEAT:	con 4;			# frames between repeats of a held key
rep:	int;

editloop()
{
	curx = 8;
	curlane = 0;
	curkind = FRAMP;
	msg = "arrows move, space places, d deletes, w writes";
	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q')
			exit;
		editkey(k);
		pad = kb.key(pad, k);
	<-ticks =>
		editstep();
		editdraw();
		win.image.draw(win.image.r, scr.img, nil, scr.img.r.min);
		win.image.flush(Draw->Flushnow);
	}
}

# The keys that act once, however long they are held.
editkey(k: int)
{
	case k {
	'[' =>	curkind = (curkind + NKIND - 1) % NKIND;
	']' =>	curkind = (curkind + 1) % NKIND;
	' ' =>	place();
	'\n' =>	place();
	'd' or 'D' or 8 or 16r7f =>
		unplace();
	'w' or 'W' =>
		e := writetrack(trk, trackfile);
		if(e != nil)
			msg = e;
		else{
			msg = "wrote " + trackfile;
			dirty = 0;
		}
	}
}

# And the ones that repeat.
editstep()
{
	if(rep > 0)
		rep--;
	if(rep == 0 && pad & (KLEFT|KRIGHT|KUP|KDOWN)){
		if(pad & KLEFT)
			curx--;
		if(pad & KRIGHT)
			curx++;
		if(pad & KUP)
			curlane--;
		if(pad & KDOWN)
			curlane++;
		if(curx < 0)
			curx = 0;
		if(curx > trk.length - 3)
			curx = trk.length - 3;
		if(curlane < 0)
			curlane = 0;
		if(curlane >= trk.lanes)
			curlane = trk.lanes - 1;
		rep = REPEAT;
	}
	if((pad & (KLEFT|KRIGHT|KUP|KDOWN)) == 0)
		rep = 0;
	cam = curx*8 - W/2;
	if(cam < 0)
		cam = 0;
	m := trk.length*8 - W;
	if(cam > m)
		cam = m;
}

place()
{
	# Everything the new feature will cover, not just the cell the
	# cursor is on: laying a four-tile mud next to a three-tile strip
	# left the two overlapping, and then the cell they shared belonged
	# to whichever came first in the list.
	clearspan(curx, featwide[curkind], curlane);
	arg := 0;
	if(curkind == FRIDER)
		arg = 190;
	addfeat(ref Feat(curx, curlane, curkind, arg));
	dirty = 1;
	msg = "placed " + featname[curkind];
	buildtrack();
	spawnrivals();
}

unplace()
{
	clearspan(curx, 1, curlane);
}

# Remove every feature in a lane that overlaps x to x+w.
clearspan(x, w, l: int)
{
	got := 0;
	for(i := 0; i < trk.n; ){
		f := trk.f[i];
		if(f.lane != l || f.x + featwide[f.kind] <= x || f.x >= x + w){
			i++;
			continue;
		}
		msg = "removed " + featname[f.kind];
		got = 1;
		for(j := i; j < trk.n - 1; j++)
			trk.f[j] = trk.f[j+1];
		trk.n--;
	}
	if(!got)
		return;
	dirty = 1;
	buildtrack();
	spawnrivals();
}

addfeat(f: ref Feat)
{
	if(trk.n >= len trk.f){
		n := 2 * len trk.f;
		if(n < 16)
			n = 16;
		a := array[n] of ref Feat;
		a[0:] = trk.f[0:trk.n];
		trk.f = a;
	}
	trk.f[trk.n++] = f;
}

editdraw()
{
	bg.view(scr, cam, 0);
	x := curx*8 - cam;
	y := int groundy(real curlane) - 16;
	w := featwide[curkind] * 8;
	c := tiles->entry(Tiles->PALE, Tiles->YELLOW);
	scr.fill(Rect((x, y), (x+w, y+1)), c);
	scr.fill(Rect((x, y+15), (x+w, y+16)), c);
	scr.fill(Rect((x, y), (x+1, y+16)), c);
	scr.fill(Rect((x+w-1, y), (x+w, y+16)), c);

	scr.fill(Rect((0,0),(W, HUDH)), panel);
	scr.text(4, 4, "design " + trk.title, phud);
	t := "at " + string curx + " lane " + string (curlane+1) + "  " + featname[curkind];
	if(dirty)
		t += " *";
	scr.text(4, 16, t, phud);
	scr.text(4, 28, msg, phud);
}

# --------------------------------------------------------- the track file

joinwords(l: list of string): string
{
	s := "";
	for(; l != nil; l = tl l){
		if(s != "")
			s += " ";
		s += hd l;
	}
	return s;
}

kindof(w: string): int
{
	for(i := 0; i < len featname; i++)
		if(featname[i] == w)
			return i;
	return -1;
}

readtrack(path: string): (ref Track, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return (nil, sys->sprint("cannot stat %s: %r", path));
	n := int d.length;
	if(n <= 0 || n > 1024*1024)
		return (nil, "unreasonable track file: " + path);
	b := array[n] of byte;
	if(sys->readn(fd, b, n) != n)
		return (nil, sys->sprint("cannot read %s: %r", path));

	t := ref Track("untitled", 0, 4, array[16] of ref Feat, 0);
	body := 0;
	ln := 0;
	(nil, lines) := sys->tokenize(string b, "\n");
	for(; lines != nil; lines = tl lines){
		ln++;
		line := hd lines;
		if(len line > 0 && line[0] == ';')
			continue;
		(nw, w) := sys->tokenize(line, " \t");
		if(nw == 0)
			continue;
		if(hd w == "%"){
			body = 1;
			continue;
		}
		where := sys->sprint("%s:%d: ", path, ln);
		if(!body){
			case hd w {
			"title" =>
				t.title = joinwords(tl w);
			"length" =>
				if(nw != 2)
					return (nil, where + "length wants one number");
				t.length = int hd tl w;
			"lanes" =>
				if(nw != 2)
					return (nil, where + "lanes wants one number");
				t.lanes = int hd tl w;
			* =>
				return (nil, where + "no such setting: " + hd w);
			}
			continue;
		}
		if(nw < 3)
			return (nil, where + "a feature is X LANE FEATURE [SPEED]");
		x := int hd w;
		l := int hd tl w;
		kw := hd tl tl w;
		k := kindof(kw);
		if(k < 0)
			return (nil, where + "no such feature: " + kw);
		arg := 0;
		if(nw > 3)
			arg = int hd tl tl tl w;
		if(l < 0 || l >= t.lanes)
			return (nil, where + "lane out of range: " + hd tl w);
		if(x < 0 || x + featwide[k] > t.length)
			return (nil, where + "off the end of the course: " + hd w);
		if(t.n >= len t.f){
			a := array[2 * len t.f] of ref Feat;
			a[0:] = t.f[0:t.n];
			t.f = a;
		}
		t.f[t.n++] = ref Feat(x, l, k, arg);
	}
	# The camera assumes there is more course than screen, and the
	# finish assumes there is room for it.
	if(t.length < W/8 + 4)
		return (nil, path + ": a course must be at least 36 tiles long");
	if(t.lanes < 1 || t.lanes > MAXLANE)
		return (nil, sys->sprint("%s: lanes must be 1 to %d", path, MAXLANE));
	return (t, nil);
}

writetrack(t: ref Track, path: string): string
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", path);
	sys->fprint(fd, "; A track for camber(1), written by camber -e.\n");
	sys->fprint(fd, "; Header, then %s, then one feature a line:\n", "%");
	sys->fprint(fd, ";\tX LANE FEATURE [SPEED]\n\n");
	sys->fprint(fd, "title %s\n", t.title);
	sys->fprint(fd, "length %d\n", t.length);
	sys->fprint(fd, "lanes %d\n\n%s\n\n", t.lanes, "%");
	# In course order, so a written file reads like the course does.
	# The list in memory is in whatever order editing left it.
	idx := array[t.n] of int;
	for(i := 0; i < t.n; i++)
		idx[i] = i;
	for(i = 1; i < t.n; i++){
		v := idx[i];
		j := i - 1;
		while(j >= 0 && key(t.f[idx[j]]) > key(t.f[v])){
			idx[j+1] = idx[j];
			j--;
		}
		idx[j+1] = v;
	}
	for(i = 0; i < t.n; i++){
		f := t.f[idx[i]];
		if(f.kind == FRIDER)
			sys->fprint(fd, "%d %d %s %d\n", f.x, f.lane,
				featname[f.kind], f.arg);
		else
			sys->fprint(fd, "%d %d %s\n", f.x, f.lane, featname[f.kind]);
	}
	return nil;
}

key(f: ref Feat): int
{
	return f.x * 16 + f.lane;
}

# ----------------------------------------------------------- screenshot

shot()
{
	audio = 0;
	restart();
	n := shotframes;
	if(n <= 0)
		n = 900;
	for(i := 0; i < n; i++){
		pad = KA;
		# level out after a launch, or every frame is a crash
		if(air && pitch > 0.0)
			pad |= KRIGHT;
		step();
		draw1();
	}
	w := scr.img.r.dx();
	h := scr.img.r.dy();
	b := array[w*h*3] of byte;
	if(scr.img.readpixels(scr.img.r, b) < 0){
		sys->print("readpixels: %r\n");
		return;
	}
	fd := sys->create("camber.raw", Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->print("create: %r\n");
		return;
	}
	sys->write(fd, b, len b);
	sys->print("wrote camber.raw %dx%d bgr\n", w, h);
}

# ---------------------------------------------------------------- test

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

run(n, held: int)
{
	for(i := 0; i < n; i++){
		pad = held;
		step();
		draw1();
	}
}

# A hash of one rectangle of the composed frame, for asking whether
# something is drawn there at all.  Counting lit pixels cannot answer
# that on a road: the road is already lit.
boxsum(r: Rect): int
{
	o := scr.img.r.min;
	q := Rect((o.x + r.min.x*SCALE, o.y + r.min.y*SCALE),
		(o.x + r.max.x*SCALE, o.y + r.max.y*SCALE));
	(cq, inside) := q.clip(scr.img.r);
	if(!inside)
		return -1;
	q = cq;
	w := q.dx();
	h := q.dy();
	if(w <= 0 || h <= 0)
		return -1;
	b := array[w*h*3] of byte;
	if(scr.img.readpixels(q, b) < 0)
		return -1;
	sum := 0;
	for(i := 0; i < len b; i += 3)
		sum = (sum * 31 + int b[i]) & 16r3FFFFFFF;
	return sum;
}

# Find the first feature of a kind, in any lane.
findfeat(k: int): ref Feat
{
	best2 := -1;
	f: ref Feat;
	for(i := 0; i < trk.n; i++){
		if(trk.f[i].kind != k)
			continue;
		if(best2 < 0 || trk.f[i].x < best2){
			best2 = trk.f[i].x;
			f = trk.f[i];
		}
	}
	return f;
}

nfeat: int;

clearcourse()
{
	nfeat = trk.n;
	trk.n = 0;
	restart();
}

restorecourse()
{
	trk.n = nfeat;
	restart();
}

# Put the machine on the ground at a feature, in that feature's lane,
# with a given speed, and nothing else going on.
putat(f: ref Feat, v: real)
{
	restart();
	lane = f.lane;
	lanep = real lane;
	px = real (f.x*8) - 8.0;
	spd = v;
	# the rivals are not what is being tested here
	for(i := 0; i < nriv; i++)
		riv[i].live = 0;
}

selftest()
{
	sys->print("camber: self test\n");
	audio = 0;

	# --- the track file, which is the point of this game ---
	cktrue("the track has a title", trk.title != "");
	cktrue("and a length", trk.length >= 36);
	cktrue("and lanes", trk.lanes >= 1 && trk.lanes <= MAXLANE);
	cktrue("and features", trk.n > 10);
	inrange := 1;
	for(i := 0; i < trk.n; i++){
		f := trk.f[i];
		if(f.lane < 0 || f.lane >= trk.lanes)
			inrange = 0;
		if(f.x < 0 || f.x + featwide[f.kind] > trk.length)
			inrange = 0;
	}
	cktrue("every feature is on the course", inrange);
	for(i = 0; i < NKIND; i++)
		cktrue("the course uses " + featname[i], findfeat(i) != nil);

	# A course survives being written and read again.  This is the
	# claim the whole design mode rests on, so it is asserted rather
	# than eyeballed.
	tmp := "camber-selftest.trk";
	e := writetrack(trk, tmp);
	cktrue("the course writes", e == nil);
	(t2, e2) := readtrack(tmp);
	if(t2 == nil)
		sys->print("\tit came back as: %s\n", e2);
	cktrue("and reads back", t2 != nil);
	if(t2 != nil){
		ck("with the same number of features", t2.n, trk.n);
		ck("the same length", t2.length, trk.length);
		ck("the same lanes", t2.lanes, trk.lanes);
		cktrue("and the same title", t2.title == trk.title);
		same := 1;
		for(i = 0; i < t2.n && i < trk.n; i++){
			a := t2.f[i];
			# written in course order, so find the match rather
			# than comparing position for position
			got := 0;
			for(j := 0; j < trk.n; j++){
				b := trk.f[j];
				if(a.x == b.x && a.lane == b.lane
				&& a.kind == b.kind && a.arg == b.arg)
					got = 1;
			}
			if(!got)
				same = 0;
		}
		cktrue("and every feature came back", same);
	}
	sys->remove(tmp);

	# A file that is wrong is refused, and says where.  Without this
	# the parser has never been seen to reject anything.
	bad := "camber-bad.trk";
	fd := sys->create(bad, Sys->OWRITE, 8r666);
	if(fd != nil){
		sys->fprint(fd, "title Bad\nlength 100\nlanes 4\n%s\n4 9 ramp\n", "%");
		fd = nil;
		(t3, e3) := readtrack(bad);
		cktrue("a lane out of range is refused", t3 == nil && e3 != nil);
		fd = sys->create(bad, Sys->OWRITE, 8r666);
		sys->fprint(fd, "title Bad\nlength 100\nlanes 4\n%s\n4 0 loop\n", "%");
		fd = nil;
		(t4, e4) := readtrack(bad);
		cktrue("an unknown feature is refused", t4 == nil && e4 != nil);
		fd = sys->create(bad, Sys->OWRITE, 8r666);
		sys->fprint(fd, "title Bad\nlength 10\nlanes 4\n%s\n", "%");
		fd = nil;
		(t5, e5) := readtrack(bad);
		cktrue("a course shorter than the screen is refused", t5 == nil && e5 != nil);
		sys->remove(bad);
	}

	# --- the throttle ---
	# On a clear stretch: run on the course as written, these measured a
	# crash, because holding the throttle with nobody flying the machine
	# reaches a ramp and lands it nose up.
	clearcourse();
	run(30, 0);
	ck("it does not move on its own", int px, 8);
	run(60, KA);
	cktrue("the throttle accelerates", spd > 1.0);
	run(200, KA);
	cktrue("and stops at the cruising speed", spd <= SPDCRUISE + 0.001);
	v := spd;
	restart();
	run(60, KB);
	cktrue("the hot throttle is faster", spd > v);
	cktrue("and it makes heat", heat > 0.0);

	# --- the gauge ---
	restart();
	h0 := 0.0;
	seized := 0;
	for(i = 0; i < 400; i++){
		run(1, KB);
		if(stall > 0){
			seized = 1;
			break;
		}
		h0 = heat;
	}
	cktrue("holding the hot throttle seizes it", seized);
	cktrue("and the gauge was full when it did", h0 > 90.0);
	if(seized){
		s0 := spd;
		run(20, KB);
		cktrue("a seized machine cannot be driven", spd < s0);
		run(STALL + 5, 0);
		ck("the seizure ends", stall, 0);
		cktrue("and the gauge is empty again", heat < 1.0);
	}
	# It cools when the hot throttle is let go.  Without this the gauge
	# would be a timer and not a decision.
	restart();
	run(40, KB);
	hh := heat;
	cktrue("the gauge rose", hh > 0.0);
	run(40, KA);
	cktrue("and falls off the hot throttle", heat < hh);

	# --- lanes ---
	restart();
	l0 := lane;
	pad = 0; prevpad = 0;
	run(1, KDOWN);
	ck("down moves out a lane", lane, l0+1);
	run(1, KDOWN);
	ck("and a held key does not keep moving", lane, l0+1);
	pad = 0; prevpad = 0; step();
	run(1, KDOWN);
	ck("a second press does", lane, l0+2);
	for(i = 0; i < 10; i++){
		pad = 0; prevpad = 0; step();
		run(1, KDOWN);
	}
	ck("and it stops at the inside", lane, trk.lanes-1);
	for(i = 0; i < 10; i++){
		pad = 0; prevpad = 0; step();
		run(1, KUP);
	}
	ck("and at the outside", lane, 0);
	restorecourse();

	# --- ramps, attitude, and the landing ---
	rf := findfeat(FRAMP);
	cktrue("there is a ramp to test", rf != nil);
	if(rf != nil){
		putat(rf, SPDCRUISE);
		flew := 0;
		for(i = 0; i < 60; i++){
			run(1, 0);
			if(air){
				flew = 1;
				break;
			}
		}
		cktrue("a ramp launches it", flew);
		cktrue("and throws the nose up", pitch > 0.0);
		top := 0.0;
		for(i = 0; i < 200 && air; i++){
			run(1, 0);
			if(z > top)
				top = z;
		}
		cktrue("it leaves the ground", top > 4.0);
		cktrue("and comes back down", !air);
		cktrue("nose up on landing puts it down", crash > 0);

		# Now the same launch, flown properly.
		putat(rf, SPDCRUISE);
		for(i = 0; i < 60 && !air; i++)
			run(1, 0);
		cktrue("launched again", air);
		for(i = 0; i < 200 && air; i++){
			held := 0;
			if(pitch > 0.0)
				held = KRIGHT;
			run(1, held);
		}
		ck("levelling out lands it clean", crash, 0);

		# A ramp at a standstill does nothing, which is what stops
		# a stopped machine hopping in place for ever.
		putat(rf, 0.0);
		run(1, 0);
		ck("a ramp does nothing at a standstill", air, 0);
	}

	# --- mud and strips ---
	mf := findfeat(FMUD);
	cktrue("there is mud to test", mf != nil);
	if(mf != nil){
		putat(mf, SPDCRUISE);
		run(8, KA);
		cktrue("mud slows it below the cruising speed", spd < SPDCRUISE);
		cktrue("and holds it down", spd <= MUDCAP + 0.001);
	}
	sf := findfeat(FSTRIP);
	cktrue("there is a strip to test", sf != nil);
	if(sf != nil){
		putat(sf, 1.0);
		s0 := spd;
		run(3, 0);
		cktrue("a strip speeds it up", spd > s0);
	}

	# --- rivals ---
	restart();
	cktrue("the course put rivals out", nriv > 0);
	if(nriv > 0){
		restart();
		r := riv[0];
		lane = r.lane;
		lanep = real lane;
		px = r.x;
		spd = 2.0;
		air = 0;
		z = 0.0;
		run(1, 0);
		cktrue("touching a rival puts you down", crash > 0);
		# and clearing one in the air does not
		restart();
		r = riv[0];
		lane = r.lane;
		lanep = real lane;
		px = r.x;
		spd = 2.0;
		air = 1;
		z = 20.0;
		vz = 1.0;
		run(1, 0);
		ck("clearing one in the air does not", crash, 0);
	}

	# --- the course is finishable, and is not finished by doing nothing ---
	restart();
	got := 0;
	for(i = 0; i < 6000; i++){
		held := KA;
		if(air && pitch > 0.0)
			held |= KRIGHT;
		run(1, held);
		if(done){
			got = 1;
			break;
		}
	}
	cktrue("the course can be finished", got);
	cktrue("and it took some time to do it", timems > 5000);
	# The negative control for that: the same loop, no throttle. If this
	# ever passes, "the course can be finished" is not testing anything.
	restart();
	idle := 0;
	for(i = 0; i < 6000; i++){
		run(1, 0);
		if(done){
			idle = 1;
			break;
		}
	}
	ck("and is not finished by doing nothing", idle, 0);

	# --- the machine is actually drawn ---
	# This is here because a game in this tree once shipped with an
	# if(0) around the enemies and thirty-eight state assertions passed.
	# A state check cannot see a picture; this reads the pixels back.
	restart();
	run(40, KA);
	box := Rect((int px - cam - 8, int (groundy(lanep) - z) - 16),
		(int px - cam + 8, int groundy(lanep)));
	norider = 0;
	draw1();
	with := boxsum(box);
	norider = 1;
	draw1();
	without := boxsum(box);
	norider = 0;
	cktrue("the frame could be read back", with >= 0 && without >= 0);
	cktrue("the machine is drawn where the rules say it is", with != without);
	# And the course behind it is painted.  Two hashes of the same
	# rectangle with the background window in two places: were the
	# course a flat field they would be equal.
	#
	# This went through draw1() at first, which meant it was reading the
	# rivals - they are at different places at the two camera positions,
	# so it passed with the whole course painting stubbed out.  The
	# background is read on its own here for that reason.
	lanes := Rect((0, LTOP), (W, H));
	bg.view(scr, 0, 0);
	a := boxsum(lanes);
	bg.view(scr, 400, 0);
	b := boxsum(lanes);
	cktrue("the course is painted, not a flat field", a >= 0 && a != b);

	# And a composed frame shows it, against a field of the colour the
	# surface was made with - which is flat by construction, so this
	# cannot pass on a frame that drew nothing.
	cam = 0;
	draw1();
	f1 := boxsum(lanes);
	scr.fill(lanes, verge);
	f0 := boxsum(lanes);
	cktrue("and a frame shows it", f1 >= 0 && f1 != f0);

	# --- the design mode ---
	# The editing itself, without a window: place() and unplace() are
	# what the keys in editloop() call, so this covers everything about
	# the design mode except the key bindings.
	restorecourse();
	n0 := trk.n;
	curlane = 0;
	# A clear stretch, found rather than guessed: the first guess was
	# trk.length-20, which the course's closing row of strips already
	# covered, so the checks below were measuring that strip.
	curx = -1;
	for(i = 0; i + featwide[FMUD] < trk.length - 4; i++){
		clear := 1;
		for(j := 0; j < featwide[FMUD]; j++)
			if(featat((i+j)*8, curlane) != nil)
				clear = 0;
		if(clear){
			curx = i;
			break;
		}
	}
	cktrue("there is a clear stretch to edit", curx >= 0);
	curkind = FRAMP;
	place();
	ck("placing adds a feature", trk.n, n0+1);
	f2 := featat(curx*8, curlane);
	cktrue("and it is where it was put", f2 != nil && f2.kind == FRAMP);
	# Placing on top of something replaces it rather than stacking two
	# features in one cell, which nothing downstream could draw.
	curkind = FMUD;
	place();
	ck("placing on top of one replaces it", trk.n, n0+1);
	f2 = featat(curx*8, curlane);
	cktrue("with the new one", f2 != nil && f2.kind == FMUD);
	# A wide feature is found from any cell it covers, not just its first.
	f2 = featat((curx + featwide[FMUD] - 1)*8, curlane);
	cktrue("a wide feature covers all its cells", f2 != nil && f2.kind == FMUD);
	curx += featwide[FMUD] - 1;
	unplace();
	ck("deleting from its far cell removes it", trk.n, n0);
	curx -= featwide[FMUD] - 1;
	cktrue("and the cell is clear", featat(curx*8, curlane) == nil);
	# A rider placed in the design mode is a rider in the race.
	nr0 := nriv;
	curkind = FRIDER;
	place();
	restart();
	ck("placing a rider puts one on the course", nriv, nr0+1);
	unplace();
	restart();
	ck("and removing it takes it off again", nriv, nr0);
	ck("the course is as it was", trk.n, n0);

	# And the designer's own picture, which nothing above draws.  Two
	# frames with the cursor in two lanes: the background window is the
	# same in both, so the only thing that can differ is the cursor.
	curx = 20;
	curlane = 0;
	curkind = FRAMP;
	pad = 0;
	editstep();
	editdraw();
	d1 := boxsum(Rect((0, LTOP), (W, H)));
	curlane = 2;
	editstep();
	editdraw();
	d2 := boxsum(Rect((0, LTOP), (W, H)));
	cktrue("the designer draws its cursor where the cursor is",
		d1 >= 0 && d1 != d2);

	if(nfail == 0)
		sys->print("camber: PASSED\n");
	else{
		sys->print("camber: FAILED (%d)\n", nfail);
		raise "fail:test";
	}
}
