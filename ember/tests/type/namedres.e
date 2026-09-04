module Namedres

// named results: the names are locals, zero at entry, and a bare
// return returns them

import sys "sys"
import draw "draw"

func divmod(a int, b int) (q int, r int) {
	q = a / b
	r = a % b
	return
}

func split(s string) (head string, rest string) {
	for i := 0; i < len(s); i++ {
		if s[i] == ' ' {
			head = s[0:i]
			rest = s[i + 1:]
			return
		}
	}
	head = s
	return
}

func pair() (a, b int) {
	a = 1
	b = 2
	return
}

func one(x int) (n int) {
	if x < 0 {
		return
	}
	n = x * 2
	return n
}

func plain(a int) (int, string) {
	return a, "plain"
}

func init(ctxt ref draw.Context, args list string) {
	q, r := divmod(7, 2)
	sys.print("%d %d\n", q, r)
	h, t := split("hello world")
	sys.print("%s|%s|\n", h, t)
	x, y := pair()
	sys.print("%d %d\n", x, y)
	sys.print("%d %d\n", one(-1), one(4))
	n, s := plain(3)
	sys.print("%d %s\n", n, s)
}
