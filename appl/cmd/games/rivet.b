implement Rivet;

# Rivet - a girder climber, in the shape the arcade settled on in 1981:
# a stack of platforms joined by ladders, hazards that roll down them in
# a zigzag, a mallet that turns the hazards into points for a few
# seconds, and one thing at the top to reach.
#
# It is here to exercise tiles(2) end to end - a tile map built once into
# a background surface, metasprites composited over it, a gamepad read
# from held keys, and effects arbitrated by priority - and to be
# playable, which is the only way to find out whether any of that is
# actually usable.
#
# The map is written as 30 strings of 32 characters below, because that
# is what a level is; nothing is generated.

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

Rivet: module
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
NTW:	con Tiles->NTW;
NTH:	con Tiles->NTH;

# map cells
EMPTY, GIRDER, LADDER: con iota;

# tile numbers in the sheet
TBLANK, TGIRDER, TLADDER, TGIRDER2: con iota;
TPLAYER:	con 4;		# stand
TWALK:		con 8;
TCLIMB:		con 12;
TCLIMB2:	con 16;
THAZARD:	con 20;
THAZARD2:	con 24;
TMALLET:	con 28;
TPRIZE:		con 32;

SMALL := array[] of {
	# 0: blank
	"........", "........", "........", "........",
	"........", "........", "........", "........",
	# 1: girder - a beam with its rivets showing
	"11111111", "13333331", "12122121", "12222221",
	"12122121", "13333331", "11111111", "........",
	# 2: ladder
	"..1..1..", "..1..1..", "..3333..", "..1..1..",
	"..1..1..", "..3333..", "..1..1..", "..1..1..",
	# 3: girder, the other rivet phase, so a long beam is not a repeat
	"11111111", "13333331", "12212212", "12222221",
	"12212212", "13333331", "11111111", "........",
};

# Every 16x16 character, written as itself.  meta() cuts each into the
# four tiles the sheet wants.
BIG := array[] of {
	# 4: climber, standing
	"................",
	".....111111.....",
	"....11222211....",
	"....12233221....",
	"....12233221....",
	"....11222211....",
	".....333333.....",
	"...3333333333...",
	"..333.3333.333..",
	"..33..3333..33..",
	"......3333......",
	".....22..22.....",
	".....22..22.....",
	"....222..222....",
	"...1111..1111...",
	"...1111..1111...",
	# 8: climber, mid stride
	"................",
	".....111111.....",
	"....11222211....",
	"....12233221....",
	"....12233221....",
	"....11222211....",
	"...3.333333.....",
	"..333333333333..",
	"..33..3333...3..",
	"......3333......",
	".....2222.......",
	".....22.22......",
	"....222..22.....",
	"...1111...22....",
	"...1111...1111..",
	"..........1111..",
	# 12: climber, on a ladder
	"................",
	".....111111.....",
	"....11222211....",
	"....12222221....",
	"....12222221....",
	"....11222211....",
	"..3333333333....",
	"..3...3333...3..",
	"..3...3333...3..",
	"......3333......",
	".....22..22.....",
	"....222..222....",
	"...1111..1111...",
	"...1111..1111...",
	"................",
	"................",
	# 16: climber, on a ladder, other foot
	"................",
	".....111111.....",
	"....11222211....",
	"....12222221....",
	"....12222221....",
	"....11222211....",
	"....3333333333..",
	"..3...3333...3..",
	"..3...3333...3..",
	"......3333......",
	".....22..22.....",
	".....222.222....",
	"....1111.1111...",
	"....1111.1111...",
	"................",
	"................",
	# 20: hazard, rolling
	"................",
	"....11111111....",
	"..112222222211..",
	"..122333333221..",
	".11233222233211.",
	".12332222223321.",
	".12322111122321.",
	".12321122112321.",
	".12321122112321.",
	".12322111122321.",
	".12332222223321.",
	".11233222233211.",
	"..122333333221..",
	"..112222222211..",
	"....11111111....",
	"................",
	# 24: hazard, quarter turn
	"................",
	"....11111111....",
	"..112222222211..",
	"..123333333321..",
	".11322222222311.",
	".13222111112231.",
	".13221222212231.",
	".13212222122231.",
	".13212222122231.",
	".13221222212231.",
	".13222111112231.",
	".11322222222311.",
	"..123333333321..",
	"..112222222211..",
	"....11111111....",
	"................",
	# 28: mallet
	"................",
	"....11111111....",
	"...1333333331...",
	"...1322222231...",
	"...1333333331...",
	"....11111111....",
	"......1221......",
	"......1221......",
	"......1221......",
	"......1221......",
	"......1221......",
	"......1221......",
	"......1221......",
	"......1221......",
	"......1111......",
	"................",
	# 32: the thing at the top
	"................",
	"......1111......",
	".....133331.....",
	"....13322331....",
	"....13233231....",
	"....13322331....",
	".....133331.....",
	"...11111111111..",
	"..1333333333331.",
	"..1322222222231.",
	"..1332222222331.",
	"..1333333333331.",
	"...11111111111..",
	"....1........1..",
	"....1........1..",
	"...111......111.",
};

MAP := array[] of {
	"................................",
	"..............F.................",
	"................................",
	"................................",
	"....GGGGGGGGGGGGGGGGGG..........",
	"........H.......................",
	"........H.......................",
	"........H.......................",
	"........H.......................",
	"......GGGGGGGGGGGGGGGGGGGGG.....",
	"........................H.......",
	"........................H.......",
	"........................H.......",
	"........................H.......",
	"...GGGGGGGGGGGGGGGGGGGGGGGG.....",
	".....H..........................",
	".....H..........................",
	".....H..........................",
	".....H..........................",
	"....GGGGGGGGGGGGGGGGGGGGGGGGG...",
	"..........................H.....",
	"..........................H.....",
	"..........................H.....",
	"..........................H.....",
	"..GGGGGGGGGGGGGGGGGGGGGGGGGGG...",
	".......H........................",
	".......H........................",
	".......H........................",
	"GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",
	"GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",
};

# The rows that are platforms, top first, and which way a hazard rolls
# along each.  Alternating gives the zigzag; nothing else does.
PLAT := array[] of {4, 9, 14, 19, 24, 28};
PDIR := array[] of {1, -1, 1, -1, 1, 1};

# Where the climber starts and where the mallet lies.
STARTX:	con 8;
STARTY:	con 28*8 - 16;
MALLETX: con 200;
MALLETROW: con 24;

Hazard: adt {
	x, y:	real;
	vy:	real;
	dir:	int;
	live:	int;
	spin:	int;
	scored:	int;		# already counted for a jump
};

win: ref Window;
scr, bg: ref Surface;		# the frame, and the level drawn once
sheet, fnt: ref Chr;
pmap: array of int;		# NTW*NTH cell codes

pskin, pgirder, pladder, phaz, pmallet, pprize, phud, pflash: ref Pal;

px, py, pvy: real;
pface := 1;
pclimb := 0;
pground := 0;
panim := 0;
hot := 0;			# frames of mallet left
lives := 3;
score := 0;
best := 0;
level := 1;
frames := 0;
spawn_t := 0;
dead := 0;			# frames of death pause left
won := 0;
hazards: array of ref Hazard;
NHAZ:	con 12;
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
	rand = load Rand Rand->PATH;
	fclock = load Frameclock Frameclock->PATH;
	scorestore = load Scorestore Scorestore->PATH;
	if(tiles == nil){
		sys->fprint(sys->fildes(2), "rivet: cannot load tiles: %r\n");
		raise "fail:load";
	}
	e := tiles->init();
	if(e != nil){
		sys->fprint(sys->fildes(2), "rivet: %s\n", e);
		raise "fail:init";
	}
	if(rand != nil)
		rand->init(sys->millisec());
	if(fclock != nil)
		fclock->init();
	for(a := tl argv; a != nil; a = tl a){
		case hd a {
		"-t" =>	testmode = 1;
		"-q" =>	audio = -1;
		"-s" =>	testmode = 2;
		}
	}

	d: ref Display;
	if(testmode){
		d = Display.allocate(nil);
		if(d == nil){
			sys->fprint(sys->fildes(2), "rivet: no display: %r\n");
			raise "fail:display";
		}
	}else{
		wmclient = load Wmclient Wmclient->PATH;
		sys->pctl(Sys->NEWPGRP, nil);
		wmclient->init();
		if(ctxt == nil)
			ctxt = wmclient->makedrawcontext();
		win = wmclient->window(ctxt, "Rivet", Wmclient->Appl);
		d = win.display;
	}
	setup(d);
	if(scorestore != nil)
		best = scorestore->loadint("rivet", 0);
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
	# "keyup" as well as "kbd": without it nothing is ever released and
	# every key sticks down for good.
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
			savebest();
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
	pgirder = tiles->pal(sky, tiles->entry(Tiles->DARK, Tiles->AZURE),
		tiles->entry(Tiles->MID, Tiles->CYAN), tiles->entry(Tiles->LIGHT, Tiles->CYAN));
	pladder = tiles->pal(sky, tiles->entry(Tiles->MID, Tiles->ORANGE),
		tiles->entry(Tiles->LIGHT, Tiles->ORANGE), tiles->entry(Tiles->PALE, Tiles->YELLOW));
	pskin = tiles->pal(sky, tiles->entry(Tiles->DARK, Tiles->RED),
		tiles->entry(Tiles->LIGHT, Tiles->ORANGE), tiles->entry(Tiles->MID, Tiles->AZURE));
	phaz = tiles->pal(sky, tiles->entry(Tiles->DARK, Tiles->ORANGE),
		tiles->entry(Tiles->MID, Tiles->YELLOW), tiles->entry(Tiles->LIGHT, Tiles->RED));
	pmallet = tiles->pal(sky, tiles->entry(Tiles->DARK, Tiles->GREY),
		tiles->entry(Tiles->LIGHT, Tiles->GREY), tiles->entry(Tiles->MID, Tiles->ROSE));
	pprize = tiles->pal(sky, tiles->entry(Tiles->DARK, Tiles->VIOLET),
		tiles->entry(Tiles->PALE, Tiles->YELLOW), tiles->entry(Tiles->MID, Tiles->MAGENTA));
	phud = tiles->pal(sky, tiles->entry(Tiles->PALE, Tiles->GREY),
		tiles->entry(Tiles->PALE, Tiles->GREY), tiles->entry(Tiles->PALE, Tiles->GREY));
	pflash = tiles->pal(sky, tiles->entry(Tiles->PALE, Tiles->YELLOW),
		tiles->entry(Tiles->PALE, Tiles->YELLOW), tiles->entry(Tiles->PALE, Tiles->YELLOW));

	scr = tiles->surface(d, sheet, fnt, W, H, sky);
	bg = tiles->surface(d, sheet, fnt, W, H, sky);
	pmap = array[NTW*NTH] of int;
	buildmap();
}

buildmap()
{
	sky := tiles->entry(Tiles->DARK, Tiles->BLACK);
	bg.fill(Rect((0,0),(W,H)), sky);
	for(ty := 0; ty < NTH; ty++){
		row := MAP[ty];
		for(tx := 0; tx < NTW; tx++){
			c := '.';
			if(tx < len row)
				c = row[tx];
			case c {
			'G' =>
				pmap[ty*NTW + tx] = GIRDER;
				t := TGIRDER;
				if((tx & 1) != 0)
					t = TGIRDER2;
				bg.tile(tx, ty, t, pgirder);
			'H' =>
				pmap[ty*NTW + tx] = LADDER;
				bg.tile(tx, ty, TLADDER, pladder);
			* =>
				pmap[ty*NTW + tx] = EMPTY;
			}
		}
	}
}

cell(tx, ty: int): int
{
	if(tx < 0 || tx >= NTW || ty < 0 || ty >= NTH)
		return EMPTY;
	return pmap[ty*NTW + tx];
}

cellat(x, y: int): int
{
	return cell(x/8, y/8);
}

newgame()
{
	lives = 3;
	score = 0;
	level = 1;
	newlevel();
}

newlevel()
{
	hazards = array[NHAZ] of ref Hazard;
	px = real STARTX;
	py = real STARTY;
	pvy = 0.0;
	pface = 1;
	pclimb = 0;
	hot = 0;
	frames = 0;
	spawn_t = 0;
	dead = 0;
	won = 0;
	pad = 0;
}

hazspeed(): real
{
	s := 0.7 + 0.12 * real (level - 1);
	if(s > 2.0)
		s = 2.0;
	return s;
}

spawnhaz()
{
	for(i := 0; i < NHAZ; i++){
		if(hazards[i] != nil && hazards[i].live)
			continue;
		h := ref Hazard;
		h.x = real (5*8);
		h.y = real (PLAT[0]*8 - 16);
		h.vy = 0.0;
		h.dir = PDIR[0];
		h.live = 1;
		h.spin = 0;
		h.scored = 0;
		hazards[i] = h;
		return;
	}
}

# Which platform row a y sits on, or -1.  A hazard picks its direction
# from the row it lands on, which is what makes the zigzag a property of
# the map rather than of the hazard.
platrow(y: int): int
{
	for(i := 0; i < len PLAT; i++)
		if(PLAT[i]*8 == y + 16)
			return i;
	return -1;
}

step()
{
	frames++;
	if(tiles != nil)
		tone->sfxtick();
	if(dead > 0){
		dead--;
		if(dead == 0){
			if(lives <= 0)
				newgame();
			else
				newlevel();
		}
		return;
	}
	if(won > 0){
		won--;
		if(won == 0){
			level++;
			newlevel();
		}
		return;
	}
	stepplayer();
	stephaz();
	if(--spawn_t <= 0){
		spawnhaz();
		spawn_t = 150 - level*8;
		if(spawn_t < 45)
			spawn_t = 45;
	}
	if(hot > 0)
		hot--;
	prevpad = pad;
}

stepplayer()
{
	# A ladder is climbable when the climber's middle is on one.
	onlad := cellat(int px + 8, int py + 8) == LADDER;
	below := cellat(int px + 8, int py + 16) == LADDER;
	if(pclimb){
		if(pad & KUP)
			py -= 1.0;
		if(pad & KDOWN)
			py += 1.0;
		if(pad & (KUP|KDOWN))
			panim++;
		# Off the top of a ladder onto the girder above, or off the
		# bottom onto the one below.
		if(!onlad && !below){
			pclimb = 0;
			pvy = 0.0;
			snapup();
		}else if(!onlad && below && (pad & KDOWN) == 0)
			;
	}else{
		if((pad & KLEFT) && !(pad & KRIGHT)){
			px -= 1.0;
			pface = -1;
			panim++;
		}else if((pad & KRIGHT) && !(pad & KLEFT)){
			px += 1.0;
			pface = 1;
			panim++;
		}
		if(px < 0.0)
			px = 0.0;
		if(px > real (W-16))
			px = real (W-16);
		pground = grounded();
		if(pground && (pad & KUP) && onlad){
			pclimb = 1;
			px = real ((int px + 8) / 8 * 8 - 4);
			pvy = 0.0;
		}else if(pground && (pad & KDOWN) && cellat(int px + 8, int py + 17) == LADDER){
			pclimb = 1;
			px = real ((int px + 8) / 8 * 8 - 4);
			py += 2.0;
			pvy = 0.0;
		}else if(pground && (keyhold->edge(pad, prevpad) & KA)){
			pvy = -3.4;
			pground = 0;
			tone->sfx(2, 640, 70);
		}
		if(!pground){
			pvy += 0.22;
			if(pvy > 4.0)
				pvy = 4.0;
			old := int py + 16;
			py += pvy;
			if(pvy > 0.0){
				y := land(old, int py + 16, int px);
				if(y >= 0){
					py = real (y - 16);
					pvy = 0.0;
				}
			}
		}
	}
	if(py > real H){
		hurt();
		return;
	}
	if(int py + 16 <= PLAT[0]*8 && int px > 13*8 - 12 && int px < 15*8 + 4){
		won = 90;
		score += 500 + 100*level;
		tone->sfx(4, 1200, 400);
		return;
	}
	if(hot == 0 && !gotmallet && overmallet()){
		gotmallet = 1;
		hot = 420;
		tone->sfx(3, 900, 200);
	}
	# Hazards.
	for(i := 0; i < NHAZ; i++){
		h := hazards[i];
		if(h == nil || !h.live)
			continue;
		if(!overlap(int px, int py, int h.x, int h.y))
			continue;
		if(hot > 0){
			h.live = 0;
			score += 300;
			tone->sfx(3, 1500, 90);
		}else
			hurt();
		return;
	}
}

gotmallet := 0;

overmallet(): int
{
	if(gotmallet)
		return 0;
	mx := MALLETX;
	my := MALLETROW*8 - 16;
	return overlap(int px, int py, mx, my);
}

overlap(ax, ay, bx, by: int): int
{
	return ax + 13 > bx + 2 && ax + 2 < bx + 13
		&& ay + 14 > by + 2 && ay + 2 < by + 14;
}

# Standing means the feet are exactly on a girder's top edge, not
# merely somewhere inside a girder tile.  "Inside" was the first version
# and it is wrong in a way that only shows up as a number: a girder tile
# is eight pixels deep, so a jump that rose 26 could land on a ledge 32
# above by finishing seven pixels inside it, and the climber went up the
# tower on jumps alone.  land() below is the other half of the same
# rule.
# One footprint, used by everything that stands on a girder.  It was
# three: the climber tested pixels 3 and 12 of its sixteen, the hazard 4
# and 11, and land() 3 and 12 again - so a hazard could roll to a place
# where the fall test said it was over thin air and the landing test
# said it was on the beam, and it hung at the end of the platform
# forever.  Two numbers that must agree should be one number.
support(x, ty: int): int
{
	return cell((x + 3) / 8, ty) == GIRDER || cell((x + 12) / 8, ty) == GIRDER;
}

onedge(x, feet: int): int
{
	return (feet & 7) == 0 && support(x, feet / 8);
}

grounded(): int
{
	return onedge(int px, int py + 16);
}

# Falling from feet at y0 to feet at y1: the topmost girder edge crossed
# on the way, or -1.  Only edges are collided with, so a girder can be
# jumped up through from below and only caught on the way down - which
# is what makes a stack of platforms climbable rather than a solid wall.
land(y0, y1, x: int): int
{
	for(y := (y0 + 7) & ~7; y <= y1; y += 8){
		if(support(x, y / 8))
			return y;
	}
	return -1;
}

snapup()
{
	py = real ((int py + 16) / 8 * 8 - 16);
}

hurt()
{
	lives--;
	score -= 0;
	dead = 90;
	tone->sfx(5, 180, 500);
}

stephaz()
{
	sp := hazspeed();
	for(i := 0; i < NHAZ; i++){
		h := hazards[i];
		if(h == nil || !h.live)
			continue;
		h.spin++;
		ground := onedge(int h.x, int h.y + 16);
		if(!ground){
			h.vy += 0.25;
			if(h.vy > 4.0)
				h.vy = 4.0;
			old := int h.y + 16;
			h.y += h.vy;
			if(h.vy > 0.0){
				y := land(old, int h.y + 16, int h.x);
				if(y >= 0){
					h.y = real (y - 16);
					h.vy = 0.0;
					r := platrow(int h.y);
					if(r >= 0)
						h.dir = PDIR[r];
				}
			}
		}else{
			h.vy = 0.0;
			h.x += sp * real h.dir;
		}
		if(h.x < -20.0 || h.x > real (W + 20) || h.y > real (H + 20))
			h.live = 0;
		# Jumped clean over: the climber is airborne and the hazard is
		# under their feet.  Worth points, as it always has been.
		if(!h.scored && !pground && !pclimb
		&& int h.y > int py + 10 && int h.y < int py + 26
		&& int h.x + 14 > int px && int h.x < int px + 14){
			h.scored = 1;
			score += 100;
			tone->sfx(2, 1500, 60);
		}
	}
}

draw1()
{
	bg.blit(scr, 0, 0);
	# the prize at the top
	scr.put16(13*8, PLAT[0]*8 - 16, TPRIZE, pprize, 0);
	if(!gotmallet)
		scr.put16(MALLETX, MALLETROW*8 - 16, TMALLET, pmallet, 0);
	for(i := 0; i < NHAZ; i++){
		h := hazards[i];
		if(h == nil || !h.live)
			continue;
		t := THAZARD;
		if((h.spin / 6 & 1) != 0)
			t = THAZARD2;
		scr.put16(int h.x, int h.y, t, phaz, 0);
	}
	if(dead == 0 || (dead & 4) != 0)
		drawplayer();
	hud();
}

drawplayer()
{
	p := pskin;
	if(hot > 0 && (frames & 4) != 0)
		p = pflash;
	t := TPLAYER;
	f := 0;
	if(pclimb){
		t = TCLIMB;
		if((panim / 8 & 1) != 0)
			t = TCLIMB2;
	}else{
		if(!pground)
			t = TWALK;
		else if(pad & (KLEFT|KRIGHT))
			if((panim / 6 & 1) != 0)
				t = TWALK;
		if(pface < 0)
			f = Tiles->FLIPX;
	}
	scr.put16(int px, int py, t, p, f);
}

hud()
{
	scr.text(8, 4, "SCORE " + pad0(score, 6), phud);
	scr.text(8*16, 4, "LEVEL " + pad0(level, 2), phud);
	scr.text(8*25, 4, "MEN " + pad0(lives, 1), phud);
	if(hot > 0)
		scr.text(8*11, 8*2, "MALLET", pflash);
	if(dead > 0 && lives <= 0)
		scr.text(8*11, 8*14, "GAME OVER", pflash);
	if(won > 0)
		scr.text(8*12, 8*14, "TOP OF", pflash);
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

savebest()
{
	if(score > best && scorestore != nil)
		scorestore->saveint("rivet", score);
}

# -s: play a scripted opening and write the frame out as a Plan 9 image,
# so what the game actually looks like can be seen from outside it.
shot()
{
	audio = 0;
	newgame();
	for(i := 0; i < 200; i++){
		pad = 0;
		if(i > 40 && i < 150)
			pad = KRIGHT;
		if(i == 100)
			pad = KRIGHT|KA;
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
	fd := sys->create("rivet.raw", Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->print("create: %r\n");
		return;
	}
	sys->write(fd, b, len b);
	sys->print("wrote rivet.raw %dx%d bgr\n", w, h);
}

# ---------------------------------------------------------------- test
#
# The point of this is that it drives the SAME step() the game loop
# drives, with the same pad, and asserts on game state rather than on
# pixels: a count of lit pixels cannot tell a climber walking from one
# stuck against a wall.  draw1() is called too, so a drawing fault is
# still a crash here.

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

selftest()
{
	sys->print("rivet: self test\n");
	audio = 0;
	# The map is the thing everything else stands on.
	cktrue("map is 30 rows", len MAP == NTH);
	for(i := 0; i < len MAP; i++)
		if(len MAP[i] != NTW){
			sys->print("FAIL map row %d is %d wide, want %d\n",
				i, len MAP[i], NTW);
			nfail++;
		}
	for(i = 0; i < len PLAT; i++)
		cktrue("platform row " + string PLAT[i] + " is girder",
			cell(NTW/2, PLAT[i]) == GIRDER);

	# Standing still on the ground, and gravity holding.
	newgame();
	y0 := int py;
	run(10, 0);
	ck("stood still, x", int px, STARTX);
	ck("stood still, y", int py, y0);
	cktrue("on the ground", grounded());

	# Walking right moves right, and one pixel a frame is one pixel a
	# frame - a walk that silently doubled would still "work".
	run(30, KRIGHT);
	ck("walked right 30 frames", int px, STARTX + 30);
	cktrue("faces right", pface == 1);
	run(10, KLEFT);
	ck("walked back 10", int px, STARTX + 20);
	cktrue("faces left", pface == -1);

	# The left wall.
	run(60, KLEFT);
	ck("stopped at the wall", int px, 0);

	# A jump leaves the ground and comes back to exactly the same row.
	newlevel();
	yj := int py;
	pad = 0; prevpad = 0;
	step();				# so PA is an edge, not a held key
	run(1, KA);
	cktrue("jump left the ground", int py < yj);
	run(60, 0);
	ck("jump landed back", int py, yj);
	cktrue("landed on the ground", grounded());

	# A ladder: walk to the one at tile x=7 and climb it.
	newlevel();
	lx := 7*8 - 4;
	while(int px < lx)
		run(1, KRIGHT);
	run(1, 0);
	yl := int py;
	run(20, KUP);
	cktrue("climbing", pclimb != 0);
	cktrue("climbed up the ladder", int py < yl - 10);
	run(30, KDOWN);
	cktrue("climbed back down", int py >= yl - 4);

	# A hazard rolls, falls, and reverses on the row it lands on.
	# Hold the hazard by reference, not by slot: spawnhaz() reuses a
	# slot as soon as its occupant dies, so checking hazards[0] after
	# the fact can be checking a different hazard entirely.  That cost
	# two false failures before it was noticed.
	newlevel();
	hz := ref Hazard(real (6*8), real (PLAT[0]*8-16), 0.0,
		PDIR[0], 1, 0, 0);
	hazards[0] = hz;
	x0 := int hz.x;
	run(30, 0);
	cktrue("hazard rolled the way its platform says",
		(int hz.x - x0) * PDIR[0] > 0);
	# Let it run off the end and land on the next platform down.
	for(i = 0; i < 1200 && hz.live && int hz.y + 16 < PLAT[1]*8; i++)
		run(1, 0);
	cktrue("hazard reached the second platform",
		hz.live && int hz.y + 16 == PLAT[1]*8);
	ck("and turned round", hz.dir, PDIR[1]);

	# Being hit costs a life; the mallet turns the same contact into
	# points.  Both are forced by putting a hazard on the climber, which
	# is the only way this path runs on demand.
	newlevel();
	lv := lives;
	hazards[0] = ref Hazard(px, py, 0.0, 1, 1, 0, 0);
	run(1, 0);
	ck("hit costs a life", lives, lv-1);
	newlevel();
	hot = 60;
	sc := score;
	hz2 := ref Hazard(px, py, 0.0, 1, 1, 0, 0);
	hazards[0] = hz2;
	run(1, 0);
	cktrue("mallet destroys instead", !hz2.live);
	ck("and scores", score, sc + 300);
	ck("and costs no life", lives, lv-1);

	# Reaching the top ends the level and the next one is faster.
	newlevel();
	lvl := level;
	s0 := hazspeed();
	px = real (14*8 - 4);
	py = real (PLAT[0]*8 - 16);
	run(1, 0);
	cktrue("reaching the top wins the level", won > 0);
	run(95, 0);
	ck("level advanced", level, lvl+1);
	cktrue("and the hazards are faster", hazspeed() > s0);

	if(nfail == 0)
		sys->print("rivet: PASSED\n");
	else{
		sys->print("rivet: FAILED (%d)\n", nfail);
		raise "fail:test";
	}
}
