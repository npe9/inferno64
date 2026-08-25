module Nestedcomposite

import sys "sys"

type Point struct {
	x, y int
}

type Rect struct {
	min, max Point
}

func (r ref Rect) dx() int {
	return r.max.x - r.min.x
}

func init() {
	// composite literal as a local's initializer (Odas / Ovardecl),
	// value-typed: no ref, no allocation, stores into the local's
	// own frame slot.
	p := Point{x: 3, y: 4}
	sys.print("p=%d,%d\n", p.x, p.y)

	var q Rect = Rect{min: Point{x: 1, y: 2}, max: Point{x: 5, y: 9}}
	sys.print("q: min=%d,%d max=%d,%d\n", q.min.x, q.min.y, q.max.x, q.max.y)

	// composite literal nested inside a ref allocation's own fields.
	r := ref Rect{min: Point{x: 1, y: 2}, max: Point{x: 5, y: 9}}
	sys.print("r: min=%d,%d max=%d,%d\n", r.min.x, r.min.y, r.max.x, r.max.y)
	sys.print("dx=%d\n", r.dx())

	// a partially-keyed nested literal still zero-fills what's unset.
	s := ref Rect{min: Point{x: 7}}
	sys.print("s: min=%d,%d max=%d,%d\n", s.min.x, s.min.y, s.max.x, s.max.y)
}
