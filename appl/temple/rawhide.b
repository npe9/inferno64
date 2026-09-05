implement Rawhide;

# TempleOS Demo/Games/RawHide.HC — herd cattle into the upper-left corral
# mouse moves horse; Enter/r restart; Esc/q quit; arrows/wasd scroll the view
#
# Timing: the original AnimateTask loops Sleep(10) (~100 steps/s), switching
# to Yield (spin) while herd stress > 100 ("converge faster at start-up"),
# and the winmgr redraws at 30fps.  We tick at 30ms, run 3 original 10ms
# substeps per tick, and 10 substeps per tick in stress mode.
#
# GAP: no TempleOS pulldown menu bar (File Abort/Exit, Play Restart are on keys)
# GAP: WM CTRL-Left-Grab scrolling replaced by arrow/wasd view scrolling
# GAP: stress>100 Yield-mode spins the original's animate loop at an unbounded
#   rate; approximated here by a fixed 10 substeps per 30ms tick

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

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

Rawhide: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MAPW: con 1000;
MAPH: con 1000;
FENCEW: con 320;
FENCEH: con 200;
BORDER: con 3;
ANIMALS: con 100;
ANIMW: con 20;
ANIMH: con 16;
GATEW: con 22;
GATEH: con 7;
WFH: con MAPH/20;	# waterfall height, 50
WFDROPS: con 512;
WFACCEL: con 10.0;

# TempleOS palette indices
BLACK, BLUE, GREEN, CYAN, RED, PURPLE, BROWN, LTGRAY,
DKGRAY, LTBLUE, LTGREEN, LTCYAN, LTRED, LTPURPLE, YELLOW, WHITE: con iota;

SND86: con 1975;	# Snd(86) = 440*2^((86-60)/12) Hz (Ona2Freq: ona 60 = 440Hz)

Animal: adt {
	x, y, dx, dy: real;
	buddy: int;
	kind: int;	# 1 cow (odd), 0 bull (even)
	frame0: int;
	dead: int;
};

Rdrop: adt {
	y, dx, dy: int;
};

# vector/bitmap sprite element (from lib/temple/sprites/*.spr), used to
# rasterize stamped sprites into the walkability shadow map
Sel: adt {
	kind: int;	# 0 line, 1 bitmap
	col, thk: int;
	x1, y1, x2, y2: int;
	w, h: int;
	data: array of byte;
};

win: ref Window;
tfont: ref Font;
ink: array of ref Image;
mapbuf: ref Image;
pix: array of byte;		# shadow map of palette indices (GrPeek)
bit, msk, mbit, mmsk: array of ref Image;	# sprites 1..10 + mirrors 1..8
postelems, cliffelems: array of Sel;
cowbins, bullbins, horsebins: array of int;
anim: array of Animal;
rx, rw: array of int;
rdrops: array of Rdrop;
nrdrops := 0;
wfdx: array of int;
wfdt: array of real;
wf_x, wf_y, wf_w: int;
waterfall_tf: real;
scrollx, scrolly: int;
mx, my: int;
lastpx := 0;
horse_left := 1;
outside := ANIMALS;
gate_ := 0.0;
gate_t := 0.0;
t0, tf: real;
best_score := 9999.0;
max_speed := 200.0;
stressmode := 0;
updates := 0;
have_tone := 0;
song_pause := 0;
help_up := 1;	# PopUpOk startup dialog showing

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	scorestore = load Scorestore Scorestore->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS RawHide", Wmclient->Appl);
	d := win.display;
	tfont = Font.open(d, "/fonts/temple/temple.font");
	if(tfont == nil)
		tfont = Font.open(d, "*default*");
	ink = array[16] of ref Image;
	cols := array[] of {
		int 16r000000FF, int 16r0000AAFF, int 16r00AA00FF, int 16r00AAAAFF,
		int 16rAA0000FF, int 16rAA00AAFF, int 16rAA5500FF, int 16rAAAAAAFF,
		int 16r555555FF, int 16r5555FFFF, int 16r55FF55FF, int 16r55FFFFFF,
		int 16rFF5555FF, int 16rFF55FFFF, int 16rFFFF55FF, int 16rFFFFFFFF
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
	if(scorestore != nil)
		best_score = scorestore->loadreal("rawhide", best_score);

	# sprites: 1-3 cow walk, 4-6 bull walk, 7-8 horse, 9 fence post, 10 cliff
	bit = array[11] of ref Image;
	msk = array[11] of ref Image;
	mbit = array[11] of ref Image;
	mmsk = array[11] of ref Image;
	for(i = 1; i <= 10; i++){
		bit[i] = d.open(sys->sprint("/icons/temple/rawhide_%d.bit", i));
		msk[i] = d.open(sys->sprint("/icons/temple/rawhide_%d.mask", i));
	}
	for(i = 1; i <= 8; i++){
		mbit[i] = mirror(d, bit[i]);
		mmsk[i] = mirror(d, msk[i]);
	}
	cowbins = array[] of {1, 2, 3, 2};
	bullbins = array[] of {4, 5, 6, 5};
	horsebins = array[] of {7, 8, 7, 8};
	postelems = loadsel("/lib/temple/sprites/rawhide_9.spr");
	cliffelems = loadsel("/lib/temple/sprites/rawhide_10.spr");

	rx = array[MAPH] of int;
	rw = array[MAPH] of int;
	wfdx = array[WFDROPS] of int;
	wfdt = array[WFDROPS] of real;
	rdrops = array[MAPH + 8] of Rdrop;
	anim = array[ANIMALS] of Animal;
	pix = array[MAPW*MAPH] of byte;
	waterfall_tf = math->sqrt(2.0 * real WFH / WFACCEL);
	mapbuf = d.newimage(Rect((0, 0), (MAPW, MAPH)), Draw->RGB24, 0, Draw->Black);
	if(mapbuf == nil)
		raise "fail:map";

	game_init();
	mx = MAPW / 2;
	my = MAPH / 2;
	scrollx = mx - 320;
	scrolly = my - 240;
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	clamp_scroll();
	if(have_tone)
		spawn songloop();

	ticks := chan of int;
	spawn timer(ticks, 30);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		if(help_up && (p.buttons & 7)){
			help_up = 0;
			t0 = now();
		}
		handleptr(p);
	k := <-win.ctxt.kbd =>
		if(help_up){
			case k {
			16r1b or 'q' or 'Q' =>
				if(have_tone)
					tone->stop();
				exit;
			* =>
				help_up = 0;
				t0 = now();
			}
		}else case k {
		16r1b or 'q' or 'Q' =>
			if(have_tone)
				tone->stop();
			exit;
		'\n' or 'r' or 'R' =>
			game_init();
		Keyboard->Left or 'a' or 'A' =>
			scrollby(-24, 0);
		Keyboard->Right or 'd' or 'D' =>
			scrollby(24, 0);
		Keyboard->Up or 'w' or 'W' =>
			scrollby(0, -24);
		Keyboard->Down or 's' or 'S' =>
			scrollby(0, 24);
		}
	<-ticks =>
		if(!help_up){
			n := 3;
			if(stressmode)
				n = 10;
			for(si := 0; si < n; si++)
				substep();
		}
		redraw();
	}
}

# ---------- game state ----------

game_init()
{
	nrdrops = 0;
	# DCNew starts black; LTGREEN field GrRect(2,2,w-4,h-4)
	mfill(0, 0, MAPW, MAPH, BLACK);
	mfill(2, 2, MAPW-4, MAPH-4, LTGREEN);
	rivermake();
	# fence posts (bin 9) every 16px along the corral's south fence
	for(i := FENCEW; i > 0; i -= 16)
		stamp(9, postelems, i, FENCEH);
	# brown dashed rails and the LTGRAY east fence line (the barrier)
	for(i = 0; i < FENCEH - 16; i += 16)
		mline(FENCEW-1, i, FENCEW-1, i+7, 1, BROWN);
	mline(FENCEW, 0, FENCEW, FENCEH-6, 1, LTGRAY);
	gate_ = 0.0;
	gate_t = 0.0;
	redrawgate();
	# GrBorder: 3px-thick red map border
	mfill(0, 0, MAPW, BORDER, RED);
	mfill(0, MAPH-BORDER, MAPW, BORDER, RED);
	mfill(0, 0, BORDER, MAPH, RED);
	mfill(MAPW-BORDER, 0, BORDER, MAPH, RED);
	# populate the whole river with floating drops (the original calls
	# RiverDropsNext once per row, cascading; we place the steady state
	# directly and let the per-update jitter take over)
	for(y := BORDER; y < MAPH - BORDER; y++){
		rdrops[nrdrops++] = Rdrop(y, 0, 0);
		dropjitter(nrdrops - 1);
	}
	for(i = 0; i < ANIMALS; i++){
		ax := 0;
		ay := 0;
		for(;;){
			ax = 64 + rn(MAPW - 128);
			ay = 64 + rn(MAPW - 128);	# sic: original uses MAP_WIDTH for y too
			if(checkmap(ax, ay))
				break;
		}
		anim[i] = Animal(real ax, real ay, 0.0, 0.0, i, i & 1, rn(4), 0);
	}
	for(i = 0; i < ANIMALS; i++)
		anim[i].buddy = buddy_pick(i);
	outside = ANIMALS;
	max_speed = 200.0;	# original: I64_MAX clamped to 200px on first pass
	stressmode = 0;
	updates = 0;
	t0 = now();
	tf = 0.0;
}

rivermake()
{
	wf_y = flo((real(MAPH - WFH) / 2.0) * rnreal() + real(MAPH - WFH) / 4.0);
	# fixed-point 32.32 walk from the original, in px units:
	# dx += RandI32/64 (±2^-7 px) with -I32_MAX/256 drift, clamp ±0.5;
	# w += RandI32*2 (±1 px), clamp 10..150
	x := 2.0 * real MAPW / 3.0;
	dxr := 0.0;
	w := 15.0;
	for(y := BORDER; y < MAPH - BORDER; y++){
		rx[y] = flo(x);
		rw[y] = flo(w);
		if(y > wf_y - 5 && y < wf_y + WFH + 5){
			wf_w = rw[y];
			wf_x = rx[y] - wf_w/2;
		}else{
			dxr = clampf(dxr + (rnreal()*2.0 - 1.0)*0.0078125, -0.5, 0.5) - 0.001953125;
			w = clampf(w + rnreal()*2.0 - 1.0, 10.0, 150.0);
			x += dxr;
		}
	}
	for(i := 0; i < WFDROPS; i++){
		wfdx[i] = wf_x + rn(wf_w);
		wfdt[i] = now() - rnreal()*waterfall_tf;
	}
	# sand bar: thickness rw+10 with per-row random x wobble (clamp ±6)
	xw := 0.0;
	for(y = BORDER; y < MAPH - BORDER; y++){
		if(!(y > wf_y - 9 && y < wf_y + WFH + 9)){
			t := rw[y] + 10;
			mfill(rx[y] + flo(xw) - t/2, y, t, 1, YELLOW);
		}
		xw = clampf(xw + rnreal() - 0.5, -6.0, 6.0);
	}
	# water
	for(y = BORDER; y < MAPH - BORDER; y++)
		mfill(rx[y] - rw[y]/2, y, rw[y], 1, BLUE);
	# waterfall cliff (bin 10)
	stamp(10, cliffelems, wf_x, wf_y);
}

buddy_pick(i: int): int
{
	best := i;
	bscore := 2000000000;
	for(b := 0; b < ANIMALS; b++){
		if(b == i || anim[b].dead)
			continue;
		dx := flo(anim[b].x) - flo(anim[i].x);
		dy := flo(anim[b].y) - flo(anim[i].y);
		sc := rn(512*512) + dx*dx + dy*dy;
		if(sc < bscore){
			bscore = sc;
			best = b;
		}
	}
	return best;
}

# original CheckMap: block on the waterfall ellipse and any LTGRAY/BLACK
# pixel in the 9x7 window around (x,y); BLUE water IS walkable
checkmap(x, y: int): int
{
	wcx := wf_x + wf_w/2;
	wcy := wf_y + WFH/2;
	if((x-wcx)*(x-wcx)/2 + (y-wcy)*(y-wcy) < 2500)
		return 0;
	for(j := -4; j <= 2; j++)
		for(i := -4; i <= 4; i++){
			c := peek(x+i, y+j);
			if(c == LTGRAY || c == BLACK)
				return 0;
		}
	return 1;
}

# one original 10ms AnimateTask iteration
substep()
{
	ts := now();
	if(mx < FENCEW && my < FENCEH)
		gate_t = ts;
	redrawgate();
	stress := 0.0;
	cnt := 0;
	out := 0;
	for(i := 0; i < ANIMALS; i++){
		a := anim[i];
		if(a.dead)
			continue;
		# move away from horse: f = 5.0e2*U32_MAX/dd -> 500/dd px
		ddx := a.x - real mx;
		ddy := a.y - real my;
		dd := ddx*ddx + ddy*ddy;
		if(dd != 0.0){
			d := math->sqrt(dd);
			f := 500.0 / dd;
			a.dx += f * ddx / d;
			a.dy += f * ddy / d;
		}
		# reselect buddy every ANIMALS updates, and when buddy dead
		if(anim[a.buddy].dead || i == updates % ANIMALS)
			a.buddy = buddy_pick(i);
		b := anim[a.buddy];
		# move toward buddy: spring s = d^1.25 - 80
		ddx = a.x - b.x;
		ddy = a.y - b.y;
		dd = ddx*ddx + ddy*ddy;
		if(dd != 0.0){
			d := math->sqrt(dd);
			s := math->pow(d, 1.25) - 80.0;
			stress += rabs(s);
			f := -0.001 * s;
			a.dx += f * ddx / d;
			a.dy += f * ddy / d;
		}
		# make velocity similar to buddy
		a.dx += 0.1 * (b.dx - a.dx);
		a.dy += 0.1 * (b.dy - a.dy);
		# random accel (RandI32/32 = ±2^-6 px), limit and dampen speed
		a.dx = 0.995 * clampf(a.dx + (rnreal()*2.0 - 1.0)*0.015625, -max_speed, max_speed);
		a.dy = 0.995 * clampf(a.dy + (rnreal()*2.0 - 1.0)*0.015625, -max_speed, max_speed);
		# slow in river (any non-LTGREEN ground: water, sand, border)
		if(peek(flo(a.x), flo(a.y)) != LTGREEN){
			a.dx /= 2.0;
			a.dy /= 2.0;
		}
		if(checkmap(flo(a.x + a.dx), flo(a.y + a.dy))){
			a.x += a.dx;
			a.y += a.dy;
		}
		# keep on map
		fx := flo(a.x);
		if(!(fx >= BORDER + ANIMW/2 && fx < MAPW - BORDER - ANIMW/2)){
			a.x -= a.dx;
			a.dx = -a.dx;
		}
		fy := flo(a.y);
		if(!(fy >= BORDER + ANIMH && fy < MAPH - BORDER)){
			a.y -= a.dy;
			a.dy = -a.dy;
		}
		cnt++;
		if(flo(a.x) >= FENCEW || flo(a.y) >= FENCEH)
			out++;
		anim[i] = a;
	}
	outside = out;
	if((updates & 15) == 0)
		riverdropsnext();
	if(tf == 0.0 && out == 0){
		tf = ts;
		beat := 0;
		if(tf - t0 < best_score){
			best_score = tf - t0;
			beat = 1;
			if(scorestore != nil)
				scorestore->savereal("rawhide", best_score);
		}
		spawn winsound(beat);
	}
	updates++;
	if(cnt > 0)
		stress /= real cnt;
	else
		stress = 0.0;
	if(stress > 100.0){
		stressmode = 1;
		max_speed = clampf(stress/5.0, 1.0/3.0, 200.0);
	}else{
		stressmode = 0;
		max_speed = 1.0/3.0;
	}
}

# swinging wireframe gate, redrawn into the map each substep; opens while
# the horse has been in the corral within 0.5s, closes after 5s
redrawgate()
{
	tt := now() - gate_t;
	if(tt < 0.5)
		gate_ = clampf(gate_ + 0.02, 0.0, Math->Pi/2.0);
	else if(tt > 5.0)
		gate_ = clampf(gate_ - 0.02, 0.0, Math->Pi/2.0);
	x1 := FENCEW - 63;
	y1 := FENCEH - 1;
	gdx := int (real GATEW * math->cos(gate_));
	gdy := int (-0.8 * real GATEW * math->sin(gate_));
	gh8 := int (0.8 * real GATEW);
	mfill(x1, y1 - gh8 - GATEH, 46, gh8 + GATEH + 3, LTGREEN);
	# left panel (6 lines; map_dc->thick is 3 during play)
	mline(x1, y1, x1+gdx, y1+gdy, 3, BLACK);
	mline(x1, y1, x1, y1-GATEH, 3, BLACK);
	mline(x1+gdx, y1+gdy, x1+gdx, y1+gdy-GATEH, 3, BLACK);
	mline(x1, y1-GATEH, x1+gdx, y1+gdy-GATEH, 3, BLACK);
	mline(x1, y1, x1+gdx, y1+gdy-GATEH, 3, BLACK);
	mline(x1, y1-GATEH, x1+gdx, y1+gdy, 3, BLACK);
	# right panel, mirrored about x1+45
	x2 := x1 + 45;
	mline(x2, y1, x2-gdx, y1+gdy, 3, BLACK);
	mline(x2, y1, x2, y1-GATEH, 3, BLACK);
	mline(x2-gdx, y1+gdy, x2-gdx, y1+gdy-GATEH, 3, BLACK);
	mline(x2, y1-GATEH, x2-gdx, y1+gdy-GATEH, 3, BLACK);
	mline(x2, y1, x2-gdx, y1+gdy-GATEH, 3, BLACK);
	mline(x2, y1-GATEH, x2-gdx, y1+gdy, 3, BLACK);
}

# ---------- river drops ----------

# advance every floating drop one row and spawn one at the river head;
# called every 16 updates, as the original RiverDropsNext
riverdropsnext()
{
	j := 0;
	for(i := 0; i < nrdrops; i++){
		rd := rdrops[i];
		rd.y++;
		if(rd.y >= MAPH - BORDER)
			continue;	# freed at map bottom
		rdrops[j] = rd;
		dropjitter(j);
		j++;
	}
	if(j >= len rdrops){
		nr := array[2*len rdrops] of Rdrop;
		nr[0:] = rdrops[0:j];
		rdrops = nr;
	}
	rdrops[j++] = Rdrop(BORDER, 0, 0);
	nrdrops = j;
}

# the original's do-while: keep a drop's jitter on BLUE water
dropjitter(i: int)
{
	rd := rdrops[i];
	for(guard := 0; guard < 256; guard++){
		if(rn(2) == 1 && peek(rx[rd.y] + rd.dx, rd.y + rd.dy) == BLUE)
			break;
		half := rw[rd.y] / 2;
		rd.dx = clampi(rd.dx + rn(3) - 1, -half, half);
		rd.dy = clampi(rd.dy + rn(3) - 1, -half, half);
		if(!(peek(rx[rd.y] + rd.dx, rd.y + rd.dy) != BLUE &&
		     peek(rx[rd.y], rd.y) == BLUE))
			break;
	}
	rdrops[i] = rd;
}

# ---------- drawing ----------

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	clamp_scroll();
	img.draw(img.r, mapbuf, nil, Point(scrollx, scrolly));
	ts := now();
	# floating river drops, LTBLUE
	for(i := 0; i < nrdrops; i++){
		rd := rdrops[i];
		px := rx[rd.y] + rd.dx - scrollx;
		py := rd.y + rd.dy - scrolly;
		if(px >= 0 && py >= 0 && px < w && py < h)
			img.draw(Rect((o.x+px, o.y+py), (o.x+px+1, o.y+py+1)),
				ink[LTBLUE], nil, Point(0, 0));
	}
	# waterfall drops, WHITE, falling at 0.5*a*t^2 with sawtooth recycle
	for(i = 0; i < WFDROPS; i++){
		v := waterfall_tf * saw(ts - wfdt[i], waterfall_tf);
		py := wf_y + int(0.5*WFACCEL*v*v) - scrolly;
		px := wfdx[i] - scrollx;
		if(px >= 0 && py >= 0 && px < w && py < h)
			img.draw(Rect((o.x+px, o.y+py), (o.x+px+1, o.y+py+1)),
				ink[WHITE], nil, Point(0, 0));
	}
	# animals: 4 walk frames at 4*tS with per-animal offset, mirrored left
	frame := flo(4.0 * ts);
	for(i = 0; i < ANIMALS; i++){
		a := anim[i];
		if(a.dead)
			continue;
		ax := flo(a.x) - scrollx;
		ay := flo(a.y) - scrolly;
		if(ax < -40 || ay < -40 || ax > w + 40 || ay > h + 40)
			continue;
		bins := bullbins;
		if(a.kind)
			bins = cowbins;
		bin := bins[(frame + a.frame0) & 3];
		drawspr(img, bin, o.x + ax, o.y + ay, a.dx < 0.0);
	}
	# horse rides the mouse cursor, mirrored by pointer direction
	hbin := horsebins[frame & 3];
	drawspr(img, hbin, o.x + mx - scrollx, o.y + my - scrolly, horse_left);
	# HUD, screen-fixed like GrPrint at (-scroll_x,-scroll_y)
	t := ts - t0;
	ci := BLACK;
	if(tf != 0.0){
		t = tf - t0;
		ci = RED;
		if((sys->millisec()/250) % 2 == 0 && tfont != nil)
			img.text(Point(o.x + (w - 14*8)/2, o.y + (h - 8)/2),
				ink[RED], Point(0, 0), tfont, "Game Completed");
	}
	if(help_up)
		t = 0.0;
	if(tfont != nil)
		img.text(Point(o.x, o.y), ink[ci], Point(0, 0), tfont,
			sys->sprint("Outside:%03d Time:%7.2fs Best:%7.2fs",
				outside, t, best_score));
	if(help_up)
		draw_help(img, o, w, h);
	img.flush(Draw->Flushnow);
}

drawspr(img: ref Image, bin, x, y: int, mirrored: int)
{
	s := bit[bin];
	m := msk[bin];
	if(mirrored){
		s = mbit[bin];
		m = mmsk[bin];
	}
	if(s == nil){
		# fallback if the sprite failed to load
		img.ellipse(Point(x, y), 8, 6, 0, ink[LTRED], Point(0, 0));
		return;
	}
	img.draw(s.r.addpt(Point(x, y)), s, m, s.r.min);
}

# PopUpOk startup dialog
draw_help(img: ref Image, o: Point, w, h: int)
{
	lines := array[] of {
		"Coral the cattle.  The coral is in the",
		"upper-left corner if you scroll.",
		"",
		"Scroll with the arrow keys or wasd.",
		"",
		"               ( OK )"
	};
	bw := 38*8 + 16;
	bh := len lines * 8 + 16;
	x0 := o.x + (w - bw)/2;
	y0 := o.y + (h - bh)/2;
	img.draw(Rect((x0-1, y0-1), (x0+bw+1, y0+bh+1)), ink[BLACK], nil, Point(0, 0));
	img.draw(Rect((x0, y0), (x0+bw, y0+bh)), ink[WHITE], nil, Point(0, 0));
	if(tfont != nil)
		for(i := 0; i < len lines; i++)
			img.text(Point(x0+8, y0+8+i*8), ink[BLACK], Point(0, 0),
				tfont, lines[i]);
}

# ---------- map + shadow plotting ----------

peek(x, y: int): int
{
	if(x < 0 || y < 0 || x >= MAPW || y >= MAPH)
		return -1;
	return int pix[y*MAPW + x];
}

sfill(x, y, w, h, ci: int)
{
	if(x < 0){
		w += x;
		x = 0;
	}
	if(y < 0){
		h += y;
		y = 0;
	}
	if(x + w > MAPW)
		w = MAPW - x;
	if(y + h > MAPH)
		h = MAPH - y;
	if(w <= 0 || h <= 0)
		return;
	b := byte ci;
	for(j := 0; j < h; j++){
		off := (y+j)*MAPW + x;
		for(i := 0; i < w; i++)
			pix[off+i] = b;
	}
}

splot(x, y, ci: int)
{
	if(x >= 0 && y >= 0 && x < MAPW && y < MAPH)
		pix[y*MAPW + x] = byte ci;
}

mfill(x, y, w, h, ci: int)
{
	sfill(x, y, w, h, ci);
	mapbuf.draw(Rect((x, y), (x+w, y+h)), ink[ci], nil, Point(0, 0));
}

sline(x1, y1, x2, y2, rad, ci: int)
{
	dx := x2 - x1;
	dy := y2 - y1;
	adx := dx;
	if(adx < 0)
		adx = -adx;
	ady := dy;
	if(ady < 0)
		ady = -ady;
	n := adx;
	if(ady > n)
		n = ady;
	if(n == 0){
		sfill(x1-rad, y1-rad, 2*rad+1, 2*rad+1, ci);
		return;
	}
	for(i := 0; i <= n; i++){
		x := x1 + dx*i/n;
		y := y1 + dy*i/n;
		sfill(x-rad, y-rad, 2*rad+1, 2*rad+1, ci);
	}
}

mline(x1, y1, x2, y2, thick, ci: int)
{
	rad := thick/2;
	sline(x1, y1, x2, y2, rad, ci);
	mapbuf.line(Point(x1, y1), Point(x2, y2), Draw->Endsquare, Draw->Endsquare,
		rad, ink[ci], Point(0, 0));
}

# stamp sprite <bin> into the map at (px,py): blit the raster into mapbuf,
# rasterize the .spr elements into the shadow map for GrPeek
stamp(bin: int, els: array of Sel, px, py: int)
{
	s := bit[bin];
	if(s != nil)
		mapbuf.draw(s.r.addpt(Point(px, py)), s, msk[bin], s.r.min);
	for(k := 0; k < len els; k++){
		e := els[k];
		if(e.kind == 0)
			sline(px+e.x1, py+e.y1, px+e.x2, py+e.y2, e.thk/2, e.col);
		else for(j := 0; j < e.h; j++)
			for(i := 0; i < e.w; i++){
				b := int e.data[j*e.w + i];
				if(b != 16rFF)
					splot(px+e.x1+i, py+e.y1+j, b);
			}
	}
}

# ---------- sprite element files ----------

loadsel(path: string): array of Sel
{
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return array[0] of Sel;
	l: list of Sel;
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
				e := Sel(0, col, thk, int hd t, int hd tl t,
					int hd tl tl t, int hd tl tl tl t, 0, 0, nil);
				l = e :: l;
				n++;
			}
		"bitmap" =>
			if(nt >= 6){
				t := tl toks;
				bx := int hd t;
				by := int hd tl t;
				bw := int hd tl tl t;
				bh := int hd tl tl tl t;
				hex := hd tl tl tl tl t;
				data := array[bw*bh] of byte;
				for(i := 0; i < bw*bh; i++){
					if(2*i+1 >= len hex)
						break;
					data[i] = byte ((hexv(hex[2*i]) << 4) | hexv(hex[2*i+1]));
				}
				e := Sel(1, col, thk, bx, by, 0, 0, bw, bh, data);
				l = e :: l;
				n++;
			}
		}
	}
	a := array[n] of Sel;
	for(i := n - 1; i >= 0; i--){
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

hexv(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}

# horizontal mirror preserving the sprite-origin rect, so drawing the
# mirrored image at the same point flips about the sprite origin
# (the original's DCF_JUST_MIRROR + DCSymmetrySet at the sprite x)
mirror(d: ref Display, src: ref Image): ref Image
{
	if(src == nil)
		return nil;
	sw := src.r.dx();
	n := d.newimage(Rect((-src.r.max.x, src.r.min.y), (-src.r.min.x, src.r.max.y)),
		src.chans, 0, Draw->Black);
	if(n == nil)
		return nil;
	for(i := 0; i < sw; i++)
		n.draw(Rect((n.r.min.x + (sw-1-i), n.r.min.y), (n.r.min.x + sw-i, n.r.max.y)),
			src, nil, Point(src.r.min.x + i, src.r.min.y));
	return n;
}

# ---------- sound ----------

songloop()
{
	# SongTask: "Randomly generated (by God :-)" — the original's Play strings
	scores := array[] of {
		"5qC4etG5DC4B5DCECFqFC4sA5D4A5D4qB",
		"5C4etG5DC4B5DCECFqFC4sA5D4A5D4qB",
		"4sGAGA5qG4etG5GD4eBBqB5F4eBA5qE",
		"4sGAGA5qG4etG5GD4eBBqB5F4eBA5qE"
	};
	for(;;){
		if(!song_pause){
			for(i := 0; i < len scores; i++){
				if(song_pause)
					break;
				tone->play(scores[i]);
			}
		}else
			sys->sleep(50);
	}
}

# completion: Snd(86) 200ms + rest; a second one only when the best
# score was beaten; music muted meanwhile
winsound(beat: int)
{
	song_pause = 1;
	if(have_tone){
		tone->beep(SND86, 200);
		sys->sleep(300);
		if(beat){
			tone->beep(SND86, 200);
			sys->sleep(300);
		}
	}
	song_pause = 0;
}

# ---------- input / misc ----------

handleptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	if(p.xy.x > lastpx)
		horse_left = 0;
	else if(p.xy.x < lastpx)
		horse_left = 1;
	lastpx = p.xy.x;
	mx = p.xy.x - img.r.min.x + scrollx;
	my = p.xy.y - img.r.min.y + scrolly;
}

scrollby(dx, dy: int)
{
	ox := scrollx;
	oy := scrolly;
	scrollx += dx;
	scrolly += dy;
	clamp_scroll();
	mx += scrollx - ox;
	my += scrolly - oy;
}

clamp_scroll()
{
	img := win.image;
	w := 640;
	h := 480;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	if(scrollx > MAPW - w)
		scrollx = MAPW - w;
	if(scrolly > MAPH - h)
		scrolly = MAPH - h;
	if(scrollx < 0)
		scrollx = 0;
	if(scrolly < 0)
		scrolly = 0;
}

clampf(v, lo, hi: real): real
{
	if(v < lo)
		return lo;
	if(v > hi)
		return hi;
	return v;
}

clampi(v, lo, hi: int): int
{
	if(v < lo)
		return lo;
	if(v > hi)
		return hi;
	return v;
}

rabs(v: real): real
{
	if(v < 0.0)
		return -v;
	return v;
}

# floor (the original's fixed-point .i32[1] / >>32); Limbo's int cast rounds
flo(v: real): int
{
	i := int v;
	if(real i > v)
		i--;
	return i;
}

saw(t, period: real): real
{
	if(period == 0.0)
		return 0.0;
	f := t / period;
	return f - real flo(f);
}

now(): real
{
	return real sys->millisec() / 1000.0;
}

rn(n: int): int
{
	if(n <= 0)
		return 0;
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

rnreal(): real
{
	return real rn(1000000) / 1000000.0;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
