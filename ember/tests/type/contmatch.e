module Contmatch

import sys "sys"

// two things the self-hosted lexer needed: "continue" inside a match
// (or alt) arm inside a loop continues the LOOP (it used to take the
// match's slot, an unpatched jump that crashed the compiler), and a
// match case label may be a named constant, local or from an
// interface ("case Eid:", "case lex.Eid:"), not only a literal.

const A = 1
const B = 2
const C = 3
const STOP = 9

func classify(n int) string {
	match n {
	case A:
		return "a"
	case B, C:
		return "b-or-three"
	case STOP:
		return "stop"
	}
	return "other"
}

func init() {
	seen := ""
	for i := 0; i < 12; i++ {
		match i % 4 {
		case 0:
			continue
		case 1:
			seen += "1"
		default:
			if i > 8 {
				break
			}
			seen += "x"
		}
		seen += "."
	}
	sys.print("seen=%s\n", seen)

	c := chan[4] int
	for k := 0; k < 4; k++ {
		c <- k
	}
	got := ""
	for n := 0; n < 4; n++ {
		alt {
		case v := <-c:
			if v % 2 == 0 {
				continue
			}
			got += string(v)
		}
		got += ";"
	}
	sys.print("got=%s\n", got)
	sys.print("%s %s %s %s %s\n", classify(1), classify(2), classify(3), classify(9), classify(4))

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
