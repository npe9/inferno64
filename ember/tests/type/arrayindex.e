module Arrayindex

import sys "sys"

// xs[i] (Oindx), the design fork put to the user directly (chose
// "keep check.c's existing semantics" -- Oindx already means the
// *loaded value*, not an address the way limbo's own rewrite()-based
// Oind(Oindx(...)) does -- over porting limbo's two-node shape).
// com.c's ecom() had no case at all before this (fatal("ecom:
// unsupported indx")), for either reads or writes.
//
// mechanism: indxaddr() computes a bounds-checked element address via
// a real Dis instruction (IINDX/IINDB/IINDF/IINDL, one per element
// size -- this can't be folded into sumark's purely static Radr/Rmadr
// addressing the way a struct field's constant offset can, since the
// index is a genuine runtime value) into a fresh tint temp, then
// wraps it in a synthetic Oind -- from there the *existing*
// genmove()/genaddr() machinery reads or writes through it exactly
// like an ordinary ref dereference. shared by ecom()'s own Oindx case
// (reads) and every lvalue call site (Oas, the compound-assignment
// family, Oinc/Odec) that already special-cased fixdblind() for the
// structurally unrelated chained-ref-lvalue gap -- both are the same
// standing invariant: sumark() alone doesn't establish addressability
// at a write site.
//
// also new here: "[size]T", a minimal zero-fill array-allocation
// expression (Oarray), needed purely so this file could construct a
// real, non-empty array from ember source at all to test indexing
// against -- previously arrays could only ever be received as
// parameters, and this module's own init(argv []string) always gets
// an empty argv (emu's "-d module" never constructs one). ported from
// limbo/ecom.c's identical case, always zero-filled (limbo's fuller
// "array[] of {v,...}" value-list form is NOT included -- that stays
// its own separate, still-open gap, compositefields() only accepting
// adt types).
//
// deliberately NOT attempted here (real, narrower, separate gaps):
// array *value-list* composite literals ("[3]int{1,2,3}", vs. the
// zero-fill-only "[3]int" this file uses) and a composite literal as
// an Oindx assignment's own RHS ("xs[i] = Point{...}", falls through
// to ecom()'s honest "no Ocomposite case" fatal, the same failure
// every other not-yet-supported composite-literal-write context
// already hits).
//
// found while writing THIS file, scoped at the time, later RESOLVED
// (see tests/type/indxfield.e): a field access chained directly off
// an array index ("bs[0].a", not "r := bs[0]; r.a") used to fatal
// ("ecom: unsupported adr") -- check.c's Odot lowering for a value
// struct's own field unconditionally wraps the base in Oadr, and
// ecom() had no case for it when the base was Oindx. below, every
// array element read still goes through an intermediate local first
// ("r0 := bs[0]") -- not required anymore, just left as-is since it
// already exercises the plain (non-chained) read/write paths this
// file is actually about; indxfield.e is the dedicated test for the
// chained case itself.

type Big struct {
	a, b int
}

func sumarr(xs []int) int {
	total := 0
	i := 0
	for i < len(xs) {
		total = total + xs[i]
		i = i + 1
	}
	return total
}

func bump(xs []int) {
	xs[0]++
	xs[1] += 10
	xs[2] = xs[2] * 2
}

func init(argv []string) {
	xs := [5]int
	xs[0] = 1
	xs[1] = 2
	xs[2] = 3
	xs[3] = 4
	xs[4] = 5
	sys.print("sum=%d\n", sumarr(xs))
	sys.print("xs0=%d xs2=%d xs4=%d\n", xs[0], xs[2], xs[4])

	xs[0] = 100
	sys.print("after write xs0=%d sum=%d\n", xs[0], sumarr(xs))

	bump(xs)
	sys.print("after bump xs0=%d xs1=%d xs2=%d\n", xs[0], xs[1], xs[2])

	// index computed at runtime, not a constant -- exercises the
	// actual IINDX bounds-check path, not just a compile-time-folded
	// constant offset.
	i := 2
	i = i + 1
	sys.print("xs[i]=%d\n", xs[i])

	// zero-fill confirmed: a freshly allocated array reads back as
	// all zero before anything writes to it.
	zs := [3]int
	sys.print("zero-fill zs0=%d zs1=%d zs2=%d\n", zs[0], zs[1], zs[2])

	// element type sized exactly IBY2LG (a two-word struct): the size
	// switch in indxaddr() sends this to IINDL rather than the
	// generic IINDX -- worth exercising directly, not just inferring
	// the stride works from the int case above.
	bs := [2]Big
	b0 := Big{a: 10, b: 20}
	b1 := Big{a: 30, b: 40}
	bs[0] = b0
	bs[1] = b1
	r0 := bs[0]
	r1 := bs[1]
	sys.print("bs0=%d,%d bs1=%d,%d\n", r0.a, r0.b, r1.a, r1.b)

	// a poisoned local before an index read/write, same methodology
	// as the nil/list investigations -- catches a stale-frame-slot
	// bug if indxaddr()'s own temps++ bump (com.c's sumark()) is
	// wrong.
	poison := 54321
	poison = 0
	sys.print("poison=%d\n", poison)
	xs[3] = xs[3] + xs[4]
	sys.print("xs3=%d\n", xs[3])

	sys.print("argv len=%d\n", len(argv))
}
