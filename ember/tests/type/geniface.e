module Genifacetest

// a generic interface: its type parameters are those of the struct
// behind it and of its converter, given outright at each conversion

import sys "sys"
import draw "draw"

type Container[T] interface {
	get() T
	put(x T)
}

type Cell[T] struct {
	v T
}

func (c ref Cell[T]) get() T {
	return c.v
}

func (c ref Cell[T]) put(x T) {
	c.v = x
}

type Pair struct {
	a, b int
}

func (p ref Pair) get() int {
	return p.a + p.b
}

func (p ref Pair) put(x int) {
	p.a = x
	p.b = x
}

func bump(c Container[int], n int) {
	for i := 0; i < n; i++ {
		c.put(c.get() + i)
	}
}

func init(ctxt ref draw.Context, args list string) {
	c := ref Cell[int]{v: 1}
	bump(c, 4)
	sys.print("cell %d\n", c.get())
	p := ref Pair{a: 1, b: 2}
	bump(p, 3)
	sys.print("pair %d %d\n", p.a, p.b)
	var s Container[string]
	s = ref Cell[string]{v: "a"}
	s.put(s.get() + "b")
	sys.print("%s\n", s.get())
	if cc := s.(ref Cell[string]); cc != nil {
		sys.print("asserted %s\n", cc.v)
	}
	var ci Container[int]
	ci = p
	sys.print("pair again %d %d\n", ci.get(), ci.(ref Cell[int]) == nil)
}
