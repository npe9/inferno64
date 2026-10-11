module Enumtest

// a typed constant block over a named type: the enum a Go programmer
// writes, with methods on the values

import sys "sys"
import draw "draw"

type Level int

const (
	Low Level = iota
	Mid
	High
)

const Origin Level = 0

const Plain = 7

type Suit string

const (
	Hearts Suit = "hearts"
	Spades Suit = "spades"
)

func (l Level) label() string {
	match l {
	case Low:
		return "low"
	case Mid:
		return "mid"
	}
	return "high"
}

func (l Level) above(m Level) int {
	return int(l) > int(m)
}

func (s Suit) red() int {
	return s == Hearts
}

func init(ctxt ref draw.Context, args list string) {
	sys.print("%s %s %s\n", Low.label(), Mid.label(), High.label())
	sys.print("%d %d %d\n", int(Low), int(Mid), int(High))
	sys.print("%d %d\n", High.above(Low), Low.above(High))
	sys.print("%s %d\n", Origin.label(), Plain)
	var l Level
	l = High
	sys.print("%s %d\n", l.label(), int(l) + 1)
	sys.print("%d %d %s\n", Hearts.red(), Spades.red(), string(Spades))
}
