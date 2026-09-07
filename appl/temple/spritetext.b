implement Spritetext;

# TempleOS Demo/Graphics/SpriteText.HC — read a sprite as text.
#
#	while (tmpg->type&SPG_TYPE_MASK) {
#	  st=SpriteElem2Summary(tmpg);
#	  "%s\n",st;
#	  tmpg(U8 *)+=SpriteElemSize(tmpg);
#	}
#	"**** ENTIRE SPRITE CODE ****"; Sprite2Code(,$IB,"<1>",BI=1$);
#
# A CSprite is a queue of drawing elements, and this demo walks it twice:
# once printing SpriteElem2Summary for each element, and once handing the
# whole thing to Sprite2Code, which emits the HolyC that would build it.
#
# In this tree a sprite already IS text — the element vocabulary written
# by scripts/tos_extract_sprites.py and edited by temple/spriteedit(1) —
# so the walk reads lib/temple/sprites/spritetext_1.spr.  The summaries
# are this port's rendering of SpriteElem2Summary; the code listing is
# the element list itself, which is the form Sprite2Code would rebuild.

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

Spritetext: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

ELEMS: con "/lib/temple/sprites/spritetext_1.spr";

win: ref Window;
font: ref Font;
white, black, purple: ref Image;
lines: list of (int, string);		# (colour index, text)
top := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS SpriteText", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(int 16rFFFFFFFF);
	black = d.color(int 16r000000FF);
	purple = d.color(int 16rAA00AAFF);

	build();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	pointerev := <-win.ctxt.ptr =>
		# The titlebar is drawn by this window and only sees a click
		# if the program hands it one: without this arm the move,
		# resize and menu buttons on the window do nothing at all.
		win.pointer(*pointerev);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			continue;
		case k {
		Keyboard->Down =>	top++;
		Keyboard->Up =>		if(top > 0) top--;
		* =>			exit;
		}
		redraw();
	}
}

build()
{
	elems := readelems();
	l: list of (int, string);
	l = (1, "**** LINE SUMMARIES ****") :: l;
	for(e := elems; e != nil; e = tl e)
		l = (0, summary(hd e)) :: l;
	l = (0, "") :: l;
	l = (1, "**** ENTIRE SPRITE CODE ****") :: l;
	for(e = elems; e != nil; e = tl e)
		l = (0, hd e) :: l;
	lines = rev(l);
}

readelems(): list of string
{
	fd := sys->open(ELEMS, Sys->OREAD);
	if(fd == nil)
		return ("cannot open " + ELEMS) :: nil;
	buf := array[65536] of byte;
	n := 0;
	for(;;){
		r := sys->read(fd, buf[n:], len buf - n);
		if(r <= 0)
			break;
		n += r;
		if(n == len buf)
			break;
	}
	(nil, ls) := sys->tokenize(string buf[0:n], "\n");
	out: list of string;
	for(; ls != nil; ls = tl ls)
		if(hd ls != "")
			out = hd ls :: out;
	return revs(out);
}

# SpriteElem2Summary: the element kind and its salient numbers
summary(e: string): string
{
	(n, t) := sys->tokenize(e, " \t");
	if(n == 0)
		return "";
	kind := hd t;
	t = tl t;
	case kind {
	"color" =>	return "Color " + arg(t, 0);
	"dither" =>	return "Dither Color " + arg(t, 0) + "," + arg(t, 1);
	"thick" =>	return "Thick " + arg(t, 0);
	"planarsym" =>	return "Planar Symmetry " + join(t);
	"pt" =>		return "Point (" + arg(t,0) + "," + arg(t,1) + ")";
	"line" =>	return "Line (" + arg(t,0) + "," + arg(t,1) + ")-(" +
				arg(t,2) + "," + arg(t,3) + ")";
	"arrow" =>	return "Arrow (" + arg(t,0) + "," + arg(t,1) + ")-(" +
				arg(t,2) + "," + arg(t,3) + ")";
	"rect" =>	return "Rect (" + arg(t,0) + "," + arg(t,1) + ")-(" +
				arg(t,2) + "," + arg(t,3) + ")";
	"circle" =>	return "Circle (" + arg(t,0) + "," + arg(t,1) +
				") radius " + arg(t,2);
	"ellipse" =>	return "Ellipse (" + arg(t,0) + "," + arg(t,1) + ")";
	"floodfill" =>	return "Flood Fill (" + arg(t,0) + "," + arg(t,1) + ")";
	"floodfillnot" => return "Flood Fill Not (" + arg(t,0) + "," + arg(t,1) + ")";
	"text" =>	return "Text (" + arg(t,0) + "," + arg(t,1) + ") " +
				join(tl tl t);
	"bitmap" =>	return "BitMap (" + arg(t,0) + "," + arg(t,1) + ") " +
				arg(t,2) + "x" + arg(t,3);
	"mesh" =>	return "Mesh " + arg(t,0) + " vertices, " + arg(t,1) +
				" triangles";
	}
	return kind + " " + join(t);
}

arg(t: list of string, i: int): string
{
	for(; i > 0 && t != nil; i--)
		t = tl t;
	if(t == nil)
		return "?";
	return hd t;
}

join(t: list of string): string
{
	s := "";
	for(; t != nil; t = tl t){
		if(s != "")
			s += " ";
		s += hd t;
	}
	return s;
}

redraw()
{
	img := win.image;
	if(img == nil || font == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));
	rows := (img.r.dy() - font.height) / font.height;
	l := lines;
	for(i := 0; i < top && l != nil; i++)
		l = tl l;
	y := o.y;
	for(i = 0; i < rows && l != nil; i++){
		(c, s) := hd l;
		col := black;
		if(c == 1)
			col = purple;
		img.text(Point(o.x, y), col, Point(0, 0), font, s);
		y += font.height;
		l = tl l;
	}
	img.text(Point(o.x, img.r.max.y - font.height), purple, Point(0, 0), font,
		"up/down scroll, any other key exits");
	img.flush(Draw->Flushnow);
}

rev(l: list of (int, string)): list of (int, string)
{
	r: list of (int, string);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revs(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}
