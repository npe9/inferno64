module Closurefield

import sys "sys"
import draw "draw"

// shared state for a closure: a captured variable is a copy, so a
// closure that must change something the outer code sees holds a ref
type Cell struct {
	v int
}

// a function type written for a variable, a struct field, a list
// element or a type argument is the same closure value a parameter's
// is, so closures and function values can be stored anywhere

type Counter struct {
	next func() int
	step func(int) int
}

type Box[T] struct {
	val T
}

func adder(k int) func(int) int {
	return func(x int) int { return x + k }
}

func counter() Counter {
	n := ref Cell{v: 0}
	return Counter{next: func() int { n.v++; return n.v }, step: adder(10)}
}

func twice(x int) int {
	return 2 * x
}

func init(ctxt ref draw.Context, argv list string) {
	f := func() int { return 1 }
	var g func() int
	g = f
	c := Counter{next: g, step: func(x int) int { return x + 1 }}
	sys.print("%d %d\n", c.next(), c.step(1))
	d := counter()
	sys.print("%d %d %d\n", d.next(), d.next(), d.step(5))
	var fs list func(int) int
	fs = twice :: adder(3) :: fs
	for l := fs; l != nil; l = tl(l) {
		h := hd(l)
		sys.print("%d ", h(4))
	}
	sys.print("\n")
	var b Box[func(int) int]
	b.val = twice
	sys.print("%d\n", b.val(21))
	var none func() int
	if none == nil {
		sys.print("nil closure\n")
	}
}
