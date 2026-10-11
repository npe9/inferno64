module Useiface

// an interface from an interface file, satisfied by a local struct

import sys "sys"
import draw "draw"
import shapelib "shapelib"

type Box struct {
	w int
	h int
}

func (b ref Box) area() int {
	return b.w * b.h
}

func init(ctxt ref draw.Context, args list string) {
	var s shapelib.Shape
	s = ref Box{w: 2, h: 3}
	sys.print("%d\n", s.area())
	boxes := [2]shapelib.Shape{ref Box{w: 1, h: 1}, ref Box{w: 4, h: 5}}
	sys.print("%d\n", shapelib.total(boxes))
}
