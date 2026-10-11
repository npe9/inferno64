module Badalt

import sys "sys"

// alt guards that aren't communications, two defaults, a send on a
// non-channel, a receive into a mismatched variable.

func init() {
	c := chan int
	x := 5
	s := "s"
	alt {
	case x:
		sys.print("plain expression\n")
	case x = 3:
		sys.print("assignment without receive\n")
	case s <- 1:
		sys.print("send on a string\n")
	case s = <-c:
		sys.print("int into string\n")
	default:
		sys.print("one\n")
	default:
		sys.print("two\n")
	}
}
