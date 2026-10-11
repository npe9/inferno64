module Genericfn

import sys "sys"

func swap[A, B](a A, b B) (B, A) {
	return b, a
}

func identity[T](x T) T {
	return x
}

func init() {
	x, y := swap[int, string](1, "one")
	sys.print("x=%s y=%d\n", x, y)

	// same instantiation again: exercises the instantiation cache.
	p, q := swap[int, string](2, "two")
	sys.print("p=%s q=%d\n", p, q)

	// a *different* generic function, instantiated at two different
	// types: each instantiation must get its own compiled body, not
	// share (and corrupt) the template's.
	n := identity[int](42)
	sys.print("n=%d\n", n)

	s := identity[string]("hello")
	sys.print("s=%s\n", s)
}
