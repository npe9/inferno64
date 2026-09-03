module Capturewrite

// a closure captures an enclosing variable by value: assigning to
// it inside the closure would change only the copy, so it is refused

func f() int {
	n := 0
	total := 0
	inc := func() {
		n++
		total = total + 1
	}
	inc()
	return n + total
}

func g(k int) func() int {
	return func() int {
		k += 1
		return k
	}
}
