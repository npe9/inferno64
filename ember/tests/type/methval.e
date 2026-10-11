module Methvaltest

// a method used as a value: the closure a programmer would write,
// the receiver evaluated once and captured

import sys "sys"
import draw "draw"

type Counter struct {
	n int
}

func (c ref Counter) get() int {
	return c.n
}

func (c ref Counter) add(x int, y int) int {
	return c.n + x + y
}

func (c ref Counter) bump() {
	c.n++
}

type Level int

func (l Level) label() string {
	if l == Level(0) {
		return "low"
	}
	return "high"
}

func mk(n int) ref Counter {
	return ref Counter{n: n}
}

func apply(f func(int, int) int, a int, b int) int {
	return f(a, b)
}

func twice(x int) int {
	return 2 * x
}

func apply2(f func(int) int, x int) int {
	return f(x)
}

func init(ctxt ref draw.Context, args list string) {
	c := ref Counter{n: 3}
	f := c.get
	sys.print("%d\n", f())
	g := c.add
	sys.print("%d %d\n", g(1, 2), apply(c.add, 10, 20))
	b := c.bump
	b()
	b()
	sys.print("%d %d\n", c.n, f())
	// a receiver that is not a name: evaluated once, when the value is made
	h := mk(5).get
	sys.print("%d %d\n", h(), h())
	// a method of a named type
	var l Level
	l = 1
	lab := l.label
	sys.print("%s %s\n", lab(), Level(0).label())
	// in an array of function values
	d := ref Counter{n: 10}
	fs := []func(int, int) int{c.add, d.add}
	sys.print("%d %d\n", fs[0](1, 1), fs[1](1, 1))
	// a plain function is a value the same way
	t := twice
	sys.print("%d %d\n", t(4), apply2(twice, 5))
}
