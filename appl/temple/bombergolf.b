implement Bombergolf;

# TempleOS Demo/Games/BomberGolf.HC — fly bomber, drop bombs on targets
# arrows turn/speed; space bomb; Enter restart; q quit
# GAP: no File/Play pull-down menu (MenuPush) — every entry is on a key;
# original runs WinMax (whole 640x480 screen), here a 640x480 window

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

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Bombergolf: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MAPW: con 600;
MAPH: con 600;
TREES: con 64;
TARGETS: con 10;
FALLMS: con 3000;	# FALL_TIME 3.00s
EXPMS: con 250;		# EXPLODE_TIME 0.25s
TANKV: con 10.0;
HITR: con 20;

MDF_TANK: con 0;
MDF_BUNKER: con 1;

FONTW := 8;			# the font's digit advance, set when the font opens
FONTH := 8;			# the font's line height, set when the font opens

win: ref Window;
font: ref Font;
pal: array of ref Image;	# the exact TempleOS 16 colors, index = TempleOS color
bgdith, smokelb, smokedl: ref Image;	# ROPF_DITHER pairs
sprites, masks: array of ref Image;	# DolDoc bins 1..10 (index 1-based)
have_tone := 0;

px, py: real;		# the world TRANSLATION (plane sits at world (-px,-py))
theta, theta_goal: real;
speed: real;
key_cnt, target_cnt, best_score: int;
last_ms := 0;

# sound state (single Snd() channel, priority noise > sweep > steer/jingle)
sweep_t0 := -1;		# BombDrop Sweep(3s, ona 74 -> 62)
noise_until := 0;	# explosion Noise(250ms, ona 62..74)
jingle_t0 := -1;	# new-best-score Snd(74) jingle; -2 = played
last_snd := 0;

tree_x, tree_y: array of int;
tg_x, tg_y, tg_th: array of real;
tg_type, tg_dead: array of int;

Bomb: adt {
	x, y: real;
	t0: int;
	exploding: int;
	next: cyclic ref Bomb;
};

bombs: ref Bomb = nil;

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
	# The device provider, for sprite2d: it sends the rotation or the
	# scale to the GPU as a textured quad instead of resampling it in
	# interpreted Limbo, and falls back to the same C resampler in
	# devdraw.c when the destination is not one the GPU can draw into.
	# 220x220 at 30 degrees measured 2725us a sprite through the Limbo
	# path and 65us through this one, end to end.  It degrades on its
	# own when there is no device, so the second load is only for the
	# .dis file being absent.
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(draw3d != nil)
		draw3d->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS BomberGolf", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "/fonts/temple/temple.font");
	if(font != nil){
		FONTW = font.width("0");
		FONTH = font.height;
	}
	loadpalette(d);
	loadart(d);
	best_score = 99999;
	if(scorestore != nil)
		best_score = scorestore->loadint("bombergolf", best_score);
	game_init();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	# Original: AnimateTask loops with measured tS deltas and Sleep(10),
	# winmgr redraws at ~30fps.  We tick at 16ms and use the measured
	# elapsed time as dt, so all rates stay real-time.
	last_ms = sys->millisec();
	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
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
			game_cleanup();
			game_init();
		' ' =>
			key_cnt++;
			drop_bomb();
		Keyboard->Up or 'w' or 'W' =>
			speed += 10.0;
			if(speed > 300.0)
				speed = 300.0;
		Keyboard->Down or 's' or 'S' =>
			speed -= 10.0;
			if(speed < 20.0)
				speed = 20.0;
		Keyboard->Left or 'a' or 'A' =>
			key_cnt++;
			turn(1);
		Keyboard->Right or 'd' or 'D' =>
			key_cnt++;
			turn(-1);
		}
	<-ticks =>
		now := sys->millisec();
		dt := real(now - last_ms) / 1000.0;
		if(dt < 0.0) dt = 0.0;
		if(dt > 0.1) dt = 0.1;
		last_ms = now;
		step(dt);
		redraw();
	}
}

loadpalette(d: ref Display)
{
	# the exact TempleOS 16 colors, index = TempleOS color
	rgba := grpal->values();
	pal = array[16] of ref Image;
	for(i := 0; i < 16; i++)
		pal[i] = d.color(rgba[i]);
	# ROPF_DITHER checkerboards (per-pixel 50/50 mixes), RGB24 rows are b,g,r:
	# background BROWN/YELLOW, smoke LTGRAY/BLACK and DKGRAY/LTGRAY
	bgdith = dither(d,
		byte 16r00, byte 16r55, byte 16rAA,	# BROWN AA5500
		byte 16r55, byte 16rFF, byte 16rFF);	# YELLOW FFFF55
	smokelb = dither(d,
		byte 16rAA, byte 16rAA, byte 16rAA,	# LTGRAY AAAAAA
		byte 16r00, byte 16r00, byte 16r00);	# BLACK 000000
	smokedl = dither(d,
		byte 16r55, byte 16r55, byte 16r55,	# DKGRAY 555555
		byte 16rAA, byte 16rAA, byte 16rAA);	# LTGRAY AAAAAA
}

dither(d: ref Display, b0, g0, r0, b1, g1, r1: byte): ref Image
{
	img := d.newimage(Rect((0, 0), (2, 2)), Draw->RGB24, 1, Draw->Black);
	if(img == nil)
		return nil;
	buf := array[] of {
		b0, g0, r0,  b1, g1, r1,
		b1, g1, r1,  b0, g0, r0
	};
	img.writepixels(img.r, buf);
	return img;
}

loadart(d: ref Display)
{
	# DolDoc bins: 1 plane, 2 tree, 3/4/5 tank alive/dead1/dead2,
	# 6/7/8 bunker alive/dead1/dead2, 9/10 bomb explosion frames
	sprites = array[11] of ref Image;
	masks = array[11] of ref Image;
	for(i := 1; i <= 10; i++){
		sprites[i] = d.open(sys->sprint("/icons/temple/bombergolf_%d.bit", i));
		masks[i] = d.open(sys->sprint("/icons/temple/bombergolf_%d.mask", i));
	}
}

game_init()
{
	speed = 20.0;
	px = real(-MAPW / 2);
	py = real(-MAPH / 2);
	theta = theta_goal = math->Pi / 4.0;	# original Init: θ=f=1*π/4
	tree_x = array[TREES] of int;
	tree_y = array[TREES] of int;
	tg_x = array[TARGETS] of real;
	tg_y = array[TARGETS] of real;
	tg_th = array[TARGETS] of real;
	tg_type = array[TARGETS] of int;
	tg_dead = array[TARGETS] of int;
	for(i := 0; i < TREES; i++){
		tree_x[i] = rn(MAPW) - MAPW / 2;
		tree_y[i] = rn(MAPH) - MAPH / 2;
	}
	for(ti := 0; ti < TARGETS; ti++){
		tg_x[ti] = real(rn(MAPW) - MAPW / 2);
		tg_y[ti] = real(rn(MAPH) - MAPH / 2);
		tg_dead[ti] = 0;
		if(ti < TARGETS / 3){
			tg_type[ti] = MDF_BUNKER;
			tg_th[ti] = real(rn(4)) * math->Pi / 2.0;
		}else{
			tg_type[ti] = MDF_TANK;
			tg_th[ti] = real(rn(62832)) / 10000.0;
		}
	}
	key_cnt = 0;
	target_cnt = TARGETS;
	game_cleanup();
}

game_cleanup()
{
	bombs = nil;
	sweep_t0 = -1;
	noise_until = 0;
	jingle_t0 = -1;
	sndoff();
}

drop_bomb()
{
	# original: BombDrop(-x-0.8*FALL_TIME*v*Sin(θ), -y-0.8*FALL_TIME*v*Cos(θ))
	bx := -px - 0.8 * real(FALLMS) / 1000.0 * speed * math->sin(theta);
	by := -py - 0.8 * real(FALLMS) / 1000.0 * speed * math->cos(theta);
	bombs = ref Bomb(bx, by, sys->millisec(), 0, bombs);
	sweep_t0 = sys->millisec();	# Sweep(FALL_TIME*1000, 74, 62)
}

step(dt: real)
{
	now := sys->millisec();
	theta += dt * (theta_goal - theta);
	px += dt * speed * math->sin(theta);
	py += dt * speed * math->cos(theta);

	for(i := 0; i < TARGETS; i++)
		if(!tg_dead[i] && tg_type[i] == MDF_TANK){
			tg_x[i] += dt * TANKV * math->cos(tg_th[i]);
			tg_y[i] += dt * TANKV * math->sin(tg_th[i]);
			if(i & 1)
				tg_th[i] += dt * math->Pi / 16.0;
			else
				tg_th[i] -= dt * math->Pi / 16.0;
		}

	prev: ref Bomb;
	b := bombs;
	while(b != nil){
		age := now - b.t0;
		n := b.next;
		if(age > FALLMS + EXPMS){
			bomb_hit(b);
			if(prev == nil)
				bombs = n;
			else
				prev.next = n;
		}else{
			if(age > FALLMS && !b.exploding){
				b.exploding = 1;
				noise_until = now + EXPMS;	# Noise(250ms, 62, 74)
			}
			prev = b;
		}
		b = n;
	}

	if(bombs == nil && target_cnt == 0 && key_cnt < best_score){
		best_score = key_cnt;
		if(scorestore != nil)
			scorestore->saveint("bombergolf", best_score);
		jingle_t0 = now;
	}
	sound(now);
}

# One Snd() channel, as in the original AnimateTask: explosion noise wins,
# then the bomb-fall sweep, then (bombs gone) the steering tone or the
# new-best jingle.  All driven from the tick so input never freezes.
sound(now: int)
{
	if(!have_tone)
		return;
	if(now < noise_until){
		# Noise(EXPLODE_TIME*1000, 62, 74): random ona 62..74
		tone->snd(int onafreq(62.0 + real rn(13)));
		last_snd = -1;
		return;
	}
	if(bombs != nil){
		if(sweep_t0 >= 0 && now < sweep_t0 + FALLMS){
			frac := real(now - sweep_t0) / real FALLMS;
			sndset(int onafreq(74.0 - 12.0 * frac));
		}else
			sndoff();
		return;
	}
	if(target_cnt > 0){
		# Snd(Freq2Ona(100+60*Clamp((0.1*(1+|Wrap(f-θ)|))`4.0, -3, 3)))
		a := 0.1 * (1.0 + absf(wrap(theta_goal - theta)));
		p := a * a * a * a;
		if(p > 3.0) p = 3.0;
		if(p < -3.0) p = -3.0;
		sndset(int(100.0 + 60.0 * p));
		return;
	}
	if(jingle_t0 >= 0){
		# Sleep(150);Snd(74);Sleep(150);Snd; twice
		ph := now - jingle_t0;
		if(ph < 150)
			sndoff();
		else if(ph < 300)
			sndset(int onafreq(74.0));
		else if(ph < 450)
			sndoff();
		else if(ph < 600)
			sndset(int onafreq(74.0));
		else{
			sndoff();
			jingle_t0 = -2;
		}
		return;
	}
	sndoff();
}

sndset(freq: int)
{
	if(freq != last_snd){
		tone->snd(freq);
		last_snd = freq;
	}
}

sndoff()
{
	if(have_tone && last_snd != 0){
		tone->stop();
		last_snd = 0;
	}
}

onafreq(ona: real): real
{
	# TempleOS Snd(ona) is in semitones: 440*2^((ona-60)/12)
	return 440.0 * math->pow(2.0, (ona - 60.0) / 12.0);
}

bomb_hit(b: ref Bomb)
{
	for(i := 0; i < TARGETS; i++){
		if(tg_dead[i])
			continue;
		dx := b.x - tg_x[i];
		dy := b.y - tg_y[i];
		if(dx*dx + dy*dy < real(HITR * HITR)){
			tg_dead[i] = 1;
			target_cnt--;
		}
	}
}

turn(dir: int)
{
	d := wrap(theta_goal - theta);
	if(d < 0.0) d = -d;
	theta_goal += real(dir) / (d + 2.0 * math->Pi);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	# clear with the BROWN/YELLOW dither (ROPF_DITHER|BROWN<<16|YELLOW)
	if(bgdith != nil)
		img.draw(img.r, bgdith, nil, Point(0, 0));
	else
		img.draw(img.r, pal[6], nil, Point(0, 0));
	w := img.r.dx();
	h := img.r.dy();
	o := img.r.min;
	cx := w / 2;
	cy := h / 2;
	ct := math->cos(theta);
	st := math->sin(theta);

	# map border (GrBorder, BLACK, in the world transform)
	draw_poly(img, o, cx, cy, ct, st,
		array[] of { (-MAPW/2, -MAPH/2), (MAPW/2, -MAPH/2), (MAPW/2, MAPH/2), (-MAPW/2, MAPH/2) },
		pal[0]);

	# original draw order: targets, then trees over them, then smoke,
	# then bombs, then the untransformed plane and HUD
	for(tj := 0; tj < TARGETS; tj++)
		draw_target(img, o, cx, cy, ct, st, tj);

	for(ti := 0; ti < TREES; ti++){
		(sx, sy) := world_scr(o, cx, cy, ct, st, real tree_x[ti], real tree_y[ti]);
		blit(img, sx, sy, 2);
	}

	for(tj = 0; tj < TARGETS; tj++)
		if(tg_dead[tj])
			draw_smoke(img, o, cx, cy, ct, st, tg_x[tj], tg_y[tj]);

	# falling bombs are invisible; only the 0.25s explosion is drawn,
	# alternating bins 9/10 at Blink(10)
	b := bombs;
	while(b != nil){
		if(sys->millisec() - b.t0 > FALLMS){
			bin := 9;
			if(!blink(10.0))
				bin = 10;
			(sx, sy) := world_scr(o, cx, cy, ct, st, b.x, b.y);
			blit(img, sx, sy, bin);
		}
		b = b.next;
	}

	# player plane (bin 1) at screen center, outside the transform
	blit(img, o.x+cx, o.y+cy, 1);

	if(font != nil){
		# GrPrint "Targets:%02d\tKeyStrokes:%04d Best:%04d": the tab
		# lands on 8-column stop 16 after the 10-char first field
		msg := sys->sprint("Targets:%02d      KeyStrokes:%04d Best:%04d",
			target_cnt, key_cnt, best_score);
		img.text(Point(o.x, o.y), pal[4], Point(0, 0), font, msg);
		if(!target_cnt && blink(4.0))
			img.text(Point(o.x + (w - font.width("Game Completed"))/2,
				o.y + (h - FONTH)/2 - 32),
				pal[4], Point(0, 0), font, "Game Completed");
	}
	img.flush(Draw->Flushnow);
}

draw_target(img: ref Image, o: Point, cx, cy: int, ct, st: real, i: int)
{
	base := 3;	# tank: alive 3, dead 4/5
	if(tg_type[i] == MDF_BUNKER)
		base = 6;	# bunker: alive 6, dead 7/8
	bin := base;
	mirror := 0;
	if(tg_dead[i]){
		# wrecks alternate dead_img1/dead_img2 at Blink(15); odd wrecks
		# get DCF_SYMMETRY|DCF_JUST_MIRROR across the heading line
		bin = base + 1;
		if(!blink(15.0))
			bin = base + 2;
		mirror = i & 1;
	}
	(sx, sy) := world_scr(o, cx, cy, ct, st, tg_x[i], tg_y[i]);
	# Sprite3ZB: bitmap rotated by target θ, plus the view rotation
	drawrot(img, sx, sy, bin, theta + tg_th[i], mirror);
}

draw_smoke(img: ref Image, o: Point, cx, cy: int, ct, st: real, tx, ty: real)
{
	# 40 GrPlot3 particles, thick=4, alternating LTGRAY/BLACK and
	# DKGRAY/LTGRAY dithers, at (x+5+dx+0.5*dy, y+0.5*dx+dy)
	ts := real sys->millisec() / 1000.0;
	for(j := 0; j < 40; j++){
		dith := smokedl;
		if(j & 1)
			dith = smokelb;
		dx := 15.0 * math->sin(ts/4.0 + real(j*64)) + real(j>>2);
		dy := 10.0 * fulltri(ts/3.0 + real j / 2.0, 20.0) + real(j>>2);
		(sx, sy) := world_scr(o, cx, cy, ct, st,
			tx + 5.0 + dx + 0.5*dy, ty + 0.5*dx + dy);
		if(dith != nil)
			img.draw(Rect((sx-2, sy-2), (sx+2, sy+2)), dith, nil, Point(0, 0));
	}
}

# blit bin n unrotated with its origin at screen (sx,sy) — TempleOS Sprite3:
# only the anchor goes through the transform, the bitmap is not rotated
blit(img: ref Image, sx, sy, n: int)
{
	spr := sprites[n];
	if(spr == nil)
		return;
	img.draw(spr.r.addpt(Point(sx, sy)), spr, masks[n], spr.r.min);
}

# draw bin n rotated by ang about its origin at screen (sx,sy) — TempleOS
# Sprite3ZB.  mirror reflects across the heading line through the origin
# (DCSymmetry3Set along angle ang + DCF_JUST_MIRROR), which for a sprite
# anchored on the mirror line is flip-x composed with rotation by ang+π.
drawrot(img: ref Image, sx, sy, n: int, ang: real, mirror: int)
{
	spr := sprites[n];
	if(spr == nil)
		return;
	if(draw3d == nil){
		blit(img, sx, sy, n);
		return;
	}
	ccx := real spr.r.min.x + real spr.r.dx() / 2.0;
	ccy := real spr.r.min.y + real spr.r.dy() / 2.0;
	if(mirror){
		ang += math->Pi;
		ccx = -ccx;
	}
	cs := math->cos(ang);
	sn := math->sin(ang);
	fx := real sx + ccx*cs - ccy*sn;
	fy := real sy + ccx*sn + ccy*cs;
	draw3d->sprite2d(img, Point(int fx, int fy), spr, masks[n], 0, 0,
		ang * 180.0 / math->Pi, mirror);
}

draw_poly(img: ref Image, o: Point, cx, cy: int, ct, st: real, pts: array of (int, int), col: ref Image)
{
	n := len pts;
	if(n < 2)
		return;
	for(i := 0; i < n; i++){
		(x0, y0) := pts[i];
		(x1, y1) := pts[(i+1) % n];
		(sx0, sy0) := world_scr(o, cx, cy, ct, st, real x0, real y0);
		(sx1, sy1) := world_scr(o, cx, cy, ct, st, real x1, real y1);
		img.line(Point(sx0, sy0), Point(sx1, sy1), 0, 0, 0, col, Point(0, 0));
	}
}

# world -> screen: the original transform is Mat4x4Translation(x,y) then
# RotZ(θ) with dc->x/y at screen center, so a world point w maps to
# RotZ(θ)·(w + (x,y)) + center; the plane at world (-x,-y) stays centered.
world_scr(o: Point, cx, cy: int, ct, st: real, wx, wy: real): (int, int)
{
	dx := wx + px;
	dy := wy + py;
	sx := cx + int(dx*ct - dy*st);
	sy := cy + int(dx*st + dy*ct);
	return (o.x+sx, o.y+sy);
}

blink(f: real): int
{
	# TempleOS Blink(Hz)
	return (int(real sys->millisec() / 1000.0 * f * 2.0)) & 1;
}

wrap(a: real): real
{
	while(a > math->Pi) a -= 2.0 * math->Pi;
	while(a < -math->Pi) a += 2.0 * math->Pi;
	return a;
}

absf(v: real): real
{
	if(v < 0.0) return -v;
	return v;
}

fulltri(t, period: real): real
{
	x := t - math->floor(t / period) * period;
	if(x < period / 2.0)
		return x;
	return period - x;
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

