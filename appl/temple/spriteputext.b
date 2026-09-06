implement Spriteputext;

# TempleOS Demo/Graphics/SpritePutExt.HC — a sprite from another file.
#
#	for (i=0;i<3;i++) {
#	  "US Map:";
#	  Sprite($IB,"<1>",BI=1,BP="::/Demo/Graphics/SpritePut.HC,2"$);
#	  "%h12c",'\n';
#	}
#
# The demo is the BP= clause.  The sprite is not in this file at all: the
# bin is a DOCEF_BIN_PTR_LINK naming another source file and the number of
# a sprite inside it, so editing SpritePut.HC's second sprite changes what
# this program draws.  The original's own warning is that the number
# breaks if the sprites in the target file are reordered; a tag string can
# be linked instead.
#
# Here that is the same thing spelled with a path: the asset opened is
# icons/temple/spriteput_2, which is bin 2 of SpritePut.HC and belongs to
# temple/spriteput(1).  Nothing in this port owns it.

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

Spriteputext: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

FH: con 8;

# the original's BP="::/Demo/Graphics/SpritePut.HC,2"
BORROWED: con "/icons/temple/spriteput_2";

win: ref Window;
font: ref Font;
white, blue, red: ref Image;
map, mapmask: ref Image;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS SpritePutExt", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(int 16rFFFFFFFF);
	blue = d.color(int 16r0000AAFF);
	red = d.color(int 16rAA0000FF);
	map = d.open(BORROWED + ".bit");
	mapmask = d.open(BORROWED + ".mask");

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: nil);
	redraw();
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));
	y := o.y;
	for(i := 0; i < 3; i++){
		if(font != nil)
			img.text(Point(o.x, y), blue, Point(0, 0), font, "US Map:");
		y += font.height;
		if(map != nil){
			img.draw(map.r.addpt(Point(o.x, y)), map, mapmask, map.r.min);
			y += 12*FH;
		}else{
			img.text(Point(o.x, y), red, Point(0, 0), font,
				"the linked sprite is missing: " + BORROWED);
			y += 2*font.height;
		}
	}
	if(font != nil)
		img.text(Point(o.x, img.r.max.y - font.height), blue, Point(0, 0), font,
			"this sprite belongs to temple/spriteput(1); nothing here owns it");
	img.flush(Draw->Flushnow);
}
