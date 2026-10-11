module Elemfield

import sys "sys"

// field reads through an element of an array whose ELEMENT type has a
// pointer field: "ps[i].n" corrupted the heap at every function exit
// (only for such element types, even for an int field, never for a
// write) -- ecom's Oind case first materialized the whole address
// through eacom(), whose Oadr temp took the struct's own type, so the
// element's interior address sat in a slot the frame descriptor marks
// as a pointer.  eacom() now types an Oadr temp as int and the Oind
// case runs fixdblind() first (no dead second computation).  the
// churn makes a corrupted heap show quickly; the reads happen in a
// helper so its frame is torn down many times.

type P struct {
	s string
	n int
	q ref P
}

func mk(n int) []P {
	ps := [3]P
	for i := 0; i < len(ps); i++ {
		ps[i].s = sys.sprint("s%d", i + n)
		ps[i].n = i + n
	}
	ps[2].q = ref P{s: "inner", n: 99}
	return ps
}

func sumn(ps []P) int {
	t := 0
	for i := 0; i < len(ps); i++ {
		t += ps[i].n
	}
	return t
}

func names(ps []P) string {
	r := ""
	for i := 0; i < len(ps); i++ {
		r = r + ps[i].s + " "
	}
	return r
}

func churn() {
	for i := 0; i < 500; i++ {
		s := sys.sprint("x%d", i)
		b := [64]byte{}
		b[0] = byte(len(s))
	}
}

func init() {
	total := 0
	for k := 0; k < 50; k++ {
		ps := mk(k)
		total += sumn(ps)
		if k == 0 {
			sys.print("names=%s\n", names(ps))
			sys.print("inner=%s %d\n", ps[2].q.s, ps[2].q.n)
		}
		churn()
	}
	sys.print("total=%d\n", total)

	// the original shape: a builtin returning an array of structs
	fd := sys.open("/ember/tests/type", sys.OREAD)
	found := 0
	for {
		cnt, dirs := sys.dirread(fd)
		if cnt <= 0 {
			break
		}
		churn()
		for i := 0; i < cnt; i++ {
			if dirs[i].name == "elemfield.e" {
				found = 1
			}
		}
	}
	sys.print("found=%d\n", found)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
