implement Lowpassfilter;

# TempleOS Demo/Graphics/LowPassFilter.HC — four ways to draw the same curve.
#
# A blue square wave is drawn first: up at t=0, down at the half-width.
# Then the same step response four times over, each a keypress apart.
#
#	CYAN:  y1 = STEP_SIZE-STEP_SIZE*Exp(-0.01*t)   rising
#	       y1 = STEP_SIZE*Exp(-0.01*(t-GR_WIDTH/2)) falling
#	BLACK: y1 = 0.99*y+.01*STEP_SIZE   /  y1 = 0.99*y
#	RED:   y1 = LowPass1(.01,y,STEP_SIZE,dt)  with dt=Rand/10
#	GREEN: y1 = LowPass1(.1, y,STEP_SIZE,dt)  with dt=Rand/10
#
# The cyan curve is the closed-form exponential.  The black one is the
# one-line recurrence everybody writes, y = 0.99y + 0.01x, which lands on
# the same curve only because dt happens to be one every step.  The red
# one is the kernel's LowPass1, which takes dt as an argument and so gives
# the same answer when the steps are ragged — here they are random lengths
# — where the recurrence would not.  The green one is the same filter ten
# times faster, to show what the coefficient means.
#
# LowPass1(f,y,x,dt) is y + (x-y)*(1-Exp(-f*dt)): the exact step over dt
# rather than a fixed fraction per sample.

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

Lowpassfilter: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

STEP_SIZE: con 400;

win: ref Window;
font: ref Font;
white, black, blue, cyan, red, green: ref Image;
stage := 0;			# how many curves have been drawn

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
	win = wmclient->window(ctxt, "TempleOS LowPassFilter", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(int 16rFFFFFFFF);
	black = d.color(int 16r000000FF);
	blue = d.color(int 16r0000AAFF);
	cyan = d.color(int 16r00AAAAFF);
	red = d.color(int 16rAA0000FF);
	green = d.color(int 16r00AA00FF);

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
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			continue;
		if(++stage > 4)
			exit;
		redraw();
	}
}

# LowPass1(f,y,x,dt): the exact exponential step over dt
lowpass1(f, y, x, dt: real): real
{
	return y + (x - y)*(1.0 - math->exp(-f*dt));
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := real img.r.dx();
	img.draw(img.r, white, nil, Point(0, 0));

	# the blue square wave the curves are responses to
	seg(img, o, 0.0, 0.0, 0.0, real STEP_SIZE, blue);
	seg(img, o, 0.0, real STEP_SIZE, w/2.0, real STEP_SIZE, blue);
	seg(img, o, w/2.0, real STEP_SIZE, w/2.0, 0.0, blue);
	seg(img, o, w/2.0, 0.0, w, 0.0, blue);

	if(stage >= 1)
		closedform(img, o, w);
	if(stage >= 2)
		recurrence(img, o, w);
	if(stage >= 3)
		filter(img, o, w, 0.01, red);
	if(stage >= 4)
		filter(img, o, w, 0.1, green);

	if(font != nil){
		msgs := array[] of {
			"blue: the step.  A key adds a curve.",
			"cyan: the closed form, STEP*(1-exp(-0.01t))",
			"black: y = 0.99y + 0.01x, right only because dt is 1",
			"red: LowPass1(.01), same answer with ragged dt",
			"green: LowPass1(.1), ten times faster.  A key exits.",
		};
		img.text(Point(o.x, img.r.max.y - font.height), black, Point(0, 0),
			font, msgs[stage]);
	}
	img.flush(Draw->Flushnow);
}

closedform(img: ref Image, o: Point, w: real)
{
	y := 0.0;
	for(t := 0.0; t < w; t += 1.0){
		y1: real;
		if(t < w/2.0)
			y1 = real STEP_SIZE - real STEP_SIZE*math->exp(-0.01*t);
		else
			y1 = real STEP_SIZE*math->exp(-0.01*(t - w/2.0));
		seg(img, o, t, y, t+1.0, y1, cyan);
		y = y1;
	}
}

recurrence(img: ref Image, o: Point, w: real)
{
	y := 0.0;
	for(t := 0.0; t < w; t += 1.0){
		y1: real;
		if(t < w/2.0)
			y1 = 0.99*y + 0.01*real STEP_SIZE;
		else
			y1 = 0.99*y;
		seg(img, o, t, y, t+1.0, y1, black);
		y = y1;
	}
}

# dt=Rand/10: steps of random length, which is the point
filter(img: ref Image, o: Point, w, f: real, col: ref Image)
{
	y := 0.0;
	t := 0.0;
	while(t < w){
		dt := rnreal()/10.0;
		if(dt <= 0.0)
			dt = 0.001;
		y1: real;
		if(t < w/2.0)
			y1 = lowpass1(f, y, real STEP_SIZE, dt);
		else
			y1 = lowpass1(f, y, 0.0, dt);
		seg(img, o, t, y, t+dt, y1, col);
		y = y1;
		t += dt;
	}
}

seg(img: ref Image, o: Point, x1, y1, x2, y2: real, col: ref Image)
{
	img.line(Point(o.x + int x1, o.y + int y1),
		Point(o.x + int x2, o.y + int y2),
		Draw->Endsquare, Draw->Endsquare, 0, col, Point(0, 0));
}

rnreal(): real
{
	if(rand == nil)
		return real(sys->millisec() & 1023) / 1023.0;
	return real(rand->rand(1000000)) / 1000000.0;
}
