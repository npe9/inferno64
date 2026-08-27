module Listtest

import sys "sys"

// "::"/hd/tl (Ocons/Ohd/Otl), unblocked now that nil (a4d50b11) has a
// real codegen path -- everything else here was already fully wired
// (Mcons/Mhd/Mtl -> real Dis opcodes, ported wholesale from limbo's
// optab.c) and just never called from ecom() before. "::" is a new,
// right-associative operator (Econs, parse.c's binprec/pbinary),
// slotted looser than every arithmetic/comparison op and tighter
// than &&/||, matching limbo's own precedence for it -- go has no
// equivalent operator to inherit a slot from. hd/tl are function-
// call-style builtins ("hd(xs)", not limbo's keyword-prefix "hd
// xs"), matching the local convention "len" already established.

func sumlist(xs list int) int {
	if xs == nil {
		return 0
	}
	return hd(xs) + sumlist(tl(xs))
}

func init() {
	xs := 1 :: 2 :: 3 :: nil
	sys.print("sum=%d\n", sumlist(xs))
	sys.print("hd=%d\n", hd(xs))

	ys := hd(xs) :: tl(xs)
	sys.print("sum2=%d\n", sumlist(ys))

	// right-associativity check: "1 :: 2 :: nil" must parse as
	// "1 :: (2 :: nil)", a 2-element list -- if it were left-assoc
	// (parsed as "(1 :: 2) :: nil", which wouldn't even typecheck,
	// since 2 isn't a list) this would be a compile error, not a
	// runtime difference, so the fact this file compiles at all is
	// itself part of the proof; sum confirms both elements are
	// still genuinely present.
	zs := 10 :: 20 :: nil
	sys.print("sum3=%d\n", sumlist(zs))

	// a poisoned local before building/walking a fresh list, same
	// methodology as niltest.e/the Sys_sleep investigation -- catches
	// a stale-frame-slot bug if Ocons/Ohd/Otl's own temps++ bump
	// (com.c's sumark()) turns out to be wrong.
	poison := 99999
	poison = 0
	sys.print("poison=%d\n", poison)
	ws := 7 :: 8 :: 9 :: nil
	sys.print("sum4=%d\n", sumlist(ws))
}
