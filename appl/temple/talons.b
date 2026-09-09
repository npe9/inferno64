implement Talons;

# TempleOS Demo/Games/Talons.HC — first-person eagle flight simulator.
# Fly over 3D island terrain, dive to the water and snatch 10 fish with
# your talons against the clock; flying into terrain ends the game.
#
# Faithful rebuild of the original renderer: WrapAngles attitude state
# (theta/pitch/roll/heading), the Mat4x4RotZ*RotX*RotZ world-to-screen
# matrix, EDTransform foreshortening (DISPLAY_SCALE/z), slope-merged
# terrain panels (TestSameSlope/MPDoPanels) with TempleOS dithered
# fills, DrawHorizon sky/ground split, mesh boats and trees (Sprite3
# scaled 10x), wing-interpolated mesh birds, the mirrored segmented
# claw arms with talon-tip sprites, and the SongTask melody.
#
# Renderer note: the original fills panels against a per-pixel depth
# buffer across cores; this port paints panels far-to-near through a
# direct Limbo port of EDTransform rather than math/draw3d (whose
# project() pays a 4x4 matmul per vertex in Limbo — far too slow for
# the thousands of terrain vertices per frame).  The depth buffer
# itself is measured, not guessed: math/polyfill's z-buffered fill is
# interpreted Limbo where Image.fillpoly is a native draw call, and on
# a load of 200 quads and 300 triangles a frame it costs 7.18ms a frame
# against 0.07ms — a hundred times over, before this game's real panel
# count is reached.  See doc/temple-plan.md.
#
# Original tick structure: AnimateTask runs on wall time (tS) throttled
# by Refresh (~30fps winmgr), so its per-iteration speed constants map
# 1:1 onto this port's 33ms tick; movement and the water auto-pitch are
# ms-scaled exactly as in the original.
#
# GAP: map is 512x512 (original 1024x1024).  Measured: at 1024x1024 the
#   world generates in 341ms into 207851 panels and 6272 objects, and it
#   plays — but only with `emu -pheap=40000000` or more, where emu's
#   default heap is 32MB, and the demo has to work when it is started
#   from the wm menu with no flags.  To try it, set MAPW/MAPH to 1024,
#   BIRDN to 256 (B_NUM) and the obx.. arrays to 16384 (4096 silently
#   drops objects past 6272), and pass the flag.  Bump/fish/boat/tree
#   densities are per-panel probabilities and scale by themselves;
#   BIRDN is the one fixed count.
# GAP: painter sort instead of a depth buffer — rare wrong overlaps
#   where a tall tree/bird should be hidden by nearer terrain (the
#   original's unlocked multicore depth buffer glitched there too).
# GAP: [Core Strip:%3d] shows this port's adaptive view radius in cells
#   (the original showed its adaptive multicore strip height 64..1024).

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

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

include "scorestore.m";
	scorestore: Scorestore;
include "grpalette.m";
	grpal: Grpalette;

Talons: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MAPW: con 512;			# original 1024; see GAP header
MAPH: con 512;
MS: con 150;			# MAP_SCALE, world units per cell
DISPLAY: con 100.0;		# DISPLAY_SCALE foreshortening
CTRLS: con 0.05;		# CTRLS_SCALE
WATER_E: con 15;
BIRD_E: con 10;
ROCK_E: con 45;
SNOW_E: con 55;
PANMAX: con 16;			# PANEL_SIZE_MAX
BIRDN: con 64;			# 256 on the 1024x1024 map: same per-area density
VIEW: con 640;
VIEWH: con 480;
PI: con Math->Pi;
NEARZ: con 10.0;		# world-space near plane for polygon clipping
NORMEPS: con 1612;		# 0.10 * 127^2: TestSameSlope threshold, quantized
BIGELEV: con 999999999;		# I64_MAX stand-in: off-map elevation
SNDFISH: con 988;		# Snd(74) = 440*2^((74-60)/12) Hz (Ona2Freq: ona 60 = 440Hz)
SNDBEEP: con 494;		# Beep() ~ Snd(62) Hz

win: ref Window;
font: ref Font;
palette: array of ref Image;
dith: array of ref Image;	# 0 GREEN/LTGREEN 1 DKGRAY/LTGRAY 2 LTGRAY/WHITE
tip7, tip7m, tip8, tip8m: ref Image;		# talon-tip sprites
tip7f, tip7fm, tip8f, tip8fm: ref Image;	# mirrored copies
have_tone := 0;
blink_on := 0;

Tri3: adt { col, a, b, c: int; };
Mesh: adt { vx, vy, vz: array of real; t: array of Tri3; };
birdm2, birdm3, boatm4, boatm5, treem6: ref Mesh;

# talons_1.spr: the original fish vector sprite ($SP <1>), 8 black lines
# (thick 2) lying flat in the water plane.
fishlines := array[] of {
	2, -32, -3, 2,   -3, 2, 2, 34,   2, 34, -1, 43,   -1, 43, 11, 38,
	11, 38, 4, 28,   4, 28, 9, -4,   9, -4, 2, -31,   2, -31, 4, 41
};

# map
elev: array of int;		# world-unit elevations, MAPW*MAPH
pidx: array of int;		# cell -> panel index, -1 none

# panels (structure-of-arrays; see MPDoPanels)
ppx, ppy: array of int;		# cell rect origin
ppw, pph: array of byte;	# cell rect size
ppcol: array of byte;		# 0..15 palette; 16+i dither pair i
ppobj: array of int;		# object index or -1
ppstamp: array of int;		# per-frame draw stamp
npan := 0;

# scenery objects: one per panel at most (fish/boat/tree)
OFISH, OBOAT4, OBOAT5, OTREE: con iota;
obx, oby, obz: array of real;
obkind: array of byte;
obalive: array of byte;
nobj := 0;

# birds
bx, by, bz, ba: array of real;

# flight state (WrapAngles)
theta, pitch, roll, heading, speed: real;
invert_pitch := 0;
rolled_over := 0;
wx, wy, wz: real;		# plane position, world units
claws_down := 0.0;
fish_left := 0;
game_t0, game_tf: real;		# seconds; game_tf 0.0 = still playing
best_score: real;

# world-to-screen rotation (RotZ(roll)*RotX(theta)*RotZ(heading))
r00, r01, r02, r10, r11, r12, r20, r21, r22: real;
scrw, scrh, scx, scy: int;	# current screen dims/centre

# adaptive view radius in cells (the original's strip_height analogue)
rad := 48;
stampctr := 0;

# frame scratch buffers
fwx := array[8] of real;
fwy := array[8] of real;
fwz := array[8] of real;
ccx := array[12] of real;
ccy := array[12] of real;
ccz := array[12] of real;
cox := array[12] of real;
coy := array[12] of real;
coz := array[12] of real;
fpts := array[12] of Point;
DLMAX: con 16384;
dlist: array of int;
ddepth: array of int;

lastms := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	scorestore = load Scorestore Scorestore->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Talons", Wmclient->Appl);
	d := win.display;
	# authentic 8x8 TempleOS system font
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	# gr_palette_std, from grpalette(2)
	palette = grpal->images(d);
	# ROPF_DITHER checkerboards, screen-anchored 2x2 replicated tiles
	dith = array[3] of ref Image;
	dith[0] = mkdither(d, 2, 10);	# GREEN+LTGREEN
	dith[1] = mkdither(d, 8, 7);	# DKGRAY+LTGRAY
	dith[2] = mkdither(d, 7, 15);	# LTGRAY+WHITE

	tip7 = d.open("/icons/temple/talons_7.bit");
	tip7m = d.open("/icons/temple/talons_7.mask");
	tip8 = d.open("/icons/temple/talons_8.bit");
	tip8m = d.open("/icons/temple/talons_8.mask");
	tip7f = flipimage(d, tip7);
	tip7fm = flipimage(d, tip7m);
	tip8f = flipimage(d, tip8);
	tip8fm = flipimage(d, tip8m);

	birdm2 = loadmesh("/icons/temple/talons_2.mesh");
	birdm3 = loadmesh("/icons/temple/talons_3.mesh");
	boatm4 = loadmesh("/icons/temple/talons_4.mesh");
	boatm5 = loadmesh("/icons/temple/talons_5.mesh");
	treem6 = loadmesh("/icons/temple/talons_6.mesh");

	dlist = array[DLMAX] of int;
	ddepth = array[DLMAX] of int;

	best_score = 9999.0;	# RegDft default
	if(scorestore != nil)
		best_score = scorestore->loadreal("talons", best_score);
	game_init();
	if(have_tone)
		spawn songtask();
	win.reshape(Rect((0, 0), (VIEW, VIEWH)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	lastms = sys->millisec();
	ticks := chan of int;
	spawn timer(ticks, 33);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			if(have_tone) tone->stop();
			exit;
		'\n' or 'r' or 'R' =>
			game_init();
		Keyboard->Up or 'w' or 'W' =>
			# airplane stick: up-arrow pushes the nose down
			theta += CTRLS*math->cos(roll);
			heading += CTRLS*math->sin(roll)*math->sin(theta);
			wrapangles();
		Keyboard->Down or 's' or 'S' =>
			theta -= CTRLS*math->cos(roll);
			heading -= CTRLS*math->sin(roll)*math->sin(theta);
			wrapangles();
		Keyboard->Right or 'd' or 'D' =>
			roll += CTRLS;
			wrapangles();
		Keyboard->Left or 'a' or 'A' =>
			roll -= CTRLS;
			wrapangles();
		}
	<-ticks =>
		now := sys->millisec();
		dtms := now - lastms;
		lastms = now;
		if(dtms < 1) dtms = 1;
		if(dtms > 200) dtms = 200;
		step(dtms);
		blink_on = (now / 250) % 2;
		redraw();
	}
}

# ---------- map generation (InitElevations / CalcNormals / MPDoPanels) ----------

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

game_init()
{
	initelevations();
	dopanels();
	# birds: random spot, altitude BIRD_ELEVATION above local terrain,
	# random heading; they fly a slow circle (2*pi per 10s)
	bx = array[BIRDN] of real;
	by = array[BIRDN] of real;
	bz = array[BIRDN] of real;
	ba = array[BIRDN] of real;
	for(i := 0; i < BIRDN; i++){
		bx[i] = real (rn(MAPW)*MS);
		by[i] = real (rn(MAPH)*MS);
		ba[i] = 2.0*PI*real rn(1000)/1000.0;
		ix := int (bx[i] / real MS);
		iy := int (by[i] / real MS);
		bz[i] = real (BIRD_E*MS + elev[iy*MAPW+ix]);
	}

	theta = -PI/2.0;	# level flight
	roll = 0.0;
	heading = 0.0;
	speed = 2.5;
	claws_down = 0.0;
	wrapangles();

	wx = real (MAPW/2*MS);
	wy = real (MAPH/2*MS);
	wz = real (64*MS + elev[(MAPH/2)*MAPW + MAPW/2]);

	fish_left = 10;
	game_tf = 0.0;
	game_t0 = real sys->millisec() / 1000.0;
}

initelevations()
{
	# additive square bumps of shrinking half-extent, then water floor
	elev = array[MAPW*MAPH] of { * => 0 };
	for(i := 0; i < MAPW*MAPH/128; i++){
		x := rn(MAPW);
		y := rn(MAPH);
		j := 1 << rn(6);
		l := 0;
		while(j > 0){
			j--;
			if(l == 0 && rn(65536) < 16384)
				l = rn(j+1);
			if(l > 0){
				x1 := x-j; if(x1 < 0) x1 = 0;
				x2 := x+j; if(x2 > MAPW-1) x2 = MAPW-1;
				y1 := y-j; if(y1 < 0) y1 = 0;
				y2 := y+j; if(y2 > MAPH-1) y2 = MAPH-1;
				for(yy := y1; yy < y2; yy++){
					row := yy*MAPW;
					for(xx := x1; xx < x2; xx++)
						elev[row+xx] += MS/2;
				}
				l--;
			}
		}
	}
	for(k := 0; k < MAPW*MAPH; k++)
		if(elev[k] < WATER_E*MS)
			elev[k] = WATER_E*MS;
}

# normals quantized to bytes (offset 127) so the slope merge compares in
# integers and the tables fit the default emu heap; freed after the build
nqx, nqy, nqz: array of byte;
groww, growh: array of byte;

calcnormals()
{
	nqx = array[MAPW*MAPH] of { * => byte 127 };
	nqy = array[MAPW*MAPH] of { * => byte 127 };
	nqz = array[MAPW*MAPH] of { * => byte 127 };
	for(j := 0; j < MAPH-1; j++){
		row := j*MAPW;
		for(i := 0; i < MAPW-1; i++){
			dx := real (elev[row+i+1] - elev[row+i]);
			dy := real (elev[row+MAPW+i] - elev[row+i]);
			d := math->sqrt(dx*dx + dy*dy + 1.0);
			nqx[row+i] = byte (127 + int (127.0*dx/d));
			nqy[row+i] = byte (127 + int (127.0*dy/d));
			nqz[row+i] = byte (127 - int (127.0/d));
		}
	}
}

sameslope(sx, sy, x, y, w, h: int): int
{
	# TestSameSlope: every normal in [x,x+w)x[y,y+h) within 0.10
	# norm-square of the normal at (sx,sy)
	if(!(0 <= x && x+w < MAPW && 0 <= y && y+h < MAPH))
		return 0;
	s := sy*MAPW + sx;
	ax := int nqx[s]; ay := int nqy[s]; az := int nqz[s];
	for(k2 := 0; k2 < h; k2++){
		row := (y+k2)*MAPW + x;
		for(k1 := 0; k1 < w; k1++){
			dx := int nqx[row+k1]-ax;
			dy := int nqy[row+k1]-ay;
			dz := int nqz[row+k1]-az;
			if(dx*dx+dy*dy+dz*dz > NORMEPS)
				return 0;
		}
	}
	return 1;
}

grow(i, j: int): (int, int)
{
	# the original re-tests the whole rectangle on each growth step;
	# testing only the newly-added column/row is equivalent (the base
	# rectangle already passed) and much cheaper
	w := 1;
	h := 1;
	for(;;){
		cont := 0;
		if(w < PANMAX && sameslope(i, j, i+w, j, 1, h)){
			w++;
			cont = 1;
		}
		if(h < PANMAX && sameslope(i, j, i, j+h, w, 1)){
			h++;
			cont = 1;
		}
		if(!cont)
			break;
	}
	return (w, h);
}

growpans(need: int)
{
	if(ppx != nil && need <= len ppx)
		return;
	n := 65536;
	if(ppx != nil)
		n = 2 * len ppx;
	nx := array[n] of int;
	ny := array[n] of int;
	nw := array[n] of byte;
	nh := array[n] of byte;
	nc := array[n] of byte;
	no := array[n] of int;
	ns := array[n] of { * => 0 };
	if(ppx != nil){
		nx[0:] = ppx[0:npan];
		ny[0:] = ppy[0:npan];
		nw[0:] = ppw[0:npan];
		nh[0:] = pph[0:npan];
		nc[0:] = ppcol[0:npan];
		no[0:] = ppobj[0:npan];
		ns[0:] = ppstamp[0:npan];
	}
	ppx = nx;
	ppy = ny;
	ppw = nw;
	pph = nh;
	ppcol = nc;
	ppobj = no;
	ppstamp = ns;
}

addobj(kind: int, x, y, z: real): int
{
	if(nobj >= len obx)
		return -1;
	obx[nobj] = x;
	oby[nobj] = y;
	obz[nobj] = z;
	obkind[nobj] = byte kind;
	obalive[nobj] = byte 1;
	return nobj++;
}

dopanels()
{
	calcnormals();
	pidx = array[MAPW*MAPH] of { * => -1 };
	groww = array[MAPW*MAPH] of { * => byte 0 };
	growh = array[MAPW*MAPH] of byte;
	npan = 0;
	ppx = nil;
	growpans(1);
	obx = array[4096] of real;
	oby = array[4096] of real;
	obz = array[4096] of real;
	obkind = array[4096] of byte;
	obalive = array[4096] of byte;
	nobj = 0;
	for(threshold := 8; threshold >= 1; threshold--){
		for(j := 0; j < MAPH-1; j++){
			row := j*MAPW;
			for(i := 0; i < MAPW-1; i++){
				if(pidx[row+i] >= 0){
					pi := pidx[row+i];
					if(ppx[pi] + int ppw[pi] > i+1)
						i = ppx[pi] + int ppw[pi] - 1;
					continue;
				}
				w: int; h: int;
				if(groww[row+i] > byte 0){
					w = int groww[row+i];
					h = int growh[row+i];
				}else{
					(w, h) = grow(i, j);
					groww[row+i] = byte w;
					growh[row+i] = byte h;
				}
				if(w >= threshold || h >= threshold){
					growpans(npan+1);
					makepanel(i, j, w, h);
					for(k2 := 0; k2 < h; k2++){
						prow := (j+k2)*MAPW;
						for(k1 := 0; k1 < w; k1++)
							pidx[prow+i+k1] = npan;
					}
					npan++;
				}
			}
		}
	}
	# the merge scaffolding is init-only; give the heap back
	nqx = nil;
	nqy = nil;
	nqz = nil;
	groww = nil;
	growh = nil;
}

makepanel(i, j, w, h: int)
{
	ppx[npan] = i;
	ppy[npan] = j;
	ppw[npan] = byte w;
	pph[npan] = byte h;
	ppstamp[npan] = 0;
	ppobj[npan] = -1;
	l := elev[j*MAPW+i];
	col := 0;
	if(l <= WATER_E*MS &&
	   elev[j*MAPW+i+w-1] <= WATER_E*MS &&
	   elev[(j+h-1)*MAPW+i] <= WATER_E*MS &&
	   elev[(j+h-1)*MAPW+i+w-1] <= WATER_E*MS){
		col = 1;			# BLUE water
		if(rn(100) < 5){
			ox := real ((i+w/2)*MS);
			oy := real ((j+h/2)*MS);
			if(rn(10) == 0){	# boat
				k := OBOAT4;
				if(rn(2))
					k = OBOAT5;
				ppobj[npan] = addobj(k, ox, oy, real ((WATER_E+2)*MS));
			}else			# fish
				ppobj[npan] = addobj(OFISH, ox, oy, real (WATER_E*MS));
		}
	}else if(l < ROCK_E*MS){
		if(rn(2))
			col = 10;		# LTGREEN
		else
			col = 16;		# GREEN+LTGREEN dither
		if(rn(100) < 3)
			ppobj[npan] = addobj(OTREE, real ((i+w/2)*MS),
				real ((j+h/2)*MS), real l);
	}else if(l < SNOW_E*MS){
		if(rn(4) == 0){
			if(rn(2))
				col = 7;	# LTGRAY
			else
				col = 17;	# DKGRAY+LTGRAY dither
		}else{
			if(rn(2))
				col = 10;
			else
				col = 16;
		}
	}else{
		if(rn(4) == 0){
			if(rn(2))
				col = 15;	# WHITE
			else
				col = 7;
		}else{
			if(rn(2))
				col = 18;	# LTGRAY+WHITE dither
			else
				col = 17;
		}
	}
	ppcol[npan] = byte col;
}

colimg(code: int): ref Image
{
	if(code < 16)
		return palette[code];
	return dith[code-16];
}

mkdither(d: ref Display, ca, cb: int): ref Image
{
	# 2x2 replicated checkerboard = ROPF_DITHER two-colour fill
	img := d.newimage(Rect((0, 0), (2, 2)), d.image.chans, 1, Draw->Black);
	if(img == nil)
		return palette[ca];
	img.draw(Rect((0, 0), (1, 1)), palette[ca], nil, Point(0, 0));
	img.draw(Rect((1, 1), (2, 2)), palette[ca], nil, Point(0, 0));
	img.draw(Rect((1, 0), (2, 1)), palette[cb], nil, Point(0, 0));
	img.draw(Rect((0, 1), (1, 2)), palette[cb], nil, Point(0, 0));
	return img;
}

# ---------- flight model (WrapAngles / AnimateTask / Core0Talons) ----------

wrap(a: real): real
{
	# into [-pi, pi)
	return a - 2.0*PI*math->floor((a+PI)/(2.0*PI));
}

wrap0(a: real): real
{
	# into [0, 2*pi)
	return a - 2.0*PI*math->floor(a/(2.0*PI));
}

sign(a: real): real
{
	if(a > 0.0) return 1.0;
	if(a < 0.0) return -1.0;
	return 0.0;
}

wrapangles()
{
	theta = wrap(theta);
	pitch = wrap(-theta - PI/2.0);
	if(pitch > PI/2.0 || pitch < -PI/2.0){
		invert_pitch = 1;
		pitch = wrap(PI - pitch);
	}else
		invert_pitch = 0;
	roll = wrap(roll);
	inrange := 0;
	if(-PI/2.0 <= roll && roll < PI/2.0)
		inrange = 1;
	# rolled_over = !(invert_pitch XOR inrange)
	rolled_over = (invert_pitch == inrange);
	heading = wrap0(heading);
}

buildmat()
{
	# world-to-screen: RotZ(roll) * RotX(theta) * RotZ(heading)
	ch := math->cos(heading); sh := math->sin(heading);
	ct := math->cos(theta); st := math->sin(theta);
	cr := math->cos(roll); sr := math->sin(roll);
	r00 = cr*ch - sr*ct*sh;
	r01 = -cr*sh - sr*ct*ch;
	r02 = sr*st;
	r10 = sr*ch + cr*ct*sh;
	r11 = -sr*sh + cr*ct*ch;
	r12 = -cr*st;
	r20 = st*sh;
	r21 = st*ch;
	r22 = ct;
}

fishfind(): (int, real)
{
	best := -1;
	bd := 1.7e308;
	for(i := 0; i < nobj; i++){
		if(int obkind[i] != OFISH || obalive[i] == byte 0)
			continue;
		dx := obx[i] - wx;
		dy := oby[i] - wy;
		dd := dx*dx + dy*dy;
		if(dd < bd){
			bd = dd;
			best = i;
		}
	}
	return (best, bd);
}

step(dtms: int)
{
	if(game_tf > 0.0)
		return;
	buildmat();
	ms := real dtms;
	dts := ms / 1000.0;
	nowsec := real sys->millisec() / 1000.0;

	# forward motion: pos -= speed*ms*(screen-to-world z axis)
	wx -= speed * ms * r20;
	wy -= speed * ms * r21;
	wz -= speed * ms * r22;

	if(wz < real ((WATER_E+3)*MS)){
		if(wz < real (WATER_E*MS)){
			wz = real (WATER_E*MS);
			# skimming the water auto-raises the nose to pitch -pi/8
			if(invert_pitch){
				if(pitch < -PI/8.0)
					theta += dts * sign(3.0*PI/8.0 - theta);
			}else if(pitch < -PI/8.0)
				theta += dts * sign(-3.0*PI/8.0 - theta);
			wrapangles();
			buildmat();
		}
		speed = 1.0;
		if(rolled_over)
			claws_down = 0.0;
		else{
			(fi, dd) := fishfind();
			if(fi < 0)
				claws_down = 0.0;
			else{
				d := math->sqrt(dd);
				x1 := wx - obx[fi];
				y1 := wy - oby[fi];
				# (r20,r21) is the backward vector: this dot is
				# positive exactly when the fish is ahead
				if(r20*x1 + r21*y1 > 0.0 && d < real (4*MS))
					claws_down = d / real (4*MS);	# Saw(d, 4*MAP_SCALE)
				else
					claws_down = 0.01;
				if(d < real (2*MS)){
					obalive[fi] = byte 0;
					fish_left--;
					if(fish_left == 0){
						game_tf = nowsec;
						if(game_tf - game_t0 < best_score){
							best_score = game_tf - game_t0;
							if(scorestore != nil)
								scorestore->savereal("talons", best_score);
						}
					}
					if(have_tone)
						tone->beep(SNDFISH, 200);	# Snd(74)
				}
			}
		}
	}else{
		claws_down = 0.0;
		# attitude-driven speed, per ~33ms tick as per the original's
		# Refresh-throttled AnimateTask iteration (theta 0 = straight down)
		if(theta >= -PI/4.0 && theta <= PI/4.0)
			speed += 0.0005;
		else if(theta >= -3.0*PI/4.0 && theta <= 3.0*PI/4.0)
			speed += 0.0001;
		else
			speed -= 0.0001;
		ath := theta;
		if(ath < 0.0)
			ath = -ath;
		speed += 0.0005 - 0.0002*ath/(PI/4.0);
		if(speed < 0.1) speed = 0.1;
		if(speed > 5.0) speed = 5.0;
	}

	# birds circle slowly at BIRD_ELEVATION above local terrain
	for(i := 0; i < BIRDN; i++){
		bx[i] += 10.0*dts*real MS*math->cos(ba[i]);
		by[i] += 10.0*dts*real MS*math->sin(ba[i]);
		ix := int math->floor(bx[i] / real MS);
		iy := int math->floor(by[i] / real MS);
		if(ix < 0) ix = 0;
		if(ix > MAPW-1) ix = MAPW-1;
		if(iy < 0) iy = 0;
		if(iy > MAPH-1) iy = MAPH-1;
		bz[i] = real (BIRD_E*MS + elev[iy*MAPW+ix]);
		ba[i] += 2.0*PI*dts/10.0;
	}

	# terrain collision (Core0Talons): hitting ground above water level
	# ends the game; so does leaving the map (elevation I64_MAX there)
	el := BIGELEV;
	xx := int math->floor(wx / real MS);
	yy := int math->floor(wy / real MS);
	if(xx >= 0 && xx < MAPW && yy >= 0 && yy < MAPH)
		el = elev[yy*MAPW+xx];
	if(int wz - el < 0 && el > WATER_E*MS && game_tf == 0.0){
		if(have_tone)
			tone->beep(SNDBEEP, 250);	# Beep()
		game_tf = nowsec;
	}
}

# ---------- renderer (EDTransform / MPDrawIt / DrawHorizon) ----------

# world point -> camera space
xform(x, y, z: real): (real, real, real)
{
	tx := x - wx;
	ty := y - wy;
	tz := z - wz;
	return (r00*tx + r01*ty + r02*tz,
		r10*tx + r11*ty + r12*tz,
		r20*tx + r21*ty + r22*tz);
}

# fill a world-space polygon in fwx/fwy/fwz[0:n]: clip against the near
# plane, foreshorten (EDTransform) and fill
fillworld(img: ref Image, o: Point, n: int, col: ref Image)
{
	for(i := 0; i < n; i++){
		(cx, cy, cz) := xform(fwx[i], fwy[i], fwz[i]);
		ccx[i] = cx;
		ccy[i] = cy;
		ccz[i] = cz;
	}
	# Sutherland-Hodgman against camera z <= -NEARZ
	m := 0;
	ax := ccx[n-1]; ay := ccy[n-1]; az := ccz[n-1];
	for(i = 0; i < n; i++){
		bxx := ccx[i]; byy := ccy[i]; bzz := ccz[i];
		ain := az <= -NEARZ;
		bin := bzz <= -NEARZ;
		if(ain != bin){
			t := (-NEARZ - az) / (bzz - az);
			cox[m] = ax + t*(bxx-ax);
			coy[m] = ay + t*(byy-ay);
			coz[m] = -NEARZ;
			m++;
		}
		if(bin){
			cox[m] = bxx;
			coy[m] = byy;
			coz[m] = bzz;
			m++;
		}
		ax = bxx; ay = byy; az = bzz;
	}
	if(m < 3)
		return;
	for(i = 0; i < m; i++){
		zz := -coz[i];
		fpts[i] = Point(o.x + scx + int (cox[i]*DISPLAY/zz),
			o.y + scy - int (coy[i]*DISPLAY/zz));
	}
	img.fillpoly(fpts[0:m], ~0, col, fpts[0]);
}

drawquad(img: ref Image, o: Point, pi: int)
{
	i := ppx[pi];
	j := ppy[pi];
	w := int ppw[pi];
	h := int pph[pi];
	fwx[0] = real (i*MS);	fwy[0] = real (j*MS);	fwz[0] = real elev[j*MAPW+i];
	fwx[1] = real ((i+w)*MS); fwy[1] = real (j*MS);	fwz[1] = real elev[j*MAPW+i+w];
	fwx[2] = real ((i+w)*MS); fwy[2] = real ((j+h)*MS); fwz[2] = real elev[(j+h)*MAPW+i+w];
	fwx[3] = real (i*MS);	fwy[3] = real ((j+h)*MS); fwz[3] = real elev[(j+h)*MAPW+i];
	fillworld(img, o, 4, colimg(int ppcol[pi]));
}

drawfish(img: ref Image, o: Point, px, py, pz: real)
{
	# the fish vector sprite lies flat in the water plane; black, thin
	for(i := 0; i < len fishlines; i += 4){
		(x1, y1, z1) := xform(px + real fishlines[i], py + real fishlines[i+1], pz);
		(x2, y2, z2) := xform(px + real fishlines[i+2], py + real fishlines[i+3], pz);
		if(z1 > -NEARZ || z2 > -NEARZ)
			continue;
		p1 := Point(o.x + scx + int (x1*DISPLAY/(-z1)), o.y + scy - int (y1*DISPLAY/(-z1)));
		p2 := Point(o.x + scx + int (x2*DISPLAY/(-z2)), o.y + scy - int (y2*DISPLAY/(-z2)));
		img.line(p1, p2, Draw->Endsquare, Draw->Endsquare, 0, palette[0], Point(0, 0));
	}
}

drawmesh(img: ref Image, o: Point, m, m2: ref Mesh, mt: real,
	px, py, pz, scale, rot, extent: real)
{
	# Sprite3 of an SPT_MESH: verts offset from p, optionally vertex-
	# interpolated with a second frame (SpriteInterpolate) and rotated
	# about world-up (SpriteTransform RotZ)
	if(m == nil)
		return;
	(nil, nil, cz) := xform(px, py, pz);
	zz := -cz;
	if(zz < NEARZ)
		return;
	if(extent*scale*DISPLAY/zz < 1.5)
		return;		# subpixel: skip
	cs := math->cos(rot);
	sn := math->sin(rot);
	nv := len m.vx;
	for(t := 0; t < len m.t; t++){
		tr := m.t[t];
		if(tr.a >= nv || tr.b >= nv || tr.c >= nv)
			continue;
		for(k := 0; k < 3; k++){
			vi := tr.a;
			if(k == 1) vi = tr.b;
			if(k == 2) vi = tr.c;
			vx := m.vx[vi]; vy := m.vy[vi]; vz := m.vz[vi];
			if(m2 != nil){
				vx += mt*(m2.vx[vi]-vx);
				vy += mt*(m2.vy[vi]-vy);
				vz += mt*(m2.vz[vi]-vz);
			}
			fwx[k] = px + scale*(vx*cs - vy*sn);
			fwy[k] = py + scale*(vx*sn + vy*cs);
			fwz[k] = pz + scale*vz;
		}
		fillworld(img, o, 3, palette[tr.col & 15]);
	}
}

drawobj(img: ref Image, o: Point, oi: int)
{
	if(oi < 0 || obalive[oi] == byte 0)
		return;
	case int obkind[oi] {
	OFISH =>
		drawfish(img, o, obx[oi], oby[oi], obz[oi]);
	OBOAT4 =>
		drawmesh(img, o, boatm4, nil, 0.0, obx[oi], oby[oi], obz[oi], 10.0, 0.0, 160.0);
	OBOAT5 =>
		drawmesh(img, o, boatm5, nil, 0.0, obx[oi], oby[oi], obz[oi], 10.0, 0.0, 160.0);
	OTREE =>
		drawmesh(img, o, treem6, nil, 0.0, obx[oi], oby[oi], obz[oi], 10.0, 0.0, 150.0);
	}
}

# quicksort panels far-to-near (painter's order)
dsort(lo, hi: int)
{
	while(lo < hi){
		p := ddepth[(lo+hi)/2];
		i := lo;
		j := hi;
		while(i <= j){
			while(ddepth[i] > p) i++;
			while(ddepth[j] < p) j--;
			if(i <= j){
				td := ddepth[i]; ddepth[i] = ddepth[j]; ddepth[j] = td;
				tv := dlist[i]; dlist[i] = dlist[j]; dlist[j] = tv;
				i++;
				j--;
			}
		}
		if(j - lo < hi - i){
			dsort(lo, j);
			lo = i;
		}else{
			dsort(i, hi);
			hi = j;
		}
	}
}

drawterrain(img: ref Image, o: Point)
{
	stampctr++;
	# scan window around the plane, pushed half a radius along the view
	xc := int (wx / real MS) - int (r20 * real rad / 2.0);
	yc := int (wy / real MS) - int (r21 * real rad / 2.0);
	xlo := xc-rad; if(xlo < 0) xlo = 0;
	xhi := xc+rad; if(xhi > MAPW-1) xhi = MAPW-1;
	ylo := yc-rad; if(ylo < 0) ylo = 0;
	yhi := yc+rad; if(yhi > MAPH-1) yhi = MAPH-1;
	nd := 0;
	for(y := ylo; y <= yhi; y++){
		row := y*MAPW;
		x := xlo;
		while(x <= xhi){
			pi := pidx[row+x];
			if(pi < 0){
				x++;
				continue;
			}
			if(ppstamp[pi] != stampctr && nd < DLMAX){
				ppstamp[pi] = stampctr;
				cxw := real ((ppx[pi] + int ppw[pi]/2)*MS);
				cyw := real ((ppy[pi] + int pph[pi]/2)*MS);
				(nil, nil, cz) := xform(cxw, cyw, real elev[ppy[pi]*MAPW+ppx[pi]]);
				# keep panels a bit behind the eye: their far corners
				# may still cross the screen plane
				if(-cz > real (-2*PANMAX*MS)){
					dlist[nd] = pi;
					ddepth[nd] = int (-cz);
					nd++;
				}
			}
			nx := ppx[pi] + int ppw[pi];
			if(nx <= x)
				nx = x+1;
			x = nx;
		}
	}
	if(nd > 1)
		dsort(0, nd-1);
	for(k := 0; k < nd; k++){
		drawquad(img, o, dlist[k]);
		if(ppobj[dlist[k]] >= 0)
			drawobj(img, o, ppobj[dlist[k]]);
	}
}

drawbirds(img: ref Image, o: Point)
{
	# wing flap: SpriteInterpolate(Tri(tS,0.2), frame2, frame3)
	t := real sys->millisec() / 1000.0 / 0.2;
	t -= math->floor(t);
	if(t < 0.5)
		t = 2.0*t;
	else
		t = 2.0*(1.0-t);
	for(i := 0; i < BIRDN; i++)
		drawmesh(img, o, birdm2, birdm3, t, bx[i], by[i], bz[i], 1.0, ba[i], 120.0);
}

# Cohen-Sutherland clip to [0,xmax]x[0,ymax]; returns (accept,x1,y1,x2,y2)
outcode(x, y, xmax, ymax: int): int
{
	c := 0;
	if(x < 0) c |= 1;
	if(x > xmax) c |= 2;
	if(y < 0) c |= 4;
	if(y > ymax) c |= 8;
	return c;
}

clipline(x1, y1, x2, y2, xmax, ymax: int): (int, int, int, int, int)
{
	c1 := outcode(x1, y1, xmax, ymax);
	c2 := outcode(x2, y2, xmax, ymax);
	for(iter := 0; iter < 32; iter++){
		if((c1 | c2) == 0)
			return (1, x1, y1, x2, y2);
		if((c1 & c2) != 0)
			return (0, x1, y1, x2, y2);
		c := c1;
		if(c == 0)
			c = c2;
		x := 0;
		y := 0;
		if(c & 8){
			x = x1 + int (real (x2-x1) * real (ymax-y1) / real (y2-y1));
			y = ymax;
		}else if(c & 4){
			x = x1 + int (real (x2-x1) * real (-y1) / real (y2-y1));
			y = 0;
		}else if(c & 2){
			y = y1 + int (real (y2-y1) * real (xmax-x1) / real (x2-x1));
			x = xmax;
		}else{
			y = y1 + int (real (y2-y1) * real (-x1) / real (x2-x1));
			x = 0;
		}
		if(c == c1){
			x1 = x;
			y1 = y;
			c1 = outcode(x1, y1, xmax, ymax);
		}else{
			x2 = x;
			y2 = y;
			c2 = outcode(x2, y2, xmax, ymax);
		}
	}
	return (0, x1, y1, x2, y2);
}

fillquad4(img: ref Image, o: Point, ax, ay, bxx, byy, cx, cy, dx, dy: int, col: ref Image)
{
	fpts[0] = Point(o.x+ax, o.y+ay);
	fpts[1] = Point(o.x+bxx, o.y+byy);
	fpts[2] = Point(o.x+cx, o.y+cy);
	fpts[3] = Point(o.x+dx, o.y+dy);
	img.fillpoly(fpts[0:4], ~0, col, fpts[0]);
}

drawhorizon(img: ref Image, o: Point, w, h: int)
{
	# straight-up-ish: all sky
	th := wrap(theta - PI);
	if(th >= -PI/4.0 && th < PI/4.0){
		img.draw(img.r, palette[11], nil, Point(0, 0));	# LTCYAN
		return;
	}
	ground := 10;					# LTGREEN
	if(wz < real ((WATER_E+3)*MS))
		ground = 1;				# BLUE over water
	# vanishing points of the horizontals perpendicular to the view
	xh := -256.0*r20;
	yh := -256.0*r21;
	(x1, y1) := edscreen(xh + yh*32.0, yh - xh*32.0, 0.0);
	(x2, y2) := edscreen(xh - yh*32.0, yh + xh*32.0, 0.0);
	(ok, cx1, cy1, cx2, cy2) := clipline(x1, y1, x2, y2, w-1, h-1);
	if(ok){
		if(cx2 < cx1){
			t := cx1; cx1 = cx2; cx2 = t;
			t = cy1; cy1 = cy2; cy2 = t;
		}
		if(cx1 == 0 && cx2 == w-1){
			sky := palette[11];
			gnd := colimgg(ground);
			if(rolled_over){
				t := sky; sky = gnd; gnd = t;
			}
			fillquad4(img, o, 0, 0, w-1, 0, w-1, cy2, 0, cy1, sky);
			fillquad4(img, o, 0, h-1, w-1, h-1, w-1, cy2, 0, cy1, gnd);
			return;
		}
		if(cy2 < cy1){
			t := cx1; cx1 = cx2; cx2 = t;
			t = cy1; cy1 = cy2; cy2 = t;
		}
		if(cy1 == 0 && cy2 == h-1){
			lc := palette[11];
			rc := colimgg(ground);
			if((cx1 < cx2) != (rolled_over != 0)){
				t := lc; lc = rc; rc = t;
			}
			fillquad4(img, o, 0, 0, 0, h-1, cx2, h-1, cx1, 0, lc);
			fillquad4(img, o, w-1, 0, w-1, h-1, cx2, h-1, cx1, 0, rc);
			return;
		}
	}
	img.draw(img.r, palette[11], nil, Point(0, 0));	# "Not correct" fallback
}

colimgg(pal: int): ref Image
{
	return palette[pal];
}

edscreen(x, y, z: real): (int, int)
{
	# EDTransform of a direction vector (rotation only, no translation)
	dx := r00*x + r01*y + r02*z;
	dy := r10*x + r11*y + r12*z;
	dz := r20*x + r21*y + r22*z;
	zz := -dz;
	if(zz > 0.0)
		return (scx + int (dx*DISPLAY/zz), scy - int (dy*DISPLAY/zz));
	return (scx + int dx, scy - int dy);
}

# ---------- claws (ClawDraw / ClawsDraw, DCF_SYMMETRY) ----------

clawline(img: ref Image, o: Point, w: int, x1, y1, x2, y2: real, rad2: int, col: ref Image)
{
	p1 := Point(o.x + int x1, o.y + int y1);
	p2 := Point(o.x + int x2, o.y + int y2);
	img.line(p1, p2, Draw->Endsquare, Draw->Endsquare, rad2, col, Point(0, 0));
	# mirrored twin (DCSymmetrySet about the vertical centre line)
	m1 := Point(o.x + w - int x1, o.y + int y1);
	m2 := Point(o.x + w - int x2, o.y + int y2);
	img.line(m1, m2, Draw->Endsquare, Draw->Endsquare, rad2, col, Point(0, 0));
}

drawtip(img: ref Image, o: Point, w: int, px, py: int, t, tm, tf, tfm: ref Image)
{
	if(t == nil)
		return;
	img.draw(t.r.addpt(Point(o.x+px, o.y+py)), t, tm, t.r.min);
	if(tf == nil)
		return;
	r := Rect((o.x + w - px - t.r.max.x, o.y + py + t.r.min.y),
		(o.x + w - px - t.r.min.x, o.y + py + t.r.max.y));
	img.draw(r, tf, tfm, tf.r.min);
}

clawdraw(img: ref Image, o: Point, w: int, x1, y1, x2, y2: real, thickw, segments, talon: int)
{
	# segmented black-over-yellow finger; TempleOS pen width thickw maps
	# to line radius (width 2r+1), keeping the 1px black outline
	for(i := 0; i < segments; i++){
		j := segments - i;
		ax := (real j*x1 + real i*x2) / real segments;
		ay := (real j*y1 + real i*y2) / real segments;
		bxx := (real (j-1)*x1 + real (i+1)*x2) / real segments;
		byy := (real (j-1)*y1 + real (i+1)*y2) / real segments;
		clawline(img, o, w, ax, ay, bxx, byy, (thickw-1)/2, palette[0]);
		clawline(img, o, w, ax, ay, bxx, byy, (thickw-3)/2, palette[14]);
	}
	if(talon){
		if(y1 < y2)
			drawtip(img, o, w, int x1, int y1, tip7, tip7m, tip7f, tip7fm);
		else
			drawtip(img, o, w, int x1, int y1, tip8, tip8m, tip8f, tip8fm);
	}
}

drawclaws(img: ref Image, o: Point, w, h: int)
{
	cd := claws_down;
	cu := 1.0 - cd;
	rw := real w;
	rh := real h;
	hx := cu*0.3*rw + cd*0.4*rw;		# HAND_X
	hy := cu*(rh-125.0) + cd*rh;		# HAND_Y
	clawdraw(img, o, w, hx-30.0, hy-50.0*cu, hx-5.0, hy, 22, 4, 1);
	clawdraw(img, o, w, hx-10.0, hy-60.0*cu, hx, hy, 22, 4, 1);
	clawdraw(img, o, w, hx+10.0, hy-60.0*cu, hx, hy, 22, 4, 1);
	clawdraw(img, o, w, hx+30.0, hy-50.0*cu, hx+5.0, hy, 22, 4, 1);
	clawdraw(img, o, w, hx+25.0, hy+40.0*cu, hx+5.0, hy, 22, 4, 1);
	clawdraw(img, o, w, hx, hy, 6.0*rw/20.0, rh, 38, 5, 0);
}

# ---------- frame ----------

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	scrw = w;
	scrh = h;
	scx = w/2;
	scy = h/2;
	buildmat();

	t0f := sys->millisec();
	crashed := game_tf > 0.0 && fish_left > 0;
	if(crashed)
		img.draw(img.r, palette[0], nil, Point(0, 0));
	else{
		drawhorizon(img, o, w, h);
		drawterrain(img, o);
		drawbirds(img, o);
	}

	nowsec := real sys->millisec() / 1000.0;
	tt := nowsec - game_t0;
	if(game_tf > 0.0)
		tt = game_tf - game_t0;

	if(font != nil){
		if(game_tf > 0.0){
			if(blink_on)
				img.text(Point(o.x+(w-9*8)/2, o.y+(h-8)/2),
					palette[4], Point(0, 0), font, "Game Over");
		}else if(tt < 5.0 && blink_on)
			img.text(Point(o.x+(w-13*8)/2, o.y+(h-8)/2-4*8),
				palette[15], Point(0, 0), font, "Catch 10 Fish");
	}

	# crosshair (thick 2), white after a crash, and HUD in the same colour
	hcol := palette[0];
	if(crashed)
		hcol = palette[15];
	img.line(Point(o.x+scx-5, o.y+scy), Point(o.x+scx+5, o.y+scy),
		Draw->Endsquare, Draw->Endsquare, 1, hcol, Point(0, 0));
	img.line(Point(o.x+scx, o.y+scy-5), Point(o.x+scx, o.y+scy+5),
		Draw->Endsquare, Draw->Endsquare, 1, hcol, Point(0, 0));

	if(font != nil){
		el := BIGELEV;
		xx := int math->floor(wx / real MS);
		yy := int math->floor(wy / real MS);
		if(xx >= 0 && xx < MAPW && yy >= 0 && yy < MAPH)
			el = elev[yy*MAPW+xx];
		hh := int wz - el;
		l1: string;
		if(invert_pitch)
			l1 = sys->sprint("Pitch:%5.1f Roll:%5.1f Heading:%5.1f Height:%5d [Core Strip:%3d]",
				pitch*180.0/PI, wrap(roll+PI)*180.0/PI,
				wrap0(heading+PI)*180.0/PI, hh, rad);
		else
			l1 = sys->sprint("Pitch:%5.1f Roll:%5.1f Heading:%5.1f Height:%5d [Core Strip:%3d]",
				pitch*180.0/PI, roll*180.0/PI, heading*180.0/PI, hh, rad);
		img.text(Point(o.x, o.y), hcol, Point(0, 0), font, l1);
		l2 := sys->sprint("Fish Remaining:%d Time:%3.2f Best:%3.2f",
			fish_left, tt, best_score);
		img.text(Point(o.x, o.y+8), hcol, Point(0, 0), font, l2);
	}

	# claws last: the original blits main_dc then draws ClawsDraw over it
	if(claws_down != 0.0)
		drawclaws(img, o, w, h);

	img.flush(Draw->Flushnow);

	# adapt the view radius to the frame budget, as the original adapted
	# its multicore strip_height
	if(!crashed){
		spent := sys->millisec() - t0f;
		if(spent > 22 && rad > 24)
			rad = rad * 9 / 10;
		else if(spent < 12 && rad < 120)
			rad = rad * 21 / 20 + 1;
	}
}

# ---------- assets / misc ----------

flipimage(d: ref Display, src: ref Image): ref Image
{
	# horizontal mirror for the DCF_SYMMETRY claw arm
	if(src == nil)
		return nil;
	sw := src.r.dx();
	sh := src.r.dy();
	n := d.newimage(Rect((0, 0), (sw, sh)), src.chans, 0, 0);
	if(n == nil)
		return nil;
	for(x := 0; x < sw; x++)
		n.draw(Rect((sw-1-x, 0), (sw-x, sh)), src, nil,
			Point(src.r.min.x+x, src.r.min.y));
	return n;
}

loadmesh(path: string): ref Mesh
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[65536] of byte;
	n := 0;
	for(;;){
		r := sys->read(fd, buf[n:], len buf - n);
		if(r <= 0)
			break;
		n += r;
		if(n == len buf){
			nb := array[2*len buf] of byte;
			nb[0:] = buf[0:n];
			buf = nb;
		}
	}
	if(n <= 0)
		return nil;
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	if(lines == nil)
		return nil;
	(nil, hdr) := sys->tokenize(hd lines, " \t");
	if(len hdr != 3 || hd hdr != "mesh")
		return nil;
	nv := int hd tl hdr;
	nf := int hd tl tl hdr;
	m := ref Mesh(array[nv] of real, array[nv] of real, array[nv] of real,
		array[nf] of Tri3);
	vi := 0;
	fi := 0;
	for(lines = tl lines; lines != nil; lines = tl lines){
		(nil, t) := sys->tokenize(hd lines, " \t\r");
		if(t == nil)
			continue;
		if(hd t == "v" && len t == 4 && vi < nv){
			t = tl t;
			m.vx[vi] = real int hd t; t = tl t;
			m.vy[vi] = real int hd t; t = tl t;
			m.vz[vi] = real int hd t;
			vi++;
		}else if(hd t == "f" && len t == 5 && fi < nf){
			t = tl t;
			c := int hd t; t = tl t;
			a := int hd t; t = tl t;
			b := int hd t; t = tl t;
			m.t[fi] = Tri3(c, a, b, int hd t);
			fi++;
		}
	}
	if(vi != nv || fi != nf)
		return nil;
	return m;
}

songtask()
{
	# SongTask's looped melody, original Play() strings
	for(;;){
		tone->play("5eCGFsD4A5e.C4sG5eGDqCDeGsGG4qG");
		tone->play("5eCGFsD4A5e.C4sG5eGDqCDeGsGG4qG");
		tone->play("5eGECGC4A5FCsC4B5C4B5e.GsG4qGB");
		tone->play("5eGECGC4A5FCsC4B5C4B5e.GsG4qGB");
	}
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
