module Usemaps

import sys "sys"
import draw "draw"
import maps "maps"
import lists "lists"

// the header-only generic hash mp module/maps.ei: a self-referencing
// generic struct (Entry) and a struct of closures (Map), instantiated
// here for string and int keys with its methods; no maps.dis is loaded

func init(ctxt ref draw.Context, argv list string) {
	m := maps.newmap[string, int](4, maps.strhash, maps.streq)
	words := [7]string{"apple", "pear", "fig", "plum", "kiwi", "lime", "date"}
	for i := 0; i < len(words); i++ {
		m.put(words[i], len(words[i]))
	}
	m.put("fig", 30)
	sys.print("%d %d %d\n", m.size(), m.find("fig").val, m.find("nope") == nil)
	sys.print("%d %d\n", m.del("pear"), m.del("pear"))
	ks := lists.sorta(lists.toarray(m.keys()), func(a string, b string) int { return a < b })
	for i := 0; i < len(ks); i++ {
		sys.print("%s ", ks[i])
	}
	sys.print("\n")
	c := maps.newmap[int, string](1, maps.inthash, maps.inteq)
	for i := 0; i < 50; i++ {
		c.put(i * 7, sys.sprint("v%d", i))
	}
	sys.print("%d %s %s %d\n", c.size(), c.find(0).val, c.find(49 * 7).val, len(c.buckets))
}
