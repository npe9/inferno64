module Defer

// defer f(args): the arguments are evaluated at the defer, the calls
// run last-first at every return and at the end of a void function;
// a defer not reached is not run; the return value is fixed before
// the defers run

import sys "sys"
import draw "draw"

func say(s string) {
	sys.print("%s\n", s)
}

func order() {
	defer say("first deferred")
	defer say("second deferred")
	say("body")
}

func early(n int) int {
	defer say("early's defer")
	if n > 0 {
		return n
	}
	defer say("not reached for n > 0")
	return -n
}

func args() {
	x := 1
	defer sys.print("x was %d\n", x)
	x = 2
	say("x is now 2")
}

func loop() {
	for i := range 3 {
		defer sys.print("loop %d\n", i)
	}
	say("loop done")
}

func pair() (int, string) {
	defer say("pair's defer")
	return 7, "seven"
}

type Counter struct {
	n int
}

func (c ref Counter) bump() {
	c.n++
}

func method() int {
	c := ref Counter{n: 10}
	defer c.bump()
	return c.n
}

func init(ctxt ref draw.Context, argv list string) {
	order()
	sys.print("%d\n", early(5))
	sys.print("%d\n", early(-3))
	args()
	loop()
	n, s := pair()
	sys.print("%d %s\n", n, s)
	sys.print("%d\n", method())
	match v := early(2); v {
	case 2:
		say("match init two")
	default:
		say("match init other")
	}
}
