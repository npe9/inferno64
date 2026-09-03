module Capture

// capture by reference, the cases that matter: a counter shared by
// two closures and the owner, a parameter captured and written, a
// loop body's variable fresh per iteration, a closure created in a
// loop reading the loop variable after the loop, a transitive
// capture two closures deep, a match binder, a captured variable
// read by a defer after the return value is fixed

import sys "sys"
import draw "draw"

type Expr pick {
	Num(v int)
	Neg(e ref Expr)
}

func counter() (func() int, func() int) {
	n := 0
	inc := func() int {
		n++
		return n
	}
	get := func() int {
		return n
	}
	n = 100
	return inc, get
}

func accumulate(xs []int) int {
	total := 0
	each := func(x int) {
		total += x
	}
	for _, x := range xs {
		each(x)
	}
	return total
}

func fresh() []func() int {
	fs := [3]func() int
	for i := range 3 {
		v := i * 10
		fs[i] = func() int {
			v++
			return v
		}
	}
	return fs
}

func shared() []func() int {
	fs := [3]func() int
	for i := 0; i < 3; i++ {
		fs[i] = func() int {
			return i
		}
	}
	return fs
}

func deep() int {
	x := 1
	outer := func() func() {
		return func() {
			x *= 3
		}
	}
	inner := outer()
	inner()
	inner()
	return x
}

func binder(e ref Expr) int {
	match e {
	case Expr.Num(v):
		bump := func() {
			v += 5
		}
		bump()
		return v
	default:
		return -1
	}
}

func deferred() int {
	r := 1
	defer func() {
		r = r * 100
	}()
	r = 7
	return r
}

func param(p int) int {
	twice := func() {
		p = p * 2
	}
	twice()
	twice()
	return p
}

func init(ctxt ref draw.Context, args list string) {
	inc, get := counter()
	sys.print("%d %d %d\n", inc(), inc(), get())
	sys.print("%d\n", accumulate([4]int{1, 2, 3, 4}))
	fs := fresh()
	sys.print("%d %d %d %d\n", fs[0](), fs[1](), fs[2](), fs[0]())
	gs := shared()
	sys.print("%d %d\n", gs[0](), gs[2]())
	sys.print("%d\n", deep())
	sys.print("%d\n", binder(ref Expr.Num{v: 2}))
	sys.print("%d\n", deferred())
	sys.print("%d\n", param(3))
}
