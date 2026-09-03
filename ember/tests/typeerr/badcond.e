module Badcond

// an if or for condition is an int

type P struct {
	x int
}

func f(s string, p ref P, b byte) int {
	if s {
		return 1
	}
	if p {
		return 2
	}
	for b {
		return 3
	}
	if p != nil && s == "" {
		return 4
	}
	return 0
}
