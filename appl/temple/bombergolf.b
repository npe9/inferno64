implement Bombergolf;

# TempleOS Demo/Games/BomberGolf.HC — fly bomber, drop bombs on targets
# arrows turn/speed; space bomb; Enter restart; q quit
# GAP: Sprite3/3D sprites → colored shapes; RegDft best score not persisted

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

Bombergolf: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MAPW: con 600;
MAPH: con 600;
TREES: con 64;
TARGETS: con 10;
FALLMS: con 3000;
EXPMS: con 250;
TANKV: con 10.0;
HITR: con 20;

MDF_TANK: con 0;
MDF_BUNKER: con 1;

win: ref Window;
font: ref Font;
brown, yellow, black, white, red, green, grey, dkgrey, ltgrey: ref Image;
have_tone := 0;
blink_on := 0;

px, py: real;
theta, theta_goal: real;
speed: real;
key_cnt, target_cnt, best_score: int;

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
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS BomberGolf", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	brown = d.color(int 16r8B4513FF);
	yellow = d.color(Draw->Yellow);
	black = d.color(Draw->Black);
	white = d.color(Draw->White);
	red = d.color(Draw->Red);
	green = d.color(Draw->Green);
	grey = d.color(Draw->Grey);
	dkgrey = d.color(int 16r444444FF);
	ltgrey = d.color(int 16rAAAAAAFF);
	best_score = 99999;
	game_init();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 16);
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
		step(0.016);
		blink_on = (sys->millisec() / 120) % 2;
		redraw();
	}
}

game_init()
{
	speed = 20.0;
	px = real(-MAPW / 2);
	py = real(-MAPH / 2);
	theta = theta_goal = math->Pi / 2.0;
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
			tg_th[ti] = real(rn(628)) / 100.0;
		}
	}
	key_cnt = 0;
	target_cnt = TARGETS;
	game_cleanup();
}

game_cleanup()
{
	b := bombs;
	while(b != nil){
		n := b.next;
		b = n;
	}
	bombs = nil;
}

drop_bomb()
{
	bx := -px - 0.8 * real(FALLMS) / 1000.0 * speed * math->sin(theta);
	by := -py - 0.8 * real(FALLMS) / 1000.0 * speed * math->cos(theta);
	bombs = ref Bomb(bx, by, sys->millisec(), 0, bombs);
	if(have_tone)
		tone->beep(62, int(0.8 * real(FALLMS)));
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
				if(have_tone)
					tone->beep(74, EXPMS);
			}
			prev = b;
		}
		b = n;
	}

	if(bombs == nil){
		if(target_cnt > 0)
			steer_tone();
		else if(key_cnt < best_score){
			best_score = key_cnt;
			if(have_tone){
				tone->beep(74, 150);
				sys->sleep(150);
				tone->stop();
				sys->sleep(150);
				tone->beep(74, 150);
				sys->sleep(150);
				tone->stop();
			}
		}else if(have_tone)
			tone->stop();
	}
}

steer_tone()
{
	if(!have_tone)
		return;
	d := wrap(theta_goal - theta);
	amp := 0.1 * (1.0 + absf(d));
	if(amp > 4.0) amp = 4.0;
	if(amp < -3.0) amp = -3.0;
	f := 100 + int(60.0 * amp);
	tone->snd(f);
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
	img.draw(img.r, brown, nil, Point(0, 0));
	w := img.r.dx();
	h := img.r.dy();
	o := img.r.min;
	cx := w / 2;
	cy := h / 2;
	ct := math->cos(theta);
	st := math->sin(theta);

	# map border
	draw_poly(img, o, cx, cy, ct, st,
		array[] of { (-MAPW/2, -MAPH/2), (MAPW/2, -MAPH/2), (MAPW/2, MAPH/2), (-MAPW/2, MAPH/2) },
		black);

	for(ti := 0; ti < TREES; ti++)
		draw_tree(img, o, cx, cy, ct, st, tree_x[ti], tree_y[ti]);

	for(tj := 0; tj < TARGETS; tj++){
		if(tg_dead[tj])
			draw_smoke(img, o, cx, cy, ct, st, tg_x[tj], tg_y[tj]);
		else
			draw_target(img, o, cx, cy, ct, st, tj);
	}

	b := bombs;
	while(b != nil){
		col := red;
		if(blink_on && sys->millisec() - b.t0 > FALLMS)
			col = yellow;
		draw_world_dot(img, o, cx, cy, ct, st, int b.x, int b.y, 4, col);
		b = b.next;
	}

	# player plane at center
	img.draw(Rect((o.x+cx-8, o.y+cy-8), (o.x+cx+8, o.y+cy+8)), white, nil, Point(0, 0));
	img.line(Point(o.x+cx, o.y+cy-10), Point(o.x+cx, o.y+cy+10), 0, 0, 2, black, Point(0, 0));
	img.line(Point(o.x+cx-12, o.y+cy+4), Point(o.x+cx+12, o.y+cy+4), 0, 0, 2, black, Point(0, 0));

	if(font != nil){
		msg := sys->sprint("Targets:%02d  Keys:%04d  Best:%04d", target_cnt, key_cnt, best_score);
		img.text(Point(o.x+4, o.y+4), red, Point(0, 0), font, msg);
		if(!target_cnt && blink_on)
			img.text(Point(o.x+cx-56, o.y+cy-20), red, Point(0, 0), font, "Game Completed");
	}
	img.flush(Draw->Flushnow);
}

draw_target(img: ref Image, o: Point, cx, cy: int, ct, st: real, i: int)
{
	wx := int tg_x[i];
	wy := int tg_y[i];
	if(tg_type[i] == MDF_BUNKER)
		draw_world_rect(img, o, cx, cy, ct, st, wx, wy, 14, 10, grey);
	else
		draw_world_rect(img, o, cx, cy, ct, st, wx, wy, 12, 8, green);
}

draw_tree(img: ref Image, o: Point, cx, cy: int, ct, st: real, wx, wy: int)
{
	draw_world_dot(img, o, cx, cy, ct, st, wx, wy, 6, green);
	draw_world_dot(img, o, cx, cy, ct, st, wx, wy+4, 3, dkgrey);
}

draw_smoke(img: ref Image, o: Point, cx, cy: int, ct, st: real, wx, wy: real)
{
	ts := real(sys->millisec()) / 1000.0;
	for(j := 0; j < 12; j++){
		col := ltgrey;
		if(j & 1)
			col = dkgrey;
		dx := int(15.0 * math->sin(ts/4.0 + real(j*64)) + real(j)/4.0);
		dy := int(10.0 * fulltri(ts/3.0 + real(j)/2.0, 20.0) + real(j)/4.0);
		draw_world_dot(img, o, cx, cy, ct, st, int wx + 5 + dx, int wy + dy, 2, col);
	}
}

draw_world_dot(img: ref Image, o: Point, cx, cy: int, ct, st: real, wx, wy, rad: int, col: ref Image)
{
	(sx, sy) := world_scr(o, cx, cy, ct, st, wx, wy);
	img.draw(Rect((sx-rad, sy-rad), (sx+rad, sy+rad)), col, nil, Point(0, 0));
}

draw_world_rect(img: ref Image, o: Point, cx, cy: int, ct, st: real, wx, wy, rw, rh: int, col: ref Image)
{
	(sx, sy) := world_scr(o, cx, cy, ct, st, wx, wy);
	img.draw(Rect((sx-rw/2, sy-rh/2), (sx+rw/2, sy+rh/2)), col, nil, Point(0, 0));
}

draw_poly(img: ref Image, o: Point, cx, cy: int, ct, st: real, pts: array of (int, int), col: ref Image)
{
	n := len pts;
	if(n < 2)
		return;
	for(i := 0; i < n; i++){
		(x0, y0) := pts[i];
		(x1, y1) := pts[(i+1) % n];
		(sx0, sy0) := world_scr(o, cx, cy, ct, st, x0, y0);
		(sx1, sy1) := world_scr(o, cx, cy, ct, st, x1, y1);
		img.line(Point(sx0, sy0), Point(sx1, sy1), 0, 0, 2, col, Point(0, 0));
	}
}

world_scr(o: Point, cx, cy: int, ct, st: real, wx, wy: int): (int, int)
{
	dx := real(wx) - px;
	dy := real(wy) - py;
	sx := cx + int(dx*ct - dy*st);
	sy := cy + int(dx*st + dy*ct);
	return (o.x+sx, o.y+sy);
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

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
