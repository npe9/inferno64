module Nilsafe

// a?.f is nil when a is, else a.f (the whole postfix chain after it);
// a ?? b is a unless it is nil; both evaluate a twice

import sys "sys"
import draw "draw"

type Node struct {
	name string
	next ref Node
}

func (n ref Node) last() ref Node {
	if n.next == nil {
		return n
	}
	return n.next.last()
}

func init(ctxt ref draw.Context, args list string) {
	c := ref Node{name: "c"}
	b := ref Node{name: "b", next: c}
	a := ref Node{name: "a", next: b}
	var none ref Node
	sys.print("%s %s\n", a?.next?.name, a?.next?.next?.name ?? "-")
	sys.print("%d %d\n", none?.next == nil, a?.next?.next?.next == nil)
	sys.print("%s %s\n", none?.name ?? "nobody", a?.last()?.name)
	s := none?.last()?.name
	sys.print("%d %s\n", s == nil, s ?? "still nobody")
	xs := [2]string{"x", "y"}
	var ys []string
	sys.print("%d %d\n", len(ys ?? xs), len(xs ?? ys))
}
