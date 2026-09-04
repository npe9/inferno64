module Vectest

// Vec[T] from the builtin library: an array that grows by doubling,
// so building one in a loop is linear

import sys "sys"
import draw "draw"

type P struct {
	n int
}

func init(ctxt ref draw.Context, args list string) {
	v := ref Vec[int]{}
	for i := 0; i < 20; i++ {
		v.push(i * i)
	}
	sys.print("%d %d %d\n", v.len(), v.at(0), v.at(19))
	a := v.slice()
	sys.print("%d %d\n", len(a), a[3])
	v.set(0, 100)
	sys.print("%d %d\n", v.at(0), a[0])
	sort(v.slice(), func(x int, y int) int { return y - x })
	sys.print("%d %d\n", v.at(0), v.at(v.len() - 1))
	v.reset()
	v.push(7)
	sys.print("%d %d\n", v.len(), v.at(0))

	// a Vec of refs, and one of a struct value
	ps := ref Vec[ref P]{}
	for i := 0; i < 3; i++ {
		ps.push(ref P{n: i})
	}
	total := 0
	for _, p := range ps.slice() {
		total += p.n
	}
	sys.print("%d %d\n", ps.len(), total)

	ss := ref Vec[string]{}
	ss.push("a")
	ss.push("b")
	b := ref Builder{}
	for _, s := range ss.slice() {
		b.puts(s)
	}
	sys.print("%s\n", b.string())
}
