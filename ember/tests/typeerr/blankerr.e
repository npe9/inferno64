module Blankerr

// "_" is never a value: it cannot be read, only assigned to

func f() (int, int) {
	return 1, 2
}

func g() int {
	_, y := f()
	x := _
	return x + y + _
}
