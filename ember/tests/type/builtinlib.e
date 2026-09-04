module Builtinlib

// the builtin library's Builder and sort

import sys "sys"
import draw "draw"

func init(ctxt ref draw.Context, args list string) {
	b := ref Builder{}
	for i := 0; i < 5; i++ {
		b.puts("ab")
	}
	b.putc(':')
	sys.print("%s %d\n", b.string(), b.len())
	b.reset()
	b.puts("x")
	sys.print("%s %d\n", b.string(), b.len())

	a := []int{5, 3, 9, 1, 4, 1, 8, 2, 7, 6, 0}
	sort(a, func(x int, y int) int { return x - y })
	s := ref Builder{}
	for _, v := range a {
		s.puts(sys.sprint("%d", v))
	}
	sys.print("%s\n", s.string())
	sort(a, func(x int, y int) int { return y - x })
	sys.print("%d %d\n", a[0], a[len(a) - 1])

	w := []string{"pear", "apple", "fig", "date"}
	sort(w, func(x string, y string) int {
		if x < y {
			return -1
		}
		if x > y {
			return 1
		}
		return 0
	})
	sys.print("%s %s %s %s\n", w[0], w[1], w[2], w[3])

	// a long array, to reach the recursive part of the sort
	n := 200
	big := [n]int
	for i := 0; i < n; i++ {
		big[i] = (i * 37) % n
	}
	sort(big, func(x int, y int) int { return x - y })
	ok := 1
	for i := 0; i < n; i++ {
		if big[i] != i {
			ok = 0
		}
	}
	sys.print("sorted %d\n", ok)
}
