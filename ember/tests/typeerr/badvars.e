module Badvars

// badvars.ei beside this file is the module's own interface: every
// variable it declares must exist here with the same type

var count int
var name int

func f() int {
	return count
}

type Point struct {
	x int
}

func g(x string) string {
	return x
}
