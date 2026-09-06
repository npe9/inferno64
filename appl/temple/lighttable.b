implement Lighttable;

# TempleOS Demo/Graphics/LightTable.HC — a two-dimensional optics bench.
#
# "There is a coarse and a fine-grained.  The coarse gets flood-filled but
# the fine grained is only outlines."
#
#	Mirror:     theta_out = 2*theta_n + pi - theta_in
#	SnellsLaw:  n1 = (last==LENS_COLOR) ? 1.5 : 1.0;
#	            n2 = (next==LENS_COLOR) ? 1.5 : 1.0;
#	            n1 Sin(theta1) == n2 Sin(theta2)
#	FindNormal: back up one step and walk forward to find the fine-
#	            grained point of contact, then sweep an arc of radius
#	            bmp_norm_radius each side of the incoming direction,
#	            coarse to fine, for the two points where the surface
#	            crosses the circle; the normal is perpendicular to the
#	            chord between them, turned to face the photon.
#	RayBurst:   a photon along the drag, then pairs offset by 2, 5 and 8
#	            along the perpendicular — WING=9.
#
# Two ideas hold the program up.  The first is that the optics live in a
# bitmap rather than in a list of shapes: a mirror is drawn, not
# described, so a spline, a freehand line and a flood-filled blob are all
# the same thing to the photon.  The second is FindNormal, which recovers
# a surface normal from that bitmap by geometry alone — no stored
# gradients, no analytic curve — which is why anything you can draw
# refracts correctly.
#
# The fine bitmap is at a larger scale than the display so the normal
# search has sub-pixel detail to work with, which is what the file's
# opening comment is about.
#
# GAP: the original divides the photons across cores, one queue each with
#      a lock; Dis execution is serialised, so this keeps one list.
# GAP: its pull-down menu holds the six drawing modes with check marks;
#      here they are on keys, listed at the foot of the window.

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

Lighttable: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;
BORDER: con 10;
WING: con 9;
VECTOR: con 20;
BABY_STEPS: con 4;
SCALE: con 4;			# bmp_scale: the fine grid per display pixel
NORM_RADIUS: con 12;		# bmp_norm_radius, in fine units
MAXPHOTONS: con 2048;

# the drawing modes, in the original's order
LTM_REFLECT_LINE, LTM_REFLECT_SPLINE, LTM_REFRACT_LINE,
LTM_REFRACT_SPLINE, LTM_REFRACT_FLOOD_FILL, LTM_TEST_RAY: con iota;

modenames := array[] of {
	"reflect line", "reflect spline", "refract line", "refract spline",
	"refract fill", "test ray"
};

win: ref Window;
font: ref Font;
ink: array of ref Image;

# the coarse map, one byte a display pixel: 0 empty, 1 mirror, 2 lens
map: array of byte;
mw, mh: int;
# the fine bitmaps, one bit a fine pixel
reflectb, refractb: array of byte;
fw, fh, fstride: int;

px, py, vx, vy, nx, ny: array of real;
np := 0;
mode := LTM_REFLECT_LINE;
shownormals := 0;
dragx, dragy: int;
dragging := 0;
splinepts: list of Point;
photoncnt, mirrorcnt, snellcnt, zeronormal: int;

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
	win = wmclient->window(ctxt, "TempleOS LightTable", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	ink = array[16] of ref Image;
	cols := array[] of {
		int 16r000000FF, int 16r0000AAFF, int 16r00AA00FF, int 16r00AAAAFF,
		int 16rAA0000FF, int 16rAA00AAFF, int 16rAA5500FF, int 16rAAAAAAFF,
		int 16r555555FF, int 16r5555FFFF, int 16r55FF55FF, int 16r55FFFFFF,
		int 16rFF5555FF, int 16rFF55FFFF, int 16rFFFF55FF, int 16rFFFFFFFF
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	px = array[MAXPHOTONS] of real;
	py = array[MAXPHOTONS] of real;
	vx = array[MAXPHOTONS] of real;
	vy = array[MAXPHOTONS] of real;
	nx = array[MAXPHOTONS] of real;
	ny = array[MAXPHOTONS] of real;

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	setup();

	ticks := chan of int;
	spawn timer(ticks, 20);		# ANIMATE_JIFFIES: a hundredth
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		setup();
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			key(k);
		redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img == nil)
			continue;
		x := p.xy.x - img.r.min.x;
		y := p.xy.y - img.r.min.y;
		if(p.buttons & 1){
			if(!dragging){
				dragging = 1;
				dragx = x;
				dragy = y;
				if(mode == LTM_REFLECT_SPLINE ||
				   mode == LTM_REFRACT_SPLINE)
					splinepts = Point(x, y) :: splinepts;
				else if(mode == LTM_REFRACT_FLOOD_FILL)
					floodfill(x, y);
			}
		}else if(dragging){
			dragging = 0;
			case mode {
			LTM_REFLECT_LINE =>	stroke(dragx, dragy, x, y, 1);
			LTM_REFRACT_LINE =>	stroke(dragx, dragy, x, y, 2);
			LTM_TEST_RAY =>		rayburst(dragx, dragy, x, y);
			}
		}
		redraw();
	<-ticks =>
		animate();
		redraw();
	}
}

setup()
{
	img := win.image;
	if(img == nil)
		return;
	if(mw == img.r.dx() && mh == img.r.dy())
		return;
	mw = img.r.dx();
	mh = img.r.dy();
	fw = mw*SCALE;
	fh = mh*SCALE;
	fstride = (fw + 7)/8;
	map = array[mw*mh] of { * => byte 0 };
	reflectb = array[fstride*fh] of { * => byte 0 };
	refractb = array[fstride*fh] of { * => byte 0 };
	np = 0;
}

key(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		exit;
	'0' to '5' =>
		mode = k - '0';
		splinepts = nil;
	'n' =>
		shownormals = !shownormals;
	'r' =>
		randomburst();
	'\n' =>
		mw = 0;			# clear everything
		setup();
	'.' =>
		endspline();
	}
}

# --- the two bitmaps ----------------------------------------------------

bpeek(b: array of byte, x, y: int): int
{
	if(x < 0 || x >= fw || y < 0 || y >= fh)
		return 0;
	return int (b[y*fstride + x/8] >> (7 - (x&7))) & 1;
}

bplot(b: array of byte, x, y: int)
{
	if(x < 0 || x >= fw || y < 0 || y >= fh)
		return;
	b[y*fstride + x/8] |= byte (16r80 >> (x&7));
}

# a stroke goes into the coarse map, which is what gets flood-filled and
# drawn, and into the fine bitmap, which is what the normal search reads
stroke(x1, y1, x2, y2, kind: int)
{
	n := absi(x2-x1);
	if(absi(y2-y1) > n)
		n = absi(y2-y1);
	n *= SCALE;
	if(n < 1)
		n = 1;
	b := reflectb;
	if(kind == 2)
		b = refractb;
	for(i := 0; i <= n; i++){
		t := real i/real n;
		fx := real(x1*SCALE) + t*real((x2-x1)*SCALE);
		fy := real(y1*SCALE) + t*real((y2-y1)*SCALE);
		for(dy := -1; dy <= 1; dy++)
			for(dx := -1; dx <= 1; dx++)
				bplot(b, int fx + dx, int fy + dy);
		cx := int(fx/real SCALE);
		cy := int(fy/real SCALE);
		if(cx >= 0 && cx < mw && cy >= 0 && cy < mh)
			map[cy*mw + cx] = byte kind;
	}
}

# a closed quadratic through the clicked points, both bitmaps' worth
endspline()
{
	pts: array of Point;
	n := 0;
	for(l := splinepts; l != nil; l = tl l)
		n++;
	if(n < 3){
		splinepts = nil;
		return;
	}
	pts = array[n] of Point;
	i := n;
	for(l = splinepts; l != nil; l = tl l)
		pts[--i] = hd l;
	kind := 1;
	if(mode == LTM_REFRACT_SPLINE)
		kind = 2;
	prev := mid(pts[n-1], pts[0]);
	for(i = 0; i < n; i++){
		s := mid(pts[(i+n-1)%n], pts[i]);
		e := mid(pts[i], pts[(i+1)%n]);
		for(k := 1; k <= 16; k++){
			t := real k/16.0;
			u := 1.0 - t;
			p := Point(int(u*u*real s.x + 2.0*t*u*real pts[i].x
					+ t*t*real e.x),
				int(u*u*real s.y + 2.0*t*u*real pts[i].y
					+ t*t*real e.y));
			stroke(prev.x, prev.y, p.x, p.y, kind);
			prev = p;
		}
	}
	splinepts = nil;
}

mid(a, b: Point): Point
{
	return Point((a.x+b.x)/2, (a.y+b.y)/2);
}

# the coarse map is what gets flood-filled, as the original's comment says
floodfill(sx, sy: int)
{
	if(sx < 0 || sx >= mw || sy < 0 || sy >= mh)
		return;
	if(map[sy*mw + sx] != byte 0)
		return;
	stack := array[mw*mh] of int;
	sp := 0;
	stack[sp++] = sy*mw + sx;
	while(sp > 0){
		p := stack[--sp];
		if(map[p] != byte 0)
			continue;
		y := p/mw;
		x0 := p%mw;
		while(x0 > 0 && map[y*mw + x0 - 1] == byte 0)
			x0--;
		x1 := p%mw;
		while(x1 < mw-1 && map[y*mw + x1 + 1] == byte 0)
			x1++;
		for(x := x0; x <= x1; x++){
			map[y*mw + x] = byte 2;
			for(fy := y*SCALE; fy < (y+1)*SCALE; fy++)
				for(fx := x*SCALE; fx < (x+1)*SCALE; fx++)
					bplot(refractb, fx, fy);
			if(y > 0 && map[(y-1)*mw + x] == byte 0 && sp < len stack-1)
				stack[sp++] = (y-1)*mw + x;
			if(y < mh-1 && map[(y+1)*mw + x] == byte 0 && sp < len stack-1)
				stack[sp++] = (y+1)*mw + x;
		}
	}
}

# --- photons ------------------------------------------------------------

newphoton(x, y, dx, dy: real)
{
	if(np >= MAXPHOTONS)
		return;
	px[np] = x; py[np] = y;
	vx[np] = dx; vy[np] = dy;
	nx[np] = 0.0; ny[np] = 0.0;
	np++;
	photoncnt++;
}

# RayBurst: the ray you dragged, and pairs offset 2, 5 and 8 across it
rayburst(x1, y1, x2, y2: int)
{
	if(x1 == x2 && y1 == y2)
		return;
	dx := real(x2-x1);
	dy := real(y2-y1);
	d := math->sqrt(dx*dx + dy*dy);
	if(d == 0.0)
		return;
	dx /= d; dy /= d;
	pnx := dy;
	pny := -dx;
	newphoton(real x2, real y2, dx, dy);
	for(i := 2; i <= WING; i += 3){
		newphoton(real x2 + real i*pnx, real y2 + real i*pny, dx, dy);
		newphoton(real x2 - real i*pnx, real y2 - real i*pny, dx, dy);
	}
}

randomburst()
{
	for(i := 0; i < 256; i++){
		a := 2.0*PI*rnreal();
		newphoton(real(BORDER) + rnreal()*real(mw-2*BORDER),
			real(BORDER) + rnreal()*real(mh-2*BORDER),
			math->cos(a), math->sin(a));
	}
}

# FindNormal: recover a normal from the bitmap alone.  Sweep an arc of
# radius NORM_RADIUS each side of the incoming direction, coarse then
# fine, for where the surface crosses the circle; the normal is
# perpendicular to the chord between those two crossings.
findnormal(b: array of byte, i: int): int
{
	th := math->atan2(vy[i], vx[i]);
	cx := px[i]*real SCALE;
	cy := py[i]*real SCALE;
	(ok1, a1) := arcfind(b, cx, cy, th, -1.0);
	(ok2, a2) := arcfind(b, cx, cy, th, 1.0);
	if(!ok1 || !ok2){
		nx[i] = math->cos(th);
		ny[i] = math->sin(th);
		zeronormal++;
		return 0;
	}
	p1x := cx + real NORM_RADIUS*math->cos(a1);
	p1y := cy + real NORM_RADIUS*math->sin(a1);
	p2x := cx + real NORM_RADIUS*math->cos(a2);
	p2y := cy + real NORM_RADIUS*math->sin(a2);
	dx := p1x - p2x;
	dy := p1y - p2y;
	if(dx*dx + dy*dy < 0.01){
		nx[i] = math->cos(th);
		ny[i] = math->sin(th);
		zeronormal++;
		return 0;
	}
	# perpendicular to the chord, turned to face the photon
	ex := dy;
	ey := -dx;
	if(ex*vx[i] + ey*vy[i] < 0.0){
		ex = -dy;
		ey = dx;
	}
	d := math->sqrt(ex*ex + ey*ey);
	nx[i] = ex/d;
	ny[i] = ey/d;
	return 1;
}

arcfind(b: array of byte, cx, cy, th, side: real): (int, real)
{
	# coarse to fine, as the original's step loop does
	step := 1.0;
	while(step >= 0.01){
		phi := 0.0;
		while(phi <= 3.0*PI/4.0){
			a := th + side*(PI/4.0 + phi);
			if(bpeek(b, int(cx + real NORM_RADIUS*math->cos(a)),
				int(cy + real NORM_RADIUS*math->sin(a))))
				return (1, a);
			phi += step*PI/real NORM_RADIUS;
		}
		step /= 4.0;
	}
	return (0, 0.0);
}

# theta_out = 2*theta_n + pi - theta_in
mirror(i: int)
{
	th := math->atan2(vy[i], vx[i]);
	findnormal(reflectb, i);
	thn := math->atan2(ny[i], nx[i]);
	a := 2.0*thn + PI - th;
	vx[i] = math->cos(a);
	vy[i] = math->sin(a);
	mirrorcnt++;
}

# n1 Sin(theta1) == n2 Sin(theta2), with 1.5 inside a lens
snell(i, last, next: int)
{
	th := math->atan2(vy[i], vx[i]);
	findnormal(refractb, i);
	thn := math->atan2(ny[i], nx[i]);
	n1 := 1.0;
	if(last == 2)
		n1 = 1.5;
	n2 := 1.0;
	if(next == 2)
		n2 = 1.5;
	t1 := wrap(th - thn);
	s2 := n1/n2*math->sin(t1);
	if(s2 > 1.0 || s2 < -1.0){
		mirror(i);		# total internal reflection
		return;
	}
	t2 := math->asin(s2);
	a := thn + t2;
	vx[i] = math->cos(a);
	vy[i] = math->sin(a);
	snellcnt++;
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

animate()
{
	i := 0;
	while(i < np){
		alive := 1;
		for(s := 0; s < BABY_STEPS; s++){
			lastc := cell(px[i], py[i]);
			px[i] += vx[i];
			py[i] += vy[i];
			if(px[i] < 0.0 || px[i] >= real mw ||
			   py[i] < 0.0 || py[i] >= real mh){
				alive = 0;
				break;
			}
			nextc := cell(px[i], py[i]);
			if(nextc == lastc)
				continue;
			if(nextc == 1 || lastc == 1)
				mirror(i);
			else
				snell(i, lastc, nextc);
		}
		if(!alive){
			np--;
			px[i] = px[np]; py[i] = py[np];
			vx[i] = vx[np]; vy[i] = vy[np];
			nx[i] = nx[np]; ny[i] = ny[np];
		}else
			i++;
	}
}

cell(x, y: real): int
{
	ix := int x;
	iy := int y;
	if(ix < 0 || ix >= mw || iy < 0 || iy >= mh)
		return 0;
	return int map[iy*mw + ix];
}

# --- drawing ------------------------------------------------------------

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, ink[0], nil, Point(0, 0));

	# the coarse map: mirrors DKGRAY, lenses WHITE, as the original names
	for(y := 0; y < mh; y++){
		x := 0;
		while(x < mw){
			c := int map[y*mw + x];
			x2 := x + 1;
			while(x2 < mw && int map[y*mw + x2] == c)
				x2++;
			if(c != 0){
				col := ink[8];		# MIRROR_COLOR DKGRAY
				if(c == 2)
					col = ink[15];	# LENS_COLOR WHITE
				img.draw(Rect((o.x+x, o.y+y), (o.x+x2, o.y+y+1)),
					col, nil, Point(0, 0));
			}
			x = x2;
		}
	}

	# each photon as a tail of length VECTOR behind it
	for(i := 0; i < np; i++){
		img.line(Point(o.x + int(px[i] - real VECTOR*vx[i]),
			o.y + int(py[i] - real VECTOR*vy[i])),
			Point(o.x + int px[i], o.y + int py[i]),
			Draw->Endsquare, Draw->Endsquare, 0, ink[12], Point(0, 0));
		if(shownormals)
			img.line(Point(o.x + int px[i], o.y + int py[i]),
				Point(o.x + int(px[i] + real VECTOR*nx[i]),
					o.y + int(py[i] + real VECTOR*ny[i])),
				Draw->Endsquare, Draw->Endsquare, 0, ink[10],
				Point(0, 0));
	}

	if(font != nil){
		img.text(o, ink[15], Point(0, 0), font,
			sys->sprint("Scale:%d (%d,%d)-->(%d,%d)", SCALE, mw, mh, fw, fh));
		img.text(Point(o.x, o.y + font.height), ink[15], Point(0, 0), font,
			sys->sprint("PhotonCnt:%d MirrorCnt:%d SnellCnt:%d ZeroNormal:%d  live:%d",
				photoncnt, mirrorcnt, snellcnt, zeronormal, np));
		img.text(Point(o.x, img.r.max.y - 2*font.height), ink[14],
			Point(0, 0), font,
			sys->sprint("mode: %s", modenames[mode]));
		img.text(Point(o.x, img.r.max.y - font.height), ink[11],
			Point(0, 0), font,
			"0-5 mode, . ends a spline, r random burst, n normals, Enter clears, q exits");
	}
	img.flush(Draw->Flushnow);
}

absi(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}

rnreal(): real
{
	if(rand == nil)
		return real(sys->millisec() & 1023) / 1023.0;
	return real(rand->rand(1000000)) / 1000000.0;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
