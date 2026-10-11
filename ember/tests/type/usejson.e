module Usejson

// the Ember JSON library across a module boundary: its interface
// declares a map and a Result, which an interface file can now carry

import sys "sys"
import draw "draw"
import json "json"

func init(ctxt ref draw.Context, args list string) {
	lib := load Json json.PATH
	if lib == nil {
		sys.print("load failed\n")
		return
	}
	src := "{\"a\":1,\"b\":[true,null,\"x\"],\"c\":{\"d\":2.5}}"
	match r := lib.parse(src) {
	case Result[ref json.Value].Err(e):
		sys.print("parse failed: %s\n", e)
		return
	case Result[ref json.Value].Ok(v):
		sys.print("%s\n", lib.text(v))
		a := lib.get(v, "a")
		match a {
		case json.Value.Num(n):
			sys.print("a=%d\n", int(n))
		default:
			sys.print("a is not a number\n")
		}
		b := lib.get(v, "b")
		sys.print("b0=%s b2=%s missing=%d\n", lib.text(lib.at(b, 0)), lib.text(lib.at(b, 2)), lib.get(v, "zz") == nil)
		sys.print("%s", lib.pretty(lib.get(v, "c"), "  "))
	}
	match bad := lib.parse("[1,") {
	case Result[ref json.Value].Err(e):
		sys.print("error: %s\n", e)
	case Result[ref json.Value].Ok(v):
		sys.print("unexpected %s\n", lib.text(v))
	}
}
