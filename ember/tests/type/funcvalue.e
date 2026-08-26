module Funcvalue

import sys "sys"

// first-class function values: a bare function name used as a plain
// value (passed as an argument), and calling *through* a function-
// typed parameter rather than a literal name.  see com.c's new Oname/
// Dfn ecom() case and fpcall() for how a value is represented (a
// heap-allocated tfnptr, types.c) and called back through.
func inc(x int) int {
	return x + 1
}

func dec(x int) int {
	return x - 1
}

func apply(f func(int) int, x int) int {
	return f(x)
}

func init() {
	a := apply(inc, 10)
	sys.print("a=%d\n", a)

	b := apply(dec, 10)
	sys.print("b=%d\n", b)

	// a function value stored in a local, then called through it,
	// and re-assigned to a *different* function -- exercises both
	// "g := name" (ecom's Oname/Dfn case) and calling through an
	// ordinary local (not just a parameter).
	g := inc
	c := apply(g, 100)
	sys.print("c=%d\n", c)

	g = dec
	d := apply(g, 100)
	sys.print("d=%d\n", d)
}
