module Copyerr

// copy wants two arrays of the same type and has no value

func f(a []int, b []string, s string) int {
	copy(a)
	copy(a, b)
	copy(s, a)
	n := copy(a, a)
	return n
}
