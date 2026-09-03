module Usegen

import sys "sys"
import draw "draw"
import gen "libgen"

// generic functions from a library's interface: inferred and explicit
// instantiation, templates calling templates and plain functions

func init(ctxt ref draw.Context, argv list string) {
	xs := [4]int{1, 2, 3, 4}
	strs := gen.mapa(xs, func(x int) string { return sys.sprint("<%d>", x) })
	joined := gen.reduce(strs, "", func(a string, s string) string { return a + s })
	total := gen.reduce[int, int](xs, 0, func(a int, x int) int { return a + x })
	sys.print("%s %d\n", joined, total)
	odd := gen.filterl(1 :: 2 :: 3 :: 4 :: 5 :: nil, func(x int) int { return x % 2 })
	sys.print("%d %d\n", gen.count(odd), hd(odd))
	sys.print("%s\n", gen.describe(xs, "xs"))
}
