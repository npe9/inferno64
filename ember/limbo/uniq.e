module Uniq

// appl/cmd/uniq.b in Ember: drop or keep repeated adjacent lines

import sys "sys"
import draw "draw"
import bufio "bufio"
import arg "arg"

func usage() {
	fail("usage", sys.sprint("usage: uniq [-ud] [file]"))
}

func init(ctxt ref draw.Context, args list string) {
	var bio ref bufio.Iobuf

	uflag := false
	dflag := false
	arg.init(args)
	for {
		opt := arg.opt()
		if opt == 0 {
			break
		}
		match opt {
		case 'u':
			uflag = true
		case 'd':
			dflag = true
		default:
			usage()
		}
	}
	args = arg.argv()
	if len(args) > 1 {
		usage()
	}
	if args != nil {
		bio = bufio.open(hd(args), bufio.OREAD)
		if bio == nil {
			fail("open file", sys.sprint("uniq: cannot open %s: %r\n", hd(args)))
		}
	} else {
		bio = bufio.fopen(sys.fildes(0), bufio.OREAD)
	}

	stdout := bufio.fopen(sys.fildes(1), bufio.OWRITE)
	if !(uflag || dflag) {
		uflag = true
		dflag = true
	}
	prev := ""
	n := 0
	for {
		s := bio.gets('\n')
		if s == nil {
			break
		}
		if s == prev {
			n++
		} else {
			if (uflag && n == 1) || (dflag && n > 1) {
				stdout.puts(prev)
			}
			n = 1
			prev = s
		}
	}
	if (uflag && n == 1) || (dflag && n > 1) {
		stdout.puts(prev)
	}
	stdout.close()
}

func fail(ex string, msg string) {
	sys.fprint(sys.fildes(2), "%s\n", msg)
	raise "fail:" + ex
}
