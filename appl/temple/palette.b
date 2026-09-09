implement Palette;

# TempleOS Demo/Graphics/Palette.HC — the sixteen colours are not fixed.
#
#	for (i=0;i<COLORS_NUM;i++)
#	  "$$BLACK$$$$BG,%d$$__%-8Z__$$FG$$$$BG$$\n",i,i,"ST_COLORS";
#	SettingsPush;
#	for (i=0;i<COLORS_NUM;i++) {
#	  j=0xFFFF*i/(COLORS_NUM-1);
#	  bgr.b=j; bgr.g=j; bgr.r=j;
#	  GrPaletteColorSet(i,bgr);
#	}
#	PressAKey;
#	GrPaletteColorSet(WHITE,0xFFFFFFFF0000);
#	PressAKey;
#	SettingsPop;   //restores the original palette
#
# Sixteen swatches, each labelled with its colour name on its own
# background.  Then the palette registers are rewritten so every entry is
# a grey of 0xFFFF*i/15, and the same swatches — unchanged, still naming
# BLUE and RED — come back as a grey ramp, because a colour index means
# whatever the palette says it means.  A second keypress sets WHITE alone
# back to full white, and SettingsPop restores the lot.
#
# GAP: this is a VGA palette register in the original.  Inferno resolves a
#      colour when the image is made, so the port keeps the palette in an
#      array and repaints from it, which shows the same thing happening to
#      the same drawing but does not reach across the display the way
#      writing the hardware registers does.

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
include "grpalette.m";
	grpal: Grpalette;

Palette: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

COLORS_NUM: con Grpalette->COLORS;

win: ref Window;
font: ref Font;
d: ref Display;
pal: array of ref Image;
stage := 0;			# 0 = as shipped, 1 = grey ramp, 2 = WHITE restored
startpal := Grpalette->RICH;	# whichever palette the session started in

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	startpal = grpal->loaded();
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS Palette", Wmclient->Appl);
	d = win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "/fonts/temple/temple.font");
	setpalette(0);

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
		if(++stage > 2)		# SettingsPop, then out
			exit;
		setpalette(stage);
		redraw();
	}
}

# GrPaletteColorSet, for real.  This port used to keep its own copy of the
# sixteen registers and paint from that; now it writes grpalette(2)'s, which
# is what the demo is actually about - the drawing does not change, the
# registers underneath it do.
setpalette(st: int)
{
	case st {
	0 =>	grpal->set(startpal);
	1 =>	grpal->set(Grpalette->GREY);	# j=0xFFFF*i/15 in every channel
	2 =>	grpal->set(Grpalette->GREY);
		grpal->setcolour(Grpalette->WHITE, int 16rFFFFFFFF);
	}
	pal = grpal->images(d);
}

redraw()
{
	img := win.image;
	if(img == nil || font == nil)
		return;
	o := img.r.min;
	img.draw(img.r, pal[15], nil, Point(0, 0));
	rowh := font.height + 4;
	for(i := 0; i < COLORS_NUM; i++){
		y := o.y + i*rowh;
		# "$$BLACK$$$$BG,%d$$__%-8Z__$$FG$$$$BG$$": the name on its own
		# background, in black, padded either side by two underscores
		img.draw(Rect((o.x, y), (o.x + 20*8, y + rowh)), pal[i], nil, Point(0,0));
		img.text(Point(o.x + 8, y + 2), pal[0], Point(0, 0), font,
			sys->sprint("__%-8s__", grpal->name(i)));
	}
	msg := "the palette as shipped.  A key greys it.";
	if(stage == 1)
		msg = "every register set to a grey ramp; the names have not changed.";
	else if(stage == 2)
		msg = "WHITE alone set back.  A key restores the rest and exits.";
	img.text(Point(o.x, o.y + COLORS_NUM*rowh + 8), pal[0], Point(0, 0), font, msg);
	img.flush(Draw->Flushnow);
}
