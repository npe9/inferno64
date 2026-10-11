module Genericinfer3

import sys "sys"

// generic-call type inference through a function-typed parameter's
// own *multi*-result return type -- "f func(int) (T, U)" -- one
// level deeper than genericinfer2.e's countargs/apply cases, which
// only ever unified through a single-result Otfunc return type.
// unifytparam() (check.c) previously had no Ottuple case at all,
// falling to its default no-op: a bare "splitfirst(mkpair)" call
// (no explicit "[...]") failed to infer T/U and asked for them
// spelled out. T and U here appear *only* inside f's own signature,
// same shape as genericinfer2.e's countargs -- there's no separate
// "x T" parameter to fall back on if the Otfunc/Ottuple recursion
// doesn't reach all the way through.

func splitfirst[T,U](f func(int) (T,U)) T {
	// b (type U) is never read again -- U's own correct inference is
	// still discriminating via the destructure's own assignability
	// check (a wrongly-inferred U would fail to typecheck "a, b :=
	// f(1)" at all, not just print wrong), and a single fixed print
	// format inside a generic body can't match both instantiations'
	// own differing U types below anyway.
	a, b := f(1)
	return a
}

func mkpair(x int) (int, string) {
	return x + 1, "hi"
}

func mkpair2(x int) (string, int) {
	return "lo", x + 2
}

func init() {
	// T=int, U=string from one instantiation, T=string, U=int from
	// another, in the same run -- proves the binding is per-call, not
	// coincidentally right for only one direction.
	sys.print("a=%d\n", splitfirst(mkpair))
	sys.print("c=%s\n", splitfirst(mkpair2))
}
