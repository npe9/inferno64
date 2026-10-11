module Spread

import sys "sys"
import draw "draw"

// a multi-valued call as a call's only argument: its results are
// the arguments, one per parameter (f(g()), go's rule)

type Acc struct {
	total int
}

func divmod(a int, b int) (int, int) {
	return a / b, a % b
}

func show(q int, r int) string {
	return sys.sprint("%d r%d", q, r)
}

func three() (int, string, int) {
	return 1, "two", 3
}

func (a ref Acc) add(x int, name string, y int) {
	a.total += x + y + len(name)
}

func report(c chan string, q int, r int) {
	c <- show(q, r)
}

func init(ctxt ref draw.Context, argv list string) {
	sys.print("%s\n", show(divmod(17, 5)))
	acc := ref Acc{total: 0}
	acc.add(three())
	sys.print("%d\n", acc.total)
	c := chan string
	spawn func(c chan string) { report(c, divmod(9, 4)) }(c)
	sys.print("%s\n", <-c)
	sys.print("%s\n", show(divmod(divmod(100, 7))))
}
