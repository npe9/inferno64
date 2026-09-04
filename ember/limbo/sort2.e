module Sort2

// appl/cmd/sort.b in Ember, written the way Ember allows: the two
// hand-written merge sorts are the builtin sort with a comparison
// closure, and the output goes through a Builder

import sys "sys"
import draw "draw"
import bufio "bufio"
import arg "arg"

func usage() {
	sys.fprint(sys.fildes(2), "usage: sort [-n] [file]\n")
	raise "fail:usage"
}

const Incr = 2000	// growth quantum for record array

func input(args list string) ref bufio.Iobuf {
	if args == nil {
		return bufio.fopen(sys.fildes(0), bufio.OREAD)
	}
	bio := bufio.open(hd(args), bufio.OREAD)
	if bio == nil {
		sys.fprint(sys.fildes(2), "sort: cannot open %s: %r\n", hd(args))
		raise "fail:open file"
	}
	return bio
}

func lines(bio ref bufio.Iobuf) []string {
	a := [Incr]string
	n := 0
	for {
		s := bio.gets('\n')
		if s == nil {
			break
		}
		if n >= len(a) {
			b := [len(a) + Incr]string
			copy(b, a)
			a = b
		}
		a[n] = s
		n++
	}
	return a[0:n]
}

func init(ctxt ref draw.Context, args list string) {
	nflag := false
	rflag := false
	arg.init(args)
	for {
		opt := arg.opt()
		if opt == 0 {
			break
		}
		match opt {
		case 'n':
			nflag = true
		case 'r':
			rflag = true
		default:
			usage()
		}
	}
	args = arg.argv()
	if len(args) > 1 {
		usage()
	}
	a := lines(input(args))

	bytext := func(x string, y string) int {
		if x < y {
			return -1
		}
		if x > y {
			return 1
		}
		return 0
	}
	bynumber := func(x string, y string) int {
		return int(x) - int(y)
	}
	if nflag {
		sort(a, bynumber)
	} else {
		sort(a, bytext)
	}

	out := ref Builder{}
	if rflag {
		for i := len(a) - 1; i >= 0; i-- {
			out.puts(a[i])
		}
	} else {
		for _, s := range a {
			out.puts(s)
		}
	}
	stdout := bufio.fopen(sys.fildes(1), bufio.OWRITE)
	stdout.puts(out.string())
	stdout.close()
}
