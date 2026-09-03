module Transcaptures

import sys "sys"

// shared state for a closure: a captured variable is a copy, so a
// closure that must change something the outer code sees holds a ref
type Cell struct {
	v int
}

// closurecaptures.e covers by-value captures one level deep (a closure
// reaching directly into its own immediate enclosing function's frame).
// this file covers *transitive* captures: a closure reaching into a
// frame two or more levels out, through one or more intermediate
// closures -- previously rejected outright ("closures capturing through
// more than one enclosing function are not yet supported").
//
// mechanism (check.c's echk() Oname case): walk curclosure's own
// ->enclosing chain out until reaching whichever function/closure
// genuinely owns the referenced decl directly.  every closure strictly
// between the innermost one and that owner also gets the decl added to
// its *own* captures -- a pure pass-through with no direct source
// reference of its own (addcapture()'s n==nil case) -- so com.c can
// read the value one frame at a time when each level's own tfnptr gets
// built (com.c's ecom(), Oname/Dfn case): a level whose ->enclosing
// directly owns the decl reads it as a plain local; a level whose
// ->enclosing is itself an intermediate closure reads it through that
// closure's own env instead.

// depth 2, pure pass-through: mid() never itself references x, only its
// own nested closure does -- mid's own capture of x exists purely as a
// forwarding slot with zero source-level uses of its own.
func outer1() func() int {
	x := 41
	mid := func() func() int {
		return func() int {
			return x
		}
	}
	return mid()
}

// depth 2, but mid *also* directly uses x itself -- a real use and a
// forwarding role in the same closure at once.  addcapture()'s dedup by
// decl identity must not give x two separate fields in mid's own capty.
func outer2() func() int {
	x := 7
	mid := func() func() int {
		y := x * 10
		return func() int {
			return x + y
		}
	}
	return mid()
}

// depth 3: two intermediate closures, neither directly owning z --
// every level in the middle needs its own forwarding capture.
func outer3() func() int {
	z := 100
	a := func() func() func() int {
		return func() func() int {
			return func() int {
				return z
			}
		}
	}
	b := a()
	return b()
}

// escaping through two frames: the innermost closure is returned out
// through both outer4 and mkescaped, called only after both have
// exited -- the actual point of a heap-allocated env, same as
// closurecaptures.e's own escaping cases but one level deeper.
func outer4() func() int {
	w := 9
	mid := func() func() int {
		return func() int {
			return w * 2
		}
	}
	return mid()
}

func mkescaped() func() int {
	return outer4()
}

// mutation timing: each level copies by value at the moment *its own*
// tfnptr is constructed, not at the moment it's called or returned.
// mid's own env gets x's value when "mid := func()..." runs (x==1,
// before either later assignment) -- the two later writes to x, one
// before mid() is called and one after, are both invisible to inner,
// same as closurecaptures.e's own depth-1 mutation-invisibility cases,
// just pinned here for the depth-2, copy-at-each-hop chain specifically.
func outer5() func() int {
	x := 1
	mid := func() func() int {
		return func() int { return x }
	}
	x = 2
	inner := mid()
	x = 3
	return inner
}

// a write *inside* the intermediate closure's own body, to the same
// variable the innermost closure also reads: mid's "x = 99" writes into
// mid's own env copy of x (mid captures x directly, one level deep,
// same as any other depth-1 capture).  x is a ref cell, since a
// captured variable itself may not be assigned inside a closure:
// mid's write is seen by outer (f=99) and by inner, constructed
// after it, reading through mid's own env per the transitive-capture
// mechanism.
func outer6() func() int {
	x := ref Cell{v: 1}
	mid := func() func() int {
		x.v = 99
		return func() int { return x.v }
	}
	inner := mid()
	sys.print("f=%d\n", x.v)
	return inner
}

func init() {
	f1 := outer1()
	sys.print("a=%d\n", f1())

	f2 := outer2()
	sys.print("b=%d\n", f2())

	f3 := outer3()
	sys.print("c=%d\n", f3())

	f4 := mkescaped()
	sys.print("d=%d\n", f4())

	f5 := outer5()
	sys.print("e=%d\n", f5())

	f6 := outer6()
	sys.print("g=%d\n", f6())
}
