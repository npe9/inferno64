module Matchbind

// "match r := f() { ... }": the name the match declares is its
// subject, as in a type switch

import sys "sys"
import draw "draw"

type Shape pick {
	Circle(r int)
	Rect(w int, h int)
}

var calls = 0

func shape(n int) ref Shape {
	calls++
	if n == 0 {
		return ref Shape.Circle{r: 2}
	}
	return ref Shape.Rect{w: n, h: n + 1}
}

func area(n int) int {
	match s := shape(n) {
	case Shape.Circle(r):
		return 3 * r * r
	case Shape.Rect(w, h):
		return w * h
	}
	return 0
}

func kind(n int) string {
	match s := shape(n) {
	case Shape.Circle:
		return "circle"
	}
	return "other"
}

func init(ctxt ref draw.Context, args list string) {
	calls = 0
	sys.print("%d %d calls=%d\n", area(0), area(3), calls)
	sys.print("%s %s\n", kind(0), kind(1))
	// the older two-part form still works
	match v := 2 + 3; v {
	case 5:
		sys.print("five\n")
	default:
		sys.print("other\n")
	}
	// and a string subject
	match s := "abc" {
	case "abc":
		sys.print("%s\n", s)
	}
}
