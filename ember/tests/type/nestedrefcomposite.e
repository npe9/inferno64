module Nestedrefcomposite

import sys "sys"

// "ref Outer{in: ref Inner{v: 42}}" -- a ref composite literal
// written directly inside another ref composite literal's own
// field, as opposed to building the inner value in a separate step
// first ("i := ref Inner{...}; o := ref Outer{in: i}", see
// nestedref.e's own header comment for why that version was always
// safe).
//
// root cause: check.c's Oref case built the literal's own Tref
// type via mktype() but never sized it (unlike Ochan, two cases
// below in the same switch, which sizes its own fresh type on the
// spot) -- so t->size and t->align stayed at mktype's zero-
// initialised default.  a *top-level* "x := ref T{...}" never
// noticed, because x is a real declared local and gets its type
// sized separately, during ordinary local-declaration processing.
// but a *nested* one has no declared local of its own -- its type
// is only ever consumed by com.c's Oref case to talloc() a
// compiler temp, needed whenever the outer literal's own field
// address isn't a plain addressable destination (which a directly-
// nested literal's inner value never is). idoffsets() then placed
// that temp at a zero-width frame slot, overlapping whatever offset
// came next -- so the temp's own pointer got silently clobbered by
// a later, unrelated write (no destroy(), since the overlap was
// invisible to both sides), while the frame's own gc descriptor
// still marked that offset as live. a background mark cycle
// eventually dereferenced whatever the other write had left there,
// as a native EXC_BAD_ACCESS inside libinterp's markheap(), always
// well after the corrupting write itself and unrelated to whether
// the nested value was ever field-accessed at all -- confirmed by
// (a) reproducing on the unmodified baseline compiler with zero
// field access and a function that ignores its own parameter, and
// (b) a debug dump of the actual frame layout showing the ref
// temp's own decl and an unrelated later temp sharing one offset.
// fixed by sizetype()ing the Oref literal's own type, matching
// Ochan's existing precedent exactly.

type Inner struct {
	v int
}
type Mid struct {
	in ref Inner
}
type Outer struct {
	mid ref Mid
}

func get3(o ref Outer) int {
	return o.mid.in.v
}

func init() {
	// three levels deep, directly nested, actually field-accessed --
	// the original shape this bug was found through.
	o := ref Outer{mid: ref Mid{in: ref Inner{v: 42}}}
	sys.print("a=%d\n", get3(o))
	sys.print("b=%d\n", o.mid.in.v)

	// two directly-nested literals as siblings, each carrying a
	// distinct value, to catch any cross-contamination between
	// their own compiler temps.
	o2 := ref Outer{mid: ref Mid{in: ref Inner{v: 100}}}
	o3 := ref Outer{mid: ref Mid{in: ref Inner{v: 200}}}
	sys.print("c=%d d=%d\n", o2.mid.in.v, o3.mid.in.v)

	// further calls afterward, to stress any leftover frame-slot
	// issue under continued temp allocation in the same function.
	sys.print("e=%d\n", get3(o))
	sys.print("f=%d\n", get3(o2))
	sys.print("g=%d\n", get3(o3))
}
