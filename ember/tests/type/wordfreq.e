module Wordfreq

import sys "sys"
import bufio "bufio"
import str "string"
import hash "hash"

// word frequencies of a file: bufio for lines, the string library for
// splitting and lowercasing, the hash library's table (ref HashVal
// counters updated in place), then the entries copied into a
// dynamically sized array of structs and insertion-sorted by count
// then word -- element reads, element-to-element copies and swaps on
// an array whose element type holds a string.  the output matches
// the host pipeline in tests/type/wordfreq.out's generating comment.

type Entry struct {
	word string
	count int
}

func before(a Entry, b Entry) int {
	if a.count != b.count {
		return a.count > b.count
	}
	return a.word < b.word
}

func sort(es []Entry) {
	for i := 1; i < len(es); i++ {
		e := es[i]
		j := i - 1
		for j >= 0 && before(e, es[j]) {
			es[j+1] = es[j]
			j--
		}
		es[j+1] = e
	}
}

func count(name string) ([]Entry, string) {
	f := bufio.open(name, bufio.OREAD)
	if f == nil {
		return nil, sys.sprint("cannot open %s", name)
	}
	h := hash.new(64)
	n := 0
	for {
		line := f.gets('\n')
		if line == nil {
			break
		}
		for l := str.fields(line); l != nil; l = tl(l) {
			w := str.tolower(hd(l))
			v := h.find(w)
			if v == nil {
				h.insert(w, hash.HashVal{i: 1, r: 0.0, s: w})
				n++
			} else {
				v.i++
			}
		}
	}
	f.close()
	es := [n]Entry
	i := 0
	for l := h.all(); l != nil; l = tl(l) {
		es[i] = Entry{word: hd(l).key, count: hd(l).val.i}
		i++
	}
	sort(es)
	return es, nil
}

func init() {
	es, err := count("/ember/tests/type/wc.e")
	if err != nil {
		sys.print("%s\n", err)
		return
	}
	sys.print("distinct=%d\n", len(es))
	for k := 0; k < 8 && k < len(es); k++ {
		sys.print("%d %s\n", es[k].count, es[k].word)
	}
	total := 0
	for k := 0; k < len(es); k++ {
		total += es[k].count
	}
	sys.print("total=%d\n", total)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
