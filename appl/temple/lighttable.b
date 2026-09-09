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
#	            grained point of contact, then sweep two arcs of radius
#	            bmp_norm_radius out from theta+pi+-pi/4, coarse to
#	            fine, for the two points where the surface crosses the
#	            circle; the normal is perpendicular to the chord
#	            between them, turned the way the photon is going.
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
# GAP: PhotonNew allocates without limit; this keeps a fixed array of
#      MAXPHOTONS and drops new photons once it is full.  Photons are
#      never destroyed in either, since they bounce off the border.

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
include "grpalette.m";
	grpal: Grpalette;

Lighttable: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;
BORDER: con 10;
WING: con 9;
VECTOR: con 20;
BABY_STEPS: con 4;
MAXPHOTONS: con 2048;
# The original asks how much memory to give the fine bitmap and defaults
# to sixteen megabytes, then derives everything else from it:
#	bmp_scale=Sqrt(bmp_mem/2*8*pix_height/pix_width)/pix_height;
#	find_normal_dist_sqr=2*Sqr(bmp_scale);
#	bmp_norm_radius=Min(10*bmp_scale,250);
# so at 640x480 the fine grid is about fifteen cells to the display pixel.
BMP_MEM: con 16*1024*1024;
INHIBIT_DIST_SQR: con 4.0;	# D3DistSqr(&p_normal_inhibit,&p)<4.0

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
bmpscale, normradius, normdistsqr: real;

px, py, vx, vy, nx, ny: array of real;
inhx, inhy: array of real;	# Photon.p_normal_inhibit
np := 0;
mode := LTM_REFLECT_LINE;
shownormals := 0;
dragx, dragy: int;
dragging := 0;
splinepts: list of Point;
photoncnt, mirrorcnt, snellcnt, normalinhibit, zeronormal: int;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
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
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	px = array[MAXPHOTONS] of real;
	py = array[MAXPHOTONS] of real;
	vx = array[MAXPHOTONS] of real;
	vy = array[MAXPHOTONS] of real;
	nx = array[MAXPHOTONS] of real;
	ny = array[MAXPHOTONS] of real;
	inhx = array[MAXPHOTONS] of real;
	inhy = array[MAXPHOTONS] of real;

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
	bmpscale = math->sqrt(real(BMP_MEM/2)*8.0*real mh/real mw)/real mh;
	normdistsqr = 2.0*bmpscale*bmpscale;
	normradius = 10.0*bmpscale;
	if(normradius > 250.0)
		normradius = 250.0;
	fw = int(bmpscale*real mw);
	fh = int(bmpscale*real mh);
	fstride = (fw + 7)/8;
	map = array[mw*mh] of { * => byte 0 };
	reflectb = array[fstride*fh] of { * => byte 0 };
	refractb = array[fstride*fh] of { * => byte 0 };
	np = 0;
	photoncnt = mirrorcnt = snellcnt = normalinhibit = zeronormal = 0;
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
	n = int(real n*bmpscale);
	if(n < 1)
		n = 1;
	b := reflectb;
	if(kind == 2)
		b = refractb;
	for(i := 0; i <= n; i++){
		t := real i/real n;
		fx := (real x1 + t*real(x2-x1))*bmpscale;
		fy := (real y1 + t*real(y2-y1))*bmpscale;
		for(dy := -1; dy <= 1; dy++)
			for(dx := -1; dx <= 1; dx++)
				bplot(b, int fx + dx, int fy + dy);
		cx := int(fx/bmpscale);
		cy := int(fy/bmpscale);
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
			# only the coarse map is filled.  "The coarse gets
			# flood-filled but the fine grained is only
			# outlines" is the first line of the original, and
			# it is load-bearing: filling the fine bitmap too
			# would leave the normal search with a solid
			# interior and no surface to find.
			map[y*mw + x] = byte 2;
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
	inhx[np] = 0.0; inhy[np] = 0.0;
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

# FindNormal: recover a normal from the bitmap alone.  Back the photon up
# one step and walk it forward at fine-bitmap resolution to get the point
# of contact, then sweep an arc of radius bmp_norm_radius from that point
# for the two places the surface crosses the circle; the normal is
# perpendicular to the chord between them, turned away from the photon.
#
# The two arcs matter more than they look.  Each starts 45 degrees off the
# *backward* direction and widens, one to each side, and between them they
# cover the whole circle — including the wedge either side of the way the
# photon is going, which is exactly where the crossings are at grazing
# incidence.  A search that skips that wedge finds nothing on a shallow
# hit and falls back to a normal along the ray, which reflects the photon
# straight back the way it came.
findnormal(b: array of byte, i: int)
{
	th := math->atan2(vy[i], vx[i]);
	inhx[i] = px[i];
	inhy[i] = py[i];

	# D3SubEqu(&tmpp->p,&tmpp->v), then forward while the fine bitmap
	# is still clear and we have not gone further than
	# find_normal_dist_sqr
	px[i] -= vx[i];
	py[i] -= vy[i];
	cx := px[i]*bmpscale;
	cy := py[i]*bmpscale;
	wx := cx;
	wy := cy;
	while(!bpeek(b, int wx, int wy) &&
	      (wx-cx)*(wx-cx) + (wy-cy)*(wy-cy) < normdistsqr){
		wx += vx[i];
		wy += vy[i];
	}
	cx = wx;
	cy = wy;
	px[i] = cx/bmpscale;
	py[i] = cy/bmpscale;

	(ok1, a1) := arcfind(b, cx, cy, th, -1.0);
	(ok2, a2) := arcfind(b, cx, cy, th, 1.0);
	p1x, p1y, p2x, p2y: real;
	if(ok1){
		p1x = cx + normradius*math->cos(a1);
		p1y = cy + normradius*math->sin(a1);
	}else{
		# The original falls back to D3Copy(&p1,&tmpp->p), which is
		# the photon in *display* coordinates where everything else
		# here is in fine ones.  Kept as written: with both arcs
		# covering the circle it is all but unreachable, and the
		# |p1-p2| test below catches the degenerate case anyway.
		p1x = px[i];
		p1y = py[i];
	}
	if(ok2){
		p2x = cx + normradius*math->cos(a2);
		p2y = cy + normradius*math->sin(a2);
	}else{
		p2x = px[i];
		p2y = py[i];
	}
	dx := p1x - p2x;
	dy := p1y - p2y;
	if(dx*dx + dy*dy < 0.01){
		nx[i] = math->cos(th);
		ny[i] = math->sin(th);
		zeronormal++;
		return;
	}
	# perpendicular to the chord, turned to point the way the photon is
	# going rather than back at it
	ex := dy;
	ey := -dx;
	if(ex*vx[i] + ey*vy[i] < 0.0){
		ex = -dy;
		ey = dx;
	}
	d := math->sqrt(ex*ex + ey*ey);
	nx[i] = ex/d;
	ny[i] = ey/d;
}

# One of the original's two arc searches.  side -1 sweeps out from
# theta+pi-pi/4 and side 1 from theta+pi+pi/4; each covers a quarter turn
# to either side first, then three quarters of a turn on its own side, and
# the whole thing repeats at a quarter of the step if nothing was hit.
arcfind(b: array of byte, cx, cy, th, side: real): (int, real)
{
	base := th + PI + side*PI/4.0;
	step := 1.0;
	while(step >= 0.01){
		inc := step*PI/normradius;
		phi := 0.0;
		while(phi <= PI/4.0){
			a := base + side*phi;
			if(bpeek(b, int(cx + normradius*math->cos(a)),
				int(cy + normradius*math->sin(a))))
				return (1, a);
			a = base - side*phi;
			if(bpeek(b, int(cx + normradius*math->cos(a)),
				int(cy + normradius*math->sin(a))))
				return (1, a);
			phi += inc;
		}
		while(phi <= 3.0*PI/4.0){
			a := base + side*phi;
			if(bpeek(b, int(cx + normradius*math->cos(a)),
				int(cy + normradius*math->sin(a))))
				return (1, a);
			phi += inc;
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

# n1 Sin(theta1) == n2 Sin(theta2), with 1.5 inside a lens.  theta1 comes
# from the dot product, and which side of the normal the refracted ray
# leaves on is decided by Wrap(theta-theta_n).
#
# GAP: the original computes ASin(n1 Sin(theta1)/n2) with no guard, so a
#      ray past the critical angle takes the arcsine of a number greater
#      than one.  Here it is clamped, which sends that ray out along the
#      surface; a physical model would reflect it instead.
snell(i, last, next: int)
{
	th := math->atan2(vy[i], vx[i]);
	n1 := 1.0;
	if(last == 2)
		n1 = 1.5;
	n2 := 1.0;
	if(next == 2)
		n2 = 1.5;
	findnormal(refractb, i);
	thn := math->atan2(ny[i], nx[i]);
	d := nx[i]*vx[i] + ny[i]*vy[i];
	if(d > 1.0)
		d = 1.0;
	if(d < -1.0)
		d = -1.0;
	t1 := math->acos(d);
	s2 := n1*math->sin(t1)/n2;
	if(s2 > 1.0)
		s2 = 1.0;
	if(s2 < -1.0)
		s2 = -1.0;
	t2 := math->asin(s2);
	a: real;
	if(wrap(th - thn) >= 0.0)
		a = thn + t2;
	else
		a = thn - t2;
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

# MPAnimateTask's inner loop.  A photon moves one unit per frame, taken in
# BABY_STEPS pieces so a boundary is not stepped over; it bounces off the
# BORDER walls rather than leaving, so the population only ever grows.
#
# p_normal_inhibit is the guard that keeps a photon from bending twice at
# the same place: FindNormal records where it was called, and any further
# crossing within two pixels of that point is counted and ignored.  It is
# cleared, by being set to (0,0), on any step that is neither inhibited
# nor a crossing — and (0,0) is outside the border, so a cleared inhibit
# never matches.
animate()
{
	for(i := 0; i < np; i++){
		for(s := 0; s < BABY_STEPS; s++){
			lastc := cell(px[i], py[i]);
			px[i] += vx[i]/real BABY_STEPS;
			py[i] += vy[i]/real BABY_STEPS;
			if(px[i] < real BORDER){
				px[i] = real(2*BORDER) - px[i];
				vx[i] = -vx[i];
			}
			if(px[i] >= real(mw-BORDER)){
				px[i] -= px[i] - real(mw-BORDER);
				vx[i] = -vx[i];
			}
			if(py[i] < real BORDER){
				py[i] = real(2*BORDER) - py[i];
				vy[i] = -vy[i];
			}
			if(py[i] >= real(mh-BORDER)){
				py[i] -= py[i] - real(mh-BORDER);
				vy[i] = -vy[i];
			}
			nextc := cell(px[i], py[i]);
			ddx := inhx[i] - px[i];
			ddy := inhy[i] - py[i];
			inhibit := ddx*ddx + ddy*ddy < INHIBIT_DIST_SQR;
			if(lastc != nextc){
				if((lastc == 0 && nextc == 2) ||
				   (lastc == 2 && nextc == 0)){
					if(inhibit)
						normalinhibit++;
					else
						snell(i, lastc, nextc);
				}else if(lastc == 0 && nextc == 1){
					if(inhibit)
						normalinhibit++;
					else
						mirror(i);
				}else if(!inhibit){
					inhx[i] = 0.0;
					inhy[i] = 0.0;
				}
			}else if(!inhibit){
				inhx[i] = 0.0;
				inhy[i] = 0.0;
			}
		}
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
			sys->sprint("Mem:0x%X %dMeg Scale:%.3f (%d,%d)-->(%d,%d)",
				fstride*fh*2, fstride*fh*2/1024/1024, bmpscale,
				mw, mh, fw, fh));
		img.text(Point(o.x, o.y + font.height), ink[15], Point(0, 0), font,
			sys->sprint("PhotonCnt:%d MirrorCnt:%d SnellCnt:%d SnellInhibit:%d ZeroNormal:%d",
				photoncnt, mirrorcnt, snellcnt, normalinhibit,
				zeronormal));
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
