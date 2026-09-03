module Tr

// appl/cmd/tr.b in Ember: translate, delete or squeeze characters.
// tr.b's Pcb adt is a struct with methods; its Pcb.new constructor
// is the function newpcb, since Ember has no static methods.

import sys "sys"
import draw "draw"
import bufio "bufio"
import arg "arg"

type Pcb struct {	// Control block controlling specification parse
	spec string	// specification string
	end int	// its length
	current int	// current parse point
	last int	// last Rune returned
	final int	// final Rune in a span
}

var bits = [8]byte{byte(1), byte(2), byte(4), byte(8), byte(16), byte(32), byte(64), byte(128)}

func SETBIT(a []byte, c int) {
	a[c >> 3] |= bits[c & 7]
}

func CLEARBIT(a []byte, c int) {
	a[c >> 3] &= ~bits[c & 7]
}

func BITSET(a []byte, c int) int {
	return int(a[c >> 3] & bits[c & 7])
}

var f = [(sys.Runemax + 1) / 8]byte
var t = [(sys.Runemax + 1) / 8]byte

var pto, pfrom ref Pcb

var cflag = false
var dflag = false
var sflag = false
var stderr ref sys.FD

var ib ref bufio.Iobuf
var ob ref bufio.Iobuf

func usage() {
	sys.fprint(stderr, "Usage: tr [-sdc] [from-set [to-set]]\n")
	raise "fail: usage"
}

func init(ctxt ref draw.Context, args list string) {
	stderr = sys.fildes(2)
	arg.init(args)
	for {
		c := arg.opt()
		if c == 0 {
			break
		}
		match c {
		case 's':
			sflag = true
		case 'd':
			dflag = true
		case 'c':
			cflag = true
		default:
			usage()
		}
	}
	args = arg.argv()
	argc := len(args)
	if args != nil {
		pfrom = newpcb(hd(args))
		args = tl(args)
	}
	if args != nil {
		pto = newpcb(hd(args))
		args = tl(args)
	}
	if args != nil {
		usage()
	}
	ib = bufio.fopen(sys.fildes(0), bufio.OREAD)
	ob = bufio.fopen(sys.fildes(1), bufio.OWRITE)
	if dflag {
		if sflag && argc != 2 || !sflag && argc != 1 {
			usage()
		}
		delete()
	} else {
		if argc != 2 {
			usage()
		}
		if cflag {
			complement()
		} else {
			translit()
		}
	}
	if ob.flush() == bufio.ERROR {
		error(sys.sprint("write error: %r"))
	}
}

func delete() {
	if cflag {
		for i := range f {
			f[i] = byte(0xFF)
		}
		for {
			c := pfrom.canon()
			if c < 0 {
				break
			}
			CLEARBIT(f, c)
		}
	} else {
		for {
			c := pfrom.canon()
			if c < 0 {
				break
			}
			SETBIT(f, c)
		}
	}
	if sflag {
		for {
			c := pto.canon()
			if c < 0 {
				break
			}
			SETBIT(t, c)
		}
	}

	last := sys.Runemax + 1
	for {
		c := ib.getc()
		if c < 0 {
			break
		}
		if BITSET(f, c) == 0 && (c != last || BITSET(t, c) == 0) {
			last = c
			ob.putc(c)
		}
	}
}

func complement() {
	lastc := 0
	high := 0
	for {
		from := pfrom.canon()
		if from < 0 {
			break
		}
		if from > high {
			high = from
		}
		SETBIT(f, from)
	}
	cto := 0
	for {
		cto = pto.canon()
		if cto < 0 {
			break
		}
		if cto > high {
			high = cto
		}
		SETBIT(t, cto)
	}
	pto.rewind()
	p := [high + 1]int
	for i := 0; i <= high; i++ {
		if BITSET(f, i) == 0 {
			cto = pto.canon()
			if cto < 0 {
				cto = lastc
			} else {
				lastc = cto
			}
			p[i] = cto
		} else {
			p[i] = i
		}
	}
	if sflag {
		lastc = sys.Runemax + 1
		for {
			from := ib.getc()
			if from < 0 {
				break
			}
			if from > high {
				from = cto
			} else {
				from = p[from]
			}
			if from != lastc || BITSET(t, from) == 0 {
				lastc = from
				ob.putc(from)
			}
		}
	} else {
		for {
			from := ib.getc()
			if from < 0 {
				break
			}
			if from > high {
				from = cto
			} else {
				from = p[from]
			}
			ob.putc(from)
		}
	}
}

func translit() {
	lastc := 0
	high := 0
	for {
		from := pfrom.canon()
		if from < 0 {
			break
		}
		if from > high {
			high = from
		}
	}
	pfrom.rewind()
	p := [high + 1]int
	for i := 0; i <= high; i++ {
		p[i] = i
	}
	for {
		from := pfrom.canon()
		if from < 0 {
			break
		}
		cto := pto.canon()
		if cto < 0 {
			cto = lastc
		} else {
			lastc = cto
		}
		if BITSET(f, from) != 0 && p[from] != cto {
			error("ambiguous translation")
		}
		SETBIT(f, from)
		p[from] = cto
		SETBIT(t, cto)
	}
	for {
		cto := pto.canon()
		if cto < 0 {
			break
		}
		SETBIT(t, cto)
	}
	if sflag {
		lastc = sys.Runemax + 1
		for {
			from := ib.getc()
			if from < 0 {
				break
			}
			if from <= high {
				from = p[from]
			}
			if from != lastc || BITSET(t, from) == 0 {
				lastc = from
				ob.putc(from)
			}
		}
	} else {
		for {
			from := ib.getc()
			if from < 0 {
				break
			}
			if from <= high {
				from = p[from]
			}
			ob.putc(from)
		}
	}
}

func newpcb(s string) ref Pcb {
	return ref Pcb{spec: s, end: len(s), current: 0, last: -1, final: -1}
}

func (p ref Pcb) rewind() {
	p.current = 0
	p.last = -1
	p.final = -1
}

func (p ref Pcb) getc() int {
	if p.current >= p.end {
		return -1
	}
	s := p.current
	r := p.spec[s]
	s++
	if r == '\\' && s < p.end {
		n := 0
		r = p.spec[s]
		if r == 'x' {
			s++
			for i := 0; i < 6 && s < p.end; i++ {
				p.current = s
				r = p.spec[s]
				s++
				if '0' <= r && r <= '9' {
					n = 16 * n + r - '0'
				} else if 'a' <= r && r <= 'f' {
					n = 16 * n + r - 'a' + 10
				} else if 'A' <= r && r <= 'F' {
					n = 16 * n + r - 'A' + 10
				} else {
					if i == 0 {
						return 'x'
					}
					return n
				}
			}
			r = n
		} else {
			for i := 0; i < 3 && s < p.end; i++ {
				p.current = s
				r = p.spec[s]
				s++
				if '0' <= r && r <= '7' {
					n = 8 * n + r - '0'
				} else {
					if i == 0 {
						return r
					}
					return n
				}
			}
			if n > 0377 {
				error("char>0377")
			}
			r = n
		}
	}
	p.current = s
	return r
}

func (p ref Pcb) canon() int {
	if p.final >= 0 {
		if p.last < p.final {
			p.last++
			return p.last
		}
		p.final = -1
	}
	if p.current >= p.end {
		return -1
	}
	if p.spec[p.current] == '-' && p.last >= 0 && p.current + 1 < p.end {
		p.current++
		r := p.getc()
		if r < p.last {
			error("Invalid range specification")
		}
		if r > p.last {
			p.final = r
			p.last++
			return p.last
		}
	}
	r := p.getc()
	p.last = r
	return p.last
}

func error(s string) {
	sys.fprint(stderr, "tr: %s\n", s)
	raise "fail: error"
}
