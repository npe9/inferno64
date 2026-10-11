module Namederr

import sys "sys"
import draw "draw"

type Color int

type Box struct {
	n int
}

func (c Color) name() string {
	return "colour"
}

func (b Box) fine() int {
	return b.n
}

func init(ctxt ref draw.Context, args list string) {
	var c Color
	sys.print("%s %d %s\n", c.missing(), Box{n: 1}.fine(), c.name())
}
