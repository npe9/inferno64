module Loadtest

import sys "sys"
import rand "rand"

// explicit "load": the runtime side of imports.  an import alias is
// autoloaded from its PATH at init only if it's referenced directly;
// "load Rand path" (or "load rand path") is the same ILOAD with a path
// of the program's choosing, yielding an ordinary value of the module
// type -- nil on failure -- that member calls go through exactly like
// the alias.  rand.dis is a real limbo-compiled library, so a
// successful load also proves Ember's link signatures match limbo's
// for a non-builtin module (link.c refuses a mismatch with nil).

func roll(r Rand, n int) int {
	// a module value as a parameter, called through
	return r.rand(n)
}

func init() {
	r := load Rand "/dis/lib/rand.dis"
	if r == nil {
		sys.print("load failed\n")
		return
	}
	sys.print("loaded\n")
	r.init(42)
	a := r.rand(100)
	b := r.rand(100)
	sys.print("in range: %d %d\n", a >= 0 && a < 100, b >= 0 && b < 100)
	sys.print("via param: %d\n", roll(r, 10) < 10)

	// a bad path yields nil, no exception
	bad := load rand "/dis/lib/nosuchmodule.dis"
	sys.print("bad is nil: %d\n", bad == nil)

	// reassigning the import alias itself, then calling through it
	rand = load Rand "/dis/lib/rand.dis"
	rand.init(7)
	sys.print("alias: %d\n", rand.rand(5) < 5)

	// the module value can be dropped
	r = nil
	sys.print("dropped: %d\n", r == nil)

	// a builtin through load, same as the autoloaded import
	s := load Sys "$Sys"
	s.print("sys via load\n")

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
