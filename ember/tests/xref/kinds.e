module Kinds

// the kinds of name "ember -X" reports: types with methods, typed
// constants, a module-level variable, arguments, locals, a binder
// from a pick case, and a member of an imported module

import sys "sys"
import draw "draw"

type Level int

const (
	Low Level = 0
	High Level = 1
)

type Point struct {
	x int
	y int
}

type Shape pick {
	Dot()
	Line(n int)
}

var origin Point

func (l Level) name() string {
	if l == Low {
		return "low"
	}
	return "high"
}

func dist(p Point) int {
	d := p.x - origin.x
	if d < 0 {
		d = -d
	}
	return d + p.y
}

func size(s ref Shape) int {
	match s {
	case Shape.Dot:
		return 0
	case Shape.Line(n):
		return n
	}
	return -1
}

func init(ctxt ref draw.Context, argv list string) {
	origin = Point{x: 1, y: 2}
	p := Point{x: 4, y: 6}
	sys.print("%s %d %d\n", High.name(), dist(p), size(ref Shape.Line{n: 3}))
}
