module Genpick

import sys "sys"
import draw "draw"

// a generic pick: its tags are attached at each instantiation with
// the type parameters in scope; Result[int].Ok names a tag in a
// literal, a match pattern and a type; ? propagates through it

type Result[T] pick {
	Ok(v T)
	Err(msg string)
}

type Option[T] pick {
	Some(v T)
	None()
}

func parse(s string) ref Result[int] {
	if s == "" {
		return ref Result[int].Err{msg: "empty"}
	}
	return ref Result[int].Ok{v: len(s)}
}

func twice(s string) ref Result[int] {
	r := parse(s)?
	return ref Result[int].Ok{v: r * 2}
}

func show(r ref Result[int]) string {
	match r {
	case Result[int].Ok(v):
		return sys.sprint("ok %d", v)
	case Result[int].Err(m):
		return "err " + m
	}
	return "?"
}

func first(l list string) ref Option[string] {
	if l == nil {
		return ref Option[string].None{}
	}
	return ref Option[string].Some{v: hd(l)}
}

func init(ctxt ref draw.Context, argv list string) {
	sys.print("%s %s\n", show(twice("abc")), show(twice("")))
	match first("x" :: "y" :: nil) {
	case Option[string].Some(v):
		sys.print("some %s\n", v)
	case Option[string].None():
		sys.print("none\n")
	}
	match first(nil) {
	case Option[string].Some(v):
		sys.print("some %s\n", v)
	case Option[string].None():
		sys.print("none\n")
	}
	var rs ref Result[string]
	rs = ref Result[string].Ok{v: "s"}
	match rs {
	case Result[string].Ok(v):
		sys.print("string ok %s\n", v)
	case Result[string].Err(m):
		sys.print("string err %s\n", m)
	}
}
