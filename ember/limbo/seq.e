module Seq

// appl/cmd/seq.b in Ember: print a sequence of numbers in steps of
// a given increment

import sys "sys"
import draw "draw"
import arg "arg"
import bufio "bufio"

var out ref bufio.Iobuf

func init(ctxt ref draw.Context, args list string) {
	arg.init(args)
	out = bufio.open("/fd/1", bufio.OWRITE)

	arg.setusage("seq [first [increment]] last")
	args = arg.argv()
	argc := len(args)

	step := 1.0
	first := 1.0
	var last real
	printer := iprint

	match argc {
	case 1:
		// Seq [1,last]
		last = real(hd(args))
	case 2:
		// Seq [first,last]
		first = real(hd(args))
		last = real(hd(tl(args)))
	case 3:
		// Seq [first,last] by step increment
		first = real(hd(args))
		step = real(hd(tl(args)))
		last = real(hd(tl(tl(args))))
	default:
		arg.usage()
	}

	if isfloat(first) || isfloat(step) || isfloat(last) {
		printer = rprint
	}

	// Iterate
	for i := first; i <= last; i += step {
		printer(i)
	}

	out.flush()
	out.close()
	exit()
}

// Print int
func iprint(i real) {
	out.puts(sys.sprint("%d\n", int(i)))
}

// Print real
func rprint(i real) {
	out.puts(sys.sprint("%g\n", i))
}

// Determine if functionally float by truncating and comparing the difference
// 2.5 - 2.0 = 0.5 != 0.0 ;; 3.0 - 3.0 = 0.0 == 0.0
func isfloat(r real) bool {
	i := int(r)
	ir := real(i)

	if r - ir == 0.0 {
		return false
	}

	return true
}
