module Varloop

import sys "sys"

// "var x T" without an initializer is zero every time it executes,
// not just on the function's first pass: inside a loop each iteration
// starts from nil/0 (the previous value released), for refs, lists,
// numbers, strings and value structs alike.

type P struct {
	n int
	s string
}

func init() {
	out := ""
	for i := 0; i < 3; i++ {
		var l list int
		var r ref P
		var k int
		var s string
		var v P
		var t (int, string)
		out += sys.sprint("[%d %d %d %d %d %d]", len(l), r == nil, k, len(s), v.n, t.t0)
		l = i :: l
		r = ref P{n: i, s: "x"}
		k = i + 10
		s += "abc"
		v.n = i + 1
		v.s = "y"
		t = (i + 1, "z")
	}
	sys.print("%s\n", out)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
