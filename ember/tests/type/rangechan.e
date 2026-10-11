module Rangechantest

// "for x := range c": receive from a channel until the body breaks

import sys "sys"
import draw "draw"

func producer(c chan int, n int) {
	for i := 1; i <= n; i++ {
		c <- i * i
	}
	c <- -1
}

func init(ctxt ref draw.Context, args list string) {
	c := chan int
	spawn producer(c, 4)
	sum := 0
	for x := range c {
		if x < 0 {
			break
		}
		sum += x
	}
	sys.print("sum %d\n", sum)
	words := chan string
	spawn func() {
		words <- "a"
		words <- "b"
		words <- ""
	}()
	s := ""
	for w := range words {
		if w == "" {
			break
		}
		s += w
	}
	sys.print("%s\n", s)
}
