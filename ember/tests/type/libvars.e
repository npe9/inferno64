module Libvars

// the library half of tests/type/modvars.e: module variables that a
// client reads and writes through the import alias.  tests/type/
// libvars.ei is this module's own interface, so exactly the
// variables it declares are exported, laid out as its .mp record;
// "hidden" below is not in it and stays private.

type Point struct {
	x int
	y int
}

var count int
var name = "libvars"
var origin Point
var hidden = 7

func bump() int {
	count++
	hidden++
	return count
}

func describe() string {
	return sys_sprint(name, count, origin.x, origin.y, hidden)
}

import sys "sys"

func sys_sprint(n string, c int, x int, y int, h int) string {
	return sys.sprint("%s count=%d origin=(%d,%d) hidden=%d", n, c, x, y, h)
}
