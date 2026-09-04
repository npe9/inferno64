module Badcompare

import sys "sys"

// no equality on tuple values, and no ordering on a ref.  two struct
// values do compare, field by field (the checker expands it: the
// one-word compare limbo used to emit called structs differing in
// any later field equal, which is why the naive form is still
// refused).  refs compare by identity; scalars and strings by value;
// ordering only on numbers and strings.

type P struct {
	x int
	y int
}

func init() {
	a := P{x: 1, y: 2}
	b := P{x: 1, y: 3}
	t := (1, 2)
	u := (1, 3)
	ra := ref P{x: 1, y: 2}
	rb := ra
	l := 1 :: nil
	sys.print("%d %d %d %d\n", a == b, t == u, ra == rb, l == nil)
	sys.print("%d\n", ra < rb)
}
