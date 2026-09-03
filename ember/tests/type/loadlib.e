module Loadlib

import sys "sys"
import libpoint "libpoint"

// an Ember module loading another Ember module: libpoint.e is
// compiled separately (its interface is tests/type/libpoint.ei) and
// loaded here at runtime.  a struct type from the interface is
// constructed on this side, passed by value and by ref across the
// boundary, and read back -- the "cross-module mod.Type{...}" path
// a42b2046 reasoned about but could never exercise.

func init() {
	lib := load Libpoint "/tmp/libpoint.dis"
	if lib == nil {
		sys.print("load failed\n")
		return
	}
	sys.print("name=%s\n", lib.name())

	a := libpoint.Point{x: 1, y: 2}
	b := libpoint.Point{x: 10, y: 20}
	c := lib.add(a, b)
	sys.print("c=%d,%d\n", c.x, c.y)

	// by ref, mutated on the library side
	rp := ref libpoint.Point{x: 3, y: -4}
	lib.scale(rp, 2)
	q := libpoint.Point{x: rp.x, y: rp.y}
	sys.print("rp=%d,%d norm=%d\n", rp.x, rp.y, lib.norm1(q))

	// a struct returned across the boundary, field read off the call
	sys.print("origin=%d,%d\n", lib.origin().x, lib.origin().y)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
