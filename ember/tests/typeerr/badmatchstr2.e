module Badmatchstr2

import sys "sys"

// string match refusals: an int label on a string subject, a name
// (which parses as a tag pattern) as a label, a string label on an
// int subject.

func f(s string, n int, v string) int {
	match s {
	case "a":
		return 1
	case 3:
		return 3
	case v:
		return 4
	}
	match n {
	case "x":
		return 5
	}
	return 0
}

func init() {
	sys.print("%d\n", f("a", 1, "v"))
}
