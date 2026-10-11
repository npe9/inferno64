module Matchstr

import sys "sys"

// match on a string subject: the labels sort and binary-search by
// text (check.c casecmp(), com.c findlab()), the table is a Tcasec
// written as string data (disw.c), dispatch is ICASEC.  enough labels
// to exercise the VM's binary search (n > 2), a multi-label arm, a
// non-ASCII label, the empty string, default and no-default forms,
// and a subject computed at runtime rather than a literal.

func color(s string) int {
	match s {
	case "red":
		return 1
	case "green":
		return 2
	case "blue":
		return 3
	case "cyan", "magenta", "yellow":
		return 4
	case "black", "white":
		return 5
	case "":
		return 6
	case "grün":
		return 7
	default:
		return 0
	}
}

func nodefault(s string) string {
	r := "none"
	match s {
	case "a":
		r = "A"
	case "b":
		r = "B"
	}
	return r
}

func init() {
	words := [12]string{"red", "green", "blue", "cyan", "magenta", "yellow", "black", "white", "", "grün", "purple", "re"}
	for i := 0; i < len(words); i++ {
		sys.print("%s=%d ", words[i], color(words[i]))
	}
	sys.print("\n")

	// a subject built at runtime
	s := "gr"
	s = s + "een"
	sys.print("built=%d\n", color(s))

	sys.print("%s %s %s\n", nodefault("a"), nodefault("b"), nodefault("c"))

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
