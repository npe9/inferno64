module Strindex

import sys "sys"

// "s[i]" on a string (Oinds -- check.c's Oindex case rewrites string
// indexing to a distinct op from array indexing's Oindx, typed tint
// as a rune) -- the sibling gap slicing was found sitting next to,
// walked past at first: `s[0:5]` (Oslice) got fixed before `s[0]`
// (Oinds) did, even though both are indexing ops in the same
// check.c switch and both used to fatal identically at codegen
// ("ecom: unsupported inds"). advisor-caught before this file was
// even written -- a strange surface for the language to present
// otherwise (slicing working, plain single-character indexing not).
//
// mechanism: unlike Oindx/Oslice, Oinds needs no indxaddr()-style
// address computation or in-place header mutation of its own --
// IINDC (libinterp/string.c's OP(indc), read directly) takes the
// string and the index and writes the decoded rune straight to the
// destination. disoptab (optab.c) already had a real row for Oinds
// selecting IINDC via genop()'s own destination-type lookup -- this
// only needed to supply addressing (materializing left/right, same
// fixed-order simplification as Ocons/Oslice), the instruction
// selection was already there.

func init() {
	s := "hello"
	sys.print("s0=%c s1=%c s4=%c\n", s[0], s[1], s[4])

	// index computed at runtime, not folded at compile time -- same
	// reasoning as arrayindex.e's own runtime-index case.
	i := 0
	i = i + 2
	sys.print("s[i]=%c\n", s[i])

	// a poisoned local right before another index read, same
	// methodology as every other investigation this session.
	poison := 55555
	poison = 0
	sys.print("poison=%d\n", poison)
	sys.print("s0=%c\n", s[0])
}
