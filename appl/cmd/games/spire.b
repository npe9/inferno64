implement Spire;

#
# Spire - a climb up a tower, in the shape that genre took: the view
# goes up and does not come back down, the world wraps left to right so
# there is no edge to fall off, only a top to reach - and there are
# doors in the wall that lead somewhere with entirely different rules.
#
# The doors are why this game is in the tree.  A room here is a MOUNT.
# Going through a door runs a program that serves four files over Styx
# and mounts what it serves on /n/room; the game then reads the room's
# name out of a file, reads what it has to offer out of a file, and
# writes to a file to take something.  Coming back out is an unmount,
# and the room's process ends with the connection, which is why neither
# of the two rooms in this tree has to remember anything between visits:
# the namespace is the lifetime.
#
# Nothing in this program knows one room from another.  Which program is
# behind which door is /lib/tiles/spire.doors, and the vocabulary the
# game understands is three words - jump, shield, heart.  A room decides
# what it stocks, what it charges, and what it will refuse.  Adding a
# room means writing a server and adding a line to that file; it does
# not mean changing this.  See roomsrv(2) and spireshop(1).
#
# There is deliberately no fallback.  If the mount fails the door does
# not open and says why.  A game that could show a shop without having
# mounted one would be a game whose shop was decoration, and a test of
# it would pass on the decoration.
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

include "roomsrv.m";
	roomsrv: Roomsrv;

Spire: module
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

ARTFILE:	con "/lib/tiles/spire.art";
MAPFILE:	con "/lib/tiles/spire.map";
DOORFILE:	con "/lib/tiles/spire.doors";
MNT:		con "/n/room";

# what the legend characters mean
CSKY:	con '.';
CSTONE:	con '#';
CLEDGE:	con '=';
CDOOR:	con 'D';
CCOIN:	con 'o';
CCLOUD:	con '~';
CTOP:	con '^';

# the machines in spire16.chr, after sheet16 has cut them
MSTAND:	con 0;
MCLIMB:	con 4;
MAIR:	con 8;
MFOE:	con 12;

# what the game does about a ware.  A room may stock any of these, at
# any price, or none of them; it may not invent a fourth, because this
# is the whole of what the climb knows how to be changed by.
WJUMP:	con "jump";
WSHIELD: con "shield";
WHEART:	con "heart";

GRAV:	con 0.42;
VMAX:	con 1.9;
ACC:	con 0.32;
FRIC:	con 0.28;
JUMPV:	con -6.3;
HIJUMPV: con -7.6;
TERM:	con 7.0;
PW:	con 16;			# the climber's box
PH:	con 16;

# modes
MCLIMBING, MROOM, MWON, MOVER: con iota;

Door: adt {
	x, y:	int;			# the cell the door stands in
	prog:	string;
};

Ware: adt {
	key:	string;
	price:	int;
	text:	string;
};

Foe: adt {
	x, y:	real;
	vx:	real;
	live:	int;
};

# --- the climber ---
px, py:	real;			# top left of the box, world pixels
vx, vy:	real;
onground: int;
face:	int;
walkf:	int;
lives:	int;
coins:	int;
shield:	int;
hijump:	int;
spawnx, spawny: real;
cam:	int;
mode:	int;
frames:	int;
hurt:	int;			# frames of invulnerability after a knock

pad, prevpad: int;
nofolk:	int;			# the self test's negative control

LW, LH:	int;			# the tower, in tiles
grid:	array of string;
doors:	array of ref Door;
foes:	array of ref Foe;

# --- the room ---
rname:	string;
rwares:	array of ref Ware;
rsel:	int;
rmsg:	string;
rbad:	int;
inroom:	int;

scn:	ref Screen;
scr, world: ref Surface;
tower, folk: ref Chr;
pyou, pfoe, phud, pwarn, pgood: ref Pal;
sky, panel: int;

win:	ref Window;
testmode: int;
shotroom: int;
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
	roomsrv = load Roomsrv Roomsrv->PATH;
	if(tiles == nil){
		sys->fprint(sys->fildes(2), "spire: cannot load tiles: %r\n");
		raise "fail:load";
	}
	if(roomsrv == nil){
		sys->fprint(sys->fildes(2), "spire: cannot load roomsrv: %r\n");
		raise "fail:load";
	}
	e := tiles->init();
	if(e != nil){
		sys->fprint(sys->fildes(2), "spire: %s\n", e);
		raise "fail:init";
	}
	e = roomsrv->init();
	if(e != nil){
		sys->fprint(sys->fildes(2), "spire: %s\n", e);
		raise "fail:init";
	}
	if(fclock != nil)
		fclock->init();
	for(a := tl argv; a != nil; a = tl a){
		case hd a {
		"-t" =>	testmode = 1;
		"-s" =>	testmode = 2;
		"-r" =>	shotroom = 1;
		"-q" =>	audio = -1;
		* =>
			sys->fprint(sys->fildes(2), "usage: spire [-t | -s [-r]] [-q]\n");
			raise "fail:usage";
		}
	}

	# A namespace of its own, in EVERY mode.  Put this in the branch
	# that makes a window and the self test mounts rooms into the
	# namespace of whatever started it and leaves them there.
	sys->pctl(Sys->FORKNS, nil);
	# Somewhere to mount them.  /n here has a fixed set of names and
	# room is not one of them; mntgen(4) is what makes a mount point
	# appear when it is walked to, which is exactly the want.
	me := roomsrv->mountprog("/dis/mntgen.dis", "mntgen" :: nil, "/n",
		Sys->MAFTER);
	if(me != nil){
		sys->fprint(sys->fildes(2), "spire: %s\n", me);
		raise "fail:mntgen";
	}

	d: ref Display;
	if(testmode){
		d = Display.allocate(nil);
		if(d == nil){
			sys->fprint(sys->fildes(2), "spire: no display: %r\n");
			raise "fail:display";
		}
	}else{
		wmclient = load Wmclient Wmclient->PATH;
		sys->pctl(Sys->NEWPGRP, nil);
		wmclient->init();
		if(ctxt == nil)
			ctxt = wmclient->makedrawcontext();
		win = wmclient->window(ctxt, "Spire", Wmclient->Appl);
		d = win.display;
	}
	setup(d);
	if(audio == 0 && playing() && tone != nil && tone->init() == nil)
		audio = 1;
	newgame();
	if(testmode == 1){
		{
			selftest();
		}exception{
		* =>
			cleanup();
			raise;
		}
		cleanup();
		return;
	}
	if(testmode == 2){
		shot();
		cleanup();
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
		sys->fprint(sys->fildes(2), "spire: %s\n", r);
		raise "fail:cmd";
	}
}

runcmds(path: string)
{
	(b, err) := slurp(path);
	if(err != nil){
		sys->fprint(sys->fildes(2), "spire: %s\n", err);
		raise "fail:art";
	}
	(nil, lines) := sys->tokenize(string b, "\n");
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		if(len l == 0 || l[0] == ';')
			continue;
		docmd(l);
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

# How big the tower is, before there is anywhere to paint it.  The map
# file is what says, not a constant here, because the map file is what
# somebody edits.
mapsize(path: string): (int, int, string)
{
	(b, err) := slurp(path);
	if(err != nil)
		return (0, 0, err);
	(nil, lines) := sys->tokenize(string b, "\n");
	body := 0;
	w := 0;
	h := 0;
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		if(len l == 0 || l[0] == ';')
			continue;
		if(!body){
			if(l == "%")
				body = 1;
			continue;
		}
		if(w == 0)
			w = len l;
		else if(len l != w)
			return (0, 0, sys->sprint("%s: row %d is %d wide, want %d",
				path, h, len l, w));
		h++;
	}
	if(w != W/8)
		return (0, 0, sys->sprint("%s: the tower must be %d tiles wide, it is %d",
			path, W/8, w));
	if(h < H/8 + 4)
		return (0, 0, path + ": the tower is shorter than the screen");
	return (w, h, nil);
}

setup(d: ref Display)
{
	scn = tiles->screen(d, Draw->RGB24, SCALE);
	if(scn == nil){
		sys->fprint(sys->fildes(2), "spire: no screen\n");
		raise "fail:screen";
	}
	runcmds(ARTFILE);
	sky = colourof("csky");
	panel = colourof("cpanel");

	(mw, mh, err) := mapsize(MAPFILE);
	if(err != nil){
		sys->fprint(sys->fildes(2), "spire: %s\n", err);
		raise "fail:map";
	}
	LW = mw;
	LH = mh;

	docmd(sys->sprint("surface scr %d %d %d", W, H, sky));
	docmd(sys->sprint("surface world %d %d %d", LW*8, LH*8, sky));
	docmd("map world tower " + MAPFILE);

	scr = scn.named("scr");
	world = scn.named("world");
	tower = scn.sheet("tower");
	folk = scn.sheet("folk");
	pyou = scn.pal("pyou");
	pfoe = scn.pal("pfoe");
	phud = scn.pal("phud");
	pwarn = scn.pal("pwarn");
	pgood = scn.pal("pgood");
	grid = scn.grid("world");
	if(scr == nil || world == nil || tower == nil || folk == nil || grid == nil){
		sys->fprint(sys->fildes(2), "spire: the screen made nothing\n");
		raise "fail:screen";
	}
	readdoors();
}

colourof(name: string): int
{
	p := scn.pal(name);
	if(p == nil || len p.c == 0){
		sys->fprint(sys->fildes(2), "spire: %s: no such colour\n", name);
		raise "fail:art";
	}
	return p.c[0];
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

readdoors()
{
	(b, err) := slurp(DOORFILE);
	if(err != nil){
		sys->fprint(sys->fildes(2), "spire: %s\n", err);
		raise "fail:doors";
	}
	out := array[8] of ref Door;
	n := 0;
	ln := 0;
	(nil, lines) := sys->tokenize(string b, "\n");
	for(; lines != nil; lines = tl lines){
		ln++;
		l := hd lines;
		if(len l > 0 && l[0] == ';')
			continue;
		(nw, w) := sys->tokenize(l, " \t");
		if(nw == 0)
			continue;
		where := sys->sprint("%s:%d: ", DOORFILE, ln);
		if(nw != 3)
			barf(where + "a door is X Y PROGRAM");
		(x, xok) := number(hd w);
		(y, yok) := number(hd tl w);
		if(!xok || !yok)
			barf(where + "not a number");
		if(x < 0 || x >= LW || y < 0 || y >= LH)
			barf(where + "off the tower");
		if(grid[y][x] != CDOOR)
			barf(sys->sprint("%sthere is no door at %d %d", where, x, y));
		if(n >= len out){
			a := array[2 * len out] of ref Door;
			a[0:] = out[0:n];
			out = a;
		}
		out[n++] = ref Door(x, y, hd tl tl w);
	}
	if(n == 0)
		barf(DOORFILE + ": no doors");
	doors = out[0:n];
}

# Give back everything mounted.  A server here lives as long as its
# connection, so this is also what ends their processes - and without it
# the game exits and emu does not, because mntgen is still serving.
cleanup()
{
	leaveroom();
	sys->unmount(nil, "/n");
}

barf(s: string)
{
	sys->fprint(sys->fildes(2), "spire: %s\n", s);
	raise "fail:data";
}

# --------------------------------------------------------------- rules

fl(v: real): int
{
	i := int v;
	if(real i > v)
		i--;
	return i;
}

wrapx(x: real): real
{
	ww := real (LW*8);
	while(x < 0.0)
		x += ww;
	while(x >= ww)
		x -= ww;
	return x;
}

cellat(tx, ty: int): int
{
	if(ty < 0 || ty >= LH)
		return CSKY;
	tx = ((tx % LW) + LW) % LW;
	return grid[ty][tx];
}

cellpx(x, y: int): int
{
	return cellat(fl(real x / 8.0), fl(real y / 8.0));
}

solid(c: int): int
{
	return c == CSTONE;
}

# something the feet can come to rest on
floorish(c: int): int
{
	return c == CSTONE || c == CLEDGE;
}

newgame()
{
	lives = 3;
	coins = 0;
	shield = 0;
	hijump = 0;
	mode = MCLIMBING;
	frames = 0;
	# the floor is the bottom two rows; stand on top of it
	px = 24.0;
	py = real ((LH-2)*8 - PH);
	spawnx = px;
	spawny = py;
	vx = vy = 0.0;
	onground = 1;
	hurt = 0;
	cam = LH*8 - H;
	pad = prevpad = 0;
	spawnfoes();
}

spawnfoes()
{
	# One drifter for every sixth ledge row, placed from the map rather
	# than from a table here, so editing the tower moves them too.
	n := 0;
	for(ty := 6; ty < LH-4; ty++)
		if(ty % 6 == 0)
			n++;
	foes = array[n] of ref Foe;
	i := 0;
	for(ty = 6; ty < LH-4; ty++){
		if(ty % 6 != 0)
			continue;
		v := 0.55;
		if((ty/6) & 1)
			v = -0.55;
		foes[i++] = ref Foe(real ((ty*7) % (LW*8)), real (ty*8 - 20), v, 1);
	}
}

respawn()
{
	px = spawnx;
	py = spawny;
	vx = vy = 0.0;
	onground = 1;
	hurt = 90;
}

knock()
{
	if(hurt > 0)
		return;
	if(shield > 0){
		shield--;
		hurt = 90;
		sfx(1, 500, 80);
		return;
	}
	sfx(2, 120, 300);
	if(--lives <= 0){
		lives = 0;
		mode = MOVER;
		return;
	}
	respawn();
}

step()
{
	if(mode != MCLIMBING)
		return;
	frames++;
	edge := pad & ~prevpad;
	prevpad = pad;
	if(hurt > 0)
		hurt--;

	# sideways
	if(pad & KLEFT){
		vx -= ACC;
		face = 1;
	}else if(pad & KRIGHT){
		vx += ACC;
		face = 0;
	}else{
		if(vx > FRIC)
			vx -= FRIC;
		else if(vx < -FRIC)
			vx += FRIC;
		else
			vx = 0.0;
	}
	if(vx > VMAX)
		vx = VMAX;
	if(vx < -VMAX)
		vx = -VMAX;

	ox := px;
	px = wrapx(px + vx);
	if(hitstone()){
		px = ox;
		vx = 0.0;
	}

	# a door, if standing in one and asking
	if((edge & KUP) && onground){
		d := doorhere();
		if(d != nil){
			enterroom(d);
			return;
		}
	}

	# jumping
	if((edge & KA) && onground){
		v := JUMPV;
		if(hijump)
			v = HIJUMPV;
		vy = v;
		onground = 0;
		sfx(1, 330, 50);
	}
	# Let go early and the rise stops: the jump is as high as it is
	# held.  The floor on this was -1.6, which is so low that a tapped
	# jump rose three pixels and could not clear anything.
	if(!(pad & KA) && vy < -3.0)
		vy = -3.0;

	vy += GRAV;
	if(vy > TERM)
		vy = TERM;
	oy := py;
	py += vy;
	onground = 0;
	if(vy > 0.0){
		t := landing(oy, py);
		if(t >= 0){
			py = real (t - PH);
			vy = 0.0;
			onground = 1;
			spawnx = px;
			spawny = py;
		}
	}else if(vy < 0.0){
		# a head on stone, and only stone: a ledge is passed through
		if(solid(cellpx(int px + 2, int py)) || solid(cellpx(int px + PW - 3, int py))){
			py = real ((fl(py / 8.0) + 1) * 8);
			vy = 0.0;
		}
	}

	pickups();
	stepfoes();

	# the camera climbs and does not come back down, so what has been
	# passed is gone and falling has a cost
	want := int py - 150;
	if(want < cam)
		cam = want;
	if(cam < 0)
		cam = 0;
	if(py > real (cam + H))
		knock();
}

# Does the box overlap stone anywhere?  Stone is the only thing that
# stops sideways movement, and the check is over the whole box because a
# pillar is two tiles tall and a one-point probe walked through it.
hitstone(): int
{
	for(dy := 1; dy < PH; dy += 6)
		if(solid(cellpx(int px + 1, int py + dy))
		|| solid(cellpx(int px + PW - 2, int py + dy)))
			return 1;
	return 0;
}

# The top of the first surface crossed by the feet between y0 and y1,
# or -1.  Both columns of the box are asked: standing half on the end of
# a ledge has to count.
landing(y0, y1: real): int
{
	f0 := y0 + real PH;
	f1 := y1 + real PH;
	t0 := fl(f0 / 8.0);
	t1 := fl(f1 / 8.0);
	for(ty := t0; ty <= t1; ty++){
		top := real (ty * 8);
		if(top < f0 - 0.001 || top > f1)
			continue;
		if(floorish(cellat(fl(real (int px + 1) / 8.0), ty))
		|| floorish(cellat(fl(real (int px + PW - 2) / 8.0), ty)))
			return ty * 8;
	}
	return -1;
}

pickups()
{
	for(dx := 1; dx < PW; dx += 7)
		for(dy := 1; dy < PH; dy += 7){
			tx := ((fl(real (int px + dx) / 8.0) % LW) + LW) % LW;
			ty := fl(real (int py + dy) / 8.0);
			if(ty < 0 || ty >= LH)
				continue;
			case grid[ty][tx] {
			CCOIN =>
				coins++;
				sfx(1, 700, 40);
				docmd(sys->sprint("set world %d %d blank", tx, ty));
			CTOP =>
				mode = MWON;
			}
		}
}

stepfoes()
{
	ww := real (LW*8);
	for(i := 0; i < len foes; i++){
		f := foes[i];
		if(!f.live)
			continue;
		f.x += f.vx;
		if(f.x < 0.0)
			f.x += ww;
		if(f.x >= ww)
			f.x -= ww;
		if(!nofolk && overlaps(f))
			knock();
	}
}

# Two boxes touching, across the seam as well as away from it.
overlaps(f: ref Foe): int
{
	ww := real (LW*8);
	dx := f.x - px;
	if(dx > ww/2.0)
		dx -= ww;
	if(dx < -ww/2.0)
		dx += ww;
	if(dx < 0.0)
		dx = -dx;
	dy := f.y - py;
	if(dy < 0.0)
		dy = -dy;
	return dx < real (PW-4) && dy < real (PH-4);
}

doorhere(): ref Door
{
	tx := ((fl(real (int px + PW/2) / 8.0) % LW) + LW) % LW;
	ty := fl(real (int py + PH/2) / 8.0);
	for(i := 0; i < len doors; i++)
		if(doors[i].x == tx && doors[i].y == ty)
			return doors[i];
	return nil;
}

sfx(pri, freq, ms: int)
{
	if(audio == 1 && tone != nil)
		tone->sfx(pri, freq, ms);
}

# ---------------------------------------------------------------- rooms

readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	s := "";
	b := array[4096] of byte;
	for(;;){
		n := sys->read(fd, b, len b);
		if(n < 0)
			return (nil, sys->sprint("cannot read %s: %r", path));
		if(n == 0)
			break;
		s += string b[0:n];
		if(len s > 64*1024)
			break;
	}
	return (s, nil);
}

writectl(s: string): string
{
	fd := sys->open(MNT + "/ctl", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("cannot open the room's ctl: %r");
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("%r");
	return nil;
}

chomp(s: string): string
{
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == ' '))
		s = s[0:len s-1];
	return s;
}

enterroom(d: ref Door): string
{
	e := roomsrv->mountprog(d.prog, "room" :: nil, MNT, Sys->MREPL);
	if(e != nil){
		# No shop appears.  There is nothing to fall back to and that
		# is on purpose: a door that opened onto something built into
		# this program would make the mount decoration.
		rmsg = e;
		rbad = 1;
		mode = MCLIMBING;
		return e;
	}
	inroom = 1;
	(n, ne) := readfile(MNT + "/name");
	if(ne != nil){
		leaveroom();
		rmsg = ne;
		rbad = 1;
		return ne;
	}
	rname = chomp(n);
	# The room is told what is being carried; what it makes of that is
	# its business, and one of the two rooms here ignores it entirely.
	writectl(sys->sprint("coins %d", coins));
	loadwares();
	rsel = 0;
	rmsg = "up/down choose  x take  esc go";
	rbad = 0;
	mode = MROOM;
	prevpad = pad = 0;
	return nil;
}

loadwares()
{
	(txt, e) := readfile(MNT + "/wares");
	if(e != nil){
		rwares = array[0] of ref Ware;
		return;
	}
	out := array[16] of ref Ware;
	n := 0;
	(nil, lines) := sys->tokenize(txt, "\n");
	for(; lines != nil; lines = tl lines){
		(nw, w) := sys->tokenize(hd lines, " \t");
		if(nw < 2)
			continue;
		(price, pok) := number(hd tl w);
		if(!pok)
			continue;
		if(n >= len out){
			a := array[2 * len out] of ref Ware;
			a[0:] = out[0:n];
			out = a;
		}
		out[n++] = ref Ware(hd w, price, joinwords(tl tl w));
	}
	rwares = out[0:n];
	if(rsel >= n)
		rsel = n - 1;
	if(rsel < 0)
		rsel = 0;
}

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

take()
{
	if(len rwares == 0){
		rmsg = "there is nothing here";
		rbad = 1;
		return;
	}
	w := rwares[rsel];
	e := writectl("buy " + w.key);
	if(e != nil){
		# The room's own refusal, in the room's own words.
		rmsg = e;
		rbad = 1;
		return;
	}
	(st, se) := readfile(MNT + "/status");
	if(se != nil){
		rmsg = se;
		rbad = 1;
		return;
	}
	(nw, a) := sys->tokenize(chomp(st), " \t");
	if(nw < 3 || hd a != "ok"){
		rmsg = "the room said: " + chomp(st);
		rbad = 1;
		return;
	}
	key := hd tl a;
	(price, nil) := number(hd tl tl a);
	# What was spent is what the ROOM says was spent, not what the game
	# thought the price was.  A room may charge what it likes.
	coins -= price;
	if(coins < 0)
		coins = 0;
	rmsg = apply(key);
	rbad = 0;
	sfx(1, 640, 90);
	writectl(sys->sprint("coins %d", coins));
	loadwares();
}

# The three words the climb understands.  A room that offers anything
# else is not refused - it is simply taken and has no effect here, and
# says so, which is better than the game pretending to know.
apply(key: string): string
{
	case key {
	WJUMP =>
		hijump = 1;
		return "the boots are on";
	WSHIELD =>
		shield++;
		return "the charm is yours";
	WHEART =>
		lives++;
		return "one more try";
	}
	return key + " means nothing on the tower";
}

leaveroom()
{
	if(!inroom)
		return;
	# Unmounting is what ends the room: the server sees the connection
	# go and its process ends with it.
	sys->unmount(nil, MNT);
	inroom = 0;
	rwares = nil;
	rname = nil;
}

roomkey(k: int)
{
	case k {
	Keyboard->Up =>
		if(rsel > 0)
			rsel--;
	Keyboard->Down =>
		if(rsel < len rwares - 1)
			rsel++;
	'x' or 'X' or '.' or ' ' or '\n' =>
		take();
	16r1b or 'q' or 'Q' =>
		leaveroom();
		mode = MCLIMBING;
		# step out of the doorway, or up re-enters at once
		py -= 2.0;
		prevpad = pad = 0;
	}
}

# ---------------------------------------------------------------- draw

# The world is exactly one screen wide and wraps, so anything near the
# seam is in two places at once and has to be drawn twice.  A state
# assertion cannot see this; spire -t reads the pixels.
folkat(x, y, t: int, p: ref Pal, flags: int)
{
	old := scr.chr;
	scr.chr = folk;
	scr.put16(x, y, t, p, flags);
	if(x + PW > W)
		scr.put16(x - W, y, t, p, flags);
	if(x < 0)
		scr.put16(x + W, y, t, p, flags);
	scr.chr = old;
}

machine(): int
{
	if(!onground)
		return MAIR;
	if(vx > 0.3 || vx < -0.3){
		if((frames / 6) & 1)
			return MCLIMB;
	}
	return MSTAND;
}

draw1()
{
	if(mode == MROOM){
		drawroom();
		return;
	}
	world.view(scr, 0, cam);
	for(i := 0; i < len foes; i++){
		f := foes[i];
		if(!f.live)
			continue;
		y := int f.y - cam;
		if(y < -PH || y > H)
			continue;
		if(!nofolk)
			folkat(int f.x, y, MFOE, pfoe, 0);
	}
	if(!nofolk && (hurt == 0 || (frames & 2)))
		folkat(int px, int py - cam, machine(), pyou, face * Tiles->FLIPX);
	hud();
}

hud()
{
	scr.fill(Rect((0,0),(W, HUDH)), panel);
	scr.text(4, 4, "coins " + string coins, phud);
	scr.text(96, 4, "lives " + string lives, phud);
	s := "";
	if(hijump)
		s += "boots ";
	if(shield)
		s += "charm ";
	if(mode == MWON)
		s = "the top!";
	if(mode == MOVER)
		s = "no more tries";
	if(s != "")
		scr.text(168, 4, s, pgood);
}

# Trim a line to what fits from x to the right-hand edge.  A room's text
# is the room's business and may be any length; running off the screen is
# this program's fault, not the room's.
fit(str: string, x: int): string
{
	n := (W - 4 - x) / 8;
	if(n < 1)
		n = 1;
	if(len str > n)
		str = str[0:n];
	return str;
}

drawroom()
{
	scr.fill(Rect((0,0),(W, H)), panel);
	scr.text(8, 8, fit(rname, 8), pgood);
	scr.text(8, 24, "coins " + string coins, phud);
	y := 44;
	for(i := 0; i < len rwares; i++){
		w := rwares[i];
		mark := "  ";
		if(i == rsel)
			mark = "> ";
		scr.text(8, y, fit(mark + w.key + " " + string w.price, 8), phud);
		scr.text(8, y + 10, fit("    " + w.text, 8), phud);
		y += 24;
	}
	if(len rwares == 0)
		scr.text(8, 44, "nothing here now", phud);
	p := phud;
	if(rbad)
		p = pwarn;
	scr.text(4, H - 20, fit(rmsg, 4), p);
}

# ----------------------------------------------------------- the loop

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
		if(mode == MROOM){
			roomkey(k);
			continue;
		}
		if(k == 16r1b || k == 'q' || k == 'Q'){
			cleanup();
			if(tone != nil)
				tone->stop();
			exit;
		}
		if(k == '\n' && (mode == MWON || mode == MOVER)){
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

# ----------------------------------------------------------- screenshot

run1(held: int)
{
	pad = held;
	step();
}

shot()
{
	audio = 0;
	newgame();
	for(i := 0; i < 240; i++){
		pad = KRIGHT;
		if((i % 30) < 10)
			pad |= KA;
		step();
		draw1();
	}
	if(shotroom){
		# Stand in the first door and go in, so there is a picture of
		# a room and not only of the climb.
		d := doors[0];
		px = wrapx(real (d.x*8 + 4 - PW/2));
		py = real (d.y*8 - 8);
		vx = vy = 0.0;
		onground = 1;
		mode = MCLIMBING;
		prevpad = pad = 0;
		coins = 120;
		run1(KUP);
		draw1();
	}
	w := scr.img.r.dx();
	h := scr.img.r.dy();
	b := array[w*h*3] of byte;
	if(scr.img.readpixels(scr.img.r, b) < 0){
		sys->print("readpixels: %r\n");
		return;
	}
	fd := sys->create("spire.raw", Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->print("create: %r\n");
		return;
	}
	sys->write(fd, b, len b);
	sys->print("wrote spire.raw %dx%d bgr\n", w, h);
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
	w := cq.dx();
	h := cq.dy();
	b := array[w*h*3] of byte;
	if(scr.img.readpixels(cq, b) < 0)
		return -1;
	sum := 0;
	for(i := 0; i < len b; i += 3)
		sum = (sum * 31 + int b[i]) & 16r3FFFFFFF;
	return sum;
}

readable(path: string): int
{
	fd := sys->open(path, Sys->OREAD);
	return fd != nil;
}

# stand in a door, on the ground, ready to press up
standin(d: ref Door)
{
	mode = MCLIMBING;
	# centred on the door cell, feet on the ledge below it: the box is
	# two tiles wide and a door is one, and it is the box's middle that
	# asks whether there is a door here
	px = wrapx(real (d.x*8 + 4 - PW/2));
	py = real (d.y*8 - 8);
	vx = vy = 0.0;
	onground = 1;
	hurt = 0;
	prevpad = pad = 0;
}

selftest()
{
	sys->print("spire: self test\n");
	audio = 0;

	# --- the data ---
	cktrue("the tower was read", LH > H/8 && LW == W/8);
	ck("and the grid has that many rows", len grid, LH);
	cktrue("there are doors", len doors >= 2);
	two := 0;
	if(len doors >= 2 && doors[0].prog != doors[1].prog)
		two = 1;
	cktrue("and two different programs behind them", two);
	for(i := 0; i < len doors; i++)
		cktrue("a door stands on a door cell",
			cellat(doors[i].x, doors[i].y) == CDOOR);
	cktrue("the art file supplied the sheets", tower != nil && folk != nil);
	ck("the tower sheet holds what the file holds", tower.n, 7);
	ck("and the folk sheet", folk.n, 16);

	# --- the mount point exists at all ---
	cktrue("mntgen gave us a mount point", readable("/n") != 0);

	# --- climbing ---
	newgame();
	run(10, 0);
	cktrue("it starts on the floor", onground != 0);
	y0 := int py;
	run(20, 0);
	ck("and stays there", int py, y0);
	run(30, KRIGHT);
	cktrue("it walks", int px != 24);
	run(60, 0);
	ck("and friction stops it", int (vx * 100.0), 0);

	# A held jump goes higher than a tapped one.
	newgame();
	run(6, 0);
	yb := int py;
	hi := yb;
	for(i = 0; i < 50; i++){
		run(1, KA);
		if(int py < hi)
			hi = int py;
	}
	held := yb - hi;
	newgame();
	run(6, 0);
	hi = yb;
	run(1, KA);
	for(i = 0; i < 50; i++){
		run(1, 0);
		if(int py < hi)
			hi = int py;
	}
	tapped := yb - hi;
	cktrue("a jump leaves the ground", tapped > 8);
	cktrue("holding jumps higher than tapping", held > tapped + 6);

	# --- the wrap ---
	newgame();
	px = 4.0;
	run(1, 0);
	run(40, KLEFT);
	cktrue("walking off the left comes back on the right", int px > W/2);
	cktrue("and it is still on the floor", onground != 0);
	px = real (W - 4);
	run(40, KRIGHT);
	cktrue("and the other way round", int px < W/2);

	# --- the camera climbs and does not come back ---
	newgame();
	c0 := cam;
	py = real ((LH-30)*8);
	run(1, 0);
	cktrue("the camera follows upward", cam < c0);
	c1 := cam;
	py = real ((LH-4)*8);
	run(1, 0);
	cktrue("and does not come back down", cam == c1);

	# --- falling behind the camera costs a try ---
	newgame();
	lv := lives;
	cam = 0;
	py = real (H + 40);
	hurt = 0;
	run(1, 0);
	ck("falling out of the view costs a try", lives, lv-1);

	# --- a room is a mount, and nothing but ---
	# Three states, because two can pass by accident: not there before,
	# there WITH THE ROOM'S OWN CONTENT during, not there after.
	newgame();
	cktrue("no room is mounted to begin with", readable(MNT + "/name") == 0);
	d := doors[0];
	standin(d);
	cktrue("standing in the doorway", doorhere() != nil);
	run(1, KUP);
	ck("pressing up goes in", mode, MROOM);
	cktrue("and the room's files are there now", readable(MNT + "/name") != 0);
	cktrue("the room named itself", rname != nil && rname != "");
	cktrue("and it is the server's name, not ours", len rwares > 0);
	nw := len rwares;
	seen := "";
	for(i = 0; i < len rwares; i++)
		seen += rwares[i].key + " ";
	sys->print("\troom is \"%s\", wares: %s\n", rname, seen);

	# Buying: the room refuses what cannot be afforded, in its words.
	coins = 0;
	writectl("coins 0");
	take();
	cktrue("a room refuses what cannot be paid for", rbad != 0);
	ck("and nothing was taken", len rwares, nw);
	coins = 200;
	writectl("coins 200");
	c2 := coins;
	take();
	cktrue("and sells what can be", rbad == 0);
	cktrue("the price came off", coins < c2);
	ck("and the ware is gone from the room", len rwares, nw-1);
	cktrue("and it did something", hijump || shield || lives > 3);

	# Leaving takes the room with it.
	roomkey(16r1b);
	ck("escape leaves", mode, MCLIMBING);
	cktrue("and the room is gone from the namespace",
		readable(MNT + "/name") == 0);

	# The other door is a different room, and the game did not change.
	d = doors[1];
	standin(d);
	run(1, KUP);
	ck("the other door opens too", mode, MROOM);
	other := rname;
	cktrue("and it is a different room", other != nil && other != "");
	sys->print("\tthe other room is \"%s\"\n", other);
	roomkey(16r1b);
	cktrue("left again", readable(MNT + "/name") == 0);

	# The control: point a door at something that is not there, and the
	# door must not open and must not quietly show anything.
	bad := ref Door(d.x, d.y, "/dis/games/nosuchroom.dis");
	standin(bad);
	e := enterroom(bad);
	cktrue("a door onto nothing is refused", e != nil);
	ck("and does not go in", mode, MCLIMBING);
	cktrue("and mounts nothing", readable(MNT + "/name") == 0);

	# --- coins ---
	newgame();
	(cx, cy) := findcell(CCOIN);
	cktrue("there are coins on the tower", cx >= 0);
	if(cx >= 0){
		c0 = coins;
		px = real (cx*8);
		py = real (cy*8);
		vy = 0.0;
		run(1, 0);
		ck("a coin is taken", coins, c0+1);
		ck("and the cell is empty", cellat(cx, cy), ' ');
		run(3, 0);
		ck("and not taken twice", coins, c0+1);
	}

	# --- the top ---
	newgame();
	(tx, ty) := findcell(CTOP);
	cktrue("the tower has a top", tx >= 0);
	if(tx >= 0){
		px = real (tx*8);
		py = real (ty*8);
		run(1, 0);
		ck("reaching it wins", mode, MWON);
	}

	# --- drawing, including the seam ---
	newgame();
	run(4, 0);
	box := Rect((0, HUDH), (W, H));
	nofolk = 0;
	draw1();
	with := boxsum(box);
	nofolk = 1;
	draw1();
	without := boxsum(box);
	nofolk = 0;
	cktrue("the frame could be read back", with >= 0 && without >= 0);
	cktrue("the climber is drawn", with != without);

	# Straddling the seam: the climber is in two places, so the strip at
	# the far edge must change too.  Parked in the middle it must not -
	# that is the control, and without it this would pass on the single
	# draw that is there either way.
	newgame();
	run(4, 0);
	px = real (W - 6);
	strip := Rect((0, int py - cam), (12, int py - cam + PH));
	nofolk = 1;
	draw1();
	e0 := boxsum(strip);
	nofolk = 0;
	draw1();
	e1 := boxsum(strip);
	cktrue("a climber over the seam is drawn on both sides", e0 != e1);
	px = real (W/2);
	strip = Rect((0, int py - cam), (12, int py - cam + PH));
	nofolk = 1;
	draw1();
	m0 := boxsum(strip);
	nofolk = 0;
	draw1();
	m1 := boxsum(strip);
	ck("and one in the middle is not", m0, m1);

	if(nfail == 0)
		sys->print("spire: PASSED\n");
	else{
		sys->print("spire: FAILED (%d)\n", nfail);
		raise "fail:test";
	}
}

findcell(c: int): (int, int)
{
	for(ty := 0; ty < LH; ty++)
		for(tx := 0; tx < LW; tx++)
			if(grid[ty][tx] == c)
				return (tx, ty);
	return (-1, -1);
}
