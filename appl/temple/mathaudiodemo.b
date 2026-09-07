implement Mathaudiodemo;

# TempleOS Demo/Graphics/MathAudioDemo.HC — the waveform library, plotted.
#
#	Init(dc);  RED: FunDraw1(&MySin);   PressAKey;
#	           BLUE: FunDraw2(&Saw,1.0);      PressAKey;
#	           GREEN: FunDraw2(&FullSaw,1.0); PressAKey;
#	Init(dc);  RED: Cos;  BLUE: Caw;  GREEN: FullCaw;
#	Init(dc);  RED: Sin;  BLUE: Tri;  GREEN: FullTri;
#
# Three pages, each a trigonometric function in red with its two cheap
# audio stand-ins over it in blue and green.  The comments in ASnd.HC say
# what the pairs are for: Saw is "0.0 - 1.0, think (Sin+1)/2" and FullSaw
# "1.0 - -1.0, think Sin"; Caw and FullCaw are the same against Cos; Tri
# and FullTri are the triangle forms.  Seeing them drawn on the same axes
# is the whole demo — how far a sawtooth is from a sine, and how little
# that matters at audio rates.
#
# The functions are transcribed from Adam/ASnd.HC, including the sign
# split for negative t, which is why Saw of a negative argument is
# 1.0+t%period/period rather than the obvious thing.
#
# MySin and MyCos exist in the original only because, as its comment says,
# "Sin() does not have an address" — they are compiler intrinsics and
# cannot be passed as function pointers.

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

Mathaudiodemo: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;
FW: con 8;
FH: con 8;

win: ref Window;
font: ref Font;
white, black, dkgray, red, blue, green: ref Image;
stage := 0;			# nine steps, three to a page

names := array[] of {
	"Sin", "Saw", "FullSaw",
	"Cos", "Caw", "FullCaw",
	"Sin", "Tri", "FullTri",
};

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
	win = wmclient->window(ctxt, "TempleOS MathAudioDemo", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(int 16rFFFFFFFF);
	black = d.color(int 16r000000FF);
	dkgray = d.color(int 16r555555FF);
	red = d.color(int 16rAA0000FF);
	blue = d.color(int 16r0000AAFF);
	green = d.color(int 16r00AA00FF);

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
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			continue;
		if(++stage >= 9)
			exit;
		redraw();
	}
}

# --- Adam/ASnd.HC, transcribed ------------------------------------------

fmod(a, b: real): real
{
	return math->fmod(a, b);
}

# Sawtooth. 0.0 - 1.0, think "(Sin+1)/2"
saw(t, period: real): real
{
	if(period == 0.0)
		return 0.0;
	if(t >= 0.0)
		return fmod(t, period)/period;
	return 1.0 + fmod(t, period)/period;
}

# Plus&Minus Sawtooth. 1.0 - -1.0, think "Sin"
fullsaw(t, period: real): real
{
	if(period == 0.0)
		return 0.0;
	if(t >= 0.0)
		return 2.0*(fmod(t, period)/period) - 1.0;
	return 2.0*(fmod(t, period)/period) + 1.0;
}

# Cawtooth. 1.0 - 0.0, think "(Cos+1)/2"
caw(t, period: real): real
{
	if(period == 0.0)
		return 1.0;
	if(t >= 0.0)
		return 1.0 - fmod(t, period)/period;
	return -fmod(t, period)/period;
}

# Plus&Minus Cawtooth. 1.0 - -1.0, think "Cos"
fullcaw(t, period: real): real
{
	if(period == 0.0)
		return 1.0;
	if(t >= 0.0)
		return -2.0*(fmod(t, period)/period) + 1.0;
	return -2.0*(fmod(t, period)/period) - 1.0;
}

# Triangle waveform. 0.0 - 1.0 - 0.0
tri(t, period: real): real
{
	if(period == 0.0)
		return 0.0;
	a := t;
	if(a < 0.0)
		a = -a;
	u := 2.0*fmod(a, period)/period;
	if(u <= 1.0)
		return u;
	return 2.0 - u;
}

# Plus&Minus Triangle waveform. 0.0 - 1.0 - 0.0 - -1.0 - 0.0
fulltri(t, period: real): real
{
	if(period == 0.0)
		return 0.0;
	u := 4.0*fmod(t, period)/period;
	if(u <= -1.0){
		if(u <= -3.0)
			return u + 4.0;
		return -2.0 - u;
	}
	if(u <= 1.0)
		return u;
	if(u <= 3.0)
		return 2.0 - u;
	return u - 4.0;
}

# --- drawing ------------------------------------------------------------

# FunDraw1: f of an angle, scaled to the axes
f1(which: int, x: real): real
{
	if(which == 0)
		return math->sin(x);
	return math->cos(x);
}

# FunDraw2: f of t with period T
f2(which: int, t: real): real
{
	case which {
	1 =>	return saw(t, 1.0);
	2 =>	return fullsaw(t, 1.0);
	4 =>	return caw(t, 1.0);
	5 =>	return fullcaw(t, 1.0);
	7 =>	return tri(t, 1.0);
	}
	return fulltri(t, 1.0);
}

redraw()
{
	img := win.image;
	if(img == nil || font == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	scale := real h / 5.0;
	page := stage / 3;
	img.draw(img.r, white, nil, Point(0, 0));

	# Init: axes, ticks at every unit and every T
	img.line(Point(o.x, o.y+h/2), Point(o.x+w-1, o.y+h/2),
		Draw->Endsquare, Draw->Endsquare, 0, black, Point(0, 0));
	img.line(Point(o.x+w/2, o.y), Point(o.x+w/2, o.y+h-1),
		Draw->Endsquare, Draw->Endsquare, 0, black, Point(0, 0));
	for(i := -2; i <= 2; i++){
		y := h/2 - int(scale*real i);
		img.line(Point(o.x+w/2-3, o.y+y), Point(o.x+w/2+3, o.y+y),
			Draw->Endsquare, Draw->Endsquare, 0, black, Point(0, 0));
		if(i != 0)
			img.text(Point(o.x+w/2+5, o.y+y-FH/2), dkgray, Point(0, 0),
				font, sys->sprint("%5.1f", real i));
	}
	for(i = -4; i <= 4; i++){
		x := w/2 + int(scale*real i);
		img.line(Point(o.x+x, o.y+h/2-3), Point(o.x+x, o.y+h/2+3),
			Draw->Endsquare, Draw->Endsquare, 0, black, Point(0, 0));
		if(i != 0)
			img.text(Point(o.x+x-7*FW/2, o.y+h/2+5+FH), dkgray,
				Point(0, 0), font, sys->sprint("%5.1f*T", real i));
	}

	# the curves drawn so far on this page
	for(k := 0; k <= stage % 3; k++){
		which := page*3 + k;
		col := red;
		if(k == 1)
			col = blue;
		else if(k == 2)
			col = green;
		curve(img, o, w, h, scale, which, col);
	}
	img.text(Point(o.x, img.r.max.y - font.height), black, Point(0, 0), font,
		names[stage] + "    any key");
	img.flush(Draw->Flushnow);
}

curve(img: ref Image, o: Point, w, h: int, scale: real, which: int, col: ref Image)
{
	prev := 0;
	for(i := -w/2; i <= w/2; i++){
		v: real;
		if(which % 3 == 0)		# FunDraw1: an angle
			v = f1(which/3 & 1, real i/scale*2.0*PI);
		else				# FunDraw2: t with period T
			v = f2(which, real i/scale);
		y := h/2 - int(scale*v);
		if(i > -w/2)
			img.line(Point(o.x+w/2+i-1, o.y+prev), Point(o.x+w/2+i, o.y+y),
				Draw->Endsquare, Draw->Endsquare, 0, col, Point(0, 0));
		prev = y;
	}
}
