module Usemaps

import sys "sys"
import draw "draw"
import maps "maps"
import lists "lists"

// the header-only generic hash map module/maps.ei: a self-referencing
// generic struct (Entry) and a struct of closures (Map), instantiated
// here for string and int keys; no maps.dis is loaded

func strhash(s string) int {
	h := 0
	for i := 0; i < len(s); i++ {
		h = h * 31 + s[i]
	}
	return h
}

func streq(a string, b string) int {
	return a == b
}

func inthash(x int) int {
	return x * 40503
}

func inteq(a int, b int) int {
	return a == b
}

func init(ctxt ref draw.Context, argv list string) {
	m := maps.newmap[string, int](4, strhash, streq)
	words := [7]string{"apple", "pear", "fig", "plum", "kiwi", "lime", "date"}
	for i := 0; i < len(words); i++ {
		maps.put(m, words[i], len(words[i]))
	}
	maps.put(m, "fig", 30)
	sys.print("%d %d %d\n", maps.size(m), maps.find(m, "fig").val, maps.find(m, "nope") == nil)
	sys.print("%d %d\n", maps.del(m, "pear"), maps.del(m, "pear"))
	ks := lists.sorta(lists.toarray(maps.keys(m)), func(a string, b string) int { return a < b })
	for i := 0; i < len(ks); i++ {
		sys.print("%s ", ks[i])
	}
	sys.print("\n")
	c := maps.newmap[int, string](1, inthash, inteq)
	for i := 0; i < 50; i++ {
		maps.put(c, i * 7, sys.sprint("v%d", i))
	}
	sys.print("%d %s %s %d\n", maps.size(c), maps.find(c, 0).val, maps.find(c, 49 * 7).val, len(c.buckets))
}
