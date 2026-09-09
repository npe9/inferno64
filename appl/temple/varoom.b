implement Varoom;

# TempleOS Demo/Games/Varoom.HC — pseudo-3D road racing
# arrows/wasd steer+accelerate; Enter/r restart; Esc/q quit
#
# Faithful rebuild of the original renderer: the road course is composed
# of straight runs and 180/90-degree arcs (InitTrack), undulated by
# DipY/Dip (DIPS=5, DIP_DEPTH=50), and drawn behind the car by projecting
# every track slice's center/left/right quads through the original
# PrepPoly camera (RotY by -heading, RotX 75 degrees minus dip,
# s=100/(|z|+50)).  512 bushes (vector sprites 1-4) and the 7 opponent
# cars (mesh sprite 6) are projected the same way; the player's own car
# (mesh sprite 5) is drawn through the original VRTransform perspective.
# Minimap track_map (MAP_BITS=9 downscale, LTGRAY/YELLOW, live car dots),
# LTCYAN sky band, horizon sun, and the GrPrint HUD are all reproduced.
#
# GAP: TempleOS MenuPush menu bar omitted (no equivalent); keys are in varoom(1)
# GAP: GrFillPoly3's per-pixel depth buffer approximated with a painter's-
#      algorithm sort; the multi-CPU JobQue fan-out is single-threaded.
#      This one was measured before it was accepted.  math/polyfill has a
#      real per-pixel z-buffer and math/draw3d's fillpoly3 drives it, and
#      it is what 3dpoly, zoneout and wenceslas use — but it is
#      interpreted Limbo where Image.fillpoly is a native draw call.  On
#      a synthetic frame of 200 quads and 300 triangles, well under this
#      game's load, the z-buffered fill costs 7.18ms a frame against
#      0.07ms for the plain one, a hundred times over, with another
#      0.68ms a frame just to clear a 640x480 depth buffer.  A racing
#      game cannot pay that, so the sort stays.
#      What the sort actually loses is narrow.  The original gives every
#      sprite one depth (Sprite3B with z+GR_Z_ALL, and GR_Z_ALL is only
#      I32_MAX/2, a bias to keep z positive), so for whole objects a
#      back-to-front sort by that same depth agrees with the depth buffer
#      exactly.  It differs in two places: where a track polygon's
#      interpolated depth crosses a sprite's single depth — a bush
#      standing on the road, whose base should be cut by nearer tarmac
#      and whose top should not — and between the triangles of one car
#      mesh, which are sorted by centroid here and resolved per pixel
#      there.
# GAP: Noise(500,22,34) approximated by rapid random snd() steps

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "rand.m";
	rand: Rand;

include "tone.m";
	tone: Tone;

include "scorestore.m";
	scorestore: Scorestore;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Varoom: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;

# original constants
BORDER: con 7500.0;
RADIUS: con 10000.0;
WIDTH: con 2000.0;
SHOULDER: con 200.0;
D_: con 2.0*PI/360.0;		# curve track slice is one degree
D_S: con 2.0*PI*RADIUS/360.0;	# straight track is a degree at 10000
DIPS: con 5.0;
DIP_DEPTH: con 50.0;
CAR_LENGTH: con 400.0;
CARS_NUM: con 8;
BUSHES_NUM: con 512;
MAP_BITS: con 9;
HORIZON_DIP: con 200.0;
FONT_WIDTH := 8;			# the font's digit advance, set when the font opens
FONT_HEIGHT := 8;			# the font's line height, set when the font opens

MAXSLICES: con 1400;

# TempleOS 16-color palette
BLACK, BLUE, GREEN, CYAN, RED, PURPLE, BROWN, LTGRAY,
DKGRAY, LTBLUE, LTGREEN, LTCYAN, LTRED, LTPURPLE, YELLOW, WHITE: con iota;

Slice: adt {
	num: int;		# 1-based
	col: int;		# shoulder color: RED or WHITE
	x, z, ang, d: real;
	ctr, lft, rgt: array of real;	# 4 corners x,y,z
};

Car: adt {
	x, y, z: real;
	ang, d, speed: real;	# heading, steering-wheel angle, speed
	ti: int;		# nearest track slice
};

El: adt {
	kind: int;		# 0 line, 1 circle
	col, thk: int;
	x1, y1, x2, y2: int;	# circle: x1,y1 center, x2 radius
};

win: ref Window;
disp: ref Display;
ink: array of ref Image;
tfont: ref Font;

slices: array of ref Slice;
nsl := 0;
totald := 0.0;
t_minx, t_maxx, t_minz, t_maxz: real;
bx, bz, bang: real;		# track build cursor

mapgrid: array of byte;
mapimg: ref Image;
mw, mh: int;

Bush: adt {
	x, y, z: real;
	sym: int;
	img: int;	# index into sprelems
};
bushes: array of Bush;
sprelems: array of array of El;		# vector elements of bush sprites 1-4
bushimg := array[] of {0, 0, 1, 1, 2, 3, 3, 3};	# original imgs[8] pattern

cars: array of Car;
distance := 0.0;
game_over := 0;
won := 0;
on_track := 0;
t0, tf: real;
best_score := 9999.0;
have_tone := 0;
last_snd := 0;
noise_until := 0;
freeze_until := 0;
rec_beep_at := 0;
last_ms := 0;

# camera state for the current frame
f_px, f_py, f_pz: real;
f_cy, f_sy, f_ca, f_sa: real;
f_w2, f_ox, f_oy: int;
f_h: real;
spts := array[4] of Point;
scrctr: array of array of Point;	# prepped center quads per slice

# painter's-algorithm work arrays
wkey: array of real;
wval: array of int;	# kind*4096 + index

# car mesh, extracted from the original's DolDoc sprite bins 5/6
# (identical geometry; bin 5 body is CYAN, bin 6 body is PURPLE)
meshverts := array[] of {
	70,-25,125, 45,-25,125, 45,-25,75, 70,-25,75, 55,-3,135, 55,-3,150,
	0,-3,150, 40,-3,135, 40,-3,65, 55,-3,65, 55,-3,0, 0,-3,0, 70,25,125,
	45,25,125, 45,25,75, 70,25,75, 55,3,135, 55,3,150, 0,3,150, 40,3,135,
	40,3,65, 55,3,65, 55,3,0, 0,3,0, -70,-25,125, -45,-25,125, -45,-25,75,
	-70,-25,75, -55,-3,135, -55,-3,150, 0,-3,150, -40,-3,135, -40,-3,65,
	-55,-3,65, -55,-3,0, 0,-3,0, -70,25,125, -45,25,125, -45,25,75, -70,25,75,
	-55,3,135, -55,3,150, 0,3,150, -40,3,135, -40,3,65, -55,3,65, -55,3,0,
	0,3,0, 70,-25,-125, 45,-25,-125, 45,-25,-75, 70,-25,-75, 55,-31,-135,
	55,-31,-150, 0,-31,-150, 40,-31,-135, 40,-31,-65, 55,-31,-65, 55,-3,0,
	0,-3,0, 70,25,-125, 45,25,-125, 45,25,-75, 70,25,-75, 55,3,-135, 55,3,-150,
	0,3,-150, 40,3,-135, 40,3,-65, 55,3,-65, 55,3,0, 0,3,0, -70,-25,-125,
	-45,-25,-125, -45,-25,-75, -70,-25,-75, -55,-31,-135, -55,-31,-150,
	0,-31,-150, -40,-31,-135, -40,-31,-65, -55,-31,-65, -55,-3,0, 0,-3,0,
	-70,25,-125, -45,25,-125, -45,25,-75, -70,25,-75, -55,3,-135, -55,3,-150,
	0,3,-150, -40,3,-135, -40,3,-65, -55,3,-65, -55,3,0, 0,3,0
};
meshtris := array[] of {
	0,12,13,14, 0,14,15,12, 0,1,0,3, 0,3,2,1, 0,1,13,12, 0,12,0,1, 0,12,15,3,
	0,3,0,12, 0,1,13,2, 0,13,14,2, 0,14,2,3, 0,3,15,14, 3,11,10,9, 3,9,8,11,
	3,11,8,6, 3,8,7,6, 3,7,4,5, 3,7,5,6, 3,23,22,21, 3,21,20,23, 3,23,20,18,
	3,20,19,18, 3,19,16,17, 3,19,17,18, 3,4,16,19, 3,19,7,4, 3,4,7,19,
	3,19,16,4, 3,9,21,22, 3,22,10,9, 3,8,7,19, 3,19,20,8, 3,5,17,18, 3,18,6,5,
	0,36,37,38, 0,38,39,36, 0,25,24,27, 0,27,26,25, 0,25,37,36, 0,36,24,25,
	0,36,39,27, 0,27,24,36, 0,25,37,26, 0,37,38,26, 0,38,26,27, 0,27,39,38,
	3,35,33,34, 3,33,35,32, 3,35,30,32, 3,32,30,31, 3,31,29,28, 3,31,30,29,
	3,47,45,46, 3,45,47,44, 3,47,42,44, 3,44,42,43, 3,43,41,40, 3,43,42,41,
	3,28,43,40, 3,43,28,31, 3,28,43,31, 3,43,28,40, 3,33,46,45, 3,46,33,34,
	3,32,43,31, 3,43,32,44, 3,29,42,41, 3,42,29,30, 0,60,61,62, 0,62,63,60,
	0,49,48,51, 0,51,50,49, 0,49,61,60, 0,60,48,49, 0,60,63,51, 0,51,48,60,
	0,49,61,50, 0,61,62,50, 0,62,50,51, 0,51,63,62, 3,59,57,58, 3,57,59,56,
	3,56,54,55, 3,55,53,52, 3,55,54,53, 3,71,69,70, 3,69,71,68, 3,71,66,68,
	3,68,66,67, 3,67,65,64, 3,67,66,65, 3,52,67,64, 3,67,52,55, 3,52,67,55,
	3,67,52,64, 3,57,70,69, 3,70,57,58, 3,56,67,55, 3,67,56,68, 3,53,66,65,
	3,66,53,54, 0,84,85,86, 0,86,87,84, 0,73,72,75, 0,75,74,73, 0,73,85,84,
	0,84,72,73, 0,84,87,75, 0,75,72,84, 0,73,85,74, 0,85,86,74, 0,86,74,75,
	0,75,87,86, 3,83,82,81, 3,81,80,83, 3,80,79,78, 3,79,76,77, 3,79,77,78,
	3,95,94,93, 3,93,92,95, 3,95,92,90, 3,92,91,90, 3,91,88,89, 3,91,89,90,
	3,76,88,91, 3,91,79,76, 3,76,79,91, 3,91,88,76, 3,81,93,94, 3,94,82,81,
	3,80,79,91, 3,91,92,80, 3,77,89,90, 3,90,78,77, 3,11,80,56, 3,56,80,54,
	3,53,52,64, 3,64,65,53, 3,76,77,89, 3,89,88,76
};
NMV: con 96;
NMT: con 140;
mvx := array[NMV] of int;	# transformed mesh scratch
mvy := array[NMV] of int;
mvz := array[NMV] of real;
mkey := array[NMT] of real;
mvalt := array[NMT] of int;
tript := array[3] of Point;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	bufio = load Bufio Bufio->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	scorestore = load Scorestore Scorestore->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Varoom", Wmclient->Appl);
	disp = win.display;
	d := disp;
	ink = array[16] of ref Image;
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
	tfont = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(tfont != nil){
		FONT_WIDTH = tfont.width("0");
		FONT_HEIGHT = tfont.height;
	}
	if(scorestore != nil)
		best_score = scorestore->loadreal("varoom", best_score);

	loadsprites();
	slices = array[MAXSLICES] of ref Slice;
	scrctr = array[MAXSLICES] of array of Point;
	for(i = 0; i < MAXSLICES; i++)
		scrctr[i] = array[4] of Point;
	wkey = array[MAXSLICES + BUSHES_NUM + CARS_NUM] of real;
	wval = array[MAXSLICES + BUSHES_NUM + CARS_NUM] of int;
	bushes = array[BUSHES_NUM] of Bush;
	cars = array[CARS_NUM] of Car;
	game_init();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	last_ms = sys->millisec();
	ticks := chan of int;
	# original: AnimateTask loops Sleep(10) (100Hz, 0.01-per-tick
	# constants) while winmgr redraws at ~30fps.  We tick at 32ms,
	# run the sim in exact 10ms steps by elapsed time, redraw per tick.
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	pointerev := <-win.ctxt.ptr =>
		# The titlebar is drawn by this window and only sees a click
		# if the program hands it one: without this arm the move,
		# resize and menu buttons on the window do nothing at all.
		win.pointer(*pointerev);
	k := <-win.ctxt.kbd =>
		key(k);
	<-ticks =>
		nowms := sys->millisec();
		if(freeze_until != 0 && nowms < freeze_until)
			last_ms = nowms;	# crash: Noise()+Sleep(500) freeze
		else{
			freeze_until = 0;
			el := nowms - last_ms;
			steps := el / 10;
			if(steps > 8){
				steps = 8;
				last_ms = nowms - 80;
			}
			for(si := 0; si < steps; si++)
				simstep();
			last_ms += steps * 10;
		}
		sound(nowms);
		redraw();
	}
}

# --- track ---------------------------------------------------------------

dipy(x, z: real): real
{
	m := math->sqrt(x*x + z*z);
	a := math->atan2(z, x);
	return DIP_DEPTH * m * math->cos(DIPS*a) / RADIUS;
}

dipf(x, z, ang: real): real
{
	yf := dipy(x - CAR_LENGTH/2.0*math->cos(ang), z - CAR_LENGTH/2.0*math->sin(ang));
	yb := dipy(x + CAR_LENGTH/2.0*math->cos(ang), z + CAR_LENGTH/2.0*math->sin(ang));
	return math->asin((yf - yb) / CAR_LENGTH);
}

setpt(q: array of real, i: int, x, z: real)
{
	q[i*3] = x;
	q[i*3+1] = dipy(x, z);
	q[i*3+2] = z;
}

cppt(dst: array of real, di: int, src: array of real, si: int)
{
	dst[di*3] = src[si*3];
	dst[di*3+1] = src[si*3+1];
	dst[di*3+2] = src[si*3+2];
}

minmax(x, z: real)
{
	if(x < t_minx) t_minx = x;
	if(x > t_maxx) t_maxx = x;
	if(z < t_minz) t_minz = z;
	if(z > t_maxz) t_maxz = z;
}

addslice(d: real)
{
	c := math->cos(bang);
	s := math->sin(bang);
	dx := d*s;
	dz := -d*c;

	sl := ref Slice;
	sl.ctr = array[12] of real;
	sl.lft = array[12] of real;
	sl.rgt = array[12] of real;
	if(nsl > 0){
		p := slices[nsl-1];
		cppt(sl.ctr, 0, p.ctr, 3);
		cppt(sl.ctr, 1, p.ctr, 2);
		cppt(sl.lft, 0, p.lft, 3);
		cppt(sl.lft, 1, p.lft, 2);
		cppt(sl.rgt, 0, p.rgt, 3);
		cppt(sl.rgt, 1, p.rgt, 2);
	}
	setpt(sl.ctr, 2, bx + (WIDTH/2.0)*c + dx, bz + (WIDTH/2.0)*s + dz);
	setpt(sl.ctr, 3, bx - (WIDTH/2.0)*c + dx, bz - (WIDTH/2.0)*s + dz);
	setpt(sl.lft, 2, bx - (WIDTH/2.0)*c + dx, bz - (WIDTH/2.0)*s + dz);
	setpt(sl.lft, 3, bx - (WIDTH/2.0+SHOULDER)*c + dx, bz - (WIDTH/2.0+SHOULDER)*s + dz);
	setpt(sl.rgt, 2, bx + (WIDTH/2.0+SHOULDER)*c + dx, bz + (WIDTH/2.0+SHOULDER)*s + dz);
	setpt(sl.rgt, 3, bx + (WIDTH/2.0)*c + dx, bz + (WIDTH/2.0)*s + dz);

	sl.x = bx;
	sl.z = bz;
	sl.ang = bang;
	sl.num = nsl + 1;
	if(nsl > 0)
		sl.d = slices[nsl-1].d + d;
	else
		sl.d = d;
	if(sl.num & 1)
		sl.col = RED;
	else
		sl.col = WHITE;

	minmax(bx, bz);
	bx += dx;
	bz += dz;
	minmax(bx, bz);
	slices[nsl++] = sl;
}

init_track()
{
	nsl = 0;
	t_minx = t_minz = 1e18;
	t_maxx = t_maxz = -1e18;
	bx = 0.0;
	bz = 0.0;
	bang = 0.0;

	# the original course: 6R straight, 180 left, R straight, 90 right,
	# 180 left, 90 right, R straight, 180 left
	for(d := 0.0; d < 6.0*RADIUS; d += D_S)
		addslice(D_S);
	for(i := 0; i < 180; i++){
		addslice(D_*RADIUS);
		bang += D_;
	}
	for(d = 0.0; d < RADIUS; d += D_S)
		addslice(D_S);
	for(i = 0; i < 90; i++){
		addslice(D_*RADIUS);
		bang -= D_;
	}
	for(i = 0; i < 180; i++){
		addslice(D_*RADIUS);
		bang += D_;
	}
	for(i = 0; i < 90; i++){
		addslice(D_*RADIUS);
		bang -= D_;
	}
	for(d = 0.0; d < RADIUS; d += D_S)
		addslice(D_S);
	for(i = 0; i < 180; i++){
		addslice(D_*RADIUS);
		bang += D_;
	}

	# CoupleEnds
	first := slices[0];
	last := slices[nsl-1];
	cppt(first.ctr, 0, last.ctr, 3);
	cppt(first.ctr, 1, last.ctr, 2);
	cppt(first.lft, 0, last.lft, 3);
	cppt(first.lft, 1, last.lft, 2);
	cppt(first.rgt, 0, last.rgt, 3);
	cppt(first.rgt, 1, last.rgt, 2);

	totald = last.d;

	t_minx -= BORDER;
	t_minz -= BORDER;
	t_maxx += BORDER;
	t_maxz += BORDER;
	mw = (int(t_maxx - t_minx) + (1<<MAP_BITS) - 1) >> MAP_BITS;
	mh = (int(t_maxz - t_minz) + (1<<MAP_BITS) - 1) >> MAP_BITS;
	mapgrid = array[mw*mh] of byte;
	for(i = 0; i < mw*mh; i++)
		mapgrid[i] = byte LTGRAY;
	# yellow track dots, thick 3
	for(i = 0; i < nsl; i++){
		mx := mw - (int(slices[i].x - t_minx) >> MAP_BITS);
		mz := int(slices[i].z - t_minz) >> MAP_BITS;
		for(oy := -1; oy <= 1; oy++)
			for(ox := -1; ox <= 1; ox++)
				mapset(mx+ox, mz+oy, YELLOW);
	}
}

mapset(x, z, v: int)
{
	if(x >= 0 && x < mw && z >= 0 && z < mh)
		mapgrid[z*mw + x] = byte v;
}

mappeek(x, z: int): int
{
	if(x >= 0 && x < mw && z >= 0 && z < mh)
		return int mapgrid[z*mw + x];
	return -1;
}

trackfind(start: int, x, z: real): int
{
	best := start;
	dx := slices[best].x - x;
	dz := slices[best].z - z;
	bd := dx*dx + dz*dz;
	i := start;
	for(;;){
		i = (i + 1) % nsl;
		dx = slices[i].x - x;
		dz = slices[i].z - z;
		dd := dx*dx + dz*dz;
		if(dd < bd){
			bd = dd;
			best = i;
		}else
			break;
	}
	i = start;
	for(;;){
		i = (i - 1 + nsl) % nsl;
		dx = slices[i].x - x;
		dz = slices[i].z - z;
		dd := dx*dx + dz*dz;
		if(dd < bd){
			bd = dd;
			best = i;
		}else
			break;
	}
	return best;
}

# --- bushes --------------------------------------------------------------

loadsprites()
{
	sprelems = array[4] of array of El;
	for(i := 0; i < 4; i++)
		sprelems[i] = loadspr(sys->sprint("/lib/temple/sprites/varoom_%d.spr", i+1));
}

loadspr(path: string): array of El
{
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return array[0] of El;
	l: list of El;
	n := 0;
	col := WHITE;
	thk := 1;
	for(;;){
		ln := b.gets('\n');
		if(ln == nil)
			break;
		(nt, toks) := sys->tokenize(ln, " \t\n");
		if(nt < 1)
			continue;
		case hd toks {
		"color" =>
			if(nt >= 2)
				col = int hd tl toks;
		"thick" =>
			if(nt >= 2)
				thk = int hd tl toks;
		"line" =>
			if(nt >= 5){
				t := tl toks;
				e := El(0, col, thk, int hd t, int hd tl t,
					int hd tl tl t, int hd tl tl tl t);
				l = e :: l;
				n++;
			}
		"circle" =>
			if(nt >= 4){
				t := tl toks;
				e := El(1, col, thk, int hd t, int hd tl t,
					int hd tl tl t, 0);
				l = e :: l;
				n++;
			}
		}
	}
	a := array[n] of El;
	for(i := n - 1; i >= 0; i--){
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

frnd(): real
{
	return real rand->rand(1073741824) / 1073741824.0;
}

init_bushes()
{
	for(i := 0; i < BUSHES_NUM; i++){
		x, z: real;
		mx, mz: int;
		tries := 0;
		for(;;){
			x = frnd()*(t_maxx - t_minx) + t_minx;
			z = frnd()*(t_maxz - t_minz) + t_minz;
			mx = mw - (int(x - t_minx) >> MAP_BITS);
			mz = int(z - t_minz) >> MAP_BITS;
			ok := 1;
			for(oy := -1; oy <= 1 && ok; oy++)
				for(ox := -1; ox <= 1; ox++){
					if(ox == 0 && oy == 0)
						continue;
					if(mappeek(mx+ox, mz+oy) != LTGRAY){
						ok = 0;
						break;
					}
				}
			if(ok || tries++ > 10000)
				break;
		}
		mapset(mx, mz, LTGREEN);
		bushes[i].x = x;
		bushes[i].z = z;
		bushes[i].y = dipy(x, z);
		bushes[i].sym = rand->rand(2);
		bushes[i].img = bushimg[i & 7];
	}
}

buildmapimg()
{
	mapimg = disp.newimage(Rect((0, 0), (mw, mh)), Draw->RGB24, 0, Draw->White);
	if(mapimg == nil)
		return;
	# run-length rows
	for(z := 0; z < mh; z++){
		x := 0;
		while(x < mw){
			v := int mapgrid[z*mw + x];
			x2 := x + 1;
			while(x2 < mw && int mapgrid[z*mw + x2] == v)
				x2++;
			mapimg.draw(Rect((x, z), (x2, z+1)), ink[v], nil, Point(0, 0));
			x = x2;
		}
	}
}

# --- game state ----------------------------------------------------------

game_init()
{
	init_track();
	init_bushes();
	buildmapimg();
	ti := 0;
	for(i := 0; i < CARS_NUM; i++){
		sl := slices[ti];
		cars[i].x = sl.x;
		cars[i].z = sl.z;
		cars[i].y = dipy(sl.x, sl.z);
		cars[i].ang = -sl.ang;
		cars[i].d = 0.0;
		cars[i].ti = ti;
		if(i == 0)
			cars[i].speed = 0.0;
		else
			cars[i].speed = 2500.0;
		dt := real(i+1) * totald / real CARS_NUM;
		while(ti < nsl-1 && slices[ti].d < dt)
			ti++;
	}
	distance = 0.0;
	tf = 0.0;
	game_over = 0;
	won = 0;
	on_track = 1;
	noise_until = 0;
	freeze_until = 0;
	rec_beep_at = 0;
	t0 = now();
}

key(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		if(have_tone)
			tone->stop();
		exit;
	'\n' or 'r' or 'R' =>
		if(have_tone)
			tone->stop();
		last_snd = 0;
		game_init();
		last_ms = sys->millisec();
	Keyboard->Left or 'a' or 'A' =>
		cars[0].d -= PI / 60.0;
	Keyboard->Right or 'd' or 'D' =>
		cars[0].d += PI / 60.0;
	Keyboard->Up or 'w' or 'W' =>
		cars[0].speed += 300.0;
	Keyboard->Down or 's' or 'S' =>
		cars[0].speed -= 900.0;
		if(cars[0].speed < 0.0)
			cars[0].speed = 0.0;
	}
}

# one original 10ms AnimateTask tick
simstep()
{
	for(i := 0; i < CARS_NUM; i++){
		cars[i].x -= 0.01 * cars[i].speed * math->cos(cars[i].ang - PI/2.0);
		cars[i].z += 0.01 * cars[i].speed * math->sin(cars[i].ang - PI/2.0);
		ti := trackfind(cars[i].ti, cars[i].x, cars[i].z);
		if(i){
			if(ti != cars[i].ti){
				t2 := slices[(ti + 1) % nsl];
				cars[i].ang = math->atan2(cars[i].x - t2.x, cars[i].z - t2.z);
			}
		}else{
			cars[0].ang += 0.01 * cars[0].d;
			mx := mw - (int(cars[0].x - t_minx) >> MAP_BITS);
			mz := int(cars[0].z - t_minz) >> MAP_BITS;
			if(mappeek(mx, mz) != YELLOW){
				on_track = 0;
				cars[0].speed -= 0.01 * cars[0].speed;
				if(cars[0].speed < 0.0)
					cars[0].speed = 0.0;
			}else
				on_track = 1;
		}
		cars[i].ti = ti;
		cars[i].y = dipy(cars[i].x, cars[i].z);
	}
	if(!game_over && on_track){
		hit := (CAR_LENGTH/2.0) * (CAR_LENGTH/2.0);
		for(i = 1; i < CARS_NUM; i++){
			dx := cars[i].x - cars[0].x;
			dy := cars[i].y - cars[0].y;
			dz := cars[i].z - cars[0].z;
			if(dx*dx + dy*dy + dz*dz < hit){
				game_over = 1;
				won = 0;
				# Noise(500,22,34) then Sleep(500)
				nowms := sys->millisec();
				noise_until = nowms + 500;
				freeze_until = nowms + 1000;
				break;
			}
		}
		if(!game_over){
			distance += 0.01 * cars[0].speed;
			if(distance > totald && slices[cars[0].ti].num < nsl>>1){
				tf = now();
				game_over = 1;
				won = 1;
				if(have_tone)
					tone->beep(932, 150);	# Beep (ona 62)
				if(tf - t0 < best_score){
					best_score = tf - t0;
					if(scorestore != nil)
						scorestore->savereal("varoom", best_score);
					rec_beep_at = sys->millisec() + 300;
				}
			}
		}
	}
}

sound(nowms: int)
{
	if(!have_tone)
		return;
	if(rec_beep_at != 0 && nowms >= rec_beep_at){
		rec_beep_at = 0;
		tone->beep(932, 150);
	}
	if(noise_until != 0){
		if(nowms < noise_until){
			# Noise(500,22,34): random pitches, ona 22..34
			tone->snd(92 + rand->rand(94));
			last_snd = -1;
			return;
		}
		noise_until = 0;
		tone->stop();
		last_snd = 0;
	}
	if(!game_over){
		# Snd(12*Log2(speed/500+0.7)): 440*2^((ona-49)/12)
		f := int(25.9566 * (cars[0].speed/500.0 + 0.7));
		if(f < 1)
			f = 1;
		if(f != last_snd){
			tone->snd(f);
			last_snd = f;
		}
	}else if(last_snd != 0){
		tone->stop();
		last_snd = 0;
	}
}

now(): real
{
	return real sys->millisec() / 1000.0;
}


# --- rendering -----------------------------------------------------------

# original PrepPoly: rotate about player, project s=100/(|z|+50),
# reject z<-200 or y offscreen
prep(q: array of real, dst: array of Point): (int, real)
{
	zsum := 0.0;
	for(i := 0; i < 4; i++){
		dx := q[i*3] - f_px;
		dy := q[i*3+1] - f_py;
		dz := q[i*3+2] - f_pz;
		xc := -dx*f_cy + dz*f_sy;
		z0 := -dx*f_sy - dz*f_cy;
		yc := dy*f_ca - z0*f_sa;
		zc := dy*f_sa + z0*f_ca;
		az := zc;
		if(az < 0.0)
			az = -az;
		s := 100.0 / (az + 50.0);
		sy := s*yc + f_h;
		if(zc < -200.0 || !(-f_h < sy && sy < 2.0*f_h))
			return (0, 0.0);
		dst[i] = Point(f_ox + f_w2 + int(s*xc), f_oy + int sy);
		zsum += zc;
	}
	return (1, zsum / 4.0);
}

# world point -> camera space
campt(dx, dy, dz: real): (real, real, real)
{
	xc := -dx*f_cy + dz*f_sy;
	z0 := -dx*f_sy - dz*f_cy;
	yc := dy*f_ca - z0*f_sa;
	zc := dy*f_sa + z0*f_ca;
	return (xc, yc, zc);
}

sortd(key: array of real, val: array of int, lo, hi: int)
{
	while(lo < hi){
		if(hi - lo < 12){
			for(i := lo + 1; i <= hi; i++){
				k := key[i];
				v := val[i];
				j := i - 1;
				while(j >= lo && key[j] < k){
					key[j+1] = key[j];
					val[j+1] = val[j];
					j--;
				}
				key[j+1] = k;
				val[j+1] = v;
			}
			return;
		}
		mid := (lo + hi) / 2;
		if(key[mid] > key[lo]){
			(key[mid], key[lo]) = (key[lo], key[mid]);
			(val[mid], val[lo]) = (val[lo], val[mid]);
		}
		if(key[hi] > key[lo]){
			(key[hi], key[lo]) = (key[lo], key[hi]);
			(val[hi], val[lo]) = (val[lo], val[hi]);
		}
		if(key[hi] > key[mid]){
			(key[hi], key[mid]) = (key[mid], key[hi]);
			(val[hi], val[mid]) = (val[mid], val[hi]);
		}
		p := key[mid];
		i := lo;
		j := hi;
		while(i <= j){
			while(key[i] > p)
				i++;
			while(key[j] < p)
				j--;
			if(i <= j){
				(key[i], key[j]) = (key[j], key[i]);
				(val[i], val[j]) = (val[j], val[i]);
				i++;
				j--;
			}
		}
		if(j - lo < hi - i){
			sortd(key, val, lo, j);
			lo = i;
		}else{
			sortd(key, val, i, hi);
			hi = j;
		}
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();

	p0 := cars[0];
	dip := dipf(p0.x, p0.z, p0.ang);
	f_px = p0.x;
	f_py = p0.y;
	f_pz = p0.z;
	f_cy = math->cos(p0.ang);
	f_sy = math->sin(p0.ang);
	pang := 75.0*PI/180.0 - dip;
	f_ca = math->cos(pang);
	f_sa = math->sin(pang);
	f_w2 = w / 2;
	f_h = real h;
	f_ox = o.x;
	f_oy = o.y;

	# background is the YELLOW window bg (Fs->text_attr YELLOW<<4+BLUE)
	img.draw(img.r, ink[YELLOW], nil, Point(0, 0));
	# LTCYAN sky band tracking the dip
	skyh := int(HORIZON_DIP*math->sin(dip) + real FONT_HEIGHT * 4.5);
	if(skyh > 0)
		img.draw(Rect((o.x, o.y), (o.x + w, o.y + skyh)), ink[LTCYAN], nil, Point(0, 0));

	# sun: original feeds (p.x, 0, 1000000-p.z) through the camera matrix
	(sxc, syc, szc) := campt(p0.x, 0.0, 1000000.0 - p0.z);
	asz := szc;
	if(asz < 0.0)
		asz = -asz;
	ss := 100.0 / (asz + 50.0);
	if(syc < 0.0){
		sunp := Point(o.x + f_w2 + int(ss*sxc), o.y + 15 + int(HORIZON_DIP*math->sin(dip)));
		img.fillellipse(sunp, 15, 15, ink[YELLOW], Point(0, 0));
		img.ellipse(sunp, 15, 15, 0, ink[BROWN], Point(0, 0));
	}

	# collect visible world items (track slices, bushes, opponents),
	# painter's sort far-to-near in place of the original depth buffer
	nv := 0;
	for(i := 0; i < nsl; i++){
		(ok, zk) := prep(slices[i].ctr, scrctr[i]);
		if(ok){
			wkey[nv] = zk;
			wval[nv] = i;
			nv++;
		}
	}
	for(i = 0; i < BUSHES_NUM; i++){
		(nil, nil, zc) := campt(bushes[i].x - f_px, bushes[i].y - f_py, bushes[i].z - f_pz);
		if(zc > 0.0){
			wkey[nv] = zc;
			wval[nv] = MAXSLICES + i;
			nv++;
		}
	}
	for(i = 1; i < CARS_NUM; i++){
		(nil, nil, zc) := campt(cars[i].x - f_px, cars[i].y - f_py, cars[i].z - f_pz);
		if(zc > 0.0){
			wkey[nv] = zc;
			wval[nv] = MAXSLICES + BUSHES_NUM + i;
			nv++;
		}
	}
	if(nv > 1)
		sortd(wkey, wval, 0, nv - 1);
	for(vi := 0; vi < nv; vi++){
		id := wval[vi];
		if(id < MAXSLICES){
			sl := slices[id];
			img.fillpoly(scrctr[id], ~0, ink[DKGRAY], Point(0, 0));
			(ok, nil) := prep(sl.lft, spts);
			if(ok)
				img.fillpoly(spts, ~0, ink[sl.col], Point(0, 0));
			(ok, nil) = prep(sl.rgt, spts);
			if(ok)
				img.fillpoly(spts, ~0, ink[sl.col], Point(0, 0));
		}else if(id < MAXSLICES + BUSHES_NUM){
			bi := id - MAXSLICES;
			(xc, yc, zc) := campt(bushes[bi].x - f_px, bushes[bi].y - f_py, bushes[bi].z - f_pz);
			s := 100.0 / (zc + 50.0);
			drawbush(img, o.x + f_w2 + int(s*xc), o.y + int(s*yc + f_h),
				2.0*s, bi);
		}else{
			ci := id - MAXSLICES - BUSHES_NUM;
			(xc, yc, zc) := campt(cars[ci].x - f_px, cars[ci].y - f_py, cars[ci].z - f_pz);
			s := 100.0 / (zc + 50.0);
			drawmesh(img, o.x + f_w2 + int(s*xc), o.y + int(s*yc + f_h),
				2.0*s, cars[ci].ang - p0.ang,
				dipf(cars[ci].x, cars[ci].z, -cars[ci].ang), 1);
		}
	}

	# the player's own car through VRTransform perspective
	drawplayer(img, o, w, h, dip);

	# minimap
	if(mapimg != nil){
		img.draw(Rect((o.x + w - mw, o.y + h - mh), (o.x + w, o.y + h)),
			mapimg, nil, mapimg.r.min);
		for(i = 0; i < CARS_NUM; i++){
			col := LTPURPLE;
			if(i == 0)
				col = LTCYAN;
			dx := o.x + w - (int(cars[i].x - t_minx) >> MAP_BITS);
			dy := o.y + h - mh + (int(cars[i].z - t_minz) >> MAP_BITS);
			img.draw(Rect((dx-1, dy-1), (dx+1, dy+1)), ink[col], nil, Point(0, 0));
		}
	}

	# HUD
	s := 0.0;
	if(game_over){
		if(won)
			s = tf - t0;
		else
			s = 99.9;
		if((sys->millisec()/250) % 2 == 0 && tfont != nil){
			if(won)
				img.text(Point(o.x + (w - tfont.width("Game Completed"))/2,
					o.y + (h - FONT_HEIGHT)/2),
					ink[LTRED], Point(0, 0), tfont, "Game Completed");
			else
				img.text(Point(o.x + (w - tfont.width("Game Over"))/2,
					o.y + (h - FONT_HEIGHT)/2),
					ink[LTRED], Point(0, 0), tfont, "Game Over");
		}
	}else
		s = now() - t0;
	if(tfont != nil)
		img.text(Point(o.x, o.y), ink[BLACK], Point(0, 0), tfont,
			sys->sprint("%.1f%% Time:%.2f Best:%.2f",
				100.0*distance/totald, s, best_score));
	img.flush(Draw->Flushnow);
}

drawbush(img: ref Image, sx, sy: int, k: real, bi: int)
{
	els := sprelems[bushes[bi].img];
	mir := 1.0;
	if(bushes[bi].sym)
		mir = -1.0;
	for(i := 0; i < len els; i++){
		e := els[i];
		r := (e.thk - 1) / 2;
		if(r < 0)
			r = 0;
		if(e.kind == 0){
			img.line(Point(sx + int(k*mir*real e.x1), sy + int(k*real e.y1)),
				Point(sx + int(k*mir*real e.x2), sy + int(k*real e.y2)),
				Draw->Endsquare, Draw->Endsquare, r, ink[e.col], Point(0, 0));
		}else{
			cr := int(k*real e.x2);
			if(cr < 0)
				cr = 0;
			img.ellipse(Point(sx + int(k*mir*real e.x1), sy + int(k*real e.y1)),
				cr, cr, r, ink[e.col], Point(0, 0));
		}
	}
}

# opponent car: Scale(2s), RotX(dip), RotY(heading diff), anchored at
# the projected car position; triangles painter-sorted
drawmesh(img: ref Image, sx, sy: int, k, yaw, pitch: real, opp: int)
{
	cyw := math->cos(yaw);
	syw := math->sin(yaw);
	cp := math->cos(pitch);
	sp := math->sin(pitch);
	for(i := 0; i < NMV; i++){
		x := real meshverts[i*3];
		y := real meshverts[i*3+1];
		z := real meshverts[i*3+2];
		x1 := x*cyw + z*syw;
		z1 := -x*syw + z*cyw;
		y2 := y*cp - z1*sp;
		z2 := y*sp + z1*cp;
		mvx[i] = sx + int(k*x1);
		mvy[i] = sy + int(k*y2);
		mvz[i] = z2;
	}
	for(i = 0; i < NMT; i++){
		mkey[i] = mvz[meshtris[i*4+1]] + mvz[meshtris[i*4+2]] + mvz[meshtris[i*4+3]];
		mvalt[i] = i;
	}
	sortd(mkey, mvalt, 0, NMT-1);
	for(i = 0; i < NMT; i++){
		t := mvalt[i];
		col := meshtris[t*4];
		if(opp && col == CYAN)
			col = PURPLE;	# bin 6 body color
		tript[0] = Point(mvx[meshtris[t*4+1]], mvy[meshtris[t*4+1]]);
		tript[1] = Point(mvx[meshtris[t*4+2]], mvy[meshtris[t*4+2]]);
		tript[2] = Point(mvx[meshtris[t*4+3]], mvy[meshtris[t*4+3]]);
		img.fillpoly(tript, ~0, ink[col], Point(0, 0));
	}
}

# player car: RotY(steering d), RotX(0.4-8*dip), VRTransform perspective
# at (w/2, h-150), mesh offset (0,0,-100)
drawplayer(img: ref Image, o: Point, w, h: int, dip: real)
{
	yaw := cars[0].d;
	pitch := 0.4 - 8.0*dip;
	cyw := math->cos(yaw);
	syw := math->sin(yaw);
	cp := math->cos(pitch);
	sp := math->sin(pitch);
	for(i := 0; i < NMV; i++){
		x := real meshverts[i*3];
		y := real meshverts[i*3+1];
		z := real meshverts[i*3+2];
		x1 := x*cyw + z*syw;
		z1 := -x*syw + z*cyw;
		y2 := y*cp - z1*sp;
		z2 := y*sp + z1*cp - 100.0;
		zz := 400.0 + z2;
		if(zz < 1.0)
			zz = 1.0;
		mvx[i] = o.x + w/2 + int(400.0*x1/zz);
		mvy[i] = o.y + h - 150 + int(400.0*y2/zz);
		mvz[i] = z2;
	}
	for(i = 0; i < NMT; i++){
		mkey[i] = mvz[meshtris[i*4+1]] + mvz[meshtris[i*4+2]] + mvz[meshtris[i*4+3]];
		mvalt[i] = i;
	}
	sortd(mkey, mvalt, 0, NMT-1);
	for(i = 0; i < NMT; i++){
		t := mvalt[i];
		tript[0] = Point(mvx[meshtris[t*4+1]], mvy[meshtris[t*4+1]]);
		tript[1] = Point(mvx[meshtris[t*4+2]], mvy[meshtris[t*4+2]]);
		tript[2] = Point(mvx[meshtris[t*4+3]], mvy[meshtris[t*4+3]]);
		img.fillpoly(tript, ~0, ink[meshtris[t*4]], Point(0, 0));
	}
}
