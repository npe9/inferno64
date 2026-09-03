module Libpoint

import rand "rand"

// the library half of tests/type/loadlib.e; no init(), never run
// directly.  see tests/type/libpoint.ei.

type Point struct {
	x int
	y int
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
