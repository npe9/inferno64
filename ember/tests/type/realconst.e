module Realconst

import sys "sys"

// a bare real literal ("x := 3.5") had no ecom() codegen case at all
// -- confirmed pre-existing, unrelated to anything else touched this
// session (a minimal "x := 3.5" outside any function-value/varargs
// context fails identically). sumark()'s Oconst switch handled Tint
// and Tstring but had no Treal case, falling to the generic default
// fatal ("sumark: const %T"). globalrconst() (com.c) mirrors
// globaliconst()'s own large-int-constant mechanism exactly -- a
// real literal can never fit Dis's own word-sized immediate operand
// (no "real immediate" addressing mode exists), so it always needs a
// real data-segment slot, keyed by value ("%.17g", enough digits to
// round-trip any IEEE double exactly) so two literals with the same
// value share one global. disw.c's disdatum() already had a Treal
// case -- ported alongside every other primitive type's global-
// initializer support in some earlier session, just never reachable
// from a plain expression constant until this.
//
// Tbig and Tbyte constant literals are a separate, still-open (but
// currently unreachable, not just untested) gap: neither has any
// literal syntax of its own, and assignable()'s strict tequal() check
// rejects a plain int literal in a byte- or big-typed context
// outright ("cannot use int as byte", confirmed) -- so nothing in
// this compiler can construct one to test against yet.

func add(a, b real) real {
	return a + b
}

func init() {
	x := 3.5
	sys.print("x=%g\n", x)

	y := add(1.25, 2.75)
	sys.print("y=%g\n", y)

	// two literals sharing the same value -- proves globalrconst()'s
	// own by-value dedup hands back the same global, not two.
	a := 9.5
	b := 9.5
	sys.print("a=%g b=%g sum=%g\n", a, b, a+b)

	// a negative value and a whole-number value (no fractional part,
	// still real-typed) -- neither is a degenerate case for the
	// "%.17g" keying.
	n := -4.5
	w := 10.0
	sys.print("n=%g w=%g\n", n, w)

	// a poisoned local before a real-constant read, same methodology
	// as the nil/list/array/vararg investigations.
	poison := 33333
	poison = 0
	sys.print("poison=%d\n", poison)
	z := 7.5
	sys.print("z=%g\n", z)
}
