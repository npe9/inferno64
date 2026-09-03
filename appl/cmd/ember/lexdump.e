module Lexdump

import sys "sys"
import draw "draw"
import lex "lex"

// dump a file's tokens in ember -T's format, one per line:
// "line:pos name [value]".  with no arguments, a fixed test file, so
// the runtime suite can run it.

func escaped(s string) string {
	out := ""
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\\' || c < 32 || c == 127 {
			out += sys.sprint("\\x%02x", c)
		} else {
			out += sys.sprint("%c", c)
		}
	}
	return out
}

func dump(file string) {
	lx := lex.open(file)
	if lx == nil {
		sys.fprint(sys.fildes(2), "lexdump: cannot open %s\n", file)
		return
	}
	for {
		t := lx.next()
		s := sys.sprint("%d:%d %s", t.line, t.pos, lex.tokname(t.t))
		match t.t {
		case lex.Eid:
			s += " " + t.sym
		case lex.Esconst:
			s += " " + escaped(t.sym)
		case lex.Econst:
			s += sys.sprint(" %bd", t.ival)
		case lex.Erconst:
			s += " " + t.text
		}
		sys.print("%s\n", s)
		if t.t == lex.Beof {
			break
		}
	}
}

func init(ctxt ref draw.Context, argv list string) {
	if argv == nil || tl(argv) == nil {
		dump("/ember/tests/type/hello.e")
		return
	}
	for l := tl(argv); l != nil; l = tl(l) {
		dump(hd(l))
	}
}
