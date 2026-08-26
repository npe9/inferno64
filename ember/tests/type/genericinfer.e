module Genericinfer

import sys "sys"

func swap[A, B](a A, b B) (B, A) {
	return b, a
}

func identity[T](x T) T {
	return x
}

func addpair[T](a, b T) T {
	return a + b
}

func init() {
	// no explicit "[...]": type arguments inferred from the call's
	// own argument types.
	x, y := swap(1, "one")
	sys.print("x=%s y=%d\n", x, y)

	n := identity(42)
	sys.print("n=%d\n", n)

	s := identity("hello")
	sys.print("s=%s\n", s)

	// "a, b T": both names share one declared type -- inference must
	// bind T from either (here, both) corresponding argument.
	sum := addpair(3, 4)
	sys.print("sum=%d\n", sum)
}
