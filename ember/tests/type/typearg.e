module Typearg

import sys "sys"
import draw "draw"

// type arguments in expression position may be any type: a function,
// list, chan or unsized array type, or a bare ref, not only a name

type Box[T] struct {
	val T
}

type P struct {
	x int
}

func twice(x int) int {
	return 2 * x
}

func init(ctxt ref draw.Context, argv list string) {
	b := ref Box[func(int) int]{val: twice}
	a := Box[[]int]{val: [2]int{4, 5}}
	l := Box[list int]{val: 3 :: nil}
	c := Box[chan int]{val: chan[1] int}
	r := Box[ref P]{val: ref P{x: 9}}
	c.val <- 8
	sys.print("%d %d %d %d %d\n", b.val(21), a.val[1], hd(l.val), <-c.val, r.val.x)
	xs := [3]int{7, 8, 9}
	i := 1
	sys.print("%d\n", xs[i + 1])
}
