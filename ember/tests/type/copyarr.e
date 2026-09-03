module Copyarr

// copy(dst, src): Dis slicela as a statement, go's copy name

import sys "sys"
import draw "draw"

type P struct {
	x int
	s string
}

func init(ctxt ref draw.Context, args list string) {
	a := [5]int{1, 2, 3, 4, 5}
	b := [5]int
	copy(b, a)
	b[0] = 9
	sys.print("%d %d %d %d\n", a[0], b[0], b[4], len(b))
	copy(b[1:], a[0:3])
	for i := range b {
		sys.print("%d ", b[i])
	}
	sys.print("\n")
	// overlapping, backwards and forwards
	copy(a[1:], a[0:4])
	copy(b[0:], b[2:])
	for i := range a {
		sys.print("%d/%d ", a[i], b[i])
	}
	sys.print("\n")
	// pointers move with refcounts intact
	ps := [3]ref P{ref P{x: 1, s: "one"}, ref P{x: 2, s: "two"}, nil}
	qs := [4]ref P
	copy(qs[1:], ps)
	sys.print("%d %s %d\n", qs[1].x, qs[2].s, qs[3] == nil)
	ss := [2]string{"a", "b"}
	copy(ss, grow(ss))
	sys.print("%s %s\n", ss[0], ss[1])
	ms := [4]string{"w", "x", "y", "z"}
	mt := [4]string
	merge(ms, mt, 4)
	sys.print("%s %s %s %s / %s %s\n", ms[0], ms[1], ms[2], ms[3], mt[0], mt[3])
	e := [2]int
	try {
		copy(e, a)
	} catch msg {
		sys.print("caught %s\n", msg)
	}
}

// copy in a function other than init, on parameters: the builtin's
// immediate 0 was once encoded as 0(fp), the frame's return link,
// and this faulted with a bounds error
func merge(a []string, b []string, r int) {
	copy(b, a[0:r])
	copy(a[1:], b[0:r - 1])
}

func grow(s []string) []string {
	t := [2]string
	t[0] = s[1]
	t[1] = s[0] + "!"
	return t
}
