module Resulttest

// Result[T] from the builtin library: Ok(v) or Err(e), matched or
// propagated with ?

import sys "sys"
import draw "draw"

func parse(s string) ref Result[int] {
	if len(s) == 0 {
		return ref Result[int].Err{e: "empty"}
	}
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return ref Result[int].Err{e: "not a digit: " + sys.sprint("%c", c)}
		}
		n = n * 10 + c - '0'
	}
	return ref Result[int].Ok{v: n}
}

func sum(a string, b string) ref Result[int] {
	x := parse(a)?
	y := parse(b)?
	return ref Result[int].Ok{v: x + y}
}

func show(r ref Result[int]) string {
	match r {
	case Result[int].Ok(v):
		return sys.sprint("ok %d", v)
	case Result[int].Err(e):
		return "error: " + e
	}
	return "?"
}

func init(ctxt ref draw.Context, args list string) {
	sys.print("%s\n", show(sum("12", "30")))
	sys.print("%s\n", show(sum("12", "3x")))
	sys.print("%s\n", show(sum("", "1")))
}
