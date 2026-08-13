implement Dungen;

# TempleOS Demo/Games/DunGen.HC — dungeon crawl; kill all monsters
# space then arrow attacks; arrows move; Enter restart; q quit
# GAP: sprite map + 3D view → procedural top-down; tile sprites → colors

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

Dungen: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MW: con 48;
MH: con 36;
CELL: con 14;
VIEWW: con 24;
VIEWH: con 24;
MONS: con 10;

T_EMPTY: con 0;
T_FLOOR: con 1;
T_WALL: con 2;

win: ref Window;
font: ref Font;
black, floorc, wallc, playerc, monsc, fog, red, green: ref Image;
have_tone := 0;
blink_on := 0;

map: array of array of int;
visible: array of array of int;
man_x, man_y, man_dx, man_dy: int;
attack_hold := 0;
attack_t0 := 0;
mon_x, mon_y, mon_dx, mon_dy, mon_dead: array of int;
monsters_left := 0;
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

	win = wmclient->window(ctxt, "TempleOS DunGen", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	black = d.color(Draw->Black);
	floorc = d.color(int 16r555555FF);
	wallc = d.color(int 16r886644FF);
	playerc = d.color(Draw->Cyan);
	monsc = d.color(Draw->Red);
	fog = d.color(int 16r111111FF);
	red = d.color(Draw->Red);
	green = d.color(Draw->Green);
	best_score = 9999.0;
	if(scorestore != nil)
		best_score = scorestore->loadreal("dungen", best_score);
	game_init();
	win.reshape(Rect((0, 0), (VIEWW*CELL, VIEWH*CELL+20)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 16);
	mtick := chan of int;
	spawn mon_timer(mtick, 1000);
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
			attack_hold = 1;
		Keyboard->Right =>
			dir_key(1, 0);
		Keyboard->Left =>
			dir_key(-1, 0);
		Keyboard->Up =>
			dir_key(0, -1);
		Keyboard->Down =>
			dir_key(0, 1);
		'a' or 'A' =>
			dir_key(-1, 0);
		'd' or 'D' =>
			dir_key(1, 0);
		'w' or 'W' =>
			dir_key(0, -1);
		's' or 'S' =>
			dir_key(0, 1);
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
	map = array[MH] of { * => array[MW] of { * => T_WALL } };
	visible = array[MH] of { * => array[MW] of { * => 0 } };
	gen_dungeon();
	(man_x, man_y) = find_floor();
	man_dx = 0;
	man_dy = 1;
	scrn_x = man_x - VIEWW/2;
	scrn_y = man_y - VIEWH/2;
	clamp_view();
	mon_x = array[MONS] of int;
	mon_y = array[MONS] of int;
	mon_dx = array[MONS] of int;
	mon_dy = array[MONS] of int;
	mon_dead = array[MONS] of int;
	for(i := 0; i < MONS; i++){
		mon_dead[i] = 0;
		mon_dx[i] = 0;
		mon_dy[i] = 0;
		(x, y) := rand_floor();
		mon_x[i] = x;
		mon_y[i] = y;
	}
	monsters_left = MONS;
	tf = 0;
	t0 = sys->millisec();
	attack_hold = 0;
	attack_t0 = 0;
}

scrn_x, scrn_y: int;

gen_dungeon()
{
	for(my := 1; my < MH-1; my++)
		for(mx := 1; mx < MW-1; mx++)
			map[my][mx] = T_WALL;
	rooms := 10;
	for(r := 0; r < rooms; r++){
		rw := 4 + rn(8);
		rh := 4 + rn(6);
		rx := 1 + rn(MW - rw - 2);
		ry := 1 + rn(MH - rh - 2);
		for(cy := ry; cy < ry+rh; cy++)
			for(cx := rx; cx < rx+rw; cx++)
				map[cy][cx] = T_FLOOR;
	}
	# connect rooms with horizontal/vertical tunnels
	for(c := 0; c < rooms-1; c++){
		(x1, y1) := find_floor();
		(x2, y2) := find_floor();
		for(tx := min(x1,x2); tx <= max(x1,x2); tx++)
			map[y1][tx] = T_FLOOR;
		for(ty := min(y1,y2); ty <= max(y1,y2); ty++)
			map[ty][x2] = T_FLOOR;
	}
}

find_floor(): (int, int)
{
	for(t := 0; t < 1000; t++){
		x := 1 + rn(MW-2);
		y := 1 + rn(MH-2);
		if(map[y][x] == T_FLOOR)
			return (x, y);
	}
	return (MW/2, MH/2);
}

rand_floor(): (int, int)
{
	for(t := 0; t < 1000; t++){
		(x, y) := find_floor();
		if(x == man_x && y == man_y)
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

dir_key(dx, dy: int)
{
	if(attack_hold){
		man_dx = dx;
		man_dy = dy;
		do_attack();
		attack_hold = 0;
	}else
		try_move(dx, dy);
}

try_move(dx, dy: int)
{
	nx := man_x + dx;
	ny := man_y + dy;
	if(nx < 0 || nx >= MW || ny < 0 || ny >= MH)
		return;
	if(map[ny][nx] != T_FLOOR)
		return;
	man_x = nx;
	man_y = ny;
	man_dx = dx;
	man_dy = dy;
	if(man_x - scrn_x > VIEWW/2 - 3){
		scrn_x += VIEWW/2;
		clamp_view();
	}
	if(man_x - scrn_x < -VIEWW/2 + 3){
		scrn_x -= VIEWW/2;
		clamp_view();
	}
	if(man_y - scrn_y > VIEWH/2 - 3){
		scrn_y += VIEWH/2;
		clamp_view();
	}
	if(man_y - scrn_y < -VIEWH/2 + 3){
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

do_attack()
{
	attack_t0 = sys->millisec();
	if(have_tone)
		tone->beep(53, 100);
	ax := man_x + man_dx;
	ay := man_y + man_dy;
	for(i := 0; i < MONS; i++){
		if(mon_dead[i])
			continue;
		if(mon_x[i] == ax && mon_y[i] == ay){
			mon_dead[i] = 1;
			monsters_left--;
			if(!monsters_left){
				tf = sys->millisec();
				elapsed := real(tf - t0) / 1000.0;
				if(elapsed < best_score){
					best_score = elapsed;
					if(scorestore != nil)
						scorestore->savereal("dungen", best_score);
				}
			}
		}
	}
}

move_monsters()
{
	for(i := 0; i < MONS; i++){
		if(mon_dead[i])
			continue;
		dx := rn(3) - 1;
		dy := rn(3) - 1;
		nx := mon_x[i] + dx;
		ny := mon_y[i] + dy;
		if(nx < 0 || nx >= MW || ny < 0 || ny >= MH)
			continue;
		if(map[ny][nx] != T_FLOOR)
			continue;
		if(nx == man_x && ny == man_y)
			continue;
		mon_x[i] = nx;
		mon_y[i] = ny;
		mon_dx[i] = dx;
		mon_dy[i] = dy;
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
		if(map[y][x] == T_WALL && !(x == x1 && y == y1))
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
			vis := los(man_x, man_y, mx, my);
			visible[my][mx] = vis;
			if(!vis)
				continue;
			col := floorc;
			if(map[my][mx] == T_WALL)
				col = wallc;
			img.draw(Rect((o.x+x*CELL, o.y+y*CELL), (o.x+x*CELL+CELL-1, o.y+y*CELL+CELL-1)),
				col, nil, Point(0, 0));
		}
	for(i := 0; i < MONS; i++){
		if(mon_dead[i])
			continue;
		mx := mon_x[i];
		my := mon_y[i];
		if(!visible[my][mx] || !los(man_x, man_y, mx, my))
			continue;
		sx := mx - scrn_x + VIEWW/2;
		sy := my - scrn_y + VIEWH/2;
		if(sx < 0 || sx >= VIEWW || sy < 0 || sy >= VIEWH)
			continue;
		img.draw(Rect((o.x+sx*CELL+3, o.y+sy*CELL+3), (o.x+sx*CELL+CELL-4, o.y+sy*CELL+CELL-4)),
			monsc, nil, Point(0, 0));
	}
	psx := man_x - scrn_x + VIEWW/2;
	psy := man_y - scrn_y + VIEWH/2;
	ox := 0;
	oy := 0;
	if(sys->millisec() - attack_t0 < 200){
		ox = man_dx * (200 - (sys->millisec() - attack_t0)) / 40;
		oy = man_dy * (200 - (sys->millisec() - attack_t0)) / 40;
	}
	img.draw(Rect((o.x+(psx+ox)*CELL+2, o.y+(psy+oy)*CELL+2),
		(o.x+(psx+ox)*CELL+CELL-3, o.y+(psy+oy)*CELL+CELL-3)), playerc, nil, Point(0, 0));

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
	if(a > b) return b;
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
