module Raise

import sys "sys"
import draw "draw"

// raise ends the process with a string error; there is no catch, so
// the program prints what it can first and the runtime reports the
// rest

func boom(where string) {
	sys.print("about to raise in %s\n", where)
	raise "fail:" + where
}

func init(ctxt ref draw.Context, argv list string) {
	sys.print("start\n")
	boom("boom")
	sys.print("not reached\n")
}
