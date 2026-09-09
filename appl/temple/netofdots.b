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
include "grpalette.m";
	grpal: Grpalette;

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
	grpal = load Grpalette Grpalette->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS NetOfDots", Wmclient->Appl);
	d := win.display;
	red = d.color(grpal->value(Grpalette->RED));	# TempleOS RED
	white = d.color(grpal->value(Grpalette->WHITE));	# TempleOS WHITE
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
	<-win.ctxt.kbd =>
		exit;	# original is PressAKey: any key exits
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
		grline(img, o, i, 0, 0, n-i, 3);
	img.flush(Draw->Flushnow);
}

# TempleOS GrLine(dc,x1,y1,x2,y2,step,start=0): a 32.32 fixed-point
# DDA (Adam/Gr/GrMath.HC Line()) stepping along the major axis; with
# step!=1 the increments are multiplied by step and the pixel count
# divided by it, so only every step-th pixel is plotted — a line of
# single-pixel dots. NetOfDots passes step=3; those dots ARE the demo.
grline(img: ref Image, o: Point, x1, y1, x2, y2, step: int)
{
	dx := big (x2-x1);
	dy := big (y2-y1);
	adx := dx;
	if(adx < big 0)
		adx = -adx;
	ady := dy;
	if(ady < big 0)
		ady = -ady;
	d := adx;
	if(ady > adx)
		d = ady;
	one := big 1 << 32;
	if(d != big 0){
		if(adx >= ady){
			if(dx >= big 0)
				dx = one;
			else
				dx = -one;
			dy = (dy << 32) / d;
		}else{
			dx = (dx << 32) / d;
			if(dy >= big 0)
				dy = one;
			else
				dy = -one;
		}
	}
	fx := big x1 << 32;
	fy := big y1 << 32;
	if(step > 1){
		dx *= big step;
		dy *= big step;
		d /= big step;
	}
	lx := 0;
	ly := 0;
	first := 1;
	for(i := big 0; i <= d; i++){
		px := int (fx >> 32);
		py := int (fy >> 32);
		if(first || px != lx || py != ly)
			img.draw(Rect((px, py), (px+1, py+1)).addpt(o), red, nil, Point(0, 0));
		first = 0;
		lx = px;
		ly = py;
		fx += dx;
		fy += dy;
	}
}
