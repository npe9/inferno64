module Fortwo

// for init; cond { with no post statement repeats the initializer's
// expression each time round: Limbo's while((s := f()) != nil)

import sys "sys"
import draw "draw"

var next = 0

func take() int {
	next++
	if next > 5 {
		return -1
	}
	return next * 10
}

func init(ctxt ref draw.Context, args list string) {
	total := 0
	for v := take(); v >= 0 {
		total += v
	}
	sys.print("%d %d\n", total, next)
	l := 3 :: 2 :: 1 :: nil
	for i, x := range l {
		sys.print("%d:%d ", i, x)
	}
	sys.print("\n")
}
