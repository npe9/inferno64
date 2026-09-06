implement Predatorprey;

# TempleOS Demo/Graphics/PredatorPrey.HC — "Classic 2nd order nonlinear
# ordinary differential equation".
#
#	Steps: for (i=0;i<10000;i++) {
#	  s->d_wabbits = s->wabbits*(1.0-0.10*s->hawks);
#	  s->d_hawks   =-s->hawks  *(1.0-0.01*s->wabbits);
#	  s->hawks   += s->d_hawks   *MICRO_STEP;
#	  s->wabbits += s->d_wabbits *MICRO_STEP;
#	}
#	PlotTrajectory: wabbits=Rand%100+10; hawks=Rand%10+1;
#	  for (i=0;i<1000;i++) {
#	    LTGREEN: GrPlot(dc, wabbits+OX, OY-d_wabbits);
#	    LTRED:   GrPlot(dc, hawks  +OX, OY-d_hawks);
#	    Steps(&s);
#	  }
#
# Lotka-Volterra, integrated by plain Euler at a millionth of a time unit,
# ten thousand of those between plotted points.  What is plotted is not
# the populations against time but each population against its own rate
# of change, which turns the cycle into a closed loop and makes the whole
# family of orbits visible at once as trajectory after trajectory is
# started from a random pair and drawn over the last.
#
# The original runs one trajectory per core through JobQue and waits on a
# bitmask; Dis execution here is serialised, so the port runs them one
# after another, which changes the order they appear in and nothing else.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "rand.m";
	rand: Rand;

Predatorprey: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

OX: con 10;
FH: con 8;
MICRO_STEP: con 0.000001;

win: ref Window;
font: ref Font;
white, black, ltgreen, ltred, blue: ref Image;
wabbits, hawks, dwabbits, dhawks: real;
n := 0;				# points plotted on this trajectory
showhelp := 1;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS PredatorPrey", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(int 16rFFFFFFFF);
	black = d.color(int 16r000000FF);
	blue = d.color(int 16r0000AAFF);
	ltgreen = d.color(int 16r55FF55FF);
	ltred = d.color(int 16rFF5555FF);

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: nil);
	newtrajectory();
	axes();
	popup();

	ticks := chan of int;
	spawn timer(ticks, 20);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(showhelp)
			popup();
		else
			axes();
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			continue;
		if(showhelp){
			showhelp = 0;
			axes();
		}else
			exit;
	<-ticks =>
		if(!showhelp)
			plot();
	}
}

newtrajectory()
{
	wabbits = real(rn(100) + 10);
	hawks = real(rn(10) + 1);
	dwabbits = dhawks = 0.0;
	n = 0;
}

# ten thousand Euler steps of a millionth each, between plotted points
steps()
{
	for(i := 0; i < 10000; i++){
		dwabbits = wabbits*(1.0 - 0.10*hawks);
		dhawks = -hawks*(1.0 - 0.01*wabbits);
		hawks += dhawks*MICRO_STEP;
		wabbits += dwabbits*MICRO_STEP;
	}
}

plot()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	oy := img.r.dy()/2 - FH;
	# a handful of points a tick, so the loop is watchable
	for(k := 0; k < 20; k++){
		dot(img, o, OX + int wabbits, oy - int dwabbits, ltgreen);
		dot(img, o, OX + int hawks, oy - int dhawks, ltred);
		steps();
		if(++n >= 1000){
			newtrajectory();
			break;
		}
	}
	img.flush(Draw->Flushnow);
}

dot(img: ref Image, o: Point, x, y: int, col: ref Image)
{
	img.draw(Rect((o.x+x, o.y+y), (o.x+x+1, o.y+y+1)), col, nil, Point(0, 0));
}

axes()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	oy := img.r.dy()/2 - FH;
	img.draw(img.r, white, nil, Point(0, 0));
	img.line(Point(o.x+OX, o.y), Point(o.x+OX, o.y+img.r.dy()-FH-1),
		Draw->Endsquare, Draw->Endsquare, 0, black, Point(0, 0));
	img.line(Point(o.x, o.y+oy), Point(o.x+img.r.dx()-1, o.y+oy),
		Draw->Endsquare, Draw->Endsquare, 0, black, Point(0, 0));
	if(font != nil)
		img.text(Point(o.x, img.r.max.y - font.height), blue, Point(0, 0),
			font, "green rabbits, red hawks, each against its own rate of change.  Any key exits.");
	img.flush(Draw->Flushnow);
}

# the original's PopUpOk, verbatim
popup()
{
	img := win.image;
	if(img == nil || font == nil)
		return;
	o := img.r.min;
	lines := array[] of {
		"This will plot multiple predator-prey",
		"trajectories.  It restarts many times",
		"with different, random, initial populations.",
	};
	img.draw(img.r, white, nil, Point(0, 0));
	y := o.y + img.r.dy()/2 - 3*font.height;
	for(i := 0; i < len lines; i++){
		img.text(Point(o.x + 40, y), black, Point(0, 0), font, lines[i]);
		y += font.height + 2;
	}
	img.text(Point(o.x + 40, y + font.height), blue, Point(0, 0), font,
		"any key");
	img.flush(Draw->Flushnow);
}

rn(n1: int): int
{
	if(rand == nil)
		return sys->millisec() % n1;
	return rand->rand(n1);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
