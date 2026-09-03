module Tsort

// appl/cmd/tsort.b in Ember: topological sort, converting a partial
// ordering read from standard input into a linear ordering

import sys "sys"
import draw "draw"
import bufio "bufio"

type Item struct {
	name string
	mark int
	succ list ref Item	// node's successors
}

type Q struct {
	item ref Item
	next ref Q
}

var items, itemt ref Q	// use a Q not a list only to keep input order
var nitem = 0
var bout ref bufio.Iobuf

func init(ctxt ref draw.Context, args list string) {
	bout = bufio.fopen(sys.fildes(1), sys.OWRITE)
	input()
	output()
	bout.flush()
}

func error(s string) {
	sys.fprint(sys.fildes(2), "tsort: %s\n", s)
	raise "fail:error"
}

func input() {
	b := bufio.fopen(sys.fildes(0), sys.OREAD)
	for {
		line := b.gets('\n')
		if line == nil {
			break
		}
		n, fld := sys.tokenize(line, " \t\n")
		if fld != nil {
			a := finditem(hd(fld))
			for fld = tl(fld); fld != nil; fld = tl(fld) {
				a.precede(finditem(hd(fld)))
			}
		}
	}
}

func (a ref Item) precede(b ref Item) {
	if a != b {
		for l := a.succ; l != nil; l = tl(l) {
			if hd(l) == b {
				return
			}
		}
		a.succ = b :: a.succ
	}
}

func finditem(s string) ref Item {
	// would use a hash table for large sets
	for il := items; il != nil; il = il.next {
		if il.item.name == s {
			return il.item
		}
	}
	i := ref Item{name: s, mark: 0}
	if items != nil {
		itemt.next = ref Q{item: i, next: nil}
		itemt = itemt.next
	} else {
		items = ref Q{item: i, next: nil}
		itemt = items
	}
	nitem++
	return i
}

var dep list ref Item

func output() {
	for k := items; k != nil; k = k.next {
		q := k.item
		if q.mark == 0 {
			visit(q, nil)
		}
	}
	for ; dep != nil; dep = tl(dep) {
		bout.puts(hd(dep).name + "\n")
	}
}

// visit q's successors depth first
// parents is only used to print any cycles, and since it matches
// the stack, the recursion could be eliminated
func visit(q ref Item, parents list ref Item) {
	q.mark = 2
	parents = q :: parents
	for sl := q.succ; sl != nil; sl = tl(sl) {
		s := hd(sl)
		if s.mark == 0 {
			visit(s, parents)
		} else if s.mark == 2 {
			sys.fprint(sys.fildes(2), "tsort: cycle in input\n")
			var rl list ref Item
			l := parents
			for ; ; l = tl(l) {	// reverse to be closer to input order
				rl = hd(l) :: rl
				if hd(l) == s {
					break
				}
			}
			for l = rl; l != nil; l = tl(l) {
				sys.fprint(sys.fildes(2), "tsort: %s\n", hd(l).name)
			}
		}
	}
	q.mark = 1
	dep = q :: dep
}
