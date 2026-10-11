module Ifacetest

// interfaces: a struct or pick with the right methods converts to
// the interface at an assignment, argument, return or literal; calls
// go through it; nil is the zero value; a pick's tags share methods

import sys "sys"
import draw "draw"

type Shape interface {
	area() int
	name() string
}

type Rect struct {
	w int
	h int
}

func (r ref Rect) area() int {
	return r.w * r.h
}

func (r ref Rect) name() string {
	return "rect"
}

type Square struct {
	side int
}

func (s ref Square) area() int {
	return s.side * s.side
}

func (s ref Square) name() string {
	return "square"
}

type Expr pick {
	Num(v int)
	Neg(e ref Expr)
}

func (e ref Expr) area() int {
	match e {
	case Expr.Num(v):
		return v
	case Expr.Neg(x):
		return -x.area()
	}
	return 0
}

func (e ref Expr) name() string {
	return "expr"
}

type Greeter interface {
	greet(who string)
}

type Loud struct {
	n int
}

func (l ref Loud) greet(who string) {
	l.n++
	sys.print("HELLO %s (%d)\n", who, l.n)
}

func describe(s Shape) string {
	return sys.sprint("%s:%d", s.name(), s.area())
}

func biggest(shapes []Shape) Shape {
	var best Shape
	for _, s := range shapes {
		if best == nil || s.area() > best.area() {
			best = s
		}
	}
	return best
}

func choose(n int) Shape {
	if n > 0 {
		return ref Rect{w: n, h: 2}
	}
	return ref Square{side: 3}
}

func init(ctxt ref draw.Context, args list string) {
	var s Shape
	sys.print("%d\n", s == nil)
	s = ref Rect{w: 3, h: 4}
	sys.print("%s\n", describe(s))
	sys.print("%s %s\n", describe(ref Square{side: 5}), describe(ref Expr.Neg{e: ref Expr.Num{v: 7}}))
	shapes := [3]Shape{ref Rect{w: 1, h: 1}, ref Square{side: 4}, ref Rect{w: 2, h: 9}}
	sys.print("%s\n", describe(biggest(shapes)))
	sys.print("%s %s\n", describe(choose(5)), describe(choose(0)))
	l := ref Loud{n: 0}
	var g Greeter
	g = l
	g.greet("world")
	g.greet("again")
	sys.print("%d\n", l.n)
}
