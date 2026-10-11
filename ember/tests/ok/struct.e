module Geometry

type Point struct {
	x, y int
}

type Rect struct {
	min, max Point
	name     string
}

func (p Point) add(q Point) Point {
	return Point{x: p.x + q.x, y: p.y + q.y}
}

func (r ref Rect) dx() int {
	return r.max.x - r.min.x
}

var origin = Point{x: 0, y: 0}

const scale = 3

func area(r ref Rect) int {
	return r.dx() * (r.max.y - r.min.y)
}

func mkrect(a, b Point) ref Rect {
	return ref Rect{min: a, max: b, name: "r"}
}
