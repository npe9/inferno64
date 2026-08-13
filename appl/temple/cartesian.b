implement Cartesian;

# TempleOS Demo/Graphics/Cartesian.HC — plot y=f(x)

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Cartesian: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
blue, white, grey, black: ref Image;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Cartesian", Wmclient->Appl);
	d := win.display;
	blue = d.color(Draw->Blue);
	white = d.color(Draw->White);
	grey = d.color(Draw->Grey);
	black = d.color(Draw->Black);
	win.reshape(Rect((0, 0), (640, 400)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	plot();

	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			plot();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q')
			exit;
		if(k == ' ')
			plot();
	}
}

plot()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, white, nil, Point(0, 0));
	w := img.r.dx();
	h := img.r.dy();
	cx := img.r.min.x + w/2;
	cy := img.r.min.y + h/2;
	img.line(Point(img.r.min.x, cy), Point(img.r.max.x, cy), 0, 0, 0, grey, Point(0, 0));
	img.line(Point(cx, img.r.min.y), Point(cx, img.r.max.y), 0, 0, 0, grey, Point(0, 0));
	ox := 0;
	oy := 0;
	first := 1;
	for(x := 0; x < w; x++){
		t := (real(x - w/2) / real(w/2)) * 2.0 * Math->Pi;
		y := math->sin(t) + 0.35*math->sin(3.0*t);
		py := cy - int(y * real(h/2 - 10) / 2.0);
		px := img.r.min.x + x;
		if(!first)
			img.line(Point(ox, oy), Point(px, py), 0, 0, 0, blue, Point(0, 0));
		ox = px; oy = py; first = 0;
	}
	img.flush(Draw->Flushnow);
}
