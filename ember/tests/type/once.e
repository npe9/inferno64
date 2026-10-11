module Oncetest

// the operand of ?. and of a type assertion is evaluated once, even
// when it is a call: a plain name is mentioned twice, anything else
// becomes the parameter of a closure

import sys "sys"
import draw "draw"

type Node struct {
	name string
	next ref Node
	n int
}

type Shape interface {
	area() int
}

type Rect struct {
	w, h int
}

func (r ref Rect) area() int {
	return r.w * r.h
}

func (nd ref Node) bump() {
	nd.n++
}

func (nd ref Node) label() string {
	return "<" + nd.name + ">"
}

var calls = 0

func get(nd ref Node) ref Node {
	calls++
	return nd
}

func shape(s Shape) Shape {
	calls++
	return s
}

func init(ctxt ref draw.Context, args list string) {
	b := ref Node{name: "b", next: nil, n: 0}
	a := ref Node{name: "a", next: b, n: 0}
	// a name: the usual guard
	sys.print("%s %s\n", a?.name, a?.next?.name)
	var none ref Node
	sys.print("%d %d\n", none?.next == nil, none?.name == "")
	// a call: once
	calls = 0
	sys.print("%s calls=%d\n", get(a)?.next?.name, calls)
	calls = 0
	sys.print("%s calls=%d\n", get(a)?.label(), calls)
	calls = 0
	get(a)?.bump()
	get(none)?.bump()
	sys.print("n=%d calls=%d\n", a.n, calls)
	calls = 0
	sys.print("%d calls=%d\n", get(none)?.next?.n, calls)
	// a type assertion on a call: once
	var s Shape
	s = ref Rect{w: 2, h: 3}
	calls = 0
	r := shape(s).(ref Rect)
	sys.print("%d calls=%d\n", r.w, calls)
	calls = 0
	r2, ok := shape(s).(ref Rect)
	sys.print("%d %d calls=%d\n", r2.h, ok, calls)
	calls = 0
	if rr := shape(nil).(ref Rect); rr == nil {
		sys.print("nil calls=%d\n", calls)
	}
}
