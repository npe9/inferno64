module Badcompare

import sys "sys"

// no equality on struct or tuple values (limbo's rule too): the
// one-word compare it used to compile to called structs differing in
// any later field equal.  refs compare by identity; scalars, strings
// compare by value; ordering only on numbers and strings.

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
