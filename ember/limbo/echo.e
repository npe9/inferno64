module Echo

// appl/cmd/echo.b in Ember: print the arguments, -n for no newline

import sys "sys"
import draw "draw"

func init(ctxt ref draw.Context, args list string) {
	if args != nil {
		args = tl(args)
	}
	addnl := true
	if args != nil && (hd(args) == "-n" || hd(args) == "--") {
		if hd(args) == "-n" {
			addnl = false
		}
		args = tl(args)
	}
	s := ""
	if args != nil {
		s = hd(args)
		for args = tl(args); args != nil; args = tl(args) {
			s += " " + hd(args)
		}
	}
	if addnl {
		s[len(s)] = '\n'
	}
	a := []byte(s)
	if sys.write(sys.fildes(1), a, len(a)) < 0 {
		sys.fprint(sys.fildes(2), "echo: write error: %r\n")
		raise "fail:write error"
	}
}
