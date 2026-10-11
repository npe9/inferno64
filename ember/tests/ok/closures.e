module Closures

func adder(n int) func(int) int {
	return func(x int) int {
		return x + n
	}
}

func compose(f, g func(int) int) func(int) int {
	return func(x int) int {
		return f(g(x))
	}
}

func apply(xs []int, f func(int) int) {
	for i := 0; i < len(xs); i++ {
		xs[i] = f(xs[i])
	}
}

func run() int {
	inc := adder(1)
	dbl := func(x int) int { return 2 * x }
	both := compose(inc, dbl)
	return both(20)
}
