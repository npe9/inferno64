module Cond

// c ? a : b, the conditional expression: lowest precedence, nested,
// with refs and nil, and next to the ? that propagates an error tag

import sys "sys"
import draw "draw"

type P struct {
	x int
}

func sign(n int) string {
	return n < 0 ? "neg" : n == 0 ? "zero" : "pos"
}

func init(ctxt ref draw.Context, args list string) {
	a := 3
	b := 7
	m := a > b ? a : b
	sys.print("%d %s %s %s\n", m, sign(-2), sign(0), sign(9))
	var p ref P
	q := ref P{x: 5}
	r := p != nil ? p : q
	sys.print("%d\n", r.x)
	n := a + (b > 5 ? 100 : 0) * 2
	sys.print("%d\n", n)
	s := a == 3 ? "three" : "other"
	sys.print("%s\n", s)
}
