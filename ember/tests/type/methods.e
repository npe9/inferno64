module Methods

import sys "sys"

type Rect struct {
	minx, miny, maxx, maxy int
}

func (r ref Rect) dx() int {
	return r.maxx - r.minx
}

func (r ref Rect) dy() int {
	return r.maxy - r.miny
}

func (r ref Rect) area() int {
	return r.dx() * r.dy()
}

func init() {
	var r ref Rect
	sys.print("area %d\n", r.area())
}
