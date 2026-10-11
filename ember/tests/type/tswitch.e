module Tswitchtest

// "match v := s.(type) { case ref T: ... }": a type switch, a chain
// of type assertions; v has the arm's type when it names one type,
// the interface's when it names several

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

type Tri struct {
	b, h int
}

func (r ref Rect) area() int {
	return r.w * r.h
}

func (c ref Circle) area() int {
	return 3 * c.r * c.r
}

func (t ref Tri) area() int {
	return t.b * t.h / 2
}

func kind(s Shape) string {
	match v := s.(type) {
	case ref Rect:
		return sys.sprint("rect %dx%d", v.w, v.h)
	case ref Circle:
		return sys.sprint("circle %d", v.r)
	default:
		return "unknown"
	}
}

func round(s Shape) int {
	match s.(type) {
	case ref Circle:
		return 1
	}
	return 0
}

func polygon(s Shape) string {
	match v := s.(type) {
	case ref Rect, ref Tri:
		return sys.sprint("polygon area %d", v.area())
	default:
		return "not a polygon"
	}
}

func first(shapes []Shape) Shape {
	return shapes[0]
}

func init(ctxt ref draw.Context, args list string) {
	shapes := []Shape{ref Rect{w: 2, h: 3}, ref Circle{r: 1}, ref Tri{b: 4, h: 5}}
	for _, s := range shapes {
		sys.print("%s / %d / %s\n", kind(s), round(s), polygon(s))
	}
	var none Shape
	sys.print("%s\n", kind(none))
	match f := first(shapes); v := f.(type) {
	case ref Rect:
		sys.print("first is a rect of area %d\n", v.area())
	default:
		sys.print("first is something else\n")
	}
	n := 0
	for _, s := range shapes {
		match s.(type) {
		case ref Tri:
			break
		default:
			n++
		}
	}
	sys.print("before the triangle: %d\n", n)
}
