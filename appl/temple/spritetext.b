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
#
# The walk goes through vsprite(2), which owns that vocabulary, rather
# than through a tokeniser of this port's own.  A demo whose whole subject
# is what a sprite element IS has no business holding a second, smaller
# opinion of it: the private version knew fifteen of the thirty kinds by
# name and printed the rest as their raw line, and it could not have said
# that a line was malformed because it never parsed one.  Reading the
# element and printing vsprite(2)'s own elemline() for the code listing
# also makes the listing what Sprite2Code emits — the source that would
# rebuild this sprite — rather than an echo of the file.  Verified: all
# 248 shipped .spr round-trip through parseline/elemline with no change
# of meaning, one of them re-quoted ("'" comes back as '\'').

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

include "math/vsprite.m";
	vspr: Vsprite;
	Elem, Sprite: import vspr;

Spritetext: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

ELEMS: con "/lib/temple/sprites/spritetext_1.spr";
elems := ELEMS;			# -t may name another

win: ref Window;
font: ref Font;
white, black, purple: ref Image;
lines: list of (int, string);		# (colour index, text)
top := 0;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	vspr = load Vsprite Vsprite->PATH;
	if(vspr != nil)
		vspr->init();
	# -t prints what the window would show and exits.  A demo whose
	# whole output is text can be diffed, and that is how the move to
	# vsprite(2) was checked line by line against the walk it replaced.
	if(tl argv != nil && hd tl argv == "-t"){
		if(tl tl argv != nil)
			elems = hd tl tl argv;
		build();
		for(l := lines; l != nil; l = tl l){
			(nil, t) := hd l;
			sys->print("%s\n", t);
		}
		return;
	}
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
	l: list of (int, string);
	if(vspr == nil){
		lines = (0, "cannot load "+Vsprite->PATH) :: nil;
		return;
	}
	(spr, err) := vspr->read(elems);
	if(spr == nil){
		lines = (0, "cannot read "+elems+": "+err) :: nil;
		return;
	}
	l = (1, "**** LINE SUMMARIES ****") :: l;
	for(i := 0; i < len spr.elems; i++)
		l = (0, summary(spr.elems[i])) :: l;
	l = (0, "") :: l;
	l = (1, "**** ENTIRE SPRITE CODE ****") :: l;
	for(i = 0; i < len spr.elems; i++)
		l = (0, vspr->elemline(spr.elems[i])) :: l;
	lines = rev(l);
}

# SpriteElem2Summary: the element kind and its salient numbers.  Every
# kind vsprite(2) knows has a case here, so a sprite using one this demo
# has not seen still gets a summary and not its raw line.
summary(e: ref Elem): string
{
	nm := vspr->kindname(e.kind);
	case e.kind {
	Vsprite->SEND =>	return "End";
	Vsprite->SCOLOR =>	return "Color " + string e.a[0];
	Vsprite->SDITHER =>	return "Dither Color " + string e.a[0] + "," +
					string e.a[1];
	Vsprite->STHICK =>	return "Thick " + string e.a[0];
	Vsprite->SPLANARSYM =>	return "Planar Symmetry " + pair(e, 0) + "-" + pair(e, 2);
	Vsprite->STRANSON =>	return "Transformation On";
	Vsprite->STRANSOFF =>	return "Transformation Off";
	Vsprite->SSHIFT =>	return "Shift " + pair(e, 0);
	Vsprite->SPT =>		return "Point " + pair(e, 0);
	Vsprite->SPOLYPT =>	return "PolyPoint " + string e.a[0] + " steps from " +
					pair(e, 1);
	Vsprite->SLINE =>	return "Line " + pair(e, 0) + "-" + pair(e, 2);
	Vsprite->SARROW =>	return "Arrow " + pair(e, 0) + "-" + pair(e, 2);
	Vsprite->SPOLYLINE =>	return "PolyLine " + string (len e.pts/2) + " points";
	Vsprite->SRECT =>	return "Rect " + pair(e, 0) + "-" + pair(e, 2);
	Vsprite->SROTRECT =>	return "Rotated Rect " + pair(e, 0) + "-" + pair(e, 2) +
					" at " + sys->sprint("%g", e.ang);
	Vsprite->SCIRCLE =>	return "Circle " + pair(e, 0) + " radius " + string e.a[2];
	Vsprite->SELLIPSE =>	return "Ellipse " + pair(e, 0) + " radii " + pair(e, 2) +
					" at " + sys->sprint("%g", e.ang);
	Vsprite->SPOLYGON =>	return "Polygon " + string e.a[4] + " sides at " +
					pair(e, 0);
	Vsprite->SBSPLINE2 or Vsprite->SBSPLINE2C or
	Vsprite->SBSPLINE3 or Vsprite->SBSPLINE3C =>
				return nm + " " + string (len e.pts/3) + " control points";
	Vsprite->SFLOOD =>	return "Flood Fill " + pair(e, 0);
	Vsprite->SFLOODNOT =>	return "Flood Fill Not " + pair(e, 0);
	Vsprite->SBITMAP =>	return "BitMap " + pair(e, 0) + " " + string e.a[2] +
					"x" + string e.a[3];
	Vsprite->SMESH or Vsprite->SSHIFTMESH =>
				return nm + " " + string e.a[0] + " vertices, " +
					string e.a[1] + " triangles";
	Vsprite->STEXT or Vsprite->STEXTBOX or Vsprite->STEXTDIAMOND =>
				return nm + " " + pair(e, 0) + " " + e.txt;
	}
	return nm;
}

pair(e: ref Elem, i: int): string
{
	if(i+1 >= len e.a)
		return "(?,?)";
	return "(" + string e.a[i] + "," + string e.a[i+1] + ")";
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

