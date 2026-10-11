module Badcast

import sys "sys"

// conversions that don't exist must be refused, not compiled to
// nothing or a fatal: struct<->scalar, array<->scalar, non-byte
// arrays to string, wrong argument counts.

type P struct {
	x int
}

func init() {
	p := P{x: 1}
	xs := [2]int{1, 2}
	s := "s"
	sys.print("%d %d %s\n", p.x, xs[0], s)
	a := int(p)
	b := string(xs)
	c := []int("abc")
	d := P(3)
	e := int()
	f := int(1, 2)
	g := []byte(xs)
	sys.print("%d %s %d %d %d %d %d\n", a, b, len(c), d.x, e, f, len(g))
}
