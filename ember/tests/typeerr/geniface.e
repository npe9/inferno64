module Geniface

// geniface.ei beside this file: a generic method cannot be declared
// in an interface, and a generic function there needs its body

type Box struct {
	v int
}

func ident[T](x T) T {
	return x
}

func plain(x int) int {
	return x
}
