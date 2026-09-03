module Pickcommon

// a pick may declare fields every tag carries, before its tags, laid
// out first in each; and several tags may share one field list

import sys "sys"
import draw "draw"

type Cmd pick {
	line int
	negate bool
	Print()
	Delete, Quit()
	Subst(from string, to string)
	Branch, Label(lab string)
}

func show(c ref Cmd) string {
	s := sys.sprint("%d%s ", c.line, neg(c.negate))
	match c {
	case Cmd.Print:
		return s + "p"
	case Cmd.Delete:
		return s + "d"
	case Cmd.Quit:
		return s + "q"
	case Cmd.Subst(from, to):
		return s + "s/" + from + "/" + to + "/"
	case Cmd.Branch(lab):
		return s + "b " + lab
	case Cmd.Label(lab):
		return s + ":" + lab
	}
	return "?"
}

func neg(b bool) string {
	if b {
		return "!"
	}
	return ""
}

func init(ctxt ref draw.Context, args list string) {
	cs := [5]ref Cmd{
		ref Cmd.Print{line: 1},
		ref Cmd.Subst{line: 2, negate: true, from: "a", to: "b"},
		ref Cmd.Branch{line: 3, lab: "top"},
		ref Cmd.Label{line: 4, lab: "top"},
		ref Cmd.Quit{line: 5},
	}
	for _, c := range cs {
		sys.print("%s\n", show(c))
	}
	s := ref Cmd.Subst{line: 9, from: "x", to: "y"}
	s.line = 10
	s.negate = true
	sys.print("%s %s\n", show(s), s.from)
}
