module Namedtype

// "type Color int": a named type with methods.  it is a type of its
// own to hang the methods on, but structurally the base type, so a
// Color is still an int in arithmetic and assignment

import sys "sys"
import draw "draw"

type Color int

type Path string

type Nums list int

func (c Color) name() string {
	match c {
	case 0:
		return "red"
	case 1:
		return "green"
	}
	return "colour" + string(int(c))
}

func (c Color) next() Color {
	return c + 1
}

func (p Path) base() string {
	s := string(p)
	last := -1
	for i := 0; i < len(s); i++ {
		if s[i] == '/' {
			last = i
		}
	}
	return s[last + 1:]
}

func (ns Nums) total() int {
	t := 0
	for _, x := range ns {
		t += x
	}
	return t
}

func init(ctxt ref draw.Context, args list string) {
	var c Color
	c = 1
	sys.print("%s %s\n", c.name(), c.next().name())
	sys.print("%d %d\n", c + 1, int(c) * 3)
	a := [3]Color
	a[0] = Color(7)
	sys.print("%s %d\n", a[0].name(), len(a))
	var p Path
	p = "/usr/npe/x.e"
	sys.print("%s\n", p.base())
	sys.print("%s\n", Path("plain").base())
	var ns Nums
	ns = 3 :: 4 :: 5 :: nil
	sys.print("%d %d\n", ns.total(), len(ns))
}
