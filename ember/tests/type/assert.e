module Asserttest

// x.(T): a type assertion on an interface value, T's value or nil;
// v, ok := x.(T) says whether it held one

import sys "sys"
import draw "draw"

type Shape interface {
	area() int
}

type Rect struct {
	w, h int
}

type Circle struct {
	r int
}

func (r ref Rect) area() int {
	return r.w * r.h
}

func (c ref Circle) area() int {
	return 3 * c.r * c.r
}

func describe(s Shape) string {
	if r := s.(ref Rect); r != nil {
		return sys.sprint("rect %dx%d area %d", r.w, r.h, s.area())
	}
	if c, ok := s.(ref Circle); ok {
		return sys.sprint("circle r=%d area %d", c.r, c.area())
	}
	return "unknown"
}

func init(ctxt ref draw.Context, args list string) {
	var s Shape
	s = ref Rect{w: 3, h: 4}
	sys.print("%s\n", describe(s))
	s = ref Circle{r: 2}
	sys.print("%s\n", describe(s))
	c, ok := s.(ref Circle)
	sys.print("ok %d r %d\n", ok, c.r)
	r, ok2 := s.(ref Rect)
	sys.print("ok %d nil %d\n", ok2, r == nil)
	var none Shape
	sys.print("none: %d %d\n", none.(ref Rect) == nil, none.(ref Circle) == nil)
	shapes := [3]Shape
	shapes[0] = ref Rect{w: 1, h: 1}
	shapes[1] = ref Circle{r: 1}
	shapes[2] = ref Rect{w: 2, h: 5}
	total := 0
	for _, sh := range shapes {
		if rr := sh.(ref Rect); rr != nil {
			total += rr.w * rr.h
		}
	}
	sys.print("rect area %d\n", total)
}
