module Niltest

import sys "sys"

// "nil" now flows through the same predeclared-global mechanism
// limbo/decls.c's own nildecl uses -- mknil() (ast.c) builds an
// ordinary Oname referencing a single Tany-typed Dglobal (nildecl,
// check.c's check()), instead of a dedicated Onil AST op with its
// own codegen. echk()'s existing Oname case and ecom()'s existing
// Oname/Dglobal case both apply unchanged; the only new plumbing
// needed was giving nildecl a real global-data-segment slot when a
// file actually uses it (modcom(), com.c), gated on refs>0 the same
// way an unused import is skipped.

type Point struct {
	x, y int
}

func nilpoint() ref Point {
	return nil
}

func init() {
	p := nilpoint()
	if p == nil {
		sys.print("p is nil\n")
	} else {
		sys.print("p is NOT nil (bug)\n")
	}

	p = ref Point{x: 1, y: 2}
	if p != nil {
		sys.print("p is non-nil after assignment, p.x=%d p.y=%d\n", p.x, p.y)
	} else {
		sys.print("p is nil after assignment (bug)\n")
	}

	// a poisoned local before an uninitialized-nil read, to catch a
	// stale-frame-slot bug the same way the Sys_sleep investigation
	// found one -- if nil's global read ever silently returned
	// garbage instead of the real (zero-filled) global, this would
	// very likely surface it.
	poison := 12345
	poison = 0
	sys.print("poison=%d\n", poison)
	q := nilpoint()
	if q == nil {
		sys.print("q is nil (poison check passed)\n")
	} else {
		sys.print("q is NOT nil (poison check FAILED)\n")
	}
}
