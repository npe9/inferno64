implement Orchard;

# Orchard - a maze chase in the shape that genre took: a grid of berries
# to clear, four chasers that each want somewhere different, four bigger
# berries that turn them blue for a while, and a tunnel across the middle
# row that both sides can use.
#
# What this one exercises in tiles(2) that the others do not is per-tile
# reasoning: everything moves on the grid and may only change direction
# at a tile's centre, and the chasers pick a direction each time they
# reach one by scoring the exits against a target square.  Different
# targets are the whole of the difference between the four of them.

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

Orchard: module
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
MW:	con 28;			# maze, in tiles
MH:	con 29;
OX:	con 2;			# where the maze sits on the screen, in tiles
OY:	con 1;

# cells
WALL, OPEN, PIP, BERRY, GATE: con iota;

# tiles
TBLANK, TWALL, TPIP, TBERRY, TGATE: con iota;
TPLAY:	con 5;			# 16x16 from here: mouth shut
TPLAY1:	con 9;			# open, along x
TPLAY2:	con 13;			# open, along y
TFOE:	con 17;
TSCARED: con 21;
TEYES:	con 25;

SMALL := array[] of {
	# 0 blank
	"........", "........", "........", "........",
	"........", "........", "........", "........",
	# 1 wall
	"22222222", "21111112", "21111112", "21111112",
	"21111112", "21111112", "21111112", "22222222",
	# 2 pip
	"........", "........", "...33...", "...33...",
	"........", "........", "........", "........",
	# 3 big berry
	"........", "..3333..", ".333333.", ".333333.",
	".333333.", ".333333.", "..3333..", "........",
	# 4 the gate on the pen
	"........", "........", "22222222", "22222222",
	"........", "........", "........", "........",
};

BIG := array[] of {
	# 5 player, mouth shut
	"................",
	"....22222222....",
	"..222222222222..",
	".22222222222222.",
	".22222222222222.",
	"2222222222222222",
	"2222222222222222",
	"2222222222222222",
	"2222222222222222",
	"2222222222222222",
	"2222222222222222",
	".22222222222222.",
	".22222222222222.",
	"..222222222222..",
	"....22222222....",
	"................",
	# 9 player, mouth open along x
	"................",
	"....22222222....",
	"..222222222222..",
	".22222222222222.",
	".2222222222222..",
	"222222222222....",
	"22222222222.....",
	"2222222222......",
	"2222222222......",
	"22222222222.....",
	"222222222222....",
	".2222222222222..",
	".22222222222222.",
	"..222222222222..",
	"....22222222....",
	"................",
	# 13 player, mouth open along y
	"................",
	"....2....2......",
	"..2222..2222....",
	".2222222222222..",
	".2222222222222..",
	"22222222222222..",
	"22222222222222..",
	"22222222222222..",
	"22222222222222..",
	"22222222222222..",
	"22222222222222..",
	".2222222222222..",
	".2222222222222..",
	"..222222222222..",
	"....22222222....",
	"................",
	# 17 chaser
	"................",
	"....11111111....",
	"..111111111111..",
	".11111111111111.",
	".11331111331111.",
	"1133331133331111",
	"1133221133221111",
	"1133221133221111",
	"1111111111111111",
	"1111111111111111",
	"1111111111111111",
	"1111111111111111",
	"1111111111111111",
	"1111111111111111",
	"11.111..111..111",
	"1....1..1....1..",
	# 21 chaser, running away
	"................",
	"....33333333....",
	"..333333333333..",
	".33333333333333.",
	".33333333333333.",
	"3333223322333333",
	"3333223322333333",
	"3333333333333333",
	"3333333333333333",
	"3322333333223333",
	"3233233223323333",
	"3333333333333333",
	"3333333333333333",
	"3333333333333333",
	"33.333..333..333",
	"3....3..3....3..",
	# 25 chaser, eaten
	"................",
	"................",
	"................",
	"................",
	"..2211....2211..",
	"..2211....2211..",
	"..2222....2222..",
	"..2222....2222..",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
};

MAZE := array[] of {
	"############################",
	"#............##............#",
	"#.####.#####.##.#####.####.#",
	"#o####.#####.##.#####.####o#",
	"#.####.#####.##.#####.####.#",
	"#..........................#",
	"#.####.##.########.##.####.#",
	"#.####.##.########.##.####.#",
	"#......##....##....##......#",
	"######.##### ## #####.######",
	"     #.##### ## #####.#     ",
	"     #.##          ##.#     ",
	"     #.## ###--### ##.#     ",
	"######.## #      # ##.######",
	"      .   #  GG  #   .      ",
	"######.## #      # ##.######",
	"     #.## ######## ##.#     ",
	"     #.##          ##.#     ",
	"     #.## ######## ##.#     ",
	"######.## ######## ##.######",
	"#............##............#",
	"#.####.#####.##.#####.####.#",
	"#.####.#####.##.#####.####.#",
	"#o..##.......P .......##..o#",
	"###.##.##.########.##.##.###",
	"#......##....##....##......#",
	"#.##########.##.##########.#",
	"#..........................#",
	"############################",
};

# directions, in the order the chasers prefer them when two exits score
# the same: up, left, down, right.  A fixed order is what makes a chase
# repeatable instead of a coin toss.
NDIR:	con 4;
DX := array[NDIR] of {0, -1, 0, 1};
DY := array[NDIR] of {-1, 0, 1, 0};
UP, LEFT, DOWN, RIGHT: con iota;

NFOE:	con 4;
# each chaser's home corner, for the roaming phase
HX := array[NFOE] of {MW-2, 1, MW-2, 1};
HY := array[NFOE] of {0, 0, MH-1, MH-1};

CHASE, SCATTER: con iota;

Foe: adt {
	x, y:	int;		# pixels, top left of a 16x16
	dir:	int;
	want:	int;		# tile it is aiming for
	wx, wy:	int;
	pen:	int;		# frames left in the pen
	scared:	int;
	eyes:	int;		# going home after being eaten
	kind:	int;
};

win: ref Window;
scr, bg: ref Surface;
sheet, fnt: ref Chr;
cells: array of int;
pwall, ppip, pberry, pplay, pgate, phud, pflash: ref Pal;
pfoe: array of ref Pal;

px, py: int;			# pixels
pdir := LEFT;
pnext := LEFT;
panim := 0;
pips := 0;
lives := 3;
score := 0;
best := 0;
level := 1;
frames := 0;
dead := 0;
clear := 0;
scared := 0;
eaten := 0;			# chasers eaten this berry, for the doubling
mode := SCATTER;
modet := 0;
foes: array of ref Foe;
pad := 0;
prevpad := 0;
audio := 0;
testmode := 0;

PSPD:	con 1;			# pixels a frame
FSPD:	con 1;

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
		sys->fprint(sys->fildes(2), "orchard: cannot load tiles: %r\n");
		raise "fail:load";
	}
	e := tiles->init();
	if(e != nil){
		sys->fprint(sys->fildes(2), "orchard: %s\n", e);
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
			sys->fprint(sys->fildes(2), "orchard: no display: %r\n");
			raise "fail:display";
		}
	}else{
		wmclient = load Wmclient Wmclient->PATH;
		sys->pctl(Sys->NEWPGRP, nil);
		wmclient->init();
		if(ctxt == nil)
			ctxt = wmclient->makedrawcontext();
		win = wmclient->window(ctxt, "Orchard", Wmclient->Appl);
		d = win.display;
	}
	setup(d);
	if(scorestore != nil)
		best = scorestore->loadint("orchard", 0);
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
				scorestore->saveint("orchard", score);
			exit;
		}
		pad = kb.key(pad, k);
		wanted();
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
	bk := tiles->entry(Tiles->DARK, Tiles->BLACK);
	pwall = tiles->pal(bk, tiles->entry(Tiles->DARK, Tiles->BLUE),
		tiles->entry(Tiles->MID, Tiles->AZURE), tiles->entry(Tiles->LIGHT, Tiles->CYAN));
	ppip = tiles->pal(bk, bk, bk, tiles->entry(Tiles->PALE, Tiles->ORANGE));
	pberry = tiles->pal(bk, bk, bk, tiles->entry(Tiles->PALE, Tiles->ROSE));
	pgate = tiles->pal(bk, bk, tiles->entry(Tiles->MID, Tiles->ROSE), bk);
	pplay = tiles->pal(bk, tiles->entry(Tiles->DARK, Tiles->YELLOW),
		tiles->entry(Tiles->PALE, Tiles->YELLOW), tiles->entry(Tiles->MID, Tiles->YELLOW));
	pfoe = array[NFOE] of ref Pal;
	hue := array[NFOE] of {Tiles->RED, Tiles->ROSE, Tiles->CYAN, Tiles->ORANGE};
	for(i := 0; i < NFOE; i++)
		pfoe[i] = tiles->pal(bk, tiles->entry(Tiles->LIGHT, hue[i]),
			tiles->entry(Tiles->PALE, Tiles->GREY),
			tiles->entry(Tiles->MID, Tiles->BLUE));
	phud = tiles->pal(bk, tiles->entry(Tiles->PALE, Tiles->GREY),
		tiles->entry(Tiles->PALE, Tiles->GREY), tiles->entry(Tiles->PALE, Tiles->GREY));
	pflash = tiles->pal(bk, tiles->entry(Tiles->PALE, Tiles->YELLOW),
		tiles->entry(Tiles->PALE, Tiles->YELLOW), tiles->entry(Tiles->PALE, Tiles->YELLOW));
	scr = tiles->surface(d, sheet, fnt, W, H, bk);
	bg = tiles->surface(d, sheet, fnt, W, H, bk);
	cells = array[MW*MH] of int;
}

buildmaze()
{
	bk := tiles->entry(Tiles->DARK, Tiles->BLACK);
	bg.fill(Rect((0,0),(W,H)), bk);
	pips = 0;
	for(ty := 0; ty < MH; ty++){
		row := MAZE[ty];
		for(tx := 0; tx < MW; tx++){
			c := ' ';
			if(tx < len row)
				c = row[tx];
			v := OPEN;
			case c {
			'#' =>	v = WALL;
			'.' =>	v = PIP;
			'o' =>	v = BERRY;
			'-' =>	v = GATE;
			}
			if(v == PIP || v == BERRY)
				pips++;
			cells[ty*MW + tx] = v;
			paint(tx, ty);
		}
	}
}

# One cell, on the background surface.  Eating a berry rewrites just
# that cell rather than the maze.
paint(tx, ty: int)
{
	v := cells[ty*MW + tx];
	t := TBLANK;
	p := pwall;
	case v {
	WALL =>		t = TWALL;
	PIP =>		t = TPIP; p = ppip;
	BERRY =>	t = TBERRY; p = pberry;
	GATE =>		t = TGATE; p = pgate;
	* =>		t = TBLANK; p = pwall;
	}
	bg.tile(OX + tx, OY + ty, t, p);
}

cell(tx, ty: int): int
{
	if(ty < 0 || ty >= MH)
		return WALL;
	# the tunnel: the middle row runs off both sides and comes back
	if(tx < 0 || tx >= MW)
		return OPEN;
	return cells[ty*MW + tx];
}

# May a mover with this size stand centred on (tx, ty)?  The gate is a
# wall to the player and open to a chaser.
free(tx, ty, isfoe: int): int
{
	v := cell(tx, ty);
	if(v == WALL)
		return 0;
	if(v == GATE)
		return isfoe;
	return 1;
}

newgame()
{
	lives = 3;
	score = 0;
	level = 1;
	buildmaze();
	newround();
}

newround()
{
	(sx, sy) := findchar('P');
	px = sx*8 + OX*8 - 4;
	py = sy*8 + OY*8 - 4;
	pdir = LEFT;
	pnext = LEFT;
	foes = array[NFOE] of ref Foe;
	(gx, gy) := findchar('G');
	for(i := 0; i < NFOE; i++){
		f := ref Foe;
		f.kind = i;
		f.x = (gx + (i&1))*8 + OX*8 - 4;
		f.y = gy*8 + OY*8 - 4;
		f.dir = UP;
		if((i & 1) != 0)
			f.dir = LEFT;
		f.pen = i*90;
		f.scared = 0;
		f.eyes = 0;
		foes[i] = f;
	}
	frames = 0;
	dead = 0;
	clear = 0;
	scared = 0;
	eaten = 0;
	mode = SCATTER;
	modet = 420;
	pad = 0;
	prevpad = 0;
}

findchar(c: int): (int, int)
{
	for(ty := 0; ty < MH; ty++){
		row := MAZE[ty];
		for(tx := 0; tx < len row; tx++)
			if(row[tx] == c)
				return (tx, ty);
	}
	return (MW/2, MH/2);
}

# A mover is a 16x16 whose position is its top left, so its own middle
# is eight pixels in; mazepix() is that middle in maze coordinates.  A
# tile is eight across and its centre is four in, so being ON a centre
# is that middle at 4 mod 8, NOT at 0 - which is what this said first,
# and it is never true.  Nothing then ever reached a tile centre, so no
# turn was ever taken, no wall was ever tested and no berry was ever
# eaten: the player walked in a straight line through the maze.
mazepix(x, y: int): (int, int)
{
	return (x + 8 - OX*8, y + 8 - OY*8);
}

tileof(x, y: int): (int, int)
{
	(cx, cy) := mazepix(x, y);
	return (cx / 8, cy / 8);
}

oncentre(x, y: int): int
{
	(cx, cy) := mazepix(x, y);
	return (cx % 8) == 4 && (cy % 8) == 4;
}

wanted()
{
	if(pad & KUP)
		pnext = UP;
	else if(pad & KDOWN)
		pnext = DOWN;
	else if(pad & KLEFT)
		pnext = LEFT;
	else if(pad & KRIGHT)
		pnext = RIGHT;
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
				newround();
		}
		return;
	}
	if(clear > 0){
		clear--;
		if(clear == 0){
			level++;
			buildmaze();
			newround();
		}
		return;
	}
	wanted();
	stepplayer();
	stepfoes();
	if(scared > 0){
		scared--;
		if(scared == 0)
			for(i := 0; i < NFOE; i++)
				foes[i].scared = 0;
	}
	if(--modet <= 0){
		if(mode == SCATTER){
			mode = CHASE;
			modet = 1200;
		}else{
			mode = SCATTER;
			modet = 420;
		}
		# a mode change turns everyone round, which is what stops a
		# chaser tailing you down a corridor for ever
		for(i := 0; i < NFOE; i++)
			if(!foes[i].eyes && foes[i].pen == 0)
				foes[i].dir = (foes[i].dir + 2) % NDIR;
	}
	if(pips == 0 && clear == 0){
		clear = 150;
		score += 1000;
		tone->sfx(4, 1300, 400);
	}
	prevpad = pad;
}

stepplayer()
{
	(tx, ty) := tileof(px, py);
	if(oncentre(px, py)){
		if(pnext != pdir && free(tx + DX[pnext], ty + DY[pnext], 0))
			pdir = pnext;
		if(!free(tx + DX[pdir], ty + DY[pdir], 0))
			return;			# nose against a wall
	}
	px += DX[pdir] * PSPD;
	py += DY[pdir] * PSPD;
	panim++;
	# tunnel
	if(px < -16)
		px = MW*8 + OX*8;
	else if(px > MW*8 + OX*8)
		px = -16;
	(tx, ty) = tileof(px, py);
	if(oncentre(px, py))
		eat(tx, ty);
}

eat(tx, ty: int)
{
	if(tx < 0 || tx >= MW || ty < 0 || ty >= MH)
		return;
	v := cells[ty*MW + tx];
	if(v == PIP){
		cells[ty*MW + tx] = OPEN;
		paint(tx, ty);
		pips--;
		score += 10;
		tone->sfx(1, 900, 30);
	}else if(v == BERRY){
		cells[ty*MW + tx] = OPEN;
		paint(tx, ty);
		pips--;
		score += 50;
		scared = 480 - level*40;
		if(scared < 120)
			scared = 120;
		eaten = 0;
		for(i := 0; i < NFOE; i++)
			if(!foes[i].eyes){
				foes[i].scared = 1;
				foes[i].dir = (foes[i].dir + 2) % NDIR;
			}
		tone->sfx(3, 300, 200);
	}
}

# Where each chaser wants to be.  This is the only thing that differs
# between them, and it is enough: one comes straight at you, one aims
# four squares in front of you, one mirrors the first about you so it
# closes from the far side, and one gives up and goes home when it gets
# close.
target(f: ref Foe): (int, int)
{
	(tx, ty) := tileof(px, py);
	if(f.eyes)
		return findchar('G');
	if(f.scared){
		# away, roughly: aim at the opposite corner
		return (MW-1 - tx, MH-1 - ty);
	}
	if(mode == SCATTER)
		return (HX[f.kind], HY[f.kind]);
	case f.kind {
	0 =>
		return (tx, ty);
	1 =>
		return (tx + DX[pdir]*4, ty + DY[pdir]*4);
	2 =>
		(ax, ay) := tileof(foes[0].x, foes[0].y);
		bx := tx + DX[pdir]*2;
		by := ty + DY[pdir]*2;
		return (bx + (bx - ax), by + (by - ay));
	}
	(fx, fy) := tileof(f.x, f.y);
	d := (fx-tx)*(fx-tx) + (fy-ty)*(fy-ty);
	if(d > 64)
		return (tx, ty);
	return (HX[f.kind], HY[f.kind]);
}

stepfoes()
{
	for(i := 0; i < NFOE; i++){
		f := foes[i];
		if(f.pen > 0){
			f.pen--;
			continue;
		}
		spd := FSPD;
		if(f.scared && (frames & 1) == 0)
			spd = 0;		# slower while running away
		if(f.eyes)
			spd = 2;
		if(spd != 0 && oncentre(f.x, f.y))
			f.dir = choose(f);
		f.x += DX[f.dir] * spd;
		f.y += DY[f.dir] * spd;
		if(f.x < -16)
			f.x = MW*8 + OX*8;
		else if(f.x > MW*8 + OX*8)
			f.x = -16;
		if(f.eyes){
			(gx, gy) := findchar('G');
			(fx, fy) := tileof(f.x, f.y);
			if(fx == gx && fy == gy){
				f.eyes = 0;
				f.scared = 0;
				f.pen = 60;
			}
		}
		if(dead > 0 || clear > 0)
			continue;
		if(!touching(f))
			continue;
		if(f.eyes)
			continue;
		if(f.scared){
			f.scared = 0;
			f.eyes = 1;
			eaten++;
			v := 200;
			for(k := 1; k < eaten; k++)
				v *= 2;
			score += v;
			tone->sfx(3, 1500, 120);
		}else
			hurt();
	}
}

touching(f: ref Foe): int
{
	dx := f.x - px;
	dy := f.y - py;
	if(dx < 0)
		dx = -dx;
	if(dy < 0)
		dy = -dy;
	return dx < 9 && dy < 9;
}

# One decision, at one tile centre: of the exits that are not walls and
# are not straight back the way it came, take the one whose next square
# is nearest the target.  Ties go to the fixed direction order at the
# top of the file, which is what makes a chase repeatable.
choose(f: ref Foe): int
{
	(fx, fy) := tileof(f.x, f.y);
	(wx, wy) := target(f);
	back := (f.dir + 2) % NDIR;
	bestd := -1;
	bestk := f.dir;
	for(k := 0; k < NDIR; k++){
		if(k == back)
			continue;
		nx := fx + DX[k];
		ny := fy + DY[k];
		if(!free(nx, ny, 1))
			continue;
		d := (nx-wx)*(nx-wx) + (ny-wy)*(ny-wy);
		if(bestd < 0 || d < bestd){
			bestd = d;
			bestk = k;
		}
	}
	if(bestd < 0)
		return back;		# a dead end: turn round
	return bestk;
}

hurt()
{
	lives--;
	dead = 120;
	tone->sfx(5, 160, 600);
}

# ------------------------------------------------------------------ draw

draw1()
{
	bg.blit(scr, 0, 0);
	if(dead == 0 || (dead & 4) != 0)
		drawplayer();
	for(i := 0; i < NFOE; i++){
		f := foes[i];
		t := TFOE;
		p := pfoe[i];
		if(f.eyes){
			t = TEYES;
			p = pfoe[i];
		}else if(f.scared){
			t = TSCARED;
			p = pfoe[i];
			if(scared < 120 && (frames / 8 & 1) != 0)
				p = phud;
		}
		scr.put16(f.x, f.y, t, p, 0);
	}
	hud();
}

drawplayer()
{
	t := TPLAY;
	fl := 0;
	if((panim / 5 & 1) != 0){
		case pdir {
		LEFT =>	t = TPLAY1; fl = Tiles->FLIPX;
		RIGHT =>	t = TPLAY1;
		UP =>	t = TPLAY2;
		DOWN =>	t = TPLAY2; fl = Tiles->FLIPY;
		}
	}
	scr.put16(px, py, t, pplay, fl);
}

hud()
{
	scr.text(8, 0, "SCORE " + pad0(score, 6), phud);
	scr.text(8*17, 0, "LV " + pad0(level, 2), phud);
	scr.text(8*23, 0, "LIVES " + pad0(lives, 1), phud);
	if(dead > 0 && lives <= 0)
		scr.text(8*11, 8*17, "GAME OVER", pflash);
	if(clear > 0)
		scr.text(8*11, 8*17, "ORCHARD", pflash);
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
	for(i := 0; i < 420; i++){
		pad = 0;
		case (i / 60) % 4 {
		0 =>	pad = KLEFT;
		1 =>	pad = KUP;
		2 =>	pad = KRIGHT;
		3 =>	pad = KDOWN;
		}
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
	fd := sys->create("orchard.raw", Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->print("create: %r\n");
		return;
	}
	sys->write(fd, b, len b);
	sys->print("wrote orchard.raw %dx%d bgr\n", w, h);
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

# A maze that has already been walked over has no berries left where the
# player starts, so a check about eating needs the maze back as well as
# the round.  newround() deliberately does not rebuild it - that is what
# keeps a lost life from refilling the maze - so the test asks for both.
fresh()
{
	buildmaze();
	newround();
}

# Hold the chasers still, so a check about the player is a check about
# the player.  Their pen counter is the game's own way of doing it.
holdfoes()
{
	for(i := 0; i < NFOE; i++)
		foes[i].pen = 1000000;
}

selftest()
{
	sys->print("orchard: self test\n");
	audio = 0;
	cktrue("maze is the right height", len MAZE == MH);
	for(i := 0; i < len MAZE; i++)
		if(len MAZE[i] != MW){
			sys->print("FAIL maze row %d is %d wide, want %d\n",
				i, len MAZE[i], MW);
			nfail++;
		}
	cktrue("the maze fits the screen",
		(OX + MW) * 8 <= W && (OY + MH) * 8 <= H);
	newgame();
	cktrue("there are berries to eat", pips > 200);
	ck("four chasers", len foes, NFOE);

	# The player starts on a tile centre, and stays on the grid.
	cktrue("starts on a tile centre", oncentre(px, py));
	holdfoes();
	run(8, KLEFT);
	cktrue("back on a centre after eight steps", oncentre(px, py));

	# A wall stops it rather than letting it through.
	newround();
	holdfoes();
	x0 := px;
	run(400, KLEFT);
	(tx, ty) := tileof(px, py);
	cktrue("still inside the maze", free(tx, ty, 0));
	cktrue("did not pass through a wall", px != x0 - 400);

	# Eating: the count goes down, the cell empties, and it scores.
	fresh();
	holdfoes();
	p0 := pips;
	s0 := score;
	run(60, KLEFT);
	cktrue("berries were eaten", pips < p0);
	cktrue("and scored", score > s0);
	n := 0;
	for(i = 0; i < MW*MH; i++)
		if(cells[i] == PIP || cells[i] == BERRY)
			n++;
	ck("the count matches the maze", pips, n);

	# A big berry frightens every chaser and turns it round.
	fresh();
	(bx, by) := findcell(BERRY);
	cktrue("the maze has a big berry", bx >= 0);
	if(bx >= 0){
		for(i = 0; i < NFOE; i++){
			foes[i].pen = 0;
			foes[i].dir = RIGHT;
		}
		# One pixel to the right of the berry's centre, walking left:
		# a berry is eaten on ARRIVING at a centre, so putting the
		# player exactly on one and stepping means it leaves before it
		# ever eats anything.
		px = bx*8 + OX*8 - 3;
		py = by*8 + OY*8 - 4;
		pdir = LEFT;
		pnext = LEFT;
		s0 = score;
		run(1, 0);
		cktrue("eating it frightens them", scared > 0);
		nsc := 0;
		for(i = 0; i < NFOE; i++)
			if(foes[i].scared)
				nsc++;
		ck("all four", nsc, NFOE);
		cktrue("and it scored", score >= s0 + 50);
	}

	# A frightened chaser is worth doubling amounts and goes home as
	# eyes; an unfrightened one costs a life.
	newround();
	holdfoes();
	f := foes[0];
	f.pen = 0;
	f.scared = 1;
	scared = 200;
	f.x = px;
	f.y = py;
	s0 = score;
	run(1, 0);
	cktrue("eating a frightened chaser turns it to eyes", f.eyes != 0);
	ck("first one is worth 200", score - s0, 200);
	f2 := foes[1];
	f2.pen = 0;
	f2.scared = 1;
	f2.x = px;
	f2.y = py;
	s0 = score;
	run(1, 0);
	ck("second is worth 400", score - s0, 400);

	newround();
	holdfoes();
	lives = 3;
	f = foes[2];
	f.pen = 0;
	f.scared = 0;
	f.x = px;
	f.y = py;
	run(1, 0);
	ck("an unfrightened one costs a life", lives, 2);

	# The chasers want four different squares, which is the whole of
	# what makes them four chasers and not one.
	newround();
	mode = CHASE;
	for(i = 0; i < NFOE; i++){
		foes[i].pen = 0;
		foes[i].scared = 0;
	}
	seen := 0;
	tg := array[NFOE] of int;
	for(i = 0; i < NFOE; i++){
		(wx, wy) := target(foes[i]);
		tg[i] = wy*1000 + wx;
	}
	for(i = 0; i < NFOE; i++)
		for(j := i+1; j < NFOE; j++)
			if(tg[i] != tg[j])
				seen++;
	cktrue("the four want different squares", seen >= 4);
	(cx, cy) := tileof(px, py);
	(dx, dy) := target(foes[0]);
	ck("the first comes straight at the player", dy*1000+dx, cy*1000+cx);

	# A chaser released from the pen gets out of it.
	newround();
	foes[0].pen = 0;
	(nil, gy) := findchar('G');
	out := 0;
	for(i = 0; i < 600; i++){
		run(1, 0);
		(nil, fy) := tileof(foes[0].x, foes[0].y);
		if(fy < gy - 2){
			out = 1;
			break;
		}
		if(dead > 0)
			break;
	}
	cktrue("a chaser leaves the pen", out);

	# The tunnel wraps both ways.
	newround();
	holdfoes();
	px = -17;
	run(1, 0);
	cktrue("the tunnel wraps left to right", px > W/2);
	pdir = RIGHT;
	pnext = RIGHT;
	px = MW*8 + OX*8;
	run(1, 0);
	cktrue("and right to left", px < 0);

	# Clearing the maze ends the level.
	newround();
	holdfoes();
	for(i = 0; i < MW*MH; i++)
		if(cells[i] == PIP || cells[i] == BERRY)
			cells[i] = OPEN;
	pips = 0;
	lv := level;
	run(1, 0);
	cktrue("an empty maze clears the level", clear > 0);
	run(155, 0);
	ck("the level advances", level, lv+1);
	cktrue("and the maze is refilled", pips > 200);

	if(nfail == 0)
		sys->print("orchard: PASSED\n");
	else{
		sys->print("orchard: FAILED (%d)\n", nfail);
		raise "fail:test";
	}
}

findcell(v: int): (int, int)
{
	for(ty := 0; ty < MH; ty++)
		for(tx := 0; tx < MW; tx++)
			if(cells[ty*MW + tx] == v)
				return (tx, ty);
	return (-1, -1);
}
