module Generics

import sys "sys"

type Pair[A, B] struct {
	first  A
	second B
}

func init() {
	a := ref Pair[int, string]{first: 1, second: "one"}
	b := ref Pair[int, string]{first: 2, second: "two"}
	c := ref Pair[int, int]{first: 5, second: 99}
	sys.print("a=%d,%s b=%d,%s c=%d,%d\n",
		a.first, a.second, b.first, b.second, c.first, c.second);
}
