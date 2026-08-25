module Hello

import sys "sys"
import draw "draw"

func init(ctxt ref draw.Context, argv list string) {
	sys.print("hello, inferno\n")
}
