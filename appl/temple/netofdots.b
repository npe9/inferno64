implement Netofdots;

# TempleOS Demo/Graphics/NetOfDots.HC

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Netofdots: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
red, white: ref Image;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS NetOfDots", Wmclient->Appl);
	d := win.display;
	red = d.color(Draw->Red);
	white = d.color(Draw->White);
	win.reshape(Rect((0, 0), (480, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	paint();
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			paint();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q')
			exit;
		if(k == ' ')
			paint();
	}
}

paint()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, white, nil, Point(0, 0));
	o := img.r.min;
	n := img.r.dx();
	if(img.r.dy() < n)
		n = img.r.dy();
	for(i := 0; i < n; i += 20)
		img.line(Point(i, 0).add(o), Point(0, n-i).add(o), 0, 0, 1, red, Point(0, 0));
	img.flush(Draw->Flushnow);
}
