module Blank

// "_", the blank identifier: a discarded result in :=, =, and range;
// each use is a fresh hidden local, so it may appear any number of
// times in one scope and never be read

import sys "sys"
import draw "draw"

func divmod(a int, b int) (int, int) {
	return a / b, a % b
}

func init(ctxt ref draw.Context, args list string) {
	q, _ := divmod(17, 5)
	_, r := divmod(17, 5)
	sys.print("%d %d\n", q, r)
	_, _ = divmod(1, 1)
	q, _ = divmod(23, 7)
	_, r = divmod(23, 7)
	sys.print("%d %d\n", q, r)
	_ := divmod(9, 4)
	_ = q
	n := 0
	for _, c := range "abc" {
		n += c
	}
	xs := [3]string{"x", "y", "z"}
	for _, s := range xs {
		sys.print("%s", s)
	}
	for i, _ := range xs {
		sys.print("%d", i)
	}
	sys.print(" %d\n", n)
}
