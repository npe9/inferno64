module Pipeline

import sys "sys"
import draw "draw"

func counter(out chan int, n int) {
	for i := 0; i < n; i++ {
		out <- i
	}
}

func sum(in chan int, done chan int, n int) {
	total := 0
	for i := 0; i < n; i++ {
		total += <-in
	}
	done <- total
}

func init(ctxt ref draw.Context, argv list string) {
	c := chan int
	done := chan int
	spawn counter(c, 10)
	spawn sum(c, done, 10)
	total := <-done
	sys.print("total %d\n", total)
}
