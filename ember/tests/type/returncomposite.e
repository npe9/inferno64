module Returncomposite

import sys "sys"

type Point struct {
	x, y int
}

func (p Point) add(q Point) Point {
	return Point{x: p.x + q.x, y: p.y + q.y}
}

type Rect struct {
	min, max Point
}

func mkrect(a, b Point) ref Rect {
	return ref Rect{min: a, max: b}
}

func init() {
	p := Point{x: 2, y: 3}
	q := Point{x: 10, y: 20}
	sum := p.add(q)
	sys.print("sum=%d,%d\n", sum.x, sum.y)

	r := mkrect(p, q)
	sys.print("rect: min=%d,%d max=%d,%d\n", r.min.x, r.min.y, r.max.x, r.max.y)
}
