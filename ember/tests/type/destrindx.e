module Destrindx

import sys "sys"

// "xs[i], y = f()" -- an Oindx destination in a multi-value
// destructuring assignment -- was the one remaining piece of the
// array-indexing gap left open by 0293a0de/indxfield.e's own fix:
// destructure() (com.c) calls fixdblind() per destructured id to
// resolve the identical chained-ref-lvalue gap ecom()'s own Oind case
// has, but fixdblind() only matches Oind, so it returns nil outright
// for an Oindx id -- leaving id->addable at Oindx's own sumark
// default (Rcant) and failing loudly at codegen ("can't deal with
// addressable ... in genaddr"), the same honest failure every other
// not-yet-wired lvalue call site hit before it got its own
// indxaddr() branch.
//
// mechanism: destructure() now special-cases an Oindx id the same
// way Oas's own Oindx branch already does -- indxaddr() computes the
// bounds-checked element address into a synthetic Oind (ia.ind), and
// the per-field store targets that instead of id directly.
// indxaddrfree() releases it once the store is done, same lifetime
// as every other indxaddr() caller.
//
// a field chained directly off an array index in a destructuring
// target ("bs[0].a, y = f()") already worked here for free, BEFORE
// this fix -- confirmed by testing, not assumed: check.c's Odot
// lowering produces the exact Oind(Oadd(...)) shape fixdblind()
// already recognizes regardless of which op called it, and the
// Oadr(Oindx) case ecom() gained for the plain read/write sites (see
// ecom()'s own Oadr case) is what made fixdblind()'s materialization
// of that base compile. only the *bare* Oindx target needed a real
// fix, which is what this file actually tests.

type Big struct {
	a, b int
}

func two() (int, int) {
	return 7, 8
}

func init() {
	xs := [3]int
	xs[0] = 1
	xs[1] = 2
	xs[2] = 3

	// the bare-Oindx case: xs[0] itself is the destructured target,
	// not a field chained off it.
	y := 0
	xs[0], y = two()
	sys.print("xs0=%d y=%d\n", xs[0], y)

	// a second, independent element -- proves the store landed at
	// xs[0]'s own computed address, not some fixed/aliased slot that
	// happens to also affect xs[1].
	sys.print("xs1=%d xs2=%d\n", xs[1], xs[2])

	// index computed at runtime, not folded at compile time -- same
	// reasoning as arrayindex.e's own runtime-index case: this must
	// go through the real IINDX bounds-check path each time, not a
	// constant offset.
	i := 0
	i = i + 1
	xs[i], y = two()
	sys.print("xs[1]=%d y=%d (xs0 unaffected)=%d\n", xs[1], y, xs[0])

	// a poisoned local right before the destructuring store, same
	// methodology as every other investigation this session -- catches
	// a stale-frame-slot bug if indxaddr()'s own temps here are wrong.
	poison := 44444
	poison = 0
	sys.print("poison=%d\n", poison)

	// the field-chained case, alongside the bare case, for a single
	// file documenting the whole destructure()-Oindx story together --
	// already worked before this fix, re-confirmed here.
	bs := [2]Big
	b0 := Big{a: 10, b: 20}
	bs[0] = b0
	bs[0].a, y = two()
	sys.print("bs0.a=%d y=%d\n", bs[0].a, y)
}
