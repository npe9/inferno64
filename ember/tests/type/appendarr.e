module Appendarr

// append(a, x) and append(a, xs...): a fresh array each time

import sys "sys"
import draw "draw"

func init(ctxt ref draw.Context, args list string) {
	var xs []int
	for i := range 5 {
		xs = append(xs, i * i)
	}
	ys := append(xs, [3]int{100, 200, 300}...)
	xs = append(xs, -1)
	sys.print("%d %d %d\n", len(xs), len(ys), xs[5])
	for _, y := range ys {
		sys.print("%d ", y)
	}
	sys.print("\n")
	names := [1]string{"first"}
	names = append(names, "second")
	sys.print("%s %s %d\n", names[0], names[1], len(names))
}
