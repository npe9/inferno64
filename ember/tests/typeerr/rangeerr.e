module Rangeerr

// range needs an array, string, list or int, and the right number of names

type P struct {
	x int
}

func f(p P, l list int, r real) int {
	for i := range p {
		return i
	}
	for i, v := range l {
		return i + v
	}
	for i, j := range 3 {
		return i + j
	}
	for i := range r {
		return i
	}
	x := range l
	return x
}
