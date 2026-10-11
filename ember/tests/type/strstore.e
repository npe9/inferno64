module Strstore

import sys "sys"

// stores through a string index -- "s[i] = c", "s[i] += n", "s[i]++"
// -- the write side of Oinds (5e7e9272 only did the read side, and
// every store shape hit gen.c's "can't deal with addressable 10"
// fatal).  com.c's indsstore() lowers all three to IINSC, whose dst
// operand is the string VARIABLE itself (libinterp/string.c's
// OP(insc) copies a shared string before writing and appends when
// i == len s), so the string must be real storage: a local, a global,
// a struct field -- all three exercised here, plus append and
// copy-on-write (t keeps its old contents after s, which it was
// copied from, is written).

type Box struct {
	name string
	n int
}

var g string

func init() {
	s := "abc"
	t := s
	s[0] = 'A'
	sys.print("s=%s t=%s\n", s, t)

	s[1] += 1
	s[2]++
	sys.print("s=%s\n", s)

	// append at len(s)
	s[len(s)] = 'z'
	sys.print("s=%s len=%d\n", s, len(s))

	// a global string
	g = "global"
	g[0] = 'G'
	sys.print("g=%s\n", g)

	// a struct field, value and ref
	b := Box{name: "box", n: 1}
	b.name[0] = 'B'
	rb := ref Box{name: "ref", n: 2}
	rb.name[0] = 'R'
	sys.print("b=%s rb=%s\n", b.name, rb.name)

	// index computed by a call, rune from a variable
	c := 'q'
	b.name[b.n] = c
	sys.print("b=%s\n", b.name)

	// nil string: insc on H allocates
	var e string
	e[0] = 'e'
	sys.print("e=%s\n", e)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
