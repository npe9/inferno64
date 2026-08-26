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
	// level deeper.  case f's inner literal ("min: Point{x: 3, y: 4}")
	// is itself exhaustive but the *outer* Rect literal still omits
	// "max" -- exhaustiveness has to be decided per level, driven by
	// what the outer literal itself sets, not by whether a nested
	// literal that IS present happens to be complete.
	r := Rect{min: Point{x: 1, y: 2}, max: Point{x: 9, y: 8}}
	r = Rect{min: Point{x: 3, y: 4}}
	sys.print("f=%d,%d min max=%d,%d\n", r.min.x, r.min.y, r.max.x, r.max.y)

	// the same unset-field zeroing again, but on a ":=" that
	// re-executes inside a loop body: its frame slot is only zero
	// "for free" the very first time (IFRAME clears a whole frame
	// once, at the function's prologue, not per iteration) -- a
	// later iteration reusing the same slot must still read an unset
	// field as zero, not whatever the previous iteration's q.y = 42
	// left behind.  found broken this way before storecomposite()'s
	// own Odas call site learned to check compositexhaustive() too,
	// not just Oas's.
	for i := 0; i < 3; i++ {
		q := Point{x: i}
		sys.print("g%d=%d,%d\n", i, q.x, q.y)
		q.y = 42
	}
}
