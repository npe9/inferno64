module Grep

// appl/cmd/grep.b in Ember: print lines matching a regular
// expression, through the Limbo regex library

import sys "sys"
import draw "draw"
import regex "regex"
import bufio "bufio"
import arg "arg"

var stdin, stderr, stdout ref sys.FD

var multi bool
var lflag, nflag, vflag, iflag, Lflag, sflag bool

func init(ctxt ref draw.Context, argv list string) {
	stdin = sys.fildes(0)
	stdout = sys.fildes(1)
	stderr = sys.fildes(2)

	arg.init(argv)
	for {
		opt := arg.opt()
		if opt == 0 {
			break
		}
		match opt {
		case 'l':
			lflag = true
		case 'n':
			nflag = true
		case 'v':
			vflag = true
		case 'i':
			iflag = true
		case 'L':
			Lflag = true
		case 's':
			sflag = true
		default:
			usage()
		}
	}
	argv = arg.argv()

	if argv == nil {
		usage()
	}
	pattern := hd(argv)
	argv = tl(argv)
	if iflag {
		pattern = tolower(pattern)
	}
	re, err := regex.compile(pattern, 0)
	if re == nil {
		sys.fprint(stderr, "grep: %s\n", err)
		raise "fail:bad regex"
	}

	matched := 0
	if argv == nil {
		matched = grep(re, bufio.fopen(stdin, bufio.OREAD), "stdin")
	} else {
		multi = tl(argv) != nil
		for ; argv != nil; argv = tl(argv) {
			f := bufio.open(hd(argv), bufio.OREAD)
			if f == nil {
				sys.fprint(stderr, "grep: cannot open %s: %r\n", hd(argv))
			} else {
				matched += grep(re, f, hd(argv))
			}
		}
	}
	if matched == 0 {
		raise "fail:no matches"
	}
}

func usage() {
	sys.fprint(stderr, "usage: grep [-lnviLs] pattern [file...]\n")
	raise "fail:usage"
}

func grep(re ref regex.Arena, f ref bufio.Iobuf, file string) int {
	matched := 0
	for line := 1; ; line++ {
		t := f.gets('\n')
		s := t
		if s == nil {
			break
		}
		if iflag {
			s = tolower(s)
		}
		if (regex.executese(re, s, (0, len(s) - 1), 1, 1) != nil) != vflag {
			matched = 1
			if lflag || sflag {
				if !sflag {
					sys.print("%s\n", file)
				}
				return matched
			}
			if !Lflag {
				if nflag {
					if multi {
						sys.print("%s:%d: %s", file, line, t)
					} else {
						sys.print("%d:%s", line, t)
					}
				} else {
					if multi {
						sys.print("%s: %s", file, t)
					} else {
						sys.print("%s", t)
					}
				}
			}
		}
	}
	if Lflag && matched == 0 && !sflag {
		sys.print("%s\n", file)
	}
	return matched
}

func tolower(s string) string {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			s[i] = c - 'A' + 'a'
		}
	}
	return s
}
