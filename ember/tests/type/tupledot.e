module Tupledot

import sys "sys"

// dot access straight onto a Ttuple value ("container.p.t0"), as
// opposed to the destructuring "x, s := container.p" that already
// worked -- the smaller, still-open gap tuplefield.e's own header
// comment (37b81a37) flagged and deliberately didn't attempt.
//
// turned out to need no new mechanism: check.c's Odot field-access
// case already builds Oind(Oadd(base,$offset)) for a Tadt/Tadtpick
// receiver, walking a field-Decl chain (t->ids, plus a second chain
// for Tadtpick's own shared fields) to find the matching offset -- a
// Ttuple's own fields live in that identical single chain (t->ids),
// the same way an ordinary struct's fields do. The only change was
// widening the receiver-kind gate to accept Ttuple alongside
// Tadt/Tadtpick -- the address arithmetic, the Oadr-wrap for a
// non-ref (value) base, and the two-chains machinery all already
// generalize correctly with zero further changes. Checked, not
// assumed: a tuple TYPE has no named-component syntax anywhere in
// this grammar at all (parse.c's own '(' type-parser only ever reads
// a bare comma-separated ptype() list, never a name) -- "t0"/"t1"/...
// (stype()'s Ottuple case and echk()'s Otuple case both auto-generate
// these, the only names that can ever exist) are therefore the only
// reachable field names, for a literal's own inferred type and a
// declared tuple-typed field alike; not a narrower test, the full
// reachable surface.
//
// a genuinely separate, pre-existing, more general gap was found
// while scoping this (not fixed here, not tuple-specific, and bigger
// than it first looked): dot access directly on ANY non-addressable
// value-typed base -- confirmed with a bare function-call result
// ("mkpoint().x", an ordinary struct-returning function, nothing to
// do with tuples) hitting "ecom: unsupported adr base call". Oadr has
// no case for a Call base specifically, but the real shape is broader
// than "calls": any value receiver with no frame slot of its own
// (a call result today; the same would apply to any other expression
// kind that produces a value struct/tuple with no addressable storage)
// needs materializing into a temp before Oadr can take its address --
// the identical class of fix bs[0].a's own Oadr-over-Oindx case
// already needed, just for a base kind (Ocall, or more generally
// "value with no lvalue") that fix didn't cover. Confirmed general,
// not new: reproduces identically for a plain struct type, with none
// of this fix's own code path involved.

type Container struct {
	id int
	p  (int, string)
}

func init() {
	// a bare tuple local, read via dot directly.
	t := (1, "hello")
	sys.print("t.t0=%d t.t1=%s\n", t.t0, t.t1)

	// the realistic motivating case: dot chained straight onto a
	// struct's own tuple-typed field.
	c := Container{id: 1, p: (2, "two")}
	sys.print("c.id=%d c.p.t0=%d c.p.t1=%s\n", c.id, c.p.t0, c.p.t1)

	// two independent constructions, proving no aliasing.
	c1 := Container{id: 10, p: (100, "one")}
	c2 := Container{id: 20, p: (200, "two")}
	sys.print("c1.p.t0=%d c1.p.t1=%s c2.p.t0=%d c2.p.t1=%s\n",
		c1.p.t0, c1.p.t1, c2.p.t0, c2.p.t1)

	// a poisoned local right before more access, same methodology as
	// every other investigation this session.
	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
	z := Container{id: 7, p: (70, "seven")}
	sys.print("z.p.t0=%d z.p.t1=%s\n", z.p.t0, z.p.t1)
}
