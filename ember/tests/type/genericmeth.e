module Genericmeth

import sys "sys"

type Box[T] struct {
	val T
}

func (b ref Box[T]) get() T {
	return b.val
}

func (b ref Box[T]) set(x T) {
	b.val = x
}

// a value (non-ref) receiver on a generic type -- exercises the
// value-typed field-access machinery through a generic instantiation.
func (b Box[T]) getval() T {
	return b.val
}

func init() {
	// two different instantiations side by side: each must get its
	// own compiled method body, not share (and corrupt) the
	// template's, same lesson generic functions already taught.
	bi := ref Box[int]{val: 5}
	bs := ref Box[string]{val: "hello"}
	sys.print("bi=%d bs=%s\n", bi.get(), bs.get())

	bi.set(99)
	bs.set("world")
	sys.print("bi=%d bs=%s\n", bi.get(), bs.get())

	// a second Box[int]: exercises the instantiation cache.
	bi2 := ref Box[int]{val: 42}
	sys.print("bi2=%d\n", bi2.get())

	bv := Box[int]{val: 7}
	sys.print("bv=%d\n", bv.getval())
}
