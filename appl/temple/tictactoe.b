implement Tictactoe;

# TempleOS Demo/Games/TicTacToe.HC — noughts and crosses, two players at
# one mouse.
#
# The sound carries the whole interface.  TakeTurn beeps at the top of
# its loop and then waits for a click, so a turn opens with a beep and an
# illegal click beeps again — and the two players have different pitches:
#
#	if (player==1) Beep; else Beep(74);
#
# Beep's default ona is 62 and 74 is the octave above it, so you can hear
# whose turn it is and whether the click took.  A win is three of that
# player's beep.  There is no computer opponent and no draw message; the
# game just stops after nine moves.
#
# GAP: the original says "$GREEN$CTRL-ALT-c$FG$ to exit."; under wm(1)
#      that key belongs to the window manager, so this says q.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tone.m";
	tone: Tone;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Tictactoe: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

A4ONA: con 60;			# Ona2Freq: ona 60 is 440Hz

win: ref Window;
font: ref Font;
ink: array of ref Image;
have_tone := 0;
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
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	math = load Math Math->PATH;
	tone = load Tone Tone->PATH;
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	# the exact TempleOS 16-colour palette, index = TempleOS colour
	ink = array[16] of ref Image;
	cols := array[] of {
		int 16r000000FF, int 16r0000AAFF, int 16r00AA00FF, int 16r00AAAAFF,
		int 16rAA0000FF, int 16rAA00AAFF, int 16rAA5500FF, int 16rAAAAAAFF,
		int 16r555555FF, int 16r5555FFFF, int 16r55FF55FF, int 16r55FFFFFF,
		int 16rFF5555FF, int 16rFF55FFFF, int 16rFFFF55FF, int 16rFFFFFFFF
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
	# TakeTurn's loop beeps and asks again until the click is inside the
	# board and on an empty square
	if(x < 100 || x >= 400 || y < 100 || y >= 400){
		spawn beeps(player, 1);
		return;
	}
	i := (x - 100) / 100 + ((y - 100) / 100) * 3;
	if(i < 0 || i >= 9 || board[i] != 0){
		spawn beeps(player, 1);
		return;
	}
	board[i] = player;
	if(winner(player)){
		gameover = 1;
		spawn beeps(player, 3);	# three of the winner's own beep
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
	if(font != nil){
		w := font.width("q");
		img.text(o, ink[2], Point(0, 0), font, "q");
		img.text(Point(o.x+w, o.y), ink[0], Point(0, 0), font,
			" to exit.");
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

# Beep for player 1 and Beep(74) for player 2: Snd(ona) for 500ms, then
# silence for 200ms, n times.  Spawned, so three of them do not freeze
# the window the way the original's do.
beeps(p, n: int)
{
	if(!have_tone)
		return;
	ona := 62;
	if(p == 2)
		ona = 74;
	for(i := 0; i < n; i++){
		tone->beep(onafreq(ona), 500);
		sys->sleep(700);
	}
}

onafreq(ona: int): int
{
	if(math == nil)
		return 494;
	f := int (440.0 * math->pow(2.0, real (ona - A4ONA) / 12.0) + 0.5);
	if(f < 1)
		f = 1;
	return f;
}
