module Indxfield

import sys "sys"

// "bs[0].a" -- a struct field accessed directly off an array index,
// both read and write -- was the one narrow gap array indexing
// (0293a0de) left open: check.c's Odot lowering for a value struct's
// own field always wraps a non-ref base in Oadr ("give me the
// address of this value's own storage, don't load it"), the same way
// it does for a plain Oname base -- producing Oind(Oadd(Oadr(base),
// $offset)). For an Oindx base, that address has no *existing* frame
// slot the way a plain local's does; it has to be *computed*, via
// the identical real Dis instruction indxaddr() already builds for a
// bare Oindx read. ecom() had no case for Oadr at all (by design --
// see its own comment -- an ordinary Oadr is just a static
// addressing-table marker, never itself compiled as a value), so an
// Oindx base fell all the way through to the generic "no case"
// fatal.
//
// mechanism: a new ecom() case for Oadr specifically when its own
// base is Oindx, computing the address via indxaddr() and handing
// back just the raw address (ia.addrtmp) -- Oadr's whole point is
// "don't load", and that address IS exactly what a subsequent load
// would dereference, so no further indirection is needed. reachable,
// with the right (tint-overridden) destination already set up, via
// fixdblind()'s own EXISTING, completely unmodified machinery:
// check.c's Odot lowering always produces the exact Oind(Oadd(...))
// shape fixdblind() already recognizes and materializes -- already
// wired into every read (ecom()'s own Oind case) and write (Oas, the
// compound-assignment family, Oinc/Odec) call site that needs it.
// zero changes needed to fixdblind() itself, or to any of its
// existing call sites -- confirmed by testing every one of those
// write paths below, all working on the first attempt once the
// single missing Oadr case was added.

type Big struct {
	a, b int
}

func init() {
	bs := [2]Big

	// composite-literal-as-Oindx-RHS stays its own separate,
	// deliberately out-of-scope gap (arrayindex.e's own header) --
	// route through a plain local first, same workaround.
	b0 := Big{a: 10, b: 20}
	b1 := Big{a: 30, b: 40}
	bs[0] = b0
	bs[1] = b1

	// read, chained directly off the index -- the gap itself.
	sys.print("direct: %d,%d %d,%d\n", bs[0].a, bs[0].b, bs[1].a, bs[1].b)

	// write, compound-assignment, and increment, all chained
	// directly off the index -- exercises every lvalue call site
	// fixdblind() already covers.
	bs[0].a = 99
	sys.print("after write: %d,%d\n", bs[0].a, bs[0].b)

	bs[0].b++
	sys.print("after inc: %d,%d\n", bs[0].a, bs[0].b)

	bs[0].a += 5
	sys.print("after compound: %d,%d\n", bs[0].a, bs[0].b)

	// a poisoned local before more chained access, same methodology
	// as every other investigation this session.
	poison := 22222
	poison = 0
	sys.print("poison=%d\n", poison)

	// a second, independent element -- proves this doesn't alias
	// bs[0]'s own address.
	bs[1] = b0
	bs[1].a = 777
	sys.print("bs1: %d,%d bs0-unaffected: %d,%d\n", bs[1].a, bs[1].b, bs[0].a, bs[0].b)
}
