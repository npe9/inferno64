module Composeas

import sys "sys"

// a bare (non-ref) composite literal assigned into an *existing*
// lvalue ("p = Point{x: 1, y: 2}", p already declared) -- previously
// only supported at declaration time (":=", daschk's own special
// case), refused everywhere else as "composite literal ... used as a
// value not yet supported".  restricted to a bare Oname LHS, the same
// boundary daschk() already draws on ":="'s own LHS: an arbitrary
// lvalue (p.field = ..., arr[i] = ...) still isn't attempted.

type Point struct {
	x, y int
}

type Rect struct {
	min, max Point
}

var gp = Point{x: 100, y: 200}

func init() {
	p := Point{x: 1, y: 2}
	sys.print("a=%d,%d\n", p.x, p.y)

	p = Point{x: 3, y: 4}
	sys.print("b=%d,%d\n", p.x, p.y)

	p = Point{5, 6}
	sys.print("c=%d,%d\n", p.x, p.y)

	// reassigning a global works the same way
	gp = Point{x: 7, y: 8}
	sys.print("d=%d,%d\n", gp.x, gp.y)

	// a keyed literal that leaves a field unset must still read as
	// the zero value on reassignment, not silently keep whatever the
	// destination held before -- a fresh ":=" local's frame slot
	// reads as zero "for free" (IFRAME clears a new frame), but a
	// reassignment doesn't get that for free; found this one broken
	// on the first attempt (com.c's Oas case, see its own comment).
	p = Point{x: 9}
	p = Point{y: 5}
	sys.print("e=%d,%d\n", p.x, p.y)

	// nested struct fields, and the same unset-field zeroing, one
	// level deeper
	r := Rect{min: Point{x: 1, y: 2}, max: Point{x: 9, y: 8}}
	r = Rect{min: Point{x: 3, y: 4}}
	sys.print("f=%d,%d min max=%d,%d\n", r.min.x, r.min.y, r.max.x, r.max.y)
}
