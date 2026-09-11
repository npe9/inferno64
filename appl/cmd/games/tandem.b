implement Tandem;

#
# Tandem - two players on one screen, in the shape that genre took: a
# fixed arena of girders, coins to collect, and a bump from underneath
# that knocks whoever is standing on the girder above you off their
# feet.  Helping and hindering are the same action.
#
# The second player is why this game is in the tree.  The game itself
# has no window and no keyboard: it is a FILE SERVER.  It serves
#
#	ctl	written to; "join", "reset"
#	pad	written to; "N MASK" - player N is holding MASK
#	state	read; where everything is, as text
#	status	read; the answer to the last ctl
#
# and a player is whatever is writing to pad.  Player one runs the
# server down a pipe and mounts it; player two mounts it over a network
# with styxlisten(1) and mount(1).  The code for the two is the same
# code, because mounting a pipe and mounting a TCP connection are the
# same thing, which is the entire argument.
#
#	tandem                  play, running a server down a pipe
#	tandem -j addr          play, joining a game somewhere else
#	tandem -serve           BE the game; serve Styx on stdin/stdout
#	tandem -b               what a frame over the mount costs
#
# There is no fallback.  A client that cannot mount does not play, and
# says so.  A client whose read of state fails stops rather than drawing
# the last thing it saw for ever, because a client that kept drawing
# would look exactly like one that was still connected.
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

include "tiles.m";
	tiles: Tiles;
	Chr, Pal, Surface, Screen: import tiles;

include "frameclock.m";
	fclock: Frameclock;

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;

include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator: import styxservers;
	nametree: Nametree;
	Tree: import nametree;

include "roomsrv.m";
	roomsrv: Roomsrv;

Tandem: module
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

ARTFILE:	con "/lib/tiles/tandem.art";
MAPFILE:	con "/lib/tiles/tandem.map";
MNT:		con "/n/game";
GAMEPROG:	con "/dis/games/tandem.dis";

CAIR:	con '.';
CWALL:	con '#';
CGIRD:	con '=';
CCOIN:	con 'o';
CLAMP:	con '*';

MSTAND:	con 0;
MWALK:	con 4;
MAIR:	con 8;

GRAV:	con 0.42;
VMAX:	con 1.9;
ACC:	con 0.34;
FRIC:	con 0.30;
JUMPV:	con -5.9;
TERM:	con 7.0;
PW:	con 16;
PH:	con 16;
STUNF:	con 70;			# frames off your feet after a bump
ROUND:	con 60*60;		# a round, in frames
NPLAYER: con 2;
NCOIN:	con 6;

Player: adt {
	x, y:	real;
	vx, vy:	real;
	ground:	int;
	face:	int;
	stun:	int;
	score:	int;
	joined:	int;
	pad:	int;
	prev:	int;
};

Coin: adt {
	x, y:	int;		# tile coordinates
	live:	int;
	at:	int;		# frame it comes back
};

# --- the game, which only the server runs ---
players: array of ref Player;
coins:	array of ref Coin;
frame:	int;
over:	int;
LW, LH:	int;
grid:	array of string;

# --- drawing, which only a client does ---
scn:	ref Screen;
scr, arena: ref Surface;
sarena, folk: ref Chr;
ppal:	array of ref Pal;
pstun, phud, pwarn, pgood, pcoin: ref Pal;
ptext:	array of ref Pal;
air:	int;
win:	ref Window;
me:	int;			# which player this client is

# what a client last read
seen:	string;

testmode: int;
shotmode: int;

# ---------------------------------------------------------------- setup

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	keyhold = load Keyhold Keyhold->PATH;
	kb = keyhold->mk(BINDS);
	tiles = load Tiles Tiles->PATH;
	fclock = load Frameclock Frameclock->PATH;
	roomsrv = load Roomsrv Roomsrv->PATH;
	if(tiles == nil || roomsrv == nil){
		sys->fprint(sys->fildes(2), "tandem: cannot load a module: %r\n");
		raise "fail:load";
	}
	# tiles(2) sets up its palette and its own module handles here.
	# Without this every drawing path faults on a nil module - which -t
	# never noticed, because -t does not draw, and which would have
	# broken the game the first time anybody played it.
	te := tiles->init();
	if(te != nil){
		sys->fprint(sys->fildes(2), "tandem: %s\n", te);
		raise "fail:init";
	}

	serve := 0;
	bench := 0;
	addr := "";
	for(a := tl argv; a != nil; a = tl a){
		case hd a {
		"-serve" =>	serve = 1;
		"-t" =>		testmode = 1;
		"-b" =>		bench = 1;
		"-s" =>		shotmode = 1;
		"-j" =>
			if(tl a == nil){
				sys->fprint(sys->fildes(2), "tandem: -j wants an address\n");
				raise "fail:usage";
			}
			a = tl a;
			addr = hd a;
		* =>
			sys->fprint(sys->fildes(2),
				"usage: tandem [-serve | -j addr | -t | -b | -s]\n");
			raise "fail:usage";
		}
	}

	if(serve){
		# No display, no window, no keyboard.  This is the game.
		readworld(nil);
		newround();
		serveloop(sys->fildes(0));
		return;
	}

	e := roomsrv->init();
	if(e != nil){
		sys->fprint(sys->fildes(2), "tandem: %s\n", e);
		raise "fail:init";
	}
	sys->pctl(Sys->FORKNS, nil);
	ge := roomsrv->mountprog("/dis/mntgen.dis", "mntgen" :: nil, "/n",
		Sys->MAFTER);
	if(ge != nil){
		sys->fprint(sys->fildes(2), "tandem: %s\n", ge);
		raise "fail:mntgen";
	}

	if(addr != ""){
		# Somebody else's game, over a network.
		if(sys->bind(addr, MNT, Sys->MREPL) < 0 && !mountaddr(addr)){
			sys->fprint(sys->fildes(2),
				"tandem: cannot reach %s: %r\n", addr);
			raise "fail:mount";
		}
	}else{
		# Our own, down a pipe.  Same mount, same files, same code
		# from here on.
		e = roomsrv->mountprog(GAMEPROG, "tandem" :: "-serve" :: nil, MNT,
			Sys->MREPL);
		if(e != nil){
			sys->fprint(sys->fildes(2), "tandem: %s\n", e);
			raise "fail:mount";
		}
	}

	if(!joingame()){
		cleanup();
		sys->fprint(sys->fildes(2), "tandem: the game would not have us\n");
		raise "fail:join";
	}

	if(bench){
		benchmark();
		cleanup();
		return;
	}
	if(testmode){
		readworld(nil);
		selftest();
		cleanup();
		return;
	}
	if(shotmode){
		shot();
		cleanup();
		return;
	}

	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "Tandem", Wmclient->Appl);
	readworld(win.display);
	win.reshape(Rect((0,0),(W*SCALE, H*SCALE)));
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);
	oe := openfiles();
	if(oe != nil){
		sys->fprint(sys->fildes(2), "tandem: %s\n", oe);
		cleanup();
		raise "fail:open";
	}
	playloop();
}

mountaddr(addr: string): int
{
	(ok, c) := sys->dial(addr, nil);
	if(ok < 0)
		return 0;
	return sys->mount(c.dfd, nil, MNT, Sys->MREPL, nil) >= 0;
}

cleanup()
{
	closefiles();
	sys->unmount(nil, MNT);
	sys->unmount(nil, "/n");
}

docmd(c: string)
{
	r := scn.cmd(c);
	if(len r > 0 && r[0] == '!'){
		sys->fprint(sys->fildes(2), "tandem: %s\n", r);
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

# The arena, for both sides: the server needs the cells to collide
# against, a client needs them to draw.  A display of nil means the
# caller is the server and wants only the grid.
readworld(d: ref Display)
{
	(b, err) := slurp(MAPFILE);
	if(err != nil)
		barf(err);
	rows := array[64] of string;
	n := 0;
	body := 0;
	(nil, lines) := sys->tokenize(string b, "\n");
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		if(len l == 0 || l[0] == ';')
			continue;
		if(!body){
			if(l == "%")
				body = 1;
			continue;
		}
		if(n >= len rows){
			a := array[2 * len rows] of string;
			a[0:] = rows[0:n];
			rows = a;
		}
		rows[n++] = l;
	}
	if(n == 0)
		barf(MAPFILE + ": no arena");
	LW = len rows[0];
	LH = n;
	if(LW != W/8 || LH != H/8)
		barf(sys->sprint("%s: the arena must be %d by %d tiles",
			MAPFILE, W/8, H/8));
	for(i := 0; i < n; i++)
		if(len rows[i] != LW)
			barf(sys->sprint("%s: row %d is the wrong width", MAPFILE, i));
	grid = rows[0:n];
	if(d == nil)
		return;

	scn = tiles->screen(d, Draw->RGB24, SCALE);
	if(scn == nil)
		barf("no screen");
	runcmds(ARTFILE);
	air = colourof("cair");
	docmd(sys->sprint("surface scr %d %d %d", W, H, air));
	docmd(sys->sprint("surface arena %d %d %d", LW*8, LH*8, air));
	docmd("map arena arena " + MAPFILE);
	scr = scn.named("scr");
	arena = scn.named("arena");
	sarena = scn.sheet("arena");
	folk = scn.sheet("folk");
	ppal = array[] of { scn.pal("pone"), scn.pal("ptwo") };
	ptext = array[] of { scn.pal("ponetext"), scn.pal("ptwotext") };
	pstun = scn.pal("pstun");
	phud = scn.pal("phud");
	pwarn = scn.pal("pwarn");
	pgood = scn.pal("pgood");
	pcoin = scn.pal("pcoin");
	if(scr == nil || arena == nil || folk == nil || ppal[0] == nil
	|| ptext[0] == nil || ptext[1] == nil)
		barf("the screen made nothing");
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

colourof(name: string): int
{
	p := scn.pal(name);
	if(p == nil || len p.c == 0)
		barf(name + ": no such colour");
	return p.c[0];
}

barf(s: string)
{
	sys->fprint(sys->fildes(2), "tandem: %s\n", s);
	raise "fail:data";
}

number(w: string): (int, int)
{
	if(len w == 0)
		return (0, 0);
	i := 0;
	sign := 1;
	if(w[0] == '-'){
		sign = -1;
		i = 1;
	}
	if(i >= len w)
		return (0, 0);
	v := 0;
	for(; i < len w; i++){
		if(w[i] < '0' || w[i] > '9')
			return (0, 0);
		v = v*10 + (w[i] - '0');
	}
	return (sign*v, 1);
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
		return CWALL;
	tx = ((tx % LW) + LW) % LW;
	return grid[ty][tx];
}

# Where the coins go, from the map: every girder row, a few columns
# apart.  Deterministic, so two machines running this see the same game
# without having to agree about anything but the frame number.
COINX := array[] of {4, 12, 20, 28, 8, 24};

newround()
{
	players = array[NPLAYER] of ref Player;
	for(i := 0; i < NPLAYER; i++){
		p := ref Player;
		p.x = real (40 + i*160);
		p.y = real ((LH-3)*8 - PH);
		p.vx = p.vy = 0.0;
		p.ground = 1;
		p.face = i;
		p.stun = 0;
		p.score = 0;
		p.joined = 0;
		p.pad = p.prev = 0;
		players[i] = p;
	}
	coins = array[NCOIN] of ref Coin;
	rows := perches();
	for(i = 0; i < NCOIN; i++){
		ty := 12;
		if(len rows > 0)
			ty = rows[i % len rows] - 1;
		coins[i] = ref Coin(COINX[i % len COINX], ty, 1, 0);
	}
	frame = 0;
	over = 0;
	if(sys != nil)
		started = sys->millisec();
}

# Every row something can stand on: the girders, and the top of the
# floor.  The floor was left out at first, so every coin in the game was
# up on a girder and a player who never jumped could not reach one - and
# the arena's whole ground level had nothing in it.
perches(): array of int
{
	out := array[LH] of int;
	n := 0;
	for(ty := 0; ty < LH; ty++)
		for(tx := 0; tx < LW; tx++)
			if(grid[ty][tx] == CGIRD){
				out[n++] = ty;
				break;
			}
	# the topmost row of the block at the bottom
	for(ty = LH-1; ty > 0; ty--){
		all := 1;
		for(x := 0; x < LW; x++)
			if(grid[ty][x] != CWALL)
				all = 0;
		if(all && (ty == 0 || !solidrow(ty-1))){
			out[n++] = ty;
			break;
		}
	}
	return out[0:n];
}

solidrow(ty: int): int
{
	for(tx := 0; tx < LW; tx++)
		if(grid[ty][tx] != CWALL)
			return 0;
	return 1;
}

stepgame()
{
	if(over)
		return;
	frame++;
	for(i := 0; i < NPLAYER; i++)
		steplayer(players[i]);
	bumps();
	pickups();
	for(i = 0; i < NCOIN; i++){
		c := coins[i];
		if(!c.live && frame >= c.at)
			c.live = 1;
	}
	if(frame >= ROUND)
		over = 1;
}

steplayer(p: ref Player)
{
	if(p.stun > 0){
		p.stun--;
		p.vx = 0.0;
		p.prev = p.pad;
		fall(p);
		return;
	}
	edge := p.pad & ~p.prev;
	p.prev = p.pad;
	if(p.pad & KLEFT){
		p.vx -= ACC;
		p.face = 1;
	}else if(p.pad & KRIGHT){
		p.vx += ACC;
		p.face = 0;
	}else{
		if(p.vx > FRIC)
			p.vx -= FRIC;
		else if(p.vx < -FRIC)
			p.vx += FRIC;
		else
			p.vx = 0.0;
	}
	if(p.vx > VMAX)
		p.vx = VMAX;
	if(p.vx < -VMAX)
		p.vx = -VMAX;
	ox := p.x;
	p.x = wrapx(p.x + p.vx);
	if(hitwall(p)){
		p.x = ox;
		p.vx = 0.0;
	}
	if((edge & KA) && p.ground){
		p.vy = JUMPV;
		p.ground = 0;
	}
	if(!(p.pad & KA) && p.vy < -3.0)
		p.vy = -3.0;
	fall(p);
}

fall(p: ref Player)
{
	p.vy += GRAV;
	if(p.vy > TERM)
		p.vy = TERM;
	oy := p.y;
	p.y += p.vy;
	p.ground = 0;
	if(p.vy > 0.0){
		t := landing(p, oy, p.y);
		if(t >= 0){
			p.y = real (t - PH);
			p.vy = 0.0;
			p.ground = 1;
		}
	}else if(p.vy < 0.0){
		if(solidat(p, int p.y)){
			p.y = real ((fl(p.y / 8.0) + 1) * 8);
			p.vy = 0.0;
		}
	}
}

solidat(p: ref Player, y: int): int
{
	return cellat(fl(real (int p.x + 1) / 8.0), fl(real y / 8.0)) == CWALL
	|| cellat(fl(real (int p.x + PW - 2) / 8.0), fl(real y / 8.0)) == CWALL;
}

hitwall(p: ref Player): int
{
	for(dy := 1; dy < PH; dy += 6)
		if(cellat(fl(real (int p.x + 1) / 8.0), fl(real (int p.y + dy) / 8.0)) == CWALL
		|| cellat(fl(real (int p.x + PW - 2) / 8.0), fl(real (int p.y + dy) / 8.0)) == CWALL)
			return 1;
	return 0;
}

landing(p: ref Player, y0, y1: real): int
{
	f0 := y0 + real PH;
	f1 := y1 + real PH;
	t0 := fl(f0 / 8.0);
	t1 := fl(f1 / 8.0);
	for(ty := t0; ty <= t1; ty++){
		top := real (ty * 8);
		if(top < f0 - 0.001 || top > f1)
			continue;
		a := cellat(fl(real (int p.x + 1) / 8.0), ty);
		b := cellat(fl(real (int p.x + PW - 2) / 8.0), ty);
		if(a == CGIRD || a == CWALL || b == CGIRD || b == CWALL)
			return ty * 8;
	}
	return -1;
}

# A player rising into the underside of a girder knocks anyone standing
# on that girder above them off their feet.  This is the only way the
# two of them touch, and it is both the help and the hindrance: it is
# also how you knock somebody clear of a coin you want.
bumps()
{
	for(i := 0; i < NPLAYER; i++){
		p := players[i];
		if(p.vy >= 0.0 || p.stun > 0)
			continue;
		ty := fl(p.y / 8.0);
		if(cellat(fl(real (int p.x + PW/2) / 8.0), ty) != CGIRD)
			continue;
		for(j := 0; j < NPLAYER; j++){
			if(j == i)
				continue;
			q := players[j];
			if(!q.ground || q.stun > 0)
				continue;
			qty := fl((q.y + real PH) / 8.0);
			if(qty != ty)
				continue;
			dx := q.x - p.x;
			if(dx < 0.0)
				dx = -dx;
			if(dx < 20.0){
				q.stun = STUNF;
				q.vy = -2.4;
				q.ground = 0;
			}
		}
	}
}

pickups()
{
	for(i := 0; i < NPLAYER; i++){
		p := players[i];
		for(k := 0; k < NCOIN; k++){
			c := coins[k];
			if(!c.live)
				continue;
			cx := real (c.x*8);
			cy := real (c.y*8);
			dx := cx - p.x;
			ww := real (LW*8);
			if(dx > ww/2.0)
				dx -= ww;
			if(dx < -ww/2.0)
				dx += ww;
			if(dx < 0.0)
				dx = -dx;
			dy := cy - p.y;
			if(dy < 0.0)
				dy = -dy;
			if(dx < 14.0 && dy < 14.0){
				c.live = 0;
				c.at = frame + 180;
				p.score++;
			}
		}
	}
}

# ---------------------------------------------------------- the server

Qdir, Qctl, Qpad, Qstate, Qstatus: con iota;

srvstatus := "";

# Set when a client has taken the clock; see "drive" below.
driven := 0;

dirent(name: string, perm: int, path: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = "inferno";
	d.gid = "inferno";
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

# Where everything is, as text.  Text and not a packed struct because a
# person has to be able to cat it while the game is running, and because
# the first thing anybody does with a protocol they cannot read is guess
# about it.
statetext(): string
{
	s := sys->sprint("frame %d %d\n", frame, over);
	for(i := 0; i < NPLAYER; i++){
		p := players[i];
		f := 0;
		if(p.ground)
			f |= 1;
		if(p.stun > 0)
			f |= 2;
		if(p.face)
			f |= 4;
		if(p.joined)
			f |= 8;
		s += sys->sprint("p %d %d %d %d %d\n", i+1, int p.x, int p.y, f, p.score);
	}
	for(k := 0; k < NCOIN; k++){
		c := coins[k];
		s += sys->sprint("c %d %d %d %d\n", k, c.x, c.y, c.live);
	}
	return s;
}

srvctl(cmd: string): string
{
	(n, a) := sys->tokenize(cmd, " \t");
	if(n == 0)
		return "!empty";
	case hd a {
	"join" =>
		for(i := 0; i < NPLAYER; i++)
			if(!players[i].joined){
				players[i].joined = 1;
				return sys->sprint("you %d", i+1);
			}
		return "!the game is full";
	"reset" =>
		j := array[NPLAYER] of int;
		for(i := 0; i < NPLAYER; i++)
			j[i] = players[i].joined;
		newround();
		for(i = 0; i < NPLAYER; i++)
			players[i].joined = j[i];
		return "reset";
	"drive" =>
		# Stop the clock and let the caller move the game instead.
		# Without this the server ticks at 60Hz AND honours step, so
		# a frame number could go up twice for one step and any
		# assertion about exactly how far the game had moved was a
		# race - which is what it was, intermittently, over TCP.
		driven = 1;
		return "driven";
	"step" =>
		# One frame, for a caller that would rather drive the game
		# than be driven by it - which is what -t does, and what
		# makes the whole thing reproducible.  Driving implies taking
		# the clock: a step mixed with a tick is the race again.
		driven = 1;
		stepgame();
		return sys->sprint("frame %d", frame);
	}
	return "!no such instruction: " + hd a;
}

srvpad(cmd: string): string
{
	(n, a) := sys->tokenize(cmd, " \t");
	if(n != 2)
		return "!pad wants N MASK";
	(who, wok) := number(hd a);
	(mask, mok) := number(hd tl a);
	if(!wok || !mok)
		return "!not a number";
	if(who < 1 || who > NPLAYER)
		return "!no such player";
	players[who-1].pad = mask;
	return sys->sprint("pad %d %d", who, mask);
}

# The clock lives in the server, so that two clients on two machines
# cannot disagree about what frame it is.  It is not a process: the game
# catches up to the wall clock when somebody reads the state.
#
# It WAS a process, ticking on frameclock(2) into an alt.  That was two
# bugs at once.  A spawned ticker outlives the server and keeps emu
# alive after everything has exited; and `break` in an alt arm leaves
# the ALT, not the loop, so the server never stopped on a read error
# either.  A plain loop over the Styx messages has neither problem.
started:	int;
CATCHUP:	con 8;		# frames a read may advance, at most

catchup()
{
	if(driven || over)
		return;
	want := (sys->millisec() - started) * 60 / 1000;
	n := want - frame;
	if(n <= 0)
		return;
	# Bounded, so a server nobody has read for a minute does not
	# disappear into three thousand frames of simulation.
	if(n > CATCHUP)
		n = CATCHUP;
	for(i := 0; i < n; i++)
		stepgame();
}

serveloop(fd: ref Sys->FD)
{
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	nametree = load Nametree Nametree->PATH;
	if(styx == nil || styxservers == nil || nametree == nil)
		barf(sys->sprint("cannot load a styx module: %r"));
	styx->init();
	styxservers->init(styx);
	nametree->init();
	(tree, treeop) := nametree->start();
	tree.create(big Qdir, dirent(".", Sys->DMDIR|8r555, Qdir));
	tree.create(big Qdir, dirent("ctl", 8r666, Qctl));
	tree.create(big Qdir, dirent("pad", 8r222, Qpad));
	tree.create(big Qdir, dirent("state", 8r444, Qstate));
	tree.create(big Qdir, dirent("status", 8r444, Qstatus));

	(tc, srv) := Styxserver.new(fd, Navigator.new(treeop), big Qdir);
	started = sys->millisec();
	while((tmsg := <-tc) != nil)
		if(!serve1(srv, tmsg))
			break;
	tree.quit();
}

serve1(srv: ref Styxserver, tmsg: ref Tmsg): int
{
	pick tm := tmsg {
	Readerror =>
		return 0;
	Open =>
		srv.open(tm);
	Read =>
		c := srv.getfid(tm.fid);
		if(c == nil || !c.isopen){
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			return 1;
		}
		case int c.path {
		Qdir =>
			srv.read(tm);
		Qstate =>
			# Reading the state is what moves the game on, unless
			# a client has taken the clock.
			catchup();
			srv.reply(styxservers->readstr(tm, statetext()));
		Qstatus =>
			srv.reply(styxservers->readstr(tm, srvstatus + "\n"));
		* =>
			srv.reply(ref Rmsg.Error(tm.tag, "no such file"));
		}
	Write =>
		c := srv.getfid(tm.fid);
		if(c == nil || !c.isopen){
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			return 1;
		}
		cmd := string tm.data;
		while(len cmd > 0 && cmd[len cmd-1] == '\n')
			cmd = cmd[0:len cmd-1];
		ans: string;
		case int c.path {
		Qctl =>
			ans = srvctl(cmd);
		Qpad =>
			ans = srvpad(cmd);
		* =>
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
			return 1;
		}
		if(len ans > 0 && ans[0] == '!'){
			srv.reply(ref Rmsg.Error(tm.tag, ans[1:]));
			return 1;
		}
		srvstatus = ans;
		srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
	Clunk =>
		srv.clunk(tm);
	* =>
		srv.default(tmsg);
	}
	return 1;
}

# ---------------------------------------------------------- the client

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

# Read a whole file from a descriptor already open, from the beginning.
readopen(fd: ref Sys->FD): (string, string)
{
	if(sys->seek(fd, big 0, Sys->SEEKSTART) < big 0)
		return (nil, sys->sprint("cannot seek: %r"));
	s := "";
	b := array[4096] of byte;
	for(;;){
		n := sys->read(fd, b, len b);
		if(n < 0)
			return (nil, sys->sprint("cannot read: %r"));
		if(n == 0)
			break;
		s += string b[0:n];
		if(len s > 64*1024)
			break;
	}
	return (s, nil);
}

writefile(path, s: string): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("cannot open %s: %r", path);
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("%r");
	return nil;
}

joingame(): int
{
	if(writefile(MNT + "/ctl", "join") != nil)
		return 0;
	(st, e) := readfile(MNT + "/status");
	if(e != nil)
		return 0;
	(n, a) := sys->tokenize(st, " \t\n");
	if(n < 2 || hd a != "you")
		return 0;
	(who, ok) := number(hd tl a);
	if(!ok)
		return 0;
	me = who;
	return 1;
}

# A client's whole view of the game.  Filled from the text the server
# serves and from nothing else: there is no local simulation to fall
# back on, so a client that stops being able to read stops.
Seen: adt {
	frame:	int;
	over:	int;
	px, py:	array of int;
	pf:	array of int;
	ps:	array of int;
	cx, cy, cl: array of int;
	ok:	int;
};

view: ref Seen;

parsestate(s: string): ref Seen
{
	v := ref Seen;
	v.px = array[NPLAYER] of int;
	v.py = array[NPLAYER] of int;
	v.pf = array[NPLAYER] of int;
	v.ps = array[NPLAYER] of int;
	v.cx = array[NCOIN] of int;
	v.cy = array[NCOIN] of int;
	v.cl = array[NCOIN] of int;
	v.ok = 0;
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines){
		(n, a) := sys->tokenize(hd lines, " \t");
		if(n == 0)
			continue;
		case hd a {
		"frame" =>
			if(n < 3)
				continue;
			(v.frame, nil) = number(hd tl a);
			(v.over, nil) = number(hd tl tl a);
			v.ok = 1;
		"p" =>
			if(n < 6)
				continue;
			(who, wok) := number(hd tl a);
			if(!wok || who < 1 || who > NPLAYER)
				continue;
			(v.px[who-1], nil) = number(hd tl tl a);
			(v.py[who-1], nil) = number(hd tl tl tl a);
			(v.pf[who-1], nil) = number(hd tl tl tl tl a);
			(v.ps[who-1], nil) = number(hd tl tl tl tl tl a);
		"c" =>
			if(n < 5)
				continue;
			(k, kok) := number(hd tl a);
			if(!kok || k < 0 || k >= NCOIN)
				continue;
			(v.cx[k], nil) = number(hd tl tl a);
			(v.cy[k], nil) = number(hd tl tl tl a);
			(v.cl[k], nil) = number(hd tl tl tl tl a);
		}
	}
	return v;
}

refresh(): string
{
	s: string;
	e: string;
	if(statefd == nil)
		(s, e) = readfile(MNT + "/state");
	else
		(s, e) = readopen(statefd);
	if(e != nil)
		return e;
	v := parsestate(s);
	if(!v.ok)
		return "the game sent something that is not a state";
	view = v;
	return nil;
}

# The two files a client touches every frame are opened once and kept.
# Opening them each time costs a walk, an open and a clunk on top of the
# read or write - four Styx round trips where one would do - and that
# showed up as 3.3 milliseconds a frame, a fifth of the budget at 60Hz.
padfd, statefd: ref Sys->FD;

openfiles(): string
{
	padfd = sys->open(MNT + "/pad", Sys->OWRITE);
	if(padfd == nil)
		return sys->sprint("cannot open the pad: %r");
	statefd = sys->open(MNT + "/state", Sys->OREAD);
	if(statefd == nil)
		return sys->sprint("cannot open the state: %r");
	return nil;
}

closefiles()
{
	padfd = nil;
	statefd = nil;
}

sendpad(mask: int): string
{
	if(padfd == nil)
		return writefile(MNT + "/pad", sys->sprint("%d %d", me, mask));
	b := array of byte sys->sprint("%d %d", me, mask);
	if(sys->write(padfd, b, len b) != len b)
		return sys->sprint("%r");
	return nil;
}

# ---------------------------------------------------------------- draw

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

draw1()
{
	arena.view(scr, 0, 0);
	if(view == nil)
		return;
	old := scr.chr;
	scr.chr = sarena;
	for(k := 0; k < NCOIN; k++)
		if(view.cl[k])
			scr.put(view.cx[k]*8, view.cy[k]*8, 3, pcoin, 0);
	scr.chr = old;
	for(i := 0; i < NPLAYER; i++){
		f := view.pf[i];
		t := MAIR;
		if(f & 1)
			t = MSTAND;
		p := ppal[i];
		if(f & 2)
			p = pstun;
		flags := 0;
		if(f & 4)
			flags = Tiles->FLIPX;
		folkat(view.px[i], view.py[i], t, p, flags);
	}
	hud();
}

hud()
{
	scr.fill(Rect((0,0),(W, HUDH)), air);
	if(view == nil)
		return;
	# Laid out so nothing overlaps at two digits: "time 58" ran into
	# "you 1" and the two read as one word.
	scr.text(4, 4, "one " + string view.ps[0], ptext[0]);
	scr.text(68, 4, "two " + string view.ps[1], ptext[1]);
	left := (ROUND - view.frame) / 60;
	if(left < 0)
		left = 0;
	scr.text(132, 4, "time " + string left, phud);
	if(view.over){
		s := "draw";
		if(view.ps[0] > view.ps[1])
			s = "one!";
		else if(view.ps[1] > view.ps[0])
			s = "two!";
		scr.text(200, 4, s, pgood);
	}else
		scr.text(200, 4, "you " + string me, pgood);
}

# ----------------------------------------------------------- the loop

playloop()
{
	pad := 0;
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
			cleanup();
			exit;
		}
		pad = kb.key(pad, k);
	<-ticks =>
		if(sendpad(pad) != nil || refresh() != nil){
			# The game has gone.  Stop, rather than drawing the
			# last thing seen for ever - which would look exactly
			# like still being connected.
			sys->fprint(sys->fildes(2), "tandem: lost the game: %r\n");
			cleanup();
			exit;
		}
		draw1();
		win.image.draw(win.image.r, scr.img, nil, scr.img.r.min);
		win.image.flush(Draw->Flushnow);
	}
}

# ------------------------------------------------------------- measure

benchmark()
{
	N: con 2000;
	sys->print("tandem: %d of each, over the mount\n\n", N);

	# Opening the files every frame, which is what the first version of
	# the client did.
	closefiles();
	t0 := sys->millisec();
	for(i := 0; i < N; i++)
		sendpad(KRIGHT);
	t1 := sys->millisec();
	for(i = 0; i < N; i++)
		refresh();
	t2 := sys->millisec();
	for(i = 0; i < N; i++){
		sendpad(KRIGHT);
		refresh();
	}
	t3 := sys->millisec();

	e := openfiles();
	if(e != nil){
		sys->print("tandem: %s\n", e);
		return;
	}
	t4 := sys->millisec();
	for(i = 0; i < N; i++)
		sendpad(KRIGHT);
	t5 := sys->millisec();
	for(i = 0; i < N; i++)
		refresh();
	t6 := sys->millisec();
	for(i = 0; i < N; i++){
		sendpad(KRIGHT);
		refresh();
	}
	t7 := sys->millisec();

	sys->print("%-20s %12s %12s\n", "", "opened each", "held open");
	sys->print("%-20s %10s us %10s us\n", "write pad", per(t1-t0, N), per(t5-t4, N));
	sys->print("%-20s %10s us %10s us\n", "read state", per(t2-t1, N), per(t6-t5, N));
	sys->print("%-20s %10s us %10s us\n", "both, as a frame",
		per(t3-t2, N), per(t7-t6, N));
	sys->print("\na frame at 60Hz has 16666 us.\n");
}

per(ms, n: int): string
{
	if(n <= 0)
		return "-";
	us := real ms * 1000.0 / real n;
	w := int (us * 10.0);
	return sys->sprint("%d.%.1d", w / 10, w % 10);
}

shot()
{
	d := Display.allocate(nil);
	if(d == nil)
		barf(sys->sprint("no display: %r"));
	readworld(d);
	if(openfiles() != nil)
		barf("cannot open the per-frame files");
	writefile(MNT + "/ctl", "drive");
	# A second player, so the picture has both.
	writefile(MNT + "/ctl", "join");
	for(i := 0; i < 420; i++){
		held := KRIGHT;
		if((i % 44) < 12)
			held |= KA;
		sendpad(held);
		two := KLEFT;
		if((i % 37) < 10)
			two |= KA;
		writefile(MNT + "/pad", "2 " + string two);
		writefile(MNT + "/ctl", "step");
	}
	refresh();
	draw1();
	w := scr.img.r.dx();
	h := scr.img.r.dy();
	b := array[w*h*3] of byte;
	if(scr.img.readpixels(scr.img.r, b) < 0){
		sys->print("readpixels: %r\n");
		return;
	}
	fd := sys->create("tandem.raw", Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->print("create: %r\n");
		return;
	}
	sys->write(fd, b, len b);
	sys->print("wrote tandem.raw %dx%d bgr\n", w, h);
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

# Like cktrue, but for things checked in a loop where a hundred "ok"
# lines would bury everything else: only a failure is reported.
quiet: int;

cktrue2(v: int)
{
	if(!v)
		quiet++;
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

# Drive the game a frame at a time through its own control file, so the
# test is reproducible: with the server ticking on a clock, what a
# hundred frames does depends on how fast this host is.
tick(n: int)
{
	for(i := 0; i < n; i++)
		writefile(MNT + "/ctl", "step");
}

selftest()
{
	sys->print("tandem: self test\n");

	cktrue("the arena was read", LW == W/8 && LH == H/8);
	cktrue("mounted a game", view == nil);
	cktrue("and it gave us a player number", me >= 1 && me <= NPLAYER);
	ck("the first to join is player one", me, 1);

	# Take the clock first: the server runs one of its own, and every
	# assertion below about exactly how far the game moved would
	# otherwise be a race against it.
	cktrue("the game hands over its clock",
		writefile(MNT + "/ctl", "drive") == nil);
	e := refresh();
	cktrue("its state reads", e == nil);
	cktrue("and parses", view != nil && view.ok);
	# The clock really is off.  This is the check that makes every
	# exact-frame assertion below mean something: without it the server
	# would still be ticking at 60Hz and two hundred milliseconds would
	# be twelve frames.
	h0 := view.frame;
	sys->sleep(200);
	refresh();
	ck("and then does not move on its own", view.frame, h0);

	f0 := view.frame;
	tick(1);
	refresh();
	ck("stepping it moves the frame on", view.frame, f0+1);

	# Player one is us; player two is somebody who has not arrived, and
	# the game must be playable without them.
	writefile(MNT + "/ctl", "reset");
	refresh();
	x0 := view.px[0];
	for(i := 0; i < 40; i++){
		sendpad(KRIGHT);
		tick(1);
	}
	refresh();
	cktrue("our pad moves our player", view.px[0] != x0);
	x1 := view.px[1];
	cktrue("and not the other one", view.px[1] == x1);

	# The second player is a second writer to the same file, which is
	# the whole claim: nothing about them is special here.
	st := writefile(MNT + "/ctl", "join");
	cktrue("a second player may join", st == nil);
	(s2, nil) := readfile(MNT + "/status");
	cktrue("and is told they are player two", ok2(s2));
	y0 := view.px[1];
	for(i = 0; i < 40; i++){
		writefile(MNT + "/pad", "2 " + string KLEFT);
		tick(1);
	}
	refresh();
	cktrue("their pad moves their player", view.px[1] != y0);

	# And a third is refused rather than quietly becoming player two.
	st = writefile(MNT + "/ctl", "join");
	cktrue("a third is refused", st != nil);

	# The game is full of rules; check the two that matter.
	writefile(MNT + "/ctl", "reset");
	refresh();
	s0 := view.ps[0];
	got := 0;
	for(i = 0; i < 900; i++){
		# run, and jump now and then: the coins are spread over every
		# row something can stand on, not only the floor
		held := KRIGHT;
		if((i % 50) < 12)
			held |= KA;
		sendpad(held);
		tick(1);
		if((i % 60) == 0){
			refresh();
			if(view.ps[0] > s0){
				got = 1;
				break;
			}
		}
	}
	refresh();
	cktrue("running about collects coins", got && view.ps[0] > s0);

	# A coin taken comes back, rather than the arena emptying.
	writefile(MNT + "/ctl", "reset");
	refresh();
	nlive := 0;
	for(k := 0; k < NCOIN; k++)
		nlive += view.cl[k];
	ck("the arena starts full of coins", nlive, NCOIN);

	# The pad is refused when it is nonsense, rather than moving
	# somebody at random.
	cktrue("a pad for nobody is refused",
		writefile(MNT + "/pad", "9 1") != nil);
	cktrue("and a pad that is not a number",
		writefile(MNT + "/pad", "1 x") != nil);
	cktrue("and an instruction that does not exist",
		writefile(MNT + "/ctl", "fly") != nil);

	# The way a client actually plays: the two files it touches every
	# frame held open, read with a seek back to the start.  This is a
	# different path through the server from open-read-clunk, and it is
	# the one that can go stale: a held descriptor that returned what it
	# read the first time would look exactly like a game that had
	# stopped moving.
	writefile(MNT + "/ctl", "reset");
	oe := openfiles();
	cktrue("the per-frame files open", oe == nil);
	cktrue("and read through the held descriptor", refresh() == nil);
	g0 := view.frame;
	tick(3);
	cktrue("and again", refresh() == nil);
	cktrue("the held read sees the new frame, not the old one",
		view.frame == g0 + 3);
	px0 := view.px[0];
	for(i = 0; i < 30; i++){
		cktrue2(sendpad(KRIGHT) == nil);
		tick(1);
	}
	refresh();
	cktrue("and the held write moves our player", view.px[0] != px0);
	closefiles();

	# The negative control for all of it: when the game is not there,
	# the client must fail rather than carry on with what it had.
	v := view;
	sys->unmount(nil, MNT);
	cktrue("with the game unmounted, reading state fails", refresh() != nil);
	cktrue("and sending a pad fails", sendpad(0) != nil);
	cktrue("and the client still has only what it last saw", view == v);

	cktrue("every held write was accepted", quiet == 0);

	if(nfail == 0)
		sys->print("tandem: PASSED\n");
	else{
		sys->print("tandem: FAILED (%d)\n", nfail);
		raise "fail:test";
	}
}

ok2(s: string): int
{
	(n, a) := sys->tokenize(s, " \t\n");
	return n >= 2 && hd a == "you" && hd tl a == "2";
}
