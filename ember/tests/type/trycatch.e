module Trycatch

import sys "sys"
import draw "draw"

// try { body } catch e { handler }: a raise in the body or in any
// function it calls unwinds to the handler with the string in e; the
// VM's own faults (a nil dereference, an index out of bounds) are
// caught the same way; a raise inside a handler reaches the next one
// out.  the bounds case is exercised by hand only: the emulator's
// trace of it prints an address.

type P struct {
	x int
}

func mayfail(n int) int {
	if n < 0 {
		raise "negative"
	}
	return n * 2
}

func deep(n int) int {
	return mayfail(n) + 1
}

func rethrow(n int) int {
	try {
		return deep(n)
	} catch e {
		raise "wrapped: " + e
	}
}

func init(ctxt ref draw.Context, argv list string) {
	try {
		sys.print("%d\n", deep(3))
		sys.print("%d\n", deep(-1))
		sys.print("not reached\n")
	} catch e {
		sys.print("caught %s\n", e)
	}
	try {
		sys.print("%d\n", rethrow(-2))
	} catch e {
		sys.print("outer caught %s\n", e)
	}
	total := 0
	for i := -2; i < 3; i++ {
		try {
			total += mayfail(i)
		} catch {
			total += 100
		}
	}
	sys.print("total %d\n", total)
	var p ref P
	try {
		sys.print("%d\n", p.x)
	} catch e {
		sys.print("nil deref: %s\n", e)
	}
	try {
		try {
			raise "inner"
		} catch e {
			sys.print("inner handler %s\n", e)
			raise "from handler"
		}
	} catch e {
		sys.print("outer handler %s\n", e)
	}
	sys.print("done\n")
}
