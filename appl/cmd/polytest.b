implement Polytest;

#
# polytest - does draw(2) draw the polygon it was GIVEN?
#
#	polytest
#
# HOST OR BOARD, no screen needed: every image here is offscreen, so
# this runs under emu-cpu as well as the Cocoa build.
#
# WHAT IT GUARDS.  libinterp/draw.c handed a Limbo `array of Point'
# straight to C:
#
#	/* sleazy: we know that Draw_Points have same shape as Points */
#	fillpolyop(d, (Point*)f->p->data, f->p->len, ...)
#
# They do not have the same shape.  A Limbo int is a WORD, which is
# intptr, so libinterp/w8/runt.h says Draw_Point_size 16; the C Point in
# include/draw.h is two s32, which is 8.  Three points stored as the
# words 2 7 13 3 13 10 therefore arrive as (2,0) (7,0) (13,0) -- a
# triangle flattened onto one row.  Every polygon and spline in the tree
# went through one of four such casts: poly, bezspline, fillpoly,
# fillbezspline.
#
# The tree already knew.  include/draw.h has the reinterpreting macros
# COMMENTED OUT and replaced with field-by-field conversions --
# IPOINT(p) is ((Point){(s32)((p).x),(s32)((p).y)}) -- so somebody fixed
# the scalar path and left the four array casts behind, with the comment
# that justified them still attached.  Found by a peer session; the same
# four casts were fixed independently in another tree a week earlier.
#
# WHY THERE WAS NO TEST, which is how a defect reaching every polygon in
# the tree survived: nothing ever compared a drawn shape against an
# oracle.  So that is what this does, and the rule it follows is the
# transferable part --
#
#	EVERY ORACLE COMES FROM A DIFFERENT PRIMITIVE.
#
# fillpoly of a rectangle is checked against draw() of that rectangle;
# poly of one segment against line() of it.  line() takes its points as
# SCALARS, through the path that was already correct, so the oracle
# cannot share the defect.  A test that drew a polygon and compared it
# with another polygon would have passed throughout.
#
# AND SYMMETRY IS THE WRONG PROPERTY, which cost the peer three false
# failures against a CORRECT implementation: a scanline fill includes
# one edge and excludes the other, so a mirrored point list legitimately
# draws a picture that is not a mirror image, by about a pixel a row.
# TRANSLATION invariance is the property that holds -- and a garbled
# array cannot satisfy it, because the garbling is not a translation.
#
# Exit: 0 all checks passed, 2 a check failed, 1 could not look.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Chans: import draw;

Polytest: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

nok := 0;
nfail := 0;

ck(name: string, ok: int, detail: string)
{
	if(ok){
		nok++;
		sys->print("polytest: PASS %s%s\n", name, detail);
	}else{
		nfail++;
		sys->print("polytest: FAIL %s%s\n", name, detail);
	}
}

#
# GREY8 so that one pixel is one byte: a readback is then directly
# comparable and countable without knowing a pixel format.
#
W: con 64;
H: con 48;

disp: ref Display;
ink: ref Image;

newgrey(): ref Image
{
	r: Rect;
	r.min = (0, 0);
	r.max = (W, H);
	return disp.newimage(r, draw->GREY8, 0, draw->Black);
}

pix(im: ref Image): array of byte
{
	r: Rect;
	r.min = (0, 0);
	r.max = (W, H);
	d := array[W*H] of byte;
	n := im.readpixels(r, d);
	if(n != len d){
		sys->print("polytest: readpixels gave %d of %d bytes\n", n, len d);
		return nil;
	}
	return d;
}

inked(d: array of byte): int
{
	n := 0;
	for(i := 0; i < len d; i++)
		if(d[i] != byte 0)
			n++;
	return n;
}

same(a, b: array of byte): int
{
	if(a == nil || b == nil || len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(draw == nil){
		sys->print("polytest: cannot load $Draw: %r\n");
		raise "fail:no draw";
	}

	#
	# A private namespace with just the draw device in it, so this does
	# not depend on what the caller had mounted.
	#
	sys->pctl(Sys->FORKNS, nil);
	if(sys->bind("#i", "/dev", Sys->MAFTER) < 0){
		sys->print("polytest: bind #i /dev: %r\n");
		raise "fail:no draw device";
	}
	disp = Display.allocate(nil);
	if(disp == nil){
		sys->print("polytest: Display.allocate: %r\n");
		raise "fail:no display";
	}

	r1: Rect;
	r1.min = (0, 0);
	r1.max = (1, 1);
	ink = disp.newimage(r1, draw->GREY8, 1, draw->White);
	if(ink == nil){
		sys->print("polytest: cannot make an ink image: %r\n");
		raise "fail:no ink";
	}

	rectcheck();
	linecheck();
	trianglecheck();
	splinecheck();

	sys->print("polytest: %d ok, %d fail\n", nok, nfail);
	if(nfail != 0){
		sys->print("polytest: a drawn shape did not match its oracle\n");
		raise "fail:polygon mismatch";
	}
	sys->print("polytest: all checks passed\n");
}

#
# 1.  fillpoly of a rectangle, against draw() of that rectangle.
#
# The oracle is draw(), which takes a Rect through the scalar
# conversion path.  Note the point list is CLOSED (five points, last ==
# first): Plan 9's fillpoly closes an open list itself, but saying so
# here removes one assumption from the comparison.
#
rectcheck()
{
	a := newgrey();
	b := newgrey();
	if(a == nil || b == nil){
		ck("rectangle", 0, ": could not allocate images");
		return;
	}

	x0 := 10; y0 := 8; x1 := 40; y1 := 30;

	p := array[5] of Point;
	p[0] = (x0, y0);
	p[1] = (x1, y0);
	p[2] = (x1, y1);
	p[3] = (x0, y1);
	p[4] = (x0, y0);
	a.fillpoly(p, ~0, ink, (0, 0));

	rr: Rect;
	rr.min = (x0, y0);
	rr.max = (x1, y1);
	b.draw(rr, ink, nil, (0, 0));

	pa := pix(a);
	pb := pix(b);
	na := inked(pa);
	nb := inked(pb);
	ck("fillpoly rectangle == draw rectangle", same(pa, pb),
		sys->sprint(": fillpoly %d pixels, draw %d", na, nb));
	#
	# ...and the shape must not be empty, or two blank images would
	# agree.  This is the check the garbled array fails outright.
	#
	ck("fillpoly rectangle is not empty", nb > 0 && na == nb,
		sys->sprint(": %d of an expected %d pixels", na, nb));
}

#
# 2.  poly of a single segment, against line() of that segment.
#
# line() is the oracle because it takes p0 and p1 as scalar Points, so
# it never touches the array path under test.
#
linecheck()
{
	a := newgrey();
	b := newgrey();
	if(a == nil || b == nil){
		ck("segment", 0, ": could not allocate images");
		return;
	}

	q0 := (6, 6);
	q1 := (50, 40);

	p := array[2] of Point;
	p[0] = q0;
	p[1] = q1;
	a.poly(p, draw->Endsquare, draw->Endsquare, 0, ink, (0, 0));
	b.line(q0, q1, draw->Endsquare, draw->Endsquare, 0, ink, (0, 0));

	pa := pix(a);
	pb := pix(b);
	ck("poly one segment == line", same(pa, pb),
		sys->sprint(": poly %d pixels, line %d", inked(pa), inked(pb)));
	ck("the segment is not empty", inked(pb) > 0,
		sys->sprint(": %d pixels", inked(pb)));
}

#
# 3.  A triangle: not empty, and TRANSLATION INVARIANT.
#
# There is no other primitive that draws a triangle, so the oracle here
# is a property rather than a second implementation.  Translation is the
# right property and mirroring is not: a scanline fill includes one edge
# and excludes the other, so a mirrored list draws a legitimately
# non-mirrored picture.  Garbling y to zero is not a translation, so a
# flattened triangle cannot pass this however it is placed.
#
trianglecheck()
{
	dx := 7;
	dy := 5;

	a := newgrey();
	b := newgrey();
	if(a == nil || b == nil){
		ck("triangle", 0, ": could not allocate images");
		return;
	}

	t := array[3] of Point;
	t[0] = (2, 7);
	t[1] = (13, 3);
	t[2] = (13, 10);
	a.fillpoly(t, ~0, ink, (0, 0));

	u := array[3] of Point;
	for(i := 0; i < 3; i++)
		u[i] = (t[i].x + dx, t[i].y + dy);
	b.fillpoly(u, ~0, ink, (0, 0));

	pa := pix(a);
	pb := pix(b);
	na := inked(pa);
	nb := inked(pb);

	#
	# THE DIRECT CATCH.  The words of this triangle are 2 7 13 3 13 10,
	# which reinterpreted as 8-byte pairs are (2,0) (7,0) (13,0): three
	# points on one row, enclosing nothing.  The defect makes this zero.
	#
	ck("a triangle covers some pixels", na > 0,
		sys->sprint(": %d pixels", na));
	#
	# na > 0 IS PART OF THE CHECK, not a separate one.  Without it this
	# reported PASS as "0 here, 0 moved" against the broken cast -- two
	# empty images agreeing, which is the silent pass this tree keeps
	# finding in its own instruments.
	#
	ck("the same triangle covers the same count when moved", na > 0 && na == nb,
		sys->sprint(": %d here, %d moved by (%d,%d)", na, nb, dx, dy));

	#
	# and the moved picture must be the first one SHIFTED, pixel for
	# pixel, not merely the same size.
	#
	shifted := 1;
	for(y := 0; y < H && shifted; y++){
		for(x := 0; x < W; x++){
			y2 := y + dy;
			x2 := x + dx;
			if(x2 >= W || y2 >= H){
				if(pa[y*W + x] != byte 0)
					shifted = 0;	# moved out of the image
				continue;
			}
			if(pa[y*W + x] != pb[y2*W + x2]){
				shifted = 0;
				break;
			}
		}
	}
	ck("the moved triangle is the first one translated", na > 0 && shifted,
		sys->sprint(": %d pixels compared", na));

	#
	# 3b.  y MUST MATTER.  The flattened list is exactly what the cast
	# produced, so drawing it deliberately and requiring a different
	# picture states the defect as a property rather than a story.
	#
	c := newgrey();
	if(c != nil){
		flat := array[3] of Point;
		flat[0] = (2, 0);
		flat[1] = (7, 0);
		flat[2] = (13, 0);
		c.fillpoly(flat, ~0, ink, (0, 0));
		pc := pix(c);
		#
		# ...and the triangle must be non-empty for "differs" to mean
		# anything: 0 pixels differs from 0 pixels only because the
		# arrays compare equal, which it did report as a PASS.
		#
		ck("the triangle differs from its flattened form",
			na > 0 && !same(pa, pc),
			sys->sprint(": triangle %d pixels, flattened %d",
				na, inked(pc)));
	}
}

#
# 4.  fillbezspline and bezspline, which are the other two casts.
#
# A spline has no oracle from another primitive either, so these get the
# same treatment: a closed spline must enclose something, and moving its
# control points must move the picture.  Without this, two of the four
# casts would be unguarded -- and the peer's report is that the last two
# render fixtures to disagree were the only ones containing a polygon
# and a spline.
#
splinecheck()
{
	dx := 9;
	dy := 4;

	a := newgrey();
	b := newgrey();
	if(a == nil || b == nil){
		ck("spline", 0, ": could not allocate images");
		return;
	}

	#
	# bezspline wants 3n+1 control points; four give one segment, and a
	# closed figure needs the ends to meet.
	#
	c := array[7] of Point;
	c[0] = (10, 10);
	c[1] = (30, 4);
	c[2] = (45, 16);
	c[3] = (40, 34);
	c[4] = (34, 44);
	c[5] = (14, 40);
	c[6] = (10, 10);
	a.fillbezspline(c, ~0, ink, (0, 0));

	d := array[7] of Point;
	for(i := 0; i < 7; i++)
		d[i] = (c[i].x + dx, c[i].y + dy);
	b.fillbezspline(d, ~0, ink, (0, 0));

	pa := pix(a);
	pb := pix(b);
	na := inked(pa);
	nb := inked(pb);
	ck("a filled spline covers some pixels", na > 0,
		sys->sprint(": %d pixels", na));
	ck("the same spline covers the same count when moved", na > 0 && na == nb,
		sys->sprint(": %d here, %d moved", na, nb));

	#
	# and the outline form, which is the fourth cast.
	#
	e := newgrey();
	if(e != nil){
		e.bezspline(c, draw->Endsquare, draw->Endsquare, 0, ink, (0, 0));
		pe := pix(e);
		ck("an outlined spline covers some pixels", inked(pe) > 0,
			sys->sprint(": %d pixels", inked(pe)));
	}
}
