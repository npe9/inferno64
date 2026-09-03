module Globalstr

// module variables initialized with string literals (the empty string
// too): the data-section writer crashed on them (found by the
// self-hosted parser's own globals).
import sys "sys"
var name = "hello"
var empty = ""
var n = 3
func init() {
	sys.print("%s [%s] %d %d\n", name, empty, len(name), n)
	name += " there"
	sys.print("%s\n", name)
}
