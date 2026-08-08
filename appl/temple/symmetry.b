implement Symmetry;

# TempleOS Demo/Graphics/Symmetry.HC
# RMB set mirror line; LMB draw (mirrored); q quit

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Symmetry: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
black, red, white: ref Image;
sym_on := 1;
sx1, sy1, sx2, sy2: int;
down := 0;
mode := 0;	# 1 LMB draw, 2 RMB set
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
	win = wmclient->window(ctxt, "TempleOS Symmetry", Wmclient->Appl);
	d := win.display;
	black = d.color(Draw->Black);
	red = d.color(Draw->Red);
	white = d.color(Draw->White);
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	if(win.image != nil){
		win.image.draw(win.image.r, white, nil, Point(0, 0));
		sx1 = win.image.r.dx()/2; sy1 = 0;
		sx2 = sx1; sy2 = 1;
		drawmirror();
	}
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q')
			exit;
		if(k == 'c' || k == 'C'){
			if(win.image != nil){
				win.image.draw(win.image.r, white, nil, Point(0, 0));
				drawmirror();
			}
		}
	}
}

drawmirror()
{
	img := win.image;
	if(img == nil || !sym_on)
		return;
	o := img.r.min;
	img.line(Point(sx1, sy1).add(o), Point(sx2, sy2).add(o), 0, 0, 0, red, Point(0, 0));
	img.flush(Draw->Flushnow);
}

# reflect point across line (sx1,sy1)-(sx2,sy2)
reflect(x, y: int): (int, int)
{
	dx := real(sx2 - sx1);
	dy := real(sy2 - sy1);
	if(dx == 0.0 && dy == 0.0)
		return (x, y);
	px := real(x - sx1);
	py := real(y - sy1);
	t := (px*dx + py*dy) / (dx*dx + dy*dy);
	qx := real sx1 + t*dx;
	qy := real sy1 + t*dy;
	return (int(2.0*qx - real x), int(2.0*qy - real y));
}

line2(img: ref Image, x1, y1, x2, y2: int, col: ref Image)
{
	o := img.r.min;
	img.line(Point(x1, y1).add(o), Point(x2, y2).add(o), 0, 0, 1, col, Point(0, 0));
	if(sym_on){
		(a, b) := reflect(x1, y1);
		(c, d) := reflect(x2, y2);
		img.line(Point(a, b).add(o), Point(c, d).add(o), 0, 0, 1, col, Point(0, 0));
	}
	img.flush(Draw->Flushnow);
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	if(p.buttons & 2){
		if(mode != 2){
			mode = 2;
			x0 = x; y0 = y;
			sx1 = x; sy1 = y; sx2 = x; sy2 = y;
			sym_on = 0;
		}else{
			# rubber — just update endpoint; full redraw expensive, draw red tip
			sx2 = x; sy2 = y;
		}
	}else if(mode == 2){
		sx2 = x; sy2 = y;
		if(sx1 != sx2 || sy1 != sy2)
			sym_on = 1;
		else
			sym_on = 0;
		mode = 0;
		drawmirror();
	}

	if(p.buttons & 1){
		if(mode != 1){
			mode = 1;
			x0 = x; y0 = y;
		}else{
			line2(img, x0, y0, x, y, black);
			x0 = x; y0 = y;
		}
	}else if(mode == 1)
		mode = 0;
}
