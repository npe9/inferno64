module Comm

// appl/cmd/comm.b in Ember: lines common to, or unique to, two
// sorted files.  "copy" is Ember's array-copy builtin, so comm.b's
// copy() is copyrest here; it ends the program with exit() from
// inside, as the original does.

import sys "sys"
import draw "draw"
import bufio "bufio"
import arg "arg"

const One = 1
const Two = 2
const Three = 4

var cols = One | Two | Three
var ldr = [3]string{"", "\t", "\t\t"}

func init(ctxt ref draw.Context, args list string) {
	arg.init(args)
	arg.setusage("comm [-123] file1 file2")
	for {
		c := arg.opt()
		if c == 0 {
			break
		}
		match c {
		case '1', '2', '3':
			cols &= ~(1 << (c - '1'))
		default:
			arg.usage()
		}
	}
	args = arg.argv()
	if len(args) != 2 {
		arg.usage()
	}

	if (cols & One) == 0 {
		ldr[1] = ""
		ldr[2] = ldr[2][1:]
	}
	if (cols & Two) == 0 {
		ldr[2] = ldr[2][1:]
	}

	ib1 := openfil(hd(args))
	ib2 := openfil(hd(tl(args)))
	lb1 := ib1.gets('\n')
	if lb1 == nil {
		lb2 := ib2.gets('\n')
		if lb2 == nil {
			exit()
		}
		copyrest(ib2, lb2, 2)
	}
	lb2 := ib2.gets('\n')
	if lb2 == nil {
		copyrest(ib1, lb1, 1)
	}
	for {
		match compare(lb1, lb2) {
		case 0:
			wr(lb1, 3)
			lb1 = ib1.gets('\n')
			if lb1 == nil {
				lb2 = ib2.gets('\n')
				if lb2 == nil {
					exit()
				}
				copyrest(ib2, lb2, 2)
			}
			lb2 = ib2.gets('\n')
			if lb2 == nil {
				copyrest(ib1, lb1, 1)
			}
		case 1:
			wr(lb1, 1)
			lb1 = ib1.gets('\n')
			if lb1 == nil {
				copyrest(ib2, lb2, 2)
			}
		case 2:
			wr(lb2, 2)
			lb2 = ib2.gets('\n')
			if lb2 == nil {
				copyrest(ib1, lb1, 1)
			}
		}
	}
}

func wr(str string, n int) {
	if (cols & (1 << (n - 1))) != 0 {
		sys.print("%s%s", ldr[n - 1], str)
	}
}

func copyrest(ibuf ref bufio.Iobuf, lbuf string, n int) {
	for {
		wr(lbuf, n)
		lbuf = ibuf.gets('\n')
		if lbuf == nil {
			break
		}
	}
	exit()
}

func compare(a string, b string) int {
	i := 0
	for ; i < len(a); i++ {
		if i >= len(b) || a[i] < b[i] {
			return 1
		}
		if a[i] != b[i] {
			return 2
		}
	}
	if i == len(b) {
		return 0
	}
	return 2
}

func openfil(s string) ref bufio.Iobuf {
	var b ref bufio.Iobuf
	if s == "-" {
		b = bufio.fopen(sys.fildes(0), bufio.OREAD)
	} else {
		b = bufio.open(s, bufio.OREAD)
	}
	if b != nil {
		return b
	}
	sys.fprint(sys.fildes(2), "comm: cannot open %s: %r\n", s)
	raise "fail:open"
}
