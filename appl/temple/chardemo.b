implement CharDemo;

# TempleOS Demo/Games/CharDemo.HC — character-map scroll demo
# arrows scroll; Enter restart; q quit
# GAP: no text.font/TextChar — 8×8 pixel cells; box-drawing border as rects;
#      animated water uses simplified bit patterns not TempleOS font RAM

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "rand.m";
	rand: Rand;

CharDemo: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

CELL: con 8;
VCOLS: con 80;
VROWS: con 60;
MAPW: con VCOLS * 2;
MAPH: con VROWS * 2;

CH_WATER: con 0;
CH_LAND: con 1;
CH_TREE: con 2;
CH_BORDER: con 3;

win: ref Window;
map: array of array of int;
scrx, scry: int;
scroll_dx, scroll_dy, scroll_left: int;
wave: int;
blue, ltblue, yellow, green, red, black, white: ref Image;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS CharDemo", Wmclient->Appl);
	d := win.display;
	blue = d.color(Draw->Blue);
	ltblue = d.color(Draw->Paleblue);
	yellow = d.color(Draw->Yellow);
	green = d.color(Draw->Green);
	red = d.color(Draw->Red);
	black = d.color(Draw->Black);
	white = d.color(Draw->White);
	map = array[MAPH] of { * => array[MAPW] of { * => CH_WATER } };
	genmap();
	win.reshape(Rect((0, 0), (VCOLS * CELL, VROWS * CELL)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 16);
	wave_ticks := chan of int;
	spawn timer(wave_ticks, 200);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			exit;
		'\n' =>
			genmap();
		Keyboard->Left =>
			startscroll(-1, 0);
		Keyboard->Right =>
			startscroll(1, 0);
		Keyboard->Up =>
			startscroll(0, -1);
		Keyboard->Down =>
			startscroll(0, 1);
		}
	<-ticks =>
		if(scroll_left > 0){
			scrx = clamp(scrx + scroll_dx, 0, (MAPW - VCOLS) * CELL);
			scry = clamp(scry + scroll_dy, 0, (MAPH - VROWS) * CELL);
			scroll_left--;
			redraw();
		}
	<-wave_ticks =>
		wave = (wave + 1) & 3;
		redraw();
	}
}

genmap()
{
	scrx = ((MAPW - VCOLS) >> 1) * CELL;
	scry = ((MAPH - VROWS) >> 1) * CELL;
	scroll_left = 0;
	for(my := 0; my < MAPH; my++)
		for(mx := 0; mx < MAPW; mx++)
			map[my][mx] = CH_WATER;
	for(bx := 0; bx < MAPW; bx++){
		map[0][bx] = CH_BORDER;
		map[MAPH - 1][bx] = CH_BORDER;
	}
	for(by := 0; by < MAPH; by++){
		map[by][0] = CH_BORDER;
		map[by][MAPW - 1] = CH_BORDER;
	}
	for(i := 0; i < 20; i++){
		lx := rn(MAPW);
		ly := rn(MAPH);
		for(j := 0; j < 1000; j++){
			map[ly][lx] = CH_LAND;
			lx = clamp(lx + rn(3) - 1, 0, MAPW - 1);
			ly = clamp(ly + rn(3) - 1, 0, MAPH - 1);
		}
	}
	tx := 0;
	ty := 0;
	for(ti := 0; ti < 100; ti++){
		for(;;){
			tx = rn(MAPW);
			ty = rn(MAPH);
			if(map[ty][tx] == CH_LAND)
				break;
		}
		for(j := 0; j < 100; j++){
			map[ty][tx] = CH_TREE;
			tx = clamp(tx + rn(3) - 1, 0, MAPW - 1);
			ty = clamp(ty + rn(3) - 1, 0, MAPH - 1);
		}
	}
	redraw();
}

startscroll(sdx, sdy: int)
{
	if(scroll_left > 0)
		return;
	scroll_dx = sdx;
	scroll_dy = sdy;
	scroll_left = 32;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, blue, nil, Point(0, 0));
	o := img.r.min;
	col0 := scrx / CELL;
	row0 := scry / CELL;
	panx := scrx & 7;
	pany := scry & 7;
	for(vy := 0; vy <= VROWS; vy++){
		my := row0 + vy;
		if(my < 0 || my >= MAPH)
			continue;
		for(vx := 0; vx <= VCOLS; vx++){
			mx := col0 + vx;
			if(mx < 0 || mx >= MAPW)
				continue;
			px := o.x + vx * CELL - panx;
			py := o.y + vy * CELL - pany;
			drawcell(img, px, py, map[my][mx]);
		}
	}
	img.flush(Draw->Flushnow);
}

drawcell(img: ref Image, px, py, kind: int)
{
	r := Rect((px, py), (px + CELL, py + CELL));
	case kind {
	CH_BORDER =>
		img.draw(r, red, nil, Point(0, 0));
		img.draw(Rect((px + 1, py + 1), (px + CELL - 1, py + CELL - 1)), blue, nil, Point(0, 0));
	CH_LAND =>
		img.draw(r, yellow, nil, Point(0, 0));
	CH_TREE =>
		img.draw(r, yellow, nil, Point(0, 0));
		img.draw(Rect((px + 2, py + 1), (px + CELL - 2, py + CELL - 3)), green, nil, Point(0, 0));
		img.draw(Rect((px + 3, py + CELL - 3), (px + CELL - 3, py + CELL - 1)), black, nil, Point(0, 0));
	CH_WATER or * =>
		wpat(img, px, py, wave);
	}
}

wpat(img: ref Image, px, py, frame: int)
{
	pats: array of int;
	pats = array[] of {
		16r0011AA44, 16r00225588, 16r0044AA11, 16r00885522,
	};
	pat := pats[frame & 3];
	for(row := 0; row < 8; row++){
		b := (pat >> (row * 8)) & 16rFF;
		for(col := 0; col < 8; col++){
			if(b & (1 << col)){
				img.draw(Rect((px + col, py + row), (px + col + 1, py + row + 1)),
					ltblue, nil, Point(0, 0));
			}else
				img.draw(Rect((px + col, py + row), (px + col + 1, py + row + 1)),
					blue, nil, Point(0, 0));
		}
	}
}

clamp(v, lo, hi: int): int
{
	if(v < lo) return lo;
	if(v > hi) return hi;
	return v;
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
