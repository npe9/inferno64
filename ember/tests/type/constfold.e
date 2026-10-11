module Constfold

import sys "sys"

// constant folding: operators and conversions on literals fold at
// compile time (check.c confoldbin()/confoldcast()), so constants may
// be expressions, may refer to earlier constants, and may size
// arrays.  an integer literal wider than 32 bits is a big, as in
// limbo (int arithmetic is 32-bit at runtime: 2000000000 + 2000000000
// wraps).

const N = 4 * 2 + 1
const M = N * 2 - 3
const S = "ab" + "cd" + "!"
const F = 2.5 * 2.0 + 1.0
const B = big(1) << 33
const K = int(7.6) + int("12") - 3
const MASK = (1 << 8) - 1
const NEGMIN = -2147483647 - 1
const WIDE = 10000000000

var table = [N]int
var names = [M / 5]string{"x", "y", "z"}

func init() {
	sys.print("%d %d %s %g %bd %d %d\n", N, M, S, F, B, K, MASK)
	sys.print("%d %d %bd\n", len(table), len(names), WIDE)
	sys.print("%d %d\n", NEGMIN, NEGMIN < 0)
	sys.print("%s %bd %d\n", string(42) + "!", big(3) * big(4) + WIDE, int(byte(300)) + 1)

	// the same expressions at runtime give the same answers
	a := 4
	b := 2
	sys.print("%d %d\n", a * b + 1, (1 << 8) - 1 == MASK)
	x := 2000000000
	sys.print("wrap=%d\n", x + x)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
