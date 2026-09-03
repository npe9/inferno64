module Callclosure

import sys "sys"
import libpoint "libpoint"

// three shapes that used to be refused or mis-lowered: a closure
// literal called at once ("func(...){...}(args)"), a closure literal
// (and a function-typed variable) spawned, and a generic function
// inferred over an imported struct type with indexed and literal
// arguments -- the last two were echk() running twice over already-
// rewritten nodes (inferfn() then Ocall's own argument loop), which
// the check-once mark on every node (NCHECKED) now prevents.

func first[T](xs []T) T {
	return xs[0]
}

func swap[T](a T, b T) (T, T) {
	return b, a
}

func init() {
	// called at once, capturing a local
	base := 100
	v := func(k int) int {
		return base + k
	}(5)
	sys.print("v=%d\n", v)

	// spawned closures reporting through a channel
	done := chan int
	for i := 0; i < 3; i++ {
		spawn func(k int) {
			done <- k * k
		}(i)
	}
	s := 0
	for i := 0; i < 3; i++ {
		s += <-done
	}
	sys.print("squares=%d\n", s)

	// a function-typed variable spawned
	f := func(c chan int, n int) {
		c <- n * 2
	}
	spawn f(done, 21)
	sys.print("doubled=%d\n", <-done)

	// generics over an imported type, with an element and a literal
	// as arguments
	ps := [2]libpoint.Point{libpoint.Point{x: 1, y: 2}, libpoint.Point{x: 3, y: 4}}
	p := first(ps)
	q, r := swap(ps[0], ps[1])
	sys.print("%d %d %d %d\n", p.x, q.x, r.x, first([1]string{"s"}) == "s")

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
