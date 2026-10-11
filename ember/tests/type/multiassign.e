module Multiassign

import sys "sys"

func pair(a int, b string) (int, string) {
	return a, b
}

func init() {
	n, s := pair(1, "one")
	sys.print("n=%d s=%s\n", n, s)

	// "a, b = f()" into *existing* variables, not just := into
	// fresh ones -- confirms it's a real re-store (different values
	// each time), not stale data from the first destructuring.
	n, s = pair(2, "two")
	sys.print("n=%d s=%s\n", n, s)
}
