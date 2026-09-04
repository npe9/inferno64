module Exported

// with export markers, ember -i derives only the marked declarations

import sys "sys"

export const Version = 3

const secret = 42

export type Point struct {
	x int
	y int
}

func (p ref Point) sum() int {
	return p.x + p.y
}

type hidden struct {
	n int
}

export func origin() ref Point {
	return ref Point{x: 0, y: 0}
}

func helper() int {
	return secret
}
