module Matchok

import sys "sys"
import draw "draw"

func classify(n int) string {
	match n {
	case 0:
		return "zero"
	case 1, 2, 3:
		return "small"
	default:
		return "big"
	}
}

func init(ctxt ref draw.Context, argv list string) {
	sys.print("%s\n", classify(2))
	sys.print("%s\n", classify(9))
	sys.print("%s\n", classify(0))
}
