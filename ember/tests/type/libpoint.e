module Libpoint

import rand "rand"

// the library half of tests/type/loadlib.e; no init(), never run
// directly.  see tests/type/libpoint.ei.

type Point struct {
	x int
	y int
}

type Shape pick {
	Circle(c Point, r int)
	Rect(min Point, max Point)
}

func (p ref Point) norm1r() int {
	return norm1(Point{x: p.x, y: p.y})
}

func (p Point) sum() int {
	return p.x + p.y
}

func area(s ref Shape) int {
	match s {
	case Shape.Circle(c, r):
		return 3 * r * r
	case Shape.Rect(a, b):
		return (b.x - a.x) * (b.y - a.y)
	}
	return -1
}

func unit() ref Shape {
	return ref Shape.Rect{min: Point{x: 0, y: 0}, max: Point{x: 1, y: 1}}
}

func add(a Point, b Point) Point {
	return Point{x: a.x + b.x, y: a.y + b.y}
}

func scale(p ref Point, k int) {
	p.x *= k
	p.y *= k
}

func norm1(p Point) int {
	n := p.x
	if n < 0 {
		n = -n
	}
	m := p.y
	if m < 0 {
		m = -m
	}
	return n + m
}

func origin() Point {
	return Point{x: 0, y: 0}
}

func name() string {
	return "libpoint"
}

func roll(r Rand, n int) int {
	r.init(3)
	return r.rand(n)
}

// an interface declared in the interface file: a value made here is
// asserted on the client side, one made there is asserted here, so
// the two compilations must agree on the type tag
type Sized interface {
	size() int
}

type Box struct {
	n int
}

func (b ref Box) size() int {
	return b.n
}

func mkbox(n int) Sized {
	return ref Box{n: n}
}

func boxsize(s Sized) int {
	if b := s.(ref Box); b != nil {
		return b.n
	}
	return -1
}

// a named type with methods, used and called on both sides
type Color int

func (c Color) label() string {
	if c == Color(0) {
		return "red"
	}
	return "other"
}

func mkcolor(n int) Color {
	return Color(n)
}
