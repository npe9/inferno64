module Methodvalue

import sys "sys"

// a method reached through a receiver is not a value (a function
// value would be a func type); using it as one is refused instead of
// producing an uncallable variable.

type P struct {
	x int
}

func (p ref P) get() int {
	return p.x
}

func init() {
	p := ref P{x: 7}
	g := p.get
	sys.print("%d\n", g())
}
