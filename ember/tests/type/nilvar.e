module Nilvar

import sys "sys"
import draw "draw"

// an uninitialized pointer-typed variable is nil even when nothing
// else in the module names nil: its zero store used to read the
// first global (the sys import) when the nil global had no slot

func grow(xs []int, v int) []int {
	ys := [len(xs) + 1]int
	for i := 0; i < len(xs); i++ {
		ys[i] = xs[i]
	}
	ys[len(xs)] = v
	return ys
}

func init(ctxt ref draw.Context, argv list string) {
	var xs []int
	sys.print("len %d nil %d\n", len(xs), xs == nil)
	for i := 0; i < 4; i++ {
		xs = grow(xs, i * i)
	}
	sys.print("%d %d\n", len(xs), xs[3])
	var l list string
	l = "a" :: l
	sys.print("%d %s\n", len(l), hd(l))
}
