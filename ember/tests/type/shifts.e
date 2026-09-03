module Shifts

import sys "sys"

// shifts and bit operations on int, big and byte, with an int shift
// count on every operand type (limbo's rule; "big(1) << 40" was
// refused as a type mismatch), including compound forms.

func init() {
	a := 17
	sys.print("%d %d %d %d %d\n", a % 5, a >> 2, a & 6, a ^ 3, a | 32)
	b := big(1) << 40
	b >>= 3
	c := big(6)
	c <<= 2
	sys.print("%bd %bd %bd\n", b, c, (big(1) << 62) >> 60)
	by := byte(3)
	by <<= 2
	sys.print("%d %d %d\n", int(by), int(by >> 1), int(byte(255) << 1))
	x := 1
	x <<= 3
	x |= 1
	x &= 0xff
	sys.print("x=%d neg=%d not=%d div=%d %d\n", x, -x, !0, -a / 4, a / -4)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
