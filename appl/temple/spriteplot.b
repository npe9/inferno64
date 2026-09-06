implement Spriteplot;

# TempleOS Demo/Graphics/SpritePlot.HC — sweep a sprite across the screen.
#
#	for (i=0;i<GR_WIDTH>>2;i++) {
#	  DCFill;
#	  Sprite3(dc,i,GR_HEIGHT>>1,0,$IB,"<1>",BI=1$);
#	  Sleep(3);
#	}
#	"Image size:%d\n",$IS,"<1>",BI=1$;
#
# The sprite is the "Welcome to TempleOS" banner.  What the file's own
# comment is about is that this demo uses the persistent gr.dc rather than
# gr.dc2 and so needs no 30fps window-update callback: it just draws and
# sleeps.  The loop runs GR_WIDTH>>2 = 160 steps with Sleep(3), which is
# what the port ticks at.
#
# $IS is the sprite's size in bytes.  The nearest honest figure here is
# the size of the extracted element list, lib/temple/sprites/spriteplot_1.spr,
# which is what the bin held; the rasterised .bit is a different encoding
# and would be a different number, so the file is measured, not the image.

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

Spriteplot: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

GR_WIDTH: con 640;
SPR: con "/icons/temple/spriteplot_1";
ELEMS: con "/lib/temple/sprites/spriteplot_1.spr";

win: ref Window;
font: ref Font;
white, black: ref Image;
spr, mask: ref Image;
x := 0;
done := 0;
imgsize := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS SpritePlot", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(int 16rFFFFFFFF);
	black = d.color(int 16r000000FF);
	spr = d.open(SPR + ".bit");
	mask = d.open(SPR + ".mask");
	(ok, st) := sys->stat(ELEMS);
	if(ok >= 0)
		imgsize = int st.length;

	win.reshape(Rect((0, 0), (GR_WIDTH, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 3);		# the original's Sleep(3)
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	k := <-win.ctxt.kbd =>
		if(done && (k & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	<-ticks =>
		if(!done){
			if(++x >= GR_WIDTH>>2)
				done = 1;
			redraw();
		}
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));	# DCFill
	if(spr != nil)
		img.draw(spr.r.addpt(Point(o.x + x, o.y + img.r.dy()/2)), spr, mask,
			spr.r.min);
	if(done && font != nil)
		img.text(o, black, Point(0, 0), font,
			sys->sprint("Image size:%d", imgsize));
	img.flush(Draw->Flushnow);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
