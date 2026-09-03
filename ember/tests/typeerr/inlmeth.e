module Inlmeth

// inlmeth.ei beside this file gives a method of an ordinary type a
// body: only a generic type's method may carry one in an interface

type Box struct {
	v int
}

func (b ref Box) get() int {
	return b.v
}

func helper(x int) int {
	return x + 1
}
