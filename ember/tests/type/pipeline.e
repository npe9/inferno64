module Pipeline

import sys "sys"
import bufio "bufio"
import str "string"

// a concurrent pipeline: a reader spawns lines from a file into a
// channel, worker methods (spawned bound-method calls on ref
// receivers) count words with the string library and report through
// a channel of tuples, and the aggregator collects with alt until
// every worker has finished.  the totals match tests/type/wc.e's
// counts for the same file (8 lines, 19 words).  the tick channel is
// buffered so the ticker can finish after init stops listening: a
// process left blocked on a send keeps the emulator alive.

type Worker struct {
	id int
	lines chan string
	results chan (int, int)
}

func (w ref Worker) run() {
	for {
		line := <-w.lines
		if line == nil {
			w.results <- (w.id, -1)
			return
		}
		n := 0
		for l := str.fields(line); l != nil; l = tl(l) {
			n++
		}
		w.results <- (w.id, n)
	}
}

func reader(name string, out chan string, nworkers int) {
	f := bufio.open(name, bufio.OREAD)
	if f != nil {
		for {
			line := f.gets('\n')
			if line == nil {
				break
			}
			out <- line
		}
		f.close()
	}
	for i := 0; i < nworkers; i++ {
		out <- nil
	}
}

func init() {
	lines := chan string
	results := chan (int, int)
	nworkers := 3
	for i := 0; i < nworkers; i++ {
		w := ref Worker{id: i, lines: lines, results: results}
		spawn w.run()
	}
	spawn reader("/ember/tests/type/hello.e", lines, nworkers)

	words := 0
	nlines := 0
	finished := 0
	ticks := 0
	tick := chan[8] int
	spawn ticker(tick)
	for finished < nworkers {
		alt {
		case r := <-results:
			id, n := r
			if n < 0 {
				finished++
			} else {
				nlines++
				words += n
			}
			if id < 0 || id >= nworkers {
				sys.print("bad id %d\n", id)
			}
		case <-tick:
			ticks++
		}
	}
	sys.print("lines=%d words=%d finished=%d ticks<=5=%d\n", nlines, words, finished, ticks <= 5)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}

func ticker(c chan int) {
	for i := 0; i < 5; i++ {
		c <- i
		sys.sleep(1)
	}
}
