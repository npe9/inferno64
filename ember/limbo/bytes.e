module Bytes

// appl/cmd/bytes.b in Ember: print a range of an input's bytes as
// text, escaping what is not a character, or replace that range with
// bytes given on the command line.
//
// bytes.b's own debug prints ("bytes: read %d bytes", "out of loop")
// are kept, since the point of this translation is to behave exactly
// as it does.

import sys "sys"
import draw "draw"
import bufio "bufio"

const END = 0x7fffffff

var stderr ref sys.FD
var stdin ref bufio.Iobuf
var stdout ref bufio.Iobuf

func usage() {
	sys.fprint(stderr, "usage: bytes start end [bytes]\n")
	raise "fail:usage"
}

func init(ctxt ref draw.Context, argv list string) {
	stderr = sys.fildes(2)
	stdin = bufio.fopen(sys.fildes(0), sys.OREAD)
	stdout = bufio.fopen(sys.fildes(1), sys.OWRITE)
	start := END
	end := END
	if len(argv) < 3 {
		usage()
	}
	argv = tl(argv)
	if hd(argv) != "end" {
		start = int(hd(argv))
	}
	argv = tl(argv)
	if hd(argv) != "end" {
		end = int(hd(argv))
	}
	if end < start {
		sys.fprint(stderr, "bytes: out of order range\n")
		raise "fail:bad range"
	}
	argv = tl(argv)
	if argv == nil {
		showbytes(start, end)
	} else {
		if tl(argv) != nil {
			usage()
		}
		b := s2bytes(hd(argv))
		setbytes(start, end, b)
	}
	stdout.close()
}

func showbytes(start int, end int) {
	buf := [sys.ATOMICIO]byte
	hold := [sys.UTFmax]byte
	tot := 0
	nhold := 0
	for tot < end {
		n := stdin.read(buf[nhold:], len(buf) - nhold)
		if n <= 0 {
			break
		}
		sys.fprint(stderr, "bytes: read %d bytes\n", n)
		if tot + n < start {
			continue
		}
		sb := 0
		eb := n
		if start > tot {
			sb = start - tot
		}
		if tot + n > end {
			eb = end - tot
		}
		nhold = putbytes(buf[sb:eb], hold)
		copy(buf, hold[0:nhold])
		tot += n - nhold
	}
	sys.fprint(stderr, "out of loop\n")
	flushbytes(hold[0:nhold])
}

func setbytes(start int, end int, d []byte) {
	buf := [sys.ATOMICIO]byte
	tot := 0
	for {
		n := stdin.read(buf, len(buf))
		if n <= 0 {
			break
		}
		if tot + n < start || tot >= end {
			stdout.write(buf, n)
			continue
		}
		if tot <= start {
			stdout.write(buf[0:start - tot], start - tot)
			stdout.write(d, len(d))
			if end == END {
				return
			}
		}
		if tot + n >= end {
			stdout.write(buf[end - tot:], n - (end - tot))
		}
		tot += n
	}
	if tot == start || start == END {
		stdout.write(d, len(d))
	}
}

func putbytes(d []byte, hold []byte) int {
	i := 0
	for i < len(d) {
		c, n, ok := sys.byte2char(d, i)
		if ok != 0 && n > 0 {
			if c == '\\' {
				stdout.putc('\\')
			}
			stdout.putc(c)
		} else {
			if n == 0 {
				copy(hold, d[i:])
				return len(d) - i
			}
			putbyte(d[i])
			n = 1
		}
		i += n
	}
	return 0
}

func flushbytes(hold []byte) {
	for i := 0; i < len(hold); i++ {
		putbyte(hold[i])
	}
}

func putbyte(b byte) {
	stdout.puts(sys.sprint("\\%2.2X", int(b)))
}

func isbschar(c int) int {
	match c {
	case 'n', 'r', 't', 'v':
		return 1
	}
	return 0
}

func s2bytes(s string) []byte {
	d := [len(s) + 2]byte
	j := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' {
			if i >= len(s) - 1 || (isbschar(s[i + 1]) == 0 && i >= len(s) - 2) {
				sys.fprint(stderr, "bytes: invalid backslash sequence\n")
				raise "fail:bad args"
			}
			d = assure(d, j + 1)
			if isbschar(s[i + 1]) != 0 {
				match s[i + 1] {
				case 'n':
					d[j] = byte('\n')
					j++
				case 'r':
					d[j] = byte('\r')
					j++
				case 't':
					d[j] = byte('\t')
					j++
				case 'v':
					d[j] = byte(11)
					j++
				case '\\':
					d[j] = byte('\\')
					j++
				default:
					sys.fprint(stderr, "bytes: invalid backslash sequence\n")
					raise "fail:bad args"
				}
				i++
			} else if ishex(s[i + 1]) == 0 || ishex(s[i + 2]) == 0 {
				sys.fprint(stderr, "bytes: invalid backslash sequence\n")
				raise "fail:bad args"
			} else {
				d[j] = byte((hex(s[i + 1]) << 4) + hex(s[i + 2]))
				j++
				i += 2
			}
		} else {
			d = assure(d, j + 3)
			j += sys.char2byte(s[i], d, j)
		}
	}
	return d[0:j]
}

func assure(d []byte, n int) []byte {
	if len(d) >= n {
		return d
	}
	nd := [n]byte
	copy(nd, d)
	return nd
}

func ishex(c int) int {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

func hex(c int) int {
	match c {
	case '0'...'9':
		return c - '0'
	case 'a'...'f':
		return c - 'a' + 10
	case 'A'...'F':
		return c - 'A' + 10
	}
	return 0
}
