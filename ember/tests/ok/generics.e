module Generics

type Pair[A, B] struct {
	first  A
	second B
}

type Stack[T] struct {
	items []T
	n     int
}

func swap[A, B](p Pair[A, B]) Pair[B, A] {
	return Pair[B, A]{first: p.second, second: p.first}
}

func map2[T, U](xs []T, f func(T) U) []U {
	var out []U
	for i := 0; i < len(xs); i++ {
		out[i] = f(xs[i])
	}
	return out
}

func (s ref Stack[T]) push(x T) {
	s.items[s.n] = x
	s.n++
}

func idents() {
	p := Pair[int, string]{first: 1, second: "one"}
	q := swap[int, string](p)
	r := swap(q)
}
