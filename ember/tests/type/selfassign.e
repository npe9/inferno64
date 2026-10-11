module Selfassign

import sys "sys"

// a literal assigned to a variable it reads (see com.c's scom Oas
// case): a ref literal chaining onto itself, a linked-list insertion
// through a field, an array element, and a value literal swapping a
// struct's own fields.  each used to overwrite the destination before
// reading it.

type Node struct {
	val int
	next ref Node
}

type Point struct {
	x int
	y int
}

func length(l ref Node) int {
	n := 0
	for p := l; p != nil; p = p.next {
		n++
		if n > 100 {
			return -1
		}
	}
	return n
}

func init() {
	// chaining: l = ref Node{next: l}
	var l ref Node
	for i := 1; i <= 5; i++ {
		l = ref Node{val: i, next: l}
	}
	sys.print("len=%d head=%d\n", length(l), l.val)

	// insertion after the head through a field
	l.next = ref Node{val: 99, next: l.next}
	sys.print("len=%d second=%d third=%d\n", length(l), l.next.val, l.next.next.val)

	// an array element
	xs := [1]ref Node
	xs[0] = ref Node{val: 1, next: nil}
	xs[0] = ref Node{val: 2, next: xs[0]}
	sys.print("len=%d first=%d\n", length(xs[0]), xs[0].val)

	// a value literal reading the destination: a swap
	p := Point{x: 1, y: 2}
	p = Point{x: p.y, y: p.x}
	sys.print("p=%d,%d\n", p.x, p.y)
	q := ref Point{x: 3, y: 4}
	q.x, q.y = q.y, q.x
	sys.print("q=%d,%d\n", q.x, q.y)
	a, b := 1, 2
	a, b = b, a
	sys.print("a=%d b=%d\n", a, b)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
