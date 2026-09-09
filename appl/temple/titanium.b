implement Titanium;

# TempleOS Apps/Titanium/Titanium.HC — ground-war gun-platform game.
# You fly a gun platform up a wrapping 4096-pixel battlefield over a ground
# war between 512 enemy and 128 friendly infantry/tanks fighting hand-to-hand.
# Scoring: +3 enemy killed, +5 enemy killed by a friendly, -100 friendly fire,
# -1 per bullet, -10 per second, +250 per surviving friendly at game over.
# Original main loop runs at 100Hz (SleepUntil jiffies+10ms) with an 8-phase
# work scheduler; we tick logic passes at the same 10ms and redraw at ~30fps
# like the TempleOS winmgr.
#
# Keys: Left/Right sweep the gun (+-15 degrees, strafe +-2), hold Space for
# autofire, z/x fire the left/right wing missiles, Enter restarts, Esc/q quits.
#
# GAP: no TempleOS pull-down menu; Ctrl+Left/Ctrl+Right missiles are keys
#      z and x here (Inferno's kbd gives no Ctrl+arrow distinction).
# GAP: unit walk cycles use the 4 mesh keyframes at the original rates and
#      16 quantized facing angles; SpriteInterpolate's sub-frame vertex lerp
#      and per-frame continuous yaw are not applied.

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

include "scorestore.m";
	scorestore: Scorestore;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Titanium: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 10;
# The most substeps one frame may run: enough to cover a frame of
# real time at this step, with headroom.  A fixed cap is wrong -
# four substeps covers 40ms at FCSTEP 10 and only 4ms at FCSTEP 1.
FCMAX: con 2 + 20/FCSTEP;
fcacc := 0;

MAPH: con 4096;
BLEN: con 10;
BSPD: con 5.0;
BNUM: con 128;
PHG: con 8;			# PHASES_GROUPS
HACKD: con 5;
UENEMY: con PHG*64;		# 512
UFRIEND: con PHG*16;		# 128
UNUM: con UFRIEND+UENEMY;
ETMAN, ETTANK, ETMISSILE, ETBUILDING: con iota;
ENUM: con 512;
LSAPTS: con 20;
LSMTNS: con 3;
LSNUM: con 128;
LSTYPES: con 4;
NDIR: con 16;			# quantized unit facing angles
INTMAX: con 2147483647;

# TempleOS 16-color palette indices
BLACK, BLUE, GREEN, CYAN, RED, PURPLE, BROWN, LTGRAY,
DKGRAY, LTBLUE, LTGREEN, LTCYAN, LTRED, LTPURPLE, YELLOW, WHITE: con iota;

Bullet: adt {
	x, y: real;		# original keeps these <<32 fixed point
	dx2, dy2: real;		# per-pass velocity
	sdx, sdy: real;		# Sin(a)/Cos(a) of the flight angle (Terry's dx/dy)
	ang: real;		# flight angle a = Arg(dx2,dy2)
	live, missile: int;
};

Unit: adt {
	x, y: int;		# map coordinates (y wraps mod MAPH)
	bestdd: int;
	ang, phase: real;
	friendly, dead, tank, cia: int;
};

Expl: adt {
	x, y: int;		# map coordinates
	num, etype: int;
	t0, tf: real;
	live: int;
};

Lsitem: adt { x, y, img: int; };

Tri: adt { colour, a, b, c: int; };
Mesh: adt { vx, vy, vz: array of real; f: array of Tri; };
Cell: adt { img, mask: ref Image; };

PHINTRO, PHPLAY, PHOVER: con iota;

win: ref Window;
disp: ref Display;
pal: array of ref Image;
white: ref Image;
dither: ref Image;
tfont: ref Font;
have_tone := 0;

# bitmap sprites by bin: 1 gun, 2 flying missile, 3 mounted missile,
# 20/21 trees, 22 mountain, 23 apartment
lsimg, lsmask: array of ref Image;		# [4] bins 20..23
gunimg, gunmask: array of ref Image;		# [3] tilts -105/-90/-75 deg
mntimg, mntmask: array of ref Image;		# mounted missile, same tilts
flyimg, flymask: array of ref Image;		# flying missile, same angles
rotang := array[] of {-105.0, -90.0, -75.0};	# degrees

meshes: array of ref Mesh;			# [16] bins 4..19
cells: array of array of ref Cell;		# [16][NDIR]

# walk-cycle image sets (bin numbers), straight from the original
frset := array[] of {5, 4, 5, 6};		# friendly_imgs
ciaset := array[] of {8, 7, 8, 9};		# CIA imgs (blinked in)
fhset := array[] of {10, 11, 10, 12};		# friendly_hacking_imgs
enset := array[] of {14, 13, 14, 15};		# enemy_imgs
ehset := array[] of {17, 16, 17, 18};		# enemy_hacking_imgs

bullets: array of Bullet;
units: array of Unit;
expl: array of Expl;
ls: array of Lsitem;

px, py, pdx: int;
th: real;			# gun angle, -pi/2 is straight up
finishline: int;
t0s, tfs: real;
sndgate := 0;			# millisec until which sounds are gated
bulletsfired, missilebmp: int;
totalscore, friendlyfire, enemybyfriendly, friendlyleft, enemyleft: int;
mainpass: int;
gameover: int;
bestscore := 0;
gun_on, left_down, right_down: int;

gphase := PHINTRO;
passepoch := 0;
lastdraw := 0;
overphase, overnext, overkey: int;

lcgseed := 0;

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

	win = wmclient->window(ctxt, "TempleOS Titanium", Wmclient->Appl);
	disp = win.display;
	loadpalette();
	tfont = Font.open(disp, "/fonts/lucida/unicode.8.font");
	loadart();

	bullets = array[BNUM] of Bullet;
	units = array[UNUM] of Unit;
	expl = array[ENUM] of Expl;
	ls = array[LSNUM] of Lsitem;
	if(scorestore != nil)
		bestscore = scorestore->loadint("titanium", bestscore);
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);
	gphase = PHINTRO;

	ticks := chan of int;
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
		keydown(k);
	dtms := <-ticks =>
		fcacc += dtms;
		if(fcacc > FCSTEP*FCMAX)
			fcacc = FCSTEP*FCMAX;
		for(fcn := 0; fcacc >= FCSTEP && fcn < FCMAX; fcn++){
			tick();
			fcacc -= FCSTEP;
		}
	}
}

loadpalette()
{
	# the exact TempleOS 16 colors, index = TempleOS color
	rgba := grpal->values();
	pal = array[16] of ref Image;
	for(i := 0; i < 16; i++)
		pal[i] = disp.color(rgba[i]);
	white = pal[WHITE];
	# 50% BROWN/YELLOW dither: the original clears the screen with
	# ROPF_DITHER|BROWN<<16|YELLOW - a tan desert checkerboard.
	dither = disp.newimage(Rect((0, 0), (2, 2)), Draw->RGB24, 1, Draw->Black);
	if(dither != nil){
		# RGB24 rows are b,g,r per pixel: brown AA5500, yellow FFFF55
		buf := array[] of {
			byte 16r00, byte 16r55, byte 16rAA,  byte 16r55, byte 16rFF, byte 16rFF,
			byte 16r55, byte 16rFF, byte 16rFF,  byte 16r00, byte 16r55, byte 16rAA
		};
		dither.writepixels(dither.r, buf);
	}
}

loadbit(n: int): (ref Image, ref Image)
{
	img := disp.open(sys->sprint("/icons/temple/titanium_%d.bit", n));
	msk := disp.open(sys->sprint("/icons/temple/titanium_%d.mask", n));
	return (img, msk);
}

loadart()
{
	lsimg = array[4] of ref Image;
	lsmask = array[4] of ref Image;
	for(i := 0; i < 4; i++)
		(lsimg[i], lsmask[i]) = loadbit(20+i);
	# The gun (bin 1) and missiles (bins 2, 3) are drawn by the original
	# through Sprite3ZB rotated by the gun angle, which only ever takes
	# -90 and -90+-15 degrees; pre-render those three rotations.
	gunimg = array[3] of ref Image;
	gunmask = array[3] of ref Image;
	mntimg = array[3] of ref Image;
	mntmask = array[3] of ref Image;
	flyimg = array[3] of ref Image;
	flymask = array[3] of ref Image;
	(g, gm) := loadbit(1);
	(m2, m2m) := loadbit(2);
	(m3, m3m) := loadbit(3);
	for(i = 0; i < 3; i++){
		a := rotang[i]*Math->Pi/180.0;
		(gunimg[i], gunmask[i]) = rotspr(g, gm, a);
		(mntimg[i], mntmask[i]) = rotspr(m3, m3m, a);
		(flyimg[i], flymask[i]) = rotspr(m2, m2m, a);
	}
	meshes = array[16] of ref Mesh;
	for(i = 0; i < 16; i++)
		meshes[i] = loadmesh(sys->sprint("/icons/temple/titanium_%d.mesh", i+4));
	cells = array[16] of array of ref Cell;
	for(i = 0; i < 16; i++)
		cells[i] = array[NDIR] of ref Cell;
}

# rotate a bitmap sprite (with its k1 mask) by ang around the sprite origin,
# matching TempleOS Sprite3ZB. Screen coords, y down.
rotspr(img, msk: ref Image, ang: real): (ref Image, ref Image)
{
	if(img == nil)
		return (nil, nil);
	sw := img.r.dx();
	sh := img.r.dy();
	pix := array[sw*sh] of byte;
	if(img.readpixels(img.r, pix) < 0)
		return (nil, nil);
	cov := array[sw*sh] of { * => byte 255 };
	if(msk != nil){
		tmp := disp.newimage(img.r, Draw->GREY8, 0, Draw->Black);
		if(tmp != nil){
			tmp.draw(img.r, white, msk, img.r.min);
			tmp.readpixels(img.r, cov);
		}
	}
	c := math->cos(ang);
	s := math->sin(ang);
	minx := miny := 16r7fffffff;
	maxx := maxy := -16r7fffffff;
	for(cy := 0; cy < 2; cy++) for(cx := 0; cx < 2; cx++){
		x := real img.r.min.x;
		if(cx)
			x = real img.r.max.x;
		y := real img.r.min.y;
		if(cy)
			y = real img.r.max.y;
		fx := int math->floor(x*c - y*s);
		fy := int math->floor(x*s + y*c);
		if(fx < minx) minx = fx;
		if(fx+1 > maxx) maxx = fx+1;
		if(fy < miny) miny = fy;
		if(fy+1 > maxy) maxy = fy+1;
	}
	dr := Rect((minx-1, miny-1), (maxx+1, maxy+1));
	dw := dr.dx();
	dh := dr.dy();
	dpix := array[dw*dh] of { * => byte 0 };
	dcov := array[dw*dh] of { * => byte 0 };
	for(dy := 0; dy < dh; dy++) for(dx := 0; dx < dw; dx++){
		xx := real (dr.min.x+dx);
		yy := real (dr.min.y+dy);
		sx := int (xx*c + yy*s);	# inverse rotation; int rounds
		sy := int (-xx*s + yy*c);
		if(sx < img.r.min.x || sx >= img.r.max.x || sy < img.r.min.y || sy >= img.r.max.y)
			continue;
		si := (sy-img.r.min.y)*sw + (sx-img.r.min.x);
		if(int cov[si] > 127){
			dpix[dy*dw+dx] = pix[si];
			dcov[dy*dw+dx] = byte 255;
		}
	}
	nimg := disp.newimage(dr, Draw->CMAP8, 0, Draw->Black);
	nmask := disp.newimage(dr, Draw->GREY8, 0, Draw->Black);
	if(nimg == nil || nmask == nil)
		return (nil, nil);
	nimg.writepixels(dr, dpix);
	nmask.writepixels(dr, dcov);
	return (nimg, nmask);
}

loadmesh(path: string): ref Mesh
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[65536] of byte;
	n := 0;
	for(;;){
		m := sys->read(fd, buf[n:], len buf - n);
		if(m <= 0)
			break;
		n += m;
	}
	if(n <= 0)
		return nil;
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	if(lines == nil)
		return nil;
	(nil, h) := sys->tokenize(hd lines, " \t");
	if(len h != 3 || hd h != "mesh")
		return nil;
	nv := int hd tl h;
	nf := int hd tl tl h;
	m := ref Mesh(array[nv] of real, array[nv] of real, array[nv] of real, array[nf] of Tri);
	vi := fi := 0;
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
			d := int hd t;
			if(a < nv && b < nv && d < nv)
				m.f[fi++] = Tri(c, a, b, d);
		}
	}
	if(vi != nv || fi != nf)
		return nil;
	return m;
}

# render one unit mesh at one of NDIR facings, per the original's
# Sprite3Mat4x4B(RotY(facing), RotX(pi/6), Scale(0.3)) pipeline,
# painter-sorted instead of depth-buffered.
buildcell(mi, dir: int): ref Cell
{
	m := meshes[mi-4];
	if(m == nil)
		return nil;
	a := real dir * 2.0*Math->Pi/real NDIR;
	ca := math->cos(a);
	sa := math->sin(a);
	cb := math->cos(Math->Pi/6.0);
	sb := math->sin(Math->Pi/6.0);
	nv := len m.vx;
	xs := array[nv] of int;
	ys := array[nv] of int;
	zs := array[nv] of real;
	minx := miny := 16r7fffffff;
	maxx := maxy := -16r7fffffff;
	for(i := 0; i < nv; i++){
		lx := m.vx[i]*ca + m.vz[i]*sa;
		lz := -m.vx[i]*sa + m.vz[i]*ca;
		ly := m.vy[i];
		wy := ly*cb - lz*sb;
		wz := ly*sb + lz*cb;
		xs[i] = int (0.3*lx);
		ys[i] = int (0.3*wy);
		zs[i] = 0.3*wz;
		if(xs[i] < minx) minx = xs[i];
		if(xs[i] > maxx) maxx = xs[i];
		if(ys[i] < miny) miny = ys[i];
		if(ys[i] > maxy) maxy = ys[i];
	}
	dr := Rect((minx-1, miny-1), (maxx+2, maxy+2));
	cimg := disp.newimage(dr, Draw->RGB24, 0, Draw->Black);
	cmask := disp.newimage(dr, Draw->GREY1, 0, Draw->Black);
	if(cimg == nil || cmask == nil)
		return nil;
	nf := len m.f;
	ord := array[nf] of int;
	key := array[nf] of real;
	for(i = 0; i < nf; i++){
		ord[i] = i;
		key[i] = zs[m.f[i].a] + zs[m.f[i].b] + zs[m.f[i].c];
	}
	# far-to-near: +z runs away from the viewer (x right, y down)
	for(i = 0; i < nf; i++){
		bi := i;
		for(j := i+1; j < nf; j++)
			if(key[ord[j]] > key[ord[bi]])
				bi = j;
		(ord[i], ord[bi]) = (ord[bi], ord[i]);
	}
	pts := array[3] of Point;
	for(i = 0; i < nf; i++){
		f := m.f[ord[i]];
		pts[0] = Point(xs[f.a], ys[f.a]);
		pts[1] = Point(xs[f.b], ys[f.b]);
		pts[2] = Point(xs[f.c], ys[f.c]);
		cimg.fillpoly(pts, ~0, pal[f.colour & 15], Point(0, 0));
		cmask.fillpoly(pts, ~0, white, Point(0, 0));
	}
	return ref Cell(cimg, cmask);
}

getcell(mi, dir: int): ref Cell
{
	if(mi < 4 || mi > 19)
		return nil;
	if(cells[mi-4][dir] == nil)
		cells[mi-4][dir] = buildcell(mi, dir);
	return cells[mi-4][dir];
}

now(): real
{
	return real sys->millisec() / 1000.0;
}

blinkon(): int
{
	return (sys->millisec()/250) & 1;
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

# deterministic per-explosion random stream, standing in for Seed(n)/Rand
sdseed(n: int)
{
	lcgseed = n;
}

sdrand(): real
{
	lcgseed = (lcgseed*1103515245 + 12345) & 16r7fffffff;
	return real lcgseed / 2147483648.0;
}

# Snd(ona): freq = 440*2^((ona-60)/12)
onafreq(ona: int): int
{
	return int (440.0 * math->pow(2.0, real (ona-60) / 12.0));
}

sndona(ona, ms, gatems: int)
{
	t := sys->millisec();
	if(t < sndgate)
		return;
	sndgate = t + gatems;
	if(have_tone)
		tone->beep(onafreq(ona), ms);
}

dims(): (int, int)
{
	img := win.image;
	if(img == nil)
		return (640, 480);
	return (img.r.dx(), img.r.dy());
}

initgame()
{
	(w, h) := dims();
	totalscore = 0;
	gameover = 0;
	mainpass = 0;
	px = w/2;
	py = int (0.9*real h);
	finishline = MAPH-100 + py;
	pdx = 0;
	th = -Math->Pi/2.0;
	gun_on = 0;

	for(i := 0; i < LSNUM; i++){
		ls[i].x = rn(w-100) + 50;
		ls[i].y = rn(MAPH-100) + 50;
		ls[i].img = rn(LSTYPES-2);		# trees/bushes
	}
	for(i = 0; i < LSAPTS; i++)
		ls[i].img = LSTYPES-1;			# apartments
	for(; i < LSAPTS+LSMTNS; i++)
		ls[i].img = LSTYPES-2;			# mountains

	xx := yy := 0;
	for(i = 0; i < UNUM; i++){
		u := ref units[i];
		if(i < UFRIEND){
			u.friendly = 1;
			if((i&7) == 0){			# squads of 8
				xx = rn(w-200);
				yy = rn(MAPH-200);
			}
			u.cia = (i&63) == 0;		# every 64th a CIA agent
			u.tank = 0;
		}else{
			u.friendly = 0;
			if((i&31) == 0){		# platoons of 32
				xx = rn(w-200);
				yy = rn(MAPH-200);
			}
			u.tank = (i&15) == 0;		# every 16th a tank
			u.cia = 0;
		}
		u.dead = 0;
		u.x = xx + rn(129)-64 + 100;
		u.y = yy + rn(129)-64 + 100;
		u.bestdd = INTMAX;
		u.ang = Math->Pi/2.0;
		u.phase = 2.0*Math->Pi*real rn(1024) / 1024.0;
		units[i] = *u;
	}
	for(i = 0; i < BNUM; i++)
		bullets[i].live = 0;
	for(i = 0; i < ENUM; i++){
		expl[i].live = 0;
		expl[i].num = i;
	}
	friendlyleft = UFRIEND;
	enemyleft = UENEMY;
	enemybyfriendly = 0;
	bulletsfired = 0;
	missilebmp = 15;
	friendlyfire = 0;
	t0s = now();
	tfs = 0.0;
	passepoch = sys->millisec();
}

explosionnew(x, y: int): int
{
	for(i := 0; i < ENUM; i++)
		if(!expl[i].live){
			expl[i].x = x;
			expl[i].y = y;
			expl[i].live = 1;
			return i;
		}
	return -1;
}

mandie(i: int, byhuman: int)
{
	u := ref units[i];
	u.dead = 1;
	if(byhuman){
		e := explosionnew(u.x, u.y);
		if(e >= 0){
			expl[e].t0 = now();
			if(u.tank){
				expl[e].etype = ETTANK;
				expl[e].tf = expl[e].t0 + 0.40;
			}else{
				expl[e].etype = ETMAN;
				expl[e].tf = expl[e].t0 + 0.20;
			}
		}
	}
	if(u.friendly){
		friendlyleft--;
		if(byhuman)
			friendlyfire++;
	}else{
		enemyleft--;
		if(!byhuman)
			enemybyfriendly++;
	}
	units[i] = *u;
	if(byhuman){
		if(u.friendly)
			sndona(46, 12, 10);	# Snd(46) friendly kill
		else
			sndona(22, 12, 10);	# Snd(22) enemy kill
	}
}

explosiondo(x, y, scrolly: int)
{
	e := explosionnew(x, y+scrolly);
	if(e >= 0){
		expl[e].t0 = now();
		expl[e].etype = ETMISSILE;
		expl[e].tf = expl[e].t0 + 1.0;
	}
	for(i := 0; i < UNUM; i++){
		if(units[i].dead)
			continue;
		x2 := units[i].x;
		y2 := (units[i].y - scrolly) & (MAPH-1);
		if((x-x2)*(x-x2) + (y-y2)*(y-y2) < 100*100)
			mandie(i, 1);
	}
	for(i = 0; i < LSAPTS; i++){
		x2 := ls[i].x;
		y2 := (ls[i].y - scrolly) & (MAPH-1);
		if((x-x2)*(x-x2) + (y-y2)*(y-y2) < 100*100){
			e = explosionnew(x2, y2+scrolly);
			if(e >= 0){
				expl[e].t0 = now();
				expl[e].etype = ETBUILDING;
				expl[e].tf = expl[e].t0 + 2.0;
			}
		}
	}
}

firebullet()
{
	for(i := 0; i < BNUM-1; i++)
		if(!bullets[i].live)
			break;
	b := ref bullets[i];
	b.x = real px + 28.0*math->cos(th);
	b.y = real py + 28.0*math->sin(th);
	b.dx2 = BSPD*math->cos(th) + real pdx;
	b.dy2 = BSPD*math->sin(th);
	a := math->atan2(b.dy2, b.dx2);
	b.ang = a;
	b.sdx = math->sin(a);
	b.sdy = math->cos(a);
	bulletsfired++;
	b.live = 1;
	b.missile = 0;
	bullets[i] = *b;
	sndona(74, 8, 1);		# Snd(74) fire tone, ~instant gate
}

# n = -1 left wing pair (bits 0,1), 1 right wing pair (bits 2,3)
firemissile(n: int)
{
	m := n;
	got := -1;
	for(k := 0; k < 2 && got < 0; k++){
		m++;
		if(missilebmp & (1<<m)){
			missilebmp &= ~(1<<m);
			got = m;
		}
	}
	if(got < 0)
		return;
	for(i := 0; i < BNUM-1; i++)
		if(!bullets[i].live)
			break;
	b := ref bullets[i];
	(mx, my) := missilepos(got);
	b.x = real mx;
	b.y = real my;
	b.dx2 = BSPD*math->cos(th) + real pdx;
	b.dy2 = BSPD*math->sin(th);
	a := math->atan2(b.dy2, b.dx2);
	b.ang = a;
	b.sdx = math->sin(a);
	b.sdy = math->cos(a);
	b.live = 1;
	b.missile = 1;
	bullets[i] = *b;
	sndona(74, 8, 1);
}

missilepos(m: int): (int, int)
{
	n := 1;
	if(m < 2)
		n = -1;
	dist := real (15 - 8*(m&1));
	a := th - real n * Math->Pi/2.0;
	mx := int (real px + 3.0*math->cos(th) - dist*math->cos(a));
	my := int (real py + 3.0*math->sin(th) - dist*math->sin(a));
	return (mx, my);
}

menmove(g: int)
{
	for(i := g; i < UFRIEND; i += PHG){
		if(units[i].dead)
			continue;
		best := UFRIEND;
		bestdd := INTMAX;
		for(j := UFRIEND; j < UNUM; j++){
			if(units[j].dead)
				continue;
			ddx := units[i].x - units[j].x;
			ddy := units[i].y - units[j].y;
			dd := ddx*ddx + ddy*ddy;
			if(dd < bestdd){
				bestdd = dd;
				best = j;
			}
		}
		units[i].bestdd = bestdd;
		if(bestdd != INTMAX){
			units[i].x += 4*sign(units[best].x - units[i].x);
			units[i].y += 4*sign(units[best].y - units[i].y);
			units[i].ang = math->atan2(real (units[best].y - units[i].y),
				real (units[best].x - units[i].x));
		}
	}
	for(i = UFRIEND+g; i < UNUM; i += PHG){
		if(units[i].dead)
			continue;
		best := 0;
		bestdd := INTMAX;
		for(j := 0; j < UFRIEND; j++){
			if(units[j].dead)
				continue;
			ddx := units[i].x - units[j].x;
			ddy := units[i].y - units[j].y;
			dd := ddx*ddx + ddy*ddy;
			if(dd < bestdd){
				bestdd = dd;
				best = j;
			}
		}
		units[i].bestdd = bestdd;
		if(bestdd != INTMAX){
			units[i].x += 4*sign(units[best].x - units[i].x);
			units[i].y += 4*sign(units[best].y - units[i].y);
			units[i].ang = math->atan2(real (units[best].y - units[i].y),
				real (units[best].x - units[i].x));
		}
	}
}

menfight(g: int)
{
	# original quirk kept: only foes with y difference < 8 are candidates
	for(i := g; i < UFRIEND; i += PHG){
		if(units[i].dead)
			continue;
		best := UFRIEND;
		bestdd := INTMAX;
		for(j := UFRIEND; j < UNUM; j++){
			if(units[j].dead || units[i].y - units[j].y >= 8)
				continue;
			ddx := units[i].x - units[j].x;
			ddy := units[i].y - units[j].y;
			dd := ddx*ddx + ddy*ddy;
			if(dd < bestdd){
				bestdd = dd;
				best = j;
			}
		}
		units[i].bestdd = bestdd;
		if(bestdd < HACKD*HACKD && rn(2) == 0)
			mandie(best, 0);
	}
	for(i = UFRIEND+g; i < UNUM; i += PHG){
		if(units[i].dead)
			continue;
		best := 0;
		bestdd := INTMAX;
		for(j := 0; j < UFRIEND; j++){
			if(units[j].dead || units[i].y - units[j].y >= 8)
				continue;
			ddx := units[i].x - units[j].x;
			ddy := units[i].y - units[j].y;
			dd := ddx*ddx + ddy*ddy;
			if(dd < bestdd){
				bestdd = dd;
				best = j;
			}
		}
		units[i].bestdd = bestdd;
		if(bestdd < HACKD*HACKD && rn(2) == 0)
			mandie(best, 0);
	}
}

sign(x: int): int
{
	if(x > 0)
		return 1;
	if(x < 0)
		return -1;
	return 0;
}

# does the segment (x1,y1)-(x2,y2) touch the axis rect [rx0,rx1]x[ry0,ry1]?
seghit(x1, y1, x2, y2: real, rx0, ry0, rx1, ry1: real): int
{
	tmin := 0.0;
	tmax := 1.0;
	dx := x2-x1;
	dy := y2-y1;
	for(e := 0; e < 4; e++){
		p, q: real;
		case e {
		0 =>	p = -dx; q = x1 - rx0;
		1 =>	p = dx; q = rx1 - x1;
		2 =>	p = -dy; q = y1 - ry0;
		* =>	p = dy; q = ry1 - y1;
		}
		if(p == 0.0){
			if(q < 0.0)
				return 0;
			continue;
		}
		t := q/p;
		if(p < 0.0){
			if(t > tmax)
				return 0;
			if(t > tmin)
				tmin = t;
		}else{
			if(t < tmin)
				return 0;
			if(t < tmax)
				tmax = t;
		}
	}
	return 1;
}

checkcollisions()
{
	(w, h) := dims();
	scrolly := int (real (MAPH-100) - 100.0*(now()-t0s));
	# Bullets: the original redraws each bullet's line with ROP_COLLISION
	# against a 6x8 rect at (x-3,y-9) per on-screen unit; geometrically the
	# same segment/rect test.  Note the original extends the collision line
	# by (dx,dy)=(Sin a,Cos a) - the axes swapped relative to the drawn
	# line - and never kills the bullet: bullets mow through whole squads.
	for(i := 0; i < UNUM; i++){
		if(units[i].dead)
			continue;
		x := units[i].x;
		y := (units[i].y - scrolly) & (MAPH-1);
		if(x < 0 || x >= w || y < 0 || y >= h)
			continue;
		for(j := 0; j < BNUM; j++){
			if(!bullets[j].live || bullets[j].missile)
				continue;
			b := bullets[j];
			if(seghit(b.x, b.y, b.x + b.sdx*real BLEN, b.y + b.sdy*real BLEN,
			   real (x-3), real (y-9), real (x+3), real (y-1))){
				mandie(i, 1);
				break;
			}
		}
	}
	# Missiles: taxicab boxes, 16 for tanks, 6 for men
	for(j := 0; j < BNUM; j++){
		if(!bullets[j].live || !bullets[j].missile)
			continue;
		x := int bullets[j].x;
		y := int bullets[j].y;
		for(i = 0; i < UNUM && bullets[j].live; i++){
			n1 := 6;
			if(units[i].tank)
				n1 = 16;
			if(units[i].dead)
				continue;
			uy := (units[i].y - scrolly) & (MAPH-1);
			if(abs(x - units[i].x - n1) + abs(y - uy + n1) < n1*2){
				bullets[j].live = 0;
				explosiondo(x, y, scrolly);
			}
		}
		if(bullets[j].live)
			for(i = 0; i < LSAPTS; i++){
				ly := (ls[i].y - scrolly) & (MAPH-1);
				if(2*(x-ls[i].x)*(x-ls[i].x) + 3*(y+35-ly)*(y+35-ly) < 2*60*60){
					bullets[j].live = 0;
					explosiondo(x, y, scrolly);
					break;
				}
			}
	}
}

abs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}

# one 10ms pass of the original 100Hz main loop
dopass()
{
	(w, h) := dims();
	for(i := 0; i < BNUM; i++){
		if(!bullets[i].live)
			continue;
		bullets[i].x += bullets[i].dx2;
		bullets[i].y += bullets[i].dy2;
		if(bullets[i].y < 0.0 || bullets[i].x < 0.0 ||
		   int bullets[i].x >= w || int bullets[i].y >= h)
			bullets[i].live = 0;
	}
	pdx = 0;
	if(left_down){
		th = -Math->Pi/2.0 - 15.0*Math->Pi/180.0;
		pdx = -2;
	}else if(right_down){
		th = -Math->Pi/2.0 + 15.0*Math->Pi/180.0;
		pdx = 2;
	}
	px += pdx;
	while(px >= w)
		px -= w;
	while(px < 0)
		px += w;

	# the original's 8-phase work scheduler
	case mainpass & 7 {
	0 =>
		g := (mainpass>>3) & 7;
		grp := (mainpass>>4) % PHG;
		if(g == 0){
			# the platform creeps up the map; past the top is victory
			py--;
			if(py < 20)
				gameover = 1;
		}
		if((g&1) == 0)
			menfight(grp);
		else
			menmove(grp);
	2 or 6 =>
		if(gun_on)
			firebullet();
	1 or 3 or 5 or 7 =>
		checkcollisions();
	* =>
		;	# pass 4 idles
	}
	mainpass++;

	totalscore = 3*(UENEMY-enemyleft) + 5*enemybyfriendly
		- 100*friendlyfire - int (10.0*(now()-t0s)) - bulletsfired;
	if(!enemyleft || !friendlyleft)
		gameover = 1;
}

tick()
{
	t := sys->millisec();
	case gphase {
	PHPLAY =>
		target := (t - passepoch) / 10;
		if(target > mainpass+40){
			# fell badly behind; drop the lost passes
			passepoch = t - (mainpass+40)*10;
			target = mainpass+40;
		}
		while(mainpass < target && !gameover)
			dopass();
		if(gameover){
			gphase = PHOVER;
			tfs = now();
			gun_on = 0;
			overphase = 0;
			overnext = t + 750;
			overkey = 0;
			if(have_tone)
				tone->stop();
		}
	PHOVER =>
		case overphase {
		0 =>
			if(t >= overnext){
				overphase = 1;
				overnext = t;
			}
		1 =>
			# survivors counted up one by one, +250 apiece, Snd(86)
			if(t >= overnext){
				if((!overkey && friendlyleft > 0) || now()-tfs < 1.5){
					totalscore += 250;
					friendlyleft--;
					if(have_tone)
						tone->beep(onafreq(86), 150);
					overnext = t + 200;
				}else{
					totalscore += 250*friendlyleft;
					if(totalscore > bestscore){
						bestscore = totalscore;
						if(scorestore != nil)
							scorestore->saveint("titanium", bestscore);
					}
					overphase = 2;
					if(overkey)
						restart();
				}
			}
		* =>
			;	# waiting for a key
		}
	* =>
		;	# intro: static
	}
	if(t - lastdraw >= 30){
		lastdraw = t;
		redraw();
	}
}

restart()
{
	gun_on = 0;
	initgame();
	gphase = PHPLAY;
}

keydown(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		if(have_tone)
			tone->stop();
		exit;
	'\n' =>
		if(gphase == PHINTRO || gphase == PHPLAY)
			restart();
		else
			overkeypress();
	' ' =>
		case gphase {
		PHINTRO =>	restart();
		PHPLAY =>	gun_on = 1;
		PHOVER =>	overkeypress();
		}
	'z' or 'Z' =>
		if(gphase == PHPLAY)
			firemissile(-1);
		else
			anykey();
	'x' or 'X' =>
		if(gphase == PHPLAY)
			firemissile(1);
		else
			anykey();
	Keyboard->Left =>
		if(gphase == PHPLAY)
			left_down = 1;
		else
			anykey();
	Keyboard->Right =>
		if(gphase == PHPLAY)
			right_down = 1;
		else
			anykey();
	Keyboard->Keyup | (Keyboard->Left & 16r7ff) =>
		left_down = 0;
		th = -Math->Pi/2.0;
	Keyboard->Keyup | (Keyboard->Right & 16r7ff) =>
		right_down = 0;
		th = -Math->Pi/2.0;
	Keyboard->Keyup | ' ' =>
		gun_on = 0;
	* =>
		if(k < Keyboard->Keyup)		# ignore other keyups
			anykey();
	}
}

anykey()
{
	case gphase {
	PHINTRO =>	restart();
	PHOVER =>	overkeypress();
	}
}

overkeypress()
{
	if(overphase < 2)
		overkey = 1;
	else
		restart();
}

# ExplosionDraw: seeded random line bursts, 4 types
drawexpl(img: ref Image, o: Point, e: ref Expl, yy: int, ts: real)
{
	t := (ts - e.t0) / (e.tf - e.t0);
	sdseed(e.num+1);
	n1, n2, n3, n4, n5: int;
	case e.etype {
	ETMAN =>	n1 = 8; n2 = 0; n3 = 0; n4 = 18; n5 = 28;
	ETTANK =>	n1 = 64; n2 = 14; n3 = 24; n4 = 60; n5 = 90;
	ETMISSILE =>	n1 = 128; n2 = 30; n3 = 60; n4 = 100; n5 = 200;
	* =>		n1 = 128; n2 = 80; n3 = 80; n4 = 200; n5 = 300;
	}
	for(i := 0; i < n1; i++){
		c := LTGRAY;
		if(i & 2){
			case e.etype {
			ETMAN =>
				if(i & 1)
					c = WHITE;
				else
					c = LTGRAY;
			ETMISSILE =>
				if(i & 1){
					if(i & 4)
						c = RED;
					else
						c = DKGRAY;
				}else
					c = YELLOW;
			ETTANK =>
				if(i & 1){
					if(i & 4)
						c = RED;
					else
						c = DKGRAY;
				}else
					c = LTRED;
			* =>
				if(i & 1){
					if(i & 4)
						c = BLACK;
					else
						c = DKGRAY;
				}else
					c = LTGRAY;
			}
		}else if(i & 1)
			c = WHITE;
		x1 := int (real e.x + real n2 * (sdrand()-0.5));
		y1 := int (real yy + real (n3/2) * sdrand());
		x2 := int (real e.x + real n4 * t * (sdrand()-0.5));
		y2 := int (real yy - real (n5/2) * t * sdrand());
		img.line(o.add((x1, y1)), o.add((x2, y2)), 0, 0, 0, pal[c], Point(0, 0));
	}
}

blit(img: ref Image, o: Point, x, y: int, spr, msk: ref Image)
{
	if(spr == nil)
		return;
	img.draw(spr.r.addpt(o.add((x, y))), spr, msk, spr.r.min);
}

comma(n: int): string
{
	neg := "";
	if(n < 0){
		neg = "-";
		n = -n;
	}
	s := sys->sprint("%d", n);
	r := "";
	for(i := len s; i > 3; i -= 3)
		r = "," + s[i-3:i] + r;
	return neg + s[0:i] + r;
}

gr(img: ref Image, o: Point, x, y, c: int, s: string)
{
	if(tfont == nil)
		return;
	img.text(o.add((x, y)), pal[c], Point(0, 0), tfont, s);
}

tiltindex(a: real): int
{
	if(a < -Math->Pi/2.0 - 0.01)
		return 0;
	if(a > -Math->Pi/2.0 + 0.01)
		return 2;
	return 1;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	if(gphase == PHINTRO){
		drawintro(img, o, w, h);
		img.flush(Draw->Flushnow);
		return;
	}
	ts := now();
	scrolly := int (real (MAPH-100) - 100.0*(ts-t0s));

	if(dither != nil)
		img.draw(img.r, dither, nil, Point(0, 0));
	else
		img.draw(img.r, pal[BROWN], nil, Point(0, 0));

	for(i := 0; i < LSNUM; i++){
		yy := (ls[i].y - scrolly) & (MAPH-1);
		if(yy <= h+32)
			blit(img, o, ls[i].x, yy, lsimg[ls[i].img], lsmask[ls[i].img]);
	}

	# the brown finish line, 3px thick
	fy := (finishline - scrolly) & (MAPH-1);
	img.line(o.add((0, fy)), o.add((w, fy)), 0, 0, 1, pal[BROWN], Point(0, 0));

	for(i = 0; i < BNUM; i++){
		if(!bullets[i].live)
			continue;
		b := bullets[i];
		if(b.missile){
			# drawn rotated by pi/2+Arg(dx,dy) = pi - flight angle
			d := Math->Pi - b.ang;
			while(d > Math->Pi)
				d -= 2.0*Math->Pi;
			bi := 0;
			bd := 1000.0;
			for(k := 0; k < 3; k++){
				dd := d - rotang[k]*Math->Pi/180.0;
				if(dd < 0.0)
					dd = -dd;
				if(dd < bd){
					bd = dd;
					bi = k;
				}
			}
			blit(img, o, int b.x, int b.y, flyimg[bi], flymask[bi]);
		}else
			img.line(o.add((int b.x, int b.y)),
				o.add((int (b.x + b.sdy*real BLEN), int (b.y + b.sdx*real BLEN))),
				0, 0, 0, pal[LTGRAY], Point(0, 0));
	}

	for(i = 0; i < ENUM; i++){
		if(!expl[i].live)
			continue;
		yy := (expl[i].y - scrolly) & (MAPH-1);
		if(yy <= h+32)
			drawexpl(img, o, ref expl[i], yy, ts);
		if(ts > expl[i].tf)
			expl[i].live = 0;
	}

	bl := blinkon();
	for(i = 0; i < UNUM; i++){
		if(units[i].dead)
			continue;
		yy := (units[i].y - scrolly) & (MAPH-1);
		if(yy > h+32)
			continue;
		u := units[i];
		mi: int;
		if(u.tank)
			mi = 19;
		else{
			iset: array of int;
			rate: real;
			if(u.bestdd < (2*HACKD)*(2*HACKD)){
				rate = 20.0;
				if(u.friendly)
					iset = fhset;
				else
					iset = ehset;
			}else{
				rate = 5.0;
				if(u.friendly){
					if(u.cia && bl)
						iset = ciaset;
					else
						iset = frset;
				}else
					iset = enset;
			}
			tt := 4.0*wrap2pi(u.phase + rate*ts)/(2.0*Math->Pi);
			mi = iset[(int tt) & 3];
		}
		dir := int (wrap2pi(u.ang) * real NDIR / (2.0*Math->Pi)) & (NDIR-1);
		cell := getcell(mi, dir);
		if(cell != nil)
			blit(img, o, u.x, yy, cell.img, cell.mask);
		else{
			c := PURPLE;
			if(u.friendly)
				c = CYAN;
			img.draw(Rect((o.x+u.x-3, o.y+yy-9), (o.x+u.x+3, o.y+yy-1)),
				pal[c], nil, Point(0, 0));
		}
	}

	ti := tiltindex(th);
	for(m := 0; m < 4; m++)
		if(missilebmp & (1<<m)){
			(mx, my) := missilepos(m);
			blit(img, o, mx, my, mntimg[ti], mntmask[ti]);
		}
	blit(img, o, px, py, gunimg[ti], gunmask[ti]);

	tt := ts;
	if(gphase == PHOVER){
		tt = tfs;
		if(bl){
			gr(img, o, w/2 - 9*8/2, h/2, RED, "Game Over");
			if(overphase == 2)
				gr(img, o, w/2 - 15*8/2, h/2+16, RED, "press a key ...");
		}
	}
	gr(img, o, 0, 0, BLACK, sys->sprint(
		"Enemy:%d Friends:%d Friendly Fire:%d Time:%6.2f Bullets:%d",
		enemyleft, friendlyleft, friendlyfire, tt-t0s, bulletsfired));
	gr(img, o, 0, 8, BLACK, "Total Score:" + comma(totalscore) +
		" High Score:" + comma(bestscore));
	img.flush(Draw->Flushnow);
}

wrap2pi(x: real): real
{
	return x - 2.0*Math->Pi*math->floor(x/(2.0*Math->Pi));
}

drawintro(img: ref Image, o: Point, w, h: int)
{
	img.draw(img.r, white, nil, Point(0, 0));
	x := w/2 - 160;
	y := h/2 - 100;
	gr(img, o, x, y, BLACK, "Scoring:");
	gr(img, o, x+32, y+16, BLACK, "Enemy Killed          +3");
	gr(img, o, x+32, y+24, BLACK, "Enemy by Friendly     +5");
	gr(img, o, x+32, y+32, BLACK, "Friendly Fire       -100");
	gr(img, o, x+32, y+40, BLACK, "Bullets Fired         -1");
	gr(img, o, x+32, y+48, BLACK, "Game Time     -10 per second");
	gr(img, o, x+32, y+56, BLACK, "Surviving Friendlies +250");
	gr(img, o, x, y+72, BLACK, "Sweep side-to-side while shooting,");
	gr(img, o, x, y+80, BLACK, "holding down ");
	gr(img, o, x+13*8, y+80, GREEN, "<SPACE>");
	gr(img, o, x+20*8, y+80, BLACK, ".");
	gr(img, o, x, y+104, BLACK, "Left/Right sweep the gun.");
	gr(img, o, x, y+112, BLACK, "z/x fire the left/right missiles.");
	gr(img, o, x, y+120, BLACK, "Enter restarts; Esc quits.");
	if(blinkon())
		gr(img, o, x, y+144, BLACK, "Press a key to begin.");
}

