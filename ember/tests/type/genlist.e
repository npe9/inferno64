module Genlist

import sys "sys"
import draw "draw"

// a self-referencing generic struct: the instance Node[int] must
// exist before its own body is walked, so "next ref Node[T]" can
// name it -- the same way a non-generic recursive struct does

type Node[T] struct {
	val T
	next ref Node[T]
}

func (n ref Node[T]) length() int {
	if n.next == nil {
		return 1
	}
	return 1 + n.next.length()
}

func push[T](l ref Node[T], v T) ref Node[T] {
	return ref Node[T]{val: v, next: l}
}

func sum(l ref Node[int]) int {
	s := 0
	for p := l; p != nil; p = p.next {
		s += p.val
	}
	return s
}

func join(l ref Node[string]) string {
	s := ""
	for p := l; p != nil; p = p.next {
		s += p.val
	}
	return s
}

func init(ctxt ref draw.Context, argv list string) {
	var l ref Node[int]
	l = push(l, 1)
	l = push(l, 2)
	l = push(l, 3)
	sys.print("sum %d length %d\n", sum(l), l.length())
	var w ref Node[string]
	w = push(w, "c")
	w = push(w, "b")
	w = push(w, "a")
	sys.print("%s length %d\n", join(w), w.length())
}
