module Slicetest

import sys "sys"

// "xs[lo:hi]" (Oslice) -- typechecked since check.c's own Oslice case
// already existed (n->right the lo/hi pair, n->ty the array/string
// type unchanged), but had no ecom() case at all: "ecom: unsupported
// slice", confirmed by actually compiling one before this fix, not
// inferred from the array-indexing gap it's structurally related to.
// unlike Oindx, this wasn't its own design fork -- arrays are already
// Tarray (IMOVP in movetab, a reference/header type, same treatment
// as a ref or a list), so "what does slicing mean at runtime" was
// already answered by the existing representation, not an open
// question the way indexing's own address-vs-value split was.
//
// mechanism: ported from limbo/ecom.c's identical case, simplified
// to drop its sameaddr()-driven materialization-order juggling
// (matching this port's established preference, see com.c's own
// Ocons case) -- left, then lo, then hi are always materialized in
// that fixed left-to-right source order, an omitted bound defaults
// to 0 (lo) or len(left) (hi), then left's own array header is
// copied into the destination and ISLICEA/ISLICEC (libinterp/xec.c's
// OP(slicea), read directly to confirm this rather than assumed from
// limbo's own call shape) mutates that copy in place from the
// resolved lo/hi bounds -- building a *new* header sharing the
// original's own underlying data (t->ref++, no copy), the identical
// aliasing semantics limbo and go both give slicing: a slice shares
// storage with what it was sliced from, it doesn't copy it. Verified
// below, not assumed.
//
// separately confirmed, not exercised in this file (a deliberately
// crashing program isn't a good permanent addition to a suite meant
// to be run by hand): an out-of-bounds slice ("xs[1:10]" on a
// 3-element array) does correctly raise a real Dis "array bounds
// error" exception rather than silently corrupting memory -- but
// this VM build then drops into an interactive post-mortem prompt on
// any unhandled exception and hangs waiting on stdin, an emu-wide
// behavior unrelated to slicing specifically (any uncaught exception
// does this), not something to route around here.

func mkarr() []int {
	xs := [4]int
	xs[0] = 1
	xs[1] = 2
	xs[2] = 3
	xs[3] = 4
	return xs
}

func init() {
	xs := [5]int
	xs[0] = 10
	xs[1] = 20
	xs[2] = 30
	xs[3] = 40
	xs[4] = 50

	ys := xs[1:3]
	sys.print("len(ys)=%d ys0=%d ys1=%d\n", len(ys), ys[0], ys[1])

	// omitted bounds -- both directions, and both at once.
	zs := xs[:2]
	sys.print("len(zs)=%d zs0=%d zs1=%d\n", len(zs), zs[0], zs[1])
	ws := xs[3:]
	sys.print("len(ws)=%d ws0=%d ws1=%d\n", len(ws), ws[0], ws[1])
	all := xs[:]
	sys.print("len(all)=%d\n", len(all))

	// aliasing: a write through a slice is visible through the
	// original array -- proves shared storage, not a copy.
	ys[0] = 999
	sys.print("xs1 after ys0 write=%d\n", xs[1])

	// string slicing -- the other ISLICEC-selecting type, exercises
	// the op-selection branch the plain array cases above don't.
	s := "hello world"
	sub := s[0:5]
	sys.print("sub=%s\n", sub)

	// a slice of a call result -- no other live reference to the
	// array at the point of slicing, the identical "early-free" shape
	// indxaddr()'s own use-after-free bug (0293a0de) was found
	// through; left is materialized into its own temp and held live
	// across the whole case here, so this is the direct regression
	// check for that class of bug in the new code.
	cs := mkarr()[1:3]
	sys.print("cs0=%d cs1=%d\n", cs[0], cs[1])

	// double slicing: a slice of a slice, exercising OP(slicea)'s own
	// "slicing a slice" branch (ds->root != H) rather than the
	// simpler "slicing a plain array" one every case above hits.
	ds := [6]int
	i := 0
	for i < 6 {
		ds[i] = i * 10
		i = i + 1
	}
	a := ds[1:5]
	b := a[1:3]
	sys.print("b len=%d b0=%d b1=%d\n", len(b), b[0], b[1])
	b[0] = 777
	sys.print("ds after double-slice write: ds2=%d\n", ds[2])

	// a poisoned local right before more slicing, same methodology as
	// every other investigation this session.
	poison := 12345
	poison = 0
	sys.print("poison=%d\n", poison)
	sys.print("xs[1]=%d\n", xs[1])
}
