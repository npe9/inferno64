module Badembed

import sys "sys"
import draw "draw"

type Reader interface {
	read() string
}

type RW interface {
	Reader
	Writer
}

func init(ctxt ref draw.Context, args list string) {
	var r RW
	sys.print("%d\n", r == nil)
}
