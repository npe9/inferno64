module Closures

import sys "sys"

// phase 2 of the closure-lowering plan (doc/ember-repository-study.md):
// "func(params) ret { body }" as a value, lifted to a fresh top-level Dfn
// (check.c's synthfunclit()) with envfn()'s env-prepended calling
// convention -- the same one every function value already goes through
// (envfn(), synthfvwrap()).  env (the tfnptr's t2) is always nil here:
// zero captures only.  a reference to an *enclosing function's* own
// parameter or local is rejected (echk's Oname case, gated on
// curclosure) -- lambda-lifting a real env adt is a later phase.

const K = 7

func apply(f func(int) int, x int) int {
	return f(x)
}

func init() {
	// stored in a local, then called through it
	inc := func(x int) int {
		return x + 1
	}
	sys.print("a=%d\n", apply(inc, 10))
	sys.print("b=%d\n", inc(41))

	// reassigned to a different closure literal
	g := inc
	sys.print("c=%d\n", apply(g, 100))
	g = func(x int) int {
		return x * 2
	}
	sys.print("d=%d\n", apply(g, 100))

	// inline literal, no intermediate local, nested as a call argument
	// (this exact shape -- a function-value construction nested inside
	// another call's own argument list -- caught a real, pre-existing
	// bug in synthfvwrap()'s valty: never sizetype()'d, so idoffsets()
	// silently failed to advance past it and let a later temp alias a
	// still-live one; fixed alongside this phase, not introduced by it)
	sys.print("e=%d\n", apply(func(x int) int { return x * 3 }, 5))

	// nested closures, neither capturing anything from outside itself
	outer := func(x int) int {
		inner := func(y int) int {
			return y + 1
		}
		return inner(x) * 2
	}
	sys.print("f=%d\n", outer(4))

	// a module-level const: not a capture (Dconst, not Darg/Dlocal)
	kf := func(x int) int {
		return x + K
	}
	sys.print("g=%d\n", kf(1))
}
