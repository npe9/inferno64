implement Tictactoe;

# TempleOS Demo/Games/TicTacToe.HC — Wmclient+Draw

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Tictactoe: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
ink: array of ref Image;
board: array of int;	# 0 empty, 1 X, 2 O
player := 1;
gameover := 0;
bx := array[] of {150, 250, 350, 150, 250, 350, 150, 250, 350};
by := array[] of {150, 150, 150, 250, 250, 250, 350, 350, 350};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS TicTacToe", Wmclient->Appl);
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
	board = array[9] of { * => 0 };
	win.reshape(Rect((0, 0), (500, 500)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw(-1, -1);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw(-1, -1);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img == nil)
			continue;
		x := p.xy.x - img.r.min.x;
		y := p.xy.y - img.r.min.y;
		redraw(x, y);
		if((p.buttons & 1) && !gameover)
			click(x, y);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			exit;
		'\n' or 'r' or 'R' =>
			for(j := 0; j < 9; j++)
				board[j] = 0;
			player = 1;
			gameover = 0;
			redraw(-1, -1);
		}
	}
}

click(x, y: int)
{
	if(x < 100 || x >= 400 || y < 100 || y >= 400)
		return;
	i := (x - 100) / 100 + ((y - 100) / 100) * 3;
	if(i < 0 || i >= 9 || board[i] != 0)
		return;
	board[i] = player;
	if(winner(player)){
		gameover = 1;
		return;
	}
	n := 0;
	for(j := 0; j < 9; j++)
		if(board[j])
			n++;
	if(n == 9){
		gameover = 1;
		return;
	}
	player = 3 - player;
}

winner(p: int): int
{
	w := array[] of {
		(0,1,2),(3,4,5),(6,7,8),
		(0,3,6),(1,4,7),(2,5,8),
		(0,4,8),(2,4,6)
	};
	for(i := 0; i < len w; i++){
		(a,b,c) := w[i];
		if(board[a] == p && board[b] == p && board[c] == p)
			return 1;
	}
	return 0;
}

redraw(mx, my: int)
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, ink[15], nil, Point(0, 0));
	o := img.r.min;
	img.line(Point(200,100).add(o), Point(200,400).add(o), 0, 0, 2, ink[0], Point(0,0));
	img.line(Point(300,100).add(o), Point(300,400).add(o), 0, 0, 2, ink[0], Point(0,0));
	img.line(Point(100,200).add(o), Point(400,200).add(o), 0, 0, 2, ink[0], Point(0,0));
	img.line(Point(100,300).add(o), Point(400,300).add(o), 0, 0, 2, ink[0], Point(0,0));
	for(i := 0; i < 9; i++)
		case board[i] {
		1 =>
			drawx(bx[i], by[i]);
		2 =>
			drawo(bx[i], by[i]);
		}
	if(!gameover && mx >= 0){
		if(player == 1)
			drawx(mx, my);
		else
			drawo(mx, my);
	}
	img.flush(Draw->Flushnow);
}

drawx(x, y: int)
{
	img := win.image;
	o := img.r.min;
	img.line(Point(x-20,y-20).add(o), Point(x+20,y+20).add(o), 0, 0, 2, ink[4], Point(0,0));
	img.line(Point(x+20,y-20).add(o), Point(x-20,y+20).add(o), 0, 0, 2, ink[4], Point(0,0));
}

drawo(x, y: int)
{
	img := win.image;
	o := img.r.min;
	img.ellipse(Point(x,y).add(o), 25, 25, 2, ink[1], Point(0,0));
}
