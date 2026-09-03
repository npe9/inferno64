module Lvalueop

import sys "sys"

// the compound-assignment, ++/--, and multi-assignment shapes of the
// same lvalue check tests/typeerr/lvalue.e covers for plain "=" --
// split out only because the compiler stops after 20 errors.

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
	sys.print("%d %d\n", p.x, xs[0])

	mkpoint().x, p.y = pair()
	p.x, f() = pair()
	5++
	f()--
	p.x + 1++
	5 += 1
	f() += 1
	len(xs) -= 1
	"abc"[1]++
	"abc"[1] += 1
	nil++
}
