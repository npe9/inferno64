module Closurecaptures

import sys "sys"

// phase 3 of the closure-lowering plan (doc/ember-repository-study.md):
// by-value captures.  a closure literal that reads or writes a Darg/
// Dlocal from its immediately enclosing function (or closure) now
// compiles instead of erroring -- check.c's synthfunclit() lifts the
// captured set into a synthesized adt (one Dfield per capture), copies
// each captured variable's *current* value into a fresh instance of it
// at the closure's own construction site, and stores that instance's
// pointer as the tfnptr's env (t2) -- nil only when nothing is
// captured.  by value, deliberately: a mutation on either side after
// the closure is created is invisible to the other.

func apply(f func(int) int, x int) int {
	return f(x)
}

// the case that actually justifies a heap-allocated env instead of
// nothing: the closure outlives the frame it captured from.  mk's own
// return type ("func(int) int") is itself function-shaped, which
// needed its own fix (stype()'s Otfunc case, check.c) -- see the
// commit message; every earlier test here calls its closure while the
// creating frame is still live, which this one deliberately isn't.
func mk(n int) func(int) int {
	return func(x int) int { return x + n }
}

func init() {
	// by-value: mutating n after the closure is created must not
	// change what the closure sees.
	n := 10
	f := func(x int) int {
		return x + n
	}
	n = 999
	sys.print("a=%d\n", f(1))

	// write to a captured variable, from inside the closure -- the
	// closure's own copy changes and persists across calls; the
	// enclosing local is untouched.
	m := 5
	g := func(delta int) int {
		m = m + delta
		return m
	}
	sys.print("b=%d\n", g(3))
	sys.print("c=%d\n", g(3))
	sys.print("d=%d\n", m)

	// multiple captures in one closure
	a := 1
	b := 2
	h := func(x int) int {
		return x + a + b
	}
	sys.print("e=%d\n", h(10))

	// a captured *function-valued* local, called as f(x) -- goes
	// through Ocall's echk(n->left)/Oind-wrapping branch (not the
	// literal-callee path), so the captured reference ends up nested
	// inside a node check.c's synthfunclit() didn't build; found (and
	// fixed, com.c's fpcall()) a real, more general pre-existing gap
	// this exposed: calling through a value read via one extra level
	// of indirection (Radr) than any earlier call-through-a-value site
	// ever produced.
	inc := func(x int) int { return x + 1 }
	callee := inc
	k := 100
	wrap := func(x int) int {
		return callee(x) + k
	}
	sys.print("i=%d\n", wrap(1))

	// nested closures: inner captures from outer, its own direct
	// parent -- supported, one level deep.
	outer := func(y int) int {
		z := 2
		inner := func(w int) int {
			return w + z
		}
		return inner(y)
	}
	sys.print("j=%d\n", outer(3))

	// escaping closures: two independently-created envs, both still
	// live after mk() has returned each time -- f's env must not be
	// affected by g's creation, proving they're genuinely separate
	// heap allocations, not one shared/reused slot.
	fe := mk(10)
	sys.print("k=%d\n", fe(1))
	ge := mk(100)
	sys.print("l=%d\n", fe(1))
	sys.print("m=%d\n", ge(1))
}
