module Valuefield

import sys "sys"

type Point struct {
	x, y int
}

type Rect struct {
	min, max Point
}

func (p Point) add(q Point) Point {
	var r Point
	r.x = p.x + q.x
	r.y = p.y + q.y
	return r
}

func (r ref Rect) dx() int {
	return r.max.x - r.min.x
}

func (r ref Rect) dy() int {
	return r.max.y - r.min.y
}

func init() {
	var p Point
	p.x = 3
	p.y = 4
	sys.print("p=%d,%d\n", p.x, p.y)

	// value receiver reading its own fields, and a value struct
	// returned by value.
	var q Point
	q.x = 1
	q.y = 2
	s := p.add(q)
	sys.print("s=%d,%d\n", s.x, s.y)

	// ref receiver whose own fields are themselves value structs
	// (r.max.x): a mixed ref-then-value chain, both write and read.
	r := ref Rect{}
	r.min.x = 1
	r.min.y = 2
	r.max.x = 5
	r.max.y = 9
	sys.print("min=%d,%d max=%d,%d dx=%d dy=%d\n",
		r.min.x, r.min.y, r.max.x, r.max.y, r.dx(), r.dy());
}
