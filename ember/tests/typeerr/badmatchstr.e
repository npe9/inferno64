module Badmatchstr

import sys "sys"

// a duplicate string label (detected while sorting the labels, so
// only reachable once every label typechecks -- the type refusals
// live in badmatchstr2.e).

func f(s string) int {
	match s {
	case "a":
		return 1
	case "b", "a":
		return 2
	}
	return 0
}

func init() {
	sys.print("%d\n", f("a"))
}
