module Alttest

import sys "sys"

// alt: receive into a fresh variable, into an existing one, a bare
// receive, a send arm, and default (non-blocking).  the two producers
// interleave nondeterministically, so only totals are printed.

func producer(c chan int, n int) {
	for i := 1; i <= n; i++ {
		c <- i
	}
}

func greeter(c chan string) {
	c <- "hi"
}

func init() {
	a := chan int
	b := chan string
	spawn producer(a, 3)
	spawn greeter(b)
	got := 0
	sum := 0
	msg := ""
	for got < 3 || msg == "" {
		alt {
		case v := <-a:
			got++
			sum += v
		case s := <-b:
			msg = s
		}
	}
	sys.print("got=%d sum=%d msg=%s\n", got, sum, msg)

	// non-blocking: nothing ready
	alt {
	case v := <-a:
		sys.print("unexpected %d\n", v)
	default:
		sys.print("nothing ready\n")
	}

	// a send arm on a buffered channel, then a full one
	buf := chan[1] int
	alt {
	case buf <- 42:
		sys.print("sent\n")
	default:
		sys.print("full\n")
	}
	alt {
	case buf <- 43:
		sys.print("sent again\n")
	default:
		sys.print("full now\n")
	}
	sys.print("recv=%d\n", <-buf)

	// receive into an existing variable, and a bare receive
	var x int
	spawn producer(a, 1)
	alt {
	case x = <-a:
		sys.print("x=%d\n", x)
	}
	spawn producer(a, 1)
	alt {
	case <-a:
		sys.print("discarded\n")
	}

	// a send arm competing with a receive: only the send can proceed
	// (nobody is sending on a), the value is a computed expression
	spawn consumer(buf)
	alt {
	case v := <-a:
		sys.print("unexpected %d\n", v)
	case buf <- 6*7:
		sys.print("sent 42 to consumer\n")
	}
	sys.sleep(50)

	// a channel that is a computed expression (a call result, an
	// array element): the table holds a real reference to it (isptr)
	chans := [2]chan int{chan int, chan int}
	spawn producer(chans[1], 1)
	spawn producer(choose(chans), 1)
	n := 0
	for n < 2 {
		alt {
		case v := <-chans[1]:
			n++
			sys.print("from element: %d\n", v)
		case w := <-choose(chans):
			n++
			sys.print("from call: %d\n", w)
		}
	}

	// break out of an alt inside a loop, by label
	spawn producer(a, 5)
	total := 0
loop:
	for {
		alt {
		case v := <-a:
			total += v
			if v == 5 {
				break loop
			}
		}
	}
	sys.print("total=%d\n", total)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}

func consumer(c chan int) {
	v := <-c
	sys.print("consumer got %d\n", v)
}

func choose(cs []chan int) chan int {
	return cs[0]
}
