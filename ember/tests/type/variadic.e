module Variadic

// typed variadic functions: the trailing arguments arrive as an
// array, an array is passed through with xs..., and a variadic
// function value works the same way

import sys "sys"
import draw "draw"

func join(sep string, parts ...string) string {
	s := ""
	for i, p := range parts {
		if i > 0 {
			s += sep
		}
		s += p
	}
	return s
}

func sum(xs ...int) int {
	t := 0
	for _, x := range xs {
		t += x
	}
	return t
}

func count(label string, xs ...int) string {
	return sys.sprint("%s:%d", label, len(xs))
}

func init(ctxt ref draw.Context, args list string) {
	sys.print("%s\n", join(", ", "a", "b", "c"))
	sys.print("%s|%s\n", join("-"), join("-", "one"))
	sys.print("%d %d\n", sum(), sum(1, 2, 3, 4))
	xs := [3]int{10, 20, 30}
	sys.print("%d\n", sum(xs...))
	sys.print("%s %s\n", count("none"), count("some", 5, 6))
	f := sum
	sys.print("%d\n", f(7, 8))
}
