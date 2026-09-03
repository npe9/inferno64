module Genpick2

import sys "sys"
import draw "draw"

// generic picks with methods, generic constructors, nesting and ? in
// a generic function; a tag value infers its pick (ok(ref
// Option[int].Some{...}) is a Result[ref Option[int]]), and every
// mention of an instantiation with a composite type argument names
// the same instance
type Result[T] pick {
	Ok(v T)
	Err(msg string)
}

type Option[T] pick {
	Some(v T)
	None()
}

func ok[T](v T) ref Result[T] {
	return ref Result[T].Ok{v: v}
}

func fail[T](msg string) ref Result[T] {
	return ref Result[T].Err{msg: msg}
}

func (r ref Result[T]) or(d T) T {
	match r {
	case Result[T].Ok(v):
		return v
	case Result[T].Err(m):
		return d
	}
	return d
}

func lift[T](o ref Option[T]) ref Result[T] {
	match o {
	case Option[T].Some(v):
		return ok(v)
	case Option[T].None():
		return fail[T]("none")
	}
	return fail[T]("?")
}

func both(a ref Result[int], b ref Result[int]) ref Result[int] {
	x := a?
	y := b?
	return ok(x + y)
}

func init(ctxt ref draw.Context, argv list string) {
	a := ok(20)
	b := fail[int]("bad")
	boxes()
	sys.print("%d %d\n", a.or(0), b.or(-1))
	sys.print("%d %d\n", both(a, ok(22)).or(0), both(a, b).or(-1))
	s := lift(ref Option[string].Some{v: "hi"})
	n := lift[int](ref Option[int].None{})
	sys.print("%s %d\n", s.or("?"), n.or(7))
	nested := ok(ref Option[int].Some{v: 5})
	match nested {
	case Result[ref Option[int]].Ok(o):
		match o {
		case Option[int].Some(v):
			sys.print("nested %d\n", v)
		case Option[int].None():
			sys.print("nested none\n")
		}
	case Result[ref Option[int]].Err(m):
		sys.print("err %s\n", m)
	}
}

type Box[T] struct {
	val T
}

func total(b Box[[]int]) int {
	t := 0
	for i := 0; i < len(b.val); i++ {
		t += b.val[i]
	}
	return t
}

func mkbox() Box[[]int] {
	return Box[[]int]{val: [3]int{1, 2, 3}}
}

func boxes() {
	b := mkbox()
	var c Box[[]int]
	c = b
	sys.print("%d %d\n", total(c), total(mkbox()))
}
