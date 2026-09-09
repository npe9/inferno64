implement Spriteput;

# TempleOS Demo/Graphics/SpritePut.HC — putting sprites in source code.
#
#	for (i=0;i<3;i++) { "US Flag:"; Sprite($IB,"<1>",BI=1$); "%h12c",'\n'; }
#	"US Map:"; Sprite($IB,"<2>",BI=2$); "%h10c",'\n';
#
# Sprite() draws into the document at the cursor and the "%h12c",'\n'
# leaves twelve blank lines for it, so the flag appears three times down
# the page and the map once.  The point of the demo is that the binary
# sprite lives in the source file after the text, addressed by its bin
# number: $SP,"",BI=1$ is the placeholder you see with <CTRL-t>.  Here the
# two bins are icons/temple/spriteput_1 and _2, extracted from that same
# file, and the twelve- and ten-line gaps are kept as pixel spacing.

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

Spriteput: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

FH: con 8;			# TempleOS FONT_HEIGHT

win: ref Window;
font: ref Font;
white, blue: ref Image;
flag, flagmask, map, mapmask: ref Image;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS SpritePut", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(grpal->value(Grpalette->WHITE));
	blue = d.color(grpal->value(Grpalette->BLUE));
	flag = d.open("/icons/temple/spriteput_1.bit");
	flagmask = d.open("/icons/temple/spriteput_1.mask");
	map = d.open("/icons/temple/spriteput_2.bit");
	mapmask = d.open("/icons/temple/spriteput_2.mask");

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
			img.text(Point(o.x, y), blue, Point(0, 0), font, "US Flag:");
		y += font.height;
		blit(img, flag, flagmask, o.x, y);
		y += 12*FH;		# the original's "%h12c",'\n'
	}
	if(font != nil)
		img.text(Point(o.x, y), blue, Point(0, 0), font, "US Map:");
	y += font.height;
	blit(img, map, mapmask, o.x, y);
	img.flush(Draw->Flushnow);
}

blit(img, src, mask: ref Image, x, y: int)
{
	if(src == nil)
		return;
	img.draw(src.r.addpt(Point(x, y)), src, mask, src.r.min);
}
