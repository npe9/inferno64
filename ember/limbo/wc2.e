module Wc2

// appl/cmd/wc.b again, using what Ember has now: the flags are a
// bool each, the sixteen action codes are one const block with
// iota, the option letters are matched with a range, the report is
// built with the conditional expression, and range loops replace
// the index arithmetic.  The state tables are as in wc.b.

import sys "sys"
import draw "draw"

const NBUF = 8 * 1024

var stderr ref sys.FD
var pline, pword, pchar, pbadr, pbyte bool
var nline, nword, nchar, nbadr, nbyte int
var tnline, tnword, tnchar, tnbadr, tnbyte int

func init(ctxt ref draw.Context, argv list string) {
	stderr = sys.fildes(2)

	for argv = tl(argv); argv != nil; argv = tl(argv) {
		arg := hd(argv)
		if len(arg) < 2 || arg[0] != '-' || arg[1] == '-' {
			break
		}
		for _, c := range arg[1:] {
			match c {
			case 'l':
				pline = true
			case 'w':
				pword = true
			case 'c':
				pchar = true
			case 'e':
				pbadr = true
			case 'b':
				pbyte = true
			default:
				sys.fprint(stderr, "usage: wc [-lwcbe] [file ...]\n")
				raise "fail:usage"
			}
		}
	}
	if !(pline || pword || pchar || pbadr || pbyte) {
		pline = true
		pword = true
		pchar = true
	}
	if argv == nil {
		count(sys.fildes(0), "")
		exit()
	}
	for _, name := range argv {
		f := sys.open(name, sys.OREAD)
		if f == nil {
			sys.fprint(stderr, "wc: can't open %s: %r\n", name)
			continue
		}
		count(f, name)
		tnline += nline
		tnword += nword
		tnchar += nchar
		tnbadr += nbadr
		tnbyte += nbyte
	}
	if len(argv) > 1 {
		report(tnline, tnword, tnchar, tnbadr, tnbyte, "total")
	}
}

func report(nline int, nword int, nchar int, nbadr int, nbyte int, fname string) {
	line := ""
	line += pline ? sys.sprint(" %7d", nline) : ""
	line += pword ? sys.sprint(" %7d", nword) : ""
	line += pchar ? sys.sprint(" %7d", nchar) : ""
	line += pbadr ? sys.sprint(" %7d", nbadr) : ""
	line += pbyte ? sys.sprint(" %7d", nbyte) : ""
	line += fname != nil ? " " + fname : ""
	sys.print("%s\n", line[1:])
}

// the actions (see wc.b for the state table it derives from)
const (
	AC2 = iota
	AC2R
	AC2W
	AC2X
	AC3
	AC3W
	AC3X
	ASP
	ASPN
	ASPNX
	ASPX
	AWD
	AWDR
	AWDW
	AWDWX
	AWDX
)

var statesp = [256]int{	// looking for the start of a word
	// looking for the start of a word
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 00-07
AWDW, ASP,  ASPN, AWDW, AWDW, AWDW, AWDW, AWDW,	// 08-0f
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 10-17
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 18-1f
ASP,  AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 20-27
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 28-2f
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 30-37
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 38-3f
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 40-47
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 48-4f
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 50-57
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 58-5f
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 60-67
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 68-6f
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 70-77
AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW, AWDW,	// 78-7f
AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,// 80-87
AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,// 88-8f
AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,// 90-97
AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,// 98-9f
AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,// a0-a7
AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,// a8-af
AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,// b0-b7
AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,// b8-bf
AC2W, AC2W, AC2W, AC2W, AC2W, AC2W, AC2W, AC2W,	// c0-c7
AC2W, AC2W, AC2W, AC2W, AC2W, AC2W, AC2W, AC2W,	// c8-cf
AC2W, AC2W, AC2W, AC2W, AC2W, AC2W, AC2W, AC2W,	// d0-d7
AC2W, AC2W, AC2W, AC2W, AC2W, AC2W, AC2W, AC2W,	// d8-df
AC3W, AC3W, AC3W, AC3W, AC3W, AC3W, AC3W, AC3W,	// e0-e7
AC3W, AC3W, AC3W, AC3W, AC3W, AC3W, AC3W, AC3W,	// e8-ef
AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,// f0-f7
AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,AWDWX,// f8-ff
}
var statewd = [256]int{	// looking for the next character in a word
	// looking for the next character in a word
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 00-07
AWD,  ASP,  ASPN, AWD,  AWD,  AWD,  AWD,  AWD,	// 08-0f
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 10-17
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 18-1f
ASP,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 20-27
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 28-2f
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 30-37
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 38-3f
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 40-47
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 48-4f
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 50-57
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 58-5f
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 60-67
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 68-6f
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 70-77
AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,  AWD,	// 78-7f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 80-87
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 88-8f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 90-97
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 98-9f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// a0-a7
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// a8-af
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// b0-b7
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// b8-bf
AC2,  AC2,  AC2,  AC2,  AC2,  AC2,  AC2,  AC2,	// c0-c7
AC2,  AC2,  AC2,  AC2,  AC2,  AC2,  AC2,  AC2,	// c8-cf
AC2,  AC2,  AC2,  AC2,  AC2,  AC2,  AC2,  AC2,	// d0-d7
AC2,  AC2,  AC2,  AC2,  AC2,  AC2,  AC2,  AC2,	// d8-df
AC3,  AC3,  AC3,  AC3,  AC3,  AC3,  AC3,  AC3,	// e0-e7
AC3,  AC3,  AC3,  AC3,  AC3,  AC3,  AC3,  AC3,	// e8-ef
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// f0-f7
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// f8-ff
}
var statec2 = [256]int{	// looking for 10xxxxxx to complete a rune
	// looking for 10xxxxxx to complete a rune
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 00-07
AWDX, ASPX, ASPNX,AWDX, AWDX, AWDX, AWDX, AWDX,	// 08-0f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 10-17
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 18-1f
ASPX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 20-27
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 28-2f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 30-37
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 38-3f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 40-47
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 48-4f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 50-57
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 58-5f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 60-67
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 68-6f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 70-77
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 78-7f
AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR,	// 80-87
AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR,	// 88-8f
AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR,	// 90-97
AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR,	// 98-9f
AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR,	// a0-a7
AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR,	// a8-af
AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR,	// b0-b7
AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR, AWDR,	// b8-bf
AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X,	// c0-c7
AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X,	// c8-cf
AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X,	// d0-d7
AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X,	// d8-df
AC3X, AC3X, AC3X, AC3X, AC3X, AC3X, AC3X, AC3X,	// e0-e7
AC3X, AC3X, AC3X, AC3X, AC3X, AC3X, AC3X, AC3X,	// e8-ef
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// f0-f7
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// f8-ff
}
var statec3 = [256]int{	// looking for 10xxxxxx,10xxxxxx to complete a rune
	// looking for 10xxxxxx,10xxxxxx to complete a rune
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 00-07
AWDX, ASPX, ASPNX,AWDX, AWDX, AWDX, AWDX, AWDX,	// 08-0f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 10-17
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 18-1f
ASPX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 20-27
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 28-2f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 30-37
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 38-3f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 40-47
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 48-4f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 50-57
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 58-5f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 60-67
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 68-6f
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 70-77
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// 78-7f
AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R,	// 80-87
AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R,	// 88-8f
AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R,	// 90-97
AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R,	// 98-9f
AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R,	// a0-a7
AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R,	// a8-af
AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R,	// b0-b7
AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R, AC2R,	// b8-bf
AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X,	// c0-c7
AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X,	// c8-cf
AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X,	// d0-d7
AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X, AC2X,	// d8-df
AC3X, AC3X, AC3X, AC3X, AC3X, AC3X, AC3X, AC3X,	// e0-e7
AC3X, AC3X, AC3X, AC3X, AC3X, AC3X, AC3X, AC3X,	// e8-ef
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// f0-f7
AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX, AWDX,	// f8-ff
}
var buf = [NBUF]byte

func count(f ref sys.FD, name string) {
	state := statesp
	nline = 0
	nword = 0
	nchar = 0
	nbadr = 0
	nbyte = 0
	n := 0
	for n = sys.read(f, buf, NBUF); n > 0; n = sys.read(f, buf, NBUF) {
		nbyte += n
		nchar += n	// might be too large, gets decreased later
		for _, b := range buf[0:n] {
			match state[int(b)] {
			case AC2:
				state = statec2
			case AC2R:
				state = statec2
				nchar--
			case AC2W:
				state = statec2
				nword++
			case AC2X:
				state = statec2
				nbadr++
			case AC3:
				state = statec3
			case AC3W:
				state = statec3
				nword++
			case AC3X:
				state = statec3
				nbadr++
			case ASP:
				state = statesp
			case ASPN:
				state = statesp
				nline++
			case ASPNX:
				state = statesp
				nline++
				nbadr++
			case ASPX:
				state = statesp
				nbadr++
			case AWD:
				state = statewd
			case AWDR:
				state = statewd
				nchar--
			case AWDW:
				state = statewd
				nword++
			case AWDWX:
				state = statewd
				nword++
				nbadr++
			case AWDX:
				state = statewd
				nbadr++
			}
		}
	}
	if state != statesp && state != statewd {
		nbadr++
	}
	if n < 0 {
		sys.fprint(stderr, "wc: error reading %s: %r\n", name)
	}
	report(nline, nword, nchar, nbadr, nbyte, name)
}
