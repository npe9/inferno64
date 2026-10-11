module Cat

// appl/cmd/cat.b in Ember

import sys "sys"
import draw "draw"

var stdout ref sys.FD

func init(ctxt ref draw.Context, args list string) {
	stdout = sys.fildes(1)
	args = tl(args)
	if args == nil {
		args = "-" :: nil
	}
	for file := range args {
		if file != "-" {
			fd := sys.open(file, sys.OREAD)
			if fd == nil {
				sys.fprint(sys.fildes(2), "cat: cannot open %s: %r\n", file)
				raise "fail:bad open"
			}
			cat(fd, file)
		} else {
			cat(sys.fildes(0), "<stdin>")
		}
	}
}

func cat(fd ref sys.FD, file string) {
	buf := [sys.ATOMICIO]byte
	n := 0
	for {
		n = sys.read(fd, buf, len(buf))
		if n <= 0 {
			break
		}
		if sys.write(stdout, buf, n) < n {
			sys.fprint(sys.fildes(2), "cat: write error: %r\n")
			raise "fail:write error"
		}
	}
	if n < 0 {
		sys.fprint(sys.fildes(2), "cat: error reading %s: %r\n", file)
		raise "fail:read error"
	}
}
