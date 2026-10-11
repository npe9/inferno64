module Globalref

import sys "sys"
import lex "lex"

// module variables with a declared (not inferred) type of ref to a
// struct, local and imported, followed by scalar globals: the
// declared type was never sized, so the ref globals had zero width
// and shared their slot with the int after them (found by the
// self-hosted parser's look-ahead globals).

type P struct {
	x int
}

var p ref P
var q ref P
var tok ref lex.Tok
var n = 7
var s = "seven"

func init() {
	n++
	p = ref P{x: 1}
	q = p
	tok = ref lex.Tok{t: 3, line: 1, pos: 2, sym: "id", ival: big(0), rval: 0.0, text: nil}
	n++
	sys.print("n=%d p.x=%d q.x=%d tok=%d %s s=%s\n", n, p.x, q.x, tok.t, tok.sym, s)
	p.x = 5
	sys.print("n=%d q.x=%d\n", n, q.x)
}
