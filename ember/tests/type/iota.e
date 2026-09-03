module Iota

// const blocks: iota counts the items from zero, and an item without
// an expression repeats the previous one (with its own iota)

import sys "sys"
import draw "draw"

const (
	Red = iota
	Green
	Blue
)

const (
	KB = 1 << (10 * (iota + 1))
	MB
	GB
)

const (
	A = 'a'
	B = 'b'
	Bit3 = 1 << 3
	Named = "x"
)

func colour(c int) string {
	match c {
	case Red:
		return "red"
	case Green:
		return "green"
	case Blue:
		return "blue"
	default:
		return "?"
	}
}

func init(ctxt ref draw.Context, args list string) {
	const (
		Local = iota + 100
		Other
	)
	sys.print("%d %d %d %s %s\n", Red, Green, Blue, colour(1), colour(2))
	sys.print("%d %d %d\n", KB, MB, GB)
	sys.print("%d %d %d %s %d %d\n", A, B, Bit3, Named, Local, Other)
}
