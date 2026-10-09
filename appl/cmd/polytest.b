implement Polytest;

#
# Does a Limbo `array of Point' reach the polygon and spline drawing
# primitives intact?
#
# Image.poly, Image.bezspline, Image.fillpoly and Image.fillbezspline
# are the only draw(2) calls that take an ARRAY of points, and
# libinterp/draw.c passed that array to C by reinterpreting it:
#
#	/* sleazy: we know that Draw_Points have same shape as Points */
#	fillpolyop(d, (Point*)f->p->data, f->p->len, ...)
#
# They do not have the same shape here.  A Limbo int is a WORD, which is
# intptr on this build, so Draw_Point is 16 bytes against a C Point of
# two s32.  Three points stored as the words 2 7 13 3 13 10 arrive as
# (2,0) (7,0) (13,0): a triangle flattened onto one row.  Every Limbo
# polygon and spline in the tree was drawing the wrong shape.
#
# EVERY CASE HERE HAS AN ORACLE FROM A DIFFERENT PRIMITIVE, because
# "did it draw something" cannot tell a correct polygon from a wrong
# one -- the broken version drew plenty.  A rectangle expressed as a
# polygon must equal the same rectangle drawn by draw(), and a
# two-point poly must equal the same segment drawn by line() -- and
# line() takes its points as SCALARS, through IPOINT, which is the path
# that was already fixed.  So the oracle does not share the defect.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;

Polytest: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

W: con 40;
H: con 40;

ok, fail: int;
disp: ref Display;

report(good: int, what: string)
{
	if(good){
		ok++;
		sys->print("ok   %s\n", what);
	}else{
		fail++;
		sys->print("FAIL %s\n", what);
	}
}

fresh(): ref Image
{
	return disp.newimage(Rect((0,0),(W,H)), draw->RGB24, 0, Draw->White);
}

pixels(i: ref Image): array of byte
{
	b := array[W*H*3] of byte;
	if(i == nil || i.readpixels(i.r, b) != len b)
		return nil;
	return b;
}

differ(a, b: array of byte): int
{
	if(a == nil || b == nil || len a != len b)
		return -1;
	n := 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			n++;
	return n;
}

inked(a: array of byte): int
{
	if(a == nil)
		return -1;
	n := 0;
	for(i := 0; i < len a; i++)
		if(a[i] != byte 255)
			n++;
	return n;
}

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(draw == nil){
		sys->print("polytest: load Draw: %r\n");
		return;
	}
	if(ctxt != nil && ctxt.display != nil)
		disp = ctxt.display;
	else
		disp = Display.allocate(nil);
	if(disp == nil){
		sys->print("polytest: no Display: %r\n");
		return;
	}
	black := disp.color(Draw->Black);
	if(black == nil){
		sys->print("polytest: no colour\n");
		return;
	}

	# THE CONTROL FIRST: draw() of a rectangle must mark pixels at
	# all.  Without it every comparison below could pass by both
	# sides drawing nothing.
	a := fresh();
	a.draw(Rect((5,5),(15,15)), black, nil, (0,0));
	pa := pixels(a);
	report(inked(pa) == 10*10*3,
		sys->sprint("control: draw() of a 10x10 rect inks %d bytes (want %d)",
			inked(pa), 10*10*3));

	# fillpoly of the SAME rectangle, as four corners, must be the
	# same pixels.  This is the decisive case: with the array
	# reinterpreted the polygon collapses and this fails.
	b := fresh();
	sq := array[] of {Point(5,5), Point(15,5), Point(15,15), Point(5,15)};
	b.fillpoly(sq, ~0, black, sq[0]);
	pb := pixels(b);
	report(differ(pa, pb) == 0,
		sys->sprint("fillpoly of a rect == draw() of it (%d bytes differ)",
			differ(pa, pb)));

	# And the points must not have been consumed destructively: the
	# same array drawn twice must give the same picture.  A
	# conversion that wrote back into the Limbo array would pass
	# above and fail here.
	c := fresh();
	c.fillpoly(sq, ~0, black, sq[0]);
	report(differ(pb, pixels(c)) == 0,
		"the same point array draws the same twice");

	# A two-point poly is one segment, and line() draws that segment
	# from SCALAR points -- a different path through libinterp, and
	# the one that was already correct.  So this is an oracle that
	# does not share the defect.
	d := fresh();
	d.line((8,10), (30,25), Draw->Endsquare, Draw->Endsquare, 0, black, (0,0));
	pd := pixels(d);
	e := fresh();
	seg := array[] of {Point(8,10), Point(30,25)};
	e.poly(seg, Draw->Endsquare, Draw->Endsquare, 0, black, (0,0));
	pe := pixels(e);
	report(inked(pd) > 0 && differ(pd, pe) == 0,
		sys->sprint("poly of one segment == line() of it (%d bytes differ, %d inked)",
			differ(pd, pe), inked(pd)));

	#
	# TRANSLATION INVARIANCE for the shapes with no second primitive
	# to check them against: the same points moved by (dx,dy) must
	# draw the same picture moved by (dx,dy).
	#
	# This is the property to use and SYMMETRY WAS NOT.  Points
	# mirrored about a vertical axis do NOT have to produce a
	# mirrored picture -- a scanline fill includes one edge and
	# excludes the other, so it is asymmetric by a pixel per row by
	# design -- and three such checks failed against a correct
	# implementation before the exact oracles above said the
	# implementation was fine and the expectation was not.
	#
	# Translation has no such caveat, and it is exactly what a
	# garbled array cannot satisfy: reinterpreting the array mixes
	# one point's y into the next point's x, so shifting every point
	# by (5,0) moves some of the shape and not the rest.
	#
	tri := array[] of {Point(10,30), Point(20,10), Point(30,30)};
	report(translates(black, tri, 0, 5, 0),
		"a filled triangle moves when its points move, in x");
	report(translates(black, tri, 0, 0, 4),
		"a filled triangle moves when its points move, in y");
	report(translates(black, tri, 1, 5, 3),
		"a filled spline moves when its points move");

	open := array[] of {Point(8,28), Point(18,9), Point(31,27)};
	report(outlinetranslates(black, open, 6, 2),
		"an open polyline moves when its points move");

	# The triangle's area, because translation invariance is also
	# satisfied by a shape that is wrong in a position-independent
	# way.  Half of 20x20 is 200; the edge rule moves that by a few,
	# so this is a band tight enough that a one-row collapse (about
	# 20) and a filled bounding box (400) both fail.
	h := fresh();
	h.fillpoly(tri, ~0, black, tri[0]);
	np := inked(pixels(h))/3;
	report(np > 150 && np < 250,
		sys->sprint("and covers about half its box: %d pixels (want 150..250)", np));

	#
	# A nil point array, and an empty one.  Limbo passes nil as H,
	# which is ((void*)(-1)), so the conversion has to test the array
	# BEFORE reading a->data -- a version that takes the pointer at
	# the call site dereferences -1 instead.  Nothing should be drawn
	# and the process should still be here afterwards; if it faults
	# the run dies without printing a tally, which is the failure.
	#
	empt := array[0] of Point;
	n1 := fresh();
	n1.fillpoly(nil, ~0, black, (0,0));
	n1.poly(nil, Draw->Endsquare, Draw->Endsquare, 0, black, (0,0));
	n1.fillbezspline(nil, ~0, black, (0,0));
	n1.bezspline(nil, Draw->Endsquare, Draw->Endsquare, 0, black, (0,0));
	n1.fillpoly(empt, ~0, black, (0,0));
	n1.poly(empt, Draw->Endsquare, Draw->Endsquare, 0, black, (0,0));
	report(inked(pixels(n1)) == 0,
		sys->sprint("nil and empty point arrays draw nothing, and do not fault (%d bytes of ink)",
			inked(pixels(n1))));

	sys->print("POLYTEST %d ok, %d fail\n", ok, fail);
}

shift(p: array of Point, dx, dy: int): array of Point
{
	q := array[len p] of Point;
	for(i := 0; i < len p; i++)
		q[i] = (p[i].x + dx, p[i].y + dy);
	return q;
}

#
# Draw a filled shape, draw it again with every point moved, and check
# the second picture is the first one moved.  smooth picks fillbezspline
# over fillpoly.
#
translates(col: ref Image, p: array of Point, smooth, dx, dy: int): int
{
	a := fresh();
	b := fresh();
	q := shift(p, dx, dy);
	if(smooth){
		a.fillbezspline(p, ~0, col, p[0]);
		b.fillbezspline(q, ~0, col, q[0]);
	}else{
		a.fillpoly(p, ~0, col, p[0]);
		b.fillpoly(q, ~0, col, q[0]);
	}
	pa := pixels(a);
	pb := pixels(b);
	if(pa == nil || pb == nil || inked(pa) <= 0)
		return 0;
	return sameshifted(pa, pb, dx, dy);
}

outlinetranslates(col: ref Image, p: array of Point, dx, dy: int): int
{
	a := fresh();
	b := fresh();
	q := shift(p, dx, dy);
	a.poly(p, Draw->Endsquare, Draw->Endsquare, 0, col, (0,0));
	b.poly(q, Draw->Endsquare, Draw->Endsquare, 0, col, (0,0));
	pa := pixels(a);
	pb := pixels(b);
	if(pa == nil || pb == nil || inked(pa) <= 0)
		return 0;
	return sameshifted(pa, pb, dx, dy);
}

# Is b the picture a, moved by (dx,dy)?  Only the overlap is compared,
# since the shift walks part of a off the edge.
sameshifted(a, b: array of byte, dx, dy: int): int
{
	for(y := 0; y + dy < H; y++){
		for(x := 0; x + dx < W; x++){
			o := (y*W + x)*3;
			n := ((y+dy)*W + x+dx)*3;
			if(a[o] != b[n] || a[o+1] != b[n+1] || a[o+2] != b[n+2])
				return 0;
		}
	}
	return 1;
}
