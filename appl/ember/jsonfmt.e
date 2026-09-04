module Jsonfmt

// jsonfmt: read JSON from a file or from standard input, and write
// it back indented

import sys "sys"
import draw "draw"
import bufio "bufio"
import json "json"

func init(ctxt ref draw.Context, args list string) {
	lib := load Json json.PATH
	if lib == nil {
		sys.fprint(sys.fildes(2), "jsonfmt: cannot load %s: %r\n", json.PATH)
		raise "fail:load"
	}
	if args != nil {
		args = tl(args)
	}
	var bio ref bufio.Iobuf
	if args != nil {
		bio = bufio.open(hd(args), bufio.OREAD)
		if bio == nil {
			sys.fprint(sys.fildes(2), "jsonfmt: cannot open %s: %r\n", hd(args))
			raise "fail:open"
		}
	} else {
		bio = bufio.fopen(sys.fildes(0), bufio.OREAD)
	}
	b := ref Builder{}
	for {
		s := bio.gets('\n')
		if s == nil {
			break
		}
		b.puts(s)
	}
	match r := lib.parse(b.string()) {
	case Result[ref json.Value].Err(e):
		sys.fprint(sys.fildes(2), "jsonfmt: %s\n", e)
		raise "fail:parse"
	case Result[ref json.Value].Ok(v):
		sys.print("%s", lib.pretty(v, "  "))
	}
}
