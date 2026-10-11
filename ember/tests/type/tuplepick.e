module Tuplepick

// a tuple is assignable element by element, so a tag value widens
// to its pick inside one: returned, assigned, or passed

import sys "sys"
import draw "draw"

type Addr pick {
	None()
	Line(n int)
}

func address(s string) (string, ref Addr) {
	if s[0] == '$' {
		return s[1:], ref Addr.None{}
	}
	return s, ref Addr.Line{n: len(s)}
}

func show(p (string, ref Addr)) {
	s, a := p
	match a {
	case Addr.None:
		sys.print("%s none\n", s)
	case Addr.Line(n):
		sys.print("%s line %d\n", s, n)
	}
}

func init(ctxt ref draw.Context, args list string) {
	show(address("$x"))
	show(address("abc"))
	var p (string, ref Addr)
	p = ("q", ref Addr.Line{n: 7})
	show(p)
	s, a := address("$$")
	show((s, a))
}
