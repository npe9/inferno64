module Matchcond

// a match with no subject: the cases are conditions, tried in order

import sys "sys"
import draw "draw"

func size(n int) string {
	match {
	case n < 0:
		return "negative"
	case n == 0, n == 1:
		return "tiny"
	case n < 10:
		return "small"
	default:
		return "big"
	}
}

func init(ctxt ref draw.Context, args list string) {
	for _, n := range []int{-3, 0, 1, 5, 50} {
		sys.print("%d %s\n", n, size(n))
	}
	x := 7
	match {
	case x > 5 && x < 10:
		sys.print("mid\n")
	}
	// a break inside is the enclosing loop's
	total := 0
	for i := 0; i < 5; i++ {
		match {
		case i == 3:
			break
		default:
			total += i
		}
	}
	sys.print("%d\n", total)
}
