module Refcalldot

import sys "sys"

// two pre-existing bugs found while bringing up interface methods:
//
// 1. a field read straight off a REF-returning call ("mkref().y",
//    Oind(Oadd(mkref(), off)) -- the pointer bare under the Oadd, not
//    Oadr-wrapped like calldot.e's value case) went through ecom's
//    general Oadd arithmetic, which put the call's ref result in an
//    int-typed temp: a live pointer outside the frame's pointer mp,
//    never released -- the heap was corrupt by the next allocation
//    ("alloc:D2B ... in block").  fixcallbase() (com.c) now handles
//    the bare shape too, materializing the rvalue in a temp of its
//    own type.
//
// 2. a method called on a method call's result ("p.get().val()")
//    failed to compile ("get is not declared"): Ocall's bound-method
//    desugar prepends the receiver to the argument list, and the
//    argument loop then echk()'d it a second time -- by which point
//    the inner call's callee was a bare method Oname no scope lookup
//    can find.  the receiver is now checked exactly once.

type P struct {
	x int
	y int
}

func mkref() ref P {
	return ref P{x: 5, y: 6}
}

func (p ref P) get() ref P {
	return p
}

func (p ref P) sum() int {
	return p.x + p.y
}

func (p ref P) bump() ref P {
	p.x++
	return p
}

func init() {
	// 1: field off a ref-returning call, then many allocations to
	// give a corrupt heap every chance to show
	y := mkref().y
	sys.print("y=%d\n", y)
	for i := 0; i < 1000; i++ {
		q := mkref()
		q.x = i
	}
	sys.print("x=%d\n", mkref().x)

	// 2: methods chained on method results, and on a plain call's
	p := ref P{x: 1, y: 2}
	sys.print("sum=%d\n", p.get().sum())
	sys.print("chain=%d\n", p.bump().bump().bump().sum())
	sys.print("callsum=%d\n", mkref().sum())
	sys.print("field=%d\n", p.get().get().x)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
