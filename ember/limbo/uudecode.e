module Uudecode

// appl/cmd/uudecode.b in Ember.  Sys->nulldir, a module variable,
// has no interface equivalent, so nulldir() builds the same all-ones
// "leave alone" Dir.

import sys "sys"
import draw "draw"
import str "string"
import bufio "bufio"

func fatal(s string) {
	sys.fprint(sys.fildes(2), "%s\n", s)
	exit()
}

func usage() {
	fatal("usage: uudecode [ -p ] [ encodedfile... ]")
}

func init(ctxt ref draw.Context, argv list string) {
	var fd ref sys.FD

	tostdout := false
	argv = tl(argv)
	if argv != nil && hd(argv) == "-p" {
		tostdout = true
		argv = tl(argv)
	}
	if argv != nil {
		for ; argv != nil; argv = tl(argv) {
			fd = sys.open(hd(argv), sys.OREAD)
			if fd == nil {
				fatal(sys.sprint("cannot open %s", hd(argv)))
			}
			decode(fd, tostdout)
		}
	} else {
		decode(sys.fildes(0), tostdout)
	}
}

func code(c byte) int {
	return (int(c) - ' ') & 0x3f
}

const LEN = 45

func nulldir() sys.Dir {
	return sys.Dir{name: nil, uid: nil, gid: nil, muid: nil,
		qid: sys.Qid{path: ~big(0), vers: ~0, qtype: ~0},
		mode: ~0, atime: ~0, mtime: ~0, length: ~big(0), dtype: ~0, dev: ~0}
}

func decode(ifd ref sys.FD, tostdout bool) {
	var mode int
	var ofile string

	bio := bufio.fopen(ifd, bufio.OREAD)
	if bio == nil {
		fatal("cannot open input for buffered io: %r")
	}
	for {
		s := bio.gets('\n')
		if s == nil {
			break
		}
		if len(s) >= 6 && s[0:6] == "begin " {
			n, l := sys.tokenize(s, " \n")
			if n < 3 {
				fatal("bad begin line")
			}
			mode, _ = str.toint(hd(tl(l)), 8)
			ofile = hd(tl(tl(l)))
			break
		}
	}
	if ofile == nil {
		fatal("no begin line")
	}
	var ofd ref sys.FD
	if tostdout {
		ofd = sys.fildes(1)
	} else {
		if ofile[0] == '~' {	// ~user/file
			ofile = "/usr/" + ofile[1:]
		}
		ofd = sys.create(ofile, sys.OWRITE, 0666)
		if ofd == nil {
			fatal(sys.sprint("cannot create %s: %r", ofile))
		}
	}
	ob := [LEN]byte
	var s string
	for {
		s = bio.gets('\n')
		if s == nil {
			break
		}
		b := []byte(s)
		n := code(b[0])
		if n == 0 && (len(b) != 2 || b[1] != byte('\n')) {
			fatal("bad 0 count line")
		}
		if n <= 0 {
			break
		}
		if n > LEN {
			fatal("too many bytes on line")
		}
		e := 0
		f := 0
		if n % 3 == 1 {
			e = 2
			f = 4
		} else if n % 3 == 2 {
			e = 3
			f = 4
		}
		if len(b) < 4 * (n / 3) + e + 2 || len(b) > 4 * (n / 3) + f + 2 {
			fatal("bad uuencode count")
		}
		b = b[1:]
		i := 0
		nl := n
		for j := 0; nl > 0; j += 4 {
			if nl >= 1 {
				ob[i] = byte(code(b[j + 0]) << 2 | code(b[j + 1]) >> 4)
				i++
			}
			if nl >= 2 {
				ob[i] = byte(code(b[j + 1]) << 4 | code(b[j + 2]) >> 2)
				i++
			}
			if nl >= 3 {
				ob[i] = byte(code(b[j + 2]) << 6 | code(b[j + 3]) >> 0)
				i++
			}
			nl -= 3
		}
		if sys.write(ofd, ob, i) != i {
			fatal("bad write to output: %r")
		}
	}
	s = bio.gets('\n')
	if s == nil || len(s) < 4 || s[0:4] != "end\n" {
		fatal("missing end line")
	}
	if !tostdout {
		d := nulldir()
		d.mode = mode
		if sys.fwstat(ofd, d) < 0 {
			fatal(sys.sprint("cannot wstat %s: %r", ofile))
		}
	}
}
