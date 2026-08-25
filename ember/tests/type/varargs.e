module Varargs

import sys "sys"

func plain() int {
	return 4
}

func init() {
	// a call used as the *last* argument to a vararg call, alongside
	// a preceding plain argument, followed by a second vararg call:
	// this exact shape once corrupted the *first* call's frame,
	// because callcom() (com.c) mutated the imported function's own
	// (shared, one-per-module) Decl.desc for the varargs frame
	// descriptor instead of a fresh, call-site-local one -- so
	// whichever such call was compiled *last* silently overwrote the
	// descriptor every earlier one's own instructions were generated
	// against.  fixed by dupdecl()ing it, matching limbo/ecom.c's
	// original (this port had dropped the dupdecl call).
	v1 := 1
	sys.print("x=%d p=%d\n", v1, plain())
	e := 7
	sys.print("e=%d\n", e)
}
