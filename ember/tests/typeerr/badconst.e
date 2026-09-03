module Badconst

import sys "sys"

// constant expressions that can't be folded: division by a zero
// literal, and a non-constant initializer.

func f() int {
	return 3
}

const Z = 1 / 0
const Y = f() + 1

func init() {
	sys.print("%d %d\n", Z, Y)
}
