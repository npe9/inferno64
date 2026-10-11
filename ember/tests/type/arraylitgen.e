module Arraylitgen

import sys "sys"

// an array composite literal inside a generic function, instantiated
// twice with distinct type arguments -- the exact shape dupntree()
// (ast.c) was found necessary through (identity[int]/identity[string]
// sharing AST nodes, last-instantiation-checked winning for both,
// ba9b000e's own history). dupntree() already clones n->aux
// generically for every node ("m->aux = dupntree(n->aux);"), so this
// is confirmation, not new plumbing -- verified by testing rather
// than assumed from reading dupntree() alone.

func mki[T]() []T {
	xs := [2]T{2, 3}
	return xs
}

func mks[T]() []T {
	xs := [2]T{"a", "b"}
	return xs
}

func init() {
	a := mki[int]()
	sys.print("a0=%d a1=%d\n", a[0], a[1])

	b := mks[string]()
	sys.print("b0=%s b1=%s\n", b[0], b[1])
}
