module Fntype

import sys "sys"

// an *anonymous* function-typed parameter -- "f"'s own declared type
// has no name for its "int" parameter, since it's a type, not a
// declaration.  see the check.c commit message for what this used to
// get silently wrong (every anonymous parameter's type was dropped
// entirely, not just left unnamed) and how it was confirmed both
// ways: "too many arguments" calling such a value, and an argument-
// mismatch error naming the wrong signature shape.
func apply(f func(int) int, x int) int {
	return x
}

func init() {
	sys.print("ok\n")
}
