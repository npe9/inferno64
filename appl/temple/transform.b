implement Transform;

# TempleOS Demo/Graphics/Transform.HC — the fourth row of the matrix.
#
# "This highlights the 4th dimension of the transformation matrix which
# is used for storing translations (shifts) in matricies so they can be
# combined with a matrix multiplication.  Scroll bar works.  The
# multiplication takes place in the Sprite3ZB routine."
#
#	UpdateDerivedCtrlSlider: arg1 = pi/2*s1/SLIDER_RANGE;
#	                         arg2 = 1.0*(s2-SLIDER_RANGE/2)/SLIDER_RANGE;
#	                         scale= 2.0*s3/SLIDER_RANGE;
#	DrawIt: horz_scroll.min=-scale*MAP_HEIGHT*Sin(arg1);
#	        horz_scroll.max= scale*MAP_WIDTH *Cos(arg1)-pix_width;
#	        vert_scroll.max= scale*(MAP_HEIGHT*Cos(arg1)
#	                               +MAP_WIDTH*Sin(arg1))-pix_height;
#	        Mat4x4RotZ(dc->r,arg1);  Mat4x4Scale(dc->r,scale);
#	        Mat4x4TranslationEqu(dc->r,-h,-v,0);
#	        Sprite3ZB(dc,tree_x[i],tree_y[i],0,tree,arg2);
#
# It is ScrollBars.HC's map of 2048 square with 256 trees, put under a
# matrix that three sliders drive: the first turns the whole map, the
# third scales it, and the second spins every tree about its own centre
# without touching the map matrix at all — because Sprite3ZB takes its
# own angle.
#
# The scroll range is the interesting arithmetic.  A map rotated by arg1
# and scaled needs a window from -scale*H*sin(arg1) across to
# scale*W*cos(arg1), because the corners move; the program recomputes
# that every frame from the slider rather than tracking a bounding box.
#
# The translation goes in the fourth column of the same matrix, which is
# the point being made: shifting is a multiplication like any other, so
# scroll, rotation and scale compose into one matrix that Sprite3ZB
# applies once per sprite.
#
# GAP: wm(1) has no scroll bars, so the port draws and drags its own, as
#      temple/scrollbars(1) does; and the original divides the trees
#      across cores through JobQue, which Dis execution serialises.

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

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;
include "grpalette.m";
	grpal: Grpalette;

Transform: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;
MAP_WIDTH: con 2048;
MAP_HEIGHT: con 2048;
TREES_NUM: con 256;
SLIDER_SPACING: con 20;
SLIDER_RANGE: con 30;
SLIDER_BORDER: con 2;
BAR: con 12;
FW: con 8;

win: ref Window;
font: ref Font;
d: ref Display;
white, black, brown, green, ltgreen, ltgray, dkgray: ref Image;
tree, treemask: ref Image;
rot: array of ref Image;	# tree pre-rotated, one per slider step
rotmask: array of ref Image;
tx, ty: array of int;
s1, s2, s3: int;
arg1, arg2, scale: real;
h, v: int;
cleft, ctop: int;
drag := 0;			# 0 none, 1 horz bar, 2 vert bar, 3 sliders

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	draw3d = load Draw3d Draw3d->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(draw3d != nil)
		draw3d->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS Transform", Wmclient->Appl);
	d = win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(grpal->value(Grpalette->WHITE));
	black = d.color(grpal->value(Grpalette->BLACK));
	brown = d.color(grpal->value(Grpalette->BROWN));
	green = d.color(grpal->value(Grpalette->GREEN));
	ltgreen = d.color(grpal->value(Grpalette->LTGREEN));
	ltgray = d.color(grpal->value(Grpalette->LTGRAY));
	dkgray = d.color(grpal->value(Grpalette->DKGRAY));
	tree = d.open("/icons/temple/transform_1.bit");
	treemask = d.open("/icons/temple/transform_1.mask");

	tx = array[TREES_NUM] of int;
	ty = array[TREES_NUM] of int;
	for(i := 0; i < TREES_NUM; i++){
		tx[i] = rn(MAP_WIDTH);
		ty[i] = rn(MAP_HEIGHT);
	}
	s1 = 0;
	s2 = SLIDER_RANGE/2;
	s3 = SLIDER_RANGE/2;

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			continue;
		case k {
		Keyboard->Left =>	h -= 32;
		Keyboard->Right =>	h += 32;
		Keyboard->Up =>		v -= 32;
		Keyboard->Down =>	v += 32;
		* =>			exit;
		}
		redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img == nil)
			continue;
		x := p.xy.x - img.r.min.x;
		y := p.xy.y - img.r.min.y;
		w := img.r.dx();
		ht := img.r.dy();
		if(p.buttons & 1){
			if(drag == 0){
				if(x >= cleft && x < cleft + SLIDER_SPACING*4+3 &&
				   y >= ctop && y < ctop + SLIDER_SPACING*2+SLIDER_RANGE)
					drag = 3;
				else if(y >= ht - BAR)
					drag = 1;
				else if(x >= w - BAR)
					drag = 2;
			}
			case drag {
			1 =>	h = x * hspan(w) / max(1, w - BAR);
			2 =>	v = y * vspan(ht) / max(1, ht - BAR);
			3 =>	slider(x, y);
			}
			redraw();
		}else
			drag = 0;
	}
}

# UpdateDerivedCtrlSlider
derive(w, ht: int)
{
	cleft = w/2 - (SLIDER_SPACING*4+3)/2;
	ctop = ht/2 - (SLIDER_SPACING*2+SLIDER_RANGE)/2;
	s1 = clamp(s1, 0, SLIDER_RANGE-1);
	s2 = clamp(s2, 0, SLIDER_RANGE-1);
	s3 = clamp(s3, 1, SLIDER_RANGE-1);
	arg1 = PI/2.0*real s1/real SLIDER_RANGE;
	arg2 = 1.0*real(s2 - SLIDER_RANGE/2)/real SLIDER_RANGE;
	scale = 2.0*real s3/real SLIDER_RANGE;
}

slider(x, y: int)
{
	third := (SLIDER_SPACING*4+3)/3;
	val := SLIDER_RANGE - 1 - (y - (ctop + SLIDER_SPACING));
	if(x < cleft + third)
		s1 = val;
	else if(x < cleft + 2*third)
		s2 = val;
	else
		s3 = val;
}

clamp(x, lo, hi: int): int
{
	if(x < lo)
		return lo;
	if(x > hi)
		return hi;
	return x;
}

max(a, b: int): int
{
	if(a > b)
		return a;
	return b;
}

hmin(): int
{
	return int(-scale*real MAP_HEIGHT*math->sin(arg1));
}

hspan(w: int): int
{
	return max(1, int(scale*real MAP_WIDTH*math->cos(arg1)) - w - hmin());
}

vspan(ht: int): int
{
	return max(1, int(scale*(real MAP_HEIGHT*math->cos(arg1)
		+ real MAP_WIDTH*math->sin(arg1))) - ht);
}

# the map matrix: RotZ(arg1), Scale(scale), translation (-h,-v)
xf(x, y: int): Point
{
	c := math->cos(arg1);
	s := math->sin(arg1);
	fx := real x;
	fy := real y;
	return Point(int(scale*(fx*c - fy*s)) - h - hmin(),
		int(scale*(fx*s + fy*c)) - v);
}

# Sprite3ZB's own angle, applied to the sprite and not to the map
rotated(step: int): (ref Image, ref Image)
{
	if(tree == nil)
		return (nil, nil);
	if(rot == nil){
		rot = array[SLIDER_RANGE] of ref Image;
		rotmask = array[SLIDER_RANGE] of ref Image;
	}
	if(rot[step] == nil){
		a := 1.0*real(step - SLIDER_RANGE/2)/real SLIDER_RANGE;
		(rot[step], rotmask[step]) = spin(a);
	}
	return (rot[step], rotmask[step]);
}

spin(a: real): (ref Image, ref Image)
{
	w := tree.r.dx();
	ht := tree.r.dy();
	n := w;
	if(ht > n)
		n = ht;
	n = n*3/2 + 2;
	im := d.newimage(Rect((0,0),(n,n)), tree.chans, 0, Draw->White);
	mk := d.newimage(Rect((0,0),(n,n)), Draw->GREY1, 0, 0);
	if(im == nil || mk == nil)
		return (tree, treemask);
	stride := (w + 7)/8;
	mb := array[stride*ht] of byte;
	pix := array[w*ht] of byte;
	if(treemask.readpixels(treemask.r, mb) <= 0 ||
	   tree.readpixels(tree.r, pix) <= 0)
		return (tree, treemask);
	ca := math->cos(a);
	sa := math->sin(a);
	cx := real(n/2);
	cy := real(n/2);
	ox := real(w)/2.0;
	oy := real(ht)/2.0;
	one := array[1] of byte;
	for(yy := 0; yy < ht; yy++)
		for(xx := 0; xx < w; xx++){
			if((int mb[yy*stride + xx/8] & (16r80 >> (xx&7))) == 0)
				continue;
			dx := real xx - ox;
			dy := real yy - oy;
			nx := int(cx + dx*ca - dy*sa);
			ny := int(cy + dx*sa + dy*ca);
			if(nx < 0 || nx >= n || ny < 0 || ny >= n)
				continue;
			one[0] = pix[yy*w + xx];
			im.writepixels(Rect((nx,ny),(nx+1,ny+1)), one);
			mk.draw(Rect((nx,ny),(nx+1,ny+1)), d.opaque, nil, Point(0,0));
		}
	return (im, mk);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	ht := img.r.dy();
	derive(w, ht);
	h = clamp(h, 0, hspan(w));
	v = clamp(v, 0, vspan(ht));
	img.draw(img.r, white, nil, Point(0, 0));

	(spr, msk) := rotated(s2);
	if(spr != nil)
		for(i := 0; i < TREES_NUM; i++){
			p := xf(tx[i], ty[i]);
			if(p.x < -80 || p.x > w+80 || p.y < -80 || p.y > ht+80)
				continue;
			img.draw(spr.r.addpt(Point(o.x+p.x-spr.r.dx()/2,
				o.y+p.y-spr.r.dy()/2)), spr, msk, spr.r.min);
		}

	# the map border, under the same matrix
	edge(img, o, 2, 2, MAP_WIDTH-3, 2);
	edge(img, o, 2, MAP_HEIGHT-3, MAP_WIDTH-3, MAP_HEIGHT-3);
	edge(img, o, 2, 2, 2, MAP_HEIGHT-3);
	edge(img, o, MAP_WIDTH-3, 2, MAP_WIDTH-3, MAP_HEIGHT-3);

	bars(img, o, w, ht);
	ctrl(img, o);
	if(font != nil)
		img.text(o, black, Point(0, 0), font,
			sys->sprint("rot %4.2f  spin %5.2f  scale %4.2f   arrows scroll, a key exits",
				arg1, arg2, scale));
	img.flush(Draw->Flushnow);
}

edge(img: ref Image, o: Point, x1, y1, x2, y2: int)
{
	a := xf(x1, y1);
	b := xf(x2, y2);
	img.line(Point(o.x+a.x, o.y+a.y), Point(o.x+b.x, o.y+b.y),
		Draw->Endsquare, Draw->Endsquare, 2, brown, Point(0, 0));
}

bars(img: ref Image, o: Point, w, ht: int)
{
	img.draw(Rect((o.x, o.y+ht-BAR), (o.x+w, o.y+ht)), ltgray, nil, Point(0,0));
	img.draw(Rect((o.x+w-BAR, o.y), (o.x+w, o.y+ht)), ltgray, nil, Point(0,0));
	hw := max(8, (w-BAR)*(w-BAR)/max(1, hspan(w)+w));
	hx := h*(w-BAR-hw)/hspan(w);
	img.draw(Rect((o.x+hx, o.y+ht-BAR), (o.x+hx+hw, o.y+ht)), dkgray, nil, Point(0,0));
	vh := max(8, (ht-BAR)*(ht-BAR)/max(1, vspan(ht)+ht));
	vy := v*(ht-BAR-vh)/vspan(ht);
	img.draw(Rect((o.x+w-BAR, o.y+vy), (o.x+w, o.y+vy+vh)), dkgray, nil, Point(0,0));
}

# DrawCtrlSlider, three tracks instead of two
ctrl(img: ref Image, o: Point)
{
	rect(img, o, cleft, ctop, SLIDER_SPACING*4+3,
		SLIDER_SPACING*2+SLIDER_RANGE, ltgreen);
	rect(img, o, cleft+SLIDER_BORDER, ctop+SLIDER_BORDER,
		SLIDER_SPACING*4+3-2*SLIDER_BORDER,
		SLIDER_SPACING*2+SLIDER_RANGE-2*SLIDER_BORDER, brown);
	vals := array[] of {s1, s2, s3};
	for(i := 0; i < 3; i++){
		tx1 := cleft + (i+1)*SLIDER_SPACING + i;
		img.line(Point(o.x+tx1, o.y+ctop+SLIDER_SPACING),
			Point(o.x+tx1, o.y+ctop+SLIDER_SPACING+SLIDER_RANGE-1),
			Draw->Endsquare, Draw->Endsquare, 0, black, Point(0, 0));
		if(font != nil)
			img.text(Point(o.x+tx1-FW/2,
				o.y+ctop+SLIDER_SPACING+SLIDER_RANGE+3), ltgreen,
				Point(0, 0), font,
				sys->sprint("%d", vals[i]*10/SLIDER_RANGE));
		hy := ctop + SLIDER_SPACING + SLIDER_RANGE - 1 - vals[i];
		rect(img, o, tx1-3, hy-2, 7, 5, ltgreen);
		rect(img, o, tx1-2, hy-1, 5, 3, green);
	}
}

rect(img: ref Image, o: Point, x, y, w, ht: int, col: ref Image)
{
	img.draw(Rect((o.x+x, o.y+y), (o.x+x+w, o.y+y+ht)), col, nil, Point(0, 0));
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}
