implement Circletrace;

# TempleOS Demo/Games/CircleTrace.HC — trace a circle freehand
# LMB draw around guide circle; score by radial error

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

Circletrace: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

RADIUS: con 100;

win: ref Window;
ink: array of ref Image;
cx, cy: int;
down := 0;
lx, ly: int;
total_err := 0.0;
total_dist := 0.001;
best := 999.0;

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

	win = wmclient->window(ctxt, "TempleOS CircleTrace", Wmclient->Appl);
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

	win.reshape(Rect((0, 0), (500, 500)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	resetguide();

	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			resetguide();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q')
			exit;
		if(k == 'r' || k == 'R' || k == '\n')
			resetguide();
	}
}

resetguide()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, ink[15], nil, Point(0, 0));
	cx = img.r.dx() / 2;
	cy = img.r.dy() / 2;
	o := img.r.min;
	img.ellipse(Point(cx, cy).add(o), RADIUS, RADIUS, 0, ink[0], Point(0, 0));
	img.flush(Draw->Flushnow);
	down = 0;
	total_err = 0.0;
	total_dist = 0.001;
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	o := img.r.min;
	if(p.buttons & 1){
		if(!down){
			down = 1;
			lx = x; ly = y;
			total_err = 0.0;
			total_dist = 0.001;
			# refresh guide
			img.draw(img.r, ink[15], nil, Point(0, 0));
			img.ellipse(Point(cx, cy).add(o), RADIUS, RADIUS, 0, ink[0], Point(0, 0));
		}else{
			img.line(Point(lx, ly).add(o), Point(x, y).add(o),
				Draw->Endsquare, Draw->Endsquare, 0, ink[4], Point(0, 0));
			rad := math->sqrt(real((x-cx)*(x-cx) + (y-cy)*(y-cy)));
			total_err += math->fabs(rad - real RADIUS);
			dd := math->sqrt(real((x-lx)*(x-lx) + (y-ly)*(y-ly)));
			total_dist += dd;
			lx = x; ly = y;
			img.flush(Draw->Flushnow);
		}
	}else if(down){
		down = 0;
		avg := total_err / (total_dist / (2.0*Math->Pi*real RADIUS) + 0.001);
		score := avg;
		if(score < best)
			best = score;
		# flash score as title
		win.settitle(sys->sprint("CircleTrace err=%.1f best=%.1f", score, best));
	}
}
