implement Sprocket;

# Sprocket - a side-scrolling platformer, in the shape that genre took:
# run and jump with momentum, a jump whose height depends on how long
# the button is held, enemies that walk and turn at edges and are dealt
# with by landing on them, boxes that give something up when hit from
# below, things to collect, and a flag at the right-hand end.
#
# Where rivet(1) exercises tiles(2)'s tile map on one screen, this one
# exercises the scroll: the level is 128 tiles wide, drawn once into a
# surface four screens across, and each frame is a window of it plus
# whatever is moving.  Hitting a box rewrites a tile in that surface
# rather than rebuilding it, which is the point of keeping it around.

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
	Chr, Pal, Surface: import tiles;

include "frameclock.m";
	fclock: Frameclock;

include "scorestore.m";
	scorestore: Scorestore;

Sprocket: module
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
NTH:	con Tiles->NTH;
LW:	con 128;		# level width, in tiles
LTOP:	con 10;			# first row the map below gives; above is sky

# map cells
SKY, BRICK, TURF, SOIL, BOX, SPENT, BOLT, POLE, FLAG: con iota;

# tiles in the sheet
TSKY, TBRICK, TTURF, TSOIL, TBOX, TSPENT, TBOLT, TPOLE, TFLAG,
	TCLOUDL, TCLOUDR: con iota;
TSTAND:	con 11;
TRUN1:	con 15;
TRUN2:	con 19;
TJUMP:	con 23;
TFOE1:	con 27;
TFOE2:	con 31;
TSQUASH: con 35;

SMALL := array[] of {
	# 0 sky
	"........", "........", "........", "........",
	"........", "........", "........", "........",
	# 1 brick
	"33333333", "31111113", "31111113", "33333333",
	"11133333", "11131111", "11131111", "33333333",
	# 2 turf
	"22222222", "23232323", "32323232", "11111111",
	"11111111", "13111311", "11113111", "11111111",
	# 3 soil
	"11111111", "11311111", "11111131", "11111111",
	"13111111", "11111311", "11111111", "11131111",
	# 4 box - the one that gives something up
	"33333333", "32222223", "32233223", "32232323",
	"32222323", "32233323", "32222223", "33333333",
	# 5 spent box
	"11111111", "13333331", "13333331", "13333331",
	"13333331", "13333331", "13333331", "11111111",
	# 6 bolt
	"..3333..", ".322223.", "32211223", "32133123",
	"32133123", "32211223", ".322223.", "..3333..",
	# 7 pole
	"...11...", "...12...", "...12...", "...12...",
	"...12...", "...12...", "...12...", "...11...",
	# 8 flag
	"11111...", "12222 1.", "1222221.", "12222 1.",
	"111111..", "........", "........", "........",
	# 9 cloud, left
	"...111..", "..12221.", ".1222221", "12222222",
	"12222222", ".1111111", "........", "........",
	# 10 cloud, right
	"..111...", ".12221..", "12222221", "22222221",
	"22222221", "11111110", "........", "........",
};

BIG := array[] of {
	# 11: standing
	"................",
	"....11111111....",
	"...1222222221...",
	"...1233333321...",
	"...1231331321...",
	"...1233333321...",
	"...1232332321...",
	"...1233333321...",
	"....11111111....",
	"...311111111 3..",
	"..3311111111133.",
	"..331222222133..",
	"...3122222213...",
	"....22....22....",
	"...111....111...",
	"...111....111...",
	# 15: running, one
	"................",
	"....11111111....",
	"...1222222221...",
	"...1233333321...",
	"...1231331321...",
	"...1233333321...",
	"...1232332321...",
	"...1233333321...",
	"....11111111....",
	"..3111111111....",
	".33111111111 3..",
	".3312222221333..",
	"...312222221....",
	"...22.....22....",
	"..111.......22..",
	"..111.......111.",
	# 19: running, two
	"................",
	"....11111111....",
	"...1222222221...",
	"...1233333321...",
	"...1231331321...",
	"...1233333321...",
	"...1232332321...",
	"...1233333321...",
	"....11111111....",
	"...31111111133..",
	"..331111111133..",
	"..3312222221....",
	"....312222213...",
	".....22..22.....",
	"....111..111....",
	"....11....11....",
	# 23: in the air
	"................",
	"..3.11111111..3.",
	"..3312222222133.",
	"..3312333333133.",
	"...1231331321...",
	"...1233333321...",
	"...1232332321...",
	"...1233333321...",
	"....11111111....",
	"....11111111....",
	"...122222221....",
	"...122222221....",
	"....22....22....",
	"...111....111...",
	"...11......11...",
	"................",
	# 27: walker, one
	"................",
	"................",
	"....33333333....",
	"...3222222223...",
	"..322111111223..",
	"..321311131223..",
	"..322111111223..",
	"..322222222223..",
	"..322233332223..",
	"..322222222223..",
	"...3222222223...",
	"....33333333....",
	"...11......11...",
	"..111......111..",
	"..11........11..",
	"................",
	# 31: walker, two
	"................",
	"................",
	"....33333333....",
	"...3222222223...",
	"..322111111223..",
	"..321311131223..",
	"..322111111223..",
	"..322222222223..",
	"..322233332223..",
	"..322222222223..",
	"...3222222223...",
	"....33333333....",
	"....11....11....",
	"...111....111...",
	"...11......11...",
	"................",
	# 35: walker, flattened
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"...33333333.....",
	"..3222222223....",
	"..3211111123....",
	"..3222222223....",
	".11333333331 1..",
	".111........111.",
	"................",
};

LEVEL := array[] of {
	"................................................................................................................................",
	"................................................................................................................................",
	"................................................................................................................................",
	"................................................................................................................................",
	"................................................................................................................................",
	"................................................................................................................................",
	"...............................................oo........................................o......................................",
	".....................oo.......................####.............................o.o......###.....................................",
	"....................####...................................o..................#####............................oo...............",
	"..........................................................###.................................................####..............",
	".......................................o.o.o...........................................o...o...........................#..F.....",
	".............o.o.o.........o..........##?####........o.o...............o.o.o..........#######..........o.o............##..|.....",
	"............##?#?#........###.......................##?##.............##?#?#.....................o....##?###.........###..|.....",
	"...............................oo..............................oo...................................................####..|.....",
	"...................................................................................................................#####..|.....",
	"........................^...........^.............^.................^...............^...............^.......^.....######..|.....",
	"==============================....============================....==============================...=============================",
	"------------------------------....----------------------------....------------------------------...-----------------------------",
	"------------------------------....----------------------------....------------------------------...-----------------------------",
	"------------------------------....----------------------------....------------------------------...-----------------------------",
};

Foe: adt {
	x, y:	real;
	vy:	real;
	dir:	int;
	live:	int;
	squash:	int;		# frames left flattened
	anim:	int;
};

NFOE:	con 24;

win: ref Window;
scr, bg: ref Surface;
sheet, fnt: ref Chr;
lmap: array of int;		# LW*NTH cells

psky, pbrick, pturf, psoil, pbox, pbolt, pbot, pfoe, phud, pflash: ref Pal;

# The player's box inside the 16x16 sprite: not the whole square, or it
# would catch on tiles the art plainly clears.
BX:	con 2;
BY:	con 2;
BW:	con 12;
BH:	con 14;

px, py, pvx, pvy: real;
pground := 0;
pface := 1;
panim := 0;
cam := 0;
lives := 3;
score := 0;
bolts := 0;
best := 0;
frames := 0;
dead := 0;
won := 0;
foes: array of ref Foe;
pad := 0;
prevpad := 0;
audio := 0;
testmode := 0;

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
		sys->fprint(sys->fildes(2), "sprocket: cannot load tiles: %r\n");
		raise "fail:load";
	}
	e := tiles->init();
	if(e != nil){
		sys->fprint(sys->fildes(2), "sprocket: %s\n", e);
		raise "fail:init";
	}
	if(fclock != nil)
		fclock->init();
	for(a := tl argv; a != nil; a = tl a){
		case hd a {
		"-t" =>	testmode = 1;
		"-s" =>	testmode = 2;
		"-q" =>	audio = -1;
		}
	}
	d: ref Display;
	if(testmode){
		d = Display.allocate(nil);
		if(d == nil){
			sys->fprint(sys->fildes(2), "sprocket: no display: %r\n");
			raise "fail:display";
		}
	}else{
		wmclient = load Wmclient Wmclient->PATH;
		sys->pctl(Sys->NEWPGRP, nil);
		wmclient->init();
		if(ctxt == nil)
			ctxt = wmclient->makedrawcontext();
		win = wmclient->window(ctxt, "Sprocket", Wmclient->Appl);
		d = win.display;
	}
	setup(d);
	if(scorestore != nil)
		best = scorestore->loadint("sprocket", 0);
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
				scorestore->saveint("sprocket", score);
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

	sky := tiles->entry(Tiles->MID, Tiles->AZURE);
	psky = tiles->pal(sky, sky, tiles->entry(Tiles->PALE, Tiles->GREY),
		tiles->entry(Tiles->LIGHT, Tiles->GREY));
	pbrick = tiles->pal(sky, tiles->entry(Tiles->DARK, Tiles->ORANGE),
		tiles->entry(Tiles->MID, Tiles->ORANGE), tiles->entry(Tiles->LIGHT, Tiles->ORANGE));
	pturf = tiles->pal(sky, tiles->entry(Tiles->DARK, Tiles->GREEN),
		tiles->entry(Tiles->MID, Tiles->LIME), tiles->entry(Tiles->LIGHT, Tiles->LIME));
	psoil = tiles->pal(sky, tiles->entry(Tiles->DARK, Tiles->ORANGE),
		tiles->entry(Tiles->DARK, Tiles->RED), tiles->entry(Tiles->MID, Tiles->ORANGE));
	pbox = tiles->pal(sky, tiles->entry(Tiles->DARK, Tiles->ORANGE),
		tiles->entry(Tiles->PALE, Tiles->YELLOW), tiles->entry(Tiles->MID, Tiles->YELLOW));
	pbolt = tiles->pal(sky, tiles->entry(Tiles->DARK, Tiles->YELLOW),
		tiles->entry(Tiles->PALE, Tiles->YELLOW), tiles->entry(Tiles->MID, Tiles->YELLOW));
	# Two passes at this, both found by looking at a frame and not by
	# any assertion.  Colour 3 is the face plate and was MID AZURE,
	# which is exactly the sky, so the head rendered as an outline with
	# a hole in it.  Colour 1 is the outline AND the legs and was DARK
	# BLUE, near enough to the same sky that the legs disappeared and
	# the robot looked half its height.  Black for the outline; nothing
	# on an azure sky is closer to it than that.
	pbot = tiles->pal(sky, tiles->entry(Tiles->DARK, Tiles->BLACK),
		tiles->entry(Tiles->PALE, Tiles->CYAN), tiles->entry(Tiles->MID, Tiles->BLUE));
	pfoe = tiles->pal(sky, tiles->entry(Tiles->DARK, Tiles->VIOLET),
		tiles->entry(Tiles->MID, Tiles->MAGENTA), tiles->entry(Tiles->LIGHT, Tiles->ROSE));
	phud = tiles->pal(sky, tiles->entry(Tiles->PALE, Tiles->GREY),
		tiles->entry(Tiles->PALE, Tiles->GREY), tiles->entry(Tiles->PALE, Tiles->GREY));
	pflash = tiles->pal(sky, tiles->entry(Tiles->PALE, Tiles->YELLOW),
		tiles->entry(Tiles->PALE, Tiles->YELLOW), tiles->entry(Tiles->PALE, Tiles->YELLOW));

	scr = tiles->surface(d, sheet, fnt, W, H, sky);
	bg = tiles->surface(d, sheet, fnt, LW*8, H, sky);
	lmap = array[LW*NTH] of int;
	buildlevel();
}

buildlevel()
{
	sky := tiles->entry(Tiles->MID, Tiles->AZURE);
	bg.fill(Rect((0,0),(LW*8, H)), sky);
	# clouds first, so the sky is not a flat field; the terrain loop
	# below skips its empty cells and leaves them alone.
	for(i := 0; i < LW - 2; i += 17){
		cy := 3 + (i/17 & 1)*2;
		bg.tile(i, cy, TCLOUDL, psky);
		bg.tile(i+1, cy, TCLOUDR, psky);
	}
	for(ty := 0; ty < NTH; ty++){
		for(tx := 0; tx < LW; tx++){
			c := '.';
			if(ty >= LTOP && ty-LTOP < len LEVEL){
				row := LEVEL[ty-LTOP];
				if(tx < len row)
					c = row[tx];
			}
			v := SKY;
			case c {
			'#' =>	v = BRICK;
			'=' =>	v = TURF;
			'-' =>	v = SOIL;
			'?' =>	v = BOX;
			'o' =>	v = BOLT;
			'|' =>	v = POLE;
			'F' =>	v = FLAG;
			}
			lmap[ty*LW + tx] = v;
			if(v != SKY)
				bg.tile(tx, ty, tileof(v), palof(v));
		}
	}
	spawnfoes();
}

tileof(v: int): int
{
	case v {
	BRICK =>	return TBRICK;
	TURF =>		return TTURF;
	SOIL =>		return TSOIL;
	BOX =>		return TBOX;
	SPENT =>	return TSPENT;
	BOLT =>		return TBOLT;
	POLE =>		return TPOLE;
	FLAG =>		return TFLAG;
	}
	return TSKY;
}

palof(v: int): ref Pal
{
	case v {
	BRICK =>	return pbrick;
	TURF =>		return pturf;
	SOIL =>		return psoil;
	BOX or SPENT =>	return pbox;
	BOLT =>		return pbolt;
	POLE or FLAG =>	return pflash;
	}
	return psky;
}

cell(tx, ty: int): int
{
	if(tx < 0 || tx >= LW || ty < 0 || ty >= NTH)
		return SKY;
	return lmap[ty*LW + tx];
}

solid(v: int): int
{
	return v == BRICK || v == TURF || v == SOIL || v == BOX || v == SPENT;
}

# Rewrite one cell and the tile standing for it.  The background surface
# is kept precisely so this costs one tile rather than a rebuild.
setmap(tx, ty, v: int)
{
	if(tx < 0 || tx >= LW || ty < 0 || ty >= NTH)
		return;
	lmap[ty*LW + tx] = v;
	if(v == SKY)
		bg.fill(Rect((tx*8, ty*8), (tx*8+8, ty*8+8)),
			tiles->entry(Tiles->MID, Tiles->AZURE));
	else
		bg.tile(tx, ty, tileof(v), palof(v));
}

spawnfoes()
{
	foes = array[NFOE] of ref Foe;
	n := 0;
	for(ty := 0; ty < len LEVEL && n < NFOE; ty++){
		row := LEVEL[ty];
		for(tx := 0; tx < len row && n < NFOE; tx++){
			if(row[tx] != '^')
				continue;
			f := ref Foe;
			f.x = real (tx*8);
			f.y = real ((ty+LTOP)*8 - 16);
			f.vy = 0.0;
			f.dir = -1;
			f.live = 1;
			f.squash = 0;
			f.anim = 0;
			foes[n++] = f;
		}
	}
}

newgame()
{
	lives = 3;
	score = 0;
	bolts = 0;
	restart();
}

restart()
{
	buildlevel();
	px = 24.0;
	py = real (25*8 - 16);
	pvx = 0.0;
	pvy = 0.0;
	pground = 0;
	pface = 1;
	cam = 0;
	frames = 0;
	dead = 0;
	won = 0;
	pad = 0;
	prevpad = 0;
}

# ------------------------------------------------------------ collision

# Does the player's box, with its top left at (x, y), meet a solid tile?
boxhit(x, y: int): int
{
	x0 := x + BX;
	y0 := y + BY;
	x1 := x0 + BW - 1;
	y1 := y0 + BH - 1;
	for(ty := y0/8; ty <= y1/8; ty++)
		for(tx := x0/8; tx <= x1/8; tx++)
			if(solid(cell(tx, ty)))
				return 1;
	return 0;
}

step()
{
	frames++;
	tone->sfxtick();
	if(dead > 0){
		dead--;
		if(dead == 0){
			if(lives <= 0)
				newgame();
			else
				restart();
		}
		return;
	}
	if(won > 0){
		won--;
		if(won == 0)
			restart();
		return;
	}
	stepplayer();
	stepfoes();
	prevpad = pad;
}

ACC:	con 0.28;
FRIC:	con 0.22;
VMAX:	con 1.9;
VRUN:	con 3.0;
GRAV:	con 0.32;
VTERM:	con 6.5;
VJUMP:	con -4.7;
VCUT:	con -2.2;		# rise left after letting go of the button

stepplayer()
{
	vmax := VMAX;
	if(pad & KB)
		vmax = VRUN;
	if((pad & KLEFT) && !(pad & KRIGHT)){
		pvx -= ACC;
		pface = -1;
	}else if((pad & KRIGHT) && !(pad & KLEFT)){
		pvx += ACC;
		pface = 1;
	}else{
		if(pvx > FRIC)
			pvx -= FRIC;
		else if(pvx < -FRIC)
			pvx += FRIC;
		else
			pvx = 0.0;
	}
	if(pvx > vmax)
		pvx = vmax;
	if(pvx < -vmax)
		pvx = -vmax;

	# x, resolved on its own axis
	px += pvx;
	if(px < 0.0){
		px = 0.0;
		pvx = 0.0;
	}
	if(px > real ((LW-1)*8)){
		px = real ((LW-1)*8);
		pvx = 0.0;
	}
	if(boxhit(int px, int py)){
		if(pvx > 0.0)
			px = real (((int px + BX + BW - 1) / 8) * 8 - BX - BW);
		else
			px = real (((int px + BX) / 8 + 1) * 8 - BX);
		pvx = 0.0;
	}
	if(pvx != 0.0)
		panim++;

	# jump: an edge starts it, and letting go early cuts it short, which
	# is what makes the height controllable rather than fixed.
	if(pground && (keyhold->edge(pad, prevpad) & KA)){
		pvy = VJUMP;
		pground = 0;
		tone->sfx(2, 700, 90);
	}
	# Letting go early cuts the jump short.  This CLAMPS the rise rather
	# than scaling it: scaling ran every frame the button was up, so the
	# cut compounded and a tapped jump reached seven pixels - lower than
	# the character is tall, and indistinguishable from not jumping.
	# A clamp applies as many times as it likes and still means one cut.
	if(!(pad & KA) && pvy < VCUT)
		pvy = VCUT;

	pvy += GRAV;
	if(pvy > VTERM)
		pvy = VTERM;
	oy := int py;
	py += pvy;
	if(boxhit(int px, int py)){
		if(pvy > 0.0)
			py = real (((int py + BY + BH - 1) / 8) * 8 - BY - BH);
		else{
			bump(oy);
			py = real (((int py + BY) / 8 + 1) * 8 - BY);
		}
		pvy = 0.0;
	}
	# Standing is a probe one pixel below, not "the frame the collision
	# resolved on".  The second is what this did first, and it flickered:
	# resting on a floor, gravity moves the box a third of a pixel a
	# frame, so int py only changes - and only then does the box meet the
	# floor tile - on every other frame.  pground was therefore 0 half
	# the time while standing perfectly still, and a jump pressed on one
	# of those frames did nothing at all.
	pground = boxhit(int px, int py + 1);

	if(py > real H){
		hurt();
		return;
	}
	pickups();
	if(cell((int px + 8)/8, (int py + 8)/8) == FLAG
	|| cell((int px + 8)/8, (int py + 8)/8) == POLE){
		won = 120;
		score += 1000;
		tone->sfx(4, 1400, 500);
		return;
	}
	# camera: the player sits a third in, and it stops at both ends.
	cam = int px - 96;
	if(cam < 0)
		cam = 0;
	if(cam > LW*8 - W)
		cam = LW*8 - W;
}

# Hit from below.  A box gives up a bolt and becomes a spent one; a
# brick just stops you.
bump(oy: int)
{
	ty := (int py + BY) / 8;
	if((oy + BY) / 8 == ty)
		return;
	for(tx := (int px + BX)/8; tx <= (int px + BX + BW - 1)/8; tx++){
		if(cell(tx, ty) != BOX)
			continue;
		setmap(tx, ty, SPENT);
		score += 200;
		bolts++;
		tone->sfx(3, 1100, 80);
		return;
	}
	tone->sfx(1, 260, 50);
}

pickups()
{
	x0 := (int px + BX)/8;
	x1 := (int px + BX + BW - 1)/8;
	y0 := (int py + BY)/8;
	y1 := (int py + BY + BH - 1)/8;
	for(ty := y0; ty <= y1; ty++)
		for(tx := x0; tx <= x1; tx++)
			if(cell(tx, ty) == BOLT){
				setmap(tx, ty, SKY);
				bolts++;
				score += 100;
				tone->sfx(2, 1600, 60);
			}
}

hurt()
{
	lives--;
	dead = 100;
	tone->sfx(5, 170, 500);
}

stepfoes()
{
	for(i := 0; i < NFOE; i++){
		f := foes[i];
		if(f == nil || !f.live)
			continue;
		if(f.squash > 0){
			if(--f.squash == 0)
				f.live = 0;
			continue;
		}
		f.anim++;
		# walk, turning at a wall or at the edge of what it is on
		nx := f.x + 0.55 * real f.dir;
		fx := int nx;
		ahead := fx + 3;
		if(f.dir > 0)
			ahead = fx + 12;
		if(solid(cell(ahead/8, (int f.y + 8)/8))
		|| !solid(cell(ahead/8, (int f.y + 16)/8)))
			f.dir = -f.dir;
		else
			f.x = nx;
		# gravity, so a walker knocked off an edge still falls
		f.vy += GRAV;
		if(f.vy > VTERM)
			f.vy = VTERM;
		ny := f.y + f.vy;
		if(solid(cell((int f.x + 8)/8, (int ny + 16)/8))){
			f.y = real (((int ny + 16) / 8) * 8 - 16);
			f.vy = 0.0;
		}else
			f.y = ny;
		if(f.y > real H){
			f.live = 0;
			continue;
		}
		if(dead > 0 || won > 0)
			continue;
		if(!hits(f))
			continue;
		# Landed on it, or ran into it.  Falling and above its middle
		# is the stomp; anything else costs a life.
		if(pvy > 0.0 && int py + BY + BH - 1 < int f.y + 10){
			f.squash = 30;
			pvy = -3.4;
			pground = 0;
			score += 200;
			tone->sfx(3, 900, 70);
		}else
			hurt();
		return;
	}
}

hits(f: ref Foe): int
{
	ax := int px + BX;
	ay := int py + BY;
	bx := int f.x + 2;
	by := int f.y + 3;
	return ax + BW > bx && ax < bx + 12 && ay + BH > by && ay < by + 12;
}

# ------------------------------------------------------------------ draw

draw1()
{
	bg.view(scr, cam, 0);
	for(i := 0; i < NFOE; i++){
		f := foes[i];
		if(f == nil || !f.live)
			continue;
		x := int f.x - cam;
		if(x < -16 || x > W)
			continue;
		t := TFOE1;
		if(f.squash > 0)
			t = TSQUASH;
		else if((f.anim / 10 & 1) != 0)
			t = TFOE2;
		scr.put16(x, int f.y, t, pfoe, 0);
	}
	if(dead == 0 || (dead & 4) != 0)
		drawplayer();
	hud();
}

drawplayer()
{
	t := TSTAND;
	if(!pground)
		t = TJUMP;
	else if(pvx != 0.0){
		t = TRUN1;
		if((panim / 7 & 1) != 0)
			t = TRUN2;
	}
	f := 0;
	if(pface < 0)
		f = Tiles->FLIPX;
	scr.put16(int px - cam, int py, t, pbot, f);
}

hud()
{
	scr.text(8, 4, "SCORE " + pad0(score, 6), phud);
	scr.text(8*15, 4, "BOLTS " + pad0(bolts, 2), phud);
	scr.text(8*24, 4, "LIFE " + pad0(lives, 1), phud);
	if(dead > 0 && lives <= 0)
		scr.text(8*11, 8*13, "GAME OVER", pflash);
	if(won > 0)
		scr.text(8*10, 8*13, "COURSE CLEAR", pflash);
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
	# Enough to be somewhere worth looking at, jumping often enough to
	# clear what is in the way rather than walking into the first pit.
	for(i := 0; i < 260; i++){
		pad = KRIGHT;
		if((i % 34) < 12)
			pad |= KA;
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
	fd := sys->create("sprocket.raw", Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->print("create: %r\n");
		return;
	}
	sys->write(fd, b, len b);
	sys->print("wrote sprocket.raw %dx%d bgr\n", w, h);
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

# Walk right until x passes t, or give up.  Returns whether it got there.
walkto(t: int): int
{
	for(i := 0; i < 3000; i++){
		if(int px >= t)
			return 1;
		run(1, KRIGHT);
		if(dead > 0 || won > 0)
			return 0;
	}
	return 0;
}

selftest()
{
	sys->print("sprocket: self test\n");
	audio = 0;
	cktrue("level rows given", len LEVEL == Tiles->NTH - LTOP);
	for(i := 0; i < len LEVEL; i++)
		if(len LEVEL[i] != LW){
			sys->print("FAIL level row %d is %d wide, want %d\n",
				i, len LEVEL[i], LW);
			nfail++;
		}
	nf := 0;
	for(i = 0; i < NFOE; i++)
		if(foes[i] != nil && foes[i].live)
			nf++;
	cktrue("walkers placed from the map", nf >= 5);

	# Starting on the ground, and staying there.
	restart();
	run(20, 0);
	cktrue("landed on the ground", pground != 0);
	y0 := int py;
	run(20, 0);
	ck("stays put", int py, y0);
	ck("and does not drift", int px, 24);

	# Momentum: it takes time to get up to speed and time to stop.
	run(4, KRIGHT);
	v4 := pvx;
	run(30, KRIGHT);
	cktrue("accelerates", pvx > v4);
	cktrue("caps at the walk speed", pvx <= VMAX + 0.001);
	run(30, KRIGHT|KB);
	cktrue("the run button is faster", pvx > VMAX);
	run(30, 0);
	ck("friction stops it", int (pvx * 100.0), 0);

	# A held jump goes higher than a tapped one.  This is the whole
	# difference between this genre and the one rivet(1) is in, so it
	# is worth an assertion rather than an eyeball.
	restart();
	run(20, 0);
	yb := int py;
	pad = 0; prevpad = 0; step();
	hi := yb;
	run(1, KA);
	for(i = 0; i < 40; i++){
		run(1, KA);
		if(int py < hi)
			hi = int py;
	}
	held := yb - hi;
	restart();
	run(20, 0);
	pad = 0; prevpad = 0; step();
	hi = yb;
	run(1, KA);
	for(i = 0; i < 40; i++){
		run(1, 0);
		if(int py < hi)
			hi = int py;
	}
	tapped := yb - hi;
	cktrue("a jump leaves the ground", tapped > 8);
	cktrue("holding jumps higher than tapping", held > tapped + 8);

	# A wall stops it dead rather than letting it through.
	restart();
	run(20, 0);
	# the steps before the flag are the tallest wall in the level
	walkto(114*8 - 20);
	xw := int px;
	run(40, KRIGHT);
	cktrue("a wall stops it", int px < xw + 40);
	cktrue("and it is not inside the wall", !boxhit(int px, int py));

	# The pit at columns 30 to 33 costs a life.
	restart();
	lv := lives;
	px = real (31*8);
	py = real (24*8);
	pvy = 0.0;
	for(i = 0; i < 200 && dead == 0; i++)
		run(1, 0);
	ck("falling in a pit costs a life", lives, lv-1);

	# A box hit from below is spent, and gives a bolt.
	restart();
	bt := bolts;
	sc := score;
	bx := findbox();
	cktrue("the level has a box", bx >= 0);
	if(bx >= 0){
		by := boxrow(bx);
		# box top just under the box's row, moving up hard enough that
		# one frame of it crosses the row boundary - the crossing is
		# what bump() keys on, so a nudge of a third of a pixel proves
		# nothing.
		px = real (bx*8 - BX);
		py = real (by*8 + 7);
		pvy = -6.0;
		pground = 0;
		run(1, 0);
		ck("the box is spent", cell(bx, by), SPENT);
		ck("and gave a bolt", bolts, bt+1);
		ck("and scored", score, sc+200);
	}

	# A bolt on the map is collected once.
	restart();
	(cx, cy) := findbolt();
	cktrue("the level has a bolt", cx >= 0);
	if(cx >= 0){
		bt = bolts;
		# High enough that the box covers the bolt's row and the empty
		# one above it, and NOT the platform the bolt stands on.  Put
		# it on the platform and the x resolution shoves the player a
		# tile sideways first, which collects the next bolt along and
		# leaves this cell full - a false failure that reads exactly
		# like a broken pickup.
		px = real (cx*8 - BX);
		py = real (cy*8 - 8);
		pvy = 0.0;
		run(1, 0);
		ck("the bolt is taken", bolts, bt+1);
		ck("and the cell is empty", cell(cx, cy), SKY);
		run(3, 0);
		ck("and not taken twice", bolts, bt+1);
	}

	# Landing on a walker flattens it and bounces; walking into one
	# costs a life.  Both are forced, because neither happens on demand.
	restart();
	f := firstfoe();
	cktrue("there is a walker to test", f != nil);
	if(f != nil){
		sc = score;
		px = f.x;
		py = f.y - 14.0;
		pvy = 2.0;
		pground = 0;
		run(1, 0);
		cktrue("landing on a walker flattens it", f.squash > 0);
		cktrue("and bounces", pvy < 0.0);
		ck("and scores", score, sc+200);
	}
	restart();
	lives = 3;
	f = firstfoe();
	if(f != nil){
		lv = lives;
		px = f.x;
		py = f.y;
		pvy = 0.0;
		pground = 1;
		run(1, 0);
		ck("running into a walker costs a life", lives, lv-1);
	}

	# A walker turns round rather than walking off its ledge.
	restart();
	f = firstfoe();
	if(f != nil){
		d0 := f.dir;
		turned := 0;
		for(i = 0; i < 900; i++){
			run(1, 0);
			if(!f.live)
				break;
			if(f.dir != d0){
				turned = 1;
				break;
			}
		}
		cktrue("a walker turns round", turned);
		cktrue("and is still on the level", f.y < real H);
	}

	# The camera follows and stops at both ends.  The player is placed
	# rather than walked there: walking crosses a pit, and a run that
	# ends in a death leaves step() in its dead branch, which updates no
	# camera at all - so the assertion read a stale value and failed for
	# a reason that had nothing to do with the camera.
	restart();
	run(20, 0);
	ck("camera starts at the left edge", cam, 0);
	px = 600.0;
	py = real (23*8);
	pvy = 0.0;
	run(1, 0);
	ck("not dead", dead, 0);
	cktrue("camera followed", cam > 0);
	cktrue("player is on screen", int px - cam >= 0 && int px - cam < W);
	px = real ((LW-3)*8);
	run(1, 0);
	ck("camera stops at the right edge", cam, LW*8 - W);

	# The flag ends the course.
	restart();
	px = real (122*8 - 4);
	py = real (21*8);
	run(1, 0);
	cktrue("the flag ends the course", won > 0);

	if(nfail == 0)
		sys->print("sprocket: PASSED\n");
	else{
		sys->print("sprocket: FAILED (%d)\n", nfail);
		raise "fail:test";
	}
}

findbox(): int
{
	for(tx := 0; tx < LW; tx++)
		for(ty := 0; ty < NTH; ty++)
			if(cell(tx, ty) == BOX)
				return tx;
	return -1;
}

boxrow(tx: int): int
{
	for(ty := 0; ty < NTH; ty++)
		if(cell(tx, ty) == BOX)
			return ty;
	return -1;
}

findbolt(): (int, int)
{
	for(tx := 0; tx < LW; tx++)
		for(ty := 0; ty < NTH; ty++)
			if(cell(tx, ty) == BOLT)
				return (tx, ty);
	return (-1, -1);
}

firstfoe(): ref Foe
{
	for(i := 0; i < NFOE; i++)
		if(foes[i] != nil && foes[i].live)
			return foes[i];
	return nil;
}
