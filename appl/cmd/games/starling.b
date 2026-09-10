implement Starling;

# Starling - a fixed shooter in the shape that genre took: a ship at the
# bottom of the screen that only moves sideways, attackers that fly in
# along a curve, settle into a swaying formation, and peel off it one at
# a time to dive at you and drop something on the way past.
#
# Of the three games on tiles(2) this is the one that tests how many
# sprites the library can actually put on a screen: a full formation is
# forty 16x16 characters, which is 160 tile blits a frame before the
# shots and the stars.  Run it with INFERNO_FPS set and frameclock(2)
# will say what rate it really managed.

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

include "rand.m";
	rand: Rand;

include "keyhold.m";
	keyhold: Keyhold;
	Binding: import keyhold;

include "tone.m";
	tone: Tone;

include "tiles.m";
	tiles: Tiles;
	Chr, Pal, Surface: import tiles;

include "frameclock.m";
	fclock: Frameclock;

include "scorestore.m";
	scorestore: Scorestore;

Starling: module
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
	return testmode == 0;
}

SCALE:	con 2;
W:	con Tiles->W;
H:	con Tiles->H;

TSHOT, TBOMB, TSTAR: con iota;		# 8x8
TSHIP:	con 3;				# 16x16 from here
TFOE1:	con 7;
TFOE2:	con 11;
TBOSS1:	con 15;
TBOSS2:	con 19;
TBOOM1:	con 23;
TBOOM2:	con 27;

SMALL := array[] of {
	# 0 shot
	"...11...", "..1331..", "..1331..", "..1331..",
	"..1331..", "...11...", "........", "........",
	# 1 bomb
	"........", "..1111..", ".133331.", ".132231.",
	".133331.", "..1111..", "........", "........",
	# 2 star
	"........", "...1....", "..131...", ".13331..",
	"..131...", "...1....", "........", "........",
};

BIG := array[] of {
	# 3 the ship
	"................",
	".......11.......",
	".......13.......",
	"......1331......",
	"......1331......",
	"......1331......",
	".....133331.....",
	".....132231.....",
	"....13322331....",
	"...1332222331...",
	"..133222222331..",
	".13322222222331.",
	".13222222222231.",
	".11.1111111.11..",
	"..1..11111..1...",
	"......1.1.......",
	# 7 attacker, wings up
	"................",
	"..11........11..",
	"..131......131..",
	"..1331....1331..",
	"...13311113311..",
	"...1332222331...",
	"..133122221331..",
	"..132133331231..",
	"..132133331231..",
	"..133122221331..",
	"...1332222331...",
	"...13311113311..",
	"..1331....1331..",
	"..131......131..",
	"..11........11..",
	"................",
	# 11 attacker, wings down
	"................",
	"................",
	"................",
	"...11......11...",
	"...131....131...",
	"...13311113311..",
	"...1332222331...",
	"..133122221331..",
	"..132133331231..",
	"..133122221331..",
	"...1332222331...",
	"...13311113311..",
	"...131....131...",
	"...11......11...",
	"................",
	"................",
	# 15 leader, wings up
	"................",
	".11..........11.",
	".131........131.",
	".1331......1331.",
	".13331....13331.",
	"..1333111133 31.",
	"..1333222233 1..",
	".13332222223 31.",
	".13322333322 31.",
	".13322333322 31.",
	".13332222223 31.",
	"..1333222233 1..",
	"..1333111133 31.",
	".13331....13331.",
	".1331......1331.",
	".11..........11.",
	# 19 leader, wings down
	"................",
	"................",
	"..11........11..",
	"..131......131..",
	"..1331....1331..",
	"...133111133 1..",
	"...13322223331..",
	"..1333222223 1..",
	"..1332233332231.",
	"..1333222223 1..",
	"...13322223331..",
	"...133111133 1..",
	"..1331....1331..",
	"..131......131..",
	"..11........11..",
	"................",
	# 23 hit, first
	"................",
	"................",
	".....1....1.....",
	"....131..131....",
	"...1333113331...",
	"....13333331....",
	".....133331.....",
	"....13333331....",
	"...1333333331...",
	"....13333331....",
	".....133331.....",
	"....13333331....",
	"...1333113331...",
	"....131..131....",
	".....1....1.....",
	"................",
	# 27 hit, second
	"................",
	"..1..........1..",
	"...1...11...1...",
	"....1.1331.1....",
	"..1..1333311..1.",
	"...11133331111..",
	"....1333333 1...",
	"..11333333331 ..",
	".1.13333333331.1",
	"..11333333331...",
	"....1333333 1...",
	"...11133331111..",
	"..1..1333311..1.",
	"....1.1331.1....",
	"...1...11...1...",
	"..1..........1..",
};

# formation
COLS:	con 8;
ROWS:	con 5;
NFOE:	con COLS*ROWS;
FX0:	con 32;			# left of the formation
FDX:	con 24;
FY0:	con 40;
FDY:	con 20;

# attacker states
GONE, ENTER, SLOT, DIVE: con iota;

Foe: adt {
	x, y:	real;
	vx, vy:	real;
	st:	int;
	col, row: int;
	t:	int;
	side:	int;		# which edge it entered from
	boom:	int;		# frames of explosion left
	leader:	int;
};

Shot: adt {
	x, y:	real;
	vy:	real;
	live:	int;
	mine:	int;
};

NSHOT:	con 24;
NSTAR:	con 48;

win: ref Window;
scr: ref Surface;
sheet, fnt: ref Chr;
pship, pfoe, pboss, pboom, pshot, pbomb, pstar, phud, pflash: ref Pal;

foes: array of ref Foe;
shots: array of ref Shot;
starx, stary, starv: array of int;

sx, sv: real;
lives := 3;
score := 0;
best := 0;
wave := 1;
frames := 0;
dead := 0;
clear := 0;
alive := 0;
firecool := 0;
divecool := 0;
pad := 0;
prevpad := 0;
audio := 0;
testmode := 0;
seed := 12345;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	keyhold = load Keyhold Keyhold->PATH;
	tone = load Tone Tone->PATH;
	kb = keyhold->mk(BINDS);
	tiles = load Tiles Tiles->PATH;
	rand = load Rand Rand->PATH;
	fclock = load Frameclock Frameclock->PATH;
	scorestore = load Scorestore Scorestore->PATH;
	if(tiles == nil){
		sys->fprint(sys->fildes(2), "starling: cannot load tiles: %r\n");
		raise "fail:load";
	}
	e := tiles->init();
	if(e != nil){
		sys->fprint(sys->fildes(2), "starling: %s\n", e);
		raise "fail:init";
	}
	if(fclock != nil)
		fclock->init();
	for(a := tl argv; a != nil; a = tl a){
		case hd a {
		"-t" =>	testmode = 1;
		"-s" =>	testmode = 2;
		"-b" =>	testmode = 3;
		"-q" =>	audio = -1;
		}
	}
	d: ref Display;
	if(testmode){
		d = Display.allocate(nil);
		if(d == nil){
			sys->fprint(sys->fildes(2), "starling: no display: %r\n");
			raise "fail:display";
		}
	}else{
		wmclient = load Wmclient Wmclient->PATH;
		sys->pctl(Sys->NEWPGRP, nil);
		wmclient->init();
		if(ctxt == nil)
			ctxt = wmclient->makedrawcontext();
		win = wmclient->window(ctxt, "Starling", Wmclient->Appl);
		d = win.display;
		seed = sys->millisec();
	}
	setup(d);
	if(scorestore != nil)
		best = scorestore->loadint("starling", 0);
	# Only when actually playing.  tone(2)'s sfx() is silent until
	# init() has succeeded, so the self test and the screenshot modes
	# make no sound and spawn nothing by simply not asking for any.
	if(audio == 0 && playing() && tone != nil && tone->init() == nil)
		audio = 1;
	newgame();
	if(testmode == 1){
		selftest();
		return;
	}
	if(testmode == 2){
		shot();
		return;
	}
	if(testmode == 3){
		bench();
		return;
	}
	win.reshape(Rect((0,0),(W*SCALE, H*SCALE)));
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
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q'){
			tone->stop();
			if(score > best && scorestore != nil)
				scorestore->saveint("starling", score);
			if(fclock != nil)
				fclock->report("starling");
			exit;
		}
		pad = kb.key(pad, k);
	<-ticks =>
		step();
		draw1();
		win.image.draw(win.image.r, scr.img, nil, scr.img.r.min);
		win.image.flush(Draw->Flushnow);
	}
}

setup(d: ref Display)
{
	art := array[len SMALL + 4*8*(len BIG / 16)] of string;
	art[0:] = SMALL;
	art[len SMALL:] = tiles->meta(BIG);
	sheet = tiles->chr(d, Draw->RGB24, SCALE, art);
	fnt = tiles->font(d, Draw->RGB24, SCALE);
	sky := tiles->entry(Tiles->DARK, Tiles->BLACK);
	pship = tiles->pal(sky, tiles->entry(Tiles->PALE, Tiles->GREY),
		tiles->entry(Tiles->MID, Tiles->CYAN), tiles->entry(Tiles->LIGHT, Tiles->AZURE));
	pfoe = tiles->pal(sky, tiles->entry(Tiles->PALE, Tiles->YELLOW),
		tiles->entry(Tiles->MID, Tiles->RED), tiles->entry(Tiles->LIGHT, Tiles->ORANGE));
	pboss = tiles->pal(sky, tiles->entry(Tiles->PALE, Tiles->CYAN),
		tiles->entry(Tiles->MID, Tiles->VIOLET), tiles->entry(Tiles->LIGHT, Tiles->MAGENTA));
	pboom = tiles->pal(sky, tiles->entry(Tiles->PALE, Tiles->YELLOW),
		tiles->entry(Tiles->PALE, Tiles->YELLOW), tiles->entry(Tiles->LIGHT, Tiles->ORANGE));
	pshot = tiles->pal(sky, tiles->entry(Tiles->PALE, Tiles->GREY),
		tiles->entry(Tiles->PALE, Tiles->CYAN), tiles->entry(Tiles->LIGHT, Tiles->CYAN));
	pbomb = tiles->pal(sky, tiles->entry(Tiles->PALE, Tiles->ROSE),
		tiles->entry(Tiles->MID, Tiles->MAGENTA), tiles->entry(Tiles->LIGHT, Tiles->RED));
	pstar = tiles->pal(sky, tiles->entry(Tiles->MID, Tiles->GREY),
		tiles->entry(Tiles->PALE, Tiles->GREY), tiles->entry(Tiles->LIGHT, Tiles->GREY));
	phud = tiles->pal(sky, tiles->entry(Tiles->PALE, Tiles->GREY),
		tiles->entry(Tiles->PALE, Tiles->GREY), tiles->entry(Tiles->PALE, Tiles->GREY));
	pflash = tiles->pal(sky, tiles->entry(Tiles->PALE, Tiles->YELLOW),
		tiles->entry(Tiles->PALE, Tiles->YELLOW), tiles->entry(Tiles->PALE, Tiles->YELLOW));
	scr = tiles->surface(d, sheet, fnt, W, H, sky);
}

# A repeatable generator, so -t sees the same waves every run.  rand(2)
# would do, but a test that plays a different game each time is not a
# test of anything in particular.
nextrand(n: int): int
{
	seed = (seed * 1103515245 + 12345) & 16r3FFFFFFF;
	if(n <= 0)
		return 0;
	return seed % n;
}

newgame()
{
	lives = 3;
	score = 0;
	wave = 1;
	newwave();
}

newwave()
{
	foes = array[NFOE] of ref Foe;
	shots = array[NSHOT] of ref Shot;
	starx = array[NSTAR] of int;
	stary = array[NSTAR] of int;
	starv = array[NSTAR] of int;
	for(i := 0; i < NSTAR; i++){
		starx[i] = nextrand(W);
		stary[i] = nextrand(H);
		starv[i] = 1 + nextrand(3);
	}
	for(r := 0; r < ROWS; r++){
		for(c := 0; c < COLS; c++){
			f := ref Foe;
			f.col = c;
			f.row = r;
			f.st = ENTER;
			# Staggered, and alternate rows come in from opposite
			# sides: that is what makes an entry read as a formation
			# arriving rather than as forty things appearing.
			f.t = -(r*COLS + c)*5 - (r&1)*20;
			f.side = 1;
			if((r & 1) != 0)
				f.side = -1;
			f.leader = 0;
			if(r == 0)
				f.leader = 1;
			f.x = real (slotx(c, 0));
			f.y = -20.0;
			f.boom = 0;
			foes[r*COLS + c] = f;
		}
	}
	sx = real (W/2 - 8);
	sv = 0.0;
	frames = 0;
	dead = 0;
	clear = 0;
	firecool = 0;
	divecool = 180;
	pad = 0;
	prevpad = 0;
	alive = NFOE;
}

slotx(c, t: int): int
{
	sway := int (12.0 * math->sin(real t / 48.0));
	return FX0 + c*FDX + sway;
}

sloty(r: int): int
{
	return FY0 + r*FDY;
}

step()
{
	frames++;
	tone->sfxtick();
	for(i := 0; i < NSTAR; i++){
		stary[i] += starv[i];
		if(stary[i] >= H){
			stary[i] = 0;
			starx[i] = nextrand(W);
		}
	}
	if(dead > 0){
		dead--;
		stepfoes();
		if(dead == 0){
			if(lives <= 0)
				newgame();
			else
				respawn();
		}
		return;
	}
	if(clear > 0){
		clear--;
		if(clear == 0){
			wave++;
			newwave();
		}
		return;
	}
	stepship();
	stepfoes();
	stepshots();
	if(alive == 0 && clear == 0){
		clear = 120;
		score += 1000;
		tone->sfx(4, 1300, 400);
	}
	prevpad = pad;
}

respawn()
{
	sx = real (W/2 - 8);
	sv = 0.0;
	for(i := 0; i < NSHOT; i++)
		shots[i] = nil;
}

SHIPV:	con 2.0;

stepship()
{
	if((pad & KLEFT) && !(pad & KRIGHT))
		sx -= SHIPV;
	else if((pad & KRIGHT) && !(pad & KLEFT))
		sx += SHIPV;
	if(sx < 0.0)
		sx = 0.0;
	if(sx > real (W-16))
		sx = real (W-16);
	if(firecool > 0)
		firecool--;
	if((pad & KA) && firecool == 0 && nmine() < 2){
		fire(sx + 4.0, real (H-32), -4.5, 1);
		firecool = 8;
		tone->sfx(2, 1200, 40);
	}
}

nmine(): int
{
	n := 0;
	for(i := 0; i < NSHOT; i++)
		if(shots[i] != nil && shots[i].live && shots[i].mine)
			n++;
	return n;
}

fire(x, y, vy: real, mine: int)
{
	for(i := 0; i < NSHOT; i++){
		if(shots[i] != nil && shots[i].live)
			continue;
		s := ref Shot;
		s.x = x;
		s.y = y;
		s.vy = vy;
		s.live = 1;
		s.mine = mine;
		shots[i] = s;
		return;
	}
}

stepshots()
{
	for(i := 0; i < NSHOT; i++){
		s := shots[i];
		if(s == nil || !s.live)
			continue;
		s.y += s.vy;
		if(s.y < -8.0 || s.y > real H){
			s.live = 0;
			continue;
		}
		if(s.mine){
			for(j := 0; j < NFOE; j++){
				f := foes[j];
				if(f == nil || f.st == GONE || f.boom > 0)
					continue;
				if(!near(int s.x, int s.y, 8, 8, int f.x, int f.y, 16, 16))
					continue;
				s.live = 0;
				f.boom = 24;
				alive--;
				v := 100;
				if(f.leader)
					v = 200;
				if(f.st == DIVE)
					v *= 2;
				score += v;
				tone->sfx(3, 500, 90);
				break;
			}
		}else if(dead == 0
		&& near(int s.x, int s.y, 8, 8, int sx, int sy(), 16, 14)){
			s.live = 0;
			hurt();
		}
	}
}

sy(): int
{
	return H-32;
}

near(ax, ay, aw, ah, bx, by, bw, bh: int): int
{
	return ax + aw > bx && ax < bx + bw && ay + ah > by && ay < by + bh;
}

ENTERT:	con 96;			# frames of arc before heading for the slot
SETTLE:	con 40;

stepfoes()
{
	if(divecool > 0)
		divecool--;
	if(divecool == 0 && dead == 0 && clear == 0){
		startdive();
		divecool = 150 - wave*12;
		if(divecool < 40)
			divecool = 40;
	}
	for(i := 0; i < NFOE; i++){
		f := foes[i];
		if(f == nil || f.st == GONE)
			continue;
		if(f.boom > 0){
			if(--f.boom == 0)
				f.st = GONE;
			continue;
		}
		f.t++;
		case f.st {
		ENTER =>
			if(f.t <= 0)
				break;
			if(f.t < ENTERT){
				# a quarter turn in from the side, then a loop
				a := real f.t / 14.0;
				f.x = real (W/2) + real f.side * (real (W/2 + 16)
					- 60.0*a) * math->cos(a) - 8.0;
				f.y = 20.0 + 40.0 * a;
				if(f.y > real (H - 60))
					f.y = real (H - 60);
			}else{
				u := real (f.t - ENTERT) / real SETTLE;
				if(u >= 1.0){
					f.st = SLOT;
					break;
				}
				f.x = f.x + (real slotx(f.col, frames) - f.x) * u * 0.35;
				f.y = f.y + (real sloty(f.row) - f.y) * u * 0.35;
			}
		SLOT =>
			f.x = real slotx(f.col, frames);
			f.y = real sloty(f.row);
		DIVE =>
			f.vy += 0.06;
			if(f.vy > 3.2)
				f.vy = 3.2;
			# steer towards where the ship is, but weakly, so a
			# dive is a threat and not a homing missile
			d := sx - f.x;
			if(d > 0.0)
				f.vx += 0.05;
			else
				f.vx -= 0.05;
			if(f.vx > 1.6)
				f.vx = 1.6;
			if(f.vx < -1.6)
				f.vx = -1.6;
			f.x += f.vx;
			f.y += f.vy;
			if(f.t % 40 == 0 && f.y < real (H - 80))
				fire(f.x + 4.0, f.y + 12.0, 2.4, 0);
			if(f.y > real H){
				# round the top and rejoin the formation
				f.y = -20.0;
				f.x = real slotx(f.col, frames);
				f.st = ENTER;
				f.t = ENTERT - 1;
				f.vx = 0.0;
				f.vy = 0.0;
			}
		}
		if(dead == 0 && clear == 0 && f.st != GONE && f.boom == 0
		&& near(int f.x, int f.y, 16, 16, int sx, sy(), 16, 14))
			hurt();
	}
}

startdive()
{
	n := 0;
	for(i := 0; i < NFOE; i++)
		if(foes[i] != nil && foes[i].st == SLOT && foes[i].boom == 0)
			n++;
	if(n == 0)
		return;
	k := nextrand(n);
	for(i = 0; i < NFOE; i++){
		f := foes[i];
		if(f == nil || f.st != SLOT || f.boom != 0)
			continue;
		if(k-- > 0)
			continue;
		f.st = DIVE;
		f.t = 0;
		f.vx = 0.0;
		f.vy = 1.0;
		tone->sfx(1, 380, 120);
		return;
	}
}

hurt()
{
	if(dead > 0)
		return;
	lives--;
	dead = 110;
	tone->sfx(5, 160, 500);
}

# ------------------------------------------------------------------ draw

draw1()
{
	scr.fill(Rect((0,0),(W,H)), tiles->entry(Tiles->DARK, Tiles->BLACK));
	for(i := 0; i < NSTAR; i++)
		scr.put(starx[i], stary[i], TSTAR, pstar, 0);
	for(i = 0; i < NSHOT; i++){
		s := shots[i];
		if(s == nil || !s.live)
			continue;
		if(s.mine)
			scr.put(int s.x, int s.y, TSHOT, pshot, 0);
		else
			scr.put(int s.x, int s.y, TBOMB, pbomb, 0);
	}
	for(i = 0; i < NFOE; i++){
		f := foes[i];
		if(f == nil || f.st == GONE)
			continue;
		if(f.t <= 0 && f.st == ENTER)
			continue;
		p := pfoe;
		t := TFOE1;
		if(f.leader){
			p = pboss;
			t = TBOSS1;
		}
		if(f.boom > 0){
			p = pboom;
			t = TBOOM1;
			if((f.boom / 6 & 1) != 0)
				t = TBOOM2;
		}else if((frames / 12 & 1) != 0)
			t += 4;
		scr.put16(int f.x, int f.y, t, p, 0);
	}
	if(dead == 0 || (dead & 4) != 0)
		scr.put16(int sx, sy(), TSHIP, pship, 0);
	hud();
}

hud()
{
	scr.text(8, 4, "SCORE " + pad0(score, 6), phud);
	scr.text(8*16, 4, "WAVE " + pad0(wave, 2), phud);
	scr.text(8*25, 4, "SHIPS " + pad0(lives, 1), phud);
	if(dead > 0 && lives <= 0)
		scr.text(8*11, 8*15, "GAME OVER", pflash);
	if(clear > 0)
		scr.text(8*10, 8*15, "WAVE CLEARED", pflash);
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

shot()
{
	audio = 0;
	newgame();
	for(i := 0; i < 260; i++){
		pad = KA;
		if((i / 40 & 1) != 0)
			pad |= KRIGHT;
		else
			pad |= KLEFT;
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
	fd := sys->create("starling.raw", Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->print("create: %r\n");
		return;
	}
	sys->write(fd, b, len b);
	sys->print("wrote starling.raw %dx%d bgr\n", w, h);
}

# -b: what a full screen of sprites actually costs.  A settled formation
# is forty 16x16 characters - a hundred and sixty tile blits - plus the
# shots and forty-eight stars, drawn into memory with no window and no
# frame pacing, so the number is the work and not the wait.
bench()
{
	audio = 0;
	newgame();
	divecool = 1000000;
	for(i := 0; i < 900 && nstate(SLOT) < NFOE; i++){
		pad = 0;
		step();
		draw1();
	}
	n := nstate(SLOT);
	N: con 300;
	t0 := sys->millisec();
	for(i = 0; i < N; i++){
		pad = 0;
		step();
		draw1();
	}
	t1 := sys->millisec();
	us := (t1 - t0) * 1000 / N;
	sys->print("starling: %d attackers, %d stars: %d us a frame", n, NSTAR, us);
	if(us > 0)
		sys->print(", %d frames a second", 1000000 / us);
	sys->print("\n");
	if(us > 16666)
		sys->print("starling: SLOWER THAN 60Hz\n");
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

run(n: int, held: int)
{
	for(i := 0; i < n; i++){
		pad = held;
		step();
		draw1();
	}
}

# Let the formation arrive with the dives held off.  Without this the
# test spends six hundred frames sitting still under attack, loses every
# ship to a diver, and then measures a ship that cannot move because
# step() is in its dead branch - which reads as eight unrelated
# failures.  divecool is the game's own knob; nothing test-only is added
# to the game for this.
settle()
{
	divecool = 1000000;
	for(i := 0; i < 900 && nstate(SLOT) < NFOE; i++)
		run(1, 0);
}

nstate(st: int): int
{
	n := 0;
	for(i := 0; i < NFOE; i++)
		if(foes[i] != nil && foes[i].st == st && foes[i].boom == 0)
			n++;
	return n;
}

selftest()
{
	sys->print("starling: self test\n");
	audio = 0;
	newgame();
	ck("a full formation", alive, NFOE);
	ck("all of it entering", nstate(ENTER), NFOE);

	# The whole formation reaches its slots, and sits in them.
	settle();
	ck("every attacker reached its slot", nstate(SLOT), NFOE);
	# and the slots are the formation, swaying together
	f0 := foes[0];
	f1 := foes[1];
	ck("neighbours are one column apart",
		int f1.x - int f0.x, FDX);
	ck("rows are one row apart",
		int foes[COLS].y - int f0.y, FDY);
	x0 := int f0.x;
	sw := 0;
	for(i := 0; i < 120; i++){
		run(1, 0);
		if(int f0.x != x0)
			sw = 1;
	}
	cktrue("the formation sways", sw);
	cktrue("and stays on screen", int f0.x >= 0 && int f0.x < W-16);

	# The ship moves and is stopped by both walls.
	x := int sx;
	run(10, KRIGHT);
	ck("the ship moves right", int sx, x + 10*int SHIPV);
	run(400, KLEFT);
	ck("and stops at the left wall", int sx, 0);
	run(400, KRIGHT);
	ck("and at the right wall", int sx, W-16);

	# Firing: at most two of ours in the air, and a hit removes an
	# attacker and scores.
	run(30, 0);
	run(1, KA);
	run(2, KA);
	cktrue("firing makes a shot", nmine() >= 1);
	run(40, KA);
	cktrue("no more than two at once", nmine() <= 2);

	sc := score;
	al := alive;
	tgt := firstslot();
	cktrue("something to shoot at", tgt != nil);
	if(tgt != nil){
		fire(tgt.x + 4.0, tgt.y + 4.0, 0.0, 1);
		run(1, 0);
		cktrue("a hit starts an explosion", tgt.boom > 0);
		ck("and one fewer alive", alive, al-1);
		cktrue("and scores", score > sc);
		for(i = 0; i < 40 && tgt.st != GONE; i++)
			run(1, 0);
		ck("and the attacker goes", tgt.st, GONE);
	}

	# A dive leaves the formation and comes back round the top.
	newwave();
	settle();
	divecool = 1;
	run(2, 0);
	ck("one attacker is diving", nstate(DIVE), 1);
	dv := firstdive();
	cktrue("a diver was found", dv != nil);
	if(dv != nil){
		y0 := int dv.y;
		run(40, 0);
		cktrue("the diver comes down", int dv.y > y0);
		for(i = 0; i < 900 && dv.st == DIVE; i++)
			run(1, 0);
		cktrue("it leaves the dive", dv.st != DIVE);
		cktrue("and comes back at the top", int dv.y < H/2);
	}

	# A bomb, and a collision, both cost a ship.
	newwave();
	settle();
	lives = 3;
	lv := lives;
	fire(sx + 4.0, real (sy() - 4), 2.0, 0);
	run(2, 0);
	ck("a bomb costs a ship", lives, lv-1);
	for(i = 0; i < 130; i++)
		run(1, 0);
	lv = lives;
	f := firstslot();
	if(f != nil){
		f.st = DIVE;
		f.x = sx;
		f.y = real sy();
		f.vx = 0.0;
		f.vy = 0.0;
		run(1, 0);
		ck("a collision costs a ship", lives, lv-1);
	}

	# Clearing the formation ends the wave and the next is faster.
	newwave();
	d0 := 150 - wave*12;
	for(i = 0; i < NFOE; i++)
		if(foes[i] != nil){
			foes[i].st = GONE;
			foes[i].boom = 0;
		}
	alive = 0;
	run(1, 0);
	cktrue("an empty formation clears the wave", clear > 0);
	w0 := wave;
	run(125, 0);
	ck("the wave advances", wave, w0+1);
	cktrue("and dives come sooner", 150 - wave*12 < d0);

	if(nfail == 0)
		sys->print("starling: PASSED\n");
	else{
		sys->print("starling: FAILED (%d)\n", nfail);
		raise "fail:test";
	}
}

firstslot(): ref Foe
{
	for(i := 0; i < NFOE; i++)
		if(foes[i] != nil && foes[i].st == SLOT && foes[i].boom == 0)
			return foes[i];
	return nil;
}

firstdive(): ref Foe
{
	for(i := 0; i < NFOE; i++)
		if(foes[i] != nil && foes[i].st == DIVE && foes[i].boom == 0)
			return foes[i];
	return nil;
}
