module Generic

// what "ember -X" makes of the pieces the checker rewrites most: a
// generic function's instantiation, an interface method call, a
// closure's captured local, and a method used as a value

import sys "sys"
import draw "draw"

type Named interface {
	name() string
}

type Tag string

func (t Tag) name() string {
	return string(t)
}

func first[T](l list T) T {
	return hd(l)
}

func label(n Named) string {
	return "[" + n.name() + "]"
}

func adder(base int) func(int) int {
	return func(x int) int {
		return base + x
	}
}

func init(ctxt ref draw.Context, argv list string) {
	t := Tag("one")
	f := adder(10)
	g := t.name
	sys.print("%s %s %d %s\n", first("a" :: "b" :: nil), label(t), f(5), g())
}
