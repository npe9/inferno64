module Tsort2

// appl/cmd/tsort.b again, written the way Ember allows now rather
// than line for line: items live in a map (tsort.b walks a linked
// list for every lookup, "would use a hash table for large sets"),
// the input order is kept in an array grown with append, the output
// buffer is flushed by a defer, and the cycle report reverses a list
// with a range loop.

import sys "sys"
import draw "draw"
import bufio "bufio"

type Item struct {
	name string
	mark int
	succ list ref Item	// node's successors
}

var items = map[string]ref Item{}
var order []ref Item	// items in input order
var bout ref bufio.Iobuf

func init(ctxt ref draw.Context, args list string) {
	bout = bufio.fopen(sys.fildes(1), sys.OWRITE)
	defer bout.flush()
	input()
	output()
}

func input() {
	b := bufio.fopen(sys.fildes(0), sys.OREAD)
	for line := b.gets('\n'); line != nil; line = b.gets('\n') {
		_, fld := sys.tokenize(line, " \t\n")
		if fld == nil {
			continue
		}
		a := finditem(hd(fld))
		for _, name := range tl(fld) {
			a.precede(finditem(name))
		}
	}
}

func (a ref Item) precede(b ref Item) {
	if a == b {
		return
	}
	for _, s := range a.succ {
		if s == b {
			return
		}
	}
	a.succ = b :: a.succ
}

func finditem(s string) ref Item {
	if i, ok := items[s]; ok {
		return i
	}
	i := ref Item{name: s}
	items[s] = i
	order = append(order, i)
	return i
}

var dep list ref Item

func output() {
	for _, q := range order {
		if q.mark == 0 {
			visit(q, nil)
		}
	}
	for _, d := range dep {
		bout.puts(d.name + "\n")
	}
}

// visit q's successors depth first; parents is only used to print
// any cycles
func visit(q ref Item, parents list ref Item) {
	q.mark = 2
	parents = q :: parents
	for _, s := range q.succ {
		match s.mark {
		case 0:
			visit(s, parents)
		case 2:
			sys.fprint(sys.fildes(2), "tsort: cycle in input\n")
			var cycle list ref Item	// reversed, closer to input order
			for _, p := range parents {
				cycle = p :: cycle
				if p == s {
					break
				}
			}
			for _, p := range cycle {
				sys.fprint(sys.fildes(2), "tsort: %s\n", p.name)
			}
		}
	}
	q.mark = 1
	dep = q :: dep
}
