implement Sprig;

#
# Sprig - a fixed screen where everything comes down at you: a thing on
# a stalk working its way toward the garden, swarms of small fast things
# dropping out of the air, and a spray that runs out.  The whole game is
# deciding when NOT to fire.
#
# What this one is for is the processes.  An entity here is a Dis
# process: each pest runs its own loop, waits on a channel for the
# frame, moves itself, and answers.  That is the obvious Inferno reading
# of "many small independent things at once", and it was not obvious
# that it was affordable - execution here is serialised, not parallel,
# so the processes and their traffic could have cost more than a loop
# and bought nothing but shape.
#
# procbench(1) settled it before this was written: a process an entity
# costs four to sixteen times a loop per entity, and at these sizes that
# is charged on a number too small to matter - two hundred and fifty-six
# entities as processes are about 54us a frame out of 16666.  So the
# shape is affordable, and the honest claim for it is that it reads
# well, not that it runs fast.  The one thing the measurement forbade is
# spawning per entity per frame, at seven to fourteen microseconds a go;
# these are spawned once a wave, and -b reports what a frame costs.
#
# The waves are /lib/tiles/sprig.waves and the art is /lib/tiles/sprig.*
# - making the last wave forty deep is editing a file.
#

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

Sprig: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

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
HUDH:	con 16;

ARTFILE:	con "/lib/tiles/sprig.art";
MAPFILE:	con "/lib/tiles/sprig.map";
WAVEFILE:	con "/lib/tiles/sprig.waves";

CSKY:	con '.';
CSTALK:	con '|';
CLEAF:	con 'v';
CGROUND: con '#';
CPLOT:	con 'o';
CEATEN:	con 'x';

TEATEN:	con 5;			# the tile an eaten plot becomes
TSPRAY:	con 6;

MYOU:	con 0;
MFLIT1:	con 4;
MFLIT2:	con 8;
MBORER:	con 12;
MMENACE: con 16;

FLIT, BORER: con iota;
kindname := array[] of {"flit", "borer"};

PW:	con 16;
PH:	con 16;
GROUND:	con 28*8;		# the top of the ground, from the map
YOU:	con GROUND - PH;
MOVE:	con 2.0;

TANK:	con 100;		# the spray
BURN:	con 2;			# a frame of spraying
REFILL:	con 1;			# a frame of not
DRY:	con 60;			# frames locked out after running it dry
SPRAYH:	con 40;			# how far up the spray reaches
SPRAYW:	con 12;

MENACETOP: con 3*8;
MENACEND: con 24*8;		# it wins here
MENACEDOWN: con 0.055;
MENACEUP: con 0.42;

Pest: adt {
	x, y:	real;
	vx:	real;
	kind:	int;
	speed:	real;
	spread:	real;
	home:	real;
	live:	int;
	frame:	int;		# how often this one's own process has run
	phase:	int;
};

Wave: adt {
	count:	int;
	kind:	int;
	speed:	int;
	spread:	int;
};

# --- the garden ---
waves:	array of ref Wave;
wave:	int;
pests:	array of ref Pest;
tick:	chan of int;		# the frame, sent once a pest
ack:	chan of int;		# and taken back once a pest
nproc:	int;			# processes running right now

px:	real;
tank:	int;
dry:	int;
spraying: int;
menace:	real;
score:	int;
plots:	int;
lost, won: int;
frames:	int;
waveframes: int;

grid:	array of string;
LW, LH:	int;

pad, prevpad: int;
nofolk:	int;

scn:	ref Screen;
scr, garden: ref Surface;
sgarden, folk: ref Chr;
pyou, pflit, pborer, pmenace, pspray, phud, pwarn, pgood: ref Pal;
sky, panel, barlo, barhi: int;

win:	ref Window;
testmode: int;
audio:	int;

playing(): int
{
	return testmode == 0;
}

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
	if(tiles == nil){
		sys->fprint(sys->fildes(2), "sprig: cannot load tiles: %r\n");
		raise "fail:load";
	}
	e := tiles->init();
	if(e != nil){
		sys->fprint(sys->fildes(2), "sprig: %s\n", e);
		raise "fail:init";
	}
	if(fclock != nil)
		fclock->init();

	bench := 0;
	for(a := tl argv; a != nil; a = tl a){
		case hd a {
		"-t" =>	testmode = 1;
		"-s" =>	testmode = 2;
		"-b" =>	bench = 1;
		"-q" =>	audio = -1;
		* =>
			sys->fprint(sys->fildes(2), "usage: sprig [-t|-s|-b] [-q]\n");
			raise "fail:usage";
		}
	}

	(ws, werr) := readwaves(WAVEFILE);
	if(ws == nil){
		sys->fprint(sys->fildes(2), "sprig: %s\n", werr);
		raise "fail:waves";
	}
	waves = ws;

	d: ref Display;
	if(testmode || bench){
		d = Display.allocate(nil);
		if(d == nil){
			sys->fprint(sys->fildes(2), "sprig: no display: %r\n");
			raise "fail:display";
		}
	}else{
		wmclient = load Wmclient Wmclient->PATH;
		sys->pctl(Sys->NEWPGRP, nil);
		wmclient->init();
		if(ctxt == nil)
			ctxt = wmclient->makedrawcontext();
		win = wmclient->window(ctxt, "Sprig", Wmclient->Appl);
		d = win.display;
	}
	setup(d);
	if(audio == 0 && playing() && !bench && tone != nil && tone->init() == nil)
		audio = 1;
	newgame();
	if(bench){
		benchmark();
		stopwave();
		return;
	}
	if(testmode == 1){
		{
			selftest();
		}exception{
		* =>
			stopwave();
			raise;
		}
		stopwave();
		return;
	}
	if(testmode == 2){
		shot();
		stopwave();
		return;
	}
	win.reshape(Rect((0,0),(W*SCALE, H*SCALE)));
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);
	play();
}

docmd(c: string)
{
	r := scn.cmd(c);
	if(len r > 0 && r[0] == '!'){
		sys->fprint(sys->fildes(2), "sprig: %s\n", r);
		raise "fail:cmd";
	}
}

slurp(path: string): (array of byte, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || d.length <= big 0 || d.length > big (1024*1024))
		return (nil, "unreasonable file: " + path);
	b := array[int d.length] of byte;
	if(sys->readn(fd, b, len b) != len b)
		return (nil, sys->sprint("cannot read %s: %r", path));
	return (b, nil);
}

runcmds(path: string)
{
	(b, err) := slurp(path);
	if(err != nil)
		barf(err);
	(nil, lines) := sys->tokenize(string b, "\n");
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		if(len l == 0 || l[0] == ';')
			continue;
		docmd(l);
	}
}

setup(d: ref Display)
{
	scn = tiles->screen(d, Draw->RGB24, SCALE);
	if(scn == nil)
		barf("no screen");
	runcmds(ARTFILE);
	sky = colourof("csky");
	panel = colourof("cpanel");
	barlo = colourof("cbarlo");
	barhi = colourof("cbarhi");
	docmd(sys->sprint("surface scr %d %d %d", W, H, sky));
	docmd(sys->sprint("surface garden %d %d %d", W, H, sky));
	docmd("map garden garden " + MAPFILE);
	scr = scn.named("scr");
	garden = scn.named("garden");
	sgarden = scn.sheet("garden");
	folk = scn.sheet("folk");
	pyou = scn.pal("pyou");
	pflit = scn.pal("pflit");
	pborer = scn.pal("pborer");
	pmenace = scn.pal("pmenace");
	pspray = scn.pal("pspray");
	phud = scn.pal("phud");
	pwarn = scn.pal("pwarn");
	pgood = scn.pal("pgood");
	grid = scn.grid("garden");
	if(scr == nil || garden == nil || folk == nil || grid == nil || pspray == nil)
		barf("the screen made nothing");
	LW = len grid[0];
	LH = len grid;
}

colourof(name: string): int
{
	p := scn.pal(name);
	if(p == nil || len p.c == 0)
		barf(name + ": no such colour");
	return p.c[0];
}

barf(s: string)
{
	sys->fprint(sys->fildes(2), "sprig: %s\n", s);
	raise "fail:data";
}

number(w: string): (int, int)
{
	if(len w == 0)
		return (0, 0);
	v := 0;
	for(i := 0; i < len w; i++){
		if(w[i] < '0' || w[i] > '9')
			return (0, 0);
		v = v*10 + (w[i] - '0');
	}
	return (v, 1);
}

kindof(w: string): int
{
	for(i := 0; i < len kindname; i++)
		if(kindname[i] == w)
			return i;
	return -1;
}

MAXWAVE: con 64;

readwaves(path: string): (array of ref Wave, string)
{
	(b, err) := slurp(path);
	if(err != nil)
		return (nil, err);
	out := array[8] of ref Wave;
	n := 0;
	ln := 0;
	body := 0;
	(nil, lines) := sys->tokenize(string b, "\n");
	for(; lines != nil; lines = tl lines){
		ln++;
		l := hd lines;
		if(len l > 0 && l[0] == ';')
			continue;
		(nw, w) := sys->tokenize(l, " \t");
		if(nw == 0)
			continue;
		if(hd w == "%"){
			body = 1;
			continue;
		}
		where := sys->sprint("%s:%d: ", path, ln);
		if(!body)
			return (nil, where + "a setting before the %");
		if(nw != 4)
			return (nil, where + "a wave is COUNT KIND SPEED SPREAD");
		(cnt, cok) := number(hd w);
		k := kindof(hd tl w);
		(spd, sok) := number(hd tl tl w);
		(spr, rok) := number(hd tl tl tl w);
		if(!cok || !sok || !rok)
			return (nil, where + "not a number");
		if(k < 0)
			return (nil, where + "no such pest: " + hd tl w);
		if(cnt < 1)
			return (nil, where + "a wave of nothing");
		# Every one of these is a process; a file asking for ten
		# thousand would be answered rather than attempted.
		if(cnt > MAXWAVE)
			return (nil, sys->sprint("%sa wave of %d, and %d is the most",
				where, cnt, MAXWAVE));
		if(spd < 1)
			return (nil, where + "a pest that does not come down");
		if(n >= len out){
			a := array[2 * len out] of ref Wave;
			a[0:] = out[0:n];
			out = a;
		}
		out[n++] = ref Wave(cnt, k, spd, spr);
	}
	if(n == 0)
		return (nil, path + ": no waves");
	return (out[0:n], nil);
}

# --------------------------------------------------- an entity's process
#
# One of these a pest.  It owns its Pest and nobody else writes to it;
# the frame arrives on a channel shared by the whole wave, and the
# answer goes back on another, so the driver knows when they have all
# moved.  A pest that is dead still takes its tick and answers: a wave
# whose acks do not match its ticks would leave the driver waiting.

pestproc(p: ref Pest, go: chan of int, done: chan of int)
{
	for(;;){
		if(<-go == 0){
			done <-= 0;
			return;
		}
		if(p.live)
			steppest(p);
		p.frame++;
		done <-= 1;
	}
}

steppest(p: ref Pest)
{
	p.y += p.speed;
	case p.kind {
	FLIT =>
		# weaves either side of where it came in
		p.x += p.vx;
		if(p.x < p.home - p.spread || p.x > p.home + p.spread)
			p.vx = -p.vx;
		if(p.x < 0.0){
			p.x = 0.0;
			p.vx = -p.vx;
		}
		if(p.x > real (W - PW)){
			p.x = real (W - PW);
			p.vx = -p.vx;
		}
		p.phase = (p.phase + 1) % 16;
	BORER =>
		;
	}
}

# Start a wave: one process an entity, spawned once here and not once a
# frame - procbench(1) puts a spawn at seven to fourteen microseconds,
# which is nothing once and milliseconds every frame.
startwave()
{
	stopwave();
	if(wave >= len waves){
		won = 1;
		return;
	}
	w := waves[wave];
	pests = array[w.count] of ref Pest;
	tick = chan of int;
	ack = chan of int;
	for(i := 0; i < w.count; i++){
		x := real (12 + (i * (W - PW - 24)) / w.count);
		p := ref Pest;
		p.x = x;
		p.home = x;
		p.y = real (MENACETOP + 8 + (i % 3) * 10) - real (i * 6);
		p.kind = w.kind;
		p.speed = real w.speed / 100.0;
		p.spread = real w.spread;
		p.vx = 0.7;
		if(i & 1)
			p.vx = -0.7;
		p.live = 1;
		p.frame = 0;
		p.phase = i;
		pests[i] = p;
		spawn pestproc(p, tick, ack);
	}
	nproc = w.count;
	waveframes = 0;
}

stopwave()
{
	if(nproc == 0)
		return;
	for(i := 0; i < nproc; i++)
		tick <-= 0;
	for(i = 0; i < nproc; i++)
		<-ack;
	nproc = 0;
	pests = nil;
}

# One frame for every pest: the tick goes out once each and is taken
# back once each.  Nothing here knows or cares which process gets which
# tick, only that as many came back as went out.
steppests()
{
	for(i := 0; i < nproc; i++)
		tick <-= 1;
	for(i = 0; i < nproc; i++)
		<-ack;
}

# ---------------------------------------------------------------- rules

fl(v: real): int
{
	i := int v;
	if(real i > v)
		i--;
	return i;
}

newgame()
{
	stopwave();
	px = real (W/2 - PW/2);
	tank = TANK;
	dry = 0;
	spraying = 0;
	menace = real MENACETOP;
	score = 0;
	lost = won = 0;
	frames = 0;
	wave = 0;
	# the plots come back, which means repainting the map
	plots = 0;
	for(ty := 0; ty < LH; ty++)
		for(tx := 0; tx < LW; tx++)
			if(grid[ty][tx] == CPLOT || grid[ty][tx] == CEATEN){
				docmd(sys->sprint("set garden %d %d o", tx, ty));
				plots++;
			}
	pad = prevpad = 0;
	startwave();
}

step()
{
	if(lost || won)
		return;
	frames++;
	waveframes++;
	prevpad = pad;

	if(pad & KLEFT)
		px -= MOVE;
	if(pad & KRIGHT)
		px += MOVE;
	if(px < 0.0)
		px = 0.0;
	if(px > real (W - PW))
		px = real (W - PW);

	# The spray.  Holding it down is the mistake: it empties, and an
	# empty tank is a second of nothing at all.
	spraying = 0;
	if(dry > 0){
		dry--;
		tank += REFILL;
	}else if((pad & KA) && tank >= BURN){
		spraying = 1;
		tank -= BURN;
		if(tank <= 0){
			tank = 0;
			dry = DRY;
			sfx(2, 140, 200);
		}
	}else
		tank += REFILL;
	if(tank > TANK)
		tank = TANK;

	steppests();
	hits();

	# The thing on the stalk comes down, and the spray is what puts it
	# back up - but only while it is over your head.
	if(spraying && overhead())
		menace -= MENACEUP;
	else
		menace += MENACEDOWN;
	if(menace < real MENACETOP)
		menace = real MENACETOP;
	if(menace >= real MENACEND){
		menace = real MENACEND;
		lost = 1;
		sfx(2, 80, 500);
	}

	if(plots <= 0)
		lost = 1;
	if(nproc > 0 && alive() == 0){
		wave++;
		startwave();
	}
}

overhead(): int
{
	mx := real (W/2 - PW/2);
	d := mx - px;
	if(d < 0.0)
		d = -d;
	return d < 24.0;
}

alive(): int
{
	n := 0;
	for(i := 0; i < nproc; i++)
		if(pests[i].live)
			n++;
	return n;
}

# The spray is a column above the gardener.  A pest in it dies; a pest
# that reaches the ground eats a plot and is gone either way.
hits()
{
	sx := px + real (PW/2);
	for(i := 0; i < nproc; i++){
		p := pests[i];
		if(!p.live)
			continue;
		cx := p.x + real (PW/2);
		cy := p.y + real (PH/2);
		if(spraying && cy > real (YOU - SPRAYH) && cy < real YOU){
			dx := cx - sx;
			if(dx < 0.0)
				dx = -dx;
			if(dx < real SPRAYW){
				p.live = 0;
				score += 50;
				sfx(1, 600, 40);
				continue;
			}
		}
		if(p.y + real PH >= real GROUND){
			p.live = 0;
			eat(cx);
		}
	}
}

eat(cx: real)
{
	tx := fl(cx / 8.0);
	best := -1;
	bd := 1000;
	for(ty := 0; ty < LH; ty++)
		for(x := 0; x < LW; x++)
			if(grid[ty][x] == CPLOT){
				d := tx - x;
				if(d < 0)
					d = -d;
				if(d < bd){
					bd = d;
					best = ty*LW + x;
				}
			}
	if(best < 0)
		return;
	ty = best / LW;
	tx = best % LW;
	docmd(sys->sprint("set garden %d %d x", tx, ty));
	plots--;
	sfx(2, 180, 120);
}

sfx(pri, freq, ms: int)
{
	if(audio == 1 && tone != nil)
		tone->sfx(pri, freq, ms);
}

# ---------------------------------------------------------------- draw

folkat(x, y, t: int, p: ref Pal, flags: int)
{
	old := scr.chr;
	scr.chr = folk;
	scr.put16(x, y, t, p, flags);
	scr.chr = old;
}

draw1()
{
	garden.blit(scr, 0, 0);
	if(!nofolk){
		folkat(W/2 - PW/2, int menace, MMENACE, pmenace, 0);
		for(i := 0; i < nproc; i++){
			p := pests[i];
			if(!p.live)
				continue;
			t := MBORER;
			if(p.kind == FLIT){
				t = MFLIT1;
				if(p.phase & 8)
					t = MFLIT2;
			}
			pal := pborer;
			if(p.kind == FLIT)
				pal = pflit;
			folkat(int p.x, int p.y, t, pal, 0);
		}
		if(spraying){
			old := scr.chr;
			scr.chr = sgarden;
			sx := int px + PW/2 - 4;
			for(y := YOU - SPRAYH; y < YOU; y += 8)
				scr.put(sx, y, TSPRAY, pspray, 0);
			scr.chr = old;
		}
		folkat(int px, YOU, MYOU, pyou, 0);
	}
	hud();
}

hud()
{
	scr.fill(Rect((0,0),(W, HUDH)), panel);
	scr.text(4, 4, "score " + string score, phud);
	scr.text(92, 4, "plots " + string plots, phud);
	c := barlo;
	if(dry > 0)
		c = barhi;
	scr.fill(Rect((150, 5), (250, 11)), tiles->entry(Tiles->DARK, Tiles->GREY));
	if(tank > 0)
		scr.fill(Rect((150, 5), (150 + tank, 11)), c);
	if(lost)
		scr.text(W/2 - 24, H - 16, "lost", pwarn);
	else if(won)
		scr.text(W/2 - 32, H - 16, "the garden holds", pgood);
	else
		scr.text(4, H - 16, "wave " + string (wave+1) + " of " +
			string len waves, phud);
}

play()
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
			stopwave();
			if(tone != nil)
				tone->stop();
			exit;
		}
		if(k == '\n' && (lost || won)){
			newgame();
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

# ------------------------------------------------------------- measure

benchmark()
{
	sys->print("sprig: what a frame of processes costs\n\n");
	sys->print("%8s %12s %12s\n", "pests", "us/frame", "us/pest");
	for(w := 0; w < len waves; w++){
		wave = w;
		startwave();
		n := nproc;
		# warm, then measured: the first frame of a wave pays for
		# whatever the spawn left to do
		for(i := 0; i < 50; i++)
			steppests();
		N: con 2000;
		t0 := sys->millisec();
		for(i = 0; i < N; i++)
			steppests();
		ms := sys->millisec() - t0;
		sys->print("%8d %12s %12s\n", n, per(ms, N), per(ms, N*n));
		stopwave();
	}
	sys->print("\na frame at 60Hz has 16666 us.  procbench(1) is the same\n");
	sys->print("measurement without a game around it.\n");
}

per(ms, n: int): string
{
	if(n <= 0)
		return "-";
	us := real ms * 1000.0 / real n;
	w := int (us * 100.0);
	return sys->sprint("%d.%.2d", w / 100, w % 100);
}

# ----------------------------------------------------------- screenshot

shot()
{
	audio = 0;
	# Pulsed, not held: holding it down is the mistake the game is
	# about, and a dry tank draws no spray at all.
	for(i := 0; i < 244; i++){
		pad = 0;
		if((i % 30) < 8)
			pad |= KA;
		if((i / 40) & 1)
			pad |= KLEFT;
		else
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
	fd := sys->create("sprig.raw", Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->print("create: %r\n");
		return;
	}
	sys->write(fd, b, len b);
	sys->print("wrote sprig.raw %dx%d bgr\n", w, h);
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

boxsum(r: Rect): int
{
	o := scr.img.r.min;
	q := Rect((o.x + r.min.x*SCALE, o.y + r.min.y*SCALE),
		(o.x + r.max.x*SCALE, o.y + r.max.y*SCALE));
	(cq, inside) := q.clip(scr.img.r);
	if(!inside)
		return -1;
	b := array[cq.dx()*cq.dy()*3] of byte;
	if(scr.img.readpixels(cq, b) < 0)
		return -1;
	sum := 0;
	for(i := 0; i < len b; i += 3)
		sum = (sum * 31 + int b[i]) & 16r3FFFFFFF;
	return sum;
}

badwaves(text: string): (array of ref Wave, string)
{
	p := "sprig-selftest.waves";
	fd := sys->create(p, Sys->OWRITE, 8r666);
	if(fd == nil)
		return (nil, "could not write the file");
	b := array of byte text;
	sys->write(fd, b, len b);
	fd = nil;
	(w, e) := readwaves(p);
	sys->remove(p);
	return (w, e);
}

refused(what, text: string)
{
	(w, e) := badwaves(text);
	if(w == nil && e != nil){
		sys->print("ok   %s\n", what);
		return;
	}
	sys->print("FAIL %s was accepted\n", what);
	nfail++;
}

selftest()
{
	sys->print("sprig: self test\n");
	audio = 0;

	# --- the waves are a file ---
	cktrue("the waves were read", len waves >= 4);
	most := 0;
	for(i := 0; i < len waves; i++)
		if(waves[i].count > most)
			most = waves[i].count;
	cktrue("and the biggest is worth calling a swarm", most >= 8);
	sys->print("\t%d waves, biggest %d\n", len waves, most);
	refused("a wave that is not four fields", "%\n4 flit 50\n");
	refused("a pest that does not exist", "%\n4 wasp 50 10\n");
	refused("a count that is not a number", "%\nmany flit 50 10\n");
	refused("a wave of nothing", "%\n0 flit 50 10\n");
	refused("a pest that does not come down", "%\n4 flit 0 10\n");
	refused("a wave of more than there can be", "%\n999 flit 50 10\n");
	refused("a line before the %", "speed 4\n%\n4 flit 50 10\n");
	refused("a file with no waves", "%\n");
	(gw, ge) := badwaves("; fine\n%\n4 flit 50 10\n6 borer 70 0\n");
	cktrue("and a file that is right is accepted", gw != nil && ge == nil);
	if(gw != nil)
		ck("with the waves it names", len gw, 2);

	# --- an entity really is a process ---
	newgame();
	ck("a wave starts as many processes as it has pests", nproc, waves[0].count);
	for(i = 0; i < nproc; i++)
		ck("and each starts at frame nought", pests[i].frame, 0);
	run(10, 0);
	allran := 1;
	for(i = 0; i < nproc; i++)
		if(pests[i].frame != 10)
			allran = 0;
	cktrue("after ten frames every process has run ten times", allran);
	# Which is the check that makes this game what it is: if the driver
	# were stepping them itself, the counters would still be right, so
	# the counter is incremented in the PROCESS and nowhere else.
	moved := 0;
	for(i = 0; i < nproc; i++)
		if(pests[i].y > real MENACETOP)
			moved++;
	cktrue("and they have moved themselves", moved > 0);

	# A wave ending starts the next one, with its own count.
	n0 := nproc;
	w0 := wave;
	for(i = 0; i < nproc; i++)
		pests[i].live = 0;
	run(1, 0);
	ck("clearing a wave moves to the next", wave, w0+1);
	cktrue("and starts its processes", nproc == waves[wave].count);
	cktrue("and the old ones are gone", nproc != n0 || waves[wave].count == n0);

	# --- the spray ---
	newgame();
	t0 := tank;
	run(20, KA);
	cktrue("spraying empties the tank", tank < t0);
	run(400, KA);
	cktrue("and holding it down runs it dry", dry > 0 || tank == 0);
	cktrue("and a dry tank cannot spray", spraying == 0);
	newgame();
	run(30, KA);
	t1 := tank;
	run(60, 0);
	cktrue("letting go fills it again", tank > t1);

	# --- spraying kills what is over your head ---
	newgame();
	p := pests[0];
	px = p.x;
	p.y = real (YOU - 20);
	tank = TANK;
	dry = 0;
	s0 := score;
	run(1, KA);
	ck("a pest in the spray dies", p.live, 0);
	cktrue("and it scores", score > s0);
	# and one that is not in it does not
	newgame();
	p = pests[0];
	px = 0.0;
	p.x = real (W - PW);
	p.y = real (YOU - 20);
	tank = TANK;
	dry = 0;
	run(1, KA);
	ck("one out of the spray does not", p.live, 1);

	# --- a pest reaching the ground eats a plot ---
	newgame();
	pl := plots;
	p = pests[0];
	p.y = real (GROUND - PH + 1);
	run(1, 0);
	ck("a pest that lands eats a plot", plots, pl-1);
	ck("and is gone", p.live, 0);

	# --- the thing on the stalk ---
	newgame();
	m0 := menace;
	run(60, 0);
	cktrue("the menace comes down", menace > m0);
	newgame();
	px = real (W/2 - PW/2);
	run(30, 0);
	m1 := menace;
	tank = TANK;
	dry = 0;
	run(20, KA);
	cktrue("spraying it from underneath puts it back up", menace < m1);
	# and not from the side
	newgame();
	px = 0.0;
	run(30, 0);
	m2 := menace;
	tank = TANK;
	dry = 0;
	run(20, KA);
	cktrue("but not from over there", menace > m2);

	# --- doing nothing loses ---
	newgame();
	idle := 0;
	for(i = 0; i < 20000; i++){
		run(1, 0);
		if(lost){
			idle = 1;
			break;
		}
		if(won)
			break;
	}
	cktrue("doing nothing loses the garden", idle);
	sys->print("\tit took %d frames to lose doing nothing\n", frames);

	# --- drawing ---
	newgame();
	run(30, 0);
	box := Rect((0, HUDH), (W, H));
	nofolk = 0;
	draw1();
	with := boxsum(box);
	nofolk = 1;
	draw1();
	without := boxsum(box);
	nofolk = 0;
	cktrue("the frame could be read back", with >= 0 && without >= 0);
	cktrue("the garden's creatures are drawn", with != without);
	# the spray is drawn when it is on, and not when it is off
	newgame();
	run(10, 0);
	tank = TANK;
	dry = 0;
	run(1, 0);
	draw1();
	off := boxsum(box);
	run(1, KA);
	draw1();
	on := boxsum(box);
	cktrue("the spray shows when it is on", off != on);

	if(nfail == 0)
		sys->print("sprig: PASSED\n");
	else{
		sys->print("sprig: FAILED (%d)\n", nfail);
		raise "fail:test";
	}
}
