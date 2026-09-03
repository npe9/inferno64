module Uuencode

// appl/cmd/uuencode.b in Ember

import sys "sys"
import draw "draw"

func fatal(s string) {
	sys.fprint(sys.fildes(2), "%s\n", s)
	exit()
}

func usage() {
	fatal("usage: uuencode [ sourcefile ] remotefile")
}

func init(ctxt ref draw.Context, argv list string) {
	var fd ref sys.FD
	var mode int

	argv = tl(argv)
	if argv == nil {
		usage()
	}
	if tl(argv) != nil {
		fd = sys.open(hd(argv), sys.OREAD)
		if fd == nil {
			fatal(sys.sprint("cannot open %s", hd(argv)))
		}
		ok, d := sys.fstat(fd)
		if ok < 0 {
			fatal(sys.sprint("cannot stat %s: %r", hd(argv)))
		}
		if (d.mode & sys.DMDIR) != 0 {
			fatal("cannot uuencode a directory")
		}
		mode = d.mode
		argv = tl(argv)
	} else {
		fd = sys.fildes(0)
		mode = 0666
	}
	if tl(argv) != nil {
		usage()
	}
	sys.print("begin %o %s\n", mode, hd(argv))
	encode(fd)
	sys.print("end\n")
}

const LEN = 45

func code(c int) byte {
	return byte((c & 0x3f) + ' ')
}

func encode(ifd ref sys.FD) {
	var c, d, e int

	ofd := sys.fildes(1)
	ib := [LEN]byte
	ob := [4 * LEN / 3 + 2]byte
	for {
		n := sys.read(ifd, ib, LEN)
		if n < 0 {
			fatal("cannot read input file: %r")
		}
		if n == 0 {
			break
		}
		i := 0
		ob[i] = code(n)
		i++
		for j := 0; j < n; j += 3 {
			c = int(ib[j])
			ob[i] = code((0 << 6) & 0x00 | (c >> 2) & 0x3f)
			i++
			if j + 1 < n {
				d = int(ib[j + 1])
			} else {
				d = 0
			}
			ob[i] = code((c << 4) & 0x30 | (d >> 4) & 0x0f)
			i++
			if j + 2 < n {
				e = int(ib[j + 2])
			} else {
				e = 0
			}
			ob[i] = code((d << 2) & 0x3c | (e >> 6) & 0x03)
			i++
			ob[i] = code((e << 0) & 0x3f | (0 >> 8) & 0x00)
			i++
		}
		ob[i] = byte('\n')
		i++
		if sys.write(ofd, ob, i) != i {
			fatal("bad write to output: %r")
		}
	}
	ob[0] = code(0)
	ob[1] = byte('\n')
	if sys.write(ofd, ob, 2) != 2 {
		fatal("bad write to output: %r")
	}
}
