implement Battlelines;

# TempleOS Demo/Games/BattleLines.HC — troop swarm combat
# GAP: MenuPush pull-down menu (File/Play entries with live checkmarks) has no
#      wmclient equivalent; the same keys ('1' TimeLapse, '2' TapMode, Enter
#      Restart, Esc Exit) work directly.
# GAP: mouse wheel force — ',' '.' (and '-','+','=') adjust wheel_z, plus
#      wheel buttons 4/8 if wm sends them; wheel_z is signed and unclamped
#      like ms.pos.z in the original.
#
# Timing: the original loop is Sleep(40) per tick (25 ticks/sec) with
# velocities in 32.32 fixed point px/tick; this port ticks at the same 40 ms,
# so per-tick constants carry over 1:1 (fixed-point ones divided by 2^32).

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Font: import draw;

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
include "grpalette.m";
	grpal: Grpalette;
include "math/vsprite.m";
	vspr: Vsprite;
	Elem, Sprite: import vspr;
include "frameclock.m";
	fclock: Frameclock;

Battlelines: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 40;
# The most substeps one frame may run: enough to cover a frame of
# real time at this step, with headroom.  A fixed cap is wrong -
# four substeps covers 40ms at FCSTEP 10 and only 4ms at FCSTEP 1.
FCMAX: con 2 + 20/FCSTEP;
fcacc := 0;

TROOPERS_NUM: con 100;
TAP_MODE_RADIUS: con 50;
AI_NOTHING, AI_TARGET, AI_RANDOM, AI_AI_NUM: con iota;
FRAMES: con 6;
FIX: con 4294967296.0;			# 2^32, one pixel in 32.32 fixed point
FORCE_SCALE: con 400000000.0 / FIX;	# original j=400000000*z on fixed velocities
SND_FREQ: con 1976;			# Snd(86): 440*2^((86-60)/12) Hz (Ona2Freq: ona 60 = 440Hz)

Trooper: adt {
	x, y, dx, dy: real;		# px, px/tick (original 32.32 fixed /2^32)
	att, def, rng, player: int;
	animate_time_base, fire_end_time: real;
	target_side, target_idx: int;
};

# A trooper is five element lists tweened between and mirrored, all drawn
# in one colour - so this is the one sprite reader in the tree that wants
# the elements as DATA and not as a picture.  vsprite(2) does the reading,
# because a second copy of the grammar is a second thing to drift; the
# drawing stays here, because no raster can be tweened.
El: adt {
	x1, y1, x2, y2: int;
};

win: ref Window;
ink: array of ref Image;
tfont: ref Font;
frames: array of array of El;		# soldier sprite bins 1..5
imgs := array[FRAMES] of {0, 1, 2, 3, 2, 1};	# ping-pong walk cycle
have_spr := 0;
tr0, tr1: array of Trooper;
time_lapse := 0;
tap_mode := 0;
ai_mode := 0;
ai_targets: array of int;
fire_end_time := 0.0;
wheel_z := 25;				# signed, unclamped (ms.pos.z)
mx, my: int;
ptr_lb, ptr_rb: int;
have_tone := 0;
snd_on := 0;
help_up := 1;				# PopUpOk startup dialog showing

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	vspr = load Vsprite Vsprite->PATH;
	if(vspr != nil)
		vspr->init();
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
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

	win = wmclient->window(ctxt, "TempleOS BattleLines", Wmclient->Appl);
	d := win.display;
	ink = array[16] of ref Image;
	# the exact TempleOS 16-color palette, index = TempleOS color
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
	tfont = Font.open(d, "/fonts/lucida/unicode.8.font");
	loadsprites();

	tr0 = array[TROOPERS_NUM] of Trooper;
	tr1 = array[TROOPERS_NUM] of Trooper;
	ai_targets = array[10] of int;
	game_init();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		handleptr(p);
	k := <-win.ctxt.kbd =>
		if(help_up){
			help_up = 0;
			redraw();
		}else case k {
		16r1b or 'q' or 'Q' =>
			if(have_tone)
				tone->stop();
			exit;
		'\n' or 'r' or 'R' =>
			game_init();
		'1' =>
			time_lapse = time_lapse ^ 1;
		'2' =>
			tap_mode = tap_mode ^ 1;
		',' or '-' =>
			wheel_z--;
		'.' or '+' or '=' =>
			wheel_z++;
		}
	dtms := <-ticks =>
		fcacc += dtms;
		if(fcacc > FCSTEP*FCMAX)
			fcacc = FCSTEP*FCMAX;
		for(fcn := 0; fcacc >= FCSTEP && fcn < FCMAX; fcn++){
			if(!help_up){
				if(ai_mode == AI_TARGET)
					do_ai_target();
				update_human_velocities();
				update_pos();
				resolve_firing();
			}
			fcacc -= FCSTEP;
		}
		redraw();
	}
}

loadsprites()
{
	frames = array[5] of array of El;
	have_spr = 1;
	for(i := 0; i < 5; i++){
		frames[i] = loadspr(sys->sprint("/lib/temple/sprites/battlelines_%d.spr", i+1));
		if(len frames[i] == 0)
			have_spr = 0;
	}
}

# The line endpoints, in order, from whatever vsprite(2) read.  A
# trooper's five frames are line-only and have to stay in step with each
# other, so anything that is not a line is skipped rather than refused.
loadspr(path: string): array of El
{
	if(vspr == nil)
		return array[0] of El;
	(spr, nil) := vspr->read(path);
	if(spr == nil)
		return array[0] of El;
	n := 0;
	for(i := 0; i < len spr.elems; i++)
		if(spr.elems[i].kind == Vsprite->SLINE)
			n++;
	a := array[n] of El;
	j := 0;
	for(i = 0; i < len spr.elems; i++){
		e := spr.elems[i];
		if(e.kind != Vsprite->SLINE)
			continue;
		a[j++] = El(e.a[0], e.a[1], e.a[2], e.a[3]);
	}
	return a;
}

game_init()
{
	img := win.image;
	w := 640; h := 480;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	tap_mode = 0;
	time_lapse = 0;
	fire_end_time = 0.0;
	wheel_z = 25;			# MsSet(,,25)
	for(i := 0; i < 10; i++){
		ai_targets[i] = rn(TROOPERS_NUM);
		# RandI32 as a 32.32 fixed velocity: uniform in (-0.5, 0.5) px/tick
		dxv := frnd() - 0.5;
		dyv := frnd() - 0.5;
		for(j := 0; j < 10; j++){
			idx := i*10 + j;
			tr0[idx] = Trooper(
				real(w - 100 - i*10), real(h/2 - 50 + j*10),
				0.0, 0.0, 3, 10, 50*50, 0,
				10.0 * frnd(), 0.0, -1, -1);
			t1 := Trooper(
				real(100 + i*10), real(h/2 - 50 + j*10),
				0.0, 0.0, 3, 10, 50*50, 1,
				10.0 * frnd(), 0.0, -1, -1);
			if(ai_mode == AI_RANDOM){
				t1.dx = dxv;
				t1.dy = dyv;
			}
			tr1[idx] = t1;
		}
	}
	# faithful quirk: ai_mode is re-randomized AFTER the loop, so the
	# AI_RANDOM branch above tested the previous round's mode
	ai_mode = rn(AI_AI_NUM);
}

handleptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	mx = p.xy.x - img.r.min.x;
	my = p.xy.y - img.r.min.y;
	if(help_up && (p.buttons & 7)){
		help_up = 0;
		return;
	}
	ptr_lb = (p.buttons & 1) != 0;
	ptr_rb = (p.buttons & 2) != 0;
	if(p.buttons & 4)
		wheel_z--;
	if(p.buttons & 8)
		wheel_z++;
}

do_ai_target()
{
	for(i := 0; i < 10; i++){
		t0 := tr0[ai_targets[i]];
		for(j := 0; j < 10; j++){
			idx := i*10 + j;
			t1 := tr1[idx];
			t1.dx = (t0.x - t1.x) / 2048.0;	# original >>11 on 32.32 fixed
			t1.dy = (t0.y - t1.y) / 2048.0;
			tr1[idx] = t1;
		}
	}
}

update_pos()
{
	img := win.image;
	w := 640.0; h := 480.0;
	i: int;
	if(img != nil){
		w = real img.r.dx();
		h = real img.r.dy();
	}
	# time-lapse is a display projection only (see draw_trooper);
	# the simulation always advances one dx per tick
	for(i = 0; i < TROOPERS_NUM; i++){
		t := tr0[i];
		t.x += t.dx;
		t.y += t.dy;
		if(t.x >= w)
			t.x -= w;
		if(t.x < 0.0)
			t.x += w;
		if(t.y >= h)
			t.y -= h;
		if(t.y < 0.0)
			t.y += h;
		tr0[i] = t;
	}
	for(i = 0; i < TROOPERS_NUM; i++){
		t := tr1[i];
		t.x += t.dx;
		t.y += t.dy;
		if(t.x >= w)
			t.x -= w;
		if(t.x < 0.0)
			t.x += w;
		if(t.y >= h)
			t.y -= h;
		if(t.y < 0.0)
			t.y += h;
		tr1[i] = t;
	}
}

resolve_firing()
{
	ts := now();
	i, j: int;
	for(i = 0; i < TROOPERS_NUM; i++){
		t := get_troop(0, i);
		if(t.target_side >= 0 && t.fire_end_time < ts)
			resolve_shot(0, i, t);
	}
	for(i = 0; i < TROOPERS_NUM; i++){
		t := get_troop(1, i);
		if(t.target_side >= 0 && t.fire_end_time < ts)
			resolve_shot(1, i, t);
	}
	for(i = 0; i < TROOPERS_NUM; i++){
		t0 := tr0[i];
		for(j = 0; j < TROOPERS_NUM; j++){
			t1 := tr1[j];
			if(t0.def <= 0 || t1.def <= 0)
				continue;
			dx := t0.x - t1.x;
			dy := t0.y - t1.y;
			dd := int(dx*dx + dy*dy);
			if(dd < t0.rng && t0.target_side < 0){
				fire_end_time = ts + 0.125;
				t0.fire_end_time = fire_end_time;
				t0.target_side = 1;
				t0.target_idx = j;
				tr0[i] = t0;
				sndfire();
			}
			if(dd < t1.rng && t1.target_side < 0){
				fire_end_time = ts + 0.125;
				t1.fire_end_time = fire_end_time;
				t1.target_side = 0;
				t1.target_idx = i;
				tr1[j] = t1;
				sndfire();
			}
		}
	}
	if(ts >= fire_end_time && snd_on){
		if(have_tone)
			tone->stop();
		snd_on = 0;
	}
}

# Snd(86): a held note for as long as anyone is firing, not a per-shot beep
sndfire()
{
	if(have_tone && !snd_on){
		tone->snd(SND_FREQ);
		snd_on = 1;
	}
}

resolve_shot(side, i: int, t: Trooper)
{
	victim := get_troop(t.target_side, t.target_idx);
	victim.def -= t.att;
	put_troop(t.target_side, t.target_idx, victim);
	t.fire_end_time = 0.0;
	t.target_side = -1;
	t.target_idx = -1;
	put_troop(side, i, t);
}

update_human_velocities()
{
	active := ptr_lb || ptr_rb;
	i: int;
	if(tap_mode){
		r2 := real(TAP_MODE_RADIUS * TAP_MODE_RADIUS);
		for(i = 0; i < TROOPERS_NUM; i++){
			t := tr0[i];
			dx := real mx - t.x;
			dy := real my - t.y;
			d := dx*dx + dy*dy;
			if(d > 0.0 && d < r2){
				# SqrI64(SqrI64(SqrI64(R)-d)) = (R^2-d)^4,
				# applied to 32.32 fixed velocities, hence /2^32
				gap := r2 - d;
				intensity := gap * gap * gap * gap / FIX;
				t.dx -= intensity * dx / d;
				t.dy -= intensity * dy / d;
			}else{
				t.dx *= 0.8;
				t.dy *= 0.8;
			}
			tr0[i] = t;
		}
	}else if(active){
		# original: j = 400000000*z; if (ms.rb) j = -j — the RIGHT
		# button negates; positive z + left button REPELS
		j := FORCE_SCALE * real wheel_z;
		if(ptr_rb)
			j = -j;
		for(i = 0; i < TROOPERS_NUM; i++){
			t := tr0[i];
			dx := real mx - t.x;
			dy := real my - t.y;
			d := dx*dx + dy*dy;
			if(d > 0.0){
				t.dx -= j * dx / d;
				t.dy -= j * dy / d;
			}
			tr0[i] = t;
		}
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	w := img.r.dx();
	o := img.r.min;
	img.draw(img.r, ink[2], nil, Point(0, 0));	# GREEN field (DocClear on GREEN<<4)
	cnt0, cnt1, i: int;
	for(i = 0; i < TROOPERS_NUM; i++){
		t := tr0[i];
		if(t.def <= 0)
			continue;
		cnt0++;
		draw_trooper(img, o, t, 0);
	}
	for(i = 0; i < TROOPERS_NUM; i++){
		t := tr1[i];
		if(t.def <= 0)
			continue;
		cnt1++;
		draw_trooper(img, o, t, 1);
	}
	if(tap_mode)
		img.ellipse(Point(o.x+mx, o.y+my), TAP_MODE_RADIUS, TAP_MODE_RADIUS, 0, ink[14], Point(0, 0));
	else{
		active := ptr_lb || ptr_rb;
		repulsive := (wheel_z > 0) != (ptr_rb != 0);
		col: ref Image;
		if(repulsive){
			if(active)
				col = ink[12];	# LTRED
			else
				col = ink[4];	# RED
		}else{
			if(active)
				col = ink[9];	# LTBLUE
			else
				col = ink[1];	# BLUE
		}
		rad := wheel_z;
		if(rad < 0)
			rad = -rad;
		img.ellipse(Point(o.x+mx, o.y+my), rad, rad, 0, col, Point(0, 0));
	}
	# GrPrint "%03d" troop counts at the top right, in character cells
	if(tfont != nil){
		cw := tfont.width("0");
		ncols := w / cw;
		img.text(Point(o.x + (ncols-8)*cw, o.y), ink[11], Point(0, 0), tfont,
			sys->sprint("%03d", cnt0));
		img.text(Point(o.x + (ncols-4)*cw, o.y), ink[13], Point(0, 0), tfont,
			sys->sprint("%03d", cnt1));
	}
	if(help_up)
		draw_help(img, o, w, img.r.dy());
	img.flush(Draw->Flushnow);
}

# PopUpOk startup dialog
draw_help(img: ref Image, o: Point, w, h: int)
{
	lines := array[] of {
		"The mouse wheel controls",
		"the command force.",
		"Attract or repel with",
		"left or right bttn.",
		"",
		"        ( OK )"
	};
	bw := widest(tfont, lines) + 16;
	bh := len lines * tfont.height + 16;
	x0 := o.x + (w - bw)/2;
	y0 := o.y + (h - bh)/2;
	img.draw(Rect((x0-1, y0-1), (x0+bw+1, y0+bh+1)), ink[0], nil, Point(0, 0));
	img.draw(Rect((x0, y0), (x0+bw, y0+bh)), ink[15], nil, Point(0, 0));
	if(tfont != nil)
		for(i := 0; i < len lines; i++)
			img.text(Point(x0+8, y0+8+i*tfont.height), ink[0],
				Point(0, 0), tfont, lines[i]);
}

draw_trooper(img: ref Image, o: Point, t: Trooper, side: int)
{
	x, y: int;
	if(time_lapse){
		# display projection 500 ticks ahead; positions still step 1 dx/tick
		x = int(t.x + 500.0*t.dx);
		y = int(t.y + 500.0*t.dy);
	}else{
		x = int t.x;
		y = int t.y;
	}
	mir := 1;
	if(t.dx < 0.0)
		mir = -1;
	body := ink[11];	# LTCYAN
	if(side != 0)
		body = ink[13];	# LTPURPLE
	if(t.target_side >= 0){
		victim := get_troop(t.target_side, t.target_idx);
		gx := x + mir*13;
		gy := y - 7;
		if(have_spr){
			# static firing pose, bin 5, black drop shadow at (x+1,y)
			draw_spr(img, o.x+x+1, o.y+y, mir, frames[4], frames[4], 0.0, ink[0]);
			draw_spr(img, o.x+x, o.y+y, mir, frames[4], frames[4], 0.0, body);
		}else{
			img.ellipse(Point(o.x+x+1, o.y+y), 3, 3, 0, ink[0], Point(0, 0));
			img.ellipse(Point(o.x+x, o.y+y), 3, 3, 0, body, Point(0, 0));
		}
		aim := ink[15];		# WHITE
		if(side != 0)
			aim = ink[9];	# LTBLUE
		img.line(Point(o.x+gx, o.y+gy), Point(o.x+int victim.x, o.y+int victim.y),
			Draw->Endsquare, Draw->Endsquare, 0, aim, Point(0, 0));
	}else{
		# walk cycle: SpriteInterpolate(tt%1, imgs[tt%6], imgs[(tt+1)%6]),
		# tt = base + tS*speed, speed = 0.5*|16*v| = 8*|v| (v in px/tick)
		spd := 8.0 * math->sqrt(t.dx*t.dx + t.dy*t.dy);
		tt := t.animate_time_base + now()*spd;
		fi := int math->floor(tt);
		f := tt - real fi;
		if(have_spr){
			a := frames[imgs[fi % FRAMES]];
			b := frames[imgs[(fi+1) % FRAMES]];
			draw_spr(img, o.x+x+1, o.y+y, mir, a, b, f, ink[0]);
			draw_spr(img, o.x+x, o.y+y, mir, a, b, f, body);
		}else{
			img.ellipse(Point(o.x+x+1, o.y+y), 3, 3, 0, ink[0], Point(0, 0));
			img.ellipse(Point(o.x+x, o.y+y), 3, 3, 0, body, Point(0, 0));
		}
	}
}

# draw the sprite morphed fraction f of the way from a to b, mirrored
# about the vertical through (x,y) when mir = -1, all elements in col
draw_spr(img: ref Image, x, y, mir: int, a, b: array of El, f: real, col: ref Image)
{
	n := len a;
	if(len b < n)
		n = len b;
	for(i := 0; i < n; i++){
		x1 := lerp(a[i].x1, b[i].x1, f);
		y1 := lerp(a[i].y1, b[i].y1, f);
		x2 := lerp(a[i].x2, b[i].x2, f);
		y2 := lerp(a[i].y2, b[i].y2, f);
		img.line(Point(x + mir*x1, y + y1), Point(x + mir*x2, y + y2),
			Draw->Endsquare, Draw->Endsquare, 0, col, Point(0, 0));
	}
}

lerp(a, b: int, f: real): int
{
	return int (real a + f * real (b - a));
}

get_troop(side, i: int): Trooper
{
	if(side == 0)
		return tr0[i];
	return tr1[i];
}

put_troop(side, i: int, t: Trooper)
{
	if(side == 0)
		tr0[i] = t;
	else
		tr1[i] = t;
}

now(): real
{
	return real sys->millisec() / 1000.0;
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

frnd(): real
{
	if(rand == nil)
		return real(sys->millisec() & 1023) / 1024.0;
	return real rand->rand(1073741824) / 1073741824.0;
}

# How wide a block of text is, which is the font's business and not a
# count of characters: these panels used to size themselves in 8-pixel
# cells, which is exactly what stops being true with a real font.
widest(f: ref Font, lines: array of string): int
{
	w := 0;
	for(i := 0; i < len lines; i++){
		lw := f.width(lines[i]);
		if(lw > w)
			w = lw;
	}
	return w;
}
