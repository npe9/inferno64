module Fold

import sys "sys"
import types "types"

// every importer of types.dis gets its own instance of it; the shared
// state (basic types, equivalence classes) lives in ONE, which the
// top-level module hands down
func usetypes(t Types) {
	types = t
}

// see fold.ei.  confoldbin() returns 0 and leaves the node alone on a
// division by a zero literal (the checker reports it).

func setconst(n ref types.Node, t ref types.Type) {
	n.op = types.Oconst
	n.left = nil
	n.right = nil
	n.aux = nil
	n.decl = nil
	n.ty = t
}

func toint(v big) big {
	return big(int(v))
}

func confoldbin(n ref types.Node) int {
	l := n.left
	r := n.right
	op := n.op
	match n.ty.kind {
	case types.Tint, types.Tbig, types.Tbyte:
		a := l.val
		b := r.val
		v := big(0)
		match op {
		case types.Oadd:
			v = a + b
		case types.Osub:
			v = a - b
		case types.Omul:
			v = a * b
		case types.Odiv, types.Omod:
			if b == big(0) {
				return 0
			}
			if op == types.Odiv {
				v = a / b
			} else {
				v = a % b
			}
		case types.Oand:
			v = a & b
		case types.Oor:
			v = a | b
		case types.Oxor:
			v = a ^ b
		case types.Olsh:
			v = a << int(b)
		case types.Orsh:
			v = a >> int(b)
		default:
			return 1
		}
		if n.ty.kind == types.Tint {
			v = toint(v)
		} else if n.ty.kind == types.Tbyte {
			v &= big(255)
		}
		t := n.ty
		setconst(n, t)
		n.flags = 0
		n.val = v
		return 1
	case types.Treal:
		x := l.rval
		y := r.rval
		z := 0.0
		match op {
		case types.Oadd:
			z = x + y
		case types.Osub:
			z = x - y
		case types.Omul:
			z = x * y
		case types.Odiv:
			z = x / y
		default:
			return 1
		}
		setconst(n, types.basic(types.Treal))
		n.flags = types.NREAL
		n.rval = z
		return 1
	case types.Tstring:
		if op != types.Oadd || l.sym == nil || r.sym == nil {
			return 1
		}
		s := l.sym + r.sym
		setconst(n, types.basic(types.Tstring))
		n.flags = types.NSTR
		n.sym = s
		return 1
	}
	return 1
}

func confoldcast(n ref types.Node) {
	l := n.left
	to := n.ty
	from := l.ty
	if from == nil || from.kind == types.Tarray || to.kind == types.Tarray {
		return
	}
	if from.kind == types.Tstring {
		if l.sym == nil {
			return
		}
		match to.kind {
		case types.Tint, types.Tbig, types.Tbyte:
			v := big(l.sym)
			setconst(n, to)
			n.flags = 0
			if to.kind == types.Tint {
				n.val = toint(v)
			} else if to.kind == types.Tbyte {
				n.val = v & big(255)
			} else {
				n.val = v
			}
			return
		case types.Treal:
			r := real(l.sym)
			setconst(n, types.basic(types.Treal))
			n.flags = types.NREAL
			n.rval = r
			return
		}
		return
	}
	match to.kind {
	case types.Tint, types.Tbig, types.Tbyte:
		v := big(0)
		if from.kind == types.Treal {
			// big(real) rounds to nearest, as the Dis conversion
			// (and the C compiler's (Long)(r +- 0.5)) does
			v = big(l.rval)
		} else {
			v = l.val
		}
		setconst(n, to)
		n.flags = 0
		if to.kind == types.Tint {
			v = toint(v)
		} else if to.kind == types.Tbyte {
			v &= big(255)
		}
		n.val = v
		return
	case types.Treal:
		r := 0.0
		if from.kind == types.Treal {
			r = l.rval
		} else {
			r = real(l.val)
		}
		setconst(n, types.basic(types.Treal))
		n.flags = types.NREAL
		n.rval = r
		return
	case types.Tstring:
		if from.kind == types.Treal {
			return
		}
		s := sys.sprint("%bd", l.val)
		setconst(n, types.basic(types.Tstring))
		n.flags = types.NSTR
		n.sym = s
		return
	}
}

func litname(name string) ref types.Type {
	match name {
	case "int":
		return types.basic(types.Tint)
	case "big":
		return types.basic(types.Tbig)
	case "real":
		return types.basic(types.Treal)
	case "byte":
		return types.basic(types.Tbyte)
	case "string":
		return types.basic(types.Tstring)
	}
	return nil
}

func foldconstexpr(n ref types.Node) int {
	if n == nil {
		return 0
	}
	match n.op {
	case types.Oconst:
		if n.ty == nil {
			if (n.flags & types.NSTR) != 0 {
				n.ty = types.basic(types.Tstring)
			} else if (n.flags & types.NREAL) != 0 {
				n.ty = types.basic(types.Treal)
			} else if n.val > big(2147483647) || n.val < big(-2147483647) - big(1) {
				n.ty = types.basic(types.Tbig)
			} else {
				n.ty = types.basic(types.Tint)
			}
		}
		return 1
	case types.Oneg:
		if foldconstexpr(n.left) == 0 || (n.left.flags & types.NSTR) != 0 {
			return 0
		}
		flags := n.left.flags
		t := n.left.ty
		if (flags & types.NREAL) != 0 {
			r := -n.left.rval
			setconst(n, t)
			n.rval = r
		} else {
			v := -n.left.val
			setconst(n, t)
			n.val = v
		}
		n.flags = flags
		return 1
	case types.Oadd, types.Osub, types.Omul, types.Odiv, types.Omod, types.Oand, types.Oor, types.Oxor, types.Olsh, types.Orsh:
		if foldconstexpr(n.left) == 0 || foldconstexpr(n.right) == 0 {
			return 0
		}
		t := n.left.ty
		tr := n.right.ty
		if (n.op == types.Olsh || n.op == types.Orsh) && tr.kind == types.Tint && (t.kind == types.Tbig || t.kind == types.Tbyte) {
			tr = t
		}
		if t != tr {
			return 0
		}
		n.ty = t
		confoldbin(n)
		return n.op == types.Oconst
	case types.Ocall:
		if n.left.op != types.Oname || n.right == nil || n.right.op == types.Oseq {
			return 0
		}
		t := litname(n.left.sym)
		if t == nil {
			return 0
		}
		if foldconstexpr(n.right) == 0 {
			return 0
		}
		n.op = types.Ocast
		n.left = n.right
		n.right = nil
		n.ty = t
		confoldcast(n)
		return n.op == types.Oconst
	}
	return 0
}
