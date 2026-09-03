module Varargsvalue

import sys "sys"

// a varargs library function has one frame shape per call site, so
// it cannot be a value: a wrapper would have to forward any shape

func f() {
	p := sys.print
	p("x\n")
}
