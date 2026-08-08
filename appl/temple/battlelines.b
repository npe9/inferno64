implement Battlelines;

# TempleOS Demo/Games/BattleLines.HC — troop swarm combat
# GAP: no soldier sprites / SpriteInterpolate — circles + aim lines
# GAP: no GrPrint troop counts — corner bars; no menu TimeLapse/TapMode checkmarks
# GAP: mouse wheel force — , . adjust radius; buttons 4/8 if wm sends them
# GAP: RegWrite / PopUpOk help omitted

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

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

Battlelines: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

TROOPERS_NUM: con 100;
TAP_MODE_RADIUS: con 50;
AI_NOTHING, AI_TARGET, AI_RANDOM, AI_AI_NUM: con iota;

Trooper: adt {
	x, y, dx, dy: real;
	att, def, rng, player: int;
	animate_time_base, fire_end_time: real;
	target_side, target_idx: int;
};

win: ref Window;
ink: array of ref Image;
tr0, tr1: array of Trooper;
time_lapse := 0;
tap_mode := 0;
ai_mode := 0;
ai_targets: array of int;
fire_end_time := 0.0;
wheel_z := 25;
mx, my: int;
ptr_lb, ptr_rb: int;
have_tone := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
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
	cols := array[] of {
		Draw->Black, Draw->Blue, Draw->Green, Draw->Cyan,
		Draw->Red, Draw->Magenta, Draw->Darkyellow, Draw->Grey,
		int 16r444444FF, Draw->Paleblue, Draw->Palegreen, Draw->Palebluegreen,
		int 16rFF8888FF, int 16rFF88FFFF, Draw->Yellow, Draw->White
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	tr0 = array[TROOPERS_NUM] of Trooper;
	tr1 = array[TROOPERS_NUM] of Trooper;
	ai_targets = array[10] of int;
	game_init();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 40);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		handleptr(p);
	k := <-win.ctxt.kbd =>
		case k {
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
			if(wheel_z > 5)
				wheel_z--;
		'.' or '+' or '=' =>
			if(wheel_z < 120)
				wheel_z++;
		}
	<-ticks =>
		if(ai_mode == AI_TARGET)
			do_ai_target();
		update_human_velocities();
		update_pos();
		resolve_firing();
		redraw();
	}
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
	wheel_z = 25;
	for(i := 0; i < 10; i++){
		ai_targets[i] = rn(TROOPERS_NUM);
		dx := rn(65536) - 32768;
		dy := rn(65536) - 32768;
		for(j := 0; j < 10; j++){
			idx := i*10 + j;
			tr0[idx] = Trooper(
				real(w - 100 - i*10), real(h/2 - 50 + j*10),
				0.0, 0.0, 3, 10, 50*50, 0,
				10.0 * rnreal(), 0.0, -1, -1);
			t1 := Trooper(
				real(100 + i*10), real(h/2 - 50 + j*10),
				0.0, 0.0, 3, 10, 50*50, 1,
				10.0 * rnreal(), 0.0, -1, -1);
			if(ai_mode == AI_RANDOM){
				t1.dx = real dx / 2048.0;
				t1.dy = real dy / 2048.0;
			}
			tr1[idx] = t1;
		}
	}
	ai_mode = rn(AI_AI_NUM);
}

handleptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	mx = p.xy.x - img.r.min.x;
	my = p.xy.y - img.r.min.y;
	ptr_lb = (p.buttons & 1) != 0;
	ptr_rb = (p.buttons & 2) != 0;
	if(p.buttons & 4){
		if(wheel_z > 5)
			wheel_z--;
	}
	if(p.buttons & 8){
		if(wheel_z < 120)
			wheel_z++;
	}
}

do_ai_target()
{
	for(i := 0; i < 10; i++){
		t0 := tr0[ai_targets[i]];
		for(j := 0; j < 10; j++){
			idx := i*10 + j;
			t1 := tr1[idx];
			t1.dx = (t0.x - t1.x) / 2048.0;
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
	for(i = 0; i < TROOPERS_NUM; i++){
		t := tr0[i];
		if(time_lapse){
			t.x += 500.0 * t.dx;
			t.y += 500.0 * t.dy;
		}else{
			t.x += t.dx;
			t.y += t.dy;
		}
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
		if(time_lapse){
			t.x += 500.0 * t.dx;
			t.y += 500.0 * t.dy;
		}else{
			t.x += t.dx;
			t.y += t.dy;
		}
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
				if(have_tone)
					tone->beep(86, 40);
			}
			if(dd < t1.rng && t1.target_side < 0){
				fire_end_time = ts + 0.125;
				t1.fire_end_time = fire_end_time;
				t1.target_side = 0;
				t1.target_idx = i;
				tr1[j] = t1;
				if(have_tone)
					tone->beep(86, 40);
			}
		}
	}
	if(ts >= fire_end_time && have_tone)
		tone->stop();
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
		for(i = 0; i < TROOPERS_NUM; i++){
			t := tr0[i];
			dx := real(mx) - t.x;
			dy := real(my) - t.y;
			d := dx*dx + dy*dy;
			r2 := real(TAP_MODE_RADIUS * TAP_MODE_RADIUS);
			if(d > 0.0 && d < r2){
				gap := r2 - d;
				intensity := gap * gap * gap;
				t.dx -= intensity * dx / d;
				t.dy -= intensity * dy / d;
			}else{
				t.dx *= 0.8;
				t.dy *= 0.8;
			}
			tr0[i] = t;
		}
	}else if(active){
		repulsive := (wheel_z > 0) != (ptr_rb != 0);
		j := 0.25 * real(wheel_z);
		if(repulsive)
			j = -j;
		for(i = 0; i < TROOPERS_NUM; i++){
			t := tr0[i];
			dx := real(mx) - t.x;
			dy := real(my) - t.y;
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
	h := img.r.dy();
	o := img.r.min;
	img.draw(img.r, ink[0], nil, Point(0, 0));
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
		img.ellipse(Point(o.x+mx, o.y+my), TAP_MODE_RADIUS, TAP_MODE_RADIUS, 1, ink[14], Point(0, 0));
	else{
		active := ptr_lb || ptr_rb;
		repulsive := (wheel_z > 0) != (ptr_rb != 0);
		col := ink[1];
		if(repulsive){
			if(active)
				col = ink[12];
		}else if(active)
			col = ink[10];
		rad := wheel_z;
		if(rad < 1)
			rad = 1;
		img.ellipse(Point(o.x+mx, o.y+my), rad, rad, 1, col, Point(0, 0));
	}
	# troop strength bars (top corners)
	bar0 := (w - 20) * cnt0 / TROOPERS_NUM;
	bar1 := (w - 20) * cnt1 / TROOPERS_NUM;
	img.draw(Rect((o.x+10, o.y+4), (o.x+10+bar0, o.y+8)), ink[11], nil, Point(0, 0));
	img.draw(Rect((o.x+w-10-bar1, o.y+4), (o.x+w-10, o.y+8)), ink[13], nil, Point(0, 0));
	img.flush(Draw->Flushnow);
}

draw_trooper(img: ref Image, o: Point, t: Trooper, side: int)
{
	x := int t.x;
	y := int t.y;
	spd := 0.5 * math->sqrt(t.dx*t.dx + t.dy*t.dy);
	pulse := int(3.0 + 2.0 * math->sin(t.animate_time_base + now()*spd));
	if(pulse < 2)
		pulse = 2;
	body := ink[11];
	edge := ink[15];
	if(side != 0){
		body = ink[13];
		edge = ink[10];
	}
	if(t.target_side >= 0){
		victim := get_troop(t.target_side, t.target_idx);
		gx := x; gy := y - 7;
		if(t.dx < 0.0)
			gx -= 13;
		else
			gx += 13;
		img.ellipse(Point(o.x+x+1, o.y+y+1), pulse, pulse, 0, ink[0], Point(0, 0));
		img.ellipse(Point(o.x+x, o.y+y), pulse, pulse, 0, body, Point(0, 0));
		aim := edge;
		if(side != 0)
			aim = ink[10];
		img.line(Point(o.x+gx, o.y+gy), Point(o.x+int victim.x, o.y+int victim.y),
			Draw->Enddisc, Draw->Enddisc, 1, aim, Point(0, 0));
	}else{
		img.ellipse(Point(o.x+x+1, o.y+y+1), pulse, pulse, 0, ink[0], Point(0, 0));
		img.ellipse(Point(o.x+x, o.y+y), pulse, pulse, 0, body, Point(0, 0));
	}
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

rnreal(): real
{
	if(rand == nil)
		return real(sys->millisec() & 1023) / 1023.0;
	return real(rand->rand(1000)) / 1000.0;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
