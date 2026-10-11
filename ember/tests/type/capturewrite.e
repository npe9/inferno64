module Capturewrite

// a closure captures an enclosing variable by reference: both sides
// see each other's writes (once this was refused as a copy)

import sys "sys"
import draw "draw"

func f() int {
	n := 0
	total := 0
	inc := func() {
		n++
		total = total + 1
	}
	inc()
	inc()
	return n + total
}

func g(k int) func() int {
	return func() int {
		k += 1
		return k
	}
}

func init(ctxt ref draw.Context, args list string) {
	sys.print("%d\n", f())
	next := g(10)
	sys.print("%d %d %d\n", next(), next(), next())
}
