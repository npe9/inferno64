module Pickvalue2

// the by-value pick rule inside a function body (declarations are
// clean, so bodies are checked): see pickvalue.e for the others

type Shape pick {
	Circle(r int)
	Rect(w int, h int)
}

func f() int {
	var v Shape
	var l list Shape
	c := chan Shape
	return 0
}
