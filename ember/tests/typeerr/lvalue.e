module Lvalue

import sys "sys"

// every LHS shape that is NOT storage, in one file: the lvalue
// validity check (check.c's chklval()) must reject each one with a
// real diagnostic, never a compiler fatal and never silence -- "5 = 3"
// compiled and ran silently before this check existed.  the .err
// golden pins every message, one per line, in source order.

type Point struct {
	x int
	y int
}

func mkpoint() Point {
	return Point{x: 1, y: 2}
}

func f() int {
	return 3
}

func pair() (int, int) {
	return 1, 2
}

func init() {
	p := Point{x: 1, y: 2}
	xs := [3]int{1, 2, 3}
	s := "abc"
	t := (1, 2)
	sys.print("%d %d %d %d\n", p.x, xs[0], len(s), t.t0)

	5 = 3
	"abc" = s
	nil = p
	f() = 3
	f = nil
	mkpoint = mkpoint
	sys.print = nil
	sys = nil
	Point = p
	p.x + 1 = 5
	-p.x = 3
	len(xs) = 3
	xs[0:1] = xs
	(1, 2) = t
	mkpoint().x = 5
	"abc"[0] = 'x'
}
