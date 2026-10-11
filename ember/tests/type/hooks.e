module Hooks

import sys "sys"
import draw "draw"
import lib "libhook"

type Cell struct {
	n int
}

func init(ctxt ref draw.Context, argv list string) {
	cell := ref Cell{n: 0}
	lib.each([3]int{1, 2, 3}, func(x int) { cell.n += x })
	sys.print("total %d\n", cell.n)
	sys.print("%d\n", lib.apply(5))
	lib.hook = func(x int) int { return x + 100 }
	sys.print("%d\n", lib.apply(5))
	lib.hook = lib.maker(3)
	sys.print("%d count %d\n", lib.apply(5), lib.count)
	f := lib.maker(7)
	sys.print("%d\n", f(6))
}
