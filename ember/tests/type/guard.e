module Guard

// match guards: "case pattern if cond:" -- when the guard fails the
// later arms are tried in order, the default last; binders are
// visible in the guard; the subject is evaluated once

import sys "sys"
import draw "draw"

type Expr pick {
	Num(v int)
	Neg(e ref Expr)
}

var evals = 0

func subject(e ref Expr) ref Expr {
	evals++
	return e
}

func classify(e ref Expr) string {
	match subject(e) {
	case Expr.Num(v) if v < 0:
		return "negative"
	case Expr.Num(v) if v == 0:
		return "zero"
	case Expr.Num(v):
		return sys.sprint("positive %d", v)
	case Expr.Neg(x) if x != nil:
		return "neg of " + classify(x)
	default:
		return "empty neg"
	}
}

func size(n int) string {
	match n {
	case 0:
		return "none"
	case 1...9 if n % 2 == 0:
		return "small even"
	case 1...9:
		return "small odd"
	default:
		return "big"
	}
}

func init(ctxt ref draw.Context, args list string) {
	sys.print("%s %s %s\n", classify(ref Expr.Num{v: -3}), classify(ref Expr.Num{v: 0}), classify(ref Expr.Num{v: 4}))
	sys.print("%s %s\n", classify(ref Expr.Neg{e: ref Expr.Num{v: 2}}), classify(ref Expr.Neg{e: nil}))
	sys.print("%d\n", evals)
	sys.print("%s %s %s %s\n", size(0), size(4), size(7), size(12))
}
