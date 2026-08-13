implement Tothefront;

# TempleOS Apps/ToTheFront — simplified turn-based grid wargame
# GAP: no hex terrain/roads/rivers, sprite units, fog, indirect fire, save games

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

Tothefront: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MAPW: con 12;
MAPH: con 10;
UNITS_PER: con 10;
MAXU: con UNITS_PER * 2;

UK_INF, UK_ARM: con iota;
PH_MOVE, PH_FIRE: con iota;

Unit: adt {
	col, row: int;
	player: int;
	kind: int;
	hp, maxhp: int;
	moved, fired: int;
};

win: ref Window;
ink: array of ref Image;
units: array of Unit;
occ: array of array of int;
cur_player, phase, sel, gameover, winner: int;
grid_x0, grid_y0, cell_w, cell_h: int;
lastl := 0;
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

	win = wmclient->window(ctxt, "TempleOS ToTheFront", Wmclient->Appl);
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

	units = array[MAXU] of Unit;
	occ = array[MAPW] of { * => array[MAPH] of { * => -1 } };

	win.reshape(Rect((0, 0), (720, 560)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	game_init();

	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p);
	k := <-win.ctxt.kbd =>
		case k {
		Keyboard->Esc or 'q' or 'Q' =>
			if(have_tone)
				tone->stop();
			exit;
		'\n' or 'r' or 'R' =>
			game_init();
		' ' or 'n' or 'N' =>
			if(!gameover && cur_player == 0)
				end_phase();
		}
	}
}

game_init()
{
	img := win.image;
	w := 720; h := 560;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	margin := 36;
	grid_x0 = margin;
	grid_y0 = margin;
	cell_w = (w - 2*margin) / MAPW;
	cell_h = (h - 2*margin - 24) / MAPH;
	if(cell_w > cell_h)
		cell_w = cell_h;
	if(cell_h > cell_w)
		cell_h = cell_w;

	for(c := 0; c < MAPW; c++)
		for(r := 0; r < MAPH; r++)
			occ[c][r] = -1;

	cur_player = 0;
	phase = PH_MOVE;
	sel = -1;
	gameover = 0;
	winner = -1;

	for(i := 0; i < MAXU; i++){
		u := Unit(0, 0, 0, 0, 0, 0, 0, 0);
		if(i < UNITS_PER){
			u.player = 0;
			if(i < 5)
				u.kind = UK_INF;
			else
				u.kind = UK_ARM;
			u.col = i % MAPW;
			u.row = MAPH - 1 - (i / MAPW);
		}else{
			u.player = 1;
			if((i - UNITS_PER) < 5)
				u.kind = UK_INF;
			else
				u.kind = UK_ARM;
			u.col = (i - UNITS_PER) % MAPW;
			u.row = (i - UNITS_PER) / MAPW;
		}
		if(u.kind == UK_INF){
			u.maxhp = 4; u.hp = 4;
		}else{
			u.maxhp = 6; u.hp = 6;
		}
		units[i] = u;
		occ[u.col][u.row] = i;
	}
	redraw();
}

unit_move(u: int): int
{
	if(units[u].kind == UK_INF)
		return 3;
	return 2;
}

unit_range(u: int): int
{
	if(units[u].kind == UK_INF)
		return 2;
	return 4;
}

unit_atk(u: int): int
{
	if(units[u].kind == UK_INF)
		return 2;
	return 4;
}

cell_px(c, r: int): Point
{
	return Point(grid_x0 + c*cell_w + cell_w/2,
		grid_y0 + r*cell_h + cell_h/2);
}

ptr_to_cell(x, y: int): (int, int)
{
	c := (x - grid_x0) / cell_w;
	r := (y - grid_y0) / cell_h;
	if(c < 0 || c >= MAPW || r < 0 || r >= MAPH)
		return (-1, -1);
	return (c, r);
}

dist(c1, r1, c2, r2: int): int
{
	dx := c1 - c2;
	if(dx < 0)
		dx = -dx;
	dy := r1 - r2;
	if(dy < 0)
		dy = -dy;
	if(dx > dy)
		return dx;
	return dy;
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	lb := (p.buttons & 1) != 0;
	if(lb && !lastl && !gameover && cur_player == 0)
		click(x, y);
	lastl = lb;
	redraw();
}

click(x, y: int)
{
	(c, r) := ptr_to_cell(x, y);
	if(c < 0)
		return;
	idx := occ[c][r];

	if(phase == PH_MOVE){
		if(idx >= 0 && units[idx].player == 0 && units[idx].hp > 0){
			sel = idx;
			return;
		}
		if(sel >= 0 && idx < 0){
			u := units[sel];
			if(u.moved || u.hp <= 0)
				return;
			if(dist(u.col, u.row, c, r) <= unit_move(sel)){
				occ[u.col][u.row] = -1;
				u.col = c;
				u.row = r;
				u.moved = 1;
				units[sel] = u;
				occ[c][r] = sel;
				sel = -1;
				check_victory();
			}
		}
	}else{
		if(idx >= 0 && units[idx].player == 0 && units[idx].hp > 0){
			sel = idx;
			return;
		}
		if(sel >= 0 && idx >= 0 && units[idx].player == 1){
			u := units[sel];
			t := units[idx];
			if(u.fired || u.hp <= 0 || t.hp <= 0)
				return;
			if(dist(u.col, u.row, c, r) <= unit_range(sel)){
				t.hp -= unit_atk(sel);
				if(t.hp < 0)
					t.hp = 0;
				units[idx] = t;
				u.fired = 1;
				units[sel] = u;
				if(have_tone)
					tone->beep(120, 60);
				sel = -1;
				check_victory();
			}
		}
	}
}

end_phase()
{
	if(phase == PH_MOVE){
		phase = PH_FIRE;
		sel = -1;
	}else{
		phase = PH_MOVE;
		sel = -1;
		for(i := 0; i < MAXU; i++){
			u := units[i];
			u.moved = 0;
			u.fired = 0;
			units[i] = u;
		}
		cur_player = 1;
		ai_turn();
		cur_player = 0;
	}
	redraw();
}

ai_turn()
{
	i, j, best, d, bc, br: int;
	u, t: Unit;

	# move phase
	for(i = 0; i < MAXU; i++){
		u = units[i];
		if(u.player != 1 || u.hp <= 0 || u.moved)
			continue;
		best = -1;
		d = 9999;
		for(j = 0; j < MAXU; j++){
			t = units[j];
			if(t.player != 0 || t.hp <= 0)
				continue;
			dd := dist(u.col, u.row, t.col, t.row);
			if(dd < d){
				d = dd;
				best = j;
			}
		}
		if(best < 0)
			continue;
		t = units[best];
		bc = u.col; br = u.row;
		if(t.col > u.col && occ[u.col+1][u.row] < 0)
			bc = u.col + 1;
		else if(t.col < u.col && occ[u.col-1][u.row] < 0)
			bc = u.col - 1;
		else if(t.row > u.row && occ[u.col][u.row+1] < 0)
			br = u.row + 1;
		else if(t.row < u.row && occ[u.col][u.row-1] < 0)
			br = u.row - 1;
		if((bc != u.col || br != u.row) &&
		   dist(u.col, u.row, bc, br) <= unit_move(i)){
			occ[u.col][u.row] = -1;
			u.col = bc;
			u.row = br;
			u.moved = 1;
			units[i] = u;
			occ[bc][br] = i;
		}
	}

	# fire phase
	for(i = 0; i < MAXU; i++){
		u = units[i];
		if(u.player != 1 || u.hp <= 0 || u.fired)
			continue;
		best = -1;
		d = 9999;
		for(j = 0; j < MAXU; j++){
			t = units[j];
			if(t.player != 0 || t.hp <= 0)
				continue;
			dd := dist(u.col, u.row, t.col, t.row);
			if(dd <= unit_range(i) && dd < d){
				d = dd;
				best = j;
			}
		}
		if(best >= 0){
			t = units[best];
			t.hp -= unit_atk(i);
			if(t.hp < 0)
				t.hp = 0;
			units[best] = t;
			u.fired = 1;
			units[i] = u;
			if(have_tone)
				tone->beep(90, 40);
		}
	}
	check_victory();
}

check_victory()
{
	alive0 := 0;
	alive1 := 0;
	for(i := 0; i < MAXU; i++){
		if(units[i].hp <= 0)
			continue;
		if(units[i].player == 0)
			alive0++;
		else
			alive1++;
	}
	if(alive0 == 0 || alive1 == 0){
		gameover = 1;
		if(alive0 > 0)
			winner = 0;
		else if(alive1 > 0)
			winner = 1;
		else
			winner = -1;
	}
}

draw_triangle(img: ref Image, o: Point, c: Point, rad: int, col: ref Image)
{
	p0 := Point(c.x+o.x, c.y+o.y-rad);
	p1 := Point(c.x+o.x-rad, c.y+o.y+rad*2/3);
	p2 := Point(c.x+o.x+rad, c.y+o.y+rad*2/3);
	img.line(p0, p1, Draw->Enddisc, Draw->Enddisc, 0, col, Point(0, 0));
	img.line(p1, p2, Draw->Enddisc, Draw->Enddisc, 0, col, Point(0, 0));
	img.line(p2, p0, Draw->Enddisc, Draw->Enddisc, 0, col, Point(0, 0));
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	w := img.r.dx();
	h := img.r.dy();
	o := img.r.min;
	img.draw(img.r, ink[15], nil, Point(0, 0));

	for(c := 0; c < MAPW; c++){
		for(r := 0; r < MAPH; r++){
			x0 := o.x + grid_x0 + c*cell_w;
			y0 := o.y + grid_y0 + r*cell_h;
			bg := ink[7];
			if((c+r) & 1)
				bg = ink[8];
			img.draw(Rect((x0, y0), (x0+cell_w, y0+cell_h)), bg, nil, Point(0, 0));
			img.line(Point(x0, y0), Point(x0+cell_w, y0),
				0, 0, 1, ink[0], Point(0, 0));
			img.line(Point(x0, y0), Point(x0, y0+cell_h),
				0, 0, 1, ink[0], Point(0, 0));
		}
	}

	rad := cell_w / 4;
	if(rad > cell_h/4)
		rad = cell_h / 4;
	if(rad < 4)
		rad = 4;

	for(i := 0; i < MAXU; i++){
		u := units[i];
		if(u.hp <= 0)
			continue;
		pt := cell_px(u.col, u.row).add(o);
		body := ink[11];
		edge := ink[1];
		if(u.player == 1){
			body = ink[13];
			edge = ink[4];
		}
		if(i == sel)
			img.ellipse(pt, rad+3, rad+3, 1, ink[14], Point(0, 0));
		if(u.kind == UK_INF)
			img.ellipse(pt, rad, rad, 0, body, Point(0, 0));
		else
			draw_triangle(img, Point(0, 0), Point(pt.x-o.x, pt.y-o.y), rad, body);
		img.ellipse(pt, rad, rad, 1, edge, Point(0, 0));

		bw := cell_w * 3 / 5;
		bh := 4;
		bx := pt.x - bw/2;
		by := pt.y - rad - 8;
		filled := bw * u.hp / u.maxhp;
		if(filled < 0)
			filled = 0;
		img.draw(Rect((bx, by), (bx+bw, by+bh)), ink[0], nil, Point(0, 0));
		if(filled > 0)
			img.draw(Rect((bx, by), (bx+filled, by+bh)), edge, nil, Point(0, 0));
	}

	# phase / player banner
	bar_col := ink[11];
	if(cur_player == 1)
		bar_col = ink[13];
	if(gameover){
		if(winner == 0)
			bar_col = ink[10];
		else if(winner == 1)
			bar_col = ink[12];
		else
			bar_col = ink[14];
	}
	img.draw(Rect((o.x+8, o.y+h-18), (o.x+w-8, o.y+h-6)), bar_col, nil, Point(0, 0));

	if(phase == PH_MOVE)
		img.draw(Rect((o.x+8, o.y+4), (o.x+80, o.y+16)), ink[10], nil, Point(0, 0));
	else
		img.draw(Rect((o.x+8, o.y+4), (o.x+80, o.y+16)), ink[12], nil, Point(0, 0));

	img.flush(Draw->Flushnow);
}
