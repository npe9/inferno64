implement Talons;

# TempleOS Demo/Games/Talons.HC — catch fish from a low-flying plane
# GAP: 3D terrain/panels/claw sprites → top-down height map + line claws
# GAP: MP rendering, birds as scenery dots; background song
# arrows steer  Enter restart  q quit

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

Talons: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MAPW: con 64;
MAPH: con 64;
FISHN: con 10;
BIRDN: con 24;
WATER: con 12;
VIEW: con 640;

win: ref Window;
font: ref Font;
black, water, grass, rock, snow, plane, fishc, birdc, claw, green, red, white: ref Image;
have_tone := 0;
blink_on := 0;

elev: array of array of int;
fish_x, fish_y, fish_alive: array of int;
bird_x, bird_y, bird_a: array of int;
px, py, heading, speed, plane_z: real;
fish_left := 0;
claws_down: real;
t0, tf: int;
best_score: real;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
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
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	black = d.color(Draw->Black);
	water = d.color(Draw->Blue);
	grass = d.color(Draw->Green);
	rock = d.color(int 16r888888FF);
	snow = d.color(Draw->White);
	plane = d.color(Draw->Yellow);
	fishc = d.color(Draw->Cyan);
	birdc = d.color(int 16rFFAA00FF);
	claw = d.color(Draw->Darkyellow);
	green = d.color(Draw->Green);
	red = d.color(Draw->Red);
	white = d.color(Draw->White);
	best_score = 9999.0;
	if(scorestore != nil)
		best_score = scorestore->loadreal("talons", best_score);
	game_init();
	win.reshape(Rect((0, 0), (VIEW, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

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
		Keyboard->Left or 'a' or 'A' =>
			heading += 0.08;
		Keyboard->Right or 'd' or 'D' =>
			heading -= 0.08;
		Keyboard->Up or 'w' or 'W' =>
			speed += 0.15;
		Keyboard->Down or 's' or 'S' =>
			speed -= 0.15;
		}
	<-ticks =>
		step(0.033);
		blink_on = (sys->millisec() / 250) % 2;
		redraw();
	}
}

game_init()
{
	elev = array[MAPH] of { * => array[MAPW] of { * => 0 } };
	gen_terrain();
	fish_x = array[FISHN] of int;
	fish_y = array[FISHN] of int;
	fish_alive = array[FISHN] of int;
	place_fish();
	bird_x = array[BIRDN] of int;
	bird_y = array[BIRDN] of int;
	bird_a = array[BIRDN] of int;
	for(i := 0; i < BIRDN; i++){
		bird_x[i] = rn(MAPW);
		bird_y[i] = rn(MAPH);
		bird_a[i] = rn(628);
	}
	px = real MAPW / 2.0;
	py = real MAPH / 2.0;
	heading = 0.0;
	speed = 2.0;
	plane_z = 20.0;
	fish_left = FISHN;
	claws_down = 0.0;
	tf = 0;
	t0 = sys->millisec();
}

gen_terrain()
{
	for(y := 0; y < MAPH; y++)
		for(x := 0; x < MAPW; x++)
			elev[y][x] = WATER + rn(8);
	for(i := 0; i < 80; i++){
		cx := rn(MAPW);
		cy := rn(MAPH);
		r := 2 + rn(6);
		h := WATER + rn(25);
		for(dy := -r; dy <= r; dy++)
			for(dx := -r; dx <= r; dx++){
				nx := cx + dx;
				ny := cy + dy;
				if(nx < 0 || nx >= MAPW || ny < 0 || ny >= MAPH)
					continue;
				if(dx*dx + dy*dy <= r*r)
					elev[ny][nx] += h;
			}
	}
	for(ty := 0; ty < MAPH; ty++)
		for(tx := 0; tx < MAPW; tx++)
			if(elev[ty][tx] < WATER)
				elev[ty][tx] = WATER;
}

place_fish()
{
	n := 0;
	for(t := 0; t < 5000 && n < FISHN; t++){
		fx := rn(MAPW);
		fy := rn(MAPH);
		if(elev[fy][fx] > WATER + 1)
			continue;
		fish_x[n] = fx;
		fish_y[n] = fy;
		fish_alive[n] = 1;
		n++;
	}
	for(; n < FISHN; n++){
		fish_x[n] = rn(MAPW);
		fish_y[n] = rn(MAPH);
		fish_alive[n] = 1;
	}
}

step(dt: real)
{
	if(tf)
		return;
	px += speed * dt * math->cos(heading);
	py += speed * dt * math->sin(heading);
	if(px < 0.0) px += real MAPW;
	if(px >= real MAPW) px -= real MAPW;
	if(py < 0.0) py += real MAPH;
	if(py >= real MAPH) py -= real MAPH;
	if(speed < 0.5) speed = 0.5;
	if(speed > 5.0) speed = 5.0;

	gnd := real elev[int py][int px];
	if(plane_z > gnd + 2.0)
		plane_z -= 0.4 * dt * 10.0;
	else
		plane_z = gnd + 2.0;

	claws_down = 0.0;
	if(plane_z < gnd + 4.0){
		best_d := 999.0;
		best_i := -1;
		for(i := 0; i < FISHN; i++){
			if(!fish_alive[i])
				continue;
			dx := real fish_x[i] - px;
			dy := real fish_y[i] - py;
			d := math->sqrt(dx*dx + dy*dy);
			if(d < best_d){
				best_d = d;
				best_i = i;
			}
		}
		if(best_i >= 0 && best_d < 4.0){
			claws_down = 1.0 - best_d / 4.0;
			if(best_d < 1.5){
				fish_alive[best_i] = 0;
				fish_left--;
				if(have_tone)
					tone->beep(74, 100);
				if(!fish_left){
					tf = sys->millisec();
					elapsed := real(tf - t0) / 1000.0;
					if(elapsed < best_score){
						best_score = elapsed;
						if(scorestore != nil)
							scorestore->savereal("talons", best_score);
					}
				}
			}
		}
	}

	for(i := 0; i < BIRDN; i++){
		bird_x[i] += int(0.3 * math->cos(real bird_a[i] / 100.0));
		bird_y[i] += int(0.3 * math->sin(real bird_a[i] / 100.0));
		bird_a[i] = (bird_a[i] + 3) % 628;
		if(bird_x[i] < 0) bird_x[i] += MAPW;
		if(bird_x[i] >= MAPW) bird_x[i] -= MAPW;
		if(bird_y[i] < 0) bird_y[i] += MAPH;
		if(bird_y[i] >= MAPH) bird_y[i] -= MAPH;
	}
}

terrain_col(h: int): ref Image
{
	if(h <= WATER + 1)
		return water;
	if(h < 22)
		return grass;
	if(h < 35)
		return rock;
	return snow;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, black, nil, Point(0, 0));
	o := img.r.min;
	scale := 8;
	ox := int(px * real scale) - VIEW/2;
	oy := int(py * real scale) - 200;
	for(my := 0; my < MAPH; my++)
		for(mx := 0; mx < MAPW; mx++){
			sx := mx * scale - ox;
			sy := my * scale - oy;
			if(sx < -scale || sx >= VIEW || sy < -scale || sy >= 440)
				continue;
			col := terrain_col(elev[my][mx]);
			img.draw(Rect((o.x+sx, o.y+sy), (o.x+sx+scale-1, o.y+sy+scale-1)),
				col, nil, Point(0, 0));
		}
	for(i := 0; i < FISHN; i++){
		if(!fish_alive[i])
			continue;
		sx := fish_x[i] * scale - ox;
		sy := fish_y[i] * scale - oy;
		if(sx >= 0 && sx < VIEW && sy >= 0 && sy < 440)
			img.fillellipse(Point(o.x+sx+scale/2, o.y+sy+scale/2), 3, 2, fishc, Point(0, 0));
	}
	for(bi := 0; bi < BIRDN; bi++){
		sx := bird_x[bi] * scale - ox;
		sy := bird_y[bi] * scale - oy - 20;
		if(sx >= 0 && sx < VIEW && sy >= 0 && sy < 440)
			img.fillellipse(Point(o.x+sx, o.y+sy), 2, 2, birdc, Point(0, 0));
	}
	cx := VIEW/2;
	cy := 220;
	img.line(Point(o.x+cx-8, o.y+cy), Point(o.x+cx+8, o.y+cy), 0, 0, 0, plane, Point(0, 0));
	img.line(Point(o.x+cx, o.y+cy-4), Point(o.x+cx, o.y+cy+4), 0, 0, 0, plane, Point(0, 0));
	if(claws_down > 0.0){
		drop := int(claws_down * 40.0);
		img.line(Point(o.x+cx-12, o.y+cy+drop), Point(o.x+cx, o.y+cy+drop+20), 0, 0, 0, claw, Point(0, 0));
		img.line(Point(o.x+cx+12, o.y+cy+drop), Point(o.x+cx, o.y+cy+drop+20), 0, 0, 0, claw, Point(0, 0));
		img.line(Point(o.x+cx, o.y+cy+drop+20), Point(o.x+cx-8, o.y+cy+drop+28), 0, 0, 0, claw, Point(0, 0));
		img.line(Point(o.x+cx, o.y+cy+drop+20), Point(o.x+cx+8, o.y+cy+drop+28), 0, 0, 0, claw, Point(0, 0));
	}
	if(font != nil){
		elapsed := real(sys->millisec() - t0) / 1000.0;
		if(tf)
			elapsed = real(tf - t0) / 1000.0;
		if(elapsed < 5.0 && blink_on)
			img.text(Point(o.x+VIEW/2-70, o.y+40), white, Point(0, 0), font, "Catch 10 Fish");
		msg := sys->sprint("Fish:%d Speed:%3.1f Time:%3.2fs Best:%3.2fs",
			fish_left, speed, elapsed, best_score);
		img.text(Point(o.x+4, o.y+448), green, Point(0, 0), font, msg);
		if(tf && blink_on)
			img.text(Point(o.x+VIEW/2-56, o.y+220), red, Point(0, 0), font, "Game Completed");
	}
	img.flush(Draw->Flushnow);
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
