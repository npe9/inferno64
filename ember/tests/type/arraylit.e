module Arraylit

import sys "sys"

// "[size]T{v, v, ...}" -- array value-list composite literals, the
// last of the two gaps this branch's own arrays-scoping note (see
// arrayindex.e's history) filed as separate from plain zero-fill
// allocation ("[size]T", 0293a0de). Go's own shape (positional-only),
// deliberately NOT limbo's fuller "array[] of {v,...}" form (ranges,
// wildcards, a default value for unset slots) -- see parse.c's own
// comment on this grammar shape for why, and com.c's own Oarray case
// for why that scope choice means this never has to answer
// compositexhaustive()'s "is this exhaustive" question the struct-
// literal codepath (storecomposite()/storecompositezero(), Odas/Oas)
// has to: every array literal that typechecks at all is *always*
// fully specified (check.c's own Oarray case requires the element
// count to exactly match the declared size), so there's no partial-
// literal-leaving-stale-data case that predicate exists to route
// around. Stays entirely self-contained inside ecom()'s own Oarray
// case instead -- each element stored the same way Oas's own Oindx
// write branch stores into an existing array, through indxaddr().
//
// mechanism note worth keeping: Oarray's own n->left/n->right were
// already spoken for (size, element type) before this, so the
// element list lives on n->aux instead of the usual Ocomposite
// wrapping struct literals use -- and sumark() (com.c) needed an
// explicit new case to walk into it, since its own generic top-of-
// function recursion only ever visits left/right, never aux.
//
// caveat for later, not a live gap today: "arrays are never
// exhaustive, always route through the zero-fill+per-element-store
// path" is the *right* answer for the positional-only, count-must-
// match-size form this file tests -- it's what sidesteps
// compositexhaustive()'s predicate entirely rather than needing an
// array branch in it. that stops being true the moment a keyed/
// sparse array form (limbo's own fuller "array[] of {v,...}", still
// not ported) is ever added: a partial array literal genuinely can
// leave slots unset, and compositexhaustive() would need a real
// array case at that point, not just continued avoidance -- the
// same "parked for a reason that later evaporates needs re-triage"
// lesson slicing's own history (ember-language-status.md) already
// recorded once.

type Big struct {
	a, b int
}

func sum(xs []int) int {
	total := 0
	i := 0
	for i < len(xs) {
		total = total + xs[i]
		i = i + 1
	}
	return total
}

func init() {
	xs := [3]int{10, 20, 30}
	sys.print("xs0=%d xs1=%d xs2=%d sum=%d\n", xs[0], xs[1], xs[2], sum(xs))

	// a single-element array -- the degenerate, smallest-real case.
	ys := [1]int{42}
	sys.print("ys0=%d\n", ys[0])

	// used directly as a call argument, no intermediate local --
	// exercises the literal as an arbitrary subexpression, not just a
	// declaration's own RHS.
	sys.print("directsum=%d\n", sum([4]int{1, 2, 3, 4}))

	// an empty literal -- zero elements, zero declared size. the
	// parser's own composite-body loop handles an immediate "}" by
	// leaving the elems chain nil, and check.c's count check (0==0)
	// passes -- confirmed this actually takes the plain n->aux==nil
	// zero-fill path, not a degenerate one-element-wide Oseq chain.
	zs := [0]int{}
	sys.print("len(zs)=%d\n", len(zs))

	// a two-word struct element (Big is exactly IBY2LG-sized) --
	// indxaddr()'s own size switch picks IINDL for this, distinct
	// from the plain IINDX every int-element case above exercises;
	// 0293a0de singled out this same size class as worth testing
	// directly for bare Oindx, and the literal path reaches the
	// identical helper but had never been run down this branch until
	// now.
	b0 := Big{a: 1, b: 2}
	b1 := Big{a: 3, b: 4}
	bs := [2]Big{b0, b1}
	sys.print("bs0=%d,%d bs1=%d,%d\n", bs[0].a, bs[0].b, bs[1].a, bs[1].b)

	// a poisoned local right before more literal construction, same
	// methodology as every other investigation this session.
	poison := 98765
	poison = 0
	sys.print("poison=%d\n", poison)
	sys.print("xs0=%d\n", xs[0])
}
