module Hashtest

import sys "sys"
import hash "hash"

// methods declared in an interface (module/hash.ei) and called on a
// value of an imported adt type: h.insert(...) dispatches through the
// hash import alias to the link-table entry "HashTable.insert" of a
// real limbo-compiled library, so a wrong receiver or parameter
// signature would be refused at load time (link typecheck), not
// silently miscalled.  also exercises: a struct literal of an imported
// type as a method argument, a list of imported structs walked with
// hd/tl, and an autoloaded import used only through methods.

func init() {
	h := hash.new(16)
	if h == nil {
		sys.print("new failed\n")
		return
	}
	h.insert("one", hash.HashVal{i: 1, r: 1.5, s: "uno"})
	h.insert("two", hash.HashVal{i: 2, r: 2.5, s: "dos"})
	h.insert("three", hash.HashVal{i: 3, r: 3.5, s: "tres"})

	v := h.find("two")
	if v == nil {
		sys.print("find failed\n")
		return
	}
	sys.print("two: %d %s\n", v.i, v.s)
	sys.print("missing is nil: %d\n", h.find("four") == nil)

	// update in place through insert, then read back
	h.insert("two", hash.HashVal{i: 22, r: 0.0, s: "veintidos"})
	sys.print("two again: %d %s\n", h.find("two").i, h.find("two").s)

	h.delete("one")
	sys.print("one after delete is nil: %d\n", h.find("one") == nil)

	// walk the list of nodes: order is the table's own, so sum instead
	n := 0
	sum := 0
	for l := h.all(); l != nil; l = tl(l) {
		n++
		sum += hd(l).val.i
	}
	sys.print("count=%d sum=%d\n", n, sum)

	// a plain module function beside the methods
	sys.print("fun1 in range: %d\n", hash.fun1("abc", 7) >= 0 && hash.fun1("abc", 7) < 7)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
