module Structeq

// "a == b" on two struct values: the field-by-field comparison, with
// each operand evaluated once

import sys "sys"
import draw "draw"

type Inner struct {
	a int
	s string
}

type P struct {
	x int
	in Inner
}

type Empty struct {
}

type Level int

func (l Level) label() string {
	return "l"
}

var calls = 0

func mk(n int) P {
	calls++
	return P{x: n, in: Inner{a: n, s: "s"}}
}

func init(ctxt ref draw.Context, args list string) {
	a := P{x: 1, in: Inner{a: 2, s: "t"}}
	b := P{x: 1, in: Inner{a: 2, s: "t"}}
	c := P{x: 1, in: Inner{a: 3, s: "t"}}
	sys.print("%d %d %d %d\n", a == b, a == c, a != c, a != b)
	calls = 0
	sys.print("%d calls=%d\n", mk(4) == mk(4), calls)
	sys.print("%d %d\n", mk(5) != mk(6), a.in == b.in)
	e1 := Empty{}
	e2 := Empty{}
	sys.print("%d\n", e1 == e2)
	// a named type still compares as its base
	var l Level
	l = 1
	sys.print("%d %s\n", l == Level(1), l.label())
}
