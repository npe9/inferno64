implement Lattice;

# TempleOS Demo/Graphics/Lattice.HC — a turtle with width and layers.
#
#	angles[35] = -2pi/1, -2pi/2, -2pi/3 ... 0 ... 2pi/3, 2pi/2, 2pi/1
#	TurtleMicroMove: x+=dt*speed*Cos(theta); y+=dt*speed*Sin(theta);
#	                 theta=Wrap(theta+dt*angles[dtheta_idx]);
#	TurtleMove: l=16*|w+1|*|speed+1|;
#	            for (i=0;i<l;i++) { TurtleMicroMove(t,1.0/l); TurtlePlot(); }
#	TurtlePlot: a line across the turtle's width in the middle colour,
#	            and a plot at each end in the edge colour.
#	TurtleEnd:  step out along theta plotting chords of a circle of
#	            radius w until w*w-4x*x goes negative — a rounded cap.
#
# The pen is a segment, not a point: every micro-step draws a line across
# the turtle's width perpendicular to its heading, so a stroke is a ribbon
# with its own edge colour.  The number of micro-steps is chosen from the
# width and the speed together, which is what keeps a fat fast stroke from
# coming out as a row of dashes.
#
# The curvature comes from a table rather than a slider, and the table is
# the interesting part: it is 2*pi over 1, 2, 3, 4, 5, 6, 8, 9, 10, 12,
# 15, 18, 20, 24, 30, 36, 40 and their negatives, with zero in the middle.
# Every entry closes a circle in a whole number of steps, so a curve
# always comes back to where it started.
#
# The z is a layer, 0 to 9, kept in the depth buffer, so strokes on a
# higher layer cover lower ones however they are drawn.
#
# GAP: the original's pull-down menu tracks the layer and the ends flag
#      with check marks; every entry is on its key here, and PopUpColor
#      is a strip of the sixteen palette entries.

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
include "grpalette.m";
	grpal: Grpalette;

Lattice: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;
TURTLE_SIZE: con 4;
TURTLE_SPEED_STEP: con 2.0;
ANGLES: con 35;
SWATCH: con 20;

win: ref Window;
font: ref Font;
d: ref Display;
ink: array of ref Image;
canvas: ref Image;		# the layers, drawn into once and kept
zbuf: array of byte;		# DCDepthBufAlloc: one layer per pixel
cw, ch: int;

angles: array of real;
tx, ty, tz, speed, theta, tw: real;
dthetaidx := ANGLES/2;
edge := 0;			# BLACK
middle := 14;			# YELLOW
ends := 1;
first := 1;
aim := 0;
picking := 0;			# PopUpColor: 0 none, 1 mid, 2 edge

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS Lattice", Wmclient->Appl);
	d = win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "/fonts/temple/temple.font");
	ink = array[16] of ref Image;
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	# the angle table, verbatim
	divs := array[] of {1, 2, 3, 4, 5, 6, 8, 9, 10, 12, 15, 18, 20, 24,
		30, 36, 40};
	angles = array[ANGLES] of real;
	for(i = 0; i < len divs; i++){
		angles[i] = -2.0*PI/real divs[i];
		angles[ANGLES-1-i] = 2.0*PI/real divs[i];
	}
	angles[ANGLES/2] = 0.0;

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	reset();
	redraw();
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		reset();
		redraw();
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			key(k);
		redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img == nil)
			continue;
		x := real(p.xy.x - img.r.min.x);
		y := real(p.xy.y - img.r.min.y);
		if(picking){
			if(p.buttons & 1){
				c := swatchat(int x, int y);
				if(c >= 0){
					if(picking == 1)
						middle = c;
					else
						edge = c;
					picking--;
					if(picking == 1)
						picking = 2;
					else
						picking = 0;
				}
				redraw();
			}
			continue;
		}
		if(p.buttons & 1){		# MSG_MS_L_DOWN: move the turtle
			first = 1;
			tx = x;
			ty = y;
		}
		if(p.buttons & 4){		# MSG_MS_R_DOWN / MOVE: aim it
			aim = 1;
			theta = math->atan2(y - ty, x - tx);
		}else if(aim){
			theta = math->atan2(y - ty, x - tx);
			aim = 0;
		}
		redraw();
	}
}

reset()
{
	img := win.image;
	if(img == nil)
		return;
	cw = img.r.dx();
	ch = img.r.dy();
	canvas = d.newimage(Rect((0,0),(cw,ch)), img.chans, 0, Draw->White);
	zbuf = array[cw*ch] of { * => byte 255 };
	tx = real(cw/2);
	ty = real(ch/2);
	tz = 5.0;
	speed = 0.0;
	theta = 0.0;
	tw = 0.0;
	dthetaidx = ANGLES/2;
	edge = 0;
	middle = 14;
	ends = 1;
	first = 1;
}

key(k: int)
{
	if(picking){
		picking = 0;
		return;
	}
	case k {
	16r1b or 'q' or 'Q' =>
		exit;
	Keyboard->Left =>
		if(dthetaidx > 0)
			dthetaidx--;
	Keyboard->Right =>
		if(dthetaidx < ANGLES-1)
			dthetaidx++;
	Keyboard->Up =>
		speed += TURTLE_SPEED_STEP;
	Keyboard->Down =>
		if(speed >= TURTLE_SPEED_STEP)
			speed -= TURTLE_SPEED_STEP;
	' ' =>
		move();			# Step
	'0' to '9' =>
		tz = real(k - '0');
	'c' =>
		picking = 1;		# PopUpColor twice: mid, then edge
	'e' =>
		ends = !ends;
	'+' or '=' =>
		tw += 1.0;
	'-' or '_' =>
		if(tw >= 1.0)
			tw -= 1.0;
	'\n' =>
		reset();
	}
}

# --- the turtle ---------------------------------------------------------

plot(x, y: int, layer, col: int)
{
	if(x < 0 || x >= cw || y < 0 || y >= ch)
		return;
	# the depth buffer: a higher layer wins
	if(int zbuf[y*cw + x] != 255 && int zbuf[y*cw + x] > layer)
		return;
	zbuf[y*cw + x] = byte layer;
	canvas.draw(Rect((x, y), (x+1, y+1)), ink[col], nil, Point(0, 0));
}

line(x1, y1, x2, y2: real, layer, col: int)
{
	dx := x2 - x1;
	dy := y2 - y1;
	n := int(math->fabs(dx));
	if(int(math->fabs(dy)) > n)
		n = int(math->fabs(dy));
	if(n == 0){
		plot(int x1, int y1, layer, col);
		return;
	}
	for(i := 0; i <= n; i++){
		t := real i/real n;
		plot(int(x1 + t*dx), int(y1 + t*dy), layer, col);
	}
}

# TurtlePlot: a line across the width, then a dot at each end
tplot(x, y, th, w: real, layer: int)
{
	hw := w/2.0 - 1.0;
	if(hw < 0.0)
		hw = 0.0;
	line(x + hw*math->cos(th + PI/2.0), y + hw*math->sin(th + PI/2.0),
		x + hw*math->cos(th - PI/2.0), y + hw*math->sin(th - PI/2.0),
		layer, middle);
	e := w/2.0;
	plot(int(x + e*math->cos(th + PI/2.0)), int(y + e*math->sin(th + PI/2.0)),
		layer, edge);
	plot(int(x + e*math->cos(th - PI/2.0)), int(y + e*math->sin(th - PI/2.0)),
		layer, edge);
}

# TurtleEnd: chords of a circle of radius w, stepping out along theta
tend(x, y, th: real, layer: int)
{
	r := tw;
	if(r == 0.0)
		return;
	cx := x;
	cy := y;
	xx := 0.0;
	for(;;){
		cx += 1.0/r*math->cos(th);
		cy += 1.0/r*math->sin(th);
		xx += 1.0/r;
		y2 := r*r - 4.0*xx*xx;
		if(y2 < 0.0)
			break;
		tplot(cx, cy, th, math->sqrt(y2), layer);
	}
}

# TurtleMove: one step of the whole stroke
move()
{
	layer := int tz;
	if(ends && first)
		tend(tx, ty, theta + PI, layer);
	first = 0;
	l := int(16.0 * math->fabs(tw + 1.0) * math->fabs(speed + 1.0));
	if(l < 1)
		l = 1;
	for(i := 0; i < l; i++){
		dt := 1.0/real l;
		tx += dt*speed*math->cos(theta);
		ty += dt*speed*math->sin(theta);
		theta = wrap(theta + dt*angles[dthetaidx]);
		tplot(tx, ty, theta, tw, layer);
	}
	if(ends)
		tend(tx, ty, theta, layer);
}

wrap(a: real): real
{
	two := 2.0*PI;
	a = math->fmod(a, two);
	if(a > PI)
		a -= two;
	if(a <= -PI)
		a += two;
	return a;
}

# --- drawing ------------------------------------------------------------

swatchat(x, y: int): int
{
	if(x < 0 || y < 0 || x >= 8*SWATCH || y >= 2*SWATCH)
		return -1;
	return (y/SWATCH)*8 + x/SWATCH;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	if(canvas == nil || cw != img.r.dx() || ch != img.r.dy())
		reset();
	o := img.r.min;
	img.draw(img.r, canvas, nil, canvas.r.min);

	# the turtle itself: an arrowhead of TURTLE_SIZE
	s := real TURTLE_SIZE;
	ax := tx + s*math->cos(theta + PI/2.0);
	ay := ty + s*math->sin(theta + PI/2.0);
	bx := tx + s*math->cos(theta - PI/2.0);
	by := ty + s*math->sin(theta - PI/2.0);
	nx := tx + s*math->cos(theta);
	ny := ty + s*math->sin(theta);
	seg(img, o, ax, ay, bx, by);
	seg(img, o, ax, ay, nx, ny);
	seg(img, o, bx, by, nx, ny);

	if(font != nil){
		img.text(o, ink[0], Point(0, 0), font,
			sys->sprint("Layer:%g Speed:%g theta:%5.1f dtheta:%5.1f Width:%g",
				tz, speed, theta*180.0/PI,
				angles[dthetaidx]*180.0/PI, tw));
		img.text(Point(o.x, img.r.max.y - font.height), ink[1], Point(0, 0),
			font, "space steps, arrows turn and accelerate, +/- width, 0-9 layer, c colour, e ends, Enter clears");
	}
	if(picking)
		picker(img, o);
	img.flush(Draw->Flushnow);
}

picker(img: ref Image, o: Point)
{
	for(i := 0; i < 16; i++){
		r := Rect((o.x + (i%8)*SWATCH, o.y + (i/8)*SWATCH),
			(o.x + (i%8+1)*SWATCH, o.y + (i/8+1)*SWATCH));
		img.draw(r, ink[i], nil, Point(0, 0));
	}
	if(font != nil){
		what := "Mid Color";
		if(picking == 2)
			what = "Edge Color";
		img.text(Point(o.x, o.y + 2*SWATCH + 2), ink[0], Point(0, 0), font,
			what);
	}
}

seg(img: ref Image, o: Point, x1, y1, x2, y2: real)
{
	img.line(Point(o.x + int x1, o.y + int y1), Point(o.x + int x2, o.y + int y2),
		Draw->Endsquare, Draw->Endsquare, 0, ink[12], Point(0, 0));
}
