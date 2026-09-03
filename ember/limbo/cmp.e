module Cmp

// appl/cmd/cmp.b in Ember: compare two files byte by byte

import sys "sys"
import draw "draw"
import arg "arg"

const BUF = 65536

var stderr ref sys.FD

func init(ctxt ref draw.Context, args list string) {
	lflag := false
	Lflag := false
	sflag := false
	buf1 := [BUF]byte
	buf2 := [BUF]byte

	stderr = sys.fildes(2)

	arg.init(args)
	for {
		op := arg.opt()
		if op == 0 {
			break
		}
		match op {
		case 'l':
			lflag = true
		case 'L':
			Lflag = true
		case 's':
			sflag = true
		default:
			usage()
		}
	}
	args = arg.argv()
	if len(args) < 2 {
		usage()
	}
	name1 := hd(args)
	args = tl(args)
	f1 := sys.open(name1, sys.OREAD)
	if f1 == nil {
		sys.fprint(stderr, "cmp: can't open %s: %r\n", name1)
		raise "fail:open"
	}
	name2 := hd(args)
	args = tl(args)
	f2 := sys.open(name2, sys.OREAD)
	if f2 == nil {
		sys.fprint(stderr, "cmp: can't open %s: %r\n", name2)
		raise "fail:open"
	}

	if args != nil {
		if sys.seek(f1, big(hd(args)), 0) < big(0) {
			sys.fprint(stderr, "cmp: seek by offset1 failed: %r\n")
			raise "fail:seek 1"
		}
		args = tl(args)
	}
	if args != nil {
		if sys.seek(f2, big(hd(args)), 0) < big(0) {
			sys.fprint(stderr, "cmp: seek by offset2 failed: %r")
			raise "fail:seek 2"
		}
		args = tl(args)
	}
	if args != nil {
		usage()
	}
	nc := big(1)
	l := big(1)
	diff := false
	var b1 []byte
	var b2 []byte
	for {
		if len(b1) == 0 {
			nr := sys.read(f1, buf1, BUF)
			if nr < 0 {
				if !sflag {
					sys.print("error on %s after %bd bytes\n", name1, nc - big(1))
				}
				raise "fail:read error"
			}
			b1 = buf1[0:nr]
		}
		if len(b2) == 0 {
			nr := sys.read(f2, buf2, BUF)
			if nr < 0 {
				if !sflag {
					sys.print("error on %s after %bd bytes\n", name2, nc - big(1))
				}
				raise "fail:read error"
			}
			b2 = buf2[0:nr]
		}
		n := len(b2)
		if n > len(b1) {
			n = len(b1)
		}
		if n == 0 {
			break
		}
		for i := range n {
			if Lflag && b1[i] == byte('\n') {
				l++
			}
			if b1[i] != b2[i] {
				if !lflag {
					if !sflag {
						sys.print("%s %s differ: char %bd", name1, name2, nc + big(i))
						if Lflag {
							sys.print(" line %bd\n", l)
						} else {
							sys.print("\n")
						}
					}
					raise "fail:differ"
				}
				sys.print("%6bd 0x%.2x 0x%.2x\n", nc + big(i), int(b1[i]), int(b2[i]))
				diff = true
			}
		}
		nc += big(n)
		b1 = b1[n:]
		b2 = b2[n:]
	}
	if len(b1) != len(b2) {
		nc--
		if len(b1) > len(b2) {
			sys.print("EOF on %s after %bd bytes\n", name2, nc)
		} else {
			sys.print("EOF on %s after %bd bytes\n", name1, nc)
		}
		raise "fail:EOF"
	}
	if diff {
		raise "fail:differ"
	}
}

func usage() {
	sys.fprint(stderr, "Usage: cmp [-lsL] file1 file2 [offset1 [offset2] ]\n")
	raise "fail:usage"
}
