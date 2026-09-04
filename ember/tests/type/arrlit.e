module Arrlittest

// "[]T{v, v, ...}": an array literal sized by its elements

import sys "sys"
import draw "draw"

type Shape interface {
	area() int
}

type Rect struct {
	w, h int
}

func (r ref Rect) area() int {
	return r.w * r.h
}

func sum(a []int) int {
	t := 0
	for _, x := range a {
		t += x
	}
	return t
}

func init(ctxt ref draw.Context, args list string) {
	a := []int{1, 2, 3}
	sys.print("%d %d\n", len(a), sum(a))
	names := []string{
		"one",
		"two",
	}
	sys.print("%d %s\n", len(names), names[1])
	shapes := []Shape{ref Rect{w: 1, h: 2}, ref Rect{w: 3, h: 4}}
	total := 0
	for _, s := range shapes {
		total += s.area()
	}
	sys.print("%d %d\n", len(shapes), total)
	none := []int{}
	sys.print("%d %d\n", len(none), sum([]int{10, 20}))
	sized := [2]int{7, 8}
	sys.print("%d %d\n", len(sized), sized[1])
}
