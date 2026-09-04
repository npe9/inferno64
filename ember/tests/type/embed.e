module Embedtest

// interface embedding: an interface names another declared earlier
// in the file and takes its methods; a value implementing the larger
// one also satisfies the smaller

import sys "sys"
import draw "draw"

type Reader interface {
	read() string
}

type Writer interface {
	write(s string)
	written() int
}

type ReadWriter interface {
	Reader
	Writer
	name() string
}

type Buf struct {
	data string
	n int
}

func (b ref Buf) read() string {
	return b.data
}

func (b ref Buf) write(s string) {
	b.data += s
	b.n++
}

func (b ref Buf) written() int {
	return b.n
}

func (b ref Buf) name() string {
	return "buf"
}

func copyall(r Reader, w Writer) {
	w.write(r.read())
}

func use(rw ReadWriter) string {
	rw.write("!")
	return rw.name() + ":" + rw.read()
}

func init(ctxt ref draw.Context, args list string) {
	b := ref Buf{data: "hi", n: 0}
	var rw ReadWriter
	rw = b
	sys.print("%s\n", use(rw))
	c := ref Buf{data: "", n: 0}
	copyall(rw, c)
	sys.print("copied %s written %d\n", c.read(), c.written())
	var w Writer
	w = c
	w.write("?")
	sys.print("%s %d\n", c.data, w.written())
	if bb := rw.(ref Buf); bb != nil {
		sys.print("asserted %s n=%d\n", bb.data, bb.n)
	}
	// narrowed to a smaller interface, the value keeps its identity
	var r Reader
	r = rw
	if bb2 := r.(ref Buf); bb2 != nil {
		sys.print("narrowed %s %s\n", bb2.name(), r.read())
	}
}
