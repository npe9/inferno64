module Nestedref

import sys "sys"

// "o.in.v" where in is itself ref-typed: check.c's Odot case lowers a
// chained field access to Oind(Oadd(base, offset)) at each level, so a
// second level of ref indirection nests one Oind(Oadd(...)) chain
// inside another. com.c's sumark() has no row for an Oadd/Oind whose
// own base is already Radr/Rmadr-addressed (one indirection deep
// already) -- the addressing enum has no representation for a third
// indirection level at all, so this used to hard-fail in codegen
// ("can't deal with addressable 10 in genaddr") for *any* expression
// chasing a ref field through another ref, unrelated to closures,
// methods, or generics despite how varied the shapes below look --
// com.c's fixdblind() is the fix, materializing the already-indirect
// base into a plain temp first so the familiar single-level Oind/Oadd
// shape (the same one p.field on an ordinary ref parameter already
// used) takes over, called from both the read side (ecom's own Oind
// case) and every write side (Oas, compound assignment, Oinc/Odec)
// that can target a chained-ref lvalue.
//
// every allocation below is deliberately two-step ("i := ref
// Inner{...}; o := ref Outer{in: i}"), not a directly-nested literal
// ("ref Outer{in: ref Inner{...}}") -- the latter hits a real,
// separate, pre-existing bug in nested ref-typed composite-literal
// construction (a background GC cycle later faults on a corrupted
// pointer, reproducible even with zero field access and zero
// parameter passing) that this file is not about and does not fix;
// see the ember-language-status memory file for that one.

type Inner struct {
	v int
}
type Mid struct {
	in ref Inner
}
type Outer struct {
	mid ref Mid
}

// three levels of ref indirection chased through a function parameter.
func get3(o ref Outer) int {
	return o.mid.in.v
}

type Box struct {
	v int
}

// a method returning a closure that captures its own ref receiver,
// then reads a field through it -- the shape this bug was originally
// found through.
func (b ref Box) mkadder() func(int) int {
	return func(x int) int { return x + b.v }
}

// a plain (non-method) closure capturing a ref-typed parameter and
// reading a field through it.
func mkfromref(b ref Box) func() int {
	return func() int { return b.v }
}

type Wrap struct {
	in ref Inner
}

// multi-return destructured directly into a chained-ref lvalue
// alongside a plain one -- destructure()'s own write path.
func pair() (int, int) {
	return 41, 43
}

func init() {
	i := ref Inner{v: 7}
	m := ref Mid{in: i}
	o := ref Outer{mid: m}
	sys.print("a=%d\n", get3(o))

	b1 := ref Box{v: 10}
	sys.print("b=%d\n", b1.mkadder()(5))

	b2 := ref Box{v: 20}
	f := mkfromref(b2)
	sys.print("c=%d\n", f())

	// the write side: assignment, increment/decrement, and compound
	// assignment all through the same chained-ref lvalue.
	i2 := ref Inner{v: 1}
	w := ref Wrap{in: i2}
	w.in.v = 99
	sys.print("d=%d\n", w.in.v)
	w.in.v++
	sys.print("e=%d\n", w.in.v)
	w.in.v += 5
	sys.print("f=%d\n", w.in.v)
	w.in.v--
	sys.print("g=%d\n", w.in.v)

	x := 0
	w.in.v, x = pair()
	sys.print("h=%d i=%d\n", w.in.v, x)
}
