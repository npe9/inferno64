module Genface

// genface.ei beside this file declares a generic function: an
// interface cannot, since a generic is instantiated from its body

func mapa[T, U](xs []T, f func(T) U) []U {
	ys := [len(xs)]U
	for i := 0; i < len(xs); i++ {
		ys[i] = f(xs[i])
	}
	return ys
}

func plain(x int) int {
	return x
}
