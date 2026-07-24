module Hello

// legacy limbo interfaces, resolved from /module (milestone 2)
import sys "sys.m"
import draw "draw.m"

func init(ctxt ref draw.Context, argv []string) {
	fd := sys.fildes(1)
	sys.fprint(fd, "hello, inferno\n")
}
