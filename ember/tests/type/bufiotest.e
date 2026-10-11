module Bufiotest

import sys "sys"
import bufio "bufio"

// bufio through module/bufio.ei -- an interface that itself imports
// sys (Iobuf.fd is a ref sys.FD) -- against the real limbo-compiled
// /dis/lib/bufio.dis: string-backed input via sopen (no files
// needed), gets/getc/gett/ungetc, and buffered output through an
// Iobuf wrapped around fd 1 with fopen, puts/putc/flush.  the field
// list of Iobuf is signed into every method's link entry, so a
// mismatch anywhere in it would refuse the load.

func init() {
	in := bufio.sopen("first line\nsecond line\nx,y,z\n")
	if in == nil {
		sys.print("sopen failed\n")
		return
	}
	l1 := in.gets('\n')
	l2 := in.gets('\n')
	sys.print("l1=%s", l1)
	sys.print("l2=%s", l2)

	// getc/ungetc, then gett with a separator set
	c := in.getc()
	in.ungetc()
	sys.print("peek=%c\n", c)
	a := in.gett(",\n")
	b := in.gett(",\n")
	z := in.gett(",\n")
	sys.print("a=%s b=%s z=%s", a, b, z)
	sys.print("eof=%d\n", in.getc() == bufio.EOF)

	// a field of the imported adt read directly: a sopen'd Iobuf has
	// no fd behind it
	sys.print("fd is nil: %d\n", in.fd == nil)

	// output through the same library
	out := bufio.fopen(sys.fildes(1), bufio.OWRITE)
	if out == nil {
		sys.print("fopen failed\n")
		return
	}
	out.puts("buffered ")
	out.putc('o')
	out.putc('k')
	out.putc('\n')
	out.flush()
	sys.print("fd is set: %d\n", out.fd != nil)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
