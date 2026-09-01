module Calldot

import sys "sys"

// dot access directly on a bare function-call result ("mkpoint().x"),
// the pre-existing, more general gap surfaced (not fixed) while
// working on tupledot.e (4372d099): "ecom: unsupported adr base
// call" -- Oadr has no case for a Call base, since a call's own
// return value has no addressable frame slot of its own to take the
// address of until something materializes it first, the identical
// class of fix bs[0].a's own Oadr-over-Oindx case needed (7c7b85a6),
// just for a base kind that fix didn't cover.
//
// mechanism (com.c's new fixcallbase(), called alongside the existing
// fixdblind() right at the top of ecom()'s own Oind case, before the
// left->addable check that would otherwise route this into the
// general arithmetic Oadd path and crash on Oadr's own missing Ocall
// case): unlike fixdblind()'s own problem (an already-Radr/Rmadr
// base, a real pointer *value* just needing a temp to sit in) and
// unlike Oindx's own indxaddr() (a genuine runtime address computed
// via a real Dis instruction, since arrays are heap objects with
// portable element addresses), a call result is a VALUE with no
// address to compute at all -- Dis has no instruction to produce "the
// address of a frame slot" as a portable int (checked, not assumed:
// no candidate instruction exists). So the fix materializes the
// call's own VALUE (not an address) into a fresh, ordinary Dlocal
// temp -- the same Ocall codegen any "x := f()" already uses --
// substitutes a plain Oname naming that temp for the Oadr's own Ocall
// base, and re-sumark()s the whole chain: from there it's
// structurally identical to "p.field" on a plain local, which already
// composes purely statically with zero further runtime work.

type Point struct {
	x int
	y int
}

func mkpoint(a int, b int) Point {
	return Point{x: a, y: b}
}

func mkpair(a int, s string) (int, string) {
	return a, s
}

func init() {
	// the motivating case: a struct-returning function's own field,
	// read directly off the call, no intermediate variable.
	sys.print("x=%d y=%d\n", mkpoint(1, 2).x, mkpoint(1, 2).y)

	// a tuple-returning function's own component, the same shape --
	// tupledot.e's own dot-on-tuple fix plus this one compose.
	sys.print("t0=%d t1=%s\n", mkpair(9, "nine").t0, mkpair(9, "nine").t1)

	// used as a real subexpression, not just a bare print argument.
	sum := mkpoint(3, 4).x + mkpoint(3, 4).y
	sys.print("sum=%d\n", sum)

	// two independent calls with different arguments in the same
	// expression, proving each materializes its own, non-aliased temp.
	diff := mkpoint(10, 1).x - mkpoint(1, 10).y
	sys.print("diff=%d\n", diff)

	// a poisoned local right before more access, same methodology as
	// every other investigation this session.
	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
	sys.print("final x=%d\n", mkpoint(7, 8).x)
}
