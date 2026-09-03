module Strings

// appl/cmd/strings.b in Ember: print the printable runs in files.
// strings.b's buffer is "string array[BUFSIZE] of { * => byte 'z' }",
// a string of BUFSIZE 'z's it then indexes into; here it is built by
// appending.

import sys "sys"
import draw "draw"
import bufio "bufio"

const MINSPAN = 6
const BUFSIZE = 70

func init(ctxt ref draw.Context, argl list string) {
	argc := len(argl)
	if argc < 2 {
		stringit("")
		exit()
	}
	argl = tl(argl)
	for i := 1; i < argc; i++ {
		if argc > 2 {
			sys.print("%s:\n", hd(argl))
		}
		stringit(hd(argl))
		argl = tl(argl)
	}
}

func stringit(str string) {
	cnt := 0
	buf := ""
	for i := range BUFSIZE {
		buf[len(buf)] = 'z'
	}

	var fin ref bufio.Iobuf
	if str == nil {
		fin = bufio.fopen(sys.fildes(0), bufio.OREAD)
	} else {
		fin = bufio.open(str, bufio.OREAD)
	}
	if fin == nil {
		sys.fprint(sys.fildes(2), "cannot open %s\n", str)
		return
	}
	start := big(-1)
	posn := fin.offset()
	for {
		c := fin.getc()
		if c < 0 {
			break
		}
		if isprint(c) {
			if start == big(-1) {
				start = posn
			}
			buf[cnt] = c
			cnt++
			if cnt == BUFSIZE {
				sys.print("%8bd: %s ...\n", start, buf[0:cnt])
				start = big(-1)
				cnt = 0
			}
		} else {
			if cnt >= MINSPAN {
				sys.print("%8bd: %s\n", start, buf[0:cnt])
			}
			start = big(-1)
			cnt = 0
		}
		posn = fin.offset()
	}
	if cnt >= MINSPAN {
		sys.print("%8bd: %s\n", start, buf[0:cnt])
	}
	fin = nil
}

func isprint(r int) bool {
	if r >= ' ' && r < 0x7f || r > 0xa0 {
		return true
	} else {
		return false
	}
}
