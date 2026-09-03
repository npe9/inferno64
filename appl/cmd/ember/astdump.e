module Astdump

import sys "sys"
import draw "draw"
import types "types"
import parse "parse"

// print a parsed module as ember -A does: indented s-expressions,
// one node per line, Oseq chains flattened, an "(aux" block for the
// third child.

func strprint(s string) string {
	out := "\""
	for i := 0; i < len(s); i++ {
		c := s[i]
		match c {
		case '\\', '"':
			out += sys.sprint("\\%c", c)
		case '\n':
			out += "\\n"
		case '\t':
			out += "\\t"
		default:
			out += sys.sprint("%c", c)
		}
	}
	return out + "\""
}

func indent(n int) string {
	s := ""
	for i := 0; i < n; i++ {
		s += "  "
	}
	return s
}

func astprint(n ref types.Node, ind int) {
	if n == nil {
		return
	}
	if n.op == types.Oseq {
		astprint(n.left, ind)
		astprint(n.right, ind)
		return
	}
	s := indent(ind) + "(" + types.opname(n.op)
	match n.op {
	case types.Oname, types.Odot:
		if n.sym != nil {
			s += " " + n.sym
		}
	case types.Oconst:
		if (n.flags & types.NSTR) != 0 {
			s += " " + strprint(n.sym)
		} else if (n.flags & types.NREAL) != 0 {
			s += sys.sprint(" %g", n.rval)
		} else {
			s += sys.sprint(" %bd", n.val)
		}
	}
	if n.left == nil && n.right == nil && n.aux == nil {
		sys.print("%s)\n", s)
		return
	}
	sys.print("%s\n", s)
	astprint(n.left, ind + 1)
	astprint(n.right, ind + 1)
	if n.aux != nil {
		sys.print("%s(aux\n", indent(ind + 1))
		astprint(n.aux, ind + 2)
		sys.print("%s)\n", indent(ind + 1))
	}
	sys.print("%s)\n", indent(ind))
}

func init(ctxt ref draw.Context, argv list string) {
	if argv == nil || tl(argv) == nil {
		astprint(parse.parse("/ember/tests/type/hello.e"), 0)
		return
	}
	for l := tl(argv); l != nil; l = tl(l) {
		astprint(parse.parse(hd(l)), 0)
	}
}
