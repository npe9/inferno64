module Recursive

import sys "sys"

// self-referential and forward-referenced struct types: check()'s
// pre-pass installs a placeholder type for every struct/pick name
// before any declaration is processed, and typedec() folds each body
// into its placeholder (re-sizing it, since an earlier "ref B" field
// may have sized it empty).  a linked list built and walked through
// "next ref Node", and mutually referencing A/B declared in either
// order.

type Node struct {
	val int
	next ref Node
}

type A struct {
	name string
	b ref B
}

type B struct {
	n int
	back ref A
	next ref B
}

func push(l ref Node, v int) ref Node {
	return ref Node{val: v, next: l}
}

func sum(l ref Node) int {
	t := 0
	for p := l; p != nil; p = p.next {
		t += p.val
	}
	return t
}

func length(l ref Node) int {
	if l == nil {
		return 0
	}
	return 1 + length(l.next)
}

func init() {
	var l ref Node
	for i := 1; i <= 10; i++ {
		l = push(l, i)
	}
	sys.print("len=%d sum=%d head=%d second=%d\n", length(l), sum(l), l.val, l.next.val)

	a := ref A{name: "a"}
	a.b = ref B{n: 1, back: a}
	a.b.next = ref B{n: 2, back: a}
	sys.print("%s %d %d %s\n", a.name, a.b.n, a.b.next.n, a.b.next.back.name)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
