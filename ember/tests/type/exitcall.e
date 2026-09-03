module Exitcall

// exit() ends the process at once, like Limbo's exit: nothing after
// it runs, not even the caller's remaining statements, and a
// function ending in exit() needs no return

import sys "sys"
import draw "draw"

func fatal(s string) int {
	sys.print("fatal: %s\n", s)
	exit()
}

func deeper(n int) int {
	if n == 0 {
		return fatal("stopping")
	}
	return deeper(n - 1) + 1
}

func init(ctxt ref draw.Context, args list string) {
	sys.print("start\n")
	n := deeper(3)
	sys.print("not reached %d\n", n)
}
