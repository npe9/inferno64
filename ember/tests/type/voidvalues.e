module Voidvalues

import sys "sys"

// a void (no return value) function or closure literal can now be used
// as a first-class value, same as one that returns something --
// check.c's synthfvwrap() and synthfunclit() previously refused this
// outright.  the wrapper every function value (or closure) calls
// through can't compile "return fn(...)" for a void fn (check.c's
// ordinary Oret case rejects any non-nil return expression inside a
// void function, same rule as real code); synthfvwrap() now builds
// "fn(...); return;" instead -- two statements -- exactly for a void
// fn, "return fn(...)" unchanged otherwise.  synthfunclit() itself
// never needed a body-shape fix at all: a closure literal's body is
// used as-is, not synthesized, so a bare "return;" or falling off the
// end of a void closure's body was always fine, the same as any other
// void function's own body -- its own restriction was copied from
// synthfvwrap()'s without actually being needed.

func noop(x int) {
	sys.print("noop x=%d\n", x)
}

func apply2(f func(int), x int) {
	f(x)
}

func init() {
	// a named void function taken as a value: assigned, reassigned,
	// called directly and called through a parameter.
	g := noop
	g(7)
	apply2(noop, 8)
	apply2(g, 9)

	// a void closure literal, capturing, called directly and through
	// a value-typed parameter -- by-value, so mutating "total" from
	// inside it is not visible to the caller.
	n := 100
	total := 0
	p := func(x int) {
		sys.print("p x=%d n=%d\n", x, n)
		total = total + x
	}
	p(1)
	apply2(p, 2)
	sys.print("total=%d\n", total)
}
