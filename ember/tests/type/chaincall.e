module Chaincall

import sys "sys"

// "f()()" -- calling the result of a call directly, no intermediate
// variable.  used to hard-fail at typecheck ("cannot call this
// expression"): Ocall's own callee-shape switch only accepted
// Oname/Odot/Omdot, and a nested Ocall wasn't one of them, even though
// the general "call through a function value" mechanism just below
// that switch (echk(n->left) then wrap in Oind when the result is
// Tref{Tfn}) already handles *any* callee shape it's given -- Ocall
// just needed adding to the list of shapes allowed to reach it.

func mk() func() int {
	return func() int { return 5 }
}

func mkchain() func() func() int {
	return func() func() int {
		return func() int { return 42 }
	}
}

func mkadd(n int) func(int) int {
	return func(x int) int { return x + n }
}

var ncalls int

func mkcounted() func(int) int {
	ncalls++
	return func(x int) int { return x * 2 }
}

func mkid[T](x T) func() T {
	return func() T { return x }
}

func init() {
	sys.print("a=%d\n", mk()())

	// double chaining: the result of the first call is itself called,
	// and *that* result is called again.
	sys.print("b=%d\n", mkchain()()())

	// chained call with an argument.
	sys.print("c=%d\n", mkadd(10)(5))

	// the inner call must be evaluated exactly once, not once per use
	// of its result -- ncalls proves it, not just the arithmetic.
	sys.print("d=%d\n", mkcounted()(21))
	sys.print("e=%d\n", ncalls)

	// a chained call nested inside a larger expression, evaluated
	// twice -- ncalls proves each mkcounted() call happens once.
	sys.print("f=%d\n", mkcounted()(1) + mkcounted()(2))
	sys.print("g=%d\n", ncalls)

	// through generic-call inference too, both bare and explicit.
	sys.print("h=%d\n", mkid(9)())
	sys.print("i=%s\n", mkid[string]("hey")())
}
