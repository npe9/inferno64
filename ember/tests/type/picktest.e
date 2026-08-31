module Picktest

import sys "sys"

// pick adts (tagged unions), the construction+field-read slice of
// this branch's own pick-adt plan (see ember-language-status.md's
// memory doc): "type X pick {...}" (declaration), sizetype()'s tag-
// word layout, and parsing for all of this were already complete --
// the genuinely missing pieces were: assigning each tag's own
// runtime discriminant (Decl.tag, declaration-order/0-based, ported
// directly from limbo/types.c's pickdecled()); resolving "Adt.Tag"
// as a type expression (stype()'s Odot case previously only handled
// a module-qualified name); compositefields() accepting a Tadtpick
// type and matching fields against the tag's own ids; com.c's
// storecomposite() writing the tag word itself, not just the fields
// a literal lists; and check.c's own Odot field-access case reading
// a Tadtpick-typed value's fields back. match's Opat handling and
// Ochk's "?" propagation are still separately open -- not attempted
// here.
//
// a real, pre-existing, previously-unreachable bug was found and
// fixed getting this far: types.c's tdescmap() (the GC pointer-map
// builder) had a Tadtpick case that reassigned "t = t->tof" and
// walked *only* the outer adt's shared fields, silently never
// examining a tag's own fields at all -- invisible until a tag with
// a pointer-typed field of its own (Err's string) was actually
// constructed and heap-scanned: a real segmentation fault, not a
// hang or a compile error. Ok (all-int, no pointer fields) worked by
// accident before the fix; Err (a string field) didn't. Confirmed via
// a live repro before fixing, not inferred from reading the code.

type Result pick {
	Ok(val int)
	Err(msg string)
}

func init() {
	// value form (no ref) -- both tags, both field types (int
	// exercises the "no pointer fields" case the bug above hid
	// behind; string is the one that actually caught it).
	ok := Result.Ok{val: 5}
	sys.print("ok.val=%d\n", ok.val)

	err := Result.Err{msg: "bad"}
	sys.print("err.msg=%s\n", err.msg)

	// ref form -- the more common real-world shape (Result values
	// are usually passed/returned, not held as plain locals).
	r := ref Result.Ok{val: 42}
	sys.print("r.val=%d\n", r.val)

	// the empty-literal / zero-value idiom (Go's own "T{}" means
	// every field defaults to zero, not an error) -- also confirms
	// the tag word gets written even down storecompositezero()'s
	// separate zero-fill-then-store path, not just the direct one
	// the cases above take.
	z := Result.Ok{}
	sys.print("z.val=%d\n", z.val)

	// two independent constructions of the *same* tag -- proves no
	// aliasing between them.
	a := Result.Ok{val: 100}
	b := Result.Ok{val: 200}
	sys.print("a.val=%d b.val=%d\n", a.val, b.val)

	// a poisoned local right before more construction, same
	// methodology as every other investigation this session.
	poison := 77777
	poison = 0
	sys.print("poison=%d\n", poison)
	sys.print("ok.val=%d err.msg=%s\n", ok.val, err.msg)
}
