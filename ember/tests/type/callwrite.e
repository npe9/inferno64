module Callwrite

import sys "sys"
import draw "draw"

// a write through a call result: get().x++, get().name = ... -- the
// call is materialized into a temp of its own type, never an int one

type P struct {
	x int
	name string
}

var keep ref P

func get() ref P {
	if keep == nil {
		keep = ref P{x: 1, name: "p"}
	}
	return keep
}

func init(ctxt ref draw.Context, argv list string) {
	get().x++
	get().x += 10
	get().name = "changed"
	for i := 0; i < 2000; i++ {
		get().x++
		s := sys.sprint("%d", i)
		if len(s) > 100 {
			sys.print("never\n")
		}
	}
	sys.print("%d %s\n", get().x, get().name)
}
