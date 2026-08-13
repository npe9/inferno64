implement Doodle;

# TempleOS Demo/Graphics/Doodle.HC — stock Inferno Wmclient+Draw port
# LMB draw; c / RMB cycle color; q quit

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Doodle: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
ink: array of ref Image;
color := 4;	# RED
down := 0;
x0, y0: int;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Doodle", Wmclient->Appl);
	d := win.display;
	ink = array[16] of ref Image;
	cols := array[] of {
		Draw->Black, Draw->Blue, Draw->Green, Draw->Cyan,
		Draw->Red, Draw->Magenta, Draw->Darkyellow, Draw->Grey,
		int 16r444444FF, Draw->Paleblue, Draw->Palegreen, Draw->Palebluegreen,
		int 16rFF8888FF, int 16rFF88FFFF, Draw->Yellow, Draw->White
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	if(win.image != nil)
		win.image.draw(win.image.r, ink[15], nil, Point(0, 0));

	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!'){
			if(win.image != nil)
				win.image.draw(win.image.r, ink[15], nil, Point(0, 0));
		}
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			exit;
		'c' or 'C' =>
			color = (color + 1) & 15;
			if(color == 15)
				color = 0;
		}
	}
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	if(p.buttons & 2){
		color = (color + 1) & 15;
		if(color == 15)
			color = 0;
	}
	if(p.buttons & 1){
		if(!down){
			down = 1;
			x0 = x;
			y0 = y;
		}else{
			img.line(Point(x0, y0).add(img.r.min), Point(x, y).add(img.r.min),
				Draw->Endsquare, Draw->Endsquare, 3, ink[color], Point(0, 0));
			x0 = x;
			y0 = y;
			img.flush(Draw->Flushnow);
		}
	}else
		down = 0;
}
