module Expr

const mask = 0xff
const bits = 0b1010
const oct = 0o17
const big = 1_000_000
const pi = 3.14159
const avo = 6.02e23
const half = .5
const ch = 'x'
const nl = '\n'
const uni = '\u00e9'

var s = "a string with \"escapes\" and \t tabs"
var raw = `a raw
string`

func ops(a, b int) int {
	c := a*b + a/b - a%b
	c = a<<2 | b>>1 & mask ^ ~a
	if a == b || a != c && a <= b && a >= c || !(a < b) && a > c {
		c = -a
	}
	c += 1
	c -= 2
	c *= 3
	c /= 4
	c %= 5
	c &= 6
	c |= 7
	c ^= 8
	c <<= 1
	c >>= 1
	c++
	c--
	return c
}

func slices(xs []int) []int {
	a := xs[1]
	b := xs[1:3]
	c := xs[:3]
	d := xs[1:]
	e := xs[:]
	tup := (a + 1)
	return b
}

func multi() (int, string) {
	return 1, "one"
}

func uses() {
	n, s := multi()
	n, s = multi()
	loop:
	for {
		break loop
	}
	for i := 0; ; i++ {
		if i > 3 {
			continue
		}
		break
	}
}
