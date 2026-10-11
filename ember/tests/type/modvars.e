module Modvars

import sys "sys"
import draw "draw"
import lib "libvars"

// reading and writing an imported module's variables: lib.count and
// friends address the library's own data through the module link,
// so a change on either side is seen by the other

func init(ctxt ref draw.Context, argv list string) {
	sys.print("%s\n", lib.describe())
	sys.print("count %d name %s\n", lib.count, lib.name)
	lib.bump()
	lib.bump()
	sys.print("count %d after two bumps\n", lib.count)
	lib.count = 40
	lib.name = "renamed"
	lib.origin = lib.Point{x: 3, y: 4}
	lib.origin.y = 5
	sys.print("%s\n", lib.describe())
	sys.print("bump returns %d, then count %d\n", lib.bump(), lib.count)
	p := lib.origin
	sys.print("copy (%d,%d)\n", p.x, p.y)
}
