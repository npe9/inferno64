module Composite

import sys "sys"

type Rect struct {
	minx, miny, maxx, maxy int
}

func (r ref Rect) area() int {
	return (r.maxx - r.minx) * (r.maxy - r.miny)
}

func init() {
	full := ref Rect{minx: 1, miny: 2, maxx: 5, maxy: 9}
	sys.print("full: %d %d %d %d area=%d\n",
		full.minx, full.miny, full.maxx, full.maxy, full.area());

	// unset fields of a keyed literal read as the zero value.
	partial := ref Rect{minx: 7, maxy: 3}
	sys.print("partial: %d %d %d %d\n",
		partial.minx, partial.miny, partial.maxx, partial.maxy);
}
