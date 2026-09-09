implement Bspline;

# TempleOS Demo/Graphics/BSpline.HC.
#
#	"Sel ctrl points with left mouse.  Right when finished."
#	collect up to PTS_NUM=16 points on MSG_MS_L_UP, drawing a GREEN
#	GrCircle of radius 10 at each; stop on MSG_MS_R_UP;
#	then Gr2BSpline(dc,c,i,TRUE) in RED and Gr3BSpline(dc,c,i,TRUE)
#	in BLUE over the same control points; PressAKey; DCFill.
#
# The two curves are the demo: the quadratic hugs the control polygon and
# the cubic pulls away from it, and both are drawn over the same points so
# the difference is the thing you look at.  The trailing TRUE is
# Gr?BSpline's connect argument, which closes the curve.
#
# Gr2BSpline is the clamped quadratic that interpolates its endpoints —
# the same curve appl/temple/zing.b draws for the bow — and Gr3BSpline the
# uniform cubic, which passes through none of its control points.

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
include "grpalette.m";
	grpal: Grpalette;

Bspline: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PTS_NUM: con 16;
SEGSTEPS: con 16;

win: ref Window;
font: ref Font;
black, white, blue, green, red: ref Image;
cx, cy: array of real;
npts := 0;
done := 0;

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

	win = wmclient->window(ctxt, "TempleOS BSpline", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "/fonts/temple/temple.font");
	black = d.color(grpal->value(Grpalette->BLACK));
	white = d.color(grpal->value(Grpalette->WHITE));
	blue = d.color(grpal->value(Grpalette->BLUE));
	green = d.color(grpal->value(Grpalette->GREEN));
	red = d.color(grpal->value(Grpalette->RED));

	cx = array[PTS_NUM] of real;
	cy = array[PTS_NUM] of real;

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();

	down := 0;
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	k := <-win.ctxt.kbd =>
		# PressAKey waits for a key-down; Inferno delivers key-up as
		# Keyup|k and it must not count
		if((k & Keyboard->Keyup) != Keyboard->Keyup && done)
			exit;
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img == nil)
			continue;
		b := p.buttons;
		if(!done && b == 0 && down){	# the button-up messages
			if(down & 1 && npts < PTS_NUM){
				cx[npts] = real(p.xy.x - img.r.min.x);
				cy[npts] = real(p.xy.y - img.r.min.y);
				npts++;
				if(npts >= PTS_NUM)
					done = 1;
			}
			if(down & 4)
				done = 1;
			redraw();
		}
		down = b;
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));
	if(font != nil){
		msg := "Sel ctrl points with left mouse.  Right when finished.";
		if(done)
			msg = "red Gr2BSpline, blue Gr3BSpline.  Any key to finish.";
		img.text(o, black, Point(0, 0), font, msg);
	}
	for(i := 0; i < npts; i++)
		img.ellipse(Point(o.x+int cx[i], o.y+int cy[i]), 10, 10, 0,
			green, Point(0, 0));
	if(done && npts >= 3){
		spline2(img, o);
		spline3(img, o);
	}
	img.flush(Draw->Flushnow);
}

# Gr2BSpline with connect: a closed clamped quadratic.  Each interior
# control point owns one quadratic Bezier whose ends are the midpoints of
# the neighbouring edges, so the curve touches those midpoints and is
# pulled toward, not through, each control point.
spline2(img: ref Image, o: Point)
{
	n := npts;
	prev := pt(o, mid(cx[n-1], cx[0]), mid(cy[n-1], cy[0]));
	for(i := 0; i < n; i++){
		sx := mid(cx[(i+n-1)%n], cx[i]);
		sy := mid(cy[(i+n-1)%n], cy[i]);
		ex := mid(cx[i], cx[(i+1)%n]);
		ey := mid(cy[i], cy[(i+1)%n]);
		for(s := 1; s <= SEGSTEPS; s++){
			t := real s / real SEGSTEPS;
			u := 1.0 - t;
			p := pt(o, u*u*sx + 2.0*t*u*cx[i] + t*t*ex,
				u*u*sy + 2.0*t*u*cy[i] + t*t*ey);
			img.line(prev, p, Draw->Endsquare, Draw->Endsquare, 0,
				red, Point(0, 0));
			prev = p;
		}
	}
}

# Gr3BSpline with connect: the closed uniform cubic B-spline, four control
# points to a segment with the usual 1/6 basis.  It interpolates none of
# them, which is the visible difference from the quadratic above.
spline3(img: ref Image, o: Point)
{
	n := npts;
	first := 1;
	prev := Point(0, 0);
	for(i := 0; i < n; i++){
		p0x := cx[i]; p0y := cy[i];
		p1x := cx[(i+1)%n]; p1y := cy[(i+1)%n];
		p2x := cx[(i+2)%n]; p2y := cy[(i+2)%n];
		p3x := cx[(i+3)%n]; p3y := cy[(i+3)%n];
		for(s := 0; s <= SEGSTEPS; s++){
			t := real s / real SEGSTEPS;
			u := 1.0 - t;
			b0 := u*u*u / 6.0;
			b1 := (3.0*t*t*t - 6.0*t*t + 4.0) / 6.0;
			b2 := (-3.0*t*t*t + 3.0*t*t + 3.0*t + 1.0) / 6.0;
			b3 := t*t*t / 6.0;
			p := pt(o, b0*p0x + b1*p1x + b2*p2x + b3*p3x,
				b0*p0y + b1*p1y + b2*p2y + b3*p3y);
			if(!first)
				img.line(prev, p, Draw->Endsquare, Draw->Endsquare,
					0, blue, Point(0, 0));
			first = 0;
			prev = p;
		}
	}
}

mid(a, b: real): real
{
	return (a + b) / 2.0;
}

pt(o: Point, x, y: real): Point
{
	return Point(o.x + int x, o.y + int y);
}
