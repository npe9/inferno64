module Adt

// algebraic data types are limbo adt-with-pick underneath
type Option[T] pick {
	None
	Some(value T)
}

type Result[T, E] pick {
	Ok(value T)
	Err(err E)
}

type Tree pick {
	Leaf
	Node(left, right ref Tree, value int)
}

func depth(t ref Tree) int {
	match t {
	case Leaf:
		return 0
	case Node(l, r, v):
		dl := depth(l)
		dr := depth(r)
		if dl > dr {
			return dl + 1
		}
		return dr + 1
	}
}

func find(xs []int, want int) Option[int] {
	for i := 0; i < len(xs); i++ {
		if xs[i] == want {
			return Some{value: i}
		}
	}
	return None{}
}

func classify(n int) string {
	match n {
	case 0:
		return "zero"
	case 1, 2, 3:
		return "small"
	default:
		return "big"
	}
}

// the ? operator propagates the Err arm of a Result
func parsepair(s string) Result[int, string] {
	a := parseint(s)?
	b := parseint(s)?
	return Ok{value: a + b}
}

func parseint(s string) Result[int, string] {
	if len(s) == 0 {
		return Err{err: "empty"}
	}
	return Ok{value: 42}
}
