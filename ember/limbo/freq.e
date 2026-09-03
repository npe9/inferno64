module Freq

// appl/cmd/freq.b in Ember: byte (or rune, -r) frequencies of the
// named files, printed in decimal, octal, hex and as characters

import sys "sys"
import draw "draw"
import bufio "bufio"
import arg "arg"

var count = [65536]big
var flag = 0

const Fdec = 1
const Fhex = 2
const Foct = 4
const Fchar = 8
const Frune = 16

func init(ctxt ref draw.Context, args list string) {
	arg.init(args)
	for {
		c := arg.opt()
		if c == 0 {
			break
		}
		match c {
		case 'd':
			flag |= Fdec
		case 'x':
			flag |= Fhex
		case 'o':
			flag |= Foct
		case 'c':
			flag |= Fchar
		case 'r':
			flag |= Frune
		default:
			sys.fprint(sys.fildes(2), "freq: unknown option %c\n", c)
			raise "fail:usage"
		}
	}
	args = arg.argv()

	bout := bufio.fopen(sys.fildes(1), sys.OWRITE)
	if (flag & (Fdec | Fhex | Foct | Fchar)) == 0 {
		flag |= Fdec | Fhex | Foct | Fchar
	}
	if args == nil {
		freq(sys.fildes(0), "-", bout)
		return
	}
	for name := range args {
		f := sys.open(name, sys.OREAD)
		if f == nil {
			sys.fprint(sys.fildes(2), "cannot open %s\n", name)
			continue
		}
		freq(f, name, bout)
	}
}

func freq(f ref sys.FD, s string, bout ref bufio.Iobuf) {
	bin := bufio.fopen(f, sys.OREAD)
	c := 0
	if (flag & Frune) != 0 {
		for {
			c = bin.getc()
			if c < 0 {
				break
			}
			count[c]++
		}
	} else {
		for {
			c = bin.getb()
			if c < 0 {
				break
			}
			count[c]++
		}
	}
	if c != bufio.EOF {
		sys.fprint(sys.fildes(2), "freq: read error on %s: %r\n", s)
	}
	for i := range len(count) / 4 {
		if count[i] == big(0) {
			continue
		}
		if (flag & Fdec) != 0 {
			bout.puts(sys.sprint("%3d ", i))
		}
		if (flag & Foct) != 0 {
			bout.puts(sys.sprint("%.3o ", i))
		}
		if (flag & Fhex) != 0 {
			bout.puts(sys.sprint("%.2x ", i))
		}
		if (flag & Fchar) != 0 {
			if i <= 0x20 || i >= 0x7f && i < 0xa0 || i > 0xff && (flag & Frune) == 0 {
				bout.puts("- ")
			} else {
				bout.puts(sys.sprint("%c ", i))
			}
		}
		bout.puts(sys.sprint("%8bd\n", count[i]))
	}
	bout.flush()
}
