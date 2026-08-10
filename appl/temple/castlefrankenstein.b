implement Castlefrankenstein;

# TempleOS Demo/Games/CastleFrankenstein.HC — maze shooter
# FPS view via math/draw3d; LOS still gates combat + visible walls
# GAP: no TempleOS Sprite3 map art / song; RegWrite best not persisted
# up/down move  left/right turn  space=fire  Enter restart  q quit

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;
	Vector: import draw3d;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "rand.m";
	rand: Rand;

include "tone.m";
	tone: Tone;

Castlefrankenstein: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MW: con 32;
MH: con 24;
CELL: con 16;
MONS: con 10;
VIEWW: con 24;
VIEWH: con 18;
SCRN_SCALE: con 480;
WALL_H: con 1.15;
PI: con 3.141592653589793;

T_EMPTY: con 0;
T_FLOOR: con 1;
T_PLANT: con 2;

# Painter sort keys for billboards
Bill: adt {
	x, y, z, dist: real;
	kind: int;	# 0 plant 1 mon 2 muzzle
};

win: ref Window;
d3c: ref Draw3d->Context;
font: ref Font;
black, floorc, plantc, playerc, monsc, fog, red, green, cyan, yellow, wallc, sky: ref Image;
have_tone := 0;
blink_on := 0;

map: array of array of int;
visible: array of array of int;
man_x, man_y: real;
man_a: real;
mon_x, mon_y, mon_dead, mon_phase: array of int;
monsters_left := 0;
fire_t0 := 0;
t0, tf: int;
best_score: real;
scrn_x, scrn_y: int;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	# Prefer protocol-backed draw3ddev; fall back to software draw3d.dis.
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	if(draw3d == nil){
		sys->fprint(sys->fildes(2), "castlefrankenstein: cannot load draw3d: %r\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	draw3d->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS CastleFrankenstein", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	black = d.color(Draw->Black);
	floorc = d.color(int 16r666666FF);
	plantc = d.color(int 16r886644FF);
	playerc = d.color(Draw->Cyan);
	monsc = d.color(Draw->Red);
	fog = d.color(int 16r111111FF);
	red = d.color(Draw->Red);
	green = d.color(Draw->Green);
	cyan = d.color(Draw->Cyan);
	yellow = d.color(Draw->Yellow);
	wallc = d.color(int 16rAA8866FF);
	sky = d.color(int 16r224466FF);
	best_score = 9999.0;
	game_init();
	win.reshape(Rect((0, 0), (VIEWW*CELL, VIEWH*CELL+20)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 33);
	mtick := chan of int;
	spawn mon_timer(mtick, 800);
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
		' ' =>
			do_fire();
		Keyboard->Left or 'a' or 'A' =>
			man_a += 0.15;
		Keyboard->Right or 'd' or 'D' =>
			man_a -= 0.15;
		Keyboard->Up or 'w' or 'W' =>
			try_move(man_a, 0.35);
		Keyboard->Down or 's' or 'S' =>
			try_move(man_a + PI, 0.35);
		}
	<-mtick =>
		if(!tf)
			move_monsters();
	<-ticks =>
		blink_on = (sys->millisec() / 250) % 2;
		redraw();
	}
}

game_init()
{
	map = array[MH] of { * => array[MW] of { * => T_EMPTY } };
	visible = array[MH] of { * => array[MW] of { * => 0 } };
	gen_map();
	(man_x, man_y) = find_start();
	man_a = 0.0;
	scrn_x = int man_x - VIEWW/2;
	scrn_y = int man_y - VIEWH/2;
	clamp_view();
	mon_x = array[MONS] of int;
	mon_y = array[MONS] of int;
	mon_dead = array[MONS] of int;
	mon_phase = array[MONS] of int;
	for(i := 0; i < MONS; i++){
		mon_dead[i] = 0;
		mon_phase[i] = rn(628);
		(x, y) := rand_floor();
		mon_x[i] = x;
		mon_y[i] = y;
	}
	monsters_left = MONS;
	tf = 0;
	t0 = sys->millisec();
	fire_t0 = 0;
}

gen_map()
{
	for(my := 0; my < MH; my++)
		for(mx := 0; mx < MW; mx++)
			map[my][mx] = T_EMPTY;
	rooms := 8;
	for(r := 0; r < rooms; r++){
		rw := 3 + rn(5);
		rh := 3 + rn(4);
		rx := 1 + rn(MW - rw - 2);
		ry := 1 + rn(MH - rh - 2);
		for(cy := ry; cy < ry+rh; cy++)
			for(cx := rx; cx < rx+rw; cx++)
				map[cy][cx] = T_FLOOR;
	}
	for(c := 0; c < rooms-1; c++){
		(x1, y1) := find_floor();
		(x2, y2) := find_floor();
		for(tx := min(x1,x2); tx <= max(x1,x2); tx++)
			if(map[y1][tx] == T_EMPTY)
				map[y1][tx] = T_FLOOR;
		for(ty := min(y1,y2); ty <= max(y1,y2); ty++)
			if(map[ty][x2] == T_EMPTY)
				map[ty][x2] = T_FLOOR;
	}
	for(jy := 1; jy < MH-1; jy++)
		for(jx := 1; jx < MW-1; jx++)
			if(map[jy][jx] == T_FLOOR && rn(100) < 8)
				map[jy][jx] = T_PLANT;
}

find_start(): (real, real)
{
	for(t := 0; t < 1000; t++){
		x := 1 + rn(MW-2);
		y := 1 + rn(MH-2);
		if(map[y][x] == T_FLOOR || map[y][x] == T_PLANT)
			return (real x + 0.5, real y + 0.5);
	}
	return (real (MW/2), real (MH/2));
}

find_floor(): (int, int)
{
	for(t := 0; t < 1000; t++){
		x := 1 + rn(MW-2);
		y := 1 + rn(MH-2);
		if(map[y][x] != T_EMPTY)
			return (x, y);
	}
	return (MW/2, MH/2);
}

rand_floor(): (int, int)
{
	for(t := 0; t < 1000; t++){
		(x, y) := find_floor();
		if(absi(int man_x - x) < 3 && absi(int man_y - y) < 3)
			continue;
		ok := 1;
		for(i := 0; i < MONS; i++)
			if(!mon_dead[i] && mon_x[i] == x && mon_y[i] == y)
				ok = 0;
		if(ok)
			return (x, y);
	}
	return find_floor();
}

tile_ok(tx, ty: int): int
{
	if(tx < 0 || tx >= MW || ty < 0 || ty >= MH)
		return 0;
	if(map[ty][tx] == T_EMPTY)
		return 0;
	return 1;
}

try_move(a, step: real)
{
	nx := man_x + step * math->cos(a);
	ny := man_y - step * math->sin(a);
	tx := int nx;
	ty := int ny;
	if(!tile_ok(tx, ty))
		return;
	man_x = nx;
	man_y = ny;
	if(man_x - real scrn_x > real (VIEWW/2) - 2.0){
		scrn_x += VIEWW/2;
		clamp_view();
	}
	if(man_x - real scrn_x < real (VIEWW/2) - real VIEWW + 2.0){
		scrn_x -= VIEWW/2;
		clamp_view();
	}
	if(man_y - real scrn_y > real (VIEWH/2) - 2.0){
		scrn_y += VIEWH/2;
		clamp_view();
	}
	if(man_y - real scrn_y < real (VIEWH/2) - real VIEWH + 2.0){
		scrn_y -= VIEWH/2;
		clamp_view();
	}
}

clamp_view()
{
	if(scrn_x < VIEWW/2) scrn_x = VIEWW/2;
	if(scrn_y < VIEWH/2) scrn_y = VIEWH/2;
	if(scrn_x > MW - VIEWW/2) scrn_x = MW - VIEWW/2;
	if(scrn_y > MH - VIEWH/2) scrn_y = MH - VIEWH/2;
}

do_fire()
{
	fire_t0 = sys->millisec();
	if(have_tone)
		tone->beep(53, 80);
	ca := math->cos(man_a);
	sa := -math->sin(man_a);
	for(i := 0; i < MONS; i++){
		if(mon_dead[i])
			continue;
		dx := real mon_x[i] + 0.5 - man_x;
		dy := real mon_y[i] + 0.5 - man_y;
		d := math->sqrt(dx*dx + dy*dy);
		if(d < 0.5 || d > 12.0)
			continue;
		if(!los(int man_x, int man_y, mon_x[i], mon_y[i]))
			continue;
		dx /= d;
		dy /= d;
		if(dx*ca + dy*sa > 0.96){
			mon_dead[i] = 1;
			monsters_left--;
			if(!monsters_left){
				tf = sys->millisec();
				elapsed := real(tf - t0) / 1000.0;
				if(elapsed < best_score)
					best_score = elapsed;
			}
		}
	}
}

move_monsters()
{
	t := sys->millisec();
	for(i := 0; i < MONS; i++){
		if(mon_dead[i])
			continue;
		osc := (t/400 + mon_phase[i]) % 628;
		ox := 0;
		oy := 0;
		if(i & 1)
			ox = int(0.3 * math->sin(real osc / 100.0));
		else
			oy = int(0.3 * math->sin(real osc / 100.0));
		nx := mon_x[i] + ox;
		ny := mon_y[i] + oy;
		if(tile_ok(nx, ny)){
			mon_x[i] = nx;
			mon_y[i] = ny;
		}
	}
}

los(x1, y1, x2, y2: int): int
{
	dx := absi(x2 - x1);
	dy := absi(y2 - y1);
	sx := 1;
	if(x1 > x2) sx = -1;
	sy := 1;
	if(y1 > y2) sy = -1;
	err := dx - dy;
	x := x1;
	y := y1;
	for(;;){
		if(x == x2 && y == y2)
			return 1;
		if(map[y][x] == T_EMPTY && !(x == x1 && y == y1))
			return 0;
		e2 := 2 * err;
		if(e2 > -dy){
			err -= dy;
			x += sx;
		}
		if(e2 < dx){
			err += dx;
			y += sy;
		}
	}
}

# World: x = map-x, y = height, z = map-y. Camera looks along man_a.
cf_xform(v: Vector): Vector
{
	tx := v.x - man_x;
	ty := v.y - 0.55;
	tz := v.z - man_y;
	ca := math->cos(man_a);
	sa := math->sin(man_a);
	rx := tx * sa + tz * ca;
	rz := tx * ca - tz * sa;
	if(rz < 0.2)
		rz = 0.2;
	sx := (real SCRN_SCALE / 2.0) * rx / rz;
	sy := (real SCRN_SCALE / 2.0) * ty / rz;
	return Vector(sx / d3c.mx, sy / d3c.my, -rz);
}

setup3d(img: ref Image)
{
	if(d3c == nil)
		d3c = draw3d->context(img);
	else
		draw3d->resize(d3c, img);
	draw3d->viewport(d3c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	draw3d->setz(d3c, 0);
	draw3d->setzclip(d3c, 0);
	draw3d->settransform(d3c, cf_xform);
	draw3d->mode(Draw3d->PROJ);
	draw3d->identity();
	draw3d->mode(Draw3d->MODEL);
	draw3d->identity();
}

solid(mx, my: int): int
{
	if(mx < 0 || mx >= MW || my < 0 || my >= MH)
		return 1;
	return map[my][mx] == T_EMPTY;
}

draw_wall(x0, z0, x1, z1: real)
{
	h := WALL_H;
	draw3d->setcolour(d3c, wallc);
	draw3d->line3(d3c, Vector(x0, 0.0, z0), Vector(x1, 0.0, z1), 0);
	draw3d->line3(d3c, Vector(x0, h, z0), Vector(x1, h, z1), 0);
	draw3d->line3(d3c, Vector(x0, 0.0, z0), Vector(x0, h, z0), 0);
	draw3d->line3(d3c, Vector(x1, 0.0, z1), Vector(x1, h, z1), 0);
}

draw_floor_tile(mx, my: int)
{
	x0 := real mx;
	z0 := real my;
	x1 := x0 + 1.0;
	z1 := z0 + 1.0;
	draw3d->setcolour(d3c, floorc);
	draw3d->line3(d3c, Vector(x0, 0.0, z0), Vector(x1, 0.0, z0), 0);
	draw3d->line3(d3c, Vector(x1, 0.0, z0), Vector(x1, 0.0, z1), 0);
	draw3d->line3(d3c, Vector(x1, 0.0, z1), Vector(x0, 0.0, z1), 0);
	draw3d->line3(d3c, Vector(x0, 0.0, z1), Vector(x0, 0.0, z0), 0);
}

cell_walls(mx, my: int)
{
	x0 := real mx;
	z0 := real my;
	x1 := x0 + 1.0;
	z1 := z0 + 1.0;
	if(solid(mx, my-1))
		draw_wall(x0, z0, x1, z0);
	if(solid(mx, my+1))
		draw_wall(x0, z1, x1, z1);
	if(solid(mx-1, my))
		draw_wall(x0, z0, x0, z1);
	if(solid(mx+1, my))
		draw_wall(x1, z0, x1, z1);
}

bill_insert(bills: array of Bill, n: int, b: Bill): int
{
	# insert by descending dist (far first)
	i := n;
	while(i > 0 && bills[i-1].dist < b.dist){
		bills[i] = bills[i-1];
		i--;
	}
	bills[i] = b;
	return n + 1;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	w := img.r.dx();
	h := img.r.dy();
	o := img.r.min;
	cx := w / 2;
	cy := h / 2;

	img.draw(Rect((o.x, o.y), (o.x+w, o.y+h/2)), sky, nil, Point(0, 0));
	img.draw(Rect((o.x, o.y+h/2), (o.x+w, o.y+h)), fog, nil, Point(0, 0));
	setup3d(img);

	# refresh visibility + draw nearby floor/walls (LOS gated)
	for(my := 0; my < MH; my++)
		for(mx := 0; mx < MW; mx++){
			vis := 0;
			if(map[my][mx] != T_EMPTY)
				vis = los(int man_x, int man_y, mx, my);
			visible[my][mx] = vis;
			if(!vis)
				continue;
			dx := real mx + 0.5 - man_x;
			dz := real my + 0.5 - man_y;
			if(dx*dx + dz*dz > 14.0*14.0)
				continue;
			draw_floor_tile(mx, my);
			cell_walls(mx, my);
		}

	bills := array[MONS + 64] of Bill;
	nb := 0;
	for(my = 0; my < MH; my++)
		for(mx = 0; mx < MW; mx++){
			if(map[my][mx] != T_PLANT || !visible[my][mx])
				continue;
			px := real mx + 0.5;
			pz := real my + 0.5;
			dd := (px - man_x)*(px - man_x) + (pz - man_y)*(pz - man_y);
			if(nb < len bills)
				nb = bill_insert(bills, nb, Bill(px, 0.35, pz, dd, 0));
		}
	for(i := 0; i < MONS; i++){
		if(mon_dead[i])
			continue;
		tx := mon_x[i];
		ty := mon_y[i];
		if(!visible[ty][tx])
			continue;
		px := real tx + 0.5;
		pz := real ty + 0.5;
		dd := (px - man_x)*(px - man_x) + (pz - man_y)*(pz - man_y);
		if(nb < len bills)
			nb = bill_insert(bills, nb, Bill(px, 0.45, pz, dd, 1));
	}
	if(sys->millisec() - fire_t0 < 150){
		fx := man_x + math->cos(man_a) * 1.2;
		fz := man_y - math->sin(man_a) * 1.2;
		if(nb < len bills)
			nb = bill_insert(bills, nb, Bill(fx, 0.5, fz, 1.0, 2));
	}

	for(bi := 0; bi < nb; bi++){
		b := bills[bi];
		(sp, ez, ok) := draw3d->project(d3c, Vector(b.x, b.y, b.z));
		if(!ok)
			continue;
		zd := -ez;
		if(zd < 0.4)
			zd = 0.4;
		case b.kind {
		0 =>
			rad := int(18.0 / zd);
			if(rad < 2) rad = 2;
			if(rad > 28) rad = 28;
			img.fillellipse(sp, rad, rad + rad/3, plantc, Point(0, 0));
		1 =>
			rad := int(28.0 / zd);
			if(rad < 3) rad = 3;
			if(rad > 40) rad = 40;
			img.fillellipse(sp, rad, rad + rad/2, monsc, Point(0, 0));
			img.fillellipse(Point(sp.x, sp.y - rad), rad/2, rad/2, red, Point(0, 0));
		2 =>
			img.fillellipse(sp, 5, 5, yellow, Point(0, 0));
		}
	}

	# crosshair
	img.line(Point(o.x+cx-6, o.y+cy), Point(o.x+cx+6, o.y+cy), 0, 0, 0, yellow, Point(0, 0));
	img.line(Point(o.x+cx, o.y+cy-6), Point(o.x+cx, o.y+cy+6), 0, 0, 0, yellow, Point(0, 0));

	# minimap (top-right)
	mmx := o.x + w - 2*MW - 4;
	mmy := o.y + 4;
	img.draw(Rect((mmx-2, mmy-2), (mmx+2*MW+2, mmy+2*MH+2)), black, nil, Point(0, 0));
	for(my = 0; my < MH; my++)
		for(mx = 0; mx < MW; mx++){
			if(map[my][mx] == T_EMPTY)
				continue;
			mc := floorc;
			if(map[my][mx] == T_PLANT)
				mc = plantc;
			if(visible[my][mx])
				img.draw(Rect((mmx+2*mx, mmy+2*my), (mmx+2*mx+1, mmy+2*my+1)), mc, nil, Point(0, 0));
			else
				img.draw(Rect((mmx+2*mx, mmy+2*my), (mmx+2*mx+1, mmy+2*my+1)), fog, nil, Point(0, 0));
		}
	for(mi := 0; mi < MONS; mi++)
		if(!mon_dead[mi])
			img.draw(Rect((mmx+2*mon_x[mi], mmy+2*mon_y[mi]),
				(mmx+2*mon_x[mi]+1, mmy+2*mon_y[mi]+1)), red, nil, Point(0, 0));
	img.draw(Rect((mmx+2*int man_x, mmy+2*int man_y),
		(mmx+2*int man_x+1, mmy+2*int man_y+1)), cyan, nil, Point(0, 0));
	# facing tick
	ex := mmx + 2*int man_x + int(math->cos(man_a)*3.0);
	ey := mmy + 2*int man_y - int(math->sin(man_a)*3.0);
	img.line(Point(mmx+2*int man_x, mmy+2*int man_y), Point(ex, ey), 0, 0, 0, yellow, Point(0, 0));

	if(font != nil){
		elapsed := real(sys->millisec() - t0) / 1000.0;
		if(tf)
			elapsed = real(tf - t0) / 1000.0;
		msg := sys->sprint("Enemy:%d Time:%3.2fs Best:%3.2fs", monsters_left, elapsed, best_score);
		img.text(Point(o.x+4, o.y+h-16), green, Point(0, 0), font, msg);
		if(tf && blink_on)
			img.text(Point(o.x+cx-56, o.y+cy), red, Point(0, 0), font, "Game Completed");
	}
	img.flush(Draw->Flushnow);
}

absi(v: int): int
{
	if(v < 0) return -v;
	return v;
}

min(a, b: int): int
{
	if(a < b) return a;
	return b;
}

max(a, b: int): int
{
	if(a > b) return a;
	return b;
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

mon_timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
