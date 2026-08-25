module Hello

import sys "sys"
import draw "draw"

func init(ctxt ref draw.Context, argv []string) {
	fd := sys.fildes(1)
	sys.fprint(fd, "hello, inferno\n")
}
