module Ifacenamed

// a named type satisfies an interface: the method closures hold the
// value itself

import sys "sys"
import draw "draw"

type Stringer interface {
	str() string
}

type Level int

type Path string

func (l Level) str() string {
	return sys.sprint("level %d", int(l))
}

func (p Path) str() string {
	return "path " + string(p)
}

func show(s Stringer) string {
	return s.str()
}

func init(ctxt ref draw.Context, args list string) {
	var s Stringer
	s = Level(2)
	sys.print("%s\n", s.str())
	sys.print("%s\n", show(Path("/tmp")))
	all := []Stringer{Level(0), Path("x")}
	for _, v := range all {
		sys.print("%s\n", v.str())
	}
}
