implement Pantext;

# TempleOS Demo/Graphics/PanText.HC — the text layer slides sub-cell.
#
#	for (i=0;i<=7;i++)  { gr.pan_text_x=i;  Sleep(30); }
#	for (;i>=-7;i--)    { gr.pan_text_x=i;  Sleep(30); }
#	for (;i<=0;i++)     { gr.pan_text_x=i;  Sleep(30); }
#	... and the same three sweeps again on gr.pan_text_y.
#
# Six sweeps of thirty milliseconds a step: right to +7, left to -7, back
# to 0, then the same vertically.  The whole program is those two globals.
# TempleOS composites a character layer over the graphics layer on a fixed
# 8x8 grid, and gr.pan_text_x/y shift that layer by up to a whole cell in
# either direction, which is how it scrolls text smoothly over a grid that
# cannot itself move.
#
# GAP: there is no separate character layer here to slide, so the port
#      draws the text at the offset instead.  The motion is the same; the
#      mechanism is not, and in the original everything already on screen
#      moves, not just what this program drew.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

Pantext: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

FW: con 8;
FH: con 8;

win: ref Window;
font: ref Font;
white, black, blue, ltgray: ref Image;
panx, pany: int;
step := 0;

page := array[] of {
	"TempleOS composites a character layer over the graphics",
	"layer on a fixed 8x8 grid.  gr.pan_text_x and",
	"gr.pan_text_y shift that layer by up to one whole cell",
	"in either direction, which is how text scrolls smoothly",
	"over a grid that cannot itself move.",
	"",
	"The grid behind this text does not move.  The text does.",
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS PanText", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(int 16rFFFFFFFF);
	black = d.color(int 16r000000FF);
	blue = d.color(int 16r0000AAFF);
	ltgray = d.color(int 16rAAAAAAFF);

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 30);		# the original's Sleep(30)
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	pointerev := <-win.ctxt.ptr =>
		# The titlebar is drawn by this window and only sees a click
		# if the program hands it one: without this arm the move,
		# resize and menu buttons on the window do nothing at all.
		win.pointer(*pointerev);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	<-ticks =>
		advance();
		redraw();
	}
}

# the six sweeps, in order, then round again
advance()
{
	step = (step + 1) % 88;
	s := step;
	panx = pany = 0;
	if(s < 8)			# 0..7
		panx = s;
	else if(s < 23)			# 7..-7
		panx = 7 - (s - 7);
	else if(s < 31)			# -7..0
		panx = -7 + (s - 22);
	else if(s < 39)
		pany = s - 31;
	else if(s < 54)
		pany = 7 - (s - 38);
	else if(s < 62)
		pany = -7 + (s - 53);
}

redraw()
{
	img := win.image;
	if(img == nil || font == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));
	# the 8x8 cell grid, which does not move
	for(x := 0; x < img.r.dx(); x += FW)
		img.draw(Rect((o.x+x, o.y), (o.x+x+1, o.y+img.r.dy())), ltgray,
			nil, Point(0, 0));
	for(y := 0; y < img.r.dy(); y += FH)
		img.draw(Rect((o.x, o.y+y), (o.x+img.r.dx(), o.y+y+1)), ltgray,
			nil, Point(0, 0));
	yy := o.y + 4*FH + pany;
	for(i := 0; i < len page; i++){
		img.text(Point(o.x + 2*FW + panx, yy), black, Point(0, 0), font, page[i]);
		yy += font.height + 4;
	}
	img.text(Point(o.x, img.r.max.y - font.height), blue, Point(0, 0), font,
		sys->sprint("gr.pan_text_x=%d gr.pan_text_y=%d    any key exits",
			panx, pany));
	img.flush(Draw->Flushnow);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
