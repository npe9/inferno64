module Libhook

// the library half of tests/type/hooks.e: function-typed variables
// and parameters across a module boundary, with unnamed parameters
// in the interface's function types (tests/type/libhook.ei)

var hook func(int) int
var count int

func each(xs []int, f func(int)) {
	for i := 0; i < len(xs); i++ {
		f(xs[i])
	}
}

func apply(x int) int {
	count++
	if hook == nil {
		return x
	}
	return hook(x)
}

func maker(k int) func(int) int {
	return func(x int) int { return x * k }
}
