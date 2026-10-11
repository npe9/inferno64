module Compositevalue

import sys "sys"

// a struct literal in general value position: as a call argument
// (value and, through "ref", pointer parameters), as the base of a
// field access, as a nested value inside another literal's field,
// cons'd onto a list, and partial (zero-filled) in each of those.

type Point struct {
	x int
	y int
}

type Seg struct {
	a Point
	b Point
	name string
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

func seglen(s Seg) int {
	return norm1(Point{x: s.b.x - s.a.x, y: s.b.y - s.a.y})
}

func init() {
	// call argument, exhaustive and partial
	sys.print("n=%d\n", norm1(Point{x: 3, y: -4}))
	sys.print("partial=%d\n", norm1(Point{y: 5}))

	// field read straight off a literal
	sys.print("x=%d y=%d\n", Point{x: 8, y: 9}.x, Point{x: 8, y: 9}.y)

	// nested: a literal as another literal's field value, both
	// passed by value across two calls
	sys.print("len=%d\n", seglen(Seg{a: Point{x: 1, y: 1}, b: Point{x: 4, y: 5}, name: "s"}))

	// a literal cons'd onto a list, read back through hd
	l := Point{x: 6, y: 7} :: nil
	l = Point{x: 1, y: 2} :: l
	sys.print("hd=%d,%d next=%d,%d\n", hd(l).x, hd(l).y, hd(tl(l)).x, hd(tl(l)).y)

	// in a loop, so the same temp slots are reused: a partial literal
	// must read as zero every iteration, not the previous value
	for i := 0; i < 3; i++ {
		sys.print("i=%d n=%d\n", i, norm1(Point{x: i}))
	}

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
