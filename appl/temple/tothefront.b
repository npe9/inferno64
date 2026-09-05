implement Tothefront;

# TempleOS Apps/ToTheFront — hex-grid wargame (Terry A. Davis, public domain).
# Faithful port of ToTheFront.HC, TTFGlbls/Init/Lib/Move/Fire/Vis/Draw.HC and
# the stock AIs (AIs/Human.HC, AIs/SimpleAI.HC).
#
# GAP: the original loads user-written HolyC AI files from ~/ToTheFront via
#      PlayerPick; there is no HolyC compiler here, so the picker offers the
#      two stock controllers (Human, SimpleAI) per player only.
# GAP: the original shows the line-of-sight overlay while SHIFT is held; this
#      input stack delivers no bare-modifier state, so 's' toggles it instead.
# GAP: no pull-down menu bar; every menu entry is available on its key.
#
# Timing: the original animates by Sleep(ms) inside the game task while the
# window manager redraws at ~30fps (JIFFY_FREQ=1000).  This port does the
# same: a spawned engine process sleeps in real milliseconds and the main
# loop redraws every 33ms, so real-time rates are preserved.

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

include "rand.m";
	rand: Rand;

include "tone.m";
	tone: Tone;

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;

Tothefront: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

UNITSNUM: con 32;
HEXSIDE: con 11.0;
DCOS: con HEXSIDE*0.5;		# HEX_SIDE*Cos(60 deg)
FONTW: con 8;
FONTH: con 8;

# TempleOS 16-color palette indices
BLACK, BLUE, GREEN, CYAN, RED, PURPLE, BROWN, LTGRAY,
DKGRAY, LTBLUE, LTGREEN, LTCYAN, LTRED, LTPURPLE, YELLOW, WHITE: con iota;

PLAINS: con LTGREEN;
TREES: con GREEN;
MOUNTAINS: con DKGRAY;

UTINFANTRY, UTARTILLERY, UTLTTANK, UTMDTANK: con iota;

PHASESTART: con 0;
PHASEINDIRECT: con 0;
PHASEMOVE: con 2;
PHASEDIRECT: con 4;
PHASEEND: con 6;

# VisRecalc modes
VRONEFRIENDLY: con 0;
VRUPDATE: con 1;
VRDIED: con 3;
VRONEENEMY: con 4;
VRALL: con 5;

# engine signals (the original's throw('PhaseOvr') etc, as return codes)
Snone, SPhaseOvr, SNewGame, SExitGame, SGameOver: con iota;

# display modes
Mgame, Mpick, Mseed, Mdelay, Mlog, Mhelp: con iota;

# pointer message types
Mldown, Mlup, Mrup: con iota;

CTLHUMAN, CTLAI: con iota;

LOGMAX: con 400;

Unit: adt {
	typ, player, num: int;
	row, col: int;
	armored_attack, unarmored_attack, armor: int;
	facing, movement, life, rng, remaining_movement, accuracy: int;
	vis: array of int;		# [2] visible to player p
	fired, infantry, indirect_fire: int;
};

Iorder: adt {
	u: ref Unit;
	row, col: int;
};

display: ref Display;
win: ref Window;
ink: array of ref Image;
tfont: ref Font;
spr: array of ref Image;
sprmask: array of ref Image;
marker: ref Image;
markermask: ref Image;
tints: array of ref Image;
have_tone := 0;

palette := array[] of {
	int 16r000000FF, int 16r0000AAFF, int 16r00AA00FF, int 16r00AAAAFF,
	int 16rAA0000FF, int 16rAA00AAFF, int 16rAA5500FF, int 16rAAAAAAFF,
	int 16r555555FF, int 16r5555FFFF, int 16r55FF55FF, int 16r55FFFFFF,
	int 16rFF5555FF, int 16rFF55FFFF, int 16rFFFF55FF, int 16rFFFFFFFF
};

dsin := 0.0;
hexradius := 0.0;
mapcols := 0;
maprows := 0;
mapw := 0;
maph := 0;
mapready := 0;	# guards redraw against a map mid-rebuild
canvas: array of byte;
mapimg: ref Image;
terrain: array of array of int;
roads: array of array of int;
rivers: array of array of int;
vismap: array of array of int;
hexcx: array of array of real;
hexcy: array of array of real;
x0 := 0;
y0 := 0;

units: array of array of ref Unit;
visbm: array of array of array of int;
alive := array[2] of int;
phase := 0;
cur_player := 0;
enemy_player := 1;
view_player := 0;
turn := 0;
cursor_row := 0;
cursor_col := 0;
show_vis := 0;
show_vis_row := -1;
show_vis_col := -1;
adelay := 0.5;			# animation_delay
moving := 0;
move_x := 0;
move_y := 0;
move_facing := 0.0;
moving_unit: ref Unit;
orders: list of ref Iorder;
firing := 0;
fire_x := 0;
fire_y := 0;
target_unit: ref Unit;
target_hit := 0;
indirect_explosion := 0;
indirect_row := 0;
indirect_col := 0;
fire_radius := 0.0;
fire_radius_x := 0.0;
fire_radius_y := 0.0;
msg := "";
msgoff := 0;
mode := Mgame;
pickplayer := 0;
playerctl := array[2] of { * => CTLHUMAN };
seedbuf := "";
lastmx := 0;
lastmy := 0;
lastbut := 0;

loglines: array of list of (int, string);
logn := 0;
curline: list of (int, string);
logscroll := 0;

curhl: ref Image;
curhlr: Rect;
curhlrow := -1;
curhlcol := -1;

kbdch: chan of int;
ptrch: chan of (int, int, int);
tickch: chan of int;
quitch: chan of int;

rowoff := array[] of {-1, -2, -1, 1, 2, 1, 0};
coloffe := array[] of {-1, 0, 0, 0, 0, -1, 0};
coloffo := array[] of {0, 0, 1, 1, 0, 0, 0};
movecost: array of int;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	draw3d = load Draw3d Draw3d->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(draw3d != nil)
		draw3d->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	dsin = HEXSIDE*math->sin(60.0/180.0*Math->Pi);
	hexradius = dsin + 0.01;
	movecost = array[16] of { * => 0 };
	movecost[PLAINS] = 2;
	movecost[TREES] = 6;
	movecost[MOUNTAINS] = 10;

	win = wmclient->window(ctxt, "TempleOS ToTheFront", Wmclient->Appl);
	display = win.display;
	ink = array[16] of ref Image;
	for(i := 0; i < 16; i++)
		ink[i] = display.color(palette[i]);
	tfont = Font.open(display, "/fonts/temple/temple.font");
	if(tfont == nil)
		tfont = Font.open(display, "*default*");

	spr = array[4] of ref Image;
	sprmask = array[4] of ref Image;
	tints = array[4*16] of ref Image;
	for(i = 0; i < 4; i++){
		spr[i] = display.open(sys->sprint("/icons/temple/ttfinit_%d.bit", i+1));
		sprmask[i] = display.open(sys->sprint("/icons/temple/ttfinit_%d.mask", i+1));
	}
	marker = display.open("/icons/temple/ttfdraw_1.bit");
	markermask = display.open("/icons/temple/ttfdraw_1.mask");

	units = array[2] of array of ref Unit;
	visbm = array[2] of array of array of int;
	for(j := 0; j < 2; j++){
		units[j] = array[UNITSNUM] of ref Unit;
		visbm[j] = array[UNITSNUM] of array of int;
		for(i = 0; i < UNITSNUM; i++)
			visbm[j][i] = array[UNITSNUM] of { * => 0 };
	}
	loglines = array[LOGMAX] of list of (int, string);

	kbdch = chan[64] of int;
	ptrch = chan[64] of (int, int, int);
	tickch = chan of int;
	quitch = chan of int;

	win.reshape(Rect((0, 0), (720, 560)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	spawn timer(tickch, 33);
	spawn engine();

	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		dopointer(p);
	k := <-win.ctxt.kbd =>
		alt{
		kbdch <-= k =>
			;
		* =>
			;
		}
	<-tickch =>
		redraw();
	<-quitch =>
		if(have_tone)
			tone->stop();
		exit;
	}
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

dopointer(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	lastmx = x;
	lastmy = y;
	b := p.buttons;
	if((b&1) && !(lastbut&1))
		nbptr(Mldown, x, y);
	if(!(b&1) && (lastbut&1))
		nbptr(Mlup, x, y);
	if(!(b&4) && (lastbut&4))
		nbptr(Mrup, x, y);
	lastbut = b;
}

nbptr(t, x, y: int)
{
	alt{
	ptrch <-= (t, x, y) =>
		;
	* =>
		;
	}
}

# ---- small helpers ----

now(): int
{
	return sys->millisec();
}

ts(): real
{
	return real sys->millisec() / 1000.0;
}

frand(): real
{
	return real rand->rand(1073741823) / 1073741823.0;
}

trunc0(x: real): int
{
	i := int x;		# Limbo rounds to nearest, like HolyC ToI64
	if(x >= 0.0){
		if(real i > x)
			i--;
	}else{
		if(real i < x)
			i++;
	}
	return i;
}

clampi(v, lo, hi: int): int
{
	if(v < lo)
		return lo;
	if(v > hi)
		return hi;
	return v;
}

sq(x: real): real
{
	return x*x;
}

blink(f: real): int
{
	return (int (ts()*f*2.0)) & 1;
}

saw(t, m: real): real
{
	return math->fmod(t, m);
}

sndfreq(ona: int): int
{
	# TempleOS Snd(ona) in semitones: 440*2^((ona-49)/12)
	return int (440.0*math->pow(2.0, real(ona-49)/12.0));
}

sndsemi(ona: int)
{
	if(have_tone)
		tone->snd(sndfreq(ona));
}

sndoff()
{
	if(have_tone)
		tone->stop();
}

beep()
{
	if(have_tone)
		tone->beep(800, 60);
}

msleep(msr: real)
{
	msi := int msr;
	if(msi < 0)
		msi = 0;
	sys->sleep(msi);
}

noisewait(msr: real, lo, hi: int)
{
	# TempleOS Noise(ms,lo,hi) queues random tones between the two
	# semitones while the caller Sleeps the same ms in parallel;
	# here it is synchronous, standing in for both calls.
	msi := int msr;
	if(msi <= 0)
		return;
	if(!have_tone){
		sys->sleep(msi);
		return;
	}
	t0 := now();
	while(now() - t0 < msi){
		tone->snd(sndfreq(lo + rand->rand(hi-lo+1)));
		sys->sleep(20);
	}
	tone->stop();
}

# ---- hex geometry (TTFLib.HC) ----

toward(row, col, direction: int): (int, int)
{
	case direction {
	0 =>
		row -= 2;
	1 =>
		if(row & 1)
			col += 1;
		row -= 1;
	2 =>
		if(row & 1)
			col += 1;
		row += 1;
	3 =>
		row += 2;
	4 =>
		if(!(row & 1))
			col -= 1;
		row += 1;
	5 =>
		if(!(row & 1))
			col -= 1;
		row -= 1;
	}
	return (row, col);
}

facingchg(f1, f2: int): int
{
	res := (f1+6-f2) % 6;
	if(res >= 3)
		return 6 - res;
	return res;
}

rc2xy(row, col: int): (real, real)
{
	row = clampi(row, 0, maprows-1);
	col = clampi(col, 0, mapcols-1);
	return (hexcx[row][col], hexcy[row][col]);
}

xy2rc(x, y: real): (int, int)
{
	col := int ((x - DCOS/2.0)/(HEXSIDE + DCOS));
	row: int;
	if(col & 1)
		row = (int ((y - dsin)/(2.0*dsin)))*2 + 1;
	else
		row = (int (y/(2.0*dsin)))*2;
	col >>= 1;
	row = clampi(row, 0, maprows-1);
	col = clampi(col, 0, mapcols-1);
	return (row, col);
}

unitfind(row, col: int): ref Unit
{
	for(j := 0; j < 2; j++)
		for(i := 0; i < UNITSNUM; i++){
			u := units[j][i];
			if(u != nil && u.life > 0 && u.row == row && u.col == col)
				return u;
		}
	return nil;
}

cursorupd(wx, wy: int)
{
	(cursor_row, cursor_col) = xy2rc(real(wx - x0), real(wy - y0));
}

los(r1, c1, r2, c2: int): int
{
	(x1, y1) := rc2xy(r1, c1);
	(x2, y2) := rc2xy(r2, c2);
	distance := int math->sqrt(sq(x1-x2) + sq(y1-y2));
	adx := x2 - x1;
	if(adx < 0.0)
		adx = -adx;
	ady := y2 - y1;
	if(ady < 0.0)
		ady = -ady;
	steps := int adx;
	if(int ady > steps)
		steps = int ady;
	if(steps <= 0)
		return 1;
	for(i := 0; i <= steps; i++){
		px := x1 + (x2-x1)*real i/real steps;
		py := y1 + (y2-y1)*real i/real steps;
		z := distance*i/steps;
		(row, col) := xy2rc(px, py);
		if((row != r1 || col != c1) && (row != r2 || col != c2) &&
		    terrain[row][col] != PLAINS){
			if(terrain[r1][c1] == MOUNTAINS){
				if(terrain[row][col] == MOUNTAINS || z > distance>>1)
					return 0;
			}else if(terrain[r2][c2] == MOUNTAINS){
				if(terrain[row][col] == MOUNTAINS || z <= distance>>1)
					return 0;
			}else
				return 0;
		}
	}
	return 1;
}

# ---- software map canvas (TTFInit.HC map drawing) ----

cget(x, y: int): int
{
	if(x < 0 || x >= mapw || y < 0 || y >= maph)
		return -1;
	return int canvas[y*mapw + x];
}

cput(x, y, c: int)
{
	if(x < 0 || x >= mapw || y < 0 || y >= maph)
		return;
	canvas[y*mapw + x] = byte c;
}

cbrush(x, y, thick, c: int)
{
	lo := -((thick-1)/2);
	hi := thick/2;
	for(dy := lo; dy <= hi; dy++)
		for(dx := lo; dx <= hi; dx++)
			cput(x+dx, y+dy, c);
}

cline(x1, y1, x2, y2: real, thick, c: int)
{
	adx := x2 - x1;
	if(adx < 0.0)
		adx = -adx;
	ady := y2 - y1;
	if(ady < 0.0)
		ady = -ady;
	steps := int adx;
	if(int ady > steps)
		steps = int ady;
	if(steps <= 0){
		cbrush(int x1, int y1, thick, c);
		return;
	}
	for(i := 0; i <= steps; i++){
		px := x1 + (x2-x1)*real i/real steps;
		py := y1 + (y2-y1)*real i/real steps;
		cbrush(int px, int py, thick, c);
	}
}

cflood(x, y, c: int)
{
	old := cget(x, y);
	if(old < 0 || old == c)
		return;
	stack := array[4096] of int;
	sp := 0;
	stack[sp++] = y*mapw + x;
	cput(x, y, c);
	while(sp > 0){
		pos := stack[--sp];
		px := pos % mapw;
		py := pos / mapw;
		for(k := 0; k < 4; k++){
			nx := px;
			ny := py;
			case k {
			0 =>	nx++;
			1 =>	nx--;
			2 =>	ny++;
			3 =>	ny--;
			}
			if(cget(nx, ny) == old){
				cput(nx, ny, c);
				if(sp >= len stack){
					ns := array[2*len stack] of int;
					ns[0:] = stack;
					stack = ns;
				}
				stack[sp++] = ny*mapw + nx;
			}
		}
	}
}

drawhexes()
{
	dx := 2.0*HEXSIDE + 2.0*DCOS;
	dy := 2.0*dsin;
	x, y, x1, y1, x2, y2: real;
	y = 0.0;
	for(j := 0; j < maprows; j += 2){
		x = DCOS;
		cline(x, y, x-DCOS, y+dsin, 1, BLACK);
		cline(x-DCOS, y+dsin, x, y+2.0*dsin, 1, BLACK);
		for(i := 0; i < mapcols; i++){
			x1 = x; y1 = y;
			x2 = x1+HEXSIDE; y2 = y1;
			cline(x1, y1, x2, y2, 1, BLACK);
			x1 = x2; y1 = y2;
			x2 += DCOS; y2 += dsin;
			cline(x1, y1, x2, y2, 1, BLACK);
			cline(x2, y2, x2-DCOS, y2+dsin, 1, BLACK);
			x1 = x2; y1 = y2;
			x2 += HEXSIDE;
			cline(x1, y1, x2, y2, 1, BLACK);
			cline(x2, y2, x2+DCOS, y2+dsin, 1, BLACK);
			x1 = x2; y1 = y2;
			x2 += DCOS; y2 -= dsin;
			if(j || i < mapcols-1)
				cline(x1, y1, x2, y2, 1, BLACK);
			x += dx;
		}
		y += dy;
	}
	x = DCOS;
	for(i := 0; i < mapcols; i++){
		x1 = x; y1 = y;
		x2 = x1+HEXSIDE; y2 = y1;
		cline(x1, y1, x2, y2, 1, BLACK);
		x1 = x2; y1 = y2;
		x2 += DCOS; y2 += dsin;
		cline(x1, y1, x2, y2, 1, BLACK);
		x1 = x2; y1 = y2;
		x2 += HEXSIDE;
		cline(x1, y1, x2, y2, 1, BLACK);
		x1 = x2; y1 = y2;
		x2 += DCOS; y2 -= dsin;
		cline(x1, y1, x2, y2, 1, BLACK);
		x += dx;
	}
}

maketerrain(color, cnt, cluslo, clushi: int)
{
	for(i := 0; i < cnt; i++){
		col := rand->rand(mapcols);
		row := rand->rand(maprows);
		l := cluslo + rand->rand(clushi-cluslo+1);
		for(j := 0; j < l; j++){
			terrain[row][col] = color;
			(row, col) = toward(row, col, rand->rand(6));
			col = clampi(col, 0, mapcols-1);
			row = clampi(row, 0, maprows-1);
		}
	}
}

makerivers()
{
	for(i := 0; i < 4; i++){
		row := rand->rand(maprows);
		col := rand->rand(mapcols);
		direction := rand->rand(6);
		for(;;){
			rivers[row][col] = 1;
			(row, col) = toward(row, col, direction);
			if(!(0 <= row && row < maprows && 0 <= col && col < mapcols))
				break;
			if(!(rand->rand(65536) & 3))
				direction = (direction + (7 - rand->rand(3))) % 6;
		}
	}
}

makeroads()
{
	for(i := 0; i < 5; i++){
		row := rand->rand(maprows);
		col := rand->rand(mapcols);
		direction := rand->rand(6);
		for(;;){
			roads[row][col] = 1;
			(row, col) = toward(row, col, direction);
			if(!(0 <= row && row < maprows && 0 <= col && col < mapcols))
				break;
			if(!(rand->rand(65536) % 3))
				direction = (direction + (7 - rand->rand(3))) % 6;
		}
	}
}

drawterrain()
{
	for(j := 0; j < maprows; j++)
		for(i := 0; i < mapcols; i++){
			(x, y) := rc2xy(j, i);
			cflood(int x, int y, terrain[j][i]);
		}
}

drawrivers()
{
	for(j := 0; j < maprows; j++)
		for(i := 0; i < mapcols; i++){
			if(!rivers[j][i])
				continue;
			(x1, y1) := rc2xy(j, i);
			for(k := 0; k < 6; k++){
				(r, c) := toward(j, i, k);
				if(0 <= r && r < maprows && 0 <= c && c < mapcols &&
				    rivers[r][c]){
					(x2, y2) := rc2xy(r, c);
					cline(x1, y1, x2, y2, 4, LTBLUE);
					cline(x1, y1, x2, y2, 2, BLUE);
				}
			}
		}
}

drawroads()
{
	for(j := 0; j < maprows; j++)
		for(i := 0; i < mapcols; i++){
			if(!roads[j][i])
				continue;
			(x1, y1) := rc2xy(j, i);
			for(k := 0; k < 6; k++){
				(r, c) := toward(j, i, k);
				if(0 <= r && r < maprows && 0 <= c && c < mapcols &&
				    roads[r][c]){
					(x2, y2) := rc2xy(r, c);
					cline(x1, y1, x2, y2, 3, RED);
				}
			}
		}
}

drawdots()
{
	for(j := 0; j < maprows; j++)
		for(i := 0; i < mapcols; i++){
			(x, y) := rc2xy(j, i);
			cput(int x, int y, BLACK);
		}
}

buildmapimg()
{
	data := array[mapw*maph*3] of byte;
	for(p := 0; p < mapw*maph; p++){
		v := palette[int canvas[p]];
		data[p*3] = byte (v>>8);	# blue
		data[p*3+1] = byte (v>>16);	# green
		data[p*3+2] = byte (v>>24);	# red
	}
	mapimg = display.newimage(Rect((0, 0), (mapw, maph)), Draw->RGB24, 0, Draw->White);
	if(mapimg != nil)
		mapimg.writepixels(mapimg.r, data);
}

initmap()
{
	mapready = 0;
	# geometry from the window, like the original's GR_WIDTH/GR_HEIGHT
	grw := 720;
	grh := 560;
	img := win.image;
	if(img != nil){
		grw = img.r.dx();
		grh = img.r.dy();
	}
	mapwidth := grw;
	mapheight := (grh - FONTH*2)*mapwidth/grw;
	mapcols = trunc0((real mapwidth - DCOS)/(2.0*HEXSIDE + 2.0*DCOS));
	maprows = trunc0((real mapheight - dsin)/dsin) & ~1;
	mapw = int (real mapcols*(2.0*HEXSIDE + 2.0*DCOS) + DCOS);
	maph = int (real maprows*dsin + dsin + 1.0);
	while(maprows > 2 && maph + FONTH > grh){
		maprows -= 2;
		maph = int (real maprows*dsin + dsin + 1.0);
	}
	x0 = (grw - mapw)/2;
	if(x0 < 0)
		x0 = 0;
	y0 = FONTH + (grh - FONTH - maph)/2;
	if(y0 < FONTH)
		y0 = FONTH;

	hexcx = array[maprows] of array of real;
	hexcy = array[maprows] of array of real;
	for(j := 0; j < maprows; j++){
		hexcx[j] = array[mapcols] of real;
		hexcy[j] = array[mapcols] of real;
		for(i := 0; i < mapcols; i++){
			x := (2.0*HEXSIDE + 2.0*DCOS)*real i + HEXSIDE/2.0 + DCOS;
			if(j & 1)
				x += HEXSIDE + DCOS;
			hexcx[j][i] = x;
			hexcy[j][i] = dsin*real(j+1);
		}
	}
	terrain = array[maprows] of array of int;
	roads = array[maprows] of array of int;
	rivers = array[maprows] of array of int;
	vismap = array[maprows] of array of int;
	for(j = 0; j < maprows; j++){
		terrain[j] = array[mapcols] of { * => PLAINS };
		roads[j] = array[mapcols] of { * => 0 };
		rivers[j] = array[mapcols] of { * => 0 };
		vismap[j] = array[mapcols] of { * => 0 };
	}
	canvas = array[mapw*maph] of { * => byte WHITE };
	drawhexes();
	nclus := int (0.03*real(mapcols*mapcols));
	maketerrain(MOUNTAINS, nclus, 5, 35);
	maketerrain(TREES, nclus, 5, 35);
	drawterrain();
	makerivers();
	drawrivers();
	makeroads();
	drawroads();
	drawdots();
	buildmapimg();
	curhlrow = -1;
	curhlcol = -1;
	curhl = nil;
	mapready = 1;
}

# ---- units (TTFInit.HC) ----

initunits()
{
	alive[0] = alive[1] = UNITSNUM;
	for(j := 0; j < 2; j++)
		for(i := 0; i < UNITSNUM; i++){
			u := ref Unit;
			u.vis = array[2] of { * => 0 };
			u.player = j;
			u.num = i;
			u.life = 100;
			u.facing = rand->rand(6);
			u.fired = 0;
			typ: int;
			if(i >= UNITSNUM/2){
				if(i >= 15*UNITSNUM/16)
					typ = UTARTILLERY;
				else
					typ = UTINFANTRY;
			}else{
				if(i >= UNITSNUM/4)
					typ = UTMDTANK;
				else
					typ = UTLTTANK;
			}
			u.typ = typ;
			case typ {
			UTINFANTRY =>
				u.infantry = 1;
				u.indirect_fire = 0;
				u.armor = 0;
				u.armored_attack = 15;
				u.unarmored_attack = 180;
				u.accuracy = 45;
				u.rng = 5;
				u.movement = 4;
			UTARTILLERY =>
				u.infantry = 1;
				u.indirect_fire = 1;
				u.armor = 0;
				u.armored_attack = 60;
				u.unarmored_attack = 180;
				u.accuracy = 25;
				u.rng = 20;
				u.movement = 2;
			UTLTTANK =>
				u.infantry = 0;
				u.indirect_fire = 0;
				u.armor = 30;
				u.armored_attack = 40;
				u.unarmored_attack = 60;
				u.accuracy = 25;
				u.rng = 8;
				u.movement = 24;
			UTMDTANK =>
				u.infantry = 0;
				u.indirect_fire = 0;
				u.armor = 60;
				u.armored_attack = 60;
				u.unarmored_attack = 80;
				u.accuracy = 25;
				u.rng = 12;
				u.movement = 16;
			}
			u.remaining_movement = u.movement;
			units[j][i] = u;
			row, col: int;
			do {
				row = rand->rand(maprows);
				col = rand->rand(mapcols/3);
				if(j)
					col += 2*mapcols/3;
			} while(unitfindother(row, col, u) != nil);
			u.row = row;
			u.col = col;
			u.vis[cur_player] = 1;
		}
}

unitfindother(row, col: int, notu: ref Unit): ref Unit
{
	for(j := 0; j < 2; j++)
		for(i := 0; i < UNITSNUM; i++){
			u := units[j][i];
			if(u != nil && u != notu && u.life > 0 &&
			    u.row == row && u.col == col)
				return u;
		}
	return nil;
}

viewplayerset(p: int)
{
	view_player = p;
}

# ---- visibility (TTFVis.HC, single-threaded) ----

vrsetup(player: int)
{
	for(i := 0; i < UNITSNUM; i++){
		units[player^1][i].vis[player] = 0;
		if(units[player][i].life > 0)
			units[player][i].vis[player] = 1;
		else
			units[player][i].vis[player] = 0;
	}
}

vrmerge(player: int)
{
	for(j := 0; j < UNITSNUM; j++){
		seen := 0;
		for(i := 0; i < UNITSNUM; i++)
			if(visbm[player][i][j]){
				seen = 1;
				break;
			}
		ut1 := units[player^1][j];
		if(seen && ut1.life > 0)
			ut1.vis[player] = 1;
		else
			ut1.vis[player] = 0;
	}
}

visrecalc(recmode: int, tu: ref Unit): int
{
	res := 0;
	case recmode {
	VRDIED =>
		# note: indexes by the global enemy_player, as the original does
		# even when the dead unit is the current player's (HexOccupy failure)
		for(j := 0; j < UNITSNUM; j++)
			visbm[enemy_player][tu.num][j] = 0;
		vrmerge(enemy_player);
	VRONEFRIENDLY or
	VRUPDATE =>
		rangelim := 0.0;
		unlimited := 0;
		if(recmode == VRUPDATE)
			unlimited = 1;
		else{
			r := real tu.rng*2.0*hexradius;
			rangelim = r*r;
		}
		(x1, y1) := rc2xy(tu.row, tu.col);
		for(i := 0; i < UNITSNUM; i++){
			ut1 := units[enemy_player][i];
			seen := 0;
			if(ut1.life > 0 && los(tu.row, tu.col, ut1.row, ut1.col)){
				(x2, y2) := rc2xy(ut1.row, ut1.col);
				dd := sq(x2-x1) + sq(y2-y1);
				if(unlimited || dd < rangelim){
					seen = 1;
					ut1.vis[cur_player] = 1;
				}
			}
			if(recmode == VRUPDATE)
				visbm[cur_player][tu.num][i] = seen;
		}
		if(recmode == VRUPDATE)
			vrmerge(cur_player);
	VRONEENEMY =>
		for(i := 0; i < UNITSNUM; i++){
			obs := units[enemy_player][i];
			if(obs.life > 0 && los(tu.row, tu.col, obs.row, obs.col)){
				visbm[enemy_player][i][tu.num] = 1;
				res = 1;
			}else
				visbm[enemy_player][i][tu.num] = 0;
		}
	VRALL =>
		for(p := 0; p < 2; p++){
			op := p^1;
			for(i := 0; i < UNITSNUM; i++){
				ut0 := units[p][i];
				for(j := 0; j < UNITSNUM; j++){
					ut1 := units[op][j];
					if(ut0.life > 0 && ut1.life > 0 &&
					    los(ut0.row, ut0.col, ut1.row, ut1.col)){
						ut1.vis[p] = 1;
						visbm[p][i][j] = 1;
					}else
						visbm[p][i][j] = 0;
				}
			}
		}
	}
	return res;
}

visrecalcmap(row, col: int)
{
	for(j := 0; j < maprows; j++)
		for(i := 0; i < mapcols; i++)
			vismap[j][i] = los(row, col, j, i);
}

# ---- combat log (the original's DolDoc odds printout; 'c' views it) ----

logseg(c: int, s: string)
{
	curline = (c, s) :: curline;
}

lognl()
{
	l: list of (int, string);
	for(x := curline; x != nil; x = tl x)
		l = hd x :: l;
	loglines[logn % LOGMAX] = l;
	logn++;
	curline = nil;
}

logline(c: int, s: string)
{
	logseg(c, s);
	lognl();
}

logclear()
{
	logn = 0;
	curline = nil;
	logscroll = 0;
}

# ---- movement (TTFMove.HC) ----

hexmoveonecost(u: ref Unit, r, c, facing: int): int
{
	res: int;
	if(u.infantry)
		res = 0;
	else{
		res = facingchg(facing, u.facing);
		if(res > 0)
			res--;
	}
	if(roads[r][c] && roads[u.row][u.col])
		res += 1;
	else{
		if(u.infantry)
			res += 2;
		else{
			res += movecost[terrain[r][c]];
			if(rivers[r][c])
				res = u.movement;
		}
	}
	return res;
}

hexmoveone(row, col: int, x, y: real): (int, int, int)
{
	bestdir := -1;
	(x1, y1) := rc2xy(row, col);
	bestdd := sq(x1-x) + sq(y1-y);
	for(direction := 0; direction < 6; direction++){
		(r, c) := toward(row, col, direction);
		(x2, y2) := rc2xy(r, c);
		dd := sq(x2-x) + sq(y2-y);
		if(0 <= r && r < maprows && 0 <= c && c < mapcols && dd < bestdd){
			bestdd = dd;
			bestdir = direction;
		}
	}
	if(bestdir >= 0){
		(row, col) = toward(row, col, bestdir);
		return (bestdir, row, col);
	}
	return (-1, row, col);
}

wrapang(a: real): real
{
	while(a >= Math->Pi)
		a -= 2.0*Math->Pi;
	while(a < -Math->Pi)
		a += 2.0*Math->Pi;
	return a;
}

unitmoveanimation(u: ref Unit, r, c, facing: int)
{
	f := real facing*60.0*Math->Pi/180.0;
	moving_unit = u;
	(x1, y1) := rc2xy(u.row, u.col);
	move_x = int x1;
	move_y = int y1;
	moving = 1;
	if(u.infantry)
		sndsemi(53);
	else{
		move_facing = real u.facing*60.0*Math->Pi/180.0;
		sndsemi(41);
		while(wrapang(f-move_facing) <= 0.0){
			move_facing -= 0.03;
			msleep(5.0*adelay);
		}
		while(wrapang(f-move_facing) > 0.0){
			move_facing += 0.03;
			msleep(5.0*adelay);
		}
		sndsemi(34);
	}
	move_facing = f;
	(x2, y2) := rc2xy(r, c);
	adx := x2-x1;
	if(adx < 0.0)
		adx = -adx;
	ady := y2-y1;
	if(ady < 0.0)
		ady = -ady;
	steps := int adx;
	if(int ady > steps)
		steps = int ady;
	for(i := 0; i <= steps; i++){
		move_x = int (x1 + (x2-x1)*real i/real steps);
		move_y = int (y1 + (y2-y1)*real i/real steps);
		msleep(5.0*adelay);
	}
	sndoff();
	moving_unit = nil;
	moving = 0;
}

unitmove(u: ref Unit, x, y: real): int
{
	r0 := u.row;
	c0 := u.col;
	died := 0;
	while(u.remaining_movement > 0){
		(facing, r, c) := hexmoveone(u.row, u.col, x, y);
		if(facing < 0)
			break;
		i := hexmoveonecost(u, r, c, facing);
		if(i > u.movement)
			i = u.movement;
		if(!u.fired && u.remaining_movement >= i &&
		    u.remaining_movement >= u.movement>>1){
			target := unitfind(r, c);
			if(target != nil && target.player != u.player &&
			    u.infantry != target.infantry){
				if(!hexoccupy(target.infantry, u, target)){
					died = 1;
					break;
				}
				i = u.remaining_movement;
			}
		}
		if(u.remaining_movement >= i && unitfind(r, c) == nil){
			unitmoveanimation(u, r, c, facing);
			u.facing = facing;
			u.remaining_movement -= i;
			u.row = r;
			u.col = c;
			visrecalc(VRUPDATE, u);
			u.vis[enemy_player] = visrecalc(VRONEENEMY, u);
		}else
			break;
	}
	if(died || u.row != r0 || u.col != c0)
		return 1;
	return 0;
}

# ---- combat (TTFFire.HC) ----

attackheader(u: ref Unit, act: string, target: ref Unit)
{
	n := 9 + len act;
	if(target != nil){
		n += 9;
		if(target.armor)
			n += 8;
		else
			n += 10;
	}
	dashes := "";
	for(i := 0; i < n; i++)
		dashes += "-";
	lognl();
	logline(BLACK, dashes);
	if(u.player)
		logseg(PURPLE, "Player 2 ");
	else
		logseg(CYAN, "Player 1 ");
	logseg(BLACK, act);
	if(target != nil){
		if(target.player)
			logseg(PURPLE, " Player 2");
		else
			logseg(CYAN, " Player 1");
		if(target.armor)
			logseg(BLACK, " Armored");
		else
			logseg(BLACK, " Unarmored");
	}
	lognl();
	logline(BLACK, dashes);
}

facingname(f: int): string
{
	case f {
	0 =>	return "Front";
	1 =>	return "FrontSide";
	2 =>	return "RearSide";
	* =>	return "Rear";
	}
}

hitdamage(u, target: ref Unit, facing: int, range_factor: real): real
{
	res := 200.0*frand();
	logline(BLACK, sys->sprint("Roll Out of 200        :%6.2f Damage", res));
	if(target.armor){
		d := real target.armor/100.0*real(5-facing)/5.0;
		if(d >= 0.0){
			logline(BLACK, sys->sprint("ArmorAttack            :%6.2f",
				real u.armored_attack));
			res *= (real u.armored_attack/100.0)/d;
		}else
			res = 0.0;
		logline(BLACK, sys->sprint("Armor(%s)Defense :%6.2f",
			facingname(facing), 100.0*d));
	}else{
		d := 1.0 - range_factor;
		if(d > 0.0){
			logline(BLACK, sys->sprint("Unarmored Attack       :%6.2f",
				real u.unarmored_attack));
			logline(BLACK, sys->sprint("Range Adjust           :%6.2f%%",
				100.0*d));
			res *= (real u.unarmored_attack/100.0)*d;
		}else
			res = 0.0;
	}
	logline(BLACK, sys->sprint("Attack/Defense Adjusted:%6.2f Damage", res));
	return real (int res);
}

damagedo(target: ref Unit, damage: real): int
{
	if(damage <= 0.0)
		return 0;
	if(target.armor)
		logseg(BLACK, sys->sprint("Armor Hit Score %6.2f :", damage));
	else
		logseg(BLACK, sys->sprint("%3d Life - %3.0f Damage =",
			target.life, damage));
	if(damage >= real target.life){
		logseg(RED, "Killed");
		lognl();
		noisewait(1000.0*adelay, 74, 98);
		target.life = 0;
		visrecalc(VRDIED, target);
		alive[target.player]--;
		return 1;
	}
	if(target.armor){
		if(damage > 0.6*real target.life){
			target.movement = 0;
			logseg(RED, "Immobilized");
		}else
			logseg(GREEN, "No Penetration");
		lognl();
	}else{
		target.life -= int damage;
		logseg(RED, sys->sprint("%6.2f Life", real target.life));
		lognl();
	}
	return 0;
}

indirectadd(u: ref Unit, row, col: int)
{
	if(u.life <= 0 || u.rng <= 0)
		return;
	u.fired = 1;
	o := ref Iorder;
	o.u = u;
	o.row = row;
	o.col = col;
	orders = o :: orders;
}

bulletwalk(x1, y1, x2, y2: real)
{
	adx := x2-x1;
	if(adx < 0.0)
		adx = -adx;
	ady := y2-y1;
	if(ady < 0.0)
		ady = -ady;
	steps := int adx;
	if(int ady > steps)
		steps = int ady;
	if(steps <= 0)
		steps = 1;
	for(i := 0; i <= steps; i++){
		fire_x = int (x1 + (x2-x1)*real i/real steps);
		fire_y = int (y1 + (y2-y1)*real i/real steps);
		firing = 1;
		msleep(3.0*adelay);
	}
}

unitdirectfire(u, target: ref Unit)
{
	if(u.life <= 0 || target.life <= 0 || u.rng <= 0)
		return;
	attackheader(u, "DirectFire", target);
	(x1, y1) := rc2xy(u.row, u.col);
	(x2, y2) := rc2xy(target.row, target.col);
	d := 100.0*frand();
	logline(BLACK, sys->sprint("+%5.2f Roll", d));
	d += real u.accuracy;
	logline(BLACK, sys->sprint("+%2d.00 Accuracy", u.accuracy));
	range_factor := math->sqrt(sq(x2-x1) + sq(y2-y1))/(real u.rng*2.0*dsin);
	logline(BLACK, sys->sprint("-%5.2f %% of Range", 100.0*range_factor));
	d -= 100.0*range_factor;
	t1 := terrain[u.row][u.col];
	t2 := terrain[target.row][target.col];
	if(t2 == TREES){
		logline(BLACK, "-30.00 Target in Trees Penalty");
		d -= 30.0;
	}
	if(t1 == MOUNTAINS && t2 != MOUNTAINS){
		logline(BLACK, "+30.00 High Ground Bonus");
		d += 30.0;
	}
	logline(BLACK, "_______");
	target_unit = target;
	if(d >= 0.0){
		logline(BLACK, sys->sprint("+%5.2f Hit", d));
		target_hit = 1;
		noisewait(500.0*adelay, 34, 41);
		bulletwalk(x1, y1, x2, y2);
	}else{
		logline(BLACK, sys->sprint("-%5.2f Miss", -d));
		target_hit = 0;
		noisewait(1000.0*adelay, 69, 74);
		a := 2.0*Math->Pi*frand();
		dd := (0.5 - d/100.0)*HEXSIDE;
		bulletwalk(x1, y1, x2 + dd*math->cos(a), y2 + dd*math->sin(a));
	}
	firing = 0;
	u.fired = 1;
	if(target_hit){
		(fdir, nil, nil) := hexmoveone(target.row, target.col, x1, y1);
		facing := 0;
		if(fdir >= 0)
			facing = facingchg(fdir, target.facing);
		damagedo(target, hitdamage(u, target, facing, range_factor));
	}
	target_unit = nil;
}

hexoccupy(overrun: int, u, target: ref Unit): int
{
	t2 := terrain[target.row][target.col];
	if(u.life <= 0 || target.life <= 0)
		return 0;
	if(overrun)
		attackheader(u, "OverRun", target);
	else
		attackheader(u, "CloseAssault", target);
	noisewait(500.0*adelay, 34, 41);
	u.fired = 1;
	target.fired = 1;
	damage := hitdamage(u, target, 1, 0.0);
	if(overrun){
		damage *= 2.0;
		logline(BLACK, sys->sprint("x2 OverRun Bonus       =%6.2f Damage", damage));
		if(t2 != PLAINS){
			damage /= 2.0;
			logline(BLACK, sys->sprint("/2 Terrain Penalty     =%6.2f Damage", damage));
		}
	}else{
		damage *= 3.0;
		logline(BLACK, sys->sprint("x3 CloseAssault Bonus  =%6.2f Damage", damage));
	}
	if(damagedo(target, real (int damage))){
		logline(RED, "Success");
		return 1;
	}
	u.life = 0;
	visrecalc(VRDIED, u);
	alive[u.player]--;
	logline(RED, "Failure");
	return 0;
}

indirectresolveall()
{
	# FIFO like the original's queue
	lst: list of ref Iorder;
	for(x := orders; x != nil; x = tl x)
		lst = hd x :: lst;
	orders = nil;
	for(; lst != nil; lst = tl lst){
		o := hd lst;
		u := o.u;
		attackheader(u, "IndirectFire", nil);
		(x1, y1) := rc2xy(u.row, u.col);
		(x2, y2) := rc2xy(o.row, o.col);
		d := 100.0*frand();
		logline(BLACK, sys->sprint("+%5.2f Roll", d));
		d += real u.accuracy;
		logline(BLACK, sys->sprint("+%2d.00 Accuracy", u.accuracy));
		range_factor := math->sqrt(sq(x2-x1) + sq(y2-y1))/(real u.rng*2.0*dsin);
		logline(BLACK, sys->sprint("-%5.2f %% of Range", 100.0*range_factor));
		d -= 100.0*range_factor;
		logline(BLACK, "_______");
		if(d >= 0.0){
			logline(BLACK, sys->sprint("+%5.2f Hit", d));
			noisewait(500.0*adelay, 34, 41);
		}else{
			logline(BLACK, sys->sprint("-%5.2f Miss", -d));
			noisewait(1000.0*adelay, 69, 74);
			i := rand->rand(6);
			if(o.row & 1)
				o.col += coloffo[i];
			else
				o.col += coloffe[i];
			o.row += rowoff[i];
			(x2, y2) = rc2xy(o.row, o.col);
		}
		bulletwalk(x1, y1, x2, y2);
		firing = 0;
		u.fired = 1;
		indirect_row = o.row;
		indirect_col = o.col;
		indirect_explosion = 1;
		for(i := 0; i < 7; i++){
			c: int;
			if(o.row & 1)
				c = o.col + coloffo[i];
			else
				c = o.col + coloffe[i];
			r := o.row + rowoff[i];
			if(0 <= r && r < maprows && 0 <= c && c < mapcols){
				target := unitfind(r, c);
				if(target != nil){
					attackheader(u, "IndirectFire", target);
					damagedo(target, hitdamage(u, target, 1, 0.0));
				}
			}
		}
		noisewait(2000.0*adelay, 70, 74);
		indirect_explosion = 0;
	}
}

# ---- turn structure (ToTheFront.HC) ----

banner(s: string)
{
	# SleepUntil(msg_off_timeout): wait out the previous banner
	while(msgoff > 0 && now() < msgoff)
		sys->sleep(10);
	msgoff = now() + int (2000.0*adelay) + 1;
	msg = s;
	# Snd(74), silenced by DrawIt when 3/2*JIFFY_FREQ*delay remains
	if(have_tone)
		tone->beep(sndfreq(74), int (500.0*adelay) + 1);
}

turnnew()
{
	for(j := 0; j < 2; j++)
		for(i := 0; i < UNITSNUM; i++){
			u := units[j][i];
			u.remaining_movement = u.movement;
			u.fired = 0;
		}
	phase = PHASESTART;
	moving_unit = nil;
	turn++;
	banner(sys->sprint("Turn %d", turn));
	vrsetup(0);
	vrsetup(1);
	visrecalc(VRALL, nil);
	cur_player = (turn&1)^1;
	enemy_player = cur_player^1;
}

phasenew()
{
	cur_player ^= 1;
	enemy_player = cur_player^1;
	if(++phase >= PHASEEND){
		indirectresolveall();
		turnnew();
	}
	pg := phase & ~1;
	if(pg == PHASEINDIRECT)
		banner(sys->sprint("Player %d Artillery Plot", cur_player+1));
	else if(pg == PHASEMOVE)
		banner(sys->sprint("Player %d Move", cur_player+1));
	else
		banner(sys->sprint("Player %d Fire", cur_player+1));
}

# ---- key handling (CharDo) ----

chardo(k: int): int
{
	case k {
	Keyboard->Esc or 'q' or 'Q' =>
		return SExitGame;
	' ' =>
		return SPhaseOvr;
	'\n' =>
		return SNewGame;
	'1' =>
		viewplayerset(0);
	'2' =>
		viewplayerset(1);
	'c' or 'C' =>
		logview();
	'd' or 'D' =>
		delaydialog();
	's' or 'S' =>
		show_vis = !show_vis;
		show_vis_row = -1;
		show_vis_col = -1;
	}
	return 0;
}

logview()
{
	mode = Mlog;
	logscroll = 0;
	for(;;) alt{
	k := <-kbdch =>
		case k {
		Keyboard->Esc or 'c' or 'C' or 'q' =>
			mode = Mgame;
			return;
		Keyboard->Up =>
			logscroll++;
		Keyboard->Down =>
			if(--logscroll < 0)
				logscroll = 0;
		Keyboard->Pgup =>
			logscroll += 16;
		Keyboard->Pgdown =>
			logscroll -= 16;
			if(logscroll < 0)
				logscroll = 0;
		}
	pt := <-ptrch =>
		(nil, nil, nil) = pt;
	}
}

delaybar(): Rect
{
	w := 720;
	h := 560;
	img := win.image;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	return Rect(((w-320)/2, h/2-8), ((w-320)/2+320, h/2+8));
}

delaydialog()
{
	# the original pops PopUpRangeF64(0,100,...): a percent slider
	mode = Mdelay;
	for(;;) alt{
	k := <-kbdch =>
		case k {
		Keyboard->Esc or '\n' or 'd' or 'D' =>
			mode = Mgame;
			return;
		}
	pt := <-ptrch =>
		(t, x, nil) := pt;
		if(t == Mldown || t == Mlup){
			br := delaybar();
			frac := real(x - br.min.x)/real br.dx();
			if(frac < 0.0)
				frac = 0.0;
			if(frac > 1.0)
				frac = 1.0;
			adelay = frac;
		}
	}
}

seedprompt()
{
	dflt := now() & 16r7FFFFFFF;
	seedbuf = sys->sprint("%x", dflt);
	mode = Mseed;
	done := 0;
	while(!done) alt{
	k := <-kbdch =>
		case k {
		'\n' or Keyboard->Esc =>
			done = 1;
		'\b' =>
			if(len seedbuf > 0)
				seedbuf = seedbuf[0:len seedbuf-1];
		'0' to '9' or 'a' to 'f' or 'A' to 'F' =>
			if(len seedbuf < 8)
				seedbuf += sys->sprint("%c", k);
		}
	pt := <-ptrch =>
		(nil, nil, nil) = pt;
	}
	seed := 0;
	any := 0;
	for(i := 0; i < len seedbuf; i++){
		c := seedbuf[i];
		v := -1;
		if(c >= '0' && c <= '9')
			v = c - '0';
		else if(c >= 'a' && c <= 'f')
			v = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F')
			v = c - 'A' + 10;
		if(v >= 0){
			seed = seed*16 + v;
			any = 1;
		}
	}
	if(!any)
		seed = dflt;
	rand->init(seed);
	logline(BLACK, sys->sprint("GameSeed(0x%x)", seed));
	mode = Mgame;
}

pickplayers()
{
	# PlayerPick: the original lists AIs/*.HC plus ~/ToTheFront/*.HC;
	# here the two stock controllers are offered (see GAP header).
	for(p := 0; p < 2; p++){
		pickplayer = p;
		mode = Mpick;
		done := 0;
		while(!done) alt{
		k := <-kbdch =>
			case k {
			'h' or 'H' =>
				playerctl[p] = CTLHUMAN;
				done = 1;
			'a' or 'A' or 's' or 'S' =>
				playerctl[p] = CTLAI;
				done = 1;
			}
		pt := <-ptrch =>
			(t, x, y) := pt;
			if(t == Mlup && x >= 40 && x < 280){
				if(y >= 80 && y < 96){
					playerctl[p] = CTLHUMAN;
					done = 1;
				}else if(y >= 104 && y < 120){
					playerctl[p] = CTLAI;
					done = 1;
				}
			}
		}
	}
	mode = Mgame;
}

helpscreen()
{
	mode = Mhelp;
	for(;;) alt{
	k := <-kbdch =>
		(nil) = k;
		mode = Mgame;
		return;
	pt := <-ptrch =>
		(t, nil, nil) := pt;
		if(t == Mlup){
			mode = Mgame;
			return;
		}
	}
}

# ---- human controller (AIs/Human.HC) ----

getmsg(): (int, int, int, int)
{
	for(;;) alt{
	k := <-kbdch =>
		s := chardo(k);
		if(s != Snone)
			return (s, -1, 0, 0);
	pt := <-ptrch =>
		(t, x, y) := pt;
		return (Snone, t, x, y);
	}
}

h_indirect(): int
{
	viewplayerset(cur_player);
	sel: ref Unit;
	remaining := 0;
	for(i := 0; i < UNITSNUM; i++){
		u := units[cur_player][i];
		if(u.life > 0 && u.indirect_fire)
			remaining++;
	}
	while(remaining > 0){
		if(alive[0] == 0 || alive[1] == 0)
			return SGameOver;
		(s, t, wx, wy) := getmsg();
		if(s != Snone)
			return s;
		case t {
		Mldown =>
			cursorupd(wx, wy);
			sel = unitfind(cursor_row, cursor_col);
			if(sel != nil){
				if(sel.player == enemy_player || sel.fired ||
				    !sel.indirect_fire)
					sel = nil;
				else{
					(fire_radius_x, fire_radius_y) =
						rc2xy(sel.row, sel.col);
					fire_radius = real sel.rng*2.0*hexradius;
				}
			}
		Mlup =>
			cursorupd(wx, wy);
			(tx, ty) := rc2xy(cursor_row, cursor_col);
			if(sel == nil)
				beep();
			else{
				if(math->sqrt(sq(fire_radius_x-tx) +
				    sq(fire_radius_y-ty)) > fire_radius)
					beep();
				else{
					indirectadd(sel, cursor_row, cursor_col);
					remaining--;
				}
			}
			sel = nil;
			fire_radius = 0.0;
		Mrup =>
			return SPhaseOvr;
		}
	}
	return SPhaseOvr;
}

h_move(): int
{
	viewplayerset(cur_player);
	sel: ref Unit;
	for(;;){
		if(alive[0] == 0 || alive[1] == 0)
			return SGameOver;
		(s, t, wx, wy) := getmsg();
		if(s != Snone)
			return s;
		case t {
		Mldown =>
			cursorupd(wx, wy);
			sel = unitfind(cursor_row, cursor_col);
			if(sel != nil && (sel.player == enemy_player ||
			    !sel.remaining_movement))
				sel = nil;
		Mlup =>
			cursorupd(wx, wy);
			if(sel == nil)
				beep();
			else{
				# the original keeps the unit selected after a move
				unitmove(sel, real(wx-x0), real(wy-y0));
			}
		Mrup =>
			return SPhaseOvr;
		}
	}
}

h_direct(): int
{
	viewplayerset(cur_player);
	sel: ref Unit;
	for(;;){
		if(alive[0] == 0 || alive[1] == 0)
			return SGameOver;
		(s, t, wx, wy) := getmsg();
		if(s != Snone)
			return s;
		case t {
		Mldown =>
			cursorupd(wx, wy);
			sel = unitfind(cursor_row, cursor_col);
			if(sel != nil){
				if(sel.player == enemy_player || sel.fired ||
				    sel.indirect_fire)
					sel = nil;
				else{
					vrsetup(cur_player);
					(fire_radius_x, fire_radius_y) =
						rc2xy(sel.row, sel.col);
					fire_radius = real sel.rng*2.0*hexradius;
					visrecalc(VRONEFRIENDLY, sel);
				}
			}
		Mlup =>
			cursorupd(wx, wy);
			target := unitfind(cursor_row, cursor_col);
			if(sel == nil)
				beep();
			else{
				# original checks vis[0] here; vis[cur_player]
				# is the evident intent
				if(target == nil || target.player != enemy_player ||
				    !target.vis[cur_player])
					beep();
				else
					unitdirectfire(sel, target);
				visrecalc(VRUPDATE, sel);
			}
			sel = nil;
			fire_radius = 0.0;
		Mrup =>
			return SPhaseOvr;
		}
	}
}

# ---- stock AI (AIs/SimpleAI.HC) ----

userchk(): int
{
	if(alive[0] == 0 || alive[1] == 0)
		return SGameOver;
	for(;;){
		got := 0;
		sig := Snone;
		alt{
		k := <-kbdch =>
			got = 1;
			sig = chardo(k);
		pt := <-ptrch =>
			got = 1;
			(nil, nil, nil) = pt;
		* =>
			;
		}
		if(sig != Snone)
			return sig;
		if(!got)
			break;
	}
	return Snone;
}

unitnearestfind(row, col, player, inlos: int, rangepx: real): ref Unit
{
	best: ref Unit;
	bestdd := 0.0;
	first := 1;
	rr := 0.0;
	unlimited := 0;
	if(rangepx < 0.0)
		unlimited = 1;
	else
		rr = rangepx*rangepx;
	(x1, y1) := rc2xy(row, col);
	for(i := 0; i < UNITSNUM; i++){
		u := units[player][i];
		if(u.life <= 0)
			continue;
		if(inlos && !los(row, col, u.row, u.col))
			continue;
		(x2, y2) := rc2xy(u.row, u.col);
		dd := sq(x2-x1) + sq(y2-y1);
		if((unlimited || dd <= rr) && (first || dd < bestdd)){
			best = u;
			bestdd = dd;
			first = 0;
		}
	}
	return best;
}

ai_indirect(): int
{
	for(i := 0; i < UNITSNUM; i++){
		s := userchk();
		if(s != Snone)
			return s;
		u := units[cur_player][i];
		if(u.life > 0 && u.indirect_fire){
			target := unitnearestfind(u.row, u.col, enemy_player, 1,
				real u.rng*2.0*hexradius);
			if(target != nil)
				indirectadd(u, target.row, target.col);
		}
	}
	return SPhaseOvr;
}

ai_move(): int
{
	for(i := 0; i < UNITSNUM; i++){
		s := userchk();
		if(s != Snone)
			return s;
		u := units[cur_player][i];
		if(u.life <= 0)
			continue;
		# Cheats because it violates Line-of-Sight (original comment)
		target := unitnearestfind(u.row, u.col, enemy_player, 0, -1.0);
		if(target != nil){
			(x, y) := rc2xy(target.row, target.col);
			if(!unitmove(u, x, y)){
				(x, y) = rc2xy(u.row, u.col);
				unitmove(u, x + real(rand->rand(65536)-32768),
					y + real(rand->rand(65536)-32768));
			}
		}
	}
	return SPhaseOvr;
}

ai_direct(): int
{
	for(i := 0; i < UNITSNUM; i++){
		s := userchk();
		if(s != Snone)
			return s;
		u := units[cur_player][i];
		if(u.life > 0 && !u.indirect_fire){
			target := unitnearestfind(u.row, u.col, enemy_player, 1,
				real u.rng*2.0*hexradius);
			if(target != nil){
				unitdirectfire(u, target);
				msleep(250.0*adelay);
			}
		}
	}
	return SPhaseOvr;
}

# ---- engine ----

initgame()
{
	logclear();
	moving_unit = nil;
	moving = 0;
	firing = 0;
	target_unit = nil;
	indirect_explosion = 0;
	seedprompt();
	initmap();
	viewplayerset(cur_player = 0);
	enemy_player = 1;
	initunits();
	orders = nil;
	turn = 0;
	fire_radius = 0.0;
	show_vis = 0;
	show_vis_row = -1;
	show_vis_col = -1;
	msg = "";
	msgoff = 0;
	phase = PHASEEND;
}

phasedo(): int
{
	phasenew();
	s: int;
	pg := phase & ~1;
	if(playerctl[cur_player] == CTLHUMAN){
		if(pg == PHASEINDIRECT)
			s = h_indirect();
		else if(pg == PHASEMOVE)
			s = h_move();
		else
			s = h_direct();
	}else{
		if(pg == PHASEINDIRECT)
			s = ai_indirect();
		else if(pg == PHASEMOVE)
			s = ai_move();
		else
			s = ai_direct();
	}
	if(s == SPhaseOvr)
		s = Snone;
	return s;
}

gameoverloop(): int
{
	msg = "Game Over";
	msgoff = 0;
	sndoff();
	for(;;){
		k := <-kbdch;
		case k {
		'\n' =>
			return SNewGame;
		Keyboard->Esc or 'q' or 'Q' =>
			return SExitGame;
		'1' =>
			viewplayerset(0);
		'2' =>
			viewplayerset(1);
		'c' or 'C' =>
			logview();
		'd' or 'D' =>
			delaydialog();
		}
	}
}

engine()
{
	first := 1;
	s := Snone;
	for(;;){
		initgame();
		if(first){
			pickplayers();
			helpscreen();
			first = 0;
		}
		for(;;){
			s = phasedo();
			if(s == SGameOver)
				s = gameoverloop();
			if(s == SNewGame || s == SExitGame)
				break;
		}
		if(s == SExitGame)
			break;
	}
	quitch <-= 1;
}

# ---- drawing (TTFDraw.HC) ----

tintof(t, c: int): ref Image
{
	if(spr[t] == nil)
		return nil;
	i := t*16 + c;
	if(tints[i] == nil)
		tints[i] = display.newimage(spr[t].r, Draw->RGBA32, 0, palette[c]);
	return tints[i];
}

text8(img: ref Image, x, y, c: int, s: string)
{
	if(tfont == nil)
		return;
	img.text(Point(x, y), ink[c], Point(0, 0), tfont, s);
}

textw(s: string): int
{
	if(tfont == nil)
		return FONTW*len s;
	return tfont.width(s);
}

drawunit(img: ref Image, o: Point, u: ref Unit, mx, my: int, frad: real, c: int)
{
	px := o.x + x0 + mx;
	py := o.y + y0 + my;
	t := u.typ;
	if(u.infantry){
		# Sprite3: colorless art tinted by dc->color
		if(spr[t] != nil && sprmask[t] != nil)
			img.draw(spr[t].r.addpt(Point(px, py)), ink[c],
				sprmask[t], spr[t].r.min);
		else
			img.fillellipse(Point(px, py), 4, 4, ink[c], Point(0, 0));
	}else{
		# Sprite3ZB: rotated to facing
		deg := frad*180.0/Math->Pi;
		ti := tintof(t, c);
		if(ti != nil && sprmask[t] != nil){
			r := spr[t].r;
			cx := real(r.min.x + r.max.x)/2.0;
			cy := real(r.min.y + r.max.y)/2.0;
			cs := math->cos(frad);
			sn := math->sin(frad);
			rx := cx*cs - cy*sn;
			ry := cx*sn + cy*cs;
			draw3d->sprite2d(img, Point(px + int rx, py + int ry),
				ti, sprmask[t], 0, 0, deg, 0);
		}else
			img.fillellipse(Point(px, py), 5, 4, ink[c], Point(0, 0));
	}
	if((phase & ~1) == PHASEINDIRECT && u.indirect_fire && !u.fired &&
	    u.player == cur_player){
		cc := CYAN;
		if(cur_player)
			cc = PURPLE;
		t4 := 4.0*ts();
		r1 := int (20.0*saw(t4, 2.0));
		r2 := int (20.0*saw(t4+1.0, 2.0));
		if(r1 > 0)
			img.ellipse(Point(px, py), r1, r1, 1, ink[cc], Point(0, 0));
		if(r2 > 0)
			img.ellipse(Point(px, py), r2, r2, 1, ink[cc], Point(0, 0));
	}
}

drawunits(img: ref Image, o: Point)
{
	pg := phase & ~1;
	for(j := 0; j < 2; j++)
		for(i := 0; i < UNITSNUM; i++){
			u := units[j][i];
			if(u == nil)
				continue;
			c: int;
			if(u == target_unit){
				if(target_hit)
					c = RED;
				else
					c = GREEN;
			}else if(j)
				c = LTPURPLE;
			else
				c = LTCYAN;
			if(u.life > 0 && u.vis[view_player] && u != moving_unit){
				pending := 0;
				if(pg == PHASEMOVE && u.remaining_movement)
					pending = 1;
				if(((pg == PHASEINDIRECT && u.indirect_fire) ||
				    (pg == PHASEDIRECT && !u.indirect_fire)) && !u.fired)
					pending = 1;
				if(pending || blink(5.0)){
					(x, y) := rc2xy(u.row, u.col);
					drawunit(img, o, u, int x, int y,
						real u.facing*60.0*Math->Pi/180.0, c);
				}
			}
		}
}

rebuildcursorhl()
{
	curhlrow = cursor_row;
	curhlcol = cursor_col;
	curhl = nil;
	if(canvas == nil)
		return;
	(xr, yr) := rc2xy(cursor_row, cursor_col);
	cx := int xr;
	cy := int yr;
	B: con 26;
	W: con 2*B + 1;
	c := terrain[cursor_row][cursor_col];
	seen := array[W*W] of { * => byte 0 };
	stack := array[W*W] of int;
	sp := 0;
	# the original's multiple seeds: roads bisect the hex interior
	half := int ((HEXSIDE + DCOS)/2.0);
	half2 := int (HEXSIDE/2.0);
	for(i := -half; i <= half; i++){
		if(cget(cx+i, cy) == c && seen[(B)*W + (B+i)] == byte 0){
			seen[(B)*W + (B+i)] = byte 1;
			stack[sp++] = (B)*W + (B+i);
		}
		for(j := -half2; j <= half2; j++)
			if(cget(cx+j, cy+i) == c && i >= -B && i <= B &&
			    seen[(B+i)*W + (B+j)] == byte 0){
				seen[(B+i)*W + (B+j)] = byte 1;
				stack[sp++] = (B+i)*W + (B+j);
			}
	}
	while(sp > 0){
		pos := stack[--sp];
		lx := pos % W;
		ly := pos / W;
		for(k := 0; k < 4; k++){
			nx := lx;
			ny := ly;
			case k {
			0 =>	nx++;
			1 =>	nx--;
			2 =>	ny++;
			3 =>	ny--;
			}
			if(nx < 0 || nx >= W || ny < 0 || ny >= W)
				continue;
			if(seen[ny*W + nx] != byte 0)
				continue;
			if(cget(cx-B+nx, cy-B+ny) != c)
				continue;
			seen[ny*W + nx] = byte 1;
			if(sp < len stack)
				stack[sp++] = ny*W + nx;
		}
	}
	bpl := (W+7)/8;
	bits := array[bpl*W] of { * => byte 0 };
	for(ly := 0; ly < W; ly++)
		for(lx := 0; lx < W; lx++)
			if(seen[ly*W + lx] != byte 0)
				bits[ly*bpl + (lx>>3)] |= byte (16r80 >> (lx&7));
	m := display.newimage(Rect((0, 0), (W, W)), Draw->GREY1, 0, 0);
	if(m == nil)
		return;
	m.writepixels(m.r, bits);
	curhl = m;
	curhlr = Rect((cx-B, cy-B), (cx+B+1, cy+B+1));
}

drawgame(img: ref Image)
{
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	img.draw(img.r, ink[WHITE], nil, Point(0, 0));

	# recenter on live resize
	if(mapready && mapimg != nil){
		x0 = (w - mapw)/2;
		if(x0 < 0)
			x0 = 0;
		y0 = FONTH + (h - FONTH - maph)/2;
		if(y0 < FONTH)
			y0 = FONTH;
		img.draw(Rect((o.x+x0, o.y+y0), (o.x+x0+mapw, o.y+y0+maph)),
			mapimg, nil, mapimg.r.min);
	}

	if(!mapready){
		img.flush(Draw->Flushnow);
		return;
	}
	cursorupd(lastmx, lastmy);

	# YELLOW flood-filled cursor hex
	if(maprows > 0){
		if(curhlrow != cursor_row || curhlcol != cursor_col)
			rebuildcursorhl();
		if(curhl != nil)
			img.draw(curhlr.addpt(Point(o.x+x0, o.y+y0)), ink[YELLOW],
				curhl, Point(0, 0));
	}

	drawunits(img, o);

	if(firing)
		img.ellipse(Point(o.x+x0+fire_x, o.y+y0+fire_y), 2, 2, 0,
			ink[BLACK], Point(0, 0));

	if(indirect_explosion){
		for(i := 0; i < 7; i++){
			c: int;
			if(indirect_row & 1)
				c = indirect_col + coloffo[i];
			else
				c = indirect_col + coloffe[i];
			r := indirect_row + rowoff[i];
			if(0 <= r && r < maprows && 0 <= c && c < mapcols){
				(x, y) := rc2xy(r, c);
				for(j := 0; j < 10; j++){
					cc := YELLOW;
					if(j & 1)
						cc = LTRED;
					img.ellipse(Point(
						o.x+x0+int x+rand->rand(11)-5,
						o.y+y0+int y+rand->rand(11)-5),
						2, 2, 0, ink[cc], Point(0, 0));
				}
			}
		}
	}

	mu := moving_unit;
	if(mu != nil && mu.vis[view_player])
		drawunit(img, o, mu, move_x, move_y, move_facing, YELLOW);

	# remaining-movement progress bar, dodging the mouse
	if(mu != nil && mu.movement > 0){
		bw := 200;
		bx := o.x + (w-bw)/2;
		by := o.y + h - 12;
		if(lastmy >= h/2)
			by = o.y + FONTH + 2;
		fillw := bw*mu.remaining_movement/mu.movement;
		fillw = clampi(fillw, 0, bw);
		img.draw(Rect((bx, by), (bx+bw, by+8)), ink[BLACK], nil, Point(0, 0));
		if(fillw > 0)
			img.draw(Rect((bx+1, by+1), (bx+fillw-1, by+7)),
				ink[LTGREEN], nil, Point(0, 0));
	}

	if(fire_radius > 0.0){
		fc := Point(o.x+x0+int fire_radius_x, o.y+y0+int fire_radius_y);
		fr := int fire_radius;
		img.ellipse(fc, fr-1, fr-1, 0, ink[YELLOW], Point(0, 0));
		img.ellipse(fc, fr+1, fr+1, 0, ink[YELLOW], Point(0, 0));
		img.ellipse(fc, fr, fr, 0, ink[RED], Point(0, 0));
	}

	# blinking artillery-plot target markers
	if(blink(10.0)){
		for(ol := orders; ol != nil; ol = tl ol){
			ord := hd ol;
			if(ord.u.player == view_player){
				(x, y) := rc2xy(ord.row, ord.col);
				p := Point(o.x+x0+int x, o.y+y0+int y);
				if(marker != nil && markermask != nil)
					img.draw(marker.r.addpt(p), marker,
						markermask, marker.r.min);
				else
					img.ellipse(p, 7, 7, 0, ink[RED], Point(0, 0));
			}
		}
	}

	# line-of-sight overlay ('s'; SHIFT in the original)
	if(show_vis && maprows > 0){
		if(show_vis_row != cursor_row || show_vis_col != cursor_col){
			show_vis_row = cursor_row;
			show_vis_col = cursor_col;
			visrecalcmap(show_vis_row, show_vis_col);
		}
		for(j := 0; j < maprows; j++)
			for(i := 0; i < mapcols; i++)
				if(!vismap[j][i]){
					(xr, yr) := rc2xy(j, i);
					x := o.x+x0+int xr;
					y := o.y+y0+int yr;
					img.line(Point(x-6, y-6), Point(x+6, y+6),
						0, 0, 0, ink[LTGRAY], Point(0, 0));
					img.line(Point(x+6, y-6), Point(x-6, y+6),
						0, 0, 0, ink[LTGRAY], Point(0, 0));
					img.line(Point(x, y-6), Point(x, y+6),
						0, 0, 0, ink[LTGRAY], Point(0, 0));
					img.line(Point(x+6, y), Point(x-6, y),
						0, 0, 0, ink[LTGRAY], Point(0, 0));
				}
	}

	# boxed centre-screen banner
	if(msgoff > 0 && now() > msgoff)
		msg = "";
	if(msg != ""){
		i := textw(msg);
		bx := o.x + (w-i)/2;
		by := o.y + (h-FONTH)/2;
		img.draw(Rect((bx-10, by-10), (bx+i+10, by+FONTH+10)),
			ink[BLACK], nil, Point(0, 0));
		img.draw(Rect((bx-7, by-7), (bx+i+7, by+FONTH+7)),
			ink[YELLOW], nil, Point(0, 0));
		text8(img, bx, by, RED, msg);
	}

	# HUD
	img.draw(Rect((o.x, o.y), (o.x+(13+7+10+10)*FONTW, o.y+FONTH)),
		ink[WHITE], nil, Point(0, 0));
	pg := phase & ~1;
	buf: string;
	if(pg == PHASEINDIRECT)
		buf = sys->sprint("Turn:%2d Artillery", turn);
	else if(pg == PHASEMOVE)
		buf = sys->sprint("Turn:%2d Move", turn);
	else
		buf = sys->sprint("Turn:%2d Fire", turn);
	text8(img, o.x, o.y, BLACK, buf);
	c1 := LTCYAN;
	if(cur_player || blink(2.5))
		c1 = CYAN;
	text8(img, o.x+(13+7)*FONTW, o.y, c1,
		sys->sprint("%3d Units", alive[0]));
	c2 := LTPURPLE;
	if(!cur_player || blink(2.5))
		c2 = PURPLE;
	text8(img, o.x+(13+7+10)*FONTW, o.y, c2,
		sys->sprint("%3d Units", alive[1]));
}

drawlog(img: ref Image)
{
	o := img.r.min;
	h := img.r.dy();
	img.draw(img.r, ink[WHITE], nil, Point(0, 0));
	text8(img, o.x+4, o.y+2, GREEN, "<Esc> to return to game.");
	nfit := (h - FONTH - 6)/FONTH;
	if(nfit < 1)
		nfit = 1;
	navail := logn;
	if(navail > LOGMAX)
		navail = LOGMAX;
	maxscroll := navail - nfit;
	if(maxscroll < 0)
		maxscroll = 0;
	if(logscroll > maxscroll)
		logscroll = maxscroll;
	last := logn - logscroll;
	first := last - nfit;
	if(first < logn - navail)
		first = logn - navail;
	y := o.y + FONTH + 4;
	for(k := first; k < last; k++){
		if(k < 0)
			continue;
		x := o.x + 4;
		for(segs := loglines[k % LOGMAX]; segs != nil; segs = tl segs){
			(c, s) := hd segs;
			text8(img, x, y, c, s);
			x += textw(s);
		}
		y += FONTH;
	}
}

drawpick(img: ref Image)
{
	o := img.r.min;
	img.draw(img.r, ink[WHITE], nil, Point(0, 0));
	text8(img, o.x+40, o.y+40, BLACK,
		sys->sprint("Player %d Type", pickplayer+1));
	c1 := LTBLUE;
	c2 := LTBLUE;
	if(playerctl[pickplayer] == CTLHUMAN)
		c1 = BLUE;
	else
		c2 = BLUE;
	text8(img, o.x+40, o.y+80, c1, "Human      (h)");
	text8(img, o.x+40, o.y+104, c2, "SimpleAI   (a)");
	text8(img, o.x+40, o.y+152, DKGRAY,
		"The original loads user AIs from ~/ToTheFront;");
	text8(img, o.x+40, o.y+160, DKGRAY,
		"only the stock controllers are available here.");
}

drawseed(img: ref Image)
{
	o := img.r.min;
	img.draw(img.r, ink[WHITE], nil, Point(0, 0));
	text8(img, o.x+40, o.y+40, BLACK,
		sys->sprint("GameSeed(0x%s_)", seedbuf));
	text8(img, o.x+40, o.y+56, DKGRAY,
		"hex digits; <Enter> to accept");
}

drawdelay(img: ref Image)
{
	o := img.r.min;
	img.draw(img.r, ink[WHITE], nil, Point(0, 0));
	br := delaybar().addpt(o);
	text8(img, br.min.x, br.min.y-16, BLACK, "Animation Delay");
	img.draw(br, ink[LTGRAY], nil, Point(0, 0));
	fillw := int (real br.dx()*adelay);
	if(fillw > 0)
		img.draw(Rect(br.min, (br.min.x+fillw, br.max.y)),
			ink[RED], nil, Point(0, 0));
	text8(img, br.min.x, br.max.y+8, BLACK,
		sys->sprint("%3d %%  (click; <Enter> done)", int (adelay*100.0)));
}

drawhelp(img: ref Image)
{
	o := img.r.min;
	img.draw(img.r, ink[WHITE], nil, Point(0, 0));
	x := o.x + 40;
	y := o.y + 40;
	text8(img, x, y, PURPLE, "ToTheFront");
	y += 2*FONTH;
	lines := array[] of {
	(GREEN, "{Left-click}", " to move or fire units."),
	(GREEN, "<SPACE>", " or {Right-click} to end phase."),
	(GREEN, "s", "       to toggle line-of-sight."),
	(GREEN, "<ENTER>", " to start new game."),
	(GREEN, "1", "       Player 1 view."),
	(GREEN, "2", "       Player 2 view."),
	(GREEN, "c", "       View odds calculations."),
	(GREEN, "d", "       Set animation delay.")
	};
	for(i := 0; i < len lines; i++){
		(c, key, rest) := lines[i];
		text8(img, x, y, c, key);
		text8(img, x+textw(key), y, BLACK, rest);
		y += FONTH+2;
	}
	y += FONTH;
	text8(img, x, y, DKGRAY, "any key to begin");
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	case mode {
	Mlog =>
		drawlog(img);
	Mpick =>
		drawpick(img);
	Mseed =>
		drawseed(img);
	Mdelay =>
		drawdelay(img);
	Mhelp =>
		drawhelp(img);
	* =>
		drawgame(img);
	}
	img.flush(Draw->Flushnow);
}
