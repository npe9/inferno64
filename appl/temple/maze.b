implement Maze;

# TempleOS Demo/Games/Maze.HC — Draw grid stand-in for text_base layer
# LMB draw walls; RMB solve from cell; c clear; q quit
# GAP: TempleOS text_base ATTR chars → pixel cells

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Maze: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

COLS: con 40;
ROWS: con 24;
CELL: con 16;

win: ref Window;
ink: array of ref Image;
cell: array of array of int;	# 0 empty, 1 wall, 2 path
solving := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Maze", Wmclient->Appl);
	d := win.display;
	ink = array[16] of {
		d.color(Draw->Black),
		d.color(Draw->White),
		d.color(Draw->Red),
		d.color(Draw->Green),
		d.color(Draw->Grey),
		* => d.color(Draw->Blue)
	};
	cell = array[ROWS] of { * => array[COLS] of { * => 0 } };
	win.reshape(Rect((0, 0), (COLS*CELL, ROWS*CELL+20)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();

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
		16r1b or 'q' or 'Q' =>
			exit;
		'c' or 'C' =>
			for(y := 0; y < ROWS; y++)
				for(x := 0; x < COLS; x++)
					cell[y][x] = 0;
			redraw();
		}
	}
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil || solving)
		return;
	x := (p.xy.x - img.r.min.x) / CELL;
	y := (p.xy.y - img.r.min.y) / CELL;
	if(x < 0 || x >= COLS || y < 0 || y >= ROWS)
		return;
	if(p.buttons & 1){
		cell[y][x] = 1;
		redraw();
	}
	if(p.buttons & 2){
		# clear old path
		for(yy := 0; yy < ROWS; yy++)
			for(xx := 0; xx < COLS; xx++)
				if(cell[yy][xx] == 2)
					cell[yy][xx] = 0;
		spawn solve(x, y);
	}
}

solve(sx, sy: int)
{
	solving = 1;
	# DFS with stack
	STK: con 2048;
	xs := array[STK] of int;
	ys := array[STK] of int;
	dirs := array[STK] of int;
	dx := array[] of {0, 1, 0, -1};
	dy := array[] of {1, 0, -1, 0};
	sp := 0;
	x := sx;
	y := sy;
	dir := 0;
	xs[sp] = x; ys[sp] = y; dirs[sp] = dir; sp++;
	for(;;){
		if(x < 0 || x >= COLS || y < 0 || y >= ROWS){
			solving = 0;
			redraw();
			return;
		}
		if(cell[y][x] == 0)
			cell[y][x] = 2;
		redraw();
		sys->sleep(30);
		nx := x + dx[dir];
		ny := y + dy[dir];
		blocked := nx < 0 || nx >= COLS || ny < 0 || ny >= ROWS || cell[ny][nx] == 1 || cell[ny][nx] == 2;
		if(blocked){
			dir++;
			if(dir == 4){
				sp--;
				if(sp < 0){
					solving = 0;
					redraw();
					return;
				}
				x = xs[sp];
				y = ys[sp];
				dir = dirs[sp];
			}
		}else{
			dir = 0;
			if(sp >= STK){
				solving = 0;
				return;
			}
			xs[sp] = x; ys[sp] = y; dirs[sp] = dir; sp++;
			x = nx; y = ny;
		}
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, ink[0], nil, Point(0, 0));
	o := img.r.min;
	for(y := 0; y < ROWS; y++)
		for(x := 0; x < COLS; x++){
			c := cell[y][x];
			if(c == 0)
				continue;
			col := ink[1];
			if(c == 2)
				col = ink[2];
			img.draw(Rect((o.x+x*CELL, o.y+y*CELL), (o.x+x*CELL+CELL-1, o.y+y*CELL+CELL-1)),
				col, nil, Point(0, 0));
		}
	img.flush(Draw->Flushnow);
}
