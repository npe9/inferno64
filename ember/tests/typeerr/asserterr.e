module Asserterr

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

func init(ctxt ref draw.Context, args list string) {
	r := ref Rect{w: 1, h: 2}
	x := r.(ref Rect)
	var s Shape
	n := s.(int)
	t := s.(Shape)
	sys.print("%d %d\n", n, x == nil || t == nil)
}
