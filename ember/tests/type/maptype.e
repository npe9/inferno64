module Maptype

// map[K]V: literals, store, read (zero when absent), the two-value
// lookup, delete, len, range, compound assignment, maps as values,
// int and string keys

import sys "sys"
import draw "draw"

func count(words []string) map[string]int {
	m := map[string]int{}
	for _, w := range words {
		m[w]++
	}
	return m
}

func init(ctxt ref draw.Context, args list string) {
	ages := map[string]int{"ann": 31, "bob": 27}
	ages["cy"] = 45
	ages["bob"] += 1
	sys.print("%d %d %d %d\n", ages["ann"], ages["bob"], ages["cy"], ages["nobody"])
	v, ok := ages["cy"]
	w, ok2 := ages["zed"]
	sys.print("%d %d %d %d\n", v, ok, w, ok2)
	delete(ages, "ann")
	sys.print("%d\n", len(ages))
	total := 0
	for k, n := range ages {
		total += n
		_ = k
	}
	sys.print("%d\n", total)
	names := 0
	for k := range ages {
		names += len(k)
	}
	sys.print("%d\n", names)

	sq := map[int]int{}
	for i := range 10 {
		sq[i] = i * i
	}
	sys.print("%d %d %d\n", sq[3], sq[9], len(sq))

	c := count([6]string{"a", "b", "a", "c", "a", "b"})
	sys.print("%d %d %d %d\n", c["a"], c["b"], c["c"], c["d"])

	var nested map[string]map[string]int
	nested = map[string]map[string]int{}
	nested["x"] = map[string]int{"one": 1}
	inner := nested["x"]
	inner["two"] = 2
	sys.print("%d %d\n", len(nested["x"]), nested["x"]["two"])
}
