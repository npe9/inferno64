module Uselists

import sys "sys"
import draw "draw"
import lists "lists"

// the header-only generic library module/lists.ei: every call is a
// template instantiated here, so no lists.dis exists or is loaded

func init(ctxt ref draw.Context, argv list string) {
	l := 3 :: 1 :: 2 :: nil
	sys.print("%d %d\n", lists.length(l), lists.nth(l, 2))
	r := lists.reverse(l)
	sys.print("%d\n", hd(r))
	both := lists.append(l, 9 :: 8 :: nil)
	sys.print("%d %d\n", lists.length(both), lists.nth(both, 4))
	sq := lists.mapl(l, func(x int) string { return sys.sprint("%d", x * x) })
	joined := lists.foldl(sq, "", func(a string, s string) string { return a + s + "," })
	sys.print("%s\n", joined)
	odd := lists.filter(both, func(x int) int { return x % 2 })
	xs := lists.toarray(odd)
	sys.print("%d %d\n", len(xs), xs[2])
	sorted := lists.sorta(xs, func(a int, b int) int { return a < b })
	sys.print("%d %d %d\n", sorted[0], sorted[1], sorted[2])
	sys.print("%d\n", lists.index(sorted, func(x int) int { return x == 3 }))
	back := lists.tolist(lists.mapa(sorted, func(x int) int { return x * 10 }))
	sys.print("%d %d\n", hd(back), lists.folda(sorted, 0, func(a int, x int) int { return a + x }))
}
