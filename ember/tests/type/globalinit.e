module Globalinit

import sys "sys"

type Point struct {
	x, y int
}

func five() int {
	return 5
}

// a non-constant module-level initializer: disw.c's disdatum() can
// only encode a literal into the data section, so this needs real
// code, emitted into entrydecl's (init's) prologue.
var x = five() + 1

// a composite literal as a module-level initializer -- also not a
// compile-time constant by disdatum()'s reckoning.
var origin = Point{x: 0, y: 0}

func init() {
	sys.print("x=%d origin=%d,%d\n", x, origin.x, origin.y)
}
