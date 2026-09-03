module Chkdump

import sys "sys"
import draw "draw"
import types "types"
import parse "parse"
import math "math"
import check "check"

// parse and check a file, then print the checked tree as ember -C
// does: astdump's format with " :type" on every typed node and
// " @store" on every resolved name.  -I dir arguments set the
// interface search path; the built-in module directory is last.

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
			// the exact bits, as ember -C prints them
			b := [8]byte
			math.export_real(b, [1]real{n.rval})
			s += " "
			for i := 0; i < 8; i++ {
				s += sys.sprint("%02x", int(b[i]))
			}
		} else {
			s += sys.sprint(" %bd", n.val)
		}
	}
	if n.ty != nil {
		s += " :" + types.tprint(n.ty)
	}
	if n.op == types.Oname && n.decl != nil {
		s += " @" + types.storename(n.decl.store)
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

func run(file string) {
	check.usetypes(types)
	tree := parse.parse(file)
	if tree == nil || parse.errors() != 0 {
		return
	}
	if check.check(tree, file) != 0 {
		return
	}
	astprint(tree, 0)
}

func init(ctxt ref draw.Context, argv list string) {
	var files list string
	l := argv
	if l != nil {
		l = tl(l)
	}
	for ; l != nil; l = tl(l) {
		if hd(l) == "-I" && tl(l) != nil {
			l = tl(l)
			check.addincpath(hd(l))
			continue
		}
		files = hd(l) :: files
	}
	check.addincpath("/ember/module")
	if files == nil {
		run("/ember/tests/type/hello.e")
		return
	}
	var r list string
	for ; files != nil; files = tl(files) {
		r = hd(files) :: r
	}
	for ; r != nil; r = tl(r) {
		run(hd(r))
	}
}
