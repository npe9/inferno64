module Boolerr

// bool is its own type: no arithmetic on it, no int-to-bool
// conversion, logical operators want conditions

func f(s string, b bool, n int) int {
	x := b + 1
	c := bool(n)
	if s && b {
		return 1
	}
	y := !s
	var k int = b
	return x + k + int(c) + int(y)
}
