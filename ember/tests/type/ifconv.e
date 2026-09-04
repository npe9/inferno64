module Ifconvtest

// "Shape(x)": an explicit conversion to an interface type, the same
// converter an assignment uses; and back down to a narrower one

import sys "sys"
import draw "draw"

type Shape interface {
	area() int
}

type Named interface {
	area() int
	name() string
}

type Rect struct {
	w, h int
}

func (r ref Rect) area() int {
	return r.w * r.h
}

func (r ref Rect) name() string {
	return "rect"
}

func describe(s Shape) string {
	return sys.sprint("area %d", s.area())
}

func init(ctxt ref draw.Context, args list string) {
	r := ref Rect{w: 2, h: 5}
	s := Shape(r)
	sys.print("%s\n", describe(s))
	n := Named(r)
	sys.print("%s %s\n", n.name(), describe(Shape(n)))
	sys.print("%d\n", Shape(n).(ref Rect) == r)
	shapes := []Shape{Shape(r), Shape(ref Rect{w: 1, h: 1})}
	sys.print("%d\n", shapes[0].area() + shapes[1].area())
}
