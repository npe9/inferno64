module Redeclare

// := may not redeclare a name in the same scope; an inner scope may shadow

func f(a int) int {
	n := 1
	n := 2
	a := 3
	if n > 0 {
		n := 4
		return n
	}
	x, y := n, a
	x, z := y, 5
	return x + z
}
