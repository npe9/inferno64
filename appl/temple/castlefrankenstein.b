implement Castlefrankenstein;

# TempleOS Demo/Games/CastleFrankenstein.HC — maze shooter
# GAP: 3D raycast + sprite map → top-down LOS wedge; monster/plant sprites → shapes
# GAP: background song; RegWrite best score not persisted
# up/down move  left/right turn  space=fire  Enter restart  q quit

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
PI: con 3.141592653589793;

T_EMPTY: con 0;
T_FLOOR: con 1;
T_PLANT: con 2;

win: ref Window;
font: ref Font;
black, floorc, plantc, playerc, monsc, fog, red, green, cyan, yellow: ref Image;
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
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
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

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, black, nil, Point(0, 0));
	o := img.r.min;
	for(y := 0; y < VIEWH; y++)
		for(x := 0; x < VIEWW; x++){
			mx := x + scrn_x - VIEWW/2;
			my := y + scrn_y - VIEWH/2;
			if(mx < 0 || mx >= MW || my < 0 || my >= MH)
				continue;
			vis := los(int man_x, int man_y, mx, my);
			visible[my][mx] = vis;
			if(!vis)
				continue;
			col := floorc;
			if(map[my][mx] == T_PLANT)
				col = plantc;
			if(map[my][mx] == T_EMPTY)
				col = fog;
			img.draw(Rect((o.x+x*CELL, o.y+y*CELL), (o.x+x*CELL+CELL-1, o.y+y*CELL+CELL-1)),
				col, nil, Point(0, 0));
		}
	for(i := 0; i < MONS; i++){
		if(mon_dead[i])
			continue;
		mx := mon_x[i];
		my := mon_y[i];
		if(!visible[my][mx] || !los(int man_x, int man_y, mx, my))
			continue;
		sx := mx - scrn_x + VIEWW/2;
		sy := my - scrn_y + VIEWH/2;
		if(sx < 0 || sx >= VIEWW || sy < 0 || sy >= VIEWH)
			continue;
		img.draw(Rect((o.x+sx*CELL+2, o.y+sy*CELL+2), (o.x+sx*CELL+CELL-3, o.y+sy*CELL+CELL-3)),
			monsc, nil, Point(0, 0));
	}
	psx := int man_x - scrn_x + VIEWW/2;
	psy := int man_y - scrn_y + VIEWH/2;
	img.fillellipse(Point(o.x+psx*CELL+CELL/2, o.y+psy*CELL+CELL/2), CELL/3, CELL/3, playerc, Point(0, 0));
	ex := int(real(psx*CELL+CELL/2) + math->cos(man_a) * real(CELL));
	ey := int(real(psy*CELL+CELL/2) - math->sin(man_a) * real(CELL));
	img.line(Point(o.x+psx*CELL+CELL/2, o.y+psy*CELL+CELL/2), Point(o.x+ex, o.y+ey),
		0, 0, 0, yellow, Point(0, 0));
	if(sys->millisec() - fire_t0 < 150){
		fx := int(man_x + math->cos(man_a) * 2.0);
		fy := int(man_y - math->sin(man_a) * 2.0);
		fs := fx - scrn_x + VIEWW/2;
		fsy := fy - scrn_y + VIEWH/2;
		if(fs >= 0 && fs < VIEWW && fsy >= 0 && fsy < VIEWH)
			img.fillellipse(Point(o.x+fs*CELL+CELL/2, o.y+fsy*CELL+CELL/2), 4, 4, red, Point(0, 0));
	}
	# minimap
	for(my := 0; my < MH; my++)
		for(mx := 0; mx < MW; mx++){
			if(map[my][mx] == T_EMPTY)
				continue;
			mc := floorc;
			if(map[my][mx] == T_PLANT)
				mc = plantc;
			img.draw(Rect((o.x+VIEWW*CELL-2*MW+2*mx, o.y+2*my),
				(o.x+VIEWW*CELL-2*MW+2*mx+1, o.y+2*my+1)), mc, nil, Point(0, 0));
		}
	for(mi := 0; mi < MONS; mi++)
		if(!mon_dead[mi])
			img.draw(Rect((o.x+VIEWW*CELL-2*MW+2*mon_x[mi], o.y+2*mon_y[mi]),
				(o.x+VIEWW*CELL-2*MW+2*mon_x[mi]+1, o.y+2*mon_y[mi]+1)), red, nil, Point(0, 0));
	img.draw(Rect((o.x+VIEWW*CELL-2*MW+2*int man_x, o.y+2*int man_y),
		(o.x+VIEWW*CELL-2*MW+2*int man_x+1, o.y+2*int man_y+1)), cyan, nil, Point(0, 0));

	if(font != nil){
		elapsed := real(sys->millisec() - t0) / 1000.0;
		if(tf)
			elapsed = real(tf - t0) / 1000.0;
		msg := sys->sprint("Enemy:%d Time:%3.2fs Best:%3.2fs", monsters_left, elapsed, best_score);
		img.text(Point(o.x+4, o.y+VIEWH*CELL+4), green, Point(0, 0), font, msg);
		if(tf && blink_on)
			img.text(Point(o.x+VIEWW*CELL/2-56, o.y+VIEWH*CELL/2), red, Point(0, 0), font, "Game Completed");
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
