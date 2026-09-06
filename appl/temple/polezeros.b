implement Polezeros;

# TempleOS Demo/Graphics/PoleZeros.HC — a transfer function, coloured.
#
#	Complex zeros[2]={{10.0,0},{-30,0}};
#	Complex poles[2]={{-20.0,-15.0},{-20.0,15.0}};
#	F(x): CPoly(&num,ZEROS_NUM,zeros,x); CPoly(&denom,POLES_NUM,poles,x);
#	      CDiv(&n1,&num,&denom); R2P(&m,&a,n1.x,n1.y);
#	      if (ms.rb) return pi+a; else return m;
#	MPDraw: CEqu(&xx,x-cx,cy-y); yy=scale*F(&xx);
#	        dc->color=Clamp(yy,0,14); y_total+=Clamp(yy,-14,14); GrPlot;
#	Draw:   scale*=7*GR_WIDTH*GR_HEIGHT/y_total;
#	        if (Abs(y_total-old_y_total)<1.0*GR_WIDTH*GR_HEIGHT) break;
#
# Every pixel of the window is a point in the complex plane, and its
# colour is the magnitude of the rational function whose roots are the
# two zeros and whose poles are the two poles — the picture engineers
# draw as a pole-zero plot, except that here it is the actual surface
# rather than a diagram of it.  Holding the right button swaps magnitude
# for phase, which is the same surface's argument.
#
# The scale is not chosen: the program renders, sums what it drew,
# rescales by 7*W*H/total and renders again, stopping when the total
# stops moving.  That is an auto-exposure loop, and it is why the picture
# looks right for any arrangement of poles you drag them into.
#
# Dragging picks whichever pole or zero is nearest the cursor, by squared
# distance, and moves it; the surface is recomputed from scratch.

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

Polezeros: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;
ZEROS_NUM: con 2;
POLES_NUM: con 2;

win: ref Window;
font: ref Font;
ink: array of ref Image;
zx, zy: array of real;
px, py: array of real;
scale := 1.0;
phase := 0;			# ms.rb
dragging := -1;			# 0..1 pole, 2..3 zero
dirty := 1;

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
	win = wmclient->window(ctxt, "TempleOS PoleZeros", Wmclient->Appl);
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

	zx = array[] of {10.0, -30.0};
	zy = array[] of {0.0, 0.0};
	px = array[] of {-20.0, -20.0};
	py = array[] of {-15.0, 15.0};

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		dirty = 1;
		redraw();
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img == nil)
			continue;
		cx := img.r.dx()/2;
		cy := img.r.dy()/2;
		x := real(p.xy.x - img.r.min.x - cx);
		y := real(cy - (p.xy.y - img.r.min.y));
		rb := (p.buttons & 4) != 0;
		if(rb != (phase != 0)){
			phase = 0;
			if(rb)
				phase = 1;
			dirty = 1;
			redraw();
		}
		if(p.buttons & 1){
			if(dragging < 0)
				dragging = find(x, y);
			if(dragging >= 0 && dragging < POLES_NUM){
				px[dragging] = x;
				py[dragging] = y;
			}else if(dragging >= 0){
				zx[dragging-POLES_NUM] = x;
				zy[dragging-POLES_NUM] = y;
			}
			dirty = 1;
			redraw();
		}else
			dragging = -1;
	}
}

# PoleZeroFind: nearest by squared distance, poles first
find(x, y: real): int
{
	best := 1e30;
	res := -1;
	for(i := 0; i < POLES_NUM; i++){
		dd := (px[i]-x)*(px[i]-x) + (py[i]-y)*(py[i]-y);
		if(dd < best){
			best = dd;
			res = i;
		}
	}
	for(i = 0; i < ZEROS_NUM; i++){
		dd := (zx[i]-x)*(zx[i]-x) + (zy[i]-y)*(zy[i]-y);
		if(dd < best){
			best = dd;
			res = POLES_NUM + i;
		}
	}
	return res;
}

# F(x): the product over the zeros divided by the product over the poles,
# then to polar; the right button asks for the argument instead
f(x, y: real): real
{
	nr := 1.0;
	ni := 0.0;
	for(i := 0; i < ZEROS_NUM; i++){
		ar := x - zx[i];
		ai := y - zy[i];
		(nr, ni) = (nr*ar - ni*ai, nr*ai + ni*ar);
	}
	dr := 1.0;
	di := 0.0;
	for(i = 0; i < POLES_NUM; i++){
		ar := x - px[i];
		ai := y - py[i];
		(dr, di) = (dr*ar - di*ai, dr*ai + di*ar);
	}
	den := dr*dr + di*di;
	if(den == 0.0)
		den = 1e-12;
	qr := (nr*dr + ni*di)/den;
	qi := (ni*dr - nr*di)/den;
	if(phase)
		return PI + math->atan2(qi, qr);
	return math->sqrt(qr*qr + qi*qi);
}

clampr(v, lo, hi: real): real
{
	if(v < lo)
		return lo;
	if(v > hi)
		return hi;
	return v;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	cx := w/2;
	cy := h/2;

	if(dirty){
		# the auto-exposure loop: render, sum, rescale, render again
		scale = 1.0;
		oldtotal := 1e30;
		for(pass := 0; pass < 8; pass++){
			total := 0.0;
			for(y := 0; y < h; y += 2)
				for(x := 0; x < w; x += 2)
					total += clampr(scale*f(real(x-cx), real(cy-y)),
						-14.0, 14.0);
			if(total == 0.0)
				break;
			scale *= 7.0*real(w*h)/4.0/total;
			if(math->fabs(total-oldtotal) < 1.0*real(w*h)/4.0)
				break;
			oldtotal = total;
		}
		dirty = 0;
	}

	for(y := 0; y < h; y++){
		x := 0;
		while(x < w){
			c := int clampr(scale*f(real(x-cx), real(cy-y)), 0.0, 14.0);
			x2 := x + 1;
			while(x2 < w){
				c2 := int clampr(scale*f(real(x2-cx), real(cy-y)),
					0.0, 14.0);
				if(c2 != c)
					break;
				x2++;
			}
			img.draw(Rect((o.x+x, o.y+y), (o.x+x2, o.y+y+1)), ink[c],
				nil, Point(0, 0));
			x = x2;
		}
	}

	img.line(Point(o.x, o.y+cy), Point(o.x+w, o.y+cy), Draw->Endsquare,
		Draw->Endsquare, 0, ink[15], Point(0, 0));
	img.line(Point(o.x+cx, o.y), Point(o.x+cx, o.y+h), Draw->Endsquare,
		Draw->Endsquare, 0, ink[15], Point(0, 0));
	for(i := 0; i < ZEROS_NUM; i++)
		mark(img, o, cx + int zx[i], cy - int zy[i], 0);
	for(i = 0; i < POLES_NUM; i++)
		mark(img, o, cx + int px[i], cy - int py[i], 1);
	if(font != nil){
		what := "magnitude";
		if(phase)
			what = "phase";
		img.text(o, ink[15], Point(0, 0), font,
			sys->sprint("%s, scale %g.  drag a pole or zero; right button for phase; a key exits",
				what, scale));
	}
	img.flush(Draw->Flushnow);
}

# a zero is a circle, a pole a cross
mark(img: ref Image, o: Point, x, y, ispole: int)
{
	c := ink[15];
	if(ispole){
		img.line(Point(o.x+x-5, o.y+y-5), Point(o.x+x+5, o.y+y+5),
			Draw->Endsquare, Draw->Endsquare, 0, c, Point(0, 0));
		img.line(Point(o.x+x-5, o.y+y+5), Point(o.x+x+5, o.y+y-5),
			Draw->Endsquare, Draw->Endsquare, 0, c, Point(0, 0));
	}else
		img.ellipse(Point(o.x+x, o.y+y), 5, 5, 0, c, Point(0, 0));
}
