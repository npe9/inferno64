module Listarray

// "[]T(l)" is the list's elements in an array, and tolist(a) goes
// back; the builtin sort is stable

import sys "sys"
import draw "draw"

type Pair struct {
	k string
	n int
}

func init(ctxt ref draw.Context, args list string) {
	l := "a" :: "b" :: "c" :: nil
	a := []string(l)
	sys.print("%d %s%s%s\n", len(a), a[0], a[1], a[2])
	back := tolist(a)
	s := ""
	for ; back != nil; back = tl(back) {
		s += hd(back)
	}
	sys.print("%s\n", s)
	var empty list int
	e := []int(empty)
	sys.print("%d %d\n", len(e), len(tolist(e)))
	ns := 3 :: 1 :: 2 :: nil
	na := []int(ns)
	sort(na, func(x int, y int) int {
		return x - y
	})
	sys.print("%d%d%d\n", na[0], na[1], na[2])
	// the sort is stable: equal keys keep their order
	ps := [4]ref Pair
	ps[0] = ref Pair{k: "x", n: 1}
	ps[1] = ref Pair{k: "y", n: 1}
	ps[2] = ref Pair{k: "z", n: 0}
	ps[3] = ref Pair{k: "w", n: 1}
	sort(ps, func(p ref Pair, q ref Pair) int {
		return p.n - q.n
	})
	out := ref Builder{}
	for _, p := range ps {
		out.puts(p.k)
	}
	sys.print("%s\n", out.string())
}
