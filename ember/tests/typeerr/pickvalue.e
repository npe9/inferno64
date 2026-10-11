module Pickvalue

// a pick has no size of its own, only each tag does: it exists only
// behind a ref, and every by-value use is refused

type Shape pick {
	Circle(r int)
	Rect(w int, h int)
}

type Box struct {
	s Shape
}

var g Shape

func area(s Shape) int {
	return 0
}

func ok(s ref Shape) int {
	var l list ref Shape
	l = s :: l
	return len(l)
}

func f() {
	var v Shape
	var l list Shape
}
