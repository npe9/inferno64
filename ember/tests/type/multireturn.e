module Multireturn

import sys "sys"

func pair() (int, string) {
	return 1, "one"
}

func triple() (int, int, string) {
	return 5, 6, "seven"
}

func init() {
	n, s := pair()
	sys.print("n=%d s=%s\n", n, s)

	a, b, c := triple()
	sys.print("a=%d b=%d c=%s\n", a, b, c)
}
