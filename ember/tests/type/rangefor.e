module Rangefor

import sys "sys"
import draw "draw"

// for i[, v] := range e: over an array or string the index and the
// element, over a list the element, over an int the count from 0;
// break and continue as in any for

func init(ctxt ref draw.Context, argv list string) {
	xs := [4]int{10, 20, 30, 40}
	sum := 0
	for i, v := range xs {
		sum += i * v
	}
	sys.print("%d\n", sum)
	for i := range xs {
		sys.print("%d ", xs[i])
	}
	sys.print("\n")
	l := "a" :: "b" :: "c" :: nil
	for s := range l {
		sys.print("%s", s)
	}
	sys.print("\n")
	n := 0
	for i := range 5 {
		if i == 3 {
			continue
		}
		n += i
	}
	sys.print("%d\n", n)
	for i, c := range "héllo" {
		if c == 'l' {
			sys.print("l at %d\n", i)
			break
		}
	}
}
