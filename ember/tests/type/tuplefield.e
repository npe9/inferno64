module Tuplefield

import sys "sys"

// tuple-typed struct fields ("struct { r (int, string) }") -- the
// "other half" of the compositefields() nerror stub the pick-adt work
// (a42b2046) left standing for tagged fields; this turned out not to
// need any new recursive store machinery at all, unlike tagged fields
// (which do): tequal()'s own Ttuple case (types.c) already compares
// two tuple types positionally, ignoring field names, so the declared
// field type and a literal's own freshly-inferred type already match
// via the ordinary assignable() call; storage already had an ecom()
// Otuple case (built for "return a, b"), just never wired to any
// other live destination before.
//
// reading a tuple field's own components back out is via ":="
// destructuring ("x, s := container.p"), not dot access -- "container.p"
// itself resolves fine (Container is a plain Tadt, and this compiler's
// existing Odot field-access case already handles that level), but a
// *further* dot straight onto the tuple result ("container.p.t0")
// would need check.c's Odot case to handle a Ttuple base too, which it
// doesn't yet -- a separate, smaller, still-open gap, not attempted
// here (destructuring is enough to observe and verify this fix).
//
// two real, genuinely pre-existing bugs were found getting the shapes
// beyond a bare literal to actually work (advisor-flagged before
// committing, not something a literal-only test alone would have
// caught):
//
// 1. echk()'s own Otuple case built its fresh Ttuple via mktype()
// only, no sizetype() call -- fine for Oret (which explicitly sizes
// the value itself, check.c) but wrong anywhere else a live Otuple
// value gets constructed and then actually stored: com.c's Otuple
// ecom case would read every field offset as its zero-initialized
// default, landing every component at the same address (or, for a
// pointer-typed component, a segfault) -- the same unsized-Type bug
// class this branch has hit four times before. First found via the
// struct-field-literal case, patched narrowly there; then found AGAIN
// via a completely different call site (a bare "bt = (1, "one")"
// reassignment, check.c's Oas fallback -- a THIRD site with the
// identical gap, no relation to struct fields at all). Fixed at the
// root instead of chasing each call site individually: echk()'s own
// Otuple case now sizetype()s the fresh type once, centrally, so
// every present and future caller gets it for free.
//
// 2. a bare "t := (1, 2)" (a tuple declared directly, not via "return
// a, b", and not routed through any struct field either) separately
// corrupted even once sized -- an all-int tuple read back garbage, a
// string-typed component segfaulted. com.c's Otuple ecom case only
// ever peeled nto->left when nto->op == Oind (retalloc()'s own
// Oind(retnode) shape, or storecomposite()'s own Oind(Oadd(...))
// shape) -- a plain ":="-declared local's own destination is a bare
// Oname (Rreg/Rmreg), not yet wrapped in any Oind at all, so the peel
// never fired and the code added each component's own offset directly
// onto the *value* stored at that slot instead of onto its *address*.
// Fixed with the identical Oadr-wrapping check.c's own Odot lowering
// already gives a value-typed struct's non-ref base -- confirmed via
// the two dependent existing "return a, b" tests (multireturn.e,
// multiassign.e) still passing unchanged, since that shape still
// takes the pre-existing Oind-peel branch.

type Container struct {
	id  int
	p   (int, string)
}

func mkpair(x int, s string) (int, string) {
	return x, s
}

func init() {
	// the realistic case: a bare parenthesised tuple expression
	// (real, general syntax already -- parse.c's own '(' case)
	// directly as a struct field's own value.
	c := Container{id: 1, p: (2, "two")}
	a, s := c.p
	sys.print("c.id=%d a=%d s=%s\n", c.id, a, s)

	// two independent constructions, proving no aliasing between
	// them (the same discriminating check every other composite-
	// literal test in this branch uses).
	c1 := Container{id: 10, p: (100, "one")}
	c2 := Container{id: 20, p: (200, "two")}
	a1, s1 := c1.p
	a2, s2 := c2.p
	sys.print("c1.id=%d a1=%d s1=%s c2.id=%d a2=%d s2=%s\n",
		c1.id, a1, s1, c2.id, a2, s2)

	// a positional (unkeyed) literal too, not just keyed.
	c3 := Container{30, (300, "three")}
	a3, s3 := c3.p
	sys.print("c3.id=%d a3=%d s3=%s\n", c3.id, a3, s3)

	// a multi-return call's own result used directly as a field's
	// value -- vt here is the function's own already-sized declared
	// return type (fndecl()'s own processing), not echk()'s Otuple
	// case at all, so this exercises a different path than the bare
	// literal above.
	c4 := Container{id: 9, p: mkpair(9, "nine")}
	a4, s4 := c4.p
	sys.print("c4.id=%d a4=%d s4=%s\n", c4.id, a4, s4)

	// a pre-declared named tuple local used as a field's value.
	t := (40, "forty")
	c5 := Container{id: 40, p: t}
	a5, s5 := c5.p
	sys.print("c5.id=%d a5=%d s5=%s\n", c5.id, a5, s5)

	// heap (ref) construction, not just a value struct in a frame
	// slot -- the tagged-adt work (a42b2046) found a real segfault
	// exactly at this ref/tdescmap() boundary (an all-int tag worked
	// by accident, a string-typed one didn't), so this gets its own
	// dedicated check rather than assuming the frame-slot cases above
	// cover it.
	rc := ref Container{id: 50, p: (60, "sixty")}
	ar, sr := rc.p
	sys.print("rc.id=%d ar=%d sr=%s\n", rc.id, ar, sr)

	// a bare tuple declared directly (not via "return", not via a
	// struct field) -- the second bug found this session, described
	// above.
	bt := (70, "seventy")
	ab, sb := bt
	sys.print("bt: ab=%d sb=%s\n", ab, sb)

	// a poisoned local right before more construction, same
	// methodology as every other investigation this session.
	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
	z := Container{id: 7, p: (70, "seven")}
	az, sz := z.p
	sys.print("z.id=%d az=%d sz=%s\n", z.id, az, sz)

	// reassignment of an already-declared tuple local ("bt = (...)",
	// Oas, not Odas) -- a THIRD site with the identical unsized-fresh-
	// Ttuple gap, found only by testing this shape directly (advisor-
	// flagged before committing): check.c's Oas fallback path
	// (echk(n->right) with no sizetype() of its own, a different call
	// site than compositefields()'s per-field one) segfaulted the
	// same way the bare ":=" case originally did. Fixed at the root
	// this time, not per call site: echk()'s own Otuple case now
	// sizetype()s the fresh type it builds once, centrally, so every
	// caller -- this one, compositefields()'s, Oas's, any future one
	// -- gets it for free, rather than chasing each call site that
	// happens to construct a live Otuple value individually.
	bt = (0, "zero")
	bt = (1, "one")
	ar1, sr1 := bt
	sys.print("reassign: ar1=%d sr1=%s\n", ar1, sr1)

	// reassignment inside a loop body: the Oadr-wrapped destination
	// is a reused frame slot, not a fresh one -- the stale-slot hazard
	// this branch's own composeas.e ("g") documents for struct
	// literals, checked here for tuples too.
	i := 0
	for i < 3 {
		bt = (i, "iter")
		xi, yi := bt
		sys.print("loop x=%d y=%s\n", xi, yi)
		i = i + 1
	}
}
