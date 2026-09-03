module Boolglobal

// a global bool with an initializer goes through the data section
// (it once hit "can't dis global type bool"); an uninitialised one
// is false

import sys "sys"
import draw "draw"

var on = true
var off = false
var unset bool
var flags = [3]bool{true, false, true}

func init(ctxt ref draw.Context, args list string) {
	sys.print("%d %d %d\n", on, off, unset)
	n := 0
	for i := range flags {
		if flags[i] {
			n++
		}
	}
	sys.print("%d set\n", n)
	on = !on
	if !on && !unset {
		sys.print("flipped\n")
	}
}
