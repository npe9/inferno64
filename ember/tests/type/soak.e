module Soak

import sys "sys"

// a reference-counting soak: every kind of allocation churned many
// times with a bounded live set -- a leaked reference anywhere in the
// compiler's moves and temporaries would exhaust the emulator's arena
// ("out of memory"), and a dropped one would corrupt it.  each round
// builds structs with strings, arrays of refs, lists, tuples,
// closures, channels, picks and byte arrays, reads them back, and
// discards them.

type Item struct {
	name string
	tags list string
	next ref Item
}

type Box pick {
	Empty()
	Full(it ref Item, n int)
}

func build(k int) ref Item {
	var head ref Item
	for i := 0; i < 8; i++ {
		head = ref Item{name: sys.sprint("item%d.%d", k, i), tags: "a" :: "b" :: nil, next: head}
	}
	return head
}

func total(l ref Item) int {
	t := 0
	for p := l; p != nil; p = p.next {
		t += len(p.name) + len(p.tags)
	}
	return t
}

func pair(k int) (string, []byte) {
	return sys.sprint("p%d", k), []byte(sys.sprint("bytes%d", k))
}

func boxed(k int) ref Box {
	if k % 3 == 0 {
		return ref Box.Empty{}
	}
	return ref Box.Full{it: build(k), n: k}
}

func init() {
	sum := 0
	keep := [16]ref Item
	c := chan[4] string
	for round := 0; round < 3000; round++ {
		it := build(round)
		keep[round % 16] = it
		sum += total(it)

		s, b := pair(round)
		sum += len(s) + len(b)

		add := func(x int) int {
			return x + len(it.name)
		}
		sum += add(round) - round

		c <- s
		sum += len(<-c)

		match boxed(round) {
		case Box.Empty():
			sum += 1
		case Box.Full(x, n):
			sum += total(x) + n - round
		}

		xs := [64]int
		xs[round % 64] = round
		ys := xs[1:]
		sum += len(ys) - 63

		t := (round, s)
		sum += t.t0 - round
	}
	sys.print("sum=%d live=%d\n", sum, keep[3] != nil)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
