module Tmplclosure

// a template called inside a closure: its own locals are not the
// closure's captures (builtin.ei's Builder, sort and append, and a
// generic function of this module's own)

import sys "sys"
import draw "draw"

type Box[T] struct {
	v T
}

func hold[T](v T) ref Box[T] {
	b := ref Box[T]{v: v}
	return b
}

func apply(f func(int)) {
	f(3)
}

func init(ctxt ref draw.Context, args list string) {
	b := ref Builder{}
	apply(func(n int) {
		// an inline method of an interface type, inside a closure
		b.puts(sys.sprint("%d", n))
		b.putc(':')
		// a generic function of this module, inside a closure
		x := hold(n * 2)
		b.puts(sys.sprint("%d", x.v))
		// a builtin template, inside a closure
		a := append([]int{1}, n)
		sort(a, func(p int, q int) int {
			return q - p
		})
		b.puts(sys.sprint(" %d%d", a[0], a[1]))
		// a list conversion, inside a closure
		l := []int(n :: nil)
		b.puts(sys.sprint(" %d", l[0]))
	})
	sys.print("%s\n", b.string())
	// the same templates outside a closure still work
	c := ref Builder{}
	c.puts("x")
	y := hold("s")
	sys.print("%s%s\n", c.string(), y.v)
}
