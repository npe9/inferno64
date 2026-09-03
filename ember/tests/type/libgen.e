module Libgen

import sys "sys"

// the library half of tests/type/usegen.e: generic functions whose
// bodies the interface (tests/type/libgen.ei) carries, instantiated
// in each importer; templates call each other and the library's
// plain functions (count, tag) through the importer's alias

func mapa[T, U](xs []T, f func(T) U) []U {
	ys := [len(xs)]U
	for i := 0; i < len(xs); i++ {
		ys[i] = f(xs[i])
	}
	return ys
}

func reduce[T, A](xs []T, acc A, f func(A, T) A) A {
	for i := 0; i < len(xs); i++ {
		acc = f(acc, xs[i])
	}
	return acc
}

func filterl[T](l list T, keep func(T) int) list T {
	var out list T
	for ; l != nil; l = tl(l) {
		if keep(hd(l)) != 0 {
			out = hd(l) :: out
		}
	}
	return reverse(out)
}

func reverse[T](l list T) list T {
	var out list T
	for ; l != nil; l = tl(l) {
		out = hd(l) :: out
	}
	return out
}

func count(l list int) int {
	return len(l)
}

func describe[T](xs []T, name string) string {
	return sys.sprint("%s has %d", name, len(xs)) + tag()
}

func tag() string {
	return "!"
}
